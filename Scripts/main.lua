local UEHelpers = require("UEHelpers")
local Config = require("config")

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
local ResolveSealTimings = nil
local socketTarget = nil
local noneSocket = nil
local currentAimTarget = nil

local function IsCurrentLockOnTarget(enemy)
    return is_valid(currentAimTarget) and currentAimTarget:GetAddress() == enemy:GetAddress()
end

local function PlayParryTargetRumble()
    if Config.disableRumbleIndicators then
        return
    end

    local playerController = UEHelpers.GetPlayerController()
    if not is_valid(playerController) then
        return
    end

    local latentInfo = {
        Linkage = 0,
        UUID = -1,
        ExecutionFunction = FName(""),
        CallbackTarget = playerController
    }
    playerController:PlayDynamicForceFeedback(Config.rumbleDuration, Config.rumbleStrength,
        Config.rumbleUseLeftLargeMotor, Config.rumbleUseLeftSmallMotor,
        Config.rumbleUseRightLargeMotor, Config.rumbleUseRightSmallMotor, 0, latentInfo)
end

local function ForgetMontage(enemyId)
    local previous = lastMontage[enemyId]
    if previous ~= nil then
        activeDangers[previous] = nil
        lastMontage[enemyId] = nil
    end
end

local function CalcParryWindow(self)
    if castDelay == nil or guardWindow == nil then
        return
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
            local isLockOnTarget = IsCurrentLockOnTarget(enemy)
            if isDanger then
                if not Config.disableDangerIndicators then
                    noneSocket = noneSocket or FName("None")
                    widget:SpawnWarningIndicator(socketTarget, false, noneSocket)
                end
            else
                if not Config.disableParryIndicators and
                    not (Config.disbaleParryIndicatorsOnLockOnly and isLockOnTarget) then
                    widget:SpawnParryableAttackIndicator(socketTarget)
                end
                if isLockOnTarget then
                    PlayParryTargetRumble()
                end
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
local aimTargetPreId = nil
local aimTargetPostId = nil
local aimTargetAssetPath = "/Game/Sparta/Core/Player/Components/BPC_Player_SoftTargeting.BPC_Player_SoftTargeting"
local aimTargetClassPath = aimTargetAssetPath .. "_C"
local aimTargetAssetLoadAttempted = false
local aimTargetHookRunning = false
local hooking = false

local blockDurationMagnitude = nil
local hardenPerfectStoneFormDuration = nil
local parryLinkValue = nil
local parryDuration = nil

local function UnhookAimTarget()
    if aimTargetClassPath ~= nil and (aimTargetPreId ~= nil or aimTargetPostId ~= nil) then
        pcall(UnregisterHook, aimTargetClassPath .. ":Update Aim Target", aimTargetPreId, aimTargetPostId)
    end
    aimTargetPreId = nil
    aimTargetPostId = nil
    aimTargetHookRunning = false
    currentAimTarget = nil
end

local function ParryIndicatorUnHook(keepAimTargetHook)
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
    if not keepAimTargetHook then
        UnhookAimTarget()
    end
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

    ParryIndicatorUnHook(true)

    local pfb_2, pfbErr_2 = LoadClassDefault(
        "/Game/Sparta/Core/Effects/GE_ActiveBlock_PerfectBlock.GE_ActiveBlock_PerfectBlock",
        "/Game/Sparta/Core/Effects/GE_ActiveBlock_PerfectBlock.GE_ActiveBlock_PerfectBlock_C")
    if pfb_2 then
        print(
            string.format("[ParryIndicator] PerfectBlock.DurationMagnitude: %f\n", pfb_2.DurationMagnitude.ScalableFloatMagnitude.Value))
        blockDurationMagnitude = pfb_2.DurationMagnitude.ScalableFloatMagnitude.Value
    else
        print("[ParryIndicator] Can't get PerfectBlock.DurationMagnitude: " .. tostring(pfbErr_2))
        blockDurationMagnitude = 0.3
    end

    local hardenBl, hardenBlErr = LoadClassDefault(
        "/Game/Sparta/Core/Characters/Player/Common/Abilities/StoneForm/GA_Harden_Original.GA_Harden_Original",
        "/Game/Sparta/Core/Characters/Player/Common/Abilities/StoneForm/GA_Harden_Original.GA_Harden_Original_C")
    if hardenBl then
        print(string.format("[ParryIndicator] HardenBlock.PerfectStoneFormDuration: %f\n", hardenBl.PerfectStoneFormDuration))
        hardenPerfectStoneFormDuration = hardenBl.PerfectStoneFormDuration
    else
        print("[ParryIndicator] Can't get HardenBlock.PerfectStoneFormDuration: " .. tostring(hardenBlErr))
        hardenPerfectStoneFormDuration = 0.25
    end

    local montage_path_1 =
        "/Game/Sparta/Characters/Shells/_Shared/Animation/Parry/AM_Shared_Actions_InfSeal_Parry_01_A.AM_Shared_Actions_InfSeal_Parry_01_A"
    pcall(function()
        LoadAsset(montage_path_1)
    end)

    local montage = StaticFindObject(montage_path_1)
    if not is_valid(montage) then
        print("[ParryIndicator] Parry montage unavailable: " .. montage_path_1)
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
            print("[ParryIndicator] Can't get Parry.LinkValue & Parry.Duration: " .. tostring(parryErr))
            parryLinkValue = 0.105
            parryDuration = 0.277
        else
            print(string.format("[ParryIndicator] Parry.LinkValue: %f\n", parryLinkValue))
            print(string.format("[ParryIndicator] Parry.Duration: %f\n", parryDuration))
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
        print(string.format("[ParryIndicator] Load ParryIndicator successfully! preId: %d | postId: %d\n", preId, postId))

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
            print(string.format("[ParryIndicator] Hooked OnDangerStart: %d | %d\n", dangerStartPreId, dangerStartPostId))
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
            print(string.format("[ParryIndicator] Hooked OnDangerEnd: %d | %d\n", dangerEndPreId, dangerEndPostId))
        end

        hooking = false
        return true
    end

    hooking = false
    print("[ParryIndicator] Load ParryIndicator failed!\n")
    return false
