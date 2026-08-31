local UEHelpers = require("UEHelpers")

local function is_valid(object)
    if not object then
        return false
    end

    local ok, result = pcall(function()
        return object:IsValid()
    end)

    return ok and result
end

-- Notify data is static per montage asset; cache it so the hook doesn't rescan every tick.
local windowCache = {}

local function getHitCheckWindows(montage)
    local key = montage:GetAddress()
    local cached = windowCache[key]
    if cached then
        return cached
    end

    local windows = {}
    local notifies = montage.Notifies
    local num = notifies:GetArrayNum()

    for i = 1, num do
        local notify = notifies[i]
        local ok, stateClass = pcall(function()
            return notify.NotifyStateClass:IsValid() and notify.NotifyStateClass:GetFName():ToString() or nil
        end)

        if ok and stateClass and stateClass:find("HitCheck", 1, true) then
            local start = notify.LinkValue
            local duration = notify.Duration
            windows[#windows + 1] = {
                start = start,
                ["end"] = start + duration
            }
        end
    end

    windowCache[key] = windows
    return windows
end

local activeIndicators = {}
-- Keyed by animation instance address; latched true for the montage's whole playback once a danger notify fires (not cleared on NotifyEnd) so later HitCheck windows in the same animation stay unparryable.
local activeDangers = {}
-- Keyed by enemy address; used to detect when an enemy moves on to a new montage so the old montage's danger flag can be freed.
local lastMontage = {}
local castDelay = nil
local guardWindow = nil
local EnsureTimings = nil
local socketTarget = nil
local noneSocket = nil

local function ForgetMontage(enemyId)
    local previous = lastMontage[enemyId]
    if previous ~= nil then
        activeDangers[previous] = nil
        lastMontage[enemyId] = nil
    end
end

local function CalcParryWindow(self)
    if castDelay == nil or guardWindow == nil then
        if not (EnsureTimings and EnsureTimings()) then
            return
        end
    end

    local invoker = self:get()
    local enemy = invoker.OwnerEnemy
    local enemyId = enemy:GetAddress()

    local existing = activeIndicators[enemyId]
    if existing ~= nil and not is_valid(existing) then
        activeIndicators[enemyId] = nil
        existing = nil
    end

    local animInstance = enemy:GetAnimInstance()
    if not animInstance:IsValid() then
        activeIndicators[enemyId] = nil
        ForgetMontage(enemyId)
        return
    end

    local montage = animInstance:GetCurrentActiveMontage()
    if not montage:IsValid() then
        activeIndicators[enemyId] = nil
        ForgetMontage(enemyId)
        return
    end

    local montageAddr = montage:GetAddress()
    if lastMontage[enemyId] ~= montageAddr then
        ForgetMontage(enemyId)
        lastMontage[enemyId] = montageAddr
    end

    local position = animInstance:Montage_GetPosition(montage)
    local windows = getHitCheckWindows(montage)
    local isDanger = activeDangers[montageAddr] or false

    local inWindow = false
    for _, w in ipairs(windows) do
        local earliest = w.start - (castDelay + guardWindow)
        local latest = w["end"] - castDelay

        if position >= earliest and position <= latest then
            inWindow = true
            break
        end
    end

    if inWindow and existing == nil then
        local widget = enemy['Enemy Health Widget']
        if is_valid(widget) then
            socketTarget = socketTarget or FName("Socket_Target")
            if isDanger then
                noneSocket = noneSocket or FName("None")
                widget:SpawnWarningIndicator(socketTarget, false, noneSocket)
            else
                widget:SpawnParryableAttackIndicator(socketTarget)
            end
            activeIndicators[enemyId] = enemy
        end
    elseif not inWindow and existing ~= nil then
        -- local widget = enemy['Enemy Health Widget']
        -- widget:ClearParryableAttackIndicator()
        activeIndicators[enemyId] = nil
    end
end

local function LoadClassDefault(assetPath, klassPath)
    pcall(function()
        LoadAsset(assetPath)
    end)

    local klass = StaticFindObject(klassPath)

    if not is_valid(klass) then
        return nil, "Class unavailable: " .. klassPath
    end

    local ok, klassOrError = pcall(function()
        return klass:GetCDO()
    end)

    if not ok or not is_valid(klassOrError) then
        return nil, "ClassDefault unavailable: " .. tostring(klassOrError)
    end

    return klassOrError, nil
end

