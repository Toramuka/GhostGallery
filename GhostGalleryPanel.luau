-- Halloween Farm v0.14 -- October 6, 2026
-- Run the complete file in your existing Roblox executor.
-- Enter the Haunted Manor first, or run during a Ghost Gallery round.
-- Click Ghost Gallery once; close the executor and F9; move the pointer off the panel.
-- End stops automation. Right Shift hides/shows the panel. X unloads everything.
-- Targets released ghosts whose visual names match GhostClustersLive.
-- Furniture sweep tries all loaded ManorMinigameInterior furniture, including unmarked items.
-- A generic visual vanishing beside furniture creates a temporary landing candidate.
-- Landing candidates are inferred, and still require live-game verification.
-- Unmatched boss targeting is not implemented.
-- Queue entry, navigation, aiming, and input need live-game verification.
-- Uses executor left-click while focused, client-only VirtualInput in the background.
-- Reconciles the requested hold with the engine button state and retries lost input.
-- Duplicate virtual button states are reconciled without a runtime pause.
-- Temporary knockdowns retain the target and resume with a fresh click after recovery.
-- While Ghost Gallery is enabled, dismiss the known Nice reward button after a round.
-- Decline the Ghost Gallery teleport invitation each time it appears.
-- Dismiss recognized cash-bonus dialogs and cash out recognized paycheck rewards.
-- Background farming remains a test mode; engine/executor support varies.
-- It is available only when this client supplies CreateVirtualInput().
-- One Ghost Gallery toggle enables queueing, movement, hunting and held blasting.
-- Background mode defaults ON when supported. Automatic camera aiming is ON.
-- Looking around and scrolling never disable the farm. Mouse aiming yields during
-- camera drags, then resumes without a second click. Targets must still be visible.
-- With auto-turn OFF, mouse aiming fires only at visible targets; 360-degree
-- direction independent of the camera is not implemented by this input backend.
-- With automatic camera aiming, align the view under the user's current cursor
-- instead of moving that cursor. This input path needs live verification.
-- Selection and following use character-space geometry, independent of the POV.
-- Uses the captured GhostClustersShielded and GhostClustersIsShield attributes.
-- When a boss does not expose its shield flag, retain the conservative fallback.
-- Continuous blast holds through aiming/movement; UI, stop, errors and round end release it.
-- Uses the paths in your captures; no downloaded UI library or remote calls.

local CONFIG = {
    StartDelay = 5,
    SearchRadius = 180,
    AimDistance = 40, -- Conservative setting, not a verified blaster range.
    FollowDistance = 22,
    FollowStart = 32,
    FollowStop = 26,
    FurnitureFollowDistance = 7,
    FurnitureFollowStart = 13,
    FurnitureFollowStop = 10,
    FurnitureAimDistance = 16,
    CameraTurnRate = 12,
    CameraShotWait = 0.8,
    CameraAimTolerance = 1,
    FocusInputDelay = 0.12,
    InputCheckInterval = 0.2,
    InputSettleSeconds = 0.35,
    InputRetrySeconds = 0.8,
    ShotRetrySeconds = 1.5,
    ShotRetryLimit = 2,
    KnockbackHorizontalSpeed = 45,
    CharacterRecoveryDelay = 0.12,
    RewardSettleSeconds = 0.7,
    RewardClickSeconds = 0.08,
    RewardRetrySeconds = 2,
    PopupRefreshSeconds = 0.25,
    TargetRouteBudget = 14,
    AimStallSeconds = 2,
    HintObservationWindow = 0.8,
    LandingLifetime = 24,
    FurnitureBlastBudget = 6,
    FurnitureSweepBlastBudget = 3,
    FurnitureAttemptBudget = 8,
    FurnitureSweepCooldown = 35,
    FloorTolerance = 6,
    TargetCooldown = 8,
    BossClearDelay = 1.2,
    BossNoProgressBudget = 4,
    BossRetrySeconds = 4,
    HintSurfaceDistance = 4,
    HintCenterDistance = 16,
    RefreshSeconds = 0.35,
    QueueRetrySeconds = 8,
    ManorDistance = 350,
}