end

ExecuteInGameThreadWithDelay(1000, function()
    ParryIndicatorHook()
end)

ResolveSealTimings = function()
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
                print(string.format("[ParryIndicator] Resolved seal timings: castDelay=%f, guardWindow=%f\n", castDelay, guardWindow))
                return true
            end
        end
    end

    return false
end

-- Equip/seal-swap happens in the WBP_MGT_ChangeEquipment menu; re-resolve only when that menu actually closes
local menuClosePreId = nil
local menuClosePostId = nil
local menuCloseHookRunning = false
local menuCloseAssetPath = "/Game/Sparta/UI/Menu/LandingArea/WBP_MGT_ChangeEquipment.WBP_MGT_ChangeEquipment"
local menuCloseClassPath = menuCloseAssetPath .. "_C"
local menuCloseAssetLoadAttempted = false

local function TryHookMenuClose()
    if menuClosePreId ~= nil then
        return true
    end

    if not menuCloseAssetLoadAttempted then
        menuCloseAssetLoadAttempted = true
        pcall(function()
            LoadAsset(menuCloseAssetPath)
        end)
    end

    local klass = StaticFindObject(menuCloseClassPath)
    if not is_valid(klass) then
        return false
    end

    local hOk, hP, hQ = pcall(function()
        return RegisterHook(menuCloseClassPath .. ":OnMenuClose", function(_)
            ResolveSealTimings()
        end)
    end)

    if hOk and hP ~= nil then
        menuClosePreId = hP
        menuClosePostId = hQ
        print(string.format("[ParryIndicator] Hooked OnMenuClose: %d | %d\n", menuClosePreId, menuClosePostId))
        return true
    end

    return false
end

local function MenuCloseHookLoop()
    if TryHookMenuClose() then
        menuCloseHookRunning = false
        return
    end

    ExecuteInGameThreadWithDelay(5000, MenuCloseHookLoop)
end

local function StartMenuCloseHookLoop()
    if menuCloseHookRunning or menuClosePreId ~= nil then
        return
    end
    menuCloseHookRunning = true
    MenuCloseHookLoop()
end

-- Retries ResolveSealTimings on a short interval only until the initial seal is found, then stops until the next ClientRestart.
local sealResolveRunning = false
local function SealResolveLoop()
    if (castDelay ~= nil and guardWindow ~= nil) or ResolveSealTimings() then
        sealResolveRunning = false
        return
    end

    ExecuteInGameThreadWithDelay(5000, SealResolveLoop)
end

local function StartSealResolveLoop()
    if sealResolveRunning then
        return
    end
    sealResolveRunning = true
    SealResolveLoop()
end

local function TryHookAimTarget()
    if aimTargetPreId ~= nil then
        return true
    end

    if not aimTargetAssetLoadAttempted then
        aimTargetAssetLoadAttempted = true
        pcall(function()
            LoadAsset(aimTargetAssetPath)
        end)
    end

    local klass = StaticFindObject(aimTargetClassPath)
    if not is_valid(klass) then
        return false
    end

    local hOk, hP, hQ = pcall(function()
        return RegisterHook(aimTargetClassPath .. ":Update Aim Target", function(_, AimTarget)
            local actor = AimTarget:get()
            if is_valid(actor) then
                currentAimTarget = actor
            else
                currentAimTarget = nil
            end
        end)
    end)

    if hOk and hP ~= nil then
        aimTargetPreId = hP
        aimTargetPostId = hQ
        print(string.format("[ParryIndicator] Hooked Update Aim Target: %d | %d\n", aimTargetPreId, aimTargetPostId))
        return true
    end

    return false
end

local function AimTargetHookLoop()
    if TryHookAimTarget() then
        aimTargetHookRunning = false
        return
    end

    ExecuteInGameThreadWithDelay(1000, AimTargetHookLoop)
end

local function StartAimTargetHookLoop()
    if aimTargetHookRunning or aimTargetPreId ~= nil then
        return
    end
    aimTargetHookRunning = true
    AimTargetHookLoop()
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
StartMenuCloseHookLoop()
StartSealResolveLoop()
StartAimTargetHookLoop()

RegisterHook("/Script/Engine.PlayerController:ClientRestart", function()
    UnhookAimTarget()
    ParryIndicatorHook()
    castDelay = nil
    guardWindow = nil
    activeIndicators = {}
    activeDangers = {}
    lastMontage = {}
    windowCache = {}
    StartCheckLoop()
    StartMenuCloseHookLoop()
    StartSealResolveLoop()
    StartAimTargetHookLoop()
end)
