local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

local CONFIG = {
    GroundThreshold = 10,
    GroundResetThreshold = 8,
    AirborneDuration = 5,
    AirborneDropGrace = 0.35,
    FastTurnThreshold = 220,
    FastTurnDuration = 0.3,
    RayLength = 2048,
    SampleInset = 0.8,
    DistanceSmoothingAlpha = 0.35,
    WindowName = "Anticheat",
    ConfigFolderName = "anticheat_configs",
    ConfigFileName = "config",
    WebhookUrl = "",
    AllowedUserIds = {
        5191232085,
        9362153313,
    },
}

local monitorEnabled = true
local playerStates = {}
local notifyAlert = nil
local webhookRequest = syn and syn.request or http_request or request or (fluxus and fluxus.request) or nil

local function setWebhookUrl(value)
    CONFIG.WebhookUrl = tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function isUserAllowed()
    if not LocalPlayer then
        return false
    end

    for _, userId in ipairs(CONFIG.AllowedUserIds) do
        if tonumber(userId) == LocalPlayer.UserId then
            return true
        end
    end

    return false
end

local function sendWebhook(message)
    if CONFIG.WebhookUrl == "" or not webhookRequest then
        return
    end

    local payload = {
        content = string.format("[AltitudeMonitor] %s", message),
    }

    local ok, err = pcall(function()
        webhookRequest({
            Url = CONFIG.WebhookUrl,
            Method = "POST",
            Headers = {
                ["Content-Type"] = "application/json",
            },
            Body = HttpService:JSONEncode(payload),
        })
    end)

    if not ok then
        warn("[AltitudeMonitor] Webhook failed: " .. tostring(err))
    end
end

local function dispatchAlert(message)
    if notifyAlert then
        notifyAlert(message)
    else
        warn("[AltitudeMonitor] " .. message)
    end

    sendWebhook(message)
end

local function getState(player)
    local state = playerStates[player]

    if not state then
        state = {
            airborneSince = nil,
            fastTurnSince = nil,
            lastAboveAt = nil,
            lastTrackedCFrame = nil,
            lastTrackedSampleAt = nil,
            smoothedDistance = nil,
            fired = false,
            fastTurnFired = false,
        }
        playerStates[player] = state
    end

    return state
end

local function resetState(player)
    playerStates[player] = {
        airborneSince = nil,
        fastTurnSince = nil,
        lastAboveAt = nil,
        lastTrackedCFrame = nil,
        lastTrackedSampleAt = nil,
        smoothedDistance = nil,
        fired = false,
        fastTurnFired = false,
    }
end

local function clearAllStates()
    for player in pairs(playerStates) do
        resetState(player)
    end
end

local function getCharacterParts(player)
    local character = player.Character
    if not character then
        return nil
    end

    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local rootPart = character:FindFirstChild("HumanoidRootPart")

    if not humanoid or humanoid.Health <= 0 or not rootPart then
        return nil
    end

    return character, humanoid, rootPart
end

local function getTrackedAssembly(character, humanoid)
    local seatPart = humanoid.SeatPart
    if not seatPart then
        return character, false
    end

    local assemblyRoot = seatPart.AssemblyRootPart
    if assemblyRoot then
        local modelFromAssembly = assemblyRoot:FindFirstAncestorOfClass("Model")
        if modelFromAssembly and modelFromAssembly ~= character then
            return modelFromAssembly, true
        end

        return assemblyRoot, true
    end

    local vehicleModel = seatPart.Parent
    if vehicleModel and vehicleModel ~= character then
        return vehicleModel, true
    end

    return seatPart, true
end

local function getTrackedAssemblyTransform(character, humanoid)
    local trackedAssembly, usingVehicle = getTrackedAssembly(character, humanoid)

    if trackedAssembly:IsA("Model") then
        local trackedCFrame, trackedSize = trackedAssembly:GetBoundingBox()
        return trackedAssembly, usingVehicle, trackedCFrame, trackedSize
    end

    return trackedAssembly, usingVehicle, trackedAssembly.CFrame, trackedAssembly.Size
end