local ENV_KEY = "__GhostGalleryPanel_v1"
local BINDING = "GhostGalleryPanel_v1"
local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")
local PathfindingService = game:GetService("PathfindingService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local player = Players.LocalPlayer

local function log(message)
    print("[GGPANEL] " .. message)
end

if not player or game.PlaceId ~= 920587237 then
    log("STOP: this file expects the Adopt Me client from your capture.")
    return
end

local playerGui = player:FindFirstChildOfClass("PlayerGui") or player:WaitForChild("PlayerGui", 10)
if not playerGui then
    log("STOP: PlayerGui is unavailable.")
    return
end

local environment = _G
if type(getgenv) == "function" then
    local ok, value = pcall(getgenv)
    if ok and type(value) == "table" then
        environment = value
    end
end
for _, key in ipairs({ "__GhostGalleryAimTest_v1", ENV_KEY }) do
    local previous = environment[key]
    if type(previous) == "table" then
        local finish = previous.Unload or previous.Stop
        if type(finish) == "function" then
            pcall(finish, "replaced by Ghost Gallery Panel")
        end
    end
end

local function inputFunction(name, direct)
    if type(direct) == "function" then
        return direct
    end
    local value = environment[name]
    return type(value) == "function" and value or nil
end
local pressMouse = inputFunction("mouse1press", mouse1press)
local releaseMouse = inputFunction("mouse1release", mouse1release)
local moveMouse = inputFunction("mousemoverel", mousemoverel)
local windowActive = inputFunction("isrbxactive", isrbxactive)
local canBlast = pressMouse ~= nil and releaseMouse ~= nil and moveMouse ~= nil
local virtualClient: any = nil
local virtualUnavailable = "This client did not provide VirtualInput."
do
    local ok, value = pcall(function()
        local inputServiceForProbe: any = UserInputService
        return inputServiceForProbe:CreateVirtualInput()
    end)
    if ok and value ~= nil then
        virtualClient = value
    elseif not ok then
        virtualUnavailable = tostring(value)
    end
end

local function follow(parent, names)
    local current = parent
    for _, name in ipairs(names) do
        current = current and current:FindFirstChild(name)
    end
    return current
end
local function visible(object)
    if not object or not object:IsDescendantOf(playerGui) then
        return false
    end
    local current = object
    while current and current ~= playerGui do
        if current:IsA("GuiObject") and not current.Visible then
            return false
        end
        if current:IsA("ScreenGui") and not current.Enabled then
            return false
        end
        current = current.Parent
    end
    return true
end
local function readRound()
    local app = playerGui:FindFirstChild("MinigameInGameApp")
    local title = follow(app, { "Body", "Middle", "Container", "TitleLabel" })
    local timer = follow(app, { "Body", "Left", "Container", "ValueLabel" })
    local score = follow(app, { "Body", "Right", "Container", "ValueLabel" })
    local hasUI = title ~= nil and title:IsA("TextLabel") and visible(title)
    local isGhost = hasUI and title.Text == "GHOST GALLERY"
    local remaining = 0
    local timerText = "--:--"
    if isGhost and timer and timer:IsA("TextLabel") and visible(timer) then
        timerText = timer.Text
        local minutes, seconds = timerText:match("^%s*(%d+):(%d+)%s*$")
        local m = tonumber(minutes or "")
        local s = tonumber(seconds or "")
        if m ~= nil and s ~= nil then
            remaining = m * 60 + s
        end
    end
    local scoreText = "--"
    if isGhost and score and score:IsA("TextLabel") and visible(score) then
        scoreText = score.Text
    end
    return { active = isGhost and remaining > 0, hasUI = hasUI,
        isGhost = isGhost, timer = timerText, score = scoreText }
end
local function queued()
    local hint = follow(playerGui, { "HintApp", "TextLabel" })
    if not hint or not hint:IsA("TextLabel") or not visible(hint) then
        return false
    end
    local text = hint.Text:lower()
    return text:find("queue", 1, true) ~= nil and text:find("ghost gallery", 1, true) ~= nil
end
local function showingRewards()
    local app = playerGui:FindFirstChild("MinigameRewardsApp")
    if not app then
        return false
    end
    if app:IsA("GuiObject") then
        return visible(app)
    end
    for _, child in ipairs(app:GetChildren()) do
        if child:IsA("GuiObject") and visible(child) then
            return true
        end
    end
    return false
end

-- The panel is created directly in PlayerGui and survives character respawns.
local colors = {
    background = Color3.fromRGB(24, 26, 34),
    card = Color3.fromRGB(36, 39, 50),
    text = Color3.fromRGB(239, 241, 247),
    muted = Color3.fromRGB(164, 171, 189),
    accent = Color3.fromRGB(177, 149, 255),
    green = Color3.fromRGB(113, 219, 172),
    orange = Color3.fromRGB(255, 190, 115),
}
local function make(className, properties, parent)
    local object = Instance.new(className)
    for name, value in pairs(properties) do
        object[name] = value
    end
    object.Parent = parent
    return object
end
local function roundCorners(parent, pixels)
    make("UICorner", { CornerRadius = UDim.new(0, pixels) }, parent)
end
local screen = make("ScreenGui", {
    Name = "GhostGalleryPanel", ResetOnSpawn = false,
    IgnoreGuiInset = true, DisplayOrder = 1000,
    ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
}, playerGui)
local panel = make("Frame", {
    Name = "Panel", Position = UDim2.fromOffset(16, 160),
    Size = UDim2.fromOffset(280, 296), BackgroundColor3 = colors.background,
    BorderSizePixel = 0, Active = true,
}, screen)
roundCorners(panel, 12)
make("UIStroke", { Color = Color3.fromRGB(64, 67, 85), Thickness = 1 }, panel)
local scale = make("UIScale", { Scale = 1 }, panel)
local function label(text, x, y, width, height, color, size)
    return make("TextLabel", {
        BackgroundTransparency = 1, Position = UDim2.fromOffset(x, y),
        Size = UDim2.fromOffset(width, height), Text = text,
        TextColor3 = color or colors.text, TextSize = size or 14,
        Font = Enum.Font.Gotham, TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center, TextTruncate = Enum.TextTruncate.AtEnd,
    }, panel)
end
local header = label("Halloween Farm", 16, 8, 208, 34, colors.accent, 17)
header.Font = Enum.Font.GothamBold
header.Active = true
local function button(text, x, y, width, height, color)
    local object = make("TextButton", {
        Position = UDim2.fromOffset(x, y), Size = UDim2.fromOffset(width, height),
        BackgroundColor3 = color or colors.card, BorderSizePixel = 0,
        Text = text, TextColor3 = colors.text, TextSize = 13,
        Font = Enum.Font.GothamMedium, AutoButtonColor = true,
    }, panel)
    roundCorners(object, 7)
    return object
end
local closeButton = button("X", 240, 12, 28, 28)
local farmButton = button("Ghost Gallery  OFF", 16, 53, 248, 36)
local statusLabel = label("Ready", 16, 99, 248, 24, colors.green, 15)
statusLabel.Font = Enum.Font.GothamBold
local detailLabel = label("Enter the Manor, then enable Ghost Gallery.", 16, 129, 248, 34, colors.muted, 12)
detailLabel.TextWrapped = true
detailLabel.TextTruncate = Enum.TextTruncate.None
detailLabel.TextYAlignment = Enum.TextYAlignment.Top
local timerLabel = label("Time  --:--", 16, 170, 110, 22, colors.text, 13)
local scoreLabel = label("Score  --", 137, 170, 127, 22, colors.text, 13)
local heldLabel = label("Click held  0.0s", 16, 193, 128, 20, colors.muted, 11)
local targetCountLabel = label("Targets  0", 156, 193, 108, 20, colors.muted, 11)
-- Use a distinct name so this table cannot be confused with Roblox's settings().
local farmOptions = { join = true, move = true, blast = true, background = virtualClient ~= nil,
    furniture = true, camera = true, sweep = true, continuous = true,
    nativeFocused = true, recoverInput = true, rewards = true, popups = true }
local targetLabel = label("Target  --", 16, 217, 248, 20, colors.muted, 11)
local captureButton = button("Capture details", 16, 242, 248, 26)
local note = label("v0.14  /  End stops  /  Right Shift hides", 16, 274, 248, 17, colors.muted, 10)
note.TextWrapped = true
note.TextTruncate = Enum.TextTruncate.None
local showButton = make("TextButton", {
    Position = UDim2.fromOffset(16, 160), Size = UDim2.fromOffset(144, 32),
    BackgroundColor3 = colors.background, BorderSizePixel = 0,
    Text = "Halloween  /  Show", TextColor3 = colors.accent,
    Font = Enum.Font.GothamMedium, TextSize = 13, Visible = false,
}, screen)
roundCorners(showButton, 8)

local connections = {}
local controller = {}
local disposed = false
local state = "idle"
local status = "Ready"
local detail = "Enter the Manor, then enable Ghost Gallery."
local pressed = false
local pressedBackend = "hardware"
local virtualAim = Vector2.new(0, 0)
local pressedPosition = virtualAim
local lastPressAt = -math.huge
local nextInputCheckAt = 0
local nextBlastAt = 0
local inputRecoveries = 0
local lastInputRecovery = "--"
local observedButton: any = nil
local shotInputWatch: any = nil
local inputNotices = { duplicates = 0, last = "--" }
local interruption: { [string]: any } = { active = false, count = 0, since = nil,
    lastReason = "--", lastState = "--", lastDuration = 0 }
local autoUIClick: { [string]: any } = { attempts = 0, closed = 0, last = "--", pending = false }
local popupPolicy: { [string]: any } = { declined = 0, cashClosed = 0, last = "--", nextScanAt = 0 }
local countdownEnd = 0
local windowFocused = true
local dragging = false
local lookingAround = false
local zoomUntil = 0
local cameraResumeAt = 0
local cameraBlockedSince: any = nil
local cursorAimPosition: any = nil
local lastCursorAngle = 0
local lastActiveEvidence = {}
local lastProtectionEvidence = {}
local evidenceAt = -math.huge
local dragStart
local dragPosition
local suspended = false
local ownedCamera
local savedCameraCFrame
local currentName
local currentModel
local currentFurnitureBlasted = false
local furnitureAttemptAt: any = nil
local targetReadyAt = 0
local lastSelectionAt = -math.huge
local blockedSince
local aimMismatchSince
local aimStallLogged = false
local lastAimDX, lastAimDY = 0, 0
local captureSequence = 0
local lastCaptureAt = -math.huge
local cached = {}
local targetMetadata: { [Instance]: any } = {}
local visualHints = {}
local landingHints = {}
local targetCooldowns = {}
local furnitureShots = {}
local furniturePartVisits: { [Instance]: any } = {}
local bossPolicy: { [string]: any } = { smallLive = 0, matchedSmall = 0, largeLive = 0,
    shieldLive = 0, matchedShields = 0, shieldedLarge = 0, flagVerified = false,
    blocked = false, fallbackBlocked = false, clearSince = nil }
local bossProgressWatch: any = nil
local lastRuntimeError = "--"
local lastInputError = "--"
local retryNotBefore = 0
local runtimeFailures = {}
local discovery = { released = 0, petFound = 0, hints = 0, sweep = 0 }
local refreshedAt = -math.huge
local heldSeconds = 0
local seen = {}
local seenCount = 0
local lastRound = false
local lastDisplayedScore = "--"
local roundStartScore = "--"
local joinNotBefore = 0
local lastQueueMoveAt = -math.huge
local lastUIUpdate = 0
local lastRenderAt = -math.huge
local lastAutomationAt = -math.huge
local latestRound = readRound()
-- Navigation stores temporary fields with several different Roblox value types.
local nav: { [string]: any } = { epoch = 0, lastRequest = -math.huge, index = 1 }

local function connect(signal, callback)
    local connection = signal:Connect(callback)
    connections[#connections + 1] = connection
    return connection
end
local function setStatus(message, explanation)
    status = message
    detail = explanation or ""
end
local function inputBackend()
    if windowFocused then
        if farmOptions.nativeFocused and canBlast then return "hardware" end
        if virtualClient then return "virtual" end
        return canBlast and "hardware" or nil
    end
    -- Hardware mouse calls are never a background fallback.
    return farmOptions.background and virtualClient and "virtual" or nil
end
local function sendButton(value, backend)
    if backend == "virtual" then
        if not virtualClient then error("Client-only input is unavailable.") end
        local ok, err = pcall(function()
            virtualClient:SendMouseButton(value and virtualAim or pressedPosition,
                Enum.UserInputType.MouseButton1, value, 0)
        end)
        if not ok then
            local message = tostring(err)
            if message:find("VirtualInput", 1, true)
                and message:lower():find("duplicate button state", 1, true) then
                -- The virtual object's state can outlive the engine focus state.
                -- This exact error means the requested state is already set.
                inputNotices.duplicates = inputNotices.duplicates + 1
                inputNotices.last = value and "Virtual button was already down" or "Virtual button was already up"
                if inputNotices.duplicates == 1 then log("INPUT_STATE: " .. inputNotices.last .. "; reconciled.") end
            else error(err) end
        end
    else
        if value then
            if not windowFocused then error("Foreground click cancelled: Roblox is not focused.") end
            if windowActive then
                local ok, active = pcall(windowActive)
                if ok and not active then error("Foreground click cancelled: Roblox lost focus.") end
            end
        end
        local action = value and pressMouse or releaseMouse
        if type(action) ~= "function" then error("Required hardware input function is unavailable.") end
        action()
    end
end
local function setPressed(value, forcedBackend)
    local backend = value and (forcedBackend or inputBackend()) or pressedBackend
    if value and not backend then return false end
    if value and pressed and pressedBackend ~= backend then
        -- Release using the backend that owns the old hold before switching.
        setPressed(false)
    end
    if pressed == value then
        return true
    end
    if value then
        pressedBackend = backend
        pressedPosition = virtualAim
        pressed = true -- Cleanup sends mouse-up even if the down call throws.
        local ok, err = pcall(sendButton, true, pressedBackend)
        if not ok then
            error("Mouse-down failed (" .. pressedBackend .. "): " .. tostring(err))
        end
        lastPressAt = os.clock()
    else
        local ok, err = pcall(sendButton, false, pressedBackend)
        if not ok then
            -- Focus changes can already have released the virtual button.
            local checked, down = pcall(function()
                return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
            end)
            if pressedBackend ~= "virtual" or not checked or down then
                error("Mouse-up failed (" .. pressedBackend .. "): " .. tostring(err))
            end
        end
        pressed = false
    end
    return true
end
local function releaseInput()
    if not pressed then
        return
    end
    local ok, err = pcall(sendButton, false, pressedBackend)
    if ok then
        pressed = false
    else
        local checked, down = pcall(function()
            return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
        end)
        if pressedBackend == "virtual" and checked and not down then
            pressed = false
        else
            log("RELEASE_ERROR: " .. tostring(err))
        end
    end
end
local function recoverBlast(reason, now)
    setPressed(false)
    inputRecoveries = inputRecoveries + 1
    lastInputRecovery = reason
    -- A real up/down edge, across updates, replaces a lost or ignored press.
    nextBlastAt = now + 0.05
    nextInputCheckAt = now + CONFIG.InputRetrySeconds
end
local function ensureBlastHeld()
    local now = os.clock()
    if now < nextBlastAt then return false end
    if farmOptions.recoverInput and pressed and now >= nextInputCheckAt then
        nextInputCheckAt = now + CONFIG.InputCheckInterval
        local ok, down = pcall(function()
            return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
        end)
        if ok then observedButton = down else observedButton = nil end
        -- The query observes client button state, not a successful beam or damage.
        if ok and not down and now - lastPressAt >= CONFIG.InputSettleSeconds then
            recoverBlast("Engine button was released while the farm requested a hold", now)
            return false
        end
    end
    return setPressed(true)
end
local function changeWindowFocus(value)
    if windowFocused == value then return end
    if autoUIClick.pending and autoUIClick.cancel then autoUIClick.cancel(true) else releaseInput() end
    windowFocused = value
    dragging, lookingAround = false, false
    observedButton, shotInputWatch = nil, nil
    nextInputCheckAt = 0
    nextBlastAt = os.clock() + CONFIG.FocusInputDelay
end
local function retryInactiveShot(metadata, now)
    if not farmOptions.recoverInput or not metadata or metadata.kind ~= "ghost"
        or not metadata.liveModel or not metadata.liveModel.Parent then return true end
    local attrs = metadata.liveModel:GetAttributes()
    local progress = attrs.GhostClustersProgress
    if type(attrs.GhostClustersBeingVacuumed) ~= "boolean" and type(progress) ~= "number" then return true end
    if not shotInputWatch or shotInputWatch.model ~= metadata.liveModel then
        shotInputWatch = { model = metadata.liveModel, progress = progress, since = now, retries = 0 }
    end
    local watch = shotInputWatch
    -- Replicated target activity can include other players. It prevents needless
    -- retries but is not counted as proof that this player's beam is attached.
    if attrs.GhostClustersBeingVacuumed == true or attrs.GhostClustersVacuumLocked == true
        or (type(progress) == "number" and progress ~= watch.progress) then
        watch.progress, watch.since, watch.retries = progress, now, 0
    elseif now - watch.since >= CONFIG.ShotRetrySeconds and watch.retries < CONFIG.ShotRetryLimit then
        watch.retries, watch.since = watch.retries + 1, now
        recoverBlast("Aligned ghost has no observed vacuum activity; retrying the press", now)
        return false
    end
    return true
end
local function restoreCamera()
    if ownedCamera and Workspace.CurrentCamera == ownedCamera and savedCameraCFrame then
        pcall(function()
            ownedCamera.CFrame = savedCameraCFrame
        end)
    end
    ownedCamera, savedCameraCFrame = nil, nil
end
local function clearPath()
    if nav.blockedConnection then
        nav.blockedConnection:Disconnect()
        nav.blockedConnection = nil
    end
    if nav.path then
        nav.path:Destroy()
        nav.path = nil
    end
    nav.waypoints, nav.goal, nav.sourcePoint = nil, nil, nil
    nav.index, nav.jumpIndex = 1, nil
end
local function cancelNavigation()
    nav.engaged = nil
    if nav.pending or nav.path or nav.humanoid then
        nav.epoch = nav.epoch + 1
        nav.pending = nil
        clearPath()
        if nav.humanoid and nav.humanoid.Parent then
            pcall(function()
                nav.humanoid:Move(Vector3.new(0, 0, 0), false)
            end)
        end
        nav.humanoid = nil
        nav.lastRequest = -math.huge
    end
end
local function releaseControls(keepCamera, keepBlast)
    if autoUIClick.pending and autoUIClick.cancel then autoUIClick.cancel(true) end
    if not keepBlast then releaseInput() end
    cancelNavigation()
    if not keepCamera then restoreCamera() end
    aimMismatchSince, aimStallLogged = nil, false
end
local function clearTarget()
    currentName, currentModel, blockedSince = nil, nil, nil
    currentFurnitureBlasted = false
    furnitureAttemptAt = nil
    shotInputWatch = nil
    interruption.active, interruption.since = false, nil
    bossProgressWatch = nil
    cameraBlockedSince = nil
    cancelNavigation()
end
local function characterInterruption(root, humanoid)
    local ok, humanoidState = pcall(function() return humanoid:GetState() end)
    local stateName = ok and tostring(humanoidState) or "unavailable"
    if root.Anchored then return "Character temporarily anchored", stateName end
    if humanoid.PlatformStand then return "Character platform standing", stateName end
    if humanoid.Sit then return "Character temporarily seated", stateName end
    if ok and (humanoidState == Enum.HumanoidStateType.FallingDown
        or humanoidState == Enum.HumanoidStateType.Ragdoll
        or humanoidState == Enum.HumanoidStateType.GettingUp
        or humanoidState == Enum.HumanoidStateType.Physics
        or humanoidState == Enum.HumanoidStateType.PlatformStanding) then
        return "Character knocked down or recovering", stateName
    end
    local velocity = root.AssemblyLinearVelocity
    if typeof(velocity) == "Vector3" then
        local horizontal = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
        if horizontal > math.max(CONFIG.KnockbackHorizontalSpeed, (humanoid.WalkSpeed or 16) * 2.5) then
            return "Character moving at knockback speed", stateName
        end
    end
    return nil, stateName
end
local function handleCharacterInterruption(root, humanoid, now)
    local reason, humanoidState = characterInterruption(root, humanoid)
    if reason then
        if not interruption.active then
            interruption.active, interruption.since = true, now
            interruption.count = interruption.count + 1
            releaseControls(true)
            nav.failedAt, nav.progressAt, nav.routeStartedAt, nav.lastPosition = nil, nil, nil, nil
            bossProgressWatch, shotInputWatch = nil, nil
            log("CHARACTER_INTERRUPTED: " .. reason .. "; retaining the target.")
        end
        interruption.lastReason, interruption.lastState = reason, humanoidState
        setStatus("Recovering from hit", "Farming stays enabled. A fresh blast starts when your character recovers.")
        return true
    end
    if interruption.active then
        local duration = now - (interruption.since or now)
        interruption.active, interruption.since, interruption.lastDuration = false, nil, duration
        if furnitureAttemptAt then furnitureAttemptAt = furnitureAttemptAt + duration end
        releaseControls(true)
        bossProgressWatch, shotInputWatch = nil, nil
        nav.failedAt, nav.progressAt, nav.routeStartedAt, nav.lastPosition = nil, nil, nil, nil
        blockedSince, cameraBlockedSince = nil, nil
        nextBlastAt = now + CONFIG.CharacterRecoveryDelay
        nextInputCheckAt, refreshedAt = 0, -math.huge
        targetReadyAt = now + CONFIG.CharacterRecoveryDelay
        inputRecoveries = inputRecoveries + 1
        lastInputRecovery = "Character recovered; restarting the held blast"
        log("CHARACTER_RECOVERED: refreshing aim and blast automatically.")
    end
    return false
end
local function report(reason)
    log(string.format("%s | heldSeconds=%.2f | targetsSeen=%d | displayedScore=%s",
        reason, heldSeconds, seenCount, lastDisplayedScore))
end
local function pause(reason)
    if disposed then
        return
    end
    state = "paused"
    suspended = false
    releaseControls()
    setStatus("Paused", reason or "Click Resume to continue.")
    report("PAUSE: " .. tostring(reason or "panel"))
end
local function stop(reason)
    if disposed then
        return
    end
    state = "idle"
    suspended = false
    releaseControls()
    clearTarget()
    setStatus("Stopped", "Enable Ghost Gallery when you are ready.")
    report("STOP: " .. tostring(reason or "panel"))
end
local function unload(reason)
    if disposed then
        return
    end
    stop(reason or "unloaded")
    disposed = true
    RunService:UnbindFromRenderStep(BINDING)
    for _, connection in ipairs(connections) do
        connection:Disconnect()
    end
    if environment[ENV_KEY] == controller then
        environment[ENV_KEY] = nil
    end
    screen:Destroy()
    -- A second attempt is useful if the runner briefly rejected mouse-up.
    releaseInput()
end
local function start()
    if disposed or state == "running" or state == "countdown" then
        return
    end
    retryNotBefore, runtimeFailures = 0, {}
    if farmOptions.background and not virtualClient then
        setStatus("Background unavailable", "This client cannot create client-only input.")
        log("BACKGROUND_UNAVAILABLE: " .. virtualUnavailable)
        return
    end
    if farmOptions.blast and not (virtualClient or canBlast) then
        setStatus("Blast unavailable", "Missing mouse1press, mouse1release or mousemoverel.")
        log("Start blocked: required mouse functions are missing.")
        return
    end
    if state == "idle" then
        heldSeconds, seenCount = 0, 0
        seen = {}
        lastDisplayedScore = "--"
        lastRound = false
    end
    releaseControls()
    clearTarget()
    state = "countdown"
    countdownEnd = os.clock() + CONFIG.StartDelay
    setStatus("Starting in 5s", "Close overlays and move the pointer off the panel.")
    log("READY: starts in 5 seconds. Close the executor and F9; move the pointer off the panel.")
end
controller.Start, controller.Stop, controller.Pause, controller.Unload = start, stop, pause, unload
controller.GetState = function() return state end
controller.Options = farmOptions
environment[ENV_KEY] = controller

local function pointIn(object, position)
    if not screen.Enabled or not object.Visible then
        return false
    end
    local top = object.AbsolutePosition
    local size = object.AbsoluteSize
    return position.X >= top.X and position.Y >= top.Y
        and position.X <= top.X + size.X and position.Y <= top.Y + size.Y
end
local function overPanel(position)
    return pointIn(panel, position) or pointIn(showButton, position)
end
local function setPanelVisible(value)
    panel.Visible = value
    showButton.Visible = not value
end
-- Optional programmatic settings remain available for diagnostics. The UI only
-- needs one farming toggle; its defaults already enable every supported step.
controller.SetOption = function(key, value)
    if farmOptions[key] == nil or type(value) ~= "boolean" then return false end
    releaseControls()
    if key == "background" and value and not virtualClient then return false end
    farmOptions[key] = value
    if key == "furniture" or key == "sweep" then
        clearTarget()
        visualHints, landingHints, furnitureShots, furniturePartVisits = {}, {}, {}, {}
        refreshedAt = -math.huge
    end
    return true
end
connect(farmButton.Activated, function()
    if state == "running" or state == "countdown" then stop("Ghost Gallery disabled")
    else start() end
end)
connect(closeButton.Activated, function() unload("X button") end)
connect(showButton.Activated, function() setPanelVisible(true) end)
connect(header.InputBegan, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = true
        dragStart = UserInputService:GetMouseLocation()
        dragPosition = panel.Position
        releaseControls(true)
    end
end)
connect(UserInputService.InputChanged, function(input)
    if input.UserInputType == Enum.UserInputType.MouseWheel then
        zoomUntil = os.clock() + 0.35
        if not farmOptions.continuous then releaseInput() end
    end
    if dragging and dragStart and dragPosition and input.UserInputType == Enum.UserInputType.MouseMovement then
        local delta = UserInputService:GetMouseLocation() - dragStart
        panel.Position = UDim2.new(dragPosition.X.Scale, dragPosition.X.Offset + delta.X,
            dragPosition.Y.Scale, dragPosition.Y.Offset + delta.Y)
    end
end)
connect(UserInputService.InputEnded, function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1 then
        dragging = false
    elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
        lookingAround = false
        cameraResumeAt = os.clock() + 0.35
    end
end)
local movementKeys = {
    [Enum.KeyCode.W] = true, [Enum.KeyCode.A] = true,
    [Enum.KeyCode.S] = true, [Enum.KeyCode.D] = true,
    [Enum.KeyCode.Up] = true, [Enum.KeyCode.Down] = true,
    [Enum.KeyCode.Left] = true, [Enum.KeyCode.Right] = true,
    [Enum.KeyCode.Space] = true,
}
connect(UserInputService.InputBegan, function(input, processed)
    if input.KeyCode == Enum.KeyCode.End then
        stop("End key")
    elseif input.KeyCode == Enum.KeyCode.RightShift and not UserInputService:GetFocusedTextBox() then
        setPanelVisible(not panel.Visible)
    elseif (state == "running" or state == "countdown") and input.KeyCode == Enum.KeyCode.F9 then
        pause("F9 pressed. Close the console before resuming.")
    elseif state == "running" and not processed and movementKeys[input.KeyCode] then
        pause("Manual movement. Click Resume to continue.")
    elseif (state == "running" or state == "countdown") and input.UserInputType == Enum.UserInputType.MouseButton2 then
        lookingAround = true
        if not farmOptions.continuous then releaseInput() end
        -- Never restore an old saved view over the user's deliberate camera move.
        ownedCamera, savedCameraCFrame = nil, nil
    end
end)
connect(UserInputService.WindowFocusReleased, function()
    changeWindowFocus(false)
    if not farmOptions.background and (state == "running" or state == "countdown") then
        pause("Roblox lost focus. Click Resume after returning.")
    end
end)
connect(UserInputService.WindowFocused, function()
    changeWindowFocus(true)
end)
connect(player.CharacterRemoving, function()
    releaseControls()
    clearTarget()
end)
connect(screen.AncestryChanged, function()
    if not disposed and not screen:IsDescendantOf(playerGui) then
        unload("panel removed")
    end
end)

-- Released ghosts retain their exact live/visual name. Furniture uses its unique
-- minigame group path, so duplicate SmallGhost/MediumGhost names never collapse.
local function boundsOf(model)
    if not model or not model.Parent then return nil end
    local ok, frame, size = pcall(function() return model:GetBoundingBox() end)
    if ok then return frame, size end
    return nil
end
local function targetPosition(model)
    if not model or not model.Parent then
        return nil
    end
    local metadata = targetMetadata[model]
    if metadata and metadata.kind == "furniture" then
        if metadata.focusPart and metadata.focusPart:IsDescendantOf(model) then
            return metadata.focusPart.Position
        end
        if metadata.focusObject and metadata.focusObject:IsA("Model") then
            local focusBounds = boundsOf(metadata.focusObject)
            if focusBounds then return focusBounds.Position end
        end
        local bounds = boundsOf(model)
        if bounds then return bounds.Position end
    end
    local ok, result = pcall(function() return model:GetPivot().Position end)
    return ok and result or nil
end
local function furnitureParts(model)
    local parts, floorY = {}, nil
    for _, object in ipairs(model:GetDescendants()) do
        if object:IsA("BasePart") then
            if object.Name == "PlacementBlock" then floorY = object.Position.Y end
            local helper = object.Name:lower():find("placementblock", 1, true)
            local parent = object.Parent
            while parent and parent ~= model do
                if parent.Name == "UseBlocks" then helper = true; break end
                parent = parent.Parent
            end
            if not helper and object.CanQuery and object.Transparency < 0.95 then
                parts[#parts + 1] = object
            end
        end
    end
    return parts, floorY
end
local function nearestFurniturePart(position, parts)
    local best, bestDistance
    for _, part in ipairs(parts) do
        local localPoint = part.CFrame:PointToObjectSpace(position)
        local size = part.Size
        local closest = Vector3.new(math.clamp(localPoint.X, -size.X * 0.5, size.X * 0.5),
            math.clamp(localPoint.Y, -size.Y * 0.5, size.Y * 0.5),
            math.clamp(localPoint.Z, -size.Z * 0.5, size.Z * 0.5))
        local distance = (localPoint - closest).Magnitude
        if not bestDistance or distance < bestDistance then best, bestDistance = part, distance end
    end
    return best, bestDistance
end
local function minigameFurniture()
    local entries = {}
    local container = follow(Workspace, { "HouseInteriors", "furniture" })
    if not container then return entries end
    for _, group in ipairs(container:GetChildren()) do
        if group.Name:find("ManorMinigameInterior::", 1, true) then
            local model = group:IsA("Model") and group or group:FindFirstChildOfClass("Model")
            local bounds, size = boundsOf(model)
            if bounds then
                local parts, floorY = furnitureParts(model)
                entries[#entries + 1] = { group = group, model = model, bounds = bounds, size = size,
                    parts = parts, floorY = floorY or (bounds.Position.Y - size.Y * 0.5),
                    key = "Furniture::" .. group.Name }
            end
        end
    end
    return entries
end
local function nearbyFurniture(position, entries)
    local best, bestPart, bestDistance
    for _, entry in ipairs(entries) do
        if (entry.bounds.Position - position).Magnitude <= CONFIG.HintCenterDistance then
            local part, distance = nearestFurniturePart(position, entry.parts)
            if part and distance <= CONFIG.HintSurfaceDistance and (not bestDistance or distance < bestDistance) then
                best, bestPart, bestDistance = entry, part, distance
            end
        end
    end
    return best, bestPart
end
local function largeGhost(model)
    return model and model.Name:lower():sub(1, 12) == "ghost_large_"
end
local function refreshTargets(now)
    if now - refreshedAt < CONFIG.RefreshSeconds then
        return
    end
    refreshedAt = now
    local nextCache = {}
    local nextMetadata: { [Instance]: any } = {}
    local counts = { released = 0, petFound = 0, hints = 0, sweep = 0 }
    local live = Workspace:FindFirstChild("GhostClustersLive")
    local visuals = Workspace:FindFirstChild("GhostClustersVisuals")
    local names = {}
    if live then
        for _, object in ipairs(live:GetDescendants()) do
            if object:IsA("Model") and object.Name:sub(1, 6):lower() == "ghost_" then
                names[object.Name] = object
            end
        end
    end
    local smallLive, largeLive, shieldLive, shieldedLarge, explicitLarge = 0, 0, 0, 0, 0
    for _, object in pairs(names) do
        local attrs = object:GetAttributes()
        if largeGhost(object) then
            largeLive = largeLive + 1
            if type(attrs.GhostClustersShielded) == "boolean" then explicitLarge = explicitLarge + 1 end
            if attrs.GhostClustersShielded == true then shieldedLarge = shieldedLarge + 1 end
        else
            smallLive = smallLive + 1
            if attrs.GhostClustersIsShield == true then shieldLive = shieldLive + 1 end
        end
    end
    bossPolicy.smallLive, bossPolicy.largeLive = smallLive, largeLive
    if largeLive > 0 and smallLive == 0 then
        bossPolicy.clearSince = bossPolicy.clearSince or now
    else
        bossPolicy.clearSince = nil
    end
    bossPolicy.shieldLive, bossPolicy.shieldedLarge = shieldLive, shieldedLarge
    bossPolicy.flagVerified = largeLive > 0 and explicitLarge == largeLive
    -- Explicit false is actionable immediately, even if ordinary ghosts remain.
    -- Only bosses missing the captured field use the old spawn-wait fallback.
    bossPolicy.fallbackBlocked = smallLive > 0 or (largeLive > 0
        and now - (bossPolicy.clearSince or now) < CONFIG.BossClearDelay)
    bossPolicy.blocked = shieldedLarge > 0 or (explicitLarge < largeLive and bossPolicy.fallbackBlocked)
    local furniture = farmOptions.furniture and minigameFurniture() or {}
    local furnitureByKey = {}
    for _, entry in ipairs(furniture) do furnitureByKey[entry.key] = entry end
    local function addFurniture(entry, evidence, source, focusPart, focusObject)
        if nextCache[entry.key] then return end
        local previous = targetMetadata[entry.model]
        nextCache[entry.key] = entry.model
        nextMetadata[entry.model] = { kind = "furniture", label = entry.model.Name,
            evidence = evidence, source = source, focusPart = focusPart, focusObject = focusObject,
            parts = entry.parts, floorY = entry.floorY, key = entry.key,
            lockedPart = previous and previous.focusPart == focusPart and previous.focusObject == focusObject
                and previous.lockedPart or nil }
        if evidence == "pet marker" then counts.petFound = counts.petFound + 1
        elseif evidence == "furniture sweep" then counts.sweep = counts.sweep + 1
        else counts.hints = counts.hints + 1 end
    end
    for _, entry in ipairs(furniture) do
        for _, object in ipairs(entry.model:GetDescendants()) do
            if object:IsA("Highlight") and object.Name == "GhostClustersPetFind" and object.Enabled then
                local focusPart
                local adornee = object.Adornee
                local focusObject
                if adornee and (adornee == entry.model or adornee:IsDescendantOf(entry.model)) then
                    focusObject = adornee
                elseif object.Parent:IsA("Model") then focusObject = object.Parent end
                if adornee and adornee:IsA("BasePart") and adornee:IsDescendantOf(entry.model) then
                    focusPart = adornee
                end
                addFurniture(entry, "pet marker", object, focusPart, focusObject)
                break
            end
        end
    end
    local nextHints = {}
    if visuals then
        for _, object in ipairs(visuals:GetDescendants()) do
            if object:IsA("Model") and names[object.Name] then
                local existing = nextCache[object.Name]
                if not existing or object == currentModel then
                    nextCache[object.Name] = object
                    local attrs = names[object.Name]:GetAttributes()
                    nextMetadata[object] = { kind = "ghost", label = object.Name, evidence = "live match",
                        isLarge = largeGhost(object), liveModel = names[object.Name],
                        shielded = attrs.GhostClustersShielded,
                        shieldKnown = type(attrs.GhostClustersShielded) == "boolean",
                        isShield = attrs.GhostClustersIsShield == true }
                end
            elseif farmOptions.furniture and object:IsA("Model")
                and (object.Name == "SmallGhost" or object.Name == "MediumGhost") then
                local bounds = boundsOf(object)
                local position = bounds and bounds.Position
                if position then
                    nextHints[object] = { position = position, lastSeen = now }
                end
            end
        end
    end
    -- The recording shows incoming visuals flying past and disappearing. Do not
    -- chase them mid-flight. Remember only a disappearance close to furniture,
    -- and expire that candidate rather than treating it as confirmed possession.
    for object, history in pairs(visualHints) do
        if not nextHints[object] and now - history.lastSeen <= CONFIG.HintObservationWindow then
            local entry, part = nearbyFurniture(history.position, furniture)
            if entry then landingHints[entry.key] = { expiresAt = now + CONFIG.LandingLifetime, focusPart = part } end
        end
    end
    for key, hint in pairs(landingHints) do
        local entry = furnitureByKey[key]
        local releasedNearby = false
        if entry then
            for _, model in pairs(nextCache) do
                if nextMetadata[model].kind == "ghost" then
                    local position = targetPosition(model)
                    if position and (position - entry.bounds.Position).Magnitude <= 12 then
                        releasedNearby = true
                        break
                    end
                end
            end
        end
        if not entry or now >= hint.expiresAt or releasedNearby then
            landingHints[key] = nil
            furnitureShots[key] = nil
        else
            addFurniture(entry, "visual landing (inferred)", nil, hint.focusPart)
        end
    end
    if farmOptions.sweep then
        local character = player.Character
        local root = character and character:FindFirstChild("HumanoidRootPart")
        for _, entry in ipairs(furniture) do
            if not nextCache[entry.key] then
                local chosen, visit, distance
                for _, part in ipairs(entry.parts) do
                    local lastVisit = furniturePartVisits[part] or -math.huge
                    local partDistance = (part.Position - (root and root.Position or entry.bounds.Position)).Magnitude
                    if not chosen or lastVisit < visit or (lastVisit == visit and partDistance < distance) then
                        chosen, visit, distance = part, lastVisit, partDistance
                    end
                end
                -- Preserve a running attempt's component across discovery refreshes.
                local previous = targetMetadata[entry.model]
                if entry.key == currentName and previous and previous.evidence == "furniture sweep"
                    and previous.focusPart and previous.focusPart:IsDescendantOf(entry.model) then chosen = previous.focusPart end
                if chosen then addFurniture(entry, "furniture sweep", nil, chosen) end
            end
        end
    end
    bossPolicy.matchedSmall, bossPolicy.matchedShields = 0, 0
    for _, model in pairs(nextCache) do
        if nextMetadata[model].kind == "ghost" then
            counts.released = counts.released + 1
            if not nextMetadata[model].isLarge then bossPolicy.matchedSmall = bossPolicy.matchedSmall + 1 end
            if nextMetadata[model].isShield then bossPolicy.matchedShields = bossPolicy.matchedShields + 1 end
        end
    end
    targetMetadata, visualHints, discovery = nextMetadata, nextHints, counts
    cached = nextCache
end
local function rayParameters(character, camera, includeVisuals)
    local params = RaycastParams.new()
    params.FilterType = Enum.RaycastFilterType.Exclude
    local excluded = { character }
    if camera then excluded[#excluded + 1] = camera end
    local live = Workspace:FindFirstChild("GhostClustersLive")
    if live then excluded[#excluded + 1] = live end
    if includeVisuals then
        local visuals = Workspace:FindFirstChild("GhostClustersVisuals")
        if visuals then excluded[#excluded + 1] = visuals end
    end
    params.FilterDescendantsInstances = excluded
    return params
end
local function clearLine(origin, point, model, character, camera, requiredPart)
    local direction = point - origin
    if direction.Magnitude < 0.1 then
        return true
    end
    local params = rayParameters(character, camera, false)
    for _ = 1, 5 do
        local hit = Workspace:Raycast(origin, direction, params)
        local metadata = targetMetadata[model]
        local source = metadata and metadata.source
        if not hit or (hit.Instance:IsDescendantOf(model) and (not requiredPart or hit.Instance == requiredPart))
            or (not requiredPart and source and source:IsA("Model") and hit.Instance:IsDescendantOf(source)) then
            return true
        end
        local part = hit.Instance
        if part:IsA("BasePart") and not part.CanCollide and part.Transparency >= 0.95 then
            local excluded = params.FilterDescendantsInstances
            excluded[#excluded + 1] = part
            params.FilterDescendantsInstances = excluded
        else
            return false
        end
    end
    return false
end
local function aimPoint(model, root, camera, character, characterOnly)
    local pivot = targetPosition(model)
    if not pivot then
        return nil, false
    end
    local metadata = targetMetadata[model]
    local shotOrigin = characterOnly and (root.Position + Vector3.new(0, 1.5, 0)) or camera.CFrame.Position
    if metadata and metadata.kind == "furniture" then
        -- A combined furniture bounding box can contain empty space between chairs.
        -- Cast through visible parts first, then check the actual hit from both origins.
        local parts = {}
        for _, part in ipairs(metadata.parts or {}) do
            local focused = not metadata.focusPart and not metadata.focusObject
                or part == metadata.focusPart
                or (not metadata.focusPart and metadata.focusObject
                    and (part == metadata.focusObject or part:IsDescendantOf(metadata.focusObject)))
            if focused and part:IsDescendantOf(model) then parts[#parts + 1] = part end
        end
        table.sort(parts, function(a, b)
            if (a == metadata.lockedPart) ~= (b == metadata.lockedPart) then return a == metadata.lockedPart end
            if (a == metadata.focusPart) ~= (b == metadata.focusPart) then return a == metadata.focusPart end
            local focus = metadata.focusObject
            local aFocused = focus and (a == focus or a:IsDescendantOf(focus)) or false
            local bFocused = focus and (b == focus or b:IsDescendantOf(focus)) or false
            if aFocused ~= bFocused then return aFocused end
            return (a.Position - root.Position).Magnitude < (b.Position - root.Position).Magnitude
        end)
        local include = RaycastParams.new()
        include.FilterType = Enum.RaycastFilterType.Include
        include.FilterDescendantsInstances = parts
        for index, part in ipairs(parts) do
            if index > 12 then break end
            local origin = shotOrigin
            local direction = part.Position - origin
            if direction.Magnitude > 0.1 then
                local hit = Workspace:Raycast(origin, direction.Unit * (direction.Magnitude + part.Size.Magnitude + 2), include)
                if hit and hit.Instance:IsDescendantOf(model) then
                    local point = hit.Position + direction.Unit * 0.03
                    if clearLine(root.Position + Vector3.new(0, 1.5, 0), point, model, character, camera, hit.Instance)
                        and (characterOnly or clearLine(origin, point, model, character, camera, hit.Instance)) then
                        metadata.lockedPart = hit.Instance
                        return point, true
                    end
                end
            end
        end
        local fallbackPart = metadata.lockedPart and metadata.lockedPart.Parent and metadata.lockedPart
            or metadata.focusPart and metadata.focusPart.Parent and metadata.focusPart
        return fallbackPart and fallbackPart.Position or pivot, false
    end
    local points = {}
    if metadata and metadata.kind == "furniture" and metadata.source then
        if metadata.source:IsA("Model") then
            local sourceBounds = boundsOf(metadata.source)
            if sourceBounds then points[#points + 1] = sourceBounds.Position end
        end
    end
    points[#points + 1] = pivot
    local ok, bounds, size = pcall(function() return model:GetBoundingBox() end)
    if ok then
        points[#points + 1] = bounds.Position
        points[#points + 1] = bounds.Position + Vector3.new(0, math.min(size.Y * 0.25, 1.8), 0)
    end
    local origin = root.Position + Vector3.new(0, 1.5, 0)
    for _, point in ipairs(points) do
        if clearLine(origin, point, model, character, camera)
            and (characterOnly or clearLine(camera.CFrame.Position, point, model, character, camera)) then
            return point, true
        end
    end
    return pivot, false
end
local function chooseTarget(root, camera, character, now)
    local humanoid = character:FindFirstChildOfClass("Humanoid")
    local playerFloor = root.Position.Y - root.Size.Y * 0.5 - humanoid.HipHeight
    local function candidateFor(name, model)
        local metadata = model and targetMetadata[model]
        local position = targetPosition(model)
        if not metadata or not position or now < (targetCooldowns[name] or 0)
            or (metadata.isLarge and (metadata.shielded == true
                or (not metadata.shieldKnown and bossPolicy.fallbackBlocked))) then return nil end
        local followPoint, clear = aimPoint(model, root, camera, character, true)
        local distance = ((metadata.kind == "furniture" and followPoint or position) - root.Position).Magnitude
        if distance > CONFIG.SearchRadius then return nil end
        local sameFloor = metadata.kind ~= "furniture" or math.abs(metadata.floorY - playerFloor) <= CONFIG.FloorTolerance
        local confidenceCost = metadata.kind == "furniture" and metadata.evidence ~= "pet marker" and 8 or 0
        return { name = name, model = model, distance = distance, clear = clear,
            sameFloor = sameFloor, kind = metadata.kind, isShield = metadata.isShield,
            cost = distance + confidenceCost + (sameFloor and 0 or 80) + (clear and 0 or 25) }
    end
    local current = currentName and candidateFor(currentName, cached[currentName])
    -- Shielded bosses are removed from selection even between selection ticks.
    -- Continuous mode keeps input held as the aim moves to the next valid target.
    if not current then
        currentModel = nil
        if not farmOptions.continuous then setPressed(false) end
    else currentModel = current.model end
    if now - lastSelectionAt < 0.25 and current then return end
    lastSelectionAt = now
    local candidates = {}
    for name, candidate in pairs(cached) do
        local entry = candidateFor(name, candidate)
        if entry then candidates[#candidates + 1] = entry end
    end
    table.sort(candidates, function(a, b)
        if (a.isShield == true) ~= (b.isShield == true) then return a.isShield == true end
        if a.cost ~= b.cost then return a.cost < b.cost end
        return a.name < b.name
    end)
    local best = candidates[1]
    if current and best then
        local releasedHere = best.isShield == true and current.isShield ~= true
        if not releasedHere and current.kind == "furniture" and currentFurnitureBlasted then
            local furniturePoint = targetPosition(current.model)
            for _, candidate in ipairs(candidates) do
                if candidate.kind == "ghost" and not targetMetadata[candidate.model].isLarge
                    and (targetPosition(candidate.model) - furniturePoint).Magnitude <= 12 then
                    best, releasedHere = candidate, true
                    break
                end
            end
        end
        -- Finish one attempt before reconsidering distance. A released ghost at
        -- the furniture can continue that attempt; unrelated spawns cannot interrupt.
        if not releasedHere then best = current end
    end
    local name = best and best.name or nil
    if name ~= currentName then
        if not farmOptions.continuous then setPressed(false) end
        cancelNavigation()
        currentName = name
        currentFurnitureBlasted = false
        furnitureAttemptAt = nil
        blockedSince = nil
        cameraBlockedSince = nil
        bossProgressWatch = nil
        shotInputWatch = nil
        nav.failedAt, nav.progressAt, nav.routeStartedAt = nil, nil, nil
        targetReadyAt = now + 0.12
        if name then
            if not seen[name] then
                seen[name] = true
                seenCount = seenCount + 1
                log("TARGET: " .. name:gsub("[%c]", " "):sub(1, 100))
                local metadata = targetMetadata[best.model]
                if metadata.kind == "furniture" then
                    log("FURNITURE_TARGET: " .. metadata.label .. " | evidence=" .. metadata.evidence)
                end
            end
        end
    end
    currentModel = best and best.model or nil
end

-- Navigation uses floor positions and path waypoints, not the floating ghost Y.
local function standingPoints(point, root, humanoid, model, character, camera)
    local offset = Vector3.new(root.Position.X - point.X, 0, root.Position.Z - point.Z)
    local direction = offset.Magnitude > 0.1 and offset.Unit or Vector3.new(1, 0, 0)
    local points = {}
    local floorParams = rayParameters(character, camera, true)
    floorParams.RespectCanCollide = true
    local furniture = follow(Workspace, { "HouseInteriors", "furniture" })
    if furniture then
        local excluded = floorParams.FilterDescendantsInstances
        excluded[#excluded + 1] = furniture
        floorParams.FilterDescendantsInstances = excluded
    end
    local metadata = targetMetadata[model]
    local isFurniture = metadata and metadata.kind == "furniture"
    local playerFloor = root.Position.Y - root.Size.Y * 0.5 - humanoid.HipHeight
    local desiredFloor = isFurniture and metadata.floorY or playerFloor
    local normalGhost = not isFurniture and not model.Name:find("Ghost_Large_", 1, true)
    local castTop = normalGhost and math.max(point.Y + 6, desiredFloor + 8) or (desiredFloor + 8)
    local radii = isFurniture and { CONFIG.FurnitureFollowDistance, 10, 12 } or { CONFIG.FollowDistance }
    for _, radius in ipairs(radii) do
      for _, angle in ipairs({ 0, math.pi / 3, -math.pi / 3, 2 * math.pi / 3, -2 * math.pi / 3, math.pi }) do
        local rotated = Vector3.new(direction.X * math.cos(angle) - direction.Z * math.sin(angle),
            0, direction.X * math.sin(angle) + direction.Z * math.cos(angle))
        local proposal = point + rotated * radius
        local hit = Workspace:Raycast(Vector3.new(proposal.X, castTop, proposal.Z),
            Vector3.new(0, -48, 0), floorParams)
        if hit and hit.Normal.Y > 0.45
            and (not isFurniture or math.abs(hit.Position.Y - desiredFloor) <= CONFIG.FloorTolerance) then
            local rootHeight = root.Size.Y * 0.5 + humanoid.HipHeight
            local candidateRoot = hit.Position + Vector3.new(0, rootHeight, 0)
            local clear = clearLine(candidateRoot + Vector3.new(0, 1.5, 0), point, model, character, camera)
            local cameraOffset = camera.CFrame.Position - root.Position
            local cameraClear = not farmOptions.camera or clearLine(candidateRoot + cameraOffset, point, model, character, camera)
            points[#points + 1] = { position = hit.Position + Vector3.new(0, 0.1, 0),
                cost = (hit.Position - root.Position).Magnitude + (clear and 0 or 80)
                    + (cameraClear and 0 or 40)
                    + (isFurniture and math.abs(radius - CONFIG.FurnitureFollowDistance) * 3 or 0)
                    + math.abs(hit.Position.Y - desiredFloor) * 3 }
        end
      end
    end
    table.sort(points, function(a, b) return a.cost < b.cost end)
    return points
end
local function requestPath(point, root, humanoid, model, camera, now)
    if nav.pending or now - nav.lastRequest < 1.2 then return end
    if nav.path and nav.sourcePoint and (point - nav.sourcePoint).Magnitude < 6
        and now - (nav.progressAt or now) < 2.5 then return end
    if humanoid.FloorMaterial == Enum.Material.Air then return end
    nav.lastRequest = now
    nav.epoch = nav.epoch + 1
    local token = nav.epoch
    nav.pending = token
    local name = currentName
    local character = root.Parent
    task.spawn(function()
        local foundPath, foundWaypoints, goal
        local ok, err = xpcall(function()
            local choices = standingPoints(point, root, humanoid, model, character, camera)
            for index, choice in ipairs(choices) do
                if index > 3 or disposed or nav.epoch ~= token then break end
                local path = PathfindingService:CreatePath({
                    AgentRadius = 2, AgentHeight = 5, AgentCanJump = true, WaypointSpacing = 4,
                })
                local computed = pcall(function() path:ComputeAsync(root.Position, choice.position) end)
                if computed and path.Status == Enum.PathStatus.Success then
                    local waypoints = path:GetWaypoints()
                    if #waypoints > 0 then
                        foundPath, foundWaypoints, goal = path, waypoints, choice.position
                        break
                    end
                end
                path:Destroy()
            end
        end, function(value) return tostring(value) end)
        if nav.pending == token then nav.pending = nil end
        if disposed or nav.epoch ~= token or state ~= "running" or suspended
            or currentName ~= name or player.Character ~= character or not latestRound.active then
            if foundPath then foundPath:Destroy() end
            return
        end
        if not ok then
            if foundPath then foundPath:Destroy() end
            nav.failedAt = nav.failedAt or os.clock()
            log("PATH_ERROR: " .. tostring(err))
            return
        end
        clearPath()
        nav.sourcePoint = point
        nav.humanoid = humanoid
        if not foundPath then
            nav.failedAt = nav.failedAt or os.clock()
            return
        end
        nav.failedAt = nil
        nav.path, nav.waypoints, nav.goal = foundPath, foundWaypoints, goal
        nav.index = #foundWaypoints > 1 and 2 or 1
        nav.progressAt = os.clock()
        nav.lastPosition = root.Position
        nav.blockedConnection = foundPath.Blocked:Connect(function(index)
            if nav.path == foundPath and index >= nav.index then
                clearPath()
                nav.lastRequest = -math.huge
            end
        end)
    end)
end
local function navigate(point, root, humanoid, model, camera, now)
    nav.humanoid = humanoid
    nav.routeStartedAt = nav.routeStartedAt or now
    requestPath(point, root, humanoid, model, camera, now)
    if nav.lastPosition and (root.Position - nav.lastPosition).Magnitude > 1 then
        nav.lastPosition = root.Position
        nav.progressAt = now
    end
    if nav.progressAt and now - nav.progressAt > 2.5 and nav.path then
        clearPath()
    end
    local waypoint = nav.waypoints and nav.waypoints[nav.index]
    while waypoint do
        local difference = waypoint.Position - root.Position
        local flat = Vector3.new(difference.X, 0, difference.Z)
        if flat.Magnitude > 2.3 or math.abs(difference.Y) > 6 then break end
        nav.index = nav.index + 1
        nav.progressAt = now
        waypoint = nav.waypoints[nav.index]
    end
    if not waypoint then
        humanoid:Move(Vector3.new(0, 0, 0), false)
        if nav.path then clearPath() end
        return false
    end
    if waypoint.Action == Enum.PathWaypointAction.Jump and nav.jumpIndex ~= nav.index then
        nav.jumpIndex = nav.index
        humanoid.Jump = true
    end
    local difference = waypoint.Position - root.Position
    local flat = Vector3.new(difference.X, 0, difference.Z)
    humanoid:Move(flat.Magnitude > 0.1 and flat.Unit or Vector3.new(0, 0, 0), false)
    return true
end

local function guiText(object)
    if not object or not (object:IsA("TextLabel") or object:IsA("TextButton")) then return "" end
    return object.Text:gsub("<[^>]*>", ""):gsub("&nbsp;", " "):lower():gsub("%s+", " "):match("^%s*(.-)%s*$")
end
local function buttonLabels(button)
    local labels = {}
    local function add(object)
        if visible(object) then
            local text = guiText(object)
            if text ~= "" then labels[text] = true end
        end
    end
    add(button)
    for _, object in ipairs(button:GetDescendants()) do add(object) end
    -- Unlabelled image close/decline controls need an explicit semantic name.
    if next(labels) == nil then
        local name = button.Name:lower():gsub("[%s_]", "")
        if name == "nobutton" or name == "no" then labels.no = true end
        if name == "closebutton" or name == "close" then labels.close = true end
        if name == "cashoutbutton" or name == "cashout" then labels["cash out"] = true end
    end
    return labels
end
local function popupAppCandidate(app)
    local name = app.Name:lower()
    return app ~= screen and (name:find("dialog", 1, true) or name:find("popup", 1, true)
        or name:find("notification", 1, true) or name:find("confirm", 1, true)
        or name:find("paycheck", 1, true) or name:find("cash", 1, true) or name:find("bonus", 1, true)
        or name:find("money", 1, true) or name:find("bucks", 1, true) or name:find("reward", 1, true))
end
local function popupKind(text, app)
    if text:find("ghost gallery", 1, true) and text:find("starting soon", 1, true)
        and text:find("teleport", 1, true) then return "teleport" end
    if text:find("cash bonus", 1, true) or text:find("bucks bonus", 1, true)
        or text:find("bonus bucks", 1, true) then return "cash" end
    local name = app.Name:lower()
    if name:find("paycheck", 1, true) or name == "cashoutapp" or text:find("bank of adopt me", 1, true)
        or text == "paycheck" or (text:find("bucks", 1, true)
            and (text:find("you earned", 1, true) or text:find("you've earned", 1, true))) then
        return "paycheck"
    end
    return nil
end
local function popupButton(message, app, kind)
    local container = message.Parent
    while container and container ~= playerGui do
        local chosen, chosenRank, ambiguous = nil, math.huge, false
        local purchase = false
        for _, object in ipairs(container:GetDescendants()) do
            if object:IsA("GuiButton") and visible(object) then
                local labels = buttonLabels(object)
                local rank = math.huge
                if labels.no then rank = 1 end
                if kind ~= "teleport" then
                    if labels.close or labels.x or labels["×"] or labels.cancel then rank = math.min(rank, 2) end
                    if labels["not now"] or labels.later then rank = math.min(rank, 3) end
                    if labels.ok or labels.okay or labels["got it"] or labels.nice then rank = math.min(rank, 4) end
                    if kind == "paycheck" and labels["cash out"] then rank = math.min(rank, 5) end
                    for labelText in pairs(labels) do
                        if labelText:find("buy", 1, true) or labelText:find("purchase", 1, true)
                            or labelText:find("robux", 1, true) then purchase = true end
                    end
                end
                if rank < chosenRank then chosen, chosenRank, ambiguous = object, rank, false
                elseif rank ~= math.huge and rank == chosenRank then ambiguous = true end
            end
        end
        if chosen then
            -- Declining/closing remains safe; never acknowledge a purchase offer as a bonus.
            if ambiguous or (purchase and chosenRank >= 4) then return nil, container end
            return chosen, container
        end
        -- Keep the message and action inside one dialog; do not cross into sibling dialogs.
        if container == app or container.Parent == app then return nil, container end
        container = container.Parent
    end
    return nil, app
end
local function popupMessageMatches(descriptor)
    if not visible(descriptor.message) then return false end
    if descriptor.markerLabel then return buttonLabels(descriptor.message)[descriptor.markerLabel] == true end
    return guiText(descriptor.message) == descriptor.text
end
local function scanPopups(now)
    local cachedPopup = popupPolicy.cached
    if cachedPopup and popupMessageMatches(cachedPopup) then
        local button, container = popupButton(cachedPopup.message, cachedPopup.app, cachedPopup.kind)
        cachedPopup.button, cachedPopup.container = button, container
        return cachedPopup
    end
    popupPolicy.cached = nil
    if now < popupPolicy.nextScanAt then return nil end
    popupPolicy.nextScanAt = now + CONFIG.PopupRefreshSeconds
    local selected
    for _, app in ipairs(playerGui:GetChildren()) do
        -- The invitation's exact message is sufficient even if its app name changes.
        if app ~= screen and not app.Name:lower():find("chat", 1, true) then
            for _, object in ipairs(app:GetDescendants()) do
                if visible(object) and (object:IsA("TextLabel") or object:IsA("TextButton")) then
                    local insideButton, ancestor = false, object.Parent
                    while ancestor and ancestor ~= app do
                        if ancestor:IsA("GuiButton") then insideButton = true; break end
                        ancestor = ancestor.Parent
                    end
                    local text = guiText(object)
                    local kind = not insideButton and text ~= "" and popupKind(text, app) or nil
                    if kind ~= "teleport" and not popupAppCandidate(app) then kind = nil end
                    if kind then
                        local button, container = popupButton(object, app, kind)
                        local candidate = { kind = kind, message = object, text = text, app = app,
                            button = button, container = container, action = kind == "teleport" and "No" or "Dismiss" }
                        if not selected or (kind == "teleport" and selected.kind ~= "teleport")
                            or (kind == selected.kind and button and not selected.button) then selected = candidate end
                    end
                end
            end
            local appName = app.Name:lower()
            if (not selected or (selected.kind ~= "teleport" and not selected.button))
                and (appName == "cashoutapp" or appName:find("paycheck", 1, true)) then
                for _, object in ipairs(app:GetDescendants()) do
                    if object:IsA("GuiButton") and visible(object) and buttonLabels(object)["cash out"] then
                        local button, container = popupButton(object, app, "paycheck")
                        if button then
                            selected = { kind = "paycheck", message = object, text = "cash out", markerLabel = "cash out",
                                app = app, button = button, container = container, action = "Cash Out" }
                            break
                        end
                    end
                end
            end
        end
    end
    popupPolicy.cached = selected
    return selected
end
local function restoreUICursor()
    local saved = autoUIClick.cursor
    if saved then
        if autoUIClick.backend == "virtual" and virtualClient then
            pcall(function()
                local current = windowFocused and UserInputService:GetMouseLocation() or nil
                local restore = current and autoUIClick.position and (current - autoUIClick.position).Magnitude > 3
                    and current or saved
                virtualClient:SendMousePosition(restore)
            end)
        elseif autoUIClick.backend == "hardware" and windowFocused and moveMouse then
            local active = true
            if windowActive then
                local checked, value = pcall(windowActive)
                active = checked and value == true
            end
            local mouse = UserInputService:GetMouseLocation()
            -- Do not move over a user's mouse movement during the short click.
            if active and autoUIClick.position and (mouse - autoUIClick.position).Magnitude <= 3 then
                pcall(moveMouse, saved.X - mouse.X, saved.Y - mouse.Y)
            end
        end
    end
    autoUIClick.cursor = nil
end
autoUIClick.cancel = function(abort)
    -- A stopped farm or changed dialog must not complete an old GUI click.
    if abort and autoUIClick.pending then
        local safe = Vector2.new(0, 0)
        if autoUIClick.backend == "virtual" then
            pressedPosition = safe
            pcall(function() virtualClient:SendMousePosition(safe) end)
        elseif autoUIClick.backend == "hardware" and windowFocused and moveMouse then
            local active = true
            if windowActive then
                local checked, value = pcall(windowActive)
                active = checked and value == true
            end
            local mouse = UserInputService:GetMouseLocation()
            if active and autoUIClick.position and (mouse - autoUIClick.position).Magnitude <= 3 then
                pcall(moveMouse, -mouse.X, -mouse.Y)
                autoUIClick.position = safe
            end
        end
    end
    releaseInput()
    restoreUICursor()
    if autoUIClick.pending and not abort then autoUIClick.completed = (autoUIClick.completed or 0) + 1 end
    autoUIClick.pending = false
end
local function uiStillShown(descriptor)
    if descriptor.kind == "nice" then return showingRewards() end
    return popupMessageMatches(descriptor)
end
local function dismissAutoUI(now, round)
    local previous = autoUIClick.descriptor
    if previous and not uiStillShown(previous) then
        if autoUIClick.pending then autoUIClick.cancel(true) end
        if previous.kind == "nice" then
            autoUIClick.closed = autoUIClick.closed + 1
            autoUIClick.last = "Results screen closed"
        elseif (autoUIClick.completed or 0) > 0 then
            if previous.kind == "teleport" then popupPolicy.declined = popupPolicy.declined + 1
            else popupPolicy.cashClosed = popupPolicy.cashClosed + 1 end
            popupPolicy.last = previous.kind .. " popup closed after " .. previous.action
        end
        autoUIClick.descriptor, autoUIClick.seenAt = nil, nil
        autoUIClick.attempts, autoUIClick.completed, autoUIClick.nextAt = 0, 0, nil
        popupPolicy.nextScanAt = 0
    end
    local descriptor = farmOptions.popups and scanPopups(now) or nil
    if not descriptor and farmOptions.rewards and not round.active
        and not (round.hasUI and not round.isGhost) and showingRewards() then
        descriptor = { kind = "nice", action = "Nice", button = follow(playerGui, { "MinigameRewardsApp", "Body", "Button" }) }
    end
    if not descriptor then
        if autoUIClick.pending then autoUIClick.cancel(true) end
        if autoUIClick.pauseAt then
            -- A modal consumes neither a furniture attempt nor an input-recovery budget.
            if furnitureAttemptAt then furnitureAttemptAt = now end
            nav.failedAt, nav.progressAt, nav.routeStartedAt, nav.lastPosition = nil, nil, nil, nil
            blockedSince, cameraBlockedSince, bossProgressWatch, shotInputWatch = nil, nil, nil, nil
            nextBlastAt, targetReadyAt = now + CONFIG.FocusInputDelay, now + CONFIG.FocusInputDelay
            refreshedAt, nextInputCheckAt, autoUIClick.pauseAt = -math.huge, 0, nil
        end
        autoUIClick.descriptor, autoUIClick.seenAt = nil, nil
        autoUIClick.attempts, autoUIClick.completed, autoUIClick.nextAt = 0, 0, nil
        return false
    end
    local same = previous and previous.kind == descriptor.kind and previous.message == descriptor.message
        and previous.text == descriptor.text and previous.button == descriptor.button
    if not same then
        if autoUIClick.pending then autoUIClick.cancel(true) end
        releaseControls(true)
        autoUIClick.seenAt, autoUIClick.attempts, autoUIClick.completed, autoUIClick.nextAt = now, 0, 0, nil
    end
    autoUIClick.descriptor = descriptor
    autoUIClick.pauseAt = autoUIClick.pauseAt or now
    local closing = descriptor.kind == "nice" and "Closing results" or "Closing popup"
    local waiting = descriptor.kind == "nice" and "Results waiting" or "Popup waiting"
    local explanation = descriptor.kind == "nice" and "Clicking Nice, then continuing the queue."
        or descriptor.kind == "teleport" and "Declining the teleport invitation, then continuing the farm."
        or "Dismissing the cash reward, then continuing the farm."
    if dragging or UserInputService:GetFocusedTextBox() or GuiService.MenuIsOpen then
        if autoUIClick.pending then
            autoUIClick.cancel(true)
            autoUIClick.nextAt = now + CONFIG.RewardRetrySeconds
        end
        setStatus(waiting, "The popup will be dismissed when the menu or text box is closed.")
        return true
    end
    if autoUIClick.pending then
        if now >= autoUIClick.releaseAt then
            autoUIClick.cancel()
            autoUIClick.nextAt = now + CONFIG.RewardRetrySeconds
        end
        setStatus(closing, explanation)
        return true
    end
    if now - autoUIClick.seenAt < CONFIG.RewardSettleSeconds or now < (autoUIClick.nextAt or 0) then
        setStatus(closing, "Waiting for the popup button to finish appearing.")
        return true
    end
    local button = descriptor.button
    local camera = Workspace.CurrentCamera
    if not button or not button:IsA("GuiButton") or not button.Active or not visible(button) or not camera then
        popupPolicy.last = descriptor.kind .. " recognized; waiting for a labelled dismissal button"
        setStatus(waiting, "Waiting for the popup's dismissal button to become clickable.")
        return true
    end
    local size = button.AbsoluteSize
    local point = button.AbsolutePosition + size * 0.5
    if size.X <= 0 or size.Y <= 0 or point.X < 16 or point.Y < 64
        or point.X > camera.ViewportSize.X - 16 or point.Y > camera.ViewportSize.Y - 16 or overPanel(point) then
        setStatus(waiting, "The popup button is still appearing or covered by the farm panel.")
        return true
    end
    for _, object in ipairs(playerGui:GetGuiObjectsAtPosition(math.floor(point.X), math.floor(point.Y))) do
        if object:IsA("GuiButton") and object.Active and visible(object) and object ~= button
            and not object:IsDescendantOf(button) then
            setStatus(waiting, "Another button is covering the popup. Retrying when it clears.")
            return true
        end
    end
    local backend = virtualClient and "virtual" or nil
    if windowFocused and canBlast and (not backend or autoUIClick.attempts >= 2) then backend = "hardware" end
    if not backend then
        setStatus(waiting, "Foreground input is needed to dismiss this popup on this client.")
        return true
    end
    releaseControls(true)
    autoUIClick.cursor = windowFocused and UserInputService:GetMouseLocation()
        or cursorAimPosition or camera.ViewportSize * 0.5
    autoUIClick.position, autoUIClick.backend, autoUIClick.button = point, backend, button
    virtualAim = point
    local ok, err = pcall(function()
        if backend == "virtual" then
            -- Normalize the virtual object's old state, then create a fresh GUI click.
            sendButton(false, "virtual")
            virtualClient:SendMousePosition(point)
        else
            moveMouse(point.X - autoUIClick.cursor.X, point.Y - autoUIClick.cursor.Y)
        end
        setPressed(true, backend)
    end)
    autoUIClick.attempts = autoUIClick.attempts + 1
    if not ok then
        releaseInput()
        restoreUICursor()
        lastInputError = tostring(err)
        autoUIClick.last = descriptor.action .. " click rejected: " .. tostring(err)
        autoUIClick.nextAt = now + CONFIG.RewardRetrySeconds
        setStatus(waiting, "Retrying the popup button automatically.")
        return true
    end
    autoUIClick.pending, autoUIClick.releaseAt = true, now + CONFIG.RewardClickSeconds
    autoUIClick.last = descriptor.action .. " click sent using " .. backend
    if descriptor.kind ~= "nice" then popupPolicy.last = descriptor.kind .. ": " .. autoUIClick.last end
    setStatus(closing, explanation)
    return true
end
local function autoJoin(root, character, now, round)
    releaseControls()
    clearTarget()
    if round.hasUI then
        setStatus(round.isGhost and "Round ending" or "Waiting", "Waiting for the minigame screen to close.")
        return
    end
    if showingRewards() or now < joinNotBefore then
        setStatus("Between rounds", "Close any results screen, then wait for the queue.")
        return
    end
    if not farmOptions.join then
        setStatus("Waiting for a round", "Auto join is off. Join Ghost Gallery manually.")
        return
    end
    if queued() then
        setStatus("Queued", "Waiting for Ghost Gallery to start.")
        return
    end
    local marker = follow(Workspace, { "Interiors", "HauntedManor", "GhostClustersJoinZoneMarker" })
    if not marker or not marker:IsA("BasePart")
        or (marker.Position - root.Position).Magnitude > CONFIG.ManorDistance
        or math.abs(marker.Position.Y - root.Position.Y) > 40 then
        setStatus("Enter the Manor", "Auto join works from inside the Haunted Manor.")
        return
    end
    local destination = marker.Position + Vector3.new(0, 3, 0)
    if (root.Position - destination).Magnitude <= 5 then
        setStatus("At the queue", "Waiting for confirmation. Step into the circle if needed.")
        return
    end
    if now - lastQueueMoveAt < CONFIG.QueueRetrySeconds then
        setStatus("Joining", "Waiting for the queue to register.")
        return
    end
    lastQueueMoveAt = now
    character:PivotTo(CFrame.new(destination - root.Position) * character:GetPivot())
    root.AssemblyLinearVelocity = Vector3.new(0, 0, 0)
    root.AssemblyAngularVelocity = Vector3.new(0, 0, 0)
    setStatus("Joining", "Moved to the Ghost Gallery queue marker.")
    log("JOIN: moved to the loaded Manor queue marker; waiting for the queue hint.")
end
local function aimHitsButton(screenPoint)
    if overPanel(Vector2.new(screenPoint.X, screenPoint.Y)) then return true end
    local objects = playerGui:GetGuiObjectsAtPosition(math.floor(screenPoint.X), math.floor(screenPoint.Y))
    for _, object in ipairs(objects) do
        if object:IsA("GuiButton") and object.Active and visible(object) then return true end
    end
    return false
end
local function aimCameraUnderCursor(camera, point, deltaTime)
    local position = windowFocused and UserInputService:GetMouseLocation() or cursorAimPosition
    if not position then position = camera.ViewportSize * 0.5 end
    if position.X < 16 or position.Y < 64 or position.X > camera.ViewportSize.X - 16
        or position.Y > camera.ViewportSize.Y - 16 or aimHitsButton(position) then
        return nil, false, nil
    end
    cursorAimPosition = Vector2.new(position.X, position.Y)
    local ray = camera:ViewportPointToRay(position.X, position.Y)
    local localRay = camera.CFrame:VectorToObjectSpace(ray.Direction)
    local correction = CFrame.lookAt(Vector3.new(0, 0, 0), localRay)
    local desired = CFrame.lookAt(camera.CFrame.Position, point) * correction:Inverse()
    if ownedCamera ~= camera then
        restoreCamera()
        ownedCamera, savedCameraCFrame = camera, camera.CFrame
    end
    camera.CFrame = camera.CFrame:Lerp(desired, 1 - math.exp(-CONFIG.CameraTurnRate * deltaTime))
    ray = camera:ViewportPointToRay(position.X, position.Y)
    local difference = point - ray.Origin
    if difference.Magnitude < 0.01 then return cursorAimPosition, false, ray end
    lastCursorAngle = math.deg(math.acos(math.clamp(ray.Direction.Unit:Dot(difference.Unit), -1, 1)))
    return cursorAimPosition, lastCursorAngle <= CONFIG.CameraAimTolerance, ray
end
local function cursorHitsFurniture(ray, point, model, root, character, camera)
    local metadata = targetMetadata[model]
    if not ray or not metadata then return false end
    local include = RaycastParams.new()
    include.FilterType = Enum.RaycastFilterType.Include
    -- The aim point was selected from this part. Do not accept a different chair
    -- or a decorative part elsewhere in the same furniture assembly.
    include.FilterDescendantsInstances = metadata.lockedPart and { metadata.lockedPart } or {}
    local hit = Workspace:Raycast(ray.Origin, ray.Direction * ((point - ray.Origin).Magnitude + 8), include)
    return hit ~= nil and hit.Instance:IsDescendantOf(model)
        and (hit.Position - root.Position).Magnitude <= CONFIG.FurnitureAimDistance
        and clearLine(ray.Origin, hit.Position, model, character, camera, hit.Instance)
        and clearLine(root.Position + Vector3.new(0, 1.5, 0), hit.Position, model, character, camera, hit.Instance)
end
local function holdContinuousBlast(camera, deltaTime)
    local position = windowFocused and UserInputService:GetMouseLocation() or cursorAimPosition
    if not position then position = camera.ViewportSize * 0.5 end
    if position.X < 16 or position.Y < 64 or position.X > camera.ViewportSize.X - 16
        or position.Y > camera.ViewportSize.Y - 16 or aimHitsButton(position) then
        releaseInput()
        return false, "ui"
    end
    cursorAimPosition = Vector2.new(position.X, position.Y)
    virtualAim = cursorAimPosition
    if not ensureBlastHeld() then return false, "retry" end
    heldSeconds = heldSeconds + deltaTime
    return true
end
local function finishFurnitureAttempt(now, reason)
    local metadata = currentModel and targetMetadata[currentModel]
    local key = currentName
    if key then
        local sweep = metadata and metadata.evidence == "furniture sweep"
        targetCooldowns[key] = now + (sweep and CONFIG.FurnitureSweepCooldown or CONFIG.TargetCooldown)
        local part = metadata and (metadata.lockedPart or metadata.focusPart)
        if part then furniturePartVisits[part] = now end
        landingHints[key], furnitureShots[key] = nil, nil
    end
    releaseControls(true, farmOptions.continuous)
    clearTarget()
    refreshedAt = -math.huge
    setStatus("Trying another object", reason)
end
local function rememberActiveEvidence(now, round)
    if now - evidenceAt < 1 then return end
    evidenceAt = now
    local rows = { "" }
    local live = Workspace:FindFirstChild("GhostClustersLive")
    local models = {}
    if live then
        for _, object in ipairs(live:GetDescendants()) do
            if object:IsA("Model") and object.Name:lower():sub(1, 6) == "ghost_" then models[#models + 1] = object end
        end
    end
    table.sort(models, function(a, b)
        if largeGhost(a) ~= largeGhost(b) then return largeGhost(a) end
        return a.Name < b.Name
    end)
    local small, large, shields, protected, known = 0, 0, 0, 0, 0
    for _, model in ipairs(models) do
        local attrs = model:GetAttributes()
        if largeGhost(model) then
            large = large + 1
            if type(attrs.GhostClustersShielded) == "boolean" then known = known + 1 end
            if attrs.GhostClustersShielded == true then protected = protected + 1 end
        else
            small = small + 1
            if attrs.GhostClustersIsShield == true then shields = shields + 1 end
        end
    end
    local blocked = protected > 0 or (known < large and bossPolicy.fallbackBlocked)
    rows[1] = "ACTIVE_SAMPLE | time=" .. round.timer .. " | score=" .. round.score
        .. " | target=" .. tostring(currentName or "--") .. " | smallLive=" .. small
        .. " | largeLive=" .. large .. " | bossBlocked=" .. tostring(blocked)
        .. " | shieldLive=" .. shields .. " | shieldedLarge=" .. protected
        .. " | inputBackend=" .. tostring(inputBackend() or "unavailable")
        .. " | requestedHeld=" .. tostring(pressed)
        .. " | engineHeld=" .. (observedButton == nil and "unavailable" or tostring(observedButton))
        .. " | focused=" .. tostring(windowFocused) .. " | recoveries=" .. inputRecoveries
    for index, model in ipairs(models) do
        if index > 6 then break end
        local attrs, keys, values = model:GetAttributes(), {}, {}
        for key in pairs(attrs) do keys[#keys + 1] = key end
        table.sort(keys)
        for attributeIndex, key in ipairs(keys) do
            if attributeIndex > 32 then break end
            values[#values + 1] = tostring(key) .. "=" .. tostring(attrs[key]):gsub("[%c]", " "):sub(1, 100)
        end
        rows[#rows + 1] = "ACTIVE_LIVE_GHOST | " .. model.Name .. " | " .. table.concat(values, "; ")
    end
    lastActiveEvidence = rows
    if large > 0 and (shields > 0 or protected > 0 or (known < large and small > 0)) then lastProtectionEvidence = rows end
end
-- A bounded snapshot of game objects, never chat, inventory, module source or remotes.
-- Capturing a glowing furniture object gives us evidence for the missing opening step.
local function captureDetails()
    local now = os.clock()
    if disposed or now - lastCaptureAt < 2 then return end
    lastCaptureAt = now
    captureSequence = captureSequence + 1
    local heldAtCapture = pressed
    local backendAtCapture = pressed and pressedBackend or inputBackend()
    local observedOk, engineHeld = pcall(function()
        return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
    end)
    releaseControls(true)
    local rows = {}
    local function clean(value, limit)
        return tostring(value):gsub("[%c]", " "):sub(1, limit or 180)
    end
    local function add(value)
        if #rows < 160 then rows[#rows + 1] = "[GGDETAIL] " .. value end
    end
    local function positionText(position)
        return position and string.format("(%.1f,%.1f,%.1f)", position.X, position.Y, position.Z) or "--"
    end
    local function screenText(position)
        return position and string.format("(%.1f,%.1f)", position.X, position.Y) or "--"
    end
    local function describe(object)
        local values = {}
        local ok, attributes = pcall(function() return object:GetAttributes() end)
        if ok then
            local keys = {}
            for key in pairs(attributes) do keys[#keys + 1] = key end
            table.sort(keys)
            for index, key in ipairs(keys) do
                if index > 10 then break end
                values[#values + 1] = clean(key, 50) .. "=" .. clean(attributes[key], 100)
            end
        end
        local interesting = object:IsA("Model") or #values > 0
        if object:IsA("ValueBase") then
            local value = object.Value
            if type(value) == "boolean" or type(value) == "number" or type(value) == "string" then
                values[#values + 1] = "Value=" .. clean(value, 100)
                interesting = true
            end
        end
        if object:IsA("ParticleEmitter") or object:IsA("Beam") or object:IsA("Highlight")
            or object:IsA("BillboardGui") or object:IsA("Light") then
            interesting = true
            for _, property in ipairs({ "Enabled", "Color", "FillColor" }) do
                local readOK, value = pcall(function() return object[property] end)
                if readOK and value ~= nil then values[#values + 1] = property .. "=" .. clean(value, 90) end
            end
            if object:IsA("Highlight") and object.Adornee then
                values[#values + 1] = "Adornee=" .. clean(object.Adornee:GetFullName(), 200)
            end
        end
        if not interesting then return false end
        local position
        if object:IsA("Model") then
            local boundsOK, bounds = pcall(function() return object:GetBoundingBox() end)
            position = boundsOK and bounds.Position or targetPosition(object)
        elseif object:IsA("BasePart") then position = object.Position end
        add(clean(object:GetFullName(), 260) .. " | " .. object.ClassName
            .. " | position=" .. positionText(position) .. " | " .. table.concat(values, "; "))
        return true
    end
    local round = readRound()
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local camera = Workspace.CurrentCamera
    local mouse = UserInputService:GetMouseLocation()
    add("BEGIN v0.14 capture=" .. captureSequence .. " | status=" .. status .. " | state=" .. state
        .. " | time=" .. round.timer .. " | displayedScore=" .. round.score
        .. " | held=" .. tostring(heldAtCapture) .. " | heldSeconds=" .. string.format("%.1f", heldSeconds))
    add("INPUT | backend=" .. tostring(backendAtCapture or "unavailable")
        .. " | background=" .. tostring(farmOptions.background) .. " | focused=" .. tostring(windowFocused)
        .. " | autoTurnCamera=" .. tostring(farmOptions.camera)
        .. " | mouse=" .. screenText(mouse) .. " | aimError=" .. string.format("(%.1f,%.1f)", lastAimDX, lastAimDY)
        .. " | mouseBehavior=" .. clean(UserInputService.MouseBehavior, 60)
        .. " | viewport=" .. screenText(camera and camera.ViewportSize))
    add("INPUT_RECOVERY | nativeFocused=" .. tostring(farmOptions.nativeFocused)
        .. " | nativeAvailable=" .. tostring(canBlast) .. " | recoverInput=" .. tostring(farmOptions.recoverInput)
        .. " | requestedHeld=" .. tostring(heldAtCapture)
        .. " | engineHeld=" .. (observedOk and tostring(engineHeld) or "unavailable")
        .. " | recoveries=" .. inputRecoveries .. " | last=" .. clean(lastInputRecovery, 260))
    add("INPUT_STATE | duplicateStates=" .. inputNotices.duplicates .. " | last=" .. inputNotices.last)
    add("CHARACTER_INTERRUPT | active=" .. tostring(interruption.active) .. " | count=" .. interruption.count
        .. " | lastReason=" .. clean(interruption.lastReason, 140) .. " | lastState=" .. clean(interruption.lastState, 100)
        .. " | lastDuration=" .. string.format("%.2f", interruption.lastDuration))
    add("REWARD_UI | autoNice=" .. tostring(farmOptions.rewards) .. " | clickPending=" .. tostring(autoUIClick.pending)
        .. " | attempts=" .. autoUIClick.attempts .. " | closedScreens=" .. autoUIClick.closed
        .. " | last=" .. clean(autoUIClick.last, 260))
    add("POPUP_UI | autoDismiss=" .. tostring(farmOptions.popups)
        .. " | kind=" .. tostring(autoUIClick.descriptor and autoUIClick.descriptor.kind or "--")
        .. " | teleportDeclined=" .. popupPolicy.declined .. " | cashClosed=" .. popupPolicy.cashClosed
        .. " | last=" .. clean(popupPolicy.last, 260))
    if autoUIClick.descriptor and autoUIClick.descriptor.message then
        add("SELECTED_POPUP | " .. clean(autoUIClick.descriptor.message:GetFullName(), 260)
            .. " | text=" .. clean(autoUIClick.descriptor.text, 220)
            .. " | button=" .. clean(autoUIClick.descriptor.button and autoUIClick.descriptor.button:GetFullName() or "--", 260))
    end
    local popupRows = 0
    for _, app in ipairs(playerGui:GetChildren()) do
        if popupAppCandidate(app) then
            for _, object in ipairs(app:GetDescendants()) do
                if popupRows >= 28 then break end
                if visible(object) and (object:IsA("TextLabel") or object:IsA("GuiButton")) then
                    local text = guiText(object)
                    if object:IsA("GuiButton") then
                        local labels = {}
                        for labelText in pairs(buttonLabels(object)) do labels[#labels + 1] = labelText end
                        table.sort(labels)
                        text = table.concat(labels, " / ")
                    end
                    if text ~= "" or object:IsA("GuiButton") then
                        popupRows = popupRows + 1
                        add("POPUP_OBJECT | " .. clean(object:GetFullName(), 260) .. " | " .. object.ClassName
                            .. " | text=" .. clean(text, 220) .. " | position=" .. screenText(object.AbsolutePosition)
                            .. " | size=" .. screenText(object.AbsoluteSize))
                    end
                end
            end
        end
    end
    add("LAST_RUNTIME_ERROR | " .. clean(lastRuntimeError, 900))
    add("LAST_INPUT_ERROR | " .. clean(lastInputError, 400))
    add("CAMERA_INPUT | lookingAround=" .. tostring(lookingAround) .. " | zooming=" .. tostring(now < zoomUntil))
    add("CAMERA_AIM | cursorMovesInjected=" .. tostring(not farmOptions.camera)
        .. " | cursorAngle=" .. string.format("%.2f", lastCursorAngle)
        .. " | furnitureRange=" .. CONFIG.FurnitureAimDistance)
    for _, row in ipairs(lastActiveEvidence) do add("LAST_" .. row) end
    if lastProtectionEvidence ~= lastActiveEvidence then
        for _, row in ipairs(lastProtectionEvidence) do add("PROTECTION_" .. row) end
    end
    add("PLAYER | position=" .. positionText(root and root.Position) .. " | target=" .. clean(currentName or "--"))
    local selectedMetadata = currentModel and targetMetadata[currentModel]
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if selectedMetadata and selectedMetadata.kind == "furniture" and root and humanoid then
        add("FURNITURE_AIM | focusPart=" .. clean(selectedMetadata.focusPart and selectedMetadata.focusPart:GetFullName() or "--", 260)
            .. " | lockedPart=" .. clean(selectedMetadata.lockedPart and selectedMetadata.lockedPart:GetFullName() or "--", 260)
            .. " | focusObject=" .. clean(selectedMetadata.focusObject and selectedMetadata.focusObject:GetFullName() or "--", 260)
            .. " | queryableParts=" .. #(selectedMetadata.parts or {})
            .. " | targetFloorY=" .. string.format("%.1f", selectedMetadata.floorY)
            .. " | playerFloorY=" .. string.format("%.1f", root.Position.Y - root.Size.Y * 0.5 - humanoid.HipHeight)
            .. " | accumulatedBlast=" .. string.format("%.1f", furnitureShots[currentName] or 0))
    end
    add("HUNT | enabled=" .. tostring(farmOptions.furniture) .. " | released=" .. discovery.released
        .. " | petFound=" .. discovery.petFound .. " | inferredHints=" .. discovery.hints
        .. " | furnitureSweep=" .. tostring(farmOptions.sweep) .. " | sweepCandidates=" .. discovery.sweep
        .. " | continuousBlast=" .. tostring(farmOptions.continuous)
        .. " | selectedEvidence=" .. clean(selectedMetadata and selectedMetadata.evidence or "--"))
    add("FOLLOW | selection=character-space | navigation=character-space | shooting=screen-space")
    add("BOSS_POLICY | smallLive=" .. bossPolicy.smallLive .. " | matchedSmall=" .. bossPolicy.matchedSmall
        .. " | largeLive=" .. bossPolicy.largeLive .. " | blocked=" .. tostring(bossPolicy.blocked)
        .. " | shieldLive=" .. bossPolicy.shieldLive .. " | matchedShields=" .. bossPolicy.matchedShields
        .. " | shieldedLarge=" .. bossPolicy.shieldedLarge .. " | shieldFlagVerified=" .. tostring(bossPolicy.flagVerified)
        .. " | clearFor=" .. string.format("%.1f", bossPolicy.clearSince and now - bossPolicy.clearSince or 0))
    -- Capture authoritative live-model attributes early, before furniture rows
    -- consume the budget. This allows the real shield phase to be investigated.
    local live = Workspace:FindFirstChild("GhostClustersLive")
    local liveModels = {}
    if live then
        for _, object in ipairs(live:GetDescendants()) do
            if object:IsA("Model") and object.Name:lower():sub(1, 6) == "ghost_" then liveModels[#liveModels + 1] = object end
        end
    end
    table.sort(liveModels, function(a, b)
        if largeGhost(a) ~= largeGhost(b) then return largeGhost(a) end
        return a.Name < b.Name
    end)
    for index, object in ipairs(liveModels) do
        if index > 12 then break end
        local attributes, values, keys = object:GetAttributes(), {}, {}
        for key in pairs(attributes) do keys[#keys + 1] = key end
        table.sort(keys)
        for attributeIndex, key in ipairs(keys) do
            if attributeIndex > 32 then break end
            values[#values + 1] = clean(key, 60) .. "=" .. clean(attributes[key], 120)
        end
        add("LIVE_GHOST_STATE | " .. clean(object:GetFullName(), 240) .. " | " .. table.concat(values, "; "))
    end
    -- Names only: identify possible direction controllers without loading code,
    -- reading module source, or guessing which method the blaster uses.
    local clientModules = ReplicatedStorage:FindFirstChild("ClientModules")
    local controllerPaths = {}
    if clientModules then
        for _, object in ipairs(clientModules:GetDescendants()) do
            if object:IsA("ModuleScript") then
                local name = object.Name:lower()
                if name:find("ghost", 1, true) or name:find("vacuum", 1, true)
                    or name:find("blast", 1, true) or name == "minigameclientmanager"
                    or name == "minigameclient" then
                    controllerPaths[#controllerPaths + 1] = object:GetFullName()
                end
            end
        end
    end
    table.sort(controllerPaths)
    for index, path in ipairs(controllerPaths) do
        if index > 16 then break end
        add("CONTROLLER_MODULE | " .. clean(path, 260))
    end
    add("DIRECTION_CONTROL | identified=false | matchingModuleNames=" .. #controllerPaths)
    local uiShown = 0
    for _, app in ipairs(playerGui:GetChildren()) do
        local name = app.Name:lower()
        if app ~= screen and app.Name ~= "MinigameRewardsApp" and (name:find("ghost", 1, true) or name:find("minigame", 1, true)
            or name:find("boss", 1, true) or name:find("mural", 1, true)) then
            for _, object in ipairs(app:GetDescendants()) do
                if uiShown >= 24 then break end
                if visible(object) and (object:IsA("ImageLabel") or object:IsA("TextLabel")) then
                    uiShown = uiShown + 1
                    add("EVENT_UI_STATE | " .. clean(object:GetFullName(), 260) .. " | " .. object.ClassName
                        .. " | text=" .. clean(object:IsA("TextLabel") and object.Text or "", 100)
                        .. " | image=" .. clean(object:IsA("ImageLabel") and object.Image or "", 100)
                        .. " | size=" .. screenText(object.AbsoluteSize))
                end
            end
        end
    end
    local candidateShown = 0
    for key, model in pairs(cached) do
        local metadata = targetMetadata[model]
        if metadata.kind == "furniture" and candidateShown < 12 then
            candidateShown = candidateShown + 1
            add("FURNITURE_CANDIDATE | " .. clean(key, 180) .. " | evidence=" .. metadata.evidence
                .. " | position=" .. positionText(targetPosition(model)))
            if metadata.source then describe(metadata.source) end
        end
    end
    for _, name in ipairs({ "GhostClustersLive", "GhostClustersVisuals" }) do
        local container = Workspace:FindFirstChild(name)
        local count = 0
        if container then
            for index, object in ipairs(container:GetDescendants()) do
                if index > 2500 or count >= 32 then break end
                if object:IsA("Model") then describe(object); count = count + 1 end
            end
        end
        add(name .. " | modelsShown=" .. count .. " | loaded=" .. tostring(container ~= nil))
    end
    local furniture = follow(Workspace, { "HouseInteriors", "furniture" })
    local candidates = {}
    if furniture and root then
        for _, object in ipairs(furniture:GetChildren()) do
            if object.Name:find("ManorMinigameInterior::", 1, true) then
                local model = object:IsA("Model") and object or object:FindFirstChildOfClass("Model")
                local ok, bounds = pcall(function() return model:GetBoundingBox() end)
                local position = ok and bounds.Position or targetPosition(model)
                if position then
                    local marked = false
                    for _, item in ipairs(object:GetDescendants()) do
                        if item:IsA("Highlight") and item.Name == "GhostClustersPetFind" and item.Enabled then
                            marked = true
                            break
                        end
                    end
                    candidates[#candidates + 1] = { object = object, distance = (position - root.Position).Magnitude, marked = marked }
                end
            end
        end
        table.sort(candidates, function(a, b)
            if a.marked ~= b.marked then return a.marked end
            return a.distance < b.distance
        end)
        for index, entry in ipairs(candidates) do
            if index > 8 then break end
            add("FURNITURE | distance=" .. string.format("%.1f", entry.distance)
                .. " | group=" .. clean(entry.object.Name, 180))
            describe(entry.object)
            local shown = 0
            local children = entry.object:GetDescendants()
            table.sort(children, function(a, b)
                local aMarker = a.Name == "GhostClustersPetFind"
                local bMarker = b.Name == "GhostClustersPetFind"
                if aMarker ~= bMarker then return aMarker end
                local aModel, bModel = a:IsA("Model"), b:IsA("Model")
                if aModel ~= bModel then return aModel end
                return a:GetFullName() < b:GetFullName()
            end)
            for childIndex, object in ipairs(children) do
                if childIndex > 250 or shown >= 12 then break end
                if describe(object) then shown = shown + 1 end
            end
        end
    end
    add("FURNITURE | minigameGroups=" .. #candidates)
    -- Capture only buttons in event/minigame UI. This can identify the pet-find
    -- control without guessing a remote or injecting clicks at fixed screen coordinates.
    for _, app in ipairs(playerGui:GetChildren()) do
        local name = app.Name:lower()
        if app ~= screen and (name:find("ghost", 1, true) or name:find("minigame", 1, true)) then
            local shown = 0
            for _, object in ipairs(app:GetDescendants()) do
                if shown >= 16 then break end
                if object:IsA("GuiButton") and visible(object) then
                    shown = shown + 1
                    local text = object:IsA("TextButton") and clean(object.Text, 80) or ""
                    add("EVENT_BUTTON | " .. clean(object:GetFullName(), 240)
                        .. " | position=" .. screenText(object.AbsolutePosition)
                        .. " | size=" .. screenText(object.AbsoluteSize) .. " | text=" .. text)
                end
            end
        end
    end
    rows[#rows + 1] = "[GGDETAIL] END capture=" .. captureSequence
    local output = table.concat(rows, "\n")
    local clipboard = inputFunction("setclipboard", setclipboard) or inputFunction("toclipboard", toclipboard)
    local copied = clipboard and pcall(clipboard, output)
    if copied then
        log("DETAILS_COPIED: paste the capture into our chat. It includes game objects and input measurements.")
        setStatus("Details copied", "Paste the capture here so we can finish furniture detection.")
    else
        for _, row in ipairs(rows) do print(row) end
        log("DETAILS_READY: copy the [GGDETAIL] block from F9.")
        setStatus("Details in F9", "Copy the [GGDETAIL] block from the console.")
    end
end
controller.CaptureDetails = captureDetails
connect(captureButton.Activated, function()
    local ok, err = pcall(captureDetails)
    if not ok then log("CAPTURE_ERROR: " .. tostring(err)) end
end)
local function runFrame(deltaTime, now, round)
    if not farmOptions.background and not windowFocused then pause("Roblox lost focus."); return end
    if not farmOptions.background and windowActive then
        local ok, active = pcall(windowActive)
        if ok and not active then pause("Roblox is not focused."); return end
    end
    if UserInputService:GetFocusedTextBox() or GuiService.MenuIsOpen then
        pause("Close the text box or Roblox menu before resuming.")
        return
    end
    if dragging or (windowFocused and overPanel(UserInputService:GetMouseLocation())) then
        if not suspended then releaseControls(true) end
        suspended = true
        setStatus("Panel interaction", "Move the pointer off the panel to continue.")
        return
    end
    suspended = false
    local character = player.Character
    local root = character and character:FindFirstChild("HumanoidRootPart")
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local camera = Workspace.CurrentCamera
    if not root or not humanoid or humanoid.Health <= 0 or not camera then
        releaseControls()
        clearTarget()
        setStatus("Waiting for character", "Automation resumes when your character is ready.")
        return
    end
    if not round.active then
        if root.Anchored then
            releaseControls()
            clearTarget()
            setStatus("Waiting for character", "Automation resumes when your character is ready.")
            return
        end
        autoJoin(root, character, now, round)
        return
    end
    refreshTargets(now)
    if handleCharacterInterruption(root, humanoid, now) then
        rememberActiveEvidence(now, round)
        return
    end
    chooseTarget(root, camera, character, now)
    rememberActiveEvidence(now, round)
    if not currentModel then
        releaseControls(true)
        if bossPolicy.largeLive > 0 and bossPolicy.blocked then
            setStatus("Waiting for protection", bossPolicy.shieldedLarge > 0
                and "Boss shield is active. Waiting for a reachable protector or furniture target."
                or "Boss shield flag is unavailable. Waiting for the fallback protection check.")
        else
            setStatus(farmOptions.furniture and "Searching furniture" or "Waiting for ghosts",
                farmOptions.sweep and "Waiting for furniture to load or its sweep cooldown to end."
                or farmOptions.furniture and "Waiting for a pet marker or a furniture landing hint."
                or "Hunt furniture is off. Waiting for released ghosts.")
        end
        return
    end
    local followPoint, characterClear = aimPoint(currentModel, root, camera, character, true)
    local metadata = targetMetadata[currentModel]
    local isFurniture = metadata and metadata.kind == "furniture"
    if not followPoint then
        releaseControls()
        clearTarget()
        return
    end
    local distance = (followPoint - root.Position).Magnitude
    local playerFloor = root.Position.Y - root.Size.Y * 0.5 - humanoid.HipHeight
    local needsFloorRoute = isFurniture and math.abs(metadata.floorY - playerFloor) > CONFIG.FloorTolerance
    if needsFloorRoute then characterClear = false end
    if characterClear then blockedSince = nil else blockedSince = blockedSince or now end
    if farmOptions.camera and characterClear then
        local _, viewClear = aimPoint(currentModel, root, camera, character)
        if viewClear then cameraBlockedSince = nil else cameraBlockedSince = cameraBlockedSince or now end
    else cameraBlockedSince = nil end
    local needsCameraRoute = cameraBlockedSince and now - cameraBlockedSince >= CONFIG.CameraShotWait
    -- Once a clear shot is in range, keep some distance instead of walking under the ghost.
    local followThreshold = isFurniture and (nav.engaged and CONFIG.FurnitureFollowStop or CONFIG.FurnitureFollowStart)
        or (nav.engaged and CONFIG.FollowStop or CONFIG.FollowStart)
    local shotRange = isFurniture and CONFIG.FurnitureAimDistance or CONFIG.AimDistance
    local shouldMove = farmOptions.move and (distance > followThreshold or not characterClear or needsCameraRoute)
    local moving = false
    if shouldMove then
        nav.engaged = true
        moving = navigate(followPoint, root, humanoid, currentModel, camera, now)
        if (nav.failedAt and now - nav.failedAt > 2)
            or (nav.progressAt and now - nav.progressAt > 4)
            or (nav.routeStartedAt and now - nav.routeStartedAt > CONFIG.TargetRouteBudget) then
            targetCooldowns[currentName] = now + CONFIG.TargetCooldown
            releaseControls(true, farmOptions.continuous)
            clearTarget()
            setStatus("Trying another target", "The previous route was blocked. It will be retried later.")
            return
        end
    else
        cancelNavigation()
        nav.routeStartedAt, nav.progressAt, nav.lastPosition, nav.failedAt = nil, nil, nil, nil
    end
    if not farmOptions.blast then
        setPressed(false)
        restoreCamera()
        setStatus(moving and "Following target" or "Target selected", "Aim + hold blast is off.")
        return
    end
    if not (virtualClient or canBlast) then
        pause("Required input functions are unavailable.")
        return
    end
    if farmOptions.continuous then
        local held, reason = holdContinuousBlast(camera, deltaTime)
        if not held then
            setStatus(reason == "ui" and "Cursor over UI" or "Reapplying blast",
                reason == "ui" and "Move the cursor into the game area. Blasting resumes automatically."
                    or "Refreshing the click after a focus change or lost input.")
            return
        end
    end
    if isFurniture and distance <= shotRange and not needsFloorRoute then
        furnitureAttemptAt = furnitureAttemptAt or now
        if farmOptions.continuous then currentFurnitureBlasted = true end
        if now - furnitureAttemptAt >= CONFIG.FurnitureAttemptBudget then
            finishFurnitureAttempt(now, "This furniture attempt timed out. Sweeping the next item.")
            return
        end
    end
    if not characterClear or distance > shotRange then
        if not farmOptions.continuous then setPressed(false) end
        if nav.failedAt and now - nav.failedAt < 2 then
            setStatus("No path found", "Move closer, then click Resume if you pause.")
        elseif needsFloorRoute then
            setStatus("Going to another floor", "Following a floor path to the furniture.")
        elseif not characterClear then
            setStatus(moving and "Moving for a shot" or "Shot blocked",
                farmOptions.move and "Keeping the target while looking for a clear path." or "Turn Follow ghosts on, or move closer.")
        else
            setStatus(moving and "Approaching target" or "Target is far away", "Waiting until the target is closer.")
        end
        if not farmOptions.continuous then return end
    end
    if windowFocused and (lookingAround or now < zoomUntil or now < cameraResumeAt) then
        if not farmOptions.continuous then releaseInput() end
        setStatus("Farming enabled", farmOptions.continuous
            and "Blast stays held while you look around. Automatic aiming resumes after the gesture."
            or "Look around freely. Blasting resumes when the pointer is free.")
        return
    end
    -- Automatic camera aiming follows the pointer instead of moving it. The
    -- legacy camera-off path retains screen-position input for diagnostics.
    local point, cameraClear = aimPoint(currentModel, root, camera, character)
    local projected, onScreen = camera:WorldToViewportPoint(point)
    local cursorRay, pointer
    if farmOptions.camera then
        local aligned
        pointer, aligned, cursorRay = aimCameraUnderCursor(camera, point, deltaTime)
        if not pointer then
            setPressed(false)
            setStatus("Cursor over UI", "Move the cursor into the game area. Farming resumes automatically.")
            return
        end
        if not aligned then
            if not farmOptions.continuous then setPressed(false) end
            setStatus("Aligning camera", "Keeping this target while smoothly lining up the shot under your cursor.")
            return
        end
        point, cameraClear = aimPoint(currentModel, root, camera, character)
        projected, onScreen = camera:WorldToViewportPoint(point)
    end
    if not onScreen or projected.Z <= 0 then
        if not farmOptions.continuous then setPressed(false) end
        setStatus(moving and "Following outside view" or "Target outside view",
            "Target stays selected. Following is independent of your view; shooting still needs it on screen.")
        return
    end
    if not cameraClear then
        if not farmOptions.continuous then setPressed(false) end
        setStatus(moving and "Following target" or "Camera shot blocked",
            farmOptions.camera and "Keeping this target and repositioning for a clear view."
            or "Waiting for a clear mouse-aimed shot.")
        if not farmOptions.continuous then return end
    end
    if not farmOptions.camera and aimHitsButton(projected) then
        setPressed(false)
        setStatus("Aim is covered", "Move the panel or close the screen covering the target.")
        return
    end
    if not farmOptions.camera and UserInputService.MouseBehavior ~= Enum.MouseBehavior.Default then
        setPressed(false)
        setStatus("Unlock the pointer", "Leave first person or Shift Lock to aim without turning the view.")
        return
    end
    local dx, dy = 0, 0
    if farmOptions.camera then
        virtualAim = pointer
        if isFurniture and not cursorHitsFurniture(cursorRay, point, currentModel, root, character, camera) then
            if not farmOptions.continuous then
                setPressed(false)
                setStatus("Checking furniture shot", "Waiting for the cursor ray to hit the selected furniture part.")
                return
            end
        end
    elseif virtualClient then
        virtualAim = Vector2.new(math.floor(projected.X + 0.5), math.floor(projected.Y + 0.5))
        local ok, err = pcall(function() virtualClient:SendMousePosition(virtualAim) end)
        if not ok then
            lastInputError = tostring(err)
            releaseInput()
            targetCooldowns[currentName] = now + 2
            clearTarget()
            setStatus("Aim input rejected", "Trying another target. Capture details includes the error.")
            log("INPUT_POSITION_ERROR: " .. lastInputError)
            return
        end
    else
        local mouse = UserInputService:GetMouseLocation()
        dx, dy = projected.X - mouse.X, projected.Y - mouse.Y
        if math.abs(dx) > 1 or math.abs(dy) > 1 then
            moveMouse(math.floor(math.clamp(dx, -120, 120) + 0.5), math.floor(math.clamp(dy, -120, 120) + 0.5))
        end
    end
    lastAimDX, lastAimDY = dx, dy
    local tolerance = pressed and 24 or 8
    if now < targetReadyAt or math.abs(dx) > tolerance or math.abs(dy) > tolerance then
        if not farmOptions.continuous then setPressed(false) end
        if now >= targetReadyAt then aimMismatchSince = aimMismatchSince or now end
        if aimMismatchSince and now - aimMismatchSince >= CONFIG.AimStallSeconds then
            setStatus("Aim input stalled", "Try windowed Roblox, then Capture details if aiming stays stuck.")
            if not aimStallLogged then
                aimStallLogged = true
                log(string.format("AIM_STALLED: backend=hardware | dx=%.1f dy=%.1f | click Capture details", dx, dy))
            end
        else
            setStatus("Aiming", "Lining up the held blast.")
        end
        return
    end
    aimMismatchSince, aimStallLogged = nil, false
    if not ensureBlastHeld() then
        setStatus("Reapplying blast", "Refreshing a lost click. The current target stays selected.")
        return
    end
    if distance <= shotRange and characterClear and cameraClear and not retryInactiveShot(metadata, now) then
        setStatus("Reapplying blast", "The aligned ghost has no vacuum activity. Retrying the click.")
        return
    end
    if not farmOptions.continuous then heldSeconds = heldSeconds + deltaTime end
    if metadata and metadata.isLarge and distance <= shotRange and cameraClear
        and metadata.liveModel and metadata.liveModel.Parent then
        local attributes = metadata.liveModel:GetAttributes()
        local progress = attributes.GhostClustersProgress
        local required = attributes.GhostClustersProgressRequired
        -- These attribute names were observed in the user's active boss capture.
        -- A lack of progress is not proof of shielding. Limit the ineffective
        -- attempt and retry instead of holding a beam indefinitely.
        if type(progress) == "number" and type(required) == "number" and required > progress then
            if not bossProgressWatch or bossProgressWatch.name ~= currentName
                or bossProgressWatch.liveModel ~= metadata.liveModel or bossProgressWatch.progress ~= progress then
                bossProgressWatch = { name = currentName, liveModel = metadata.liveModel,
                    progress = progress, heldSeconds = 0 }
            end
            bossProgressWatch.heldSeconds = bossProgressWatch.heldSeconds + deltaTime
            if bossProgressWatch.heldSeconds >= CONFIG.BossNoProgressBudget then
                targetCooldowns[currentName] = now + CONFIG.BossRetrySeconds
                releaseControls(true, farmOptions.continuous)
                clearTarget()
                setStatus("Boss not progressing", "Trying another target before retrying this boss.")
                log("BOSS_NO_PROGRESS: retrying after " .. CONFIG.BossRetrySeconds .. " seconds; shielding is not confirmed.")
                return
            end
        else bossProgressWatch = nil end
    else bossProgressWatch = nil end
    if isFurniture then
        if distance <= shotRange and not needsFloorRoute then
            currentFurnitureBlasted = true
            furnitureShots[currentName] = (furnitureShots[currentName] or 0) + deltaTime
        end
        local budget = metadata.evidence == "furniture sweep" and CONFIG.FurnitureSweepBlastBudget or CONFIG.FurnitureBlastBudget
        if (furnitureShots[currentName] or 0) >= budget then
            finishFurnitureAttempt(now, "No release detected during this attempt. Sweeping the next item.")
            return
        end
    end
    local shotDetail = pressedBackend == "virtual" and "Client-only hold requested. Beam attachment is not confirmed."
        or (moving and "Following the ghost while holding left-click." or "Holding left-click on the selected ghost.")
    if isFurniture then
        shotDetail = metadata.evidence == "pet marker" and "Holding on the pet-found object. Verify a ghost releases."
            or (metadata.evidence == "furniture sweep" and "Sweeping an unmarked furniture item. Holding blast while aiming."
                or "Testing a furniture hint. Verify a ghost releases.")
    elseif metadata and metadata.isLarge then
        shotDetail = metadata.shieldKnown and "Boss shield flag is false. Holding blast on the boss."
            or "Boss shield flag is unavailable. Using the conservative fallback."
    end
    setStatus(farmOptions.background and not windowFocused and "Holding in background"
        or (isFurniture and "Holding on furniture" or "Holding blast"), shotDetail)
end

local function updateUI(now, round)
    if now - lastUIUpdate < 0.1 then return end
    lastUIUpdate = now
    statusLabel.Text, detailLabel.Text = status, detail
    statusLabel.TextColor3 = (state == "running" and not suspended) and colors.green
        or (state == "paused" and colors.orange or colors.accent)
    timerLabel.Text = "Time  " .. round.timer
    scoreLabel.Text = "Score  " .. (round.active and round.score or lastDisplayedScore)
    heldLabel.Text = string.format("Click held  %.1fs", heldSeconds)
    targetCountLabel.Text = "Targets  " .. tostring(seenCount)
    local metadata = currentModel and targetMetadata[currentModel]
    local kind = currentName and currentName:match("^Ghost_([^_]+)")
    targetLabel.Text = "Target  " .. (metadata and metadata.kind == "furniture"
        and (metadata.evidence == "pet marker" and "Pet-found furniture"
            or metadata.evidence == "furniture sweep" and "Furniture sweep" or "Furniture hint")
        or (kind and (kind .. " ghost") or "--"))
    local enabled = state == "running" or state == "countdown"
    farmButton.Text = state == "paused" and "Ghost Gallery  RESUME" or (enabled and "Ghost Gallery  ON" or "Ghost Gallery  OFF")
    farmButton.TextColor3 = enabled and colors.green or colors.muted
    farmButton.BackgroundColor3 = enabled and Color3.fromRGB(59, 107, 86) or colors.card
    local camera = Workspace.CurrentCamera
    if camera then
        local viewport = camera.ViewportSize
        scale.Scale = math.min(1, math.max(0.6, (viewport.Y - 40) / 296), math.max(0.6, (viewport.X - 32) / 280))
        if not dragging then
            local size = panel.AbsoluteSize
            panel.Position = UDim2.fromOffset(math.clamp(panel.Position.X.Offset, 8, math.max(8, viewport.X - size.X - 8)),
                math.clamp(panel.Position.Y.Offset, 8, math.max(8, viewport.Y - size.Y - 8)))
        end
    end
end
local function automationTick(deltaTime)
    if disposed then return end
    local ok, err = xpcall(function()
        local now = os.clock()
        lastAutomationAt = now
        if windowActive then
            local checked, active = pcall(windowActive)
            if checked and type(active) == "boolean" then changeWindowFocus(active) end
        end
        local round = readRound()
        latestRound = round
        if round.active then lastDisplayedScore = round.score end
        if round.active and not lastRound then
            clearTarget()
            visualHints, landingHints, furnitureShots, furniturePartVisits, targetCooldowns = {}, {}, {}, {}, {}
            lastActiveEvidence, lastProtectionEvidence = {}, {}
            evidenceAt = -math.huge
            bossPolicy = { smallLive = 0, matchedSmall = 0, largeLive = 0,
                shieldLive = 0, matchedShields = 0, shieldedLarge = 0, flagVerified = false,
                blocked = false, fallbackBlocked = false, clearSince = nil }
            refreshedAt = -math.huge
            roundStartScore = round.score
            log("ROUND: started; displayedScore=" .. roundStartScore)
        elseif not round.active and lastRound then
            releaseControls()
            clearTarget()
            visualHints, landingHints, cached, targetMetadata = {}, {}, {}, {}
            furnitureShots, furniturePartVisits, targetCooldowns = {}, {}, {}
            bossPolicy = { smallLive = 0, matchedSmall = 0, largeLive = 0,
                shieldLive = 0, matchedShields = 0, shieldedLarge = 0, flagVerified = false,
                blocked = false, fallbackBlocked = false, clearSince = nil }
            discovery = { released = 0, petFound = 0, hints = 0, sweep = 0 }
            refreshedAt = -math.huge
            joinNotBefore = now + 6
            report("ROUND_END: startDisplayedScore=" .. roundStartScore)
            log("Displayed score can include team activity; verify that your beam attaches.")
        end
        lastRound = round.active
        if state == "countdown" then
            local seconds = math.ceil(countdownEnd - now)
            if seconds > 0 then
                setStatus("Starting in " .. tostring(seconds) .. "s", "Close overlays and move the pointer off the panel.")
            else
                state = "running"
                log("START: End stops; Right Shift toggles the panel. Do not manually hold left-click.")
            end
        end
        if state == "running" and now >= retryNotBefore then
            if not dismissAutoUI(now, round) then
                runFrame(math.min(math.max(deltaTime, 0), 0.25), now, round)
            end
        elseif pressed then
            releaseInput()
        end
        updateUI(now, round)
    end, function(value)
        return debug and type(debug.traceback) == "function" and debug.traceback(tostring(value), 2) or tostring(value)
    end)
    if not ok then
        lastRuntimeError = tostring(err)
        local now = os.clock()
        local recent = {}
        for _, failedAt in ipairs(runtimeFailures) do if now - failedAt < 10 then recent[#recent + 1] = failedAt end end
        recent[#recent + 1] = now
        runtimeFailures = recent
        pcall(releaseControls)
        pcall(clearTarget)
        cached, targetMetadata = {}, {}
        refreshedAt = -math.huge
        retryNotBefore = now + 1
        if #recent >= 3 then
            state = "paused"
            setStatus("Runtime error", "Capture details, then click Ghost Gallery to retry.")
        else
            setStatus("Retrying", "A game or input update failed. Retrying automatically.")
        end
        pcall(function()
            updateUI(now + 0.1, latestRound)
        end)
        log("ERROR: " .. lastRuntimeError)
    end
end
RunService:BindToRenderStep(BINDING, Enum.RenderPriority.Camera.Value + 1, function(deltaTime)
    lastRenderAt = os.clock()
    automationTick(deltaTime)
end)
connect(RunService.Heartbeat, function()
    local now = os.clock()
    if farmOptions.background and (state == "running" or state == "countdown" or pressed)
        and now - lastRenderAt >= 0.15 and now - lastAutomationAt >= 0.05 then
        automationTick(math.min(now - lastAutomationAt, 0.25))
    end
end)
log("UI_READY: Halloween Farm v0.14. Click Ghost Gallery once inside the Manor or in an active round.")
log("INPUT_BACKEND: focused=" .. (canBlast and "executor left-click" or virtualClient and "client-only input" or "unavailable")
    .. " | background=" .. (virtualClient and "client-only input" or "unavailable"))
log("INPUT_RECOVERY: reconciles duplicate virtual states and retries each inactive shot spell twice. Activity renews the retry budget.")
log("CHARACTER_RECOVERY: preserves targets and attempt budgets during temporary knockdowns; restarts blast after control returns.")
log("AUTO_NICE: ON. Clicks the known MinigameRewardsApp.Body.Button after rounds and confirms that the screen closes.")
log("BACKGROUND_SUPPORT: " .. (virtualClient and "ON by default; client-only input needs an unfocused live test" or virtualUnavailable))
log("CAMERA: automatic aiming ON; aligns the view under your current cursor without mouse-position calls. Live verification required.")
log("Scope: queue entry, matched ghosts, and all loaded Manor minigame furniture, including unmarked items.")
log("HUNT_FURNITURE: sweep ON. Short attempts with cooldowns; each assembly's components are rotated on retries.")
log("CONTINUOUS_BLAST: ON. Holds through aiming, movement and camera gestures; UI interaction, stop and round end release input.")
log("CAMERA_INPUT: look/zoom do not pause the farm; aiming resumes automatically after the camera gesture.")
log("BOSS_POLICY: GhostClustersShielded controls boss eligibility; GhostClustersIsShield prioritizes protectors. Fallback only when the boss flag is missing.")
log("TARGET_POLICY: choose by distance, floor and evidence, then finish one attempt before selecting another.")
if not canBlast then log("MOUSE_SUPPORT: one or more required mouse functions are missing.") end