local function is_parry_notify_state(state)
    if not is_valid(state) then
        return false
    end

    local ok, full_name = pcall(function()
        return state.GameplayEffectClass:GetFullName()
    end)

    return ok and type(full_name) == "string" and string.find(full_name, "GE_Parry_C", 1, true) ~= nil
end

local preId = nil
local postId = nil
local dangerStartPreId = nil
local dangerStartPostId = nil
local dangerEndPreId = nil
local dangerEndPostId = nil
local hooking = false

local blockDurationMagnitude = nil
local hardenPerfectStoneFormDuration = nil
local parryLinkValue = nil
local parryDuration = nil

local function ParryIndicatorUnHook()
    if preId ~= nil or postId ~= nil then
        pcall(UnregisterHook,
            "/Game/Sparta/Core/AI/Components/BPC_AttackWarningInvoker.BPC_AttackWarningInvoker_C:UpdateAttackWarning",
            preId, postId)
    end
    preId = nil
    postId = nil

    if dangerStartPreId ~= nil or dangerStartPostId ~= nil then
        pcall(UnregisterHook,
            "/Game/Sparta/Core/Animations/ANS/ANS_UnparryableAttackWarning.ANS_UnparryableAttackWarning_C:Received_NotifyBegin",
            dangerStartPreId, dangerStartPostId)
    end
    dangerStartPreId = nil
    dangerStartPostId = nil

    if dangerEndPreId ~= nil or dangerEndPostId ~= nil then
        pcall(UnregisterHook,
            "/Game/Sparta/Core/Animations/ANS/ANS_UnparryableAttackWarning.ANS_UnparryableAttackWarning_C:Received_NotifyEnd",
            dangerEndPreId, dangerEndPostId)
    end
    dangerEndPreId = nil
    dangerEndPostId = nil
    activeDangers = {}
    lastMontage = {}

    blockDurationMagnitude = nil
    hardenPerfectStoneFormDuration = nil
    parryLinkValue = nil
    parryDuration = nil
end

local function ParryIndicatorHook()
    if hooking then
        return false
    end
    hooking = true

    ParryIndicatorUnHook()

    local pfb_2, pfbErr_2 = LoadClassDefault(
        "/Game/Sparta/Core/Effects/GE_ActiveBlock_PerfectBlock.GE_ActiveBlock_PerfectBlock",
        "/Game/Sparta/Core/Effects/GE_ActiveBlock_PerfectBlock.GE_ActiveBlock_PerfectBlock_C")
    if pfb_2 then
        print(
            string.format("PerfectBlock.DurationMagnitude: %f\n", pfb_2.DurationMagnitude.ScalableFloatMagnitude.Value))
        blockDurationMagnitude = pfb_2.DurationMagnitude.ScalableFloatMagnitude.Value
    else
        print("Can't get PerfectBlock.DurationMagnitude: " .. tostring(pfbErr_2))
        blockDurationMagnitude = nil
    end

    local hardenBl, hardenBlErr = LoadClassDefault(
        "/Game/Sparta/Core/Characters/Player/Common/Abilities/StoneForm/GA_Harden_Original.GA_Harden_Original",
        "/Game/Sparta/Core/Characters/Player/Common/Abilities/StoneForm/GA_Harden_Original.GA_Harden_Original_C")
    if hardenBl then
        print(string.format("HardenBlock.PerfectStoneFormDuration: %f\n", hardenBl.PerfectStoneFormDuration))
        hardenPerfectStoneFormDuration = hardenBl.PerfectStoneFormDuration
    else
        print("Can't get HardenBlock.PerfectStoneFormDuration: " .. tostring(hardenBlErr))
        hardenPerfectStoneFormDuration = nil
    end

    local montage_path_1 =
        "/Game/Sparta/Characters/Shells/_Shared/Animation/Parry/AM_Shared_Actions_InfSeal_Parry_01_A.AM_Shared_Actions_InfSeal_Parry_01_A"
    pcall(function()
        LoadAsset(montage_path_1)
    end)

    local montage = StaticFindObject(montage_path_1)
    if not is_valid(montage) then
        print("Parry montage unavailable: " .. montage_path_1)
    else
        local parry, parryErr = pcall(function()
            montage.Notifies:ForEach(function(_, element)
                local event = element:get()
                local state = event.NotifyStateClass

                if is_parry_notify_state(state) then
                    parryLinkValue = event.LinkValue
                    parryDuration = event.Duration
                end
            end)
        end)

        if not parry then
            print("Can't get Parry.LinkValue & Parry.Duration: " .. tostring(parryErr))
            parryLinkValue = nil
            parryDuration = nil
        else
            print(string.format("Parry.LinkValue: %f\n", parryLinkValue))
            print(string.format("Parry.Duration: %f\n", parryDuration))
        end
    end

    local ok, p, q = pcall(function()
        return RegisterHook(
            "/Game/Sparta/Core/AI/Components/BPC_AttackWarningInvoker.BPC_AttackWarningInvoker_C:UpdateAttackWarning",
            CalcParryWindow)
    end)

    if ok and p ~= nil then
        preId = p
        postId = q
        print(string.format("Load ParryIndicator successfully! preId: %d | postId: %d\n", preId, postId))

        local dsOk, dsP, dsQ = pcall(function()
            return RegisterHook(
                "/Game/Sparta/Core/Animations/ANS/ANS_UnparryableAttackWarning.ANS_UnparryableAttackWarning_C:Received_NotifyBegin",
                function(_, _, Animation)
                    local animation = Animation:get()
                    if is_valid(animation) then
                        activeDangers[animation:GetAddress()] = true
                    end
                end)
        end)
        if dsOk and dsP ~= nil then
            dangerStartPreId = dsP
            dangerStartPostId = dsQ
            print(string.format("Hooked OnDangerStart: %d | %d\n", dangerStartPreId, dangerStartPostId))
        end

        -- NotifyEnd intentionally does not clear activeDangers: the flag stays latched for the rest of the montage's playback.
        local deOk, deP, deQ = pcall(function()
            return RegisterHook(
                "/Game/Sparta/Core/Animations/ANS/ANS_UnparryableAttackWarning.ANS_UnparryableAttackWarning_C:Received_NotifyEnd",
                function(_, _, Animation) end)
        end)
        if deOk and deP ~= nil then
            dangerEndPreId = deP
            dangerEndPostId = deQ
            print(string.format("Hooked OnDangerEnd: %d | %d\n", dangerEndPreId, dangerEndPostId))
        end

        hooking = false
        return true
    end

    hooking = false
    print("Load ParryIndicator failed!\n")
    return false