local function getSampleOrigins(trackedCFrame, trackedSize)
    local halfX = (trackedSize.X / 2) * CONFIG.SampleInset
    local halfY = (trackedSize.Y / 2) - 0.25
    local halfZ = (trackedSize.Z / 2) * CONFIG.SampleInset

    return {
        trackedCFrame:PointToWorldSpace(Vector3.new(0, -halfY, 0)),
        trackedCFrame:PointToWorldSpace(Vector3.new(halfX, -halfY, halfZ)),
        trackedCFrame:PointToWorldSpace(Vector3.new(halfX, -halfY, -halfZ)),
        trackedCFrame:PointToWorldSpace(Vector3.new(-halfX, -halfY, halfZ)),
        trackedCFrame:PointToWorldSpace(Vector3.new(-halfX, -halfY, -halfZ)),
    }
end

local function getGroundDistance(character, humanoid)
    local trackedAssembly, usingVehicle, trackedCFrame, trackedSize = getTrackedAssemblyTransform(character, humanoid)

    local raycastParams = RaycastParams.new()
    raycastParams.FilterType = Enum.RaycastFilterType.Exclude
    raycastParams.FilterDescendantsInstances = { character, trackedAssembly }
    raycastParams.IgnoreWater = false

    local shortestDistance = nil

    for _, origin in ipairs(getSampleOrigins(trackedCFrame, trackedSize)) do
        local result = workspace:Raycast(origin, Vector3.new(0, -CONFIG.RayLength, 0), raycastParams)
        if result then
            local distance = origin.Y - result.Position.Y
            if not shortestDistance or distance < shortestDistance then
                shortestDistance = distance
            end
        end
    end

    if not shortestDistance then
        return CONFIG.RayLength, usingVehicle, trackedCFrame
    end

    return shortestDistance, usingVehicle, trackedCFrame
end

local function getTurnRateDegreesPerSecond(previousCFrame, currentCFrame, deltaTime)
    if not previousCFrame or not currentCFrame or not deltaTime or deltaTime <= 0 then
        return 0
    end

    local relativeRotation = previousCFrame:ToObjectSpace(currentCFrame)
    local _, angle = relativeRotation:ToAxisAngle()
    return math.deg(math.abs(angle)) / deltaTime
end

local function processPlayer(player)
    local state = getState(player)
    local character, humanoid, rootPart = getCharacterParts(player)
    local now = os.clock()

    if not character or not humanoid or not rootPart then
        state.airborneSince = nil
        state.fastTurnSince = nil
        state.lastAboveAt = nil
        state.lastTrackedCFrame = nil
        state.lastTrackedSampleAt = nil
        state.smoothedDistance = nil
        state.fired = false
        state.fastTurnFired = false
        return
    end

    local groundDistance, usingVehicle, trackedCFrame = getGroundDistance(character, humanoid)
    if not groundDistance then
        state.airborneSince = nil
        state.fastTurnSince = nil
        state.lastAboveAt = nil
        state.lastTrackedCFrame = nil
        state.lastTrackedSampleAt = nil
        state.smoothedDistance = nil
        state.fired = false
        state.fastTurnFired = false
        return
    end

    if state.smoothedDistance == nil then
        state.smoothedDistance = groundDistance
    else
        state.smoothedDistance = state.smoothedDistance + ((groundDistance - state.smoothedDistance) * CONFIG.DistanceSmoothingAlpha)
    end

    local aboveThreshold = state.smoothedDistance > CONFIG.GroundThreshold
    local belowResetThreshold = state.smoothedDistance <= CONFIG.GroundResetThreshold

    if aboveThreshold then
        state.lastAboveAt = now
    elseif belowResetThreshold then
        local shouldReset = (not state.lastAboveAt) or ((now - state.lastAboveAt) > CONFIG.AirborneDropGrace)
        if shouldReset then
            state.airborneSince = nil
            state.fastTurnSince = nil
            state.lastAboveAt = nil
            state.fired = false
            state.fastTurnFired = false
            return
        end
    else
        if state.airborneSince and state.lastAboveAt and (now - state.lastAboveAt) > CONFIG.AirborneDropGrace then
            state.airborneSince = nil
            state.fastTurnSince = nil
            state.lastAboveAt = nil
            state.fired = false
            state.fastTurnFired = false
            return
        end
    end

    local turnRate = 0
    if usingVehicle and trackedCFrame and state.lastTrackedCFrame and state.lastTrackedSampleAt then
        turnRate = getTurnRateDegreesPerSecond(state.lastTrackedCFrame, trackedCFrame, now - state.lastTrackedSampleAt)
    end

    state.lastTrackedCFrame = trackedCFrame
    state.lastTrackedSampleAt = now

    if usingVehicle and aboveThreshold and turnRate >= CONFIG.FastTurnThreshold then
        if not state.fastTurnSince then
            state.fastTurnSince = now
        end
    else
        state.fastTurnSince = nil
        state.fastTurnFired = false
    end

    if not state.airborneSince then
        state.airborneSince = now
        state.fired = false
        return
    end

    if state.fired then
        if state.fastTurnFired or not state.fastTurnSince then
            return
        end
    end

    if now - state.airborneSince >= CONFIG.AirborneDuration then
        if not state.fired then
            state.fired = true
            local message = string.format(
                "%s - %.2f studs",
                player.Name,
                state.smoothedDistance
            )
            dispatchAlert(message)
        end
    end

    if usingVehicle and state.fastTurnSince and not state.fastTurnFired and (now - state.fastTurnSince) >= CONFIG.FastTurnDuration then
        state.fastTurnFired = true
        local message = string.format(
            "%s - %.2f studs",
            player.Name,
            state.smoothedDistance or 0
        )
        dispatchAlert(message)
    end