end

ExecuteInGameThreadWithDelay(1000, function()
    ParryIndicatorHook()
end)

local function ResolveSealTimings()
    local playerController = UEHelpers.GetPlayerController()
    if not is_valid(playerController) then
        return false
    end

    local player = playerController.Pawn
    if not is_valid(player) then
        return false
    end

    local wCom = player.WeaponsComponent
    if not is_valid(wCom) then
        return false
    end

    local ok, weapons = pcall(function()
        return wCom:GetAllWeapons()
    end)
    if not ok or not weapons then
        return false
    end

    for _, wrapper in ipairs(weapons) do
        local weapon = wrapper:get()
        if is_valid(weapon) then
            local wName = weapon:GetClass():GetFName():ToString()
            local delay, window
            if wName == "WP_TarnishedSeal_C" then
                delay, window = 0, blockDurationMagnitude
            elseif wName == "WP_StoneSeal_C" then
                delay, window = 0, hardenPerfectStoneFormDuration
            elseif wName == "WP_InfiniteSeal_C" then
                delay, window = parryLinkValue, parryDuration
            end

            if delay ~= nil and window ~= nil then
                castDelay = delay
                guardWindow = window
                return true
            end
        end
    end

    return false
end

-- Resolved lazily from the hook instead of a timer; retried sparsely so a missing seal can't hammer the API.
local resolveCountdown = 0
EnsureTimings = function()
    if castDelay ~= nil and guardWindow ~= nil then
        return true
    end

    if resolveCountdown > 0 then
        resolveCountdown = resolveCountdown - 1
        return false
    end
    resolveCountdown = 60

    if ResolveSealTimings() then
        print(string.format("[ParryIndicator] castDelay: %f | guardWindow: %f\n", castDelay, guardWindow))
        return true
    end

    return false
end

local loopRunning = false
local function CheckLoop()
    if preId ~= nil then
        loopRunning = false
        return
    end

    ParryIndicatorHook()
    ExecuteInGameThreadWithDelay(1500, CheckLoop)
end

local function StartCheckLoop()
    if loopRunning then
        return
    end
    loopRunning = true
    ExecuteInGameThreadWithDelay(1500, CheckLoop)
end

StartCheckLoop()

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    ParryIndicatorHook()
    castDelay = nil
    guardWindow = nil
    resolveCountdown = 0
    activeIndicators = {}
    activeDangers = {}
    lastMontage = {}
    windowCache = {}
    StartCheckLoop()
end)