end

local function onCharacterAdded(player)
    resetState(player)
end

local function onPlayerAdded(player)
    resetState(player)
    player.CharacterAdded:Connect(function()
        onCharacterAdded(player)
    end)
end

local function onPlayerRemoving(player)
    playerStates[player] = nil
end

for _, player in ipairs(Players:GetPlayers()) do
    onPlayerAdded(player)
end

Players.PlayerAdded:Connect(onPlayerAdded)
Players.PlayerRemoving:Connect(onPlayerRemoving)

if not isUserAllowed() then
    warn("[AltitudeMonitor] Accès refusé pour l'utilisateur Roblox : " .. tostring(LocalPlayer and LocalPlayer.UserId or "inconnu"))
    return
end

local guiLoaded, guiError = pcall(function()
    local Rayfield = loadstring(game:HttpGet("https://sirius.menu/rayfield"))()
    notifyAlert = function(message)
        Rayfield:Notify({
            Title = "Alerte",
            Content = message,
            Duration = 6.5,
            Image = 4483362458,
        })
    end

    local Window = Rayfield:CreateWindow({
        Name = CONFIG.WindowName,
        LoadingTitle = CONFIG.WindowName,
        LoadingSubtitle = "Anticheat de car fly",
        ConfigurationSaving = {
            Enabled = true,
            FolderName = CONFIG.ConfigFolderName,
            FileName = CONFIG.ConfigFileName,
        },
        Discord = {
            Enabled = false,
        },
        KeySystem = false,
    })

    local MainTab = Window:CreateTab("Anticheat", 4483362458)

    MainTab:CreateToggle({
        Name = "Active l'anticheat",
        CurrentValue = monitorEnabled,
        Flag = "AltitudeMonitorEnabled",
        Callback = function(value)
            monitorEnabled = value
            if not monitorEnabled then
                clearAllStates()
            end
        end,
    })

    MainTab:CreateInput({
        Name = "Webhook Discord",
        PlaceholderText = "Colle ta webhook puis appuie sur Entrée",
        RemoveTextAfterFocusLost = false,
        Callback = function(value)
            setWebhookUrl(value)
            if notifyAlert then
                notifyAlert("Webhook enregistrée")
            end
        end,
    })
end)

if not guiLoaded then
    warn("[AltitudeMonitor] Rayfield failed to load: " .. tostring(guiError))
end

RunService.Heartbeat:Connect(function()
    if not monitorEnabled then
        return
    end

    for _, player in ipairs(Players:GetPlayers()) do
        processPlayer(player)
    end
end)
