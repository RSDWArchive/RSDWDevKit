local M = {}

local core = require("feature_player_core")

local RANGED_ALIASES = { "BP_Components_PlayerRangedAttack", "PlayerRangedAttackComponent" }
local COMBAT_MAGIC_ALIASES = { "BP_Components_PlayerCombatMagic", "PlayerCombatMagicComponent" }
local UTILITY_MAGIC_ALIASES = { "BP_Components_PlayerUtilityMagic", "PlayerUtilityMagicComponent" }
local PLAYER_MELEE_ATTACK_ALIASES = { "BP_Components_PlayerMeleeAttack", "PlayerMeleeAttackComponent" }
local PLAYER_EQUIPMENT_ALIASES = { "BP_Components_PlayerEquipment", "PlayerEquipmentComponent" }
local PLAYER_ACTION_PERFORMER_ALIASES = { "BP_Components_PlayerActionPerformer", "PlayerActionPerformerComponent" }
local PLAYER_INPUT_BUFFER_ALIASES = { "InputBuffer" }

local function trim_animation_arg(value_str)
    return value_str and tostring(value_str):match("^%s*(.-)%s*$") or ""
end

local function split_animation_arg(value_str)
    local text = trim_animation_arg(value_str)
    local first, rest = text:match("^(%S+)%s*(.-)%s*$")
    return first or "", rest or ""
end

local function strip_animation_prefix(value_str, prefix)
    local text = trim_animation_arg(value_str)
    local lower = text:lower()
    if lower:sub(1, #prefix + 1) == prefix .. ":" then
        return trim_animation_arg(text:sub(#prefix + 2))
    end
    return text
end

local function append_fields(lines, label, root, fields)
    for _, field in ipairs(fields) do
        lines[#lines + 1] = string.format("%s.%s = %s", label, field, core.field_text(root, field))
    end
end

local function append_component_state(lines, label, pawn, aliases, fields)
    local comp, alias = core.get_component(pawn, aliases)
    if not comp then
        lines[#lines + 1] = label .. " = <missing: " .. tostring(alias) .. ">"
        return nil, alias
    end
    lines[#lines + 1] = string.format("%s = %s via %s", label, core.value_label(comp), alias)
    append_fields(lines, label, comp, fields)
    return comp, alias
end

local function append_method_state(lines, label, comp, alias, methods)
    if not comp then return end
    for _, method_name in ipairs(methods) do
        local ok_call, value = core.call_comp_method(comp, alias, method_name)
        lines[#lines + 1] = string.format("%s:%s() = %s", label, method_name,
            ok_call and core.value_label(value) or ("<call failed: " .. core.first_error_line(value) .. ">"))
    end
end

local function print_attack_diag(title, lines)
    print("[RSDWTools.attack." .. title .. "] begin")
    for _, line in ipairs(lines) do print("[RSDWTools.attack." .. title .. "] " .. line) end
    print("[RSDWTools.attack." .. title .. "] end")
end

local ATTACK_COMPONENT_FIELDS = {
    "Player",
    "CachedAttackMontage",
    "AttackInputBufferWindow",
    "CurrentAttack.AttackData",
    "CurrentAttack.ActionInstance.Data",
    "CurrentAttack.ActionInstance.ActionGranter",
    "LastExecutedAttack.AttackData",
    "LastExecutedAttack.ActionInstance.Data",
    "LastExecutedAttack.ActionInstance.ActionGranter",
}

local MELEE_COMPONENT_FIELDS = {
    "MaximumAngleAimAssist",
    "ScreenSpaceRadius",
}

local RANGED_COMPONENT_FIELDS = {
    "EquipmentComponent",
    "CachedEquipmentUsed",
    "bAimModeAvailable",
    "bAimModeActive",
    "bServerAimModeActive",
    "IsAimingOnCooldown",
    "WindUpStartTime",
    "AimingDurationCounter",
    "CachedRangedAttackCollection",
    "RangedWeaponActor",
    "PreChargeUpDuration",
    "ChargeUpDuration",
    "HasReachedFullAccuracy",
    "bIsInTrickShotWindow",
}

local RANGED_COLLECTION_FIELDS = {
    "QuickAttackData",
    "bAllowMovementDuringQuickAttack",
    "FullAttackData",
    "MaxPreChargeUpDuration",
    "MaxChargeUpDuration",
    "WindUpNoShootPeriod",
    "TimeBeforeFullAccuracy",
    "TimeAtFullStrength",
    "TrickShotWindowDuration",
    "AdditionalTimeBeforeFiringTheArrow",
}

local RANGED_METHODS = {
    "IsAimModeActive",
    "IsWindingUp",
    "HasRequiredAmmoEquipped",
    "IsInQuickShotWindow",
    "IsInTrickShotWindow",
    "GetChargeUpProgressNormalized",
    "GetWeaponReadyProgressNormalized",
    "GetCurrentArrowInaccuracy",
    "GetCurrentStrainLevel",
    "GetEquippedRangedAmmoDataForCurrentWeapon",
}

local MAGIC_COMPONENT_FIELDS = {
    "PlayerCharacter",
    "EquippedMagicAmmoToPrimaryStarterSpell",
    "EquippedMagicAmmoToSecondaryStarterSpell",
    "LastChainedSpell",
    "SpellAnimationPlayer",
    "CurrentSpellActor",
    "bShouldBlockMovement",
    "bHoldingInput",
    "CurrentTargets",
}

local SPELLCASTING_COMPONENT_FIELDS = {
    "SelectedSpells",
    "CastIDToSpellPlacementVisualizer",
}

local EQUIPMENT_STATE_FIELDS = {
    "HeldEquipmentActorLeft",
    "HeldEquipmentActorRight",
}

local ACTION_PERFORMER_FIELDS = {
    "DefaultPrimaryAction",
    "DefaultSecondaryAction",
    "DefaultSpecialAction",
    "DefaultEvadeAction",
    "TriggeredFlags",
}

local INPUT_BUFFER_FIELDS = {
    "ActionPerformer",
}

local ATTACK_DATA_FIELDS = {
    "InPlaceAttackData.Montage",
    "RootMotionAttackData.Montage",
    "MontagePreset",
    "HeldEquipmentMontage",
    "Directionality",
    "DamageAmount",
    "DamageClass",
    "AttackPropertyFlags",
    "AiBlockStaminaCostMultiplier",
    "bDamageSingleTarget",
    "Force",
    "TimedDamageShapes",
    "StaminaCost",
    "AttackSpeedMultiplierAttribute",
    "NextAttackClass",
    "RequiredPerkForNextAttack",
    "NextAttackClassNoRequiredPerk",
    "GameplayEffectInstancesToApply",
    "GameplayEffectsToApply",
    "bLimitMovementSpeedDuringAttack",
    "MaxMovementSpeedDuringAttack",
}

local function collection_membership(comp, attack_class)
    if not comp or not attack_class then return "missing component" end
    local ok_read, collection = core.read_path(comp, "AttackDataCollection")
    if not ok_read or collection == nil then return "collection unreadable" end
    local count = core.tarray_count(collection)
    if not count then return "collection not array" end
    local target = core.value_label(attack_class)
    for i = 1, count do
        local item, ok_item = core.tarray_get(collection, i)
        if ok_item then
            local item_label = core.value_label(item)
            if item == attack_class or item_label == target then
                return string.format("yes gameDataIndex=%d luaIndex=%d count=%d", i - 1, i, count)
            end
        end
    end
    return string.format("no count=%d", count)
end

function M.attack_state(_value_str)
    local pawn = core.get_pawn()
    if not pawn then return false, "no local pawn" end

    local lines = { "pawn = " .. core.value_label(pawn) }
    local melee = append_component_state(lines, "melee", pawn, PLAYER_MELEE_ATTACK_ALIASES, ATTACK_COMPONENT_FIELDS)
    if melee then append_fields(lines, "melee", melee, MELEE_COMPONENT_FIELDS) end
    local ranged, ranged_alias = append_component_state(lines, "ranged", pawn, RANGED_ALIASES, ATTACK_COMPONENT_FIELDS)
    if ranged then
        append_fields(lines, "ranged", ranged, RANGED_COMPONENT_FIELDS)
        append_method_state(lines, "ranged", ranged, ranged_alias, RANGED_METHODS)
        local ok_collection, ranged_collection = core.read_path(ranged, "CachedRangedAttackCollection")
        if ok_collection and core.is_valid_uobject(ranged_collection) then
            append_fields(lines, "ranged.collection", ranged_collection, RANGED_COLLECTION_FIELDS)
        end
    end

    append_component_state(lines, "combat_magic", pawn, COMBAT_MAGIC_ALIASES, MAGIC_COMPONENT_FIELDS)
    append_component_state(lines, "utility_magic", pawn, UTILITY_MAGIC_ALIASES, MAGIC_COMPONENT_FIELDS)

    local spellcasting, spellcasting_err = core.get_spellcasting_component(pawn)
    if spellcasting then
        lines[#lines + 1] = "spellcasting = " .. core.value_label(spellcasting)
        append_fields(lines, "spellcasting", spellcasting, SPELLCASTING_COMPONENT_FIELDS)
    else
        lines[#lines + 1] = "spellcasting = <missing: " .. tostring(spellcasting_err) .. ">"
    end

    append_component_state(lines, "equipment", pawn, PLAYER_EQUIPMENT_ALIASES, EQUIPMENT_STATE_FIELDS)
    append_component_state(lines, "action_performer", pawn, PLAYER_ACTION_PERFORMER_ALIASES, ACTION_PERFORMER_FIELDS)
    append_component_state(lines, "input_buffer", pawn, PLAYER_INPUT_BUFFER_ALIASES, INPUT_BUFFER_FIELDS)

    print_attack_diag("state", lines)
    return true, string.format("printed %d combat state lines", #lines)
end

function M.attack_data(value_str)
    local class_path = strip_animation_prefix(value_str, "attack")
    if class_path == "" then return false, "usage: player.attack.data <UPlayerAttackDataClassPath>" end

    local attack_class = core.resolve_uclass(class_path)
    if not attack_class then return false, "attack class not found: " .. core.normalize_uclass_path(class_path) end
    local cdo, cdo_err = core.resolve_class_cdo(attack_class)
    if not cdo then return false, cdo_err end

    local normalized = core.normalize_uclass_path(class_path)
    local lines = {
        "class = " .. core.value_label(attack_class),
        "cdo = " .. core.value_label(cdo),
    }
    append_fields(lines, "data", cdo, ATTACK_DATA_FIELDS)

    local pawn = core.get_pawn()
    if pawn then
        local melee = core.get_component(pawn, PLAYER_MELEE_ATTACK_ALIASES)
        local ranged = core.get_component(pawn, RANGED_ALIASES)
        lines[#lines + 1] = "melee.AttackDataCollection contains class = " .. collection_membership(melee, attack_class)
        lines[#lines + 1] = "ranged.AttackDataCollection contains class = " .. collection_membership(ranged, attack_class)
    end

    print_attack_diag("data", lines)
    return true, string.format("%s printed %d data lines", core.animation_short_name(normalized), #lines)
end

local ATTACK_TRACE_HOOKS = {
    {
        name = "PlayerAction.OnInputTriggered",
        path = "/Script/Dominion.PlayerAction:OnInputTriggered",
        params = { "Player", "TriggerData", "PlayerActionInstance" },
    },
    {
        name = "PlayerMeleeAttackAction.GetAttackDataClass",
        path = "/Script/Dominion.PlayerMeleeAttackAction:GetAttackDataClass",
        params = { "PlayerActionInstance" },
    },
    {
        name = "PlayerAttackComponent.BP_PerformAttack",
        path = "/Script/Dominion.PlayerAttackComponent:BP_PerformAttack",
        params = { "DataClass", "PlayerActionInstance" },
    },
    {
        name = "PlayerAttackComponent.Multicast_PerformAttackOnSimulatedProxies",
        path = "/Script/Dominion.PlayerAttackComponent:Multicast_PerformAttackOnSimulatedProxies",
        params = { "AttackId", "DataIndex", "Forward", "bUseRootMotion", "TranslationScale", "SpeedMultiplier", "PlayerActionInstance" },
    },
    {
        name = "PlayerAttackComponent.Multicast_AttackHasCompleted",
        path = "/Script/Dominion.PlayerAttackComponent:Multicast_AttackHasCompleted",
        params = { "ActionIndex", "AttackId" },
    },
    {
        name = "PlayerAttackComponent.AttackEnded",
        path = "/Script/Dominion.PlayerAttackComponent:AttackEnded",
        params = {},
    },
    {
        name = "PlayerMeleeAttackComponent.Multicast_SendDamageCacheData",
        path = "/Script/Dominion.PlayerMeleeAttackComponent:Multicast_SendDamageCacheData",
        params = { "DamageInfo" },
    },
    {
        name = "DamageComponent.BP_PredictPointDamage",
        path = "/Script/Dominion.DamageComponent:BP_PredictPointDamage",
        params = {
            "DamageClass", "TypeDamages", "ApplicationTime", "Instigator", "Source",
            "Location", "Direction", "Directionality", "Force", "OptionalGameplayEffectsToApply",
            "DamageProperties", "AttackProperties", "AttackId", "StaminaCostMultiplier",
            "DamageShape", "DamageShapeTransform", "WeakPointEventName", "bCanCauseCrits", "bApplyGEsIfBlocked",
            "ParryWindowExtensionMs", "OverrideInstigatorLocation",
        },
    },
    {
        name = "DamageFunctionLibrary.ApplyPointDamage",
        path = "/Script/Dominion.DamageFunctionLibrary:ApplyPointDamage",
        params = { "Target", "PointDamageEvent" },
    },
    {
        name = "PlayerRangedAttackComponent.BP_OnStartDraw",
        path = "/Script/Dominion.PlayerRangedAttackComponent:BP_OnStartDraw",
        params = {},
    },
    {
        name = "PlayerRangedAttackComponent.BP_OnShootArrow",
        path = "/Script/Dominion.PlayerRangedAttackComponent:BP_OnShootArrow",
        params = { "bMisfire" },
    },
    {
        name = "PlayerRangedAttackComponent.BP_OnEndDraw",
        path = "/Script/Dominion.PlayerRangedAttackComponent:BP_OnEndDraw",
        params = {},
    },
    {
        name = "PlayerRangedAttackComponent.BP_OnStartStrain",
        path = "/Script/Dominion.PlayerRangedAttackComponent:BP_OnStartStrain",
        params = {},
    },
    {
        name = "PlayerRangedAttackComponent.BP_OnEndStrain",
        path = "/Script/Dominion.PlayerRangedAttackComponent:BP_OnEndStrain",
        params = {},
    },
    {
        name = "PlayerRangedAttackComponent.BP_OnFullAccuracyReached",
        path = "/Script/Dominion.PlayerRangedAttackComponent:BP_OnFullAccuracyReached",
        params = {},
    },
    {
        name = "PlayerRangedAttackComponent.BP_OnAimStateChange",
        path = "/Script/Dominion.PlayerRangedAttackComponent:BP_OnAimStateChange",
        params = { "bAiming" },
    },
    {
        name = "DominionRuntimeBlueprintLibrary.TriggerModularAbilityForPlayer",
        path = "/Script/Dominion.DominionRuntimeBlueprintLibrary:TriggerModularAbilityForPlayer",
        params = { "PlayerCharacter", "AbilityData" },
    },
    {
        name = "PlayerMagicComponent.Multicast_SendPayloadForSpellCasting",
        path = "/Script/Dominion.PlayerMagicComponent:Multicast_SendPayloadForSpellCasting",
        params = { "SpellNetId" },
    },
    {
        name = "PlayerMagicComponent.HandleOnSpellCastingAnimationFinished",
        path = "/Script/Dominion.PlayerMagicComponent:HandleOnSpellCastingAnimationFinished",
        params = {},
    },
    {
        name = "DominionSpellActor.OnRep_SpellDataNetId",
        path = "/Script/Dominion.DominionSpellActor:OnRep_SpellDataNetId",
        params = {},
    },
    {
        name = "DominionSpellActor.OnMontageEnded",
        path = "/Script/Dominion.DominionSpellActor:OnMontageEnded",
        params = { "Montage", "bInterrupted" },
    },
    {
        name = "DominionSpellInstance.OnRep_State",
        path = "/Script/Dominion.DominionSpellInstance:OnRep_State",
        params = { "OldState" },
    },
    {
        name = "SpellAnimationPlayer.OnMontageEnded",
        path = "/Script/Dominion.SpellAnimationPlayer:OnMontageEnded",
        params = { "AnimMontage", "bInterrupted" },
    },
    {
        name = "SpellModule_DamageRuntime.OnRep_DamageInfo",
        path = "/Script/Dominion.SpellModule_DamageRuntime:OnRep_DamageInfo",
        params = {},
    },
    {
        name = "SpellModule_TargetingRuntime.OnRep_TargetLocation",
        path = "/Script/Dominion.SpellModule_TargetingRuntime:OnRep_TargetLocation",
        params = {},
    },
    {
        name = "SpellModule_SpawnActorRuntime.OnRep_Actor",
        path = "/Script/Dominion.SpellModule_SpawnActorRuntime:OnRep_Actor",
        params = {},
    },
    {
        name = "SpellModule_PlayMontageRuntime.OnRep_AnimationParam",
        path = "/Script/Dominion.SpellModule_PlayMontageRuntime:OnRep_AnimationParam",
        params = {},
    },
}

local attack_trace_state = { enabled = false, hooks = {}, events = 0 }

local PLAYER_ACTION_INSTANCE_TRACE_FIELDS = {
    "Data",
    "ActionGranter",
    "PlayerOwner",
    "EquipmentHand",
    "ActionInputType",
}

local DAMAGE_INFO_TRACE_FIELDS = {
    "DamagedActors",
    "AttackId",
    "Location",
    "Source",
    "Shape",
    "PlayerActionInstance.Data",
    "PlayerActionInstance.ActionGranter",
    "PlayerActionInstance.EquipmentHand",
    "PlayerActionInstance.ActionInputType",
}

local TIMED_DAMAGE_INFO_TRACE_FIELDS = {
    "TimeOffset",
    "bIsInstigatorPendingFullBodyReact",
    "DamageInfo.DamagedActors",
    "DamageInfo.AttackId",
    "DamageInfo.Location",
    "DamageInfo.Source",
    "DamageInfo.Shape",
    "DamageInfo.PlayerActionInstance.Data",
    "DamageInfo.PlayerActionInstance.ActionGranter",
    "DamageInfo.PlayerActionInstance.EquipmentHand",
    "DamageInfo.PlayerActionInstance.ActionInputType",
}

local SPELL_NET_ID_TRACE_FIELDS = {
    "NetId",
}

local SPELL_INSTANCE_STATE_TRACE_FIELDS = {
    "State",
    "Owner",
}

local function vector_label(value)
    local ok_x, x = core.read_path(value, "X")
    local ok_y, y = core.read_path(value, "Y")
    local ok_z, z = core.read_path(value, "Z")
    if ok_x and ok_y and ok_z and type(x) == "number" and type(y) == "number" and type(z) == "number" then
        return string.format("(%.3f, %.3f, %.3f)", x, y, z)
    end
    return nil
end

local function trace_field_label(field, value)
    local field_name = tostring(field or "")
    if field_name == "Forward"
        or field_name:match("Location$")
        or field_name:match("Direction$")
        or field_name:match("OverrideInstigatorLocation$") then
        local vector = vector_label(value)
        if vector then return vector end
    end
    if field_name:find("DamagedActors", 1, true) then
        local count = core.tarray_count(core.unwrap_param(value))
        if count then return string.format("<array count=%d>", count) end
    end
    return core.value_label(value)
end

local function summarize_struct(value, fields)
    local parts = {}
    for _, field in ipairs(fields) do
        local ok_read, field_value = core.read_path(value, field)
        if ok_read then parts[#parts + 1] = field .. "=" .. trace_field_label(field, field_value) end
    end
    if #parts == 0 then return "" end
    return " {" .. table.concat(parts, ", ") .. "}"
end

local function collection_item_label(collection, index)
    local item, ok_item = core.tarray_get(collection, index)
    if ok_item and item ~= nil then return core.value_label(item) end
    return "<unreadable>"
end

local function attack_data_index_detail(context, value)
    local data_index = tonumber(core.unwrap_param(value))
    if not data_index then return nil end
    local comp = core.unwrap_param(context)
    if not comp then return nil end
    local ok_read, collection = core.read_path(comp, "AttackDataCollection")
    if not ok_read or collection == nil then return nil end
    local count = core.tarray_count(collection)
    return string.format("selected=plus1[%d]=%s, raw[%d]=%s, count=%s",
        data_index + 1, collection_item_label(collection, data_index + 1),
        data_index, collection_item_label(collection, data_index), tostring(count or "?"))
end

local function timed_damage_array_detail(value)
    local arr = core.unwrap_param(value)
    local count = core.tarray_count(arr)
    if not count then return summarize_struct(arr, DAMAGE_INFO_TRACE_FIELDS) end
    if count <= 0 then return "" end
    local samples = {}
    local max_index = math.min(count, 3)
    for index = 0, max_index do
        local item, ok_item = core.tarray_get(arr, index)
        if ok_item and item ~= nil then
            local detail = summarize_struct(item, TIMED_DAMAGE_INFO_TRACE_FIELDS)
            samples[#samples + 1] = string.format("[%d]%s", index, detail ~= "" and detail or ("=" .. core.value_label(item)))
            if #samples >= 3 then break end
        end
    end
    if #samples == 0 then return "" end
    return " sample=" .. table.concat(samples, "; ")
end

local function trace_arg_text(name, value, context)
    local base = trace_field_label(name, value)
    if name == "DataIndex" then
        local detail = attack_data_index_detail(context, value)
        if detail then return base .. " (" .. detail .. ")" end
    elseif name == "PlayerActionInstance" then
        return base .. summarize_struct(value, PLAYER_ACTION_INSTANCE_TRACE_FIELDS)
    elseif name == "DamageInfo" then
        local count = core.tarray_count(core.unwrap_param(value))
        if count then base = string.format("<array count=%d>", count) end
        return base .. timed_damage_array_detail(value)
    elseif name == "SpellNetId" then
        return base .. summarize_struct(value, SPELL_NET_ID_TRACE_FIELDS)
    elseif name == "OldState" then
        return base .. summarize_struct(value, SPELL_INSTANCE_STATE_TRACE_FIELDS)
    end
    return base
end

local function make_attack_trace_callback(spec)
    return function(context, ...)
        if not attack_trace_state.enabled then return end
        attack_trace_state.events = attack_trace_state.events + 1
        local parts = {
            string.format("[RSDWTools.attack.trace] #%d %s", attack_trace_state.events, spec.name),
            "self=" .. core.value_label(context),
        }
        local arg_count = select("#", ...)
        for i = 1, arg_count do
            local value = select(i, ...)
            local param_name = (spec.params and spec.params[i]) or ("arg" .. tostring(i))
            parts[#parts + 1] = param_name .. "=" .. trace_arg_text(param_name, value, context)
        end
        print(table.concat(parts, " | "))
    end
end

local function unregister_attack_trace()
    if UnregisterHook then
        for _, hook in ipairs(attack_trace_state.hooks or {}) do
            pcall(function() UnregisterHook(hook.path, hook.pre_id or 0, hook.post_id or 0) end)
            if hook.pre_id then pcall(function() UnregisterHook(hook.path, hook.pre_id, 0) end) end
            if hook.post_id then pcall(function() UnregisterHook(hook.path, 0, hook.post_id) end) end
        end
    end
    attack_trace_state.enabled = false
    attack_trace_state.hooks = {}
end

function M.attack_trace(value_str)
    local arg = tostring(value_str or ""):lower():match("^%s*(.-)%s*$")
    if arg == "" or arg == "toggle" then arg = attack_trace_state.enabled and "off" or "on" end
    if arg == "status" or arg == "state" then
        return true, string.format("%s hooks=%d events=%d", attack_trace_state.enabled and "on" or "off",
            #(attack_trace_state.hooks or {}), attack_trace_state.events or 0)
    end
    if arg == "off" or arg == "0" or arg == "false" then
        local prior_events = attack_trace_state.events or 0
        unregister_attack_trace()
        return true, string.format("off events=%d", prior_events)
    end
    if arg ~= "on" and arg ~= "1" and arg ~= "true" then
        return false, "usage: player.attack.trace <on|off|toggle|status>"
    end
    if not RegisterHook then return false, "RegisterHook unavailable" end

    unregister_attack_trace()
    attack_trace_state.enabled = true
    attack_trace_state.events = 0
    local failures = {}
    for _, spec in ipairs(ATTACK_TRACE_HOOKS) do
        local ok_reg, pre_id, post_id = pcall(function()
            return RegisterHook(spec.path, make_attack_trace_callback(spec))
        end)
        if ok_reg then
            attack_trace_state.hooks[#attack_trace_state.hooks + 1] = {
                name = spec.name,
                path = spec.path,
                pre_id = pre_id,
                post_id = post_id,
            }
        else
            failures[#failures + 1] = spec.name .. ": " .. tostring(pre_id)
        end
    end
    if #attack_trace_state.hooks == 0 then
        attack_trace_state.enabled = false
        return false, "no hooks registered: " .. table.concat(failures, "; ")
    end
    for _, hook in ipairs(attack_trace_state.hooks) do
        print(string.format("[RSDWTools.attack.trace] hook %s pre=%s post=%s", hook.name, tostring(hook.pre_id), tostring(hook.post_id)))
    end
    print(string.format("[RSDWTools.attack.trace] registered %d hooks", #attack_trace_state.hooks))
    if #failures > 0 then
        print("[RSDWTools.attack.trace] failed hooks: " .. table.concat(failures, "; "))
    end
    return true, string.format("on hooks=%d failed=%d", #attack_trace_state.hooks, #failures)
end

local PLAYER_MELEE_ACTION_SPECS = {
    unarmed = {
        normal = { path = "/Game/Gameplay/Character/Player/Attacks/Unarmed/PA_Attack_Unarmed.PA_Attack_Unarmed_C", input = 0 },
    },
    dagger = {
        normal = { path = "/Game/Gameplay/Character/Player/Attacks/Dagger/PA_Attack_Dagger.PA_Attack_Dagger_C", input = 0 },
        special = { path = "/Game/Gameplay/Character/Player/Attacks/Dagger/PA_Attack_Dagger_Special.PA_Attack_Dagger_Special_C", input = 2 },
    },
    sword = {
        normal = { path = "/Game/Gameplay/Character/Player/Attacks/Sword/PA_Attack_Sword.PA_Attack_Sword_C", input = 0 },
        special = { path = "/Game/Gameplay/Character/Player/Attacks/Sword/PA_Attack_Sword_Special.PA_Attack_Sword_Special_C", input = 2 },
    },
    scimitar = {
        normal = { path = "/Game/Gameplay/Character/Player/Attacks/Scimitar/PA_Attack_Scimitar.PA_Attack_Scimitar_C", input = 0 },
        special = { path = "/Game/Gameplay/Character/Player/Attacks/Scimitar/PA_Attack_Scimitar_Special.PA_Attack_Scimitar_Special_C", input = 2 },
    },
    club = {
        normal = { path = "/Game/Gameplay/Character/Player/Attacks/Club/PA_Attack_Club.PA_Attack_Club_C", input = 0 },
        special = { path = "/Game/Gameplay/Character/Player/Attacks/Club/PA_Attack_Club_Special.PA_Attack_Club_Special_C", input = 2 },
    },
    greataxe = {
        normal = { path = "/Game/Gameplay/Character/Player/Attacks/2H_Axe/PA_Attack_GreatAxe.PA_Attack_GreatAxe_C", input = 0 },
        special = { path = "/Game/Gameplay/Character/Player/Attacks/2H_Axe/PA_Attack_Greataxe_Special.PA_Attack_Greataxe_Special_C", input = 2 },
    },
    greatsword = {
        normal = { path = "/Game/Gameplay/Character/Player/Attacks/2H_Greatsword/PA_Attack_2H_Greatsword.PA_Attack_2H_Greatsword_C", input = 0 },
        special = { path = "/Game/Gameplay/Character/Player/Attacks/2H_Greatsword/PA_Attack_2H_Greatsword_Special.PA_Attack_2H_Greatsword_Special_C", input = 2 },
    },
    hammer = {
        normal = { path = "/Game/Gameplay/Character/Player/Attacks/2H_Hammer/PA_Attack_2H_Hammer.PA_Attack_2H_Hammer_C", input = 0 },
        special = { path = "/Game/Gameplay/Character/Player/Attacks/2H_Hammer/PA_Attack_2H_Hammer_Special.PA_Attack_2H_Hammer_Special_C", input = 2 },
    },
    granite_maul = {
        normal = { path = "/Game/Gameplay/Character/Player/Attacks/Granite_Maul/PA_Attack_Granite_Maul.PA_Attack_Granite_Maul_C", input = 0 },
        special = { path = "/Game/Gameplay/Character/Player/Attacks/Granite_Maul/PA_Attack_Granite_Maul_Special.PA_Attack_Granite_Maul_Special_C", input = 2 },
    },
    abyssal_whip = {
        normal = { path = "/Game/Gameplay/Character/Player/Attacks/Unique/AbyssalWhip/PA_Attack_AbyssalWhip.PA_Attack_AbyssalWhip_C", input = 0 },
        special = {
            path = "/Game/Gameplay/Character/Player/Spells/Specials/AbyssalWhip/PA_AbyssalWhip_Special.PA_AbyssalWhip_Special_C",
            input = 2,
            component = "magic",
            special_origin = "melee",
            spell_path = "/Game/Gameplay/Character/Player/Spells/Specials/AbyssalWhip/DA_AbyssalWhip_Special.DA_AbyssalWhip_Special",
        },
    },
    hatchet = {
        normal = { path = "/Game/Gameplay/Character/Player/Attacks/Axe/PA_Attack_Hatchet.PA_Attack_Hatchet_C", input = 0 },
        secondary = { path = "/Game/Gameplay/Character/Player/Attacks/Axe/PA_Attack_Hatchet_Special.PA_Attack_Hatchet_Special_C", input = 1 },
        special = { path = "/Game/Gameplay/Character/Player/Attacks/Axe/PA_Attack_Hatchet_Special.PA_Attack_Hatchet_Special_C", input = 1 },
    },
    longbow = {
        normal = { path = "/Game/Gameplay/Character/Player/Attacks/Bow/PA_Attack_Longbow.PA_Attack_Longbow_C", input = 0 },
    },
    test_bleeding = {
        normal = { path = "/Game/Gameplay/Character/Player/Attacks/test/PA_Attack_TEST_Bleeding.PA_Attack_TEST_Bleeding_C", input = 0 },
    },
    test_burning = {
        normal = { path = "/Game/Gameplay/Character/Player/Attacks/test/PA_Attack_TEST_Burning.PA_Attack_TEST_Burning_C", input = 0 },
    },
    test_poison = {
        normal = { path = "/Game/Gameplay/Character/Player/Attacks/test/PA_Attack_TEST_Poison.PA_Attack_TEST_Poison_C", input = 0 },
    },
    test_shocked = {
        normal = { path = "/Game/Gameplay/Character/Player/Attacks/test/PA_Attack_TEST_Shocked.PA_Attack_TEST_Shocked_C", input = 0 },
    },
}

local PLAYER_RANGED_ACTION_SPECS = {
    bow = {
        normal = { path = "/Game/Gameplay/Character/Player/Attacks/Bow/PA_RangedAttack_Bow.PA_RangedAttack_Bow_C", input = 0, attack_field = "FullAttackData" },
        full = { path = "/Game/Gameplay/Character/Player/Attacks/Bow/PA_RangedAttack_Bow.PA_RangedAttack_Bow_C", input = 0, attack_field = "FullAttackData" },
        quick = { path = "/Game/Gameplay/Character/Player/Attacks/Bow/PA_RangedAttack_Bow.PA_RangedAttack_Bow_C", input = 1, attack_field = "QuickAttackData" },
        secondary = { path = "/Game/Gameplay/Character/Player/Attacks/Bow/PA_RangedAttack_Bow.PA_RangedAttack_Bow_C", input = 1, attack_field = "QuickAttackData" },
    },
    shortbow = {
        normal = { path = "/Game/Gameplay/Character/Player/Attacks/Shortbow/PA_RangedAttack_Shortbow.PA_RangedAttack_Shortbow_C", input = 0, attack_field = "FullAttackData" },
        full = { path = "/Game/Gameplay/Character/Player/Attacks/Shortbow/PA_RangedAttack_Shortbow.PA_RangedAttack_Shortbow_C", input = 0, attack_field = "FullAttackData" },
        quick = { path = "/Game/Gameplay/Character/Player/Attacks/Shortbow/PA_RangedAttack_Shortbow_QuickAction.PA_RangedAttack_Shortbow_QuickAction_C", input = 1, attack_field = "QuickAttackData" },
        secondary = { path = "/Game/Gameplay/Character/Player/Attacks/Shortbow/PA_RangedAttack_Shortbow_QuickAction.PA_RangedAttack_Shortbow_QuickAction_C", input = 1, attack_field = "QuickAttackData" },
    },
    crossbow = {
        normal = { path = "/Game/Gameplay/Character/Player/Attacks/Crossbow/PA_RangedAttack_Crossbow.PA_RangedAttack_Crossbow_C", input = 0, attack_field = "QuickAttackData" },
        quick = { path = "/Game/Gameplay/Character/Player/Attacks/Crossbow/PA_RangedAttack_Crossbow.PA_RangedAttack_Crossbow_C", input = 1, attack_field = "QuickAttackData" },
        secondary = { path = "/Game/Gameplay/Character/Player/Attacks/Crossbow/PA_RangedAttack_Crossbow.PA_RangedAttack_Crossbow_C", input = 1, attack_field = "QuickAttackData" },
        full = { path = "/Game/Gameplay/Character/Player/Attacks/Crossbow/PA_RangedAttack_Crossbow.PA_RangedAttack_Crossbow_C", input = 0, attack_field = "FullAttackData" },
    },
    crystalbow = {
        normal = { path = "/Game/Gameplay/Character/Player/Attacks/Unique/CrystalBow/PA_RangedAttack_CrystalBow.PA_RangedAttack_CrystalBow_C", input = 0, attack_field = "FullAttackData" },
        full = { path = "/Game/Gameplay/Character/Player/Attacks/Unique/CrystalBow/PA_RangedAttack_CrystalBow.PA_RangedAttack_CrystalBow_C", input = 0, attack_field = "FullAttackData" },
        quick = { path = "/Game/Gameplay/Character/Player/Attacks/Unique/CrystalBow/PA_RangedAttack_CrystalBow.PA_RangedAttack_CrystalBow_C", input = 1, attack_field = "QuickAttackData" },
        secondary = { path = "/Game/Gameplay/Character/Player/Attacks/Unique/CrystalBow/PA_RangedAttack_CrystalBow.PA_RangedAttack_CrystalBow_C", input = 1, attack_field = "QuickAttackData" },
        special = {
            path = "/Game/Gameplay/Character/Player/Spells/Specials/CrystalBow/PA_CrystalBow_Special.PA_CrystalBow_Special_C",
            input = 2,
            component = "magic",
            special_origin = "ranged",
            spell_path = "/Game/Gameplay/Character/Player/Spells/Specials/CrystalBow/DA_CrystalBow_Special.DA_CrystalBow_Special",
        },
    },
}

M._magic_attack = M._magic_attack or {}
M._magic_attack.action_specs = {
    magic = {
        normal = {
            path = "/Game/Gameplay/Character/Player/Abilities/AttackSpells/PA_MagicAttack_Primary.PA_MagicAttack_Primary_C",
            input = 0,
            magic_slot = "primary",
            spell_map_field = "EquippedMagicAmmoToPrimaryStarterSpell",
        },
        secondary = {
            path = "/Game/Gameplay/Character/Player/Abilities/AttackSpells/PA_MagicAttack_Secondary.PA_MagicAttack_Secondary_C",
            input = 1,
            magic_slot = "secondary",
            spell_map_field = "EquippedMagicAmmoToSecondaryStarterSpell",
        },
    },
}

M._magic_attack.action_aliases = {
    ["magic"] = "magic", ["spell"] = "magic", ["combat_magic"] = "magic", ["combatmagic"] = "magic",
    ["primarymagic"] = "magic", ["primary_magic"] = "magic", ["pa_magicattack_primary"] = "magic",
    ["secondarymagic"] = "magic", ["secondary_magic"] = "magic", ["pa_magicattack_secondary"] = "magic",
}

local PLAYER_RANGED_ACTION_ALIASES = {
    ["bow"] = "bow", ["longbow"] = "bow", ["pa_rangedattack_bow"] = "bow",
    ["shortbow"] = "shortbow", ["short_bow"] = "shortbow", ["pa_rangedattack_shortbow"] = "shortbow",
    ["pa_rangedattack_shortbow_quickaction"] = "shortbow",
    ["crossbow"] = "crossbow", ["cross_bow"] = "crossbow", ["pa_rangedattack_crossbow"] = "crossbow",
    ["crystalbow"] = "crystalbow", ["crystal_bow"] = "crystalbow", ["pa_rangedattack_crystalbow"] = "crystalbow",
}

local PLAYER_MELEE_ACTION_ALIASES = {
    ["unarmed"] = "unarmed", ["pa_attack_unarmed"] = "unarmed",
    ["dagger"] = "dagger", ["pa_attack_dagger"] = "dagger",
    ["sword"] = "sword", ["pa_attack_sword"] = "sword",
    ["scimitar"] = "scimitar", ["pa_attack_scimitar"] = "scimitar",
    ["club"] = "club", ["pa_attack_club"] = "club",
    ["greataxe"] = "greataxe", ["great_axe"] = "greataxe", ["2h_axe"] = "greataxe",
    ["pa_attack_greataxe"] = "greataxe", ["pa_attack_great_axe"] = "greataxe",
    ["greatsword"] = "greatsword", ["great_sword"] = "greatsword", ["2h_greatsword"] = "greatsword",
    ["pa_attack_2h_greatsword"] = "greatsword",
    ["hammer"] = "hammer", ["2h_hammer"] = "hammer", ["pa_attack_2h_hammer"] = "hammer",
    ["granite_maul"] = "granite_maul", ["granitemaul"] = "granite_maul", ["maul"] = "granite_maul",
    ["pa_attack_granite_maul"] = "granite_maul",
    ["abyssal_whip"] = "abyssal_whip", ["abyssalwhip"] = "abyssal_whip", ["whip"] = "abyssal_whip",
    ["pa_attack_abyssalwhip"] = "abyssal_whip",
    ["hatchet"] = "hatchet", ["woodcut"] = "hatchet", ["woodcutting"] = "hatchet",
    ["pa_attack_hatchet"] = "hatchet",
    ["longbow"] = "longbow", ["pa_attack_longbow"] = "longbow",
    ["test_bleeding"] = "test_bleeding", ["bleeding"] = "test_bleeding", ["pa_attack_test_bleeding"] = "test_bleeding",
    ["test_burning"] = "test_burning", ["burning"] = "test_burning", ["pa_attack_test_burning"] = "test_burning",
    ["test_poison"] = "test_poison", ["poison"] = "test_poison", ["pa_attack_test_poison"] = "test_poison",
    ["test_shocked"] = "test_shocked", ["test_shock"] = "test_shocked", ["shocked"] = "test_shocked",
    ["shock"] = "test_shocked", ["pa_attack_test_shocked"] = "test_shocked",
}

local function strip_class_suffix(value)
    local text = tostring(value or ""):gsub("_C$", "")
    return text:gsub("_special$", "")
end

local function normalized_leaf(value)
    local text = tostring(value or ""):lower()
    local leaf = text:match("([^/.]+)$") or text
    return leaf:gsub("_c$", "")
end

local function parse_attack_input_mode(first, rest)
    local text = (tostring(first or "") .. " " .. tostring(rest or "")):lower()
    if text:find("quick", 1, true) or text:find("snap", 1, true) then return "quick" end
    if text:find("full", 1, true) or text:find("draw", 1, true) or text:find("charged", 1, true) then return "full" end
    if text:find("secondary", 1, true) or text:find("alt", 1, true) then return "secondary" end
    if text:find("special", 1, true) then return "special" end
    if text:find("primary", 1, true) or text:find("normal", 1, true) then return "normal" end
    return nil
end

local function parse_attack_combo_index(text)
    local lower = tostring(text or ""):lower()
    if lower == "" then return nil, false, nil end
    local short_combo_end = lower:find("short", 1, true) ~= nil or lower:find("end", 1, true) ~= nil
    local raw_index = lower:match("%f[%w]combo%s*(%d+)%f[%W]")
        or lower:match("%f[%w]attack%s*(%d+)%f[%W]")
        or lower:match("%f[%w]move%s*(%d+)%f[%W]")
        or lower:match("%f[%d](%d+)%f[%D]")
    if not raw_index then return nil, short_combo_end, nil end
    local index = tonumber(raw_index)
    if not index or index < 1 or index > 20 then return nil, short_combo_end, "combo index must be 1..20" end
    return index, short_combo_end, nil
end

local function token_requests_current_combo(token)
    local lower = tostring(token or ""):lower()
    return lower == "combo" or lower == "attack" or lower == "move"
        or lower:match("^%d+$") ~= nil
        or lower:match("^combo%d+$") ~= nil
        or lower:match("^attack%d+$") ~= nil
        or lower:match("^move%d+$") ~= nil
end

local function text_has_word(text, word)
    return tostring(text or ""):lower():find("%f[%w]" .. tostring(word):lower() .. "%f[%W]") ~= nil
end

local function parse_attack_reset_flags(text)
    local chain = text_has_word(text, "chain") or text_has_word(text, "continue") or text_has_word(text, "noreset") or text_has_word(text, "no_reset")
    local fresh = text_has_word(text, "fresh") or text_has_word(text, "interrupt") or text_has_word(text, "restart")
    local hard_reset = text_has_word(text, "reset") or text_has_word(text, "hardreset") or text_has_word(text, "hard_reset") or text_has_word(text, "state_reset")
    return fresh or hard_reset, hard_reset, chain
end

local function action_key_from_token(token)
    local leaf = normalized_leaf(token)
    local compact = leaf:gsub("[%s%-]+", "_")
    local no_special = strip_class_suffix(compact)
    return M._magic_attack.action_aliases[compact] or M._magic_attack.action_aliases[no_special]
        or PLAYER_RANGED_ACTION_ALIASES[compact] or PLAYER_RANGED_ACTION_ALIASES[no_special]
        or PLAYER_MELEE_ACTION_ALIASES[compact] or PLAYER_MELEE_ACTION_ALIASES[no_special]
end

function M._magic_attack.looks_like_perform_path(path)
    local lower = core.normalize_uclass_path(path):lower()
    return lower:find("pa_magicattack", 1, true) ~= nil
        or lower:find("magicattack", 1, true) ~= nil
        or lower:find("/abilities/attackspells/", 1, true) ~= nil
        or lower:find("/spells/specials/", 1, true) ~= nil
end

function M._magic_attack.action_key_from_path(class_path)
    local lower = core.normalize_uclass_path(class_path):lower()
    if not M._magic_attack.looks_like_perform_path(lower) then return nil, nil end
    if lower:find("crystalbow", 1, true) or lower:find("crystal_bow", 1, true) then return "crystalbow", "special" end
    if lower:find("abyssalwhip", 1, true) or lower:find("abyssal_whip", 1, true) then return "abyssal_whip", "special" end
    if lower:find("secondary", 1, true) then return "magic", "secondary" end
    return "magic", "normal"
end

local function looks_like_ranged_perform_path(path)
    local lower = core.normalize_uclass_path(path):lower()
    return lower:find("pa_rangedattack", 1, true) ~= nil
        or lower:find("rangedattack", 1, true) ~= nil
        or lower:find("shortbow", 1, true) ~= nil
        or lower:find("crossbow", 1, true) ~= nil
        or lower:find("crystalbow", 1, true) ~= nil
        or lower:find("bp_player_bow", 1, true) ~= nil
end

local function action_key_from_ranged_path(class_path)
    local lower = core.normalize_uclass_path(class_path):lower()
    local mode = nil
    if lower:find("quick", 1, true) then mode = "quick" end
    if lower:find("fulldraw", 1, true) or lower:find("full_draw", 1, true) then mode = "full" end
    if lower:find("crystalbow", 1, true) or lower:find("crystal_bow", 1, true) then return "crystalbow", mode or "normal" end
    if lower:find("crossbow", 1, true) or lower:find("cross_bow", 1, true) then return "crossbow", mode or "normal" end
    if lower:find("shortbow", 1, true) or lower:find("short_bow", 1, true) then return "shortbow", mode or "normal" end
    if lower:find("longbow", 1, true) or lower:find("bow", 1, true) then return "bow", mode or "normal" end
    return nil, nil
end

local function action_key_from_attack_data_path(class_path)
    local lower = core.normalize_uclass_path(class_path):lower()
    if looks_like_ranged_perform_path(lower) then return nil, nil, "ranged attacks use a separate projectile path" end
    if lower:find("2h_greatsword", 1, true) or lower:find("greatsword", 1, true) then
        return "greatsword", lower:find("special", 1, true) and "special" or "normal"
    end
    if lower:find("2h_hammer", 1, true) or lower:find("hammer", 1, true) then
        return "hammer", lower:find("special", 1, true) and "special" or "normal"
    end
    if lower:find("granite_maul", 1, true) or lower:find("granitemaul", 1, true) then
        return "granite_maul", lower:find("special", 1, true) and "special" or "normal"
    end
    if lower:find("abyssalwhip", 1, true) or lower:find("abyssal_whip", 1, true) then return "abyssal_whip", "normal" end
    if lower:find("greataxe", 1, true) or lower:find("2h_axe", 1, true) then
        return "greataxe", lower:find("special", 1, true) and "special" or "normal"
    end
    if lower:find("scimitar", 1, true) then return "scimitar", lower:find("special", 1, true) and "special" or "normal" end
    if lower:find("dagger", 1, true) then return "dagger", lower:find("special", 1, true) and "special" or "normal" end
    if lower:find("club", 1, true) then return "club", lower:find("special", 1, true) and "special" or "normal" end
    if lower:find("sword", 1, true) then return "sword", lower:find("special", 1, true) and "special" or "normal" end
    if lower:find("axe_woodcut2", 1, true) then return "hatchet", "secondary" end
    if lower:find("axe_woodcut", 1, true) or lower:find("hatchet", 1, true) then return "hatchet", lower:find("special", 1, true) and "secondary" or "normal" end
    if lower:find("longbow", 1, true) then return "longbow", "normal" end
    if lower:find("test_bleeding", 1, true) then return "test_bleeding", "normal" end
    if lower:find("test_burning", 1, true) then return "test_burning", "normal" end
    if lower:find("test_poison", 1, true) then return "test_poison", "normal" end
    if lower:find("test_shock", 1, true) or lower:find("test_shocked", 1, true) then return "test_shocked", "normal" end
    if lower:find("unarmed", 1, true) then return "unarmed", "normal" end
    return nil, nil, "could not infer action family from attack data path"
end

local function selected_action_spec(action_key, mode)
    local selected_mode = mode or "normal"
    local magic_entry = M._magic_attack.action_specs[action_key or ""]
    if magic_entry then
        local selected = magic_entry[selected_mode]
        if not selected then return nil, "magic action family has no " .. tostring(selected_mode) .. " mode: " .. tostring(action_key) end
        return selected, nil, "magic"
    end
    local ranged_entry = PLAYER_RANGED_ACTION_SPECS[action_key or ""]
    if ranged_entry then
        local selected = ranged_entry[selected_mode]
        if not selected and selected_mode == "normal" then selected = ranged_entry.normal end
        if not selected then return nil, "ranged action family has no " .. tostring(selected_mode) .. " mode: " .. tostring(action_key) end
        return selected, nil, selected.component or "ranged"
    end
    local melee_entry = PLAYER_MELEE_ACTION_SPECS[action_key or ""]
    if melee_entry then
        local selected = melee_entry[selected_mode]
        if not selected and selected_mode == "normal" then selected = melee_entry.normal end
        if not selected then return nil, "melee action family has no " .. tostring(selected_mode) .. " mode: " .. tostring(action_key) end
        return selected, nil, selected.component or "melee"
    end
    return nil, "unknown player action family: " .. tostring(action_key)
end

local function ranged_attack_field_for_mode(mode)
    local selected_mode = mode or "normal"
    if selected_mode == "quick" or selected_mode == "secondary" or selected_mode == "alt" then return "QuickAttackData" end
    return "FullAttackData"
end

local function get_uobject_class(obj)
    obj = core.unwrap_param(obj)
    if not core.is_valid_uobject(obj) then return nil end
    local ok_class, class_obj = pcall(function() return obj:GetClass() end)
    if ok_class and core.is_valid_uobject(class_obj) then return class_obj end
    return nil
end

local function uobject_identity_key(obj)
    obj = core.unwrap_param(obj)
    if type(obj) ~= "userdata" then return nil end
    if not core.is_valid_uobject(obj) then
        local ok_probe = pcall(function() return obj:GetFullName() end)
        if not ok_probe then return nil end
    end
    local probes = {
        function() return obj:GetPathName() end,
        function() return obj:GetFullName() end,
        function() return core.value_label(obj) end,
    }
    for _, probe in ipairs(probes) do
        local ok_probe, value = pcall(probe)
        local text = ok_probe and tostring(value or "") or ""
        if text ~= "" then
            text = text:lower():gsub("^[%w_]+%s+", "")
            text = text:gsub("^class%s+", ""):gsub("^blueprintgeneratedclass%s+", "")
            text = text:gsub("^object%s+", ""):gsub("'", "")
            if text ~= "" then return text end
        end
    end
    return nil
end

local function same_uobject_identity(left, right)
    left = core.unwrap_param(left)
    right = core.unwrap_param(right)
    if left ~= nil and left == right then return true end
    local left_key = uobject_identity_key(left)
    local right_key = uobject_identity_key(right)
    return left_key ~= nil and right_key ~= nil and left_key == right_key
end

local function read_valid_method_or_field(root, method_name, field_name)
    root = core.unwrap_param(root)
    if not core.is_valid_uobject(root) then return nil end
    local ok_method, method = pcall(function() return root[method_name] end)
    if ok_method and method ~= nil then
        local ok_call, value = pcall(function() return root[method_name](root) end)
        if ok_call and core.is_valid_uobject(core.unwrap_param(value)) then return core.unwrap_param(value) end
    end
    local ok_field, value = pcall(function() return root[field_name] end)
    if ok_field and core.is_valid_uobject(core.unwrap_param(value)) then return core.unwrap_param(value) end
    return nil
end

local function read_userdata_method_or_field(root, method_name, field_name)
    root = core.unwrap_param(root)
    if not core.is_valid_uobject(root) then return nil end
    local ok_method, method = pcall(function() return root[method_name] end)
    if ok_method and method ~= nil then
        local ok_call, value = pcall(function() return root[method_name](root) end)
        value = core.unwrap_param(value)
        if ok_call and type(value) == "userdata" then return value end
    end
    local ok_field, value = pcall(function() return root[field_name] end)
    value = core.unwrap_param(value)
    if ok_field and type(value) == "userdata" then return value end
    return nil
end

local function resolve_held_equipment_item(pawn, equipment_hand)
    local equipment = core.get_component(pawn, PLAYER_EQUIPMENT_ALIASES)
    if not equipment then return nil, nil, nil end
    local right_hand = (tonumber(equipment_hand) or 1) ~= 0
    local actor = nil
    if right_hand then
        actor = read_valid_method_or_field(equipment, "GetHeldEquipmentActorRight", "HeldEquipmentActorRight")
    else
        actor = read_valid_method_or_field(equipment, "GetHeldEquipmentActorLeft", "HeldEquipmentActorLeft")
    end
    local item = read_valid_method_or_field(actor, "GetHeldEquipmentItem", "HeldEquipmentItem")
    return item, actor, equipment
end

local function resolve_cached_action_granter(comp)
    local paths = {
        "CurrentAttack.ActionInstance",
        "LastExecutedAttack.ActionInstance",
    }
    for _, path in ipairs(paths) do
        local ok_read, value = core.read_path(comp, path .. ".ActionGranter")
        if ok_read and core.is_valid_uobject(value) then
            local ok_hand, hand = core.read_path(comp, path .. ".EquipmentHand")
            return value, path .. ".ActionGranter", (ok_hand and tonumber(hand)) or nil
        end
    end
    return nil, nil, nil
end

local function resolve_held_equipment_data(held_item, held_actor)
    return read_userdata_method_or_field(held_item, "GetHeldEquipmentData", "HeldEquipmentData")
        or read_userdata_method_or_field(held_actor, "GetHeldEquipmentData", "HeldEquipmentData")
end

local function infer_equipment_hand_for_item(pawn, target_item)
    if not core.is_valid_uobject(target_item) then return nil end
    local left_item = resolve_held_equipment_item(pawn, 0)
    if same_uobject_identity(left_item, target_item) then return 0 end
    local right_item = resolve_held_equipment_item(pawn, 1)
    if same_uobject_identity(right_item, target_item) then return 1 end
    return nil
end

local function resolve_ranged_collection_from_data(source, held_data)
    local ok_class, collection_class = core.read_path(held_data, "RangedAttackCollection")
    if ok_class and core.is_valid_uobject(collection_class) then
        local collection_cdo, cdo_err = core.resolve_class_cdo(collection_class)
        if collection_cdo then return collection_cdo, tostring(source) .. ".RangedAttackCollection" end
        return nil, tostring(source) .. ".RangedAttackCollection CDO failed: " .. tostring(cdo_err)
    end
    return nil, string.format("%s heldData=%s collection=%s", tostring(source), core.value_label(held_data), core.value_label(collection_class))
end

local function resolve_ranged_collection_from_equipment_source(source, held_item, held_actor)
    local held_data = resolve_held_equipment_data(held_item, held_actor)
    local collection, detail = resolve_ranged_collection_from_data(source, held_data)
    if collection then return collection, detail end
    return nil, string.format("%s item=%s actor=%s %s", tostring(source), core.value_label(held_item), core.value_label(held_actor), tostring(detail))
end

local function resolve_ranged_attack_collection(pawn, ranged_comp)
    local attempts = {}

    local ok_cached, cached_collection = core.read_path(ranged_comp, "CachedRangedAttackCollection")
    if ok_cached and core.is_valid_uobject(cached_collection) then return cached_collection, "ranged.CachedRangedAttackCollection" end
    attempts[#attempts + 1] = "ranged.CachedRangedAttackCollection=" .. core.value_label(cached_collection)

    local ok_cached_item, cached_item = core.read_path(ranged_comp, "CachedEquipmentUsed")
    if ok_cached_item and core.is_valid_uobject(cached_item) then
        local collection, detail = resolve_ranged_collection_from_equipment_source("ranged.CachedEquipmentUsed", cached_item, nil)
        if collection then return collection, detail end
        attempts[#attempts + 1] = detail
    end

    local ok_ranged_actor, ranged_actor = core.read_path(ranged_comp, "RangedWeaponActor")
    if ok_ranged_actor and core.is_valid_uobject(ranged_actor) then
        local ranged_item = read_valid_method_or_field(ranged_actor, "GetHeldEquipmentItem", "HeldEquipmentItem")
        local collection, detail = resolve_ranged_collection_from_equipment_source("ranged.RangedWeaponActor", ranged_item, ranged_actor)
        if collection then return collection, detail end
        attempts[#attempts + 1] = detail
    end

    for _, hand in ipairs({ 0, 1 }) do
        local held_item, held_actor = resolve_held_equipment_item(pawn, hand)
        local source = hand == 0 and "equipment.left" or "equipment.right"
        local collection, detail = resolve_ranged_collection_from_equipment_source(source, held_item, held_actor)
        if collection then return collection, detail end
        attempts[#attempts + 1] = detail
    end

    local equipment = core.get_component(pawn, PLAYER_EQUIPMENT_ALIASES)
    if equipment then
        local direct_sources = {
            { source = "equipment.GetHeldEquipmentDataLeft", method = "GetHeldEquipmentDataLeft", field = "HeldEquipmentDataLeft" },
            { source = "equipment.GetHeldEquipmentDataRight", method = "GetHeldEquipmentDataRight", field = "HeldEquipmentDataRight" },
        }
        for _, entry in ipairs(direct_sources) do
            local held_data = read_userdata_method_or_field(equipment, entry.method, entry.field)
            local collection, detail = resolve_ranged_collection_from_data(entry.source, held_data)
            if collection then return collection, detail end
            attempts[#attempts + 1] = detail
        end
    end

    return nil, "no ranged attack collection; tried " .. table.concat(attempts, " | ")
end

local function resolve_action_granter_for_attack(pawn, comp, component_label)
    local attempts = {}
    local function try_item(source, held_item, held_actor, equipment_hand)
        if core.is_valid_uobject(held_item) then
            return held_item, source, equipment_hand
        end
        attempts[#attempts + 1] = string.format("%s item=%s actor=%s", tostring(source), core.value_label(held_item), core.value_label(held_actor))
        return nil, nil, nil
    end

    local function try_held_hand(hand)
        local held_item, held_actor = resolve_held_equipment_item(pawn, hand)
        local source = hand == 0 and "equipment.left.GetHeldEquipmentItem" or "equipment.right.GetHeldEquipmentItem"
        return try_item(source, held_item, held_actor, hand)
    end

    if component_label == "ranged" then
        local cached_granter, cached_path, cached_hand = resolve_cached_action_granter(comp)
        if cached_granter then
            return cached_granter, cached_path, cached_hand or infer_equipment_hand_for_item(pawn, cached_granter) or 0
        end
        attempts[#attempts + 1] = "attack cache ActionGranter=nil"

        local ok_cached_item, cached_item = core.read_path(comp, "CachedEquipmentUsed")
        if ok_cached_item and core.is_valid_uobject(cached_item) then
            return cached_item, "ranged.CachedEquipmentUsed", infer_equipment_hand_for_item(pawn, cached_item) or 0
        end
        attempts[#attempts + 1] = "ranged.CachedEquipmentUsed=" .. core.value_label(cached_item)

        local ok_ranged_actor, ranged_actor = core.read_path(comp, "RangedWeaponActor")
        if ok_ranged_actor and core.is_valid_uobject(ranged_actor) then
            local ranged_item = read_valid_method_or_field(ranged_actor, "GetHeldEquipmentItem", "HeldEquipmentItem")
            local item, source, hand = try_item("ranged.RangedWeaponActor.GetHeldEquipmentItem", ranged_item, ranged_actor, infer_equipment_hand_for_item(pawn, ranged_item) or 0)
            if item then return item, source, hand end
        else
            attempts[#attempts + 1] = "ranged.RangedWeaponActor=" .. core.value_label(ranged_actor)
        end

        local item, source, hand = try_held_hand(0)
        if item then return item, source, hand end
        item, source, hand = try_held_hand(1)
        if item then return item, source, hand end
    else
        local item, source, hand = try_held_hand(1)
        if item then return item, source, hand end
        item, source, hand = try_held_hand(0)
        if item then return item, source, hand end

        local cached_granter, cached_path, cached_hand = resolve_cached_action_granter(comp)
        if cached_granter then
            return cached_granter, cached_path, cached_hand or infer_equipment_hand_for_item(pawn, cached_granter) or 1
        end
        attempts[#attempts + 1] = "attack cache ActionGranter=nil"
    end

    return nil, nil, 1, "HeldEquipmentItem not found; tried " .. table.concat(attempts, " | ") .. "; equip the matching weapon first or use unarmed"
end

local function resolve_ranged_attack_class(pawn, ranged_comp, field_name)
    local collection, source_or_err = resolve_ranged_attack_collection(pawn, ranged_comp)
    if not collection then return nil, source_or_err end
    local ok_attack, attack_class = core.read_path(collection, field_name or "FullAttackData")
    if not ok_attack or not core.is_valid_uobject(attack_class) then
        return nil, string.format("%s unavailable on %s: %s", tostring(field_name or "FullAttackData"), tostring(source_or_err), core.value_label(attack_class))
    end
    return attack_class, tostring(source_or_err) .. "." .. tostring(field_name or "FullAttackData"), collection
end

local function infer_current_action_key(pawn)
    local labels = {}
    local function add_label(prefix, value)
        if value ~= nil then labels[#labels + 1] = tostring(prefix) .. "=" .. core.value_label(value) end
    end

    for _, hand in ipairs({ 1, 0 }) do
        local held_item, held_actor = resolve_held_equipment_item(pawn, hand)
        local held_data = resolve_held_equipment_data(held_item, held_actor)
        local prefix = hand == 0 and "left" or "right"
        add_label(prefix .. ".data", held_data)
        add_label(prefix .. ".actor", held_actor)
        add_label(prefix .. ".item", held_item)
    end

    local ranged = core.get_component(pawn, RANGED_ALIASES)
    if ranged then
        local ok_cached_item, cached_item = core.read_path(ranged, "CachedEquipmentUsed")
        if ok_cached_item then add_label("ranged.cachedItem", cached_item) end
        local ok_ranged_actor, ranged_actor = core.read_path(ranged, "RangedWeaponActor")
        if ok_ranged_actor then add_label("ranged.actor", ranged_actor) end
    end

    if #labels == 0 then return "unarmed", "unarmed" end
    local lower = table.concat(labels, " "):lower()
    if lower:find("greatsword", 1, true) or lower:find("great_sword", 1, true) then return "greatsword", table.concat(labels, " | ") end
    if lower:find("2h_hammer", 1, true) or lower:find("hammer", 1, true) then return "hammer", table.concat(labels, " | ") end
    if lower:find("granite_maul", 1, true) or lower:find("granitemaul", 1, true) then return "granite_maul", table.concat(labels, " | ") end
    if lower:find("abyssalwhip", 1, true) or lower:find("abyssal_whip", 1, true) then return "abyssal_whip", table.concat(labels, " | ") end
    if lower:find("greataxe", 1, true) or lower:find("great_axe", 1, true) or lower:find("2h_axe", 1, true) then return "greataxe", table.concat(labels, " | ") end
    if lower:find("scimitar", 1, true) then return "scimitar", table.concat(labels, " | ") end
    if lower:find("dagger", 1, true) then return "dagger", table.concat(labels, " | ") end
    if lower:find("club", 1, true) then return "club", table.concat(labels, " | ") end
    if lower:find("crystalbow", 1, true) or lower:find("crystal_bow", 1, true) then return "crystalbow", table.concat(labels, " | ") end
    if lower:find("crossbow", 1, true) or lower:find("cross_bow", 1, true) then return "crossbow", table.concat(labels, " | ") end
    if lower:find("shortbow", 1, true) or lower:find("short_bow", 1, true) then return "shortbow", table.concat(labels, " | ") end
    if lower:find("longbow", 1, true) or lower:find("bow", 1, true) then return "bow", table.concat(labels, " | ") end
    if lower:find("hatchet", 1, true) or lower:find("woodcut", 1, true) then return "hatchet", table.concat(labels, " | ") end
    if lower:find("sword", 1, true) then return "sword", table.concat(labels, " | ") end
    return nil, table.concat(labels, " | ")
end

local function resolve_action_cdo(action_path)
    local action_class = core.resolve_uclass(action_path)
    if not action_class then return nil, "action class not found: " .. core.normalize_uclass_path(action_path) end
    local action_cdo, cdo_err = core.resolve_class_cdo(action_class)
    if not action_cdo then return nil, "action CDO failed: " .. tostring(cdo_err) end
    return action_cdo, nil, action_class
end

local function next_player_attack_combo_class(attack_class, prefer_short_end)
    local cdo, cdo_err = core.resolve_class_cdo(attack_class)
    if not cdo then return nil, "attack data CDO failed: " .. tostring(cdo_err) end
    if prefer_short_end then
        local ok_short, short_class = core.read_path(cdo, "NextAttackClassNoRequiredPerk")
        if ok_short and core.is_valid_uobject(short_class) then return short_class, "NextAttackClassNoRequiredPerk" end
        return nil, "short combo end unavailable from " .. core.animation_short_name(core.value_label(attack_class))
    end
    local ok_next, next_class = core.read_path(cdo, "NextAttackClass")
    if ok_next and core.is_valid_uobject(next_class) then return next_class, "NextAttackClass" end
    local ok_fallback, fallback_class = core.read_path(cdo, "NextAttackClassNoRequiredPerk")
    if ok_fallback and core.is_valid_uobject(fallback_class) then return fallback_class, "NextAttackClassNoRequiredPerk" end
    return nil, "no NextAttackClass from " .. core.animation_short_name(core.value_label(attack_class))
end

local function select_player_attack_combo_class(start_class, combo_index, short_combo_end)
    local index = tonumber(combo_index)
    if not index then return start_class, nil end
    if index < 1 then return nil, "combo index must be >= 1" end
    local current = start_class
    local visited = {}
    local start_key = uobject_identity_key(current)
    if start_key then visited[start_key] = 1 end
    for step = 2, index do
        local next_class, next_err = next_player_attack_combo_class(current, short_combo_end and step == index)
        if not next_class then
            return nil, string.format("combo %d unavailable at step %d: %s", index, step, tostring(next_err))
        end
        if same_uobject_identity(next_class, current) then
            return nil, string.format("combo %d unavailable at step %d: combo chain loops at %s", index, step, core.animation_short_name(core.value_label(current)))
        end
        local next_key = uobject_identity_key(next_class)
        if next_key and visited[next_key] then
            return nil, string.format("combo %d unavailable at step %d: combo chain loops back to step %d (%s)", index, step, visited[next_key], core.animation_short_name(core.value_label(next_class)))
        end
        if next_key then visited[next_key] = step end
        current = next_class
    end
    return current, string.format("combo%d%s", index, short_combo_end and "/short" or "")
end

M._magic_attack = M._magic_attack or {}
M._magic_attack.loadout_component_aliases = M._magic_attack.loadout_component_aliases or { "LoadoutComponent", "BP_Components_Loadout", "BP_Components_LoadoutComponent" }
M._magic_attack.release_delay_ms = M._magic_attack.release_delay_ms or 80
M._magic_attack.patch_tag = "magic-chain-v5"

function M._magic_attack.get_dominion_runtime_library()
    local runtime_cdo = M._magic_attack.runtime_cdo
    if runtime_cdo and runtime_cdo.IsValid and runtime_cdo:IsValid() then return runtime_cdo end
    if not StaticFindObject then return nil end
    local ok, obj = pcall(StaticFindObject, "/Script/Dominion.Default__DominionRuntimeBlueprintLibrary")
    if ok and obj and obj.IsValid and obj:IsValid() then
        M._magic_attack.runtime_cdo = obj
        return obj
    end
    return nil
end

function M._magic_attack.is_readable_uobject(value)
    value = core.unwrap_param(value)
    if type(value) ~= "userdata" then return false end
    if core.is_valid_uobject(value) then return true end
    local ok_full, full = pcall(function() return value:GetFullName() end)
    return ok_full and full ~= nil and tostring(full) ~= ""
end

function M._magic_attack.read_readable_method_or_field(root, method_name, field_name)
    root = core.unwrap_param(root)
    if not M._magic_attack.is_readable_uobject(root) then return nil end
    local ok_method, method = pcall(function() return root[method_name] end)
    if ok_method and method ~= nil then
        local ok_call, value = pcall(function() return root[method_name](root) end)
        value = core.unwrap_param(value)
        if ok_call and M._magic_attack.is_readable_uobject(value) then return value end
    end
    local ok_field, value = pcall(function() return root[field_name] end)
    value = core.unwrap_param(value)
    if ok_field and M._magic_attack.is_readable_uobject(value) then return value end
    return nil
end

function M._magic_attack.get_player_controller_for_pawn(pawn)
    local ok_net, feature_net = pcall(require, "feature_net")
    if ok_net and feature_net and feature_net.local_controller then
        local ok_pc, pc = pcall(feature_net.local_controller)
        if ok_pc and M._magic_attack.is_readable_uobject(pc) then return pc, "feature_net.local_controller" end
    end
    local ok_controller, controller = core.read_path(pawn, "Controller")
    if ok_controller and M._magic_attack.is_readable_uobject(controller) then return controller, "pawn.Controller" end
    return nil, "no player controller"
end

function M._magic_attack.get_loadout_component_for_pawn(pawn)
    local pc, pc_source = M._magic_attack.get_player_controller_for_pawn(pawn)
    if not pc then return nil, pc_source end
    local loadout, alias = core.get_component(pc, M._magic_attack.loadout_component_aliases)
    if loadout then return loadout, tostring(pc_source) .. "." .. tostring(alias) end
    return nil, tostring(pc_source) .. ": " .. tostring(alias)
end

function M._magic_attack.resolve_equipped_magic_ammo_data(pawn)
    local loadout, loadout_detail = M._magic_attack.get_loadout_component_for_pawn(pawn)
    if not loadout then return nil, loadout_detail end
    if not loadout.GetEquipmentFromSlot then return nil, tostring(loadout_detail) .. ".GetEquipmentFromSlot missing" end

    local magic_ammo = nil
    local ok_equipment, equipment_or_err = pcall(function() return loadout:GetEquipmentFromSlot(6) end)
    if ok_equipment and M._magic_attack.is_readable_uobject(equipment_or_err) then magic_ammo = equipment_or_err end
    if not magic_ammo then
        return nil, tostring(loadout_detail) .. ".GetEquipmentFromSlot(MagicAmmo1=6)=" .. core.value_label(equipment_or_err)
    end

    local ammo_data = M._magic_attack.read_readable_method_or_field(magic_ammo, "BP_GetMagicAmmoData", "MagicAmmoData")
        or M._magic_attack.read_readable_method_or_field(magic_ammo, "BP_GetAmmoData", "AmmoData")
        or M._magic_attack.read_readable_method_or_field(magic_ammo, "BP_GetItemData", "ItemData")
    if not ammo_data then return nil, "equipped magic ammo data unavailable from " .. core.value_label(magic_ammo) end
    return ammo_data, tostring(loadout_detail) .. ".MagicAmmo1=" .. core.value_label(ammo_data), magic_ammo
end

function M._magic_attack.resolve_spell_from_magic_map(comp, map_field, equipped_ammo_data)
    local ok_map, magic_map = core.read_path(comp, map_field)
    if not ok_map or magic_map == nil then return nil, tostring(map_field) .. " unreadable: " .. tostring(magic_map) end

    if M._magic_attack.is_readable_uobject(equipped_ammo_data) then
        local ok_direct, direct_value = pcall(function() return magic_map[equipped_ammo_data] end)
        direct_value = core.unwrap_param(direct_value)
        if ok_direct and M._magic_attack.is_readable_uobject(direct_value) then return direct_value, tostring(map_field) .. "[equipped]" end
    end

    local entries = {}
    local matched_spell = nil
    local matched_detail = nil
    local ok_each, each_err = pcall(function()
        magic_map:ForEach(function(key_accessor, value_accessor)
            local key = core.unwrap_param(key_accessor)
            local value = core.unwrap_param(value_accessor)
            if M._magic_attack.is_readable_uobject(value) then
                entries[#entries + 1] = { key = key, value = value }
                if M._magic_attack.is_readable_uobject(equipped_ammo_data) and same_uobject_identity(key, equipped_ammo_data) then
                    matched_spell = value
                    matched_detail = tostring(map_field) .. "[" .. core.animation_short_name(core.value_label(key)) .. "]"
                end
            end
        end)
    end)
    if matched_spell then return matched_spell, matched_detail end
    if not ok_each then return nil, tostring(map_field) .. ":ForEach failed: " .. tostring(each_err) end
    if not M._magic_attack.is_readable_uobject(equipped_ammo_data) and #entries == 1 then
        return entries[1].value, tostring(map_field) .. "[only-entry]"
    end

    local sample = {}
    for index = 1, math.min(#entries, 4) do
        sample[#sample + 1] = core.animation_short_name(core.value_label(entries[index].key)) .. "=" .. core.animation_short_name(core.value_label(entries[index].value))
    end
    if M._magic_attack.is_readable_uobject(equipped_ammo_data) then
        return nil, string.format("no starter spell for equipped ammo %s in %s; entries=%s",
            core.animation_short_name(core.value_label(equipped_ammo_data)), tostring(map_field), table.concat(sample, ", "))
    end
    return nil, string.format("equipped magic ammo unavailable and %s has %d entries: %s", tostring(map_field), #entries, table.concat(sample, ", "))
end

function M._magic_attack.magic_slot_from_map_field(map_field)
    local text = tostring(map_field or ""):lower()
    if text:find("secondary", 1, true) then return "secondary" end
    return "primary"
end

function M._magic_attack.magic_element_from_ammo_data(ammo_data)
    local label = core.value_label(ammo_data)
    local element = tostring(label or ""):match("ITEM_Rune_([%w]+)")
    if element and element ~= "" then return element end
    return nil
end

function M._magic_attack.resolve_spell_from_ammo_data(ammo_data, map_field)
    local element = M._magic_attack.magic_element_from_ammo_data(ammo_data)
    if not element then return nil, "ammo element unavailable from " .. core.animation_short_name(core.value_label(ammo_data)) end
    local slot = M._magic_attack.magic_slot_from_map_field(map_field)
    local asset = nil
    if slot == "secondary" then
        asset = "DA_Spell_Secondary_" .. element .. "_HOLD"
    else
        asset = "DA_Spell_Primary_" .. element .. "_01"
    end
    local path = "/Game/Gameplay/Character/Player/Spells/Combat/" .. element .. "/" .. asset .. "." .. asset
    local spell, detail = M._magic_attack.resolve_spell_object_path(path)
    if spell then return spell, "ammo-derived " .. path .. " via " .. tostring(detail) end
    return nil, "ammo-derived " .. path .. " failed: " .. tostring(detail)
end

function M._magic_attack.normalize_magic_starter_spell(spell, equipped_ammo_data, map_field)
    if not spell then return nil, "starter spell unavailable" end
    local path = M._magic_attack.spell_object_path(spell)
    if path then return spell, "starter-path=" .. tostring(path) end
    if M._magic_attack.is_readable_uobject(equipped_ammo_data) then
        local derived_spell, derived_detail = M._magic_attack.resolve_spell_from_ammo_data(equipped_ammo_data, map_field)
        if derived_spell then return derived_spell, tostring(derived_detail) .. " replacing opaque map value=" .. core.animation_short_name(core.value_label(spell)) end
        return spell, "starter opaque; " .. tostring(derived_detail)
    end
    return spell, "starter opaque; no equipped ammo data"
end

function M._magic_attack.resolve_magic_starter_spell(pawn, comp, map_field, action_cdo)
    local attempts = {}
    local equipped_ammo_data, ammo_detail, magic_ammo = M._magic_attack.resolve_equipped_magic_ammo_data(pawn)
    if equipped_ammo_data then
        local spell, map_detail = M._magic_attack.resolve_spell_from_magic_map(comp, map_field, equipped_ammo_data)
        if spell then
            local normalized_spell, normalized_detail = M._magic_attack.normalize_magic_starter_spell(spell, equipped_ammo_data, map_field)
            return normalized_spell, tostring(map_detail) .. " " .. tostring(normalized_detail) .. " ammo=" .. tostring(ammo_detail), magic_ammo
        end
        attempts[#attempts + 1] = tostring(map_detail)
    else
        attempts[#attempts + 1] = tostring(ammo_detail)
        local spell, map_detail = M._magic_attack.resolve_spell_from_magic_map(comp, map_field, nil)
        if spell then
            local normalized_spell, normalized_detail = M._magic_attack.normalize_magic_starter_spell(spell, nil, map_field)
            return normalized_spell, tostring(map_detail) .. " " .. tostring(normalized_detail) .. " ammo=<unresolved>", nil
        end
        attempts[#attempts + 1] = tostring(map_detail)
    end

    local ok_cached, cached_spell = core.read_path(action_cdo, "CachedSpell")
    if ok_cached and M._magic_attack.is_readable_uobject(cached_spell) then return cached_spell, "action.CachedSpell", magic_ammo end
    attempts[#attempts + 1] = "action.CachedSpell=" .. core.value_label(cached_spell)
    return nil, "magic starter spell unavailable; tried " .. table.concat(attempts, " | ")
end

function M._magic_attack.spell_object_path(spell_data)
    spell_data = core.unwrap_param(spell_data)
    if type(spell_data) ~= "userdata" then return nil end
    local probes = {
        function() return spell_data:GetPathName() end,
        function() return spell_data:GetFullName() end,
        function() return core.value_label(spell_data) end,
    }
    for _, probe in ipairs(probes) do
        local ok_probe, value = pcall(probe)
        local text = ok_probe and tostring(value or "") or ""
        local path = text:match("(/Game/[^%s']+)")
        if path and path ~= "" then return path end
    end
    return nil
end

function M._magic_attack.resolve_spell_object_path(path)
    local object_path = tostring(path or "")
    if object_path == "" then return nil, "empty spell path" end
    local wanted_asset = object_path:match("%.([^%.]+)$") or object_path:match("([^/]+)$")
    local loaders = {
        { name = "StaticFindObject", fn = StaticFindObject },
        { name = "LoadObject", fn = LoadObject },
        { name = "LoadAsset", fn = LoadAsset },
    }
    for _, loader in ipairs(loaders) do
        if loader.fn then
            local ok_load, loaded = pcall(loader.fn, object_path)
            if ok_load and M._magic_attack.is_readable_uobject(loaded) then
                return loaded, loader.name
            end
        end
    end
    if FindAllOf and wanted_asset and wanted_asset ~= "" then
        local ok_all, all_spells = pcall(FindAllOf, "DominionSpellData")
        if ok_all and type(all_spells) == "table" then
            for _, candidate in ipairs(all_spells) do
                if M._magic_attack.is_readable_uobject(candidate) then
                    local candidate_path = M._magic_attack.spell_object_path(candidate) or ""
                    local candidate_asset = candidate_path:match("%.([^%.]+)$") or candidate_path:match("([^/]+)$")
                    if candidate_path == object_path or candidate_asset == wanted_asset then
                        return candidate, "FindAllOf(DominionSpellData)"
                    end
                end
            end
        end
    end
    return nil, "spell data not found: " .. object_path
end

function M._magic_attack.resolve_next_numbered_spell(spell_data)
    local path = M._magic_attack.spell_object_path(spell_data)
    if not path then return nil, "spell path unavailable" end
    local package_prefix, object_name = path:match("^(.-/)([^/]+)$")
    local asset_name, object_asset_name = nil, nil
    if object_name then asset_name, object_asset_name = object_name:match("^([^%.]+)%.([^%.]+)$") end
    if not package_prefix or not asset_name or asset_name ~= object_asset_name then
        return nil, "spell path is not a data asset path: " .. tostring(path)
    end
    local name_prefix, digits = asset_name:match("^(.*_)(%d+)$")
    if not name_prefix or not digits then
        return nil, "spell asset has no numeric combo suffix: " .. tostring(asset_name)
    end
    local next_index = tonumber(digits) + 1
    local next_asset = name_prefix .. string.format("%0" .. tostring(#digits) .. "d", next_index)
    local next_path = package_prefix .. next_asset .. "." .. next_asset
    local next_spell, detail = M._magic_attack.resolve_spell_object_path(next_path)
    if next_spell then return next_spell, "asset-sequence " .. next_asset .. " via " .. tostring(detail) end
    return nil, detail
end

function M._magic_attack.next_magic_combo_spell(spell_data)
    local ok_modules, modules = core.read_path(spell_data, "Modules.Modules")
    if not ok_modules or modules == nil then return nil, "Modules.Modules unreadable from " .. core.animation_short_name(core.value_label(spell_data)) end
    local count = core.tarray_count(modules)
    if not count then return nil, "Modules.Modules is not an array on " .. core.animation_short_name(core.value_label(spell_data)) end

    local fallback_spell = nil
    local fallback_detail = nil
    local function inspect_module_index(index)
        local wrapper, ok_item = core.tarray_get(modules, index)
        if not ok_item or wrapper == nil then return nil end
        local ok_module, module = core.read_path(wrapper, "Module")
        if not ok_module or not M._magic_attack.is_readable_uobject(module) then return nil end
        local ok_spell, next_spell = core.read_path(module, "SpellData")
        if ok_spell and M._magic_attack.is_readable_uobject(next_spell) then
            local module_label = core.value_label(module)
            if same_uobject_identity(next_spell, spell_data) then
                local inferred_spell, inferred_detail = M._magic_attack.resolve_next_numbered_spell(spell_data)
                local detail = core.animation_short_name(module_label) .. ".SpellData self-loop; " .. tostring(inferred_detail)
                if inferred_spell then return inferred_spell, detail end
                if module_label:find("SpellModule_Chaining", 1, true) then return next_spell, detail end
                fallback_spell = fallback_spell or next_spell
                fallback_detail = fallback_detail or detail
                return nil
            end
            if module_label:find("SpellModule_Chaining", 1, true) then
                return next_spell, "SpellModule_Chaining.SpellData"
            end
            fallback_spell = fallback_spell or next_spell
            fallback_detail = fallback_detail or (core.animation_short_name(module_label) .. ".SpellData")
        end
        return nil
    end

    for index = 1, count do
        local next_spell, detail = inspect_module_index(index)
        if next_spell then return next_spell, detail end
    end
    for index = 0, count - 1 do
        local next_spell, detail = inspect_module_index(index)
        if next_spell then return next_spell, detail end
    end
    if fallback_spell then return fallback_spell, fallback_detail end
    return nil, "no SpellModule_Chaining.SpellData from " .. core.animation_short_name(core.value_label(spell_data))
end

function M._magic_attack.select_magic_combo_spell(start_spell, combo_index)
    local index = tonumber(combo_index)
    if not index then return start_spell, nil end
    if index < 1 then return nil, "combo index must be >= 1" end
    local current = start_spell
    local visited = {}
    local selected_detail = string.format("combo%d", index)
    local start_key = uobject_identity_key(current)
    if start_key then visited[start_key] = 1 end
    for step = 2, index do
        local next_spell, next_err = M._magic_attack.next_magic_combo_spell(current)
        if not next_spell then
            return nil, string.format("magic combo %d unavailable at step %d: %s", index, step, tostring(next_err))
        end
        local chain_detail = tostring(next_err)
        if same_uobject_identity(next_spell, current) then
            selected_detail = string.format("combo%d/native-chain/%s", index, chain_detail)
            current = next_spell
        else
            selected_detail = string.format("combo%d/%s", index, chain_detail)
            local next_key = uobject_identity_key(next_spell)
            if next_key and visited[next_key] then
                return nil, string.format("magic combo %d unavailable at step %d: combo chain loops back to step %d (%s)", index, step, visited[next_key], core.animation_short_name(core.value_label(next_spell)))
            end
            if next_key then visited[next_key] = step end
            current = next_spell
        end
    end
    return current, selected_detail
end

function M._magic_attack.select_magic_combo_target(start_spell, combo_index)
    local index = tonumber(combo_index)
    if not index then return start_spell, nil, nil end
    if index < 1 then return nil, nil, "combo index must be >= 1" end
    if index == 1 then return start_spell, nil, "combo1" end

    local current = start_spell
    local previous = nil
    local selected_detail = string.format("combo%d", index)
    local visited = {}
    local start_key = uobject_identity_key(current)
    if start_key then visited[start_key] = 1 end
    for step = 2, index do
        previous = current
        local next_spell, next_detail = M._magic_attack.next_magic_combo_spell(current)
        if not next_spell then
            return nil, nil, string.format("magic combo %d unavailable at step %d: %s", index, step, tostring(next_detail))
        end
        local chain_detail = tostring(next_detail)
        if not same_uobject_identity(next_spell, current) then
            local next_key = uobject_identity_key(next_spell)
            if next_key and visited[next_key] then
                return nil, nil, string.format("magic combo %d unavailable at step %d: combo chain loops back to step %d (%s)", index, step,
                    visited[next_key], core.animation_short_name(core.value_label(next_spell)))
            end
            if next_key then visited[next_key] = step end
        end
        selected_detail = string.format("combo%d/%s", index, chain_detail)
        current = next_spell
    end
    return current, previous, selected_detail
end

function M._magic_attack.reset_magic_playback_before_perform(comp, hard_reset)
    local details = {}
    if hard_reset and comp and comp.Server_CancelSpell then
        local ok_cancel, cancel_err = pcall(function() comp:Server_CancelSpell() end)
        details[#details + 1] = ok_cancel and "Server_CancelSpell" or ("Server_CancelSpell failed=" .. tostring(cancel_err))
    end
    local anim, anim_err = core.get_player_anim_instance()
    if anim then
        local ok_stop, stop_err = pcall(function() anim:Montage_Stop(0.0, nil) end)
        details[#details + 1] = ok_stop and "Montage_Stop=0" or ("Montage_Stop failed=" .. tostring(stop_err))
    else
        details[#details + 1] = "Montage_Stop skipped=" .. tostring(anim_err)
    end
    if #details > 0 then
        print("[RSDWTools.attack.perform] magic pre-reset " .. table.concat(details, " | "))
    end
end

function M._magic_attack.state_value_text(root, path)
    local ok_value, value = core.read_path(root, path)
    if not ok_value then return "<read failed: " .. core.first_error_line(value) .. ">" end
    value = core.unwrap_param(value)
    local count = core.tarray_count(value)
    if count then return string.format("%s <array count=%d>", core.value_label(value), count) end
    if type(value) == "userdata" then
        local ok_full, full = pcall(function() return value:GetFullName() end)
        if ok_full and full and tostring(full) ~= "" then return tostring(full) end
        local ok_name, name = pcall(function() return value:GetName() end)
        if ok_name and name and tostring(name) ~= "" then return tostring(name) end
    end
    return core.value_label(value)
end

function M._magic_attack.state_summary(comp)
    local fields = { "bHoldingInput", "LastChainedSpell", "CurrentSpellActor", "SpellAnimationPlayer", "CurrentTargets", "SpellCastingActionInstance" }
    local details = {}
    for _, field in ipairs(fields) do
        details[#details + 1] = tostring(field) .. "=" .. M._magic_attack.state_value_text(comp, field)
    end
    return table.concat(details, ", ")
end

function M._magic_attack.prepare_action_spell_state(comp, action_cdo, spell_data, request)
    local details = {}
    if action_cdo and M._magic_attack.is_readable_uobject(spell_data) then
        local ok_cached, cached_err = pcall(function() action_cdo.CachedSpell = spell_data end)
        details[#details + 1] = ok_cached and ("CachedSpell=" .. core.animation_short_name(core.value_label(spell_data)))
            or ("CachedSpell write failed=" .. core.first_error_line(cached_err))
    end
    if comp and request and M._magic_attack.is_readable_uobject(request.magic_chain_seed_spell) then
        local seed_spell = request.magic_chain_seed_spell
        local ok_chain, chain_err = pcall(function() comp.LastChainedSpell = seed_spell end)
        details[#details + 1] = ok_chain and ("LastChainedSpell=" .. core.animation_short_name(core.value_label(seed_spell)))
            or ("LastChainedSpell seed failed=" .. core.first_error_line(chain_err))
    elseif comp and request and request.reset_before then
        local ok_chain, chain_err = pcall(function() comp.LastChainedSpell = nil end)
        details[#details + 1] = ok_chain and "LastChainedSpell=nil" or ("LastChainedSpell clear failed=" .. core.first_error_line(chain_err))
    end
    if comp then
        local ok_hold, hold_err = pcall(function() comp.bHoldingInput = true end)
        details[#details + 1] = ok_hold and "bHoldingInput=true" or ("bHoldingInput write failed=" .. core.first_error_line(hold_err))
    end
    return table.concat(details, " | ")
end

function M._magic_attack.schedule_action_release(pawn, comp, action_cdo, trigger_data, action_instance, delay_ms)
    if not action_cdo or not action_cdo.OnInputCompleted then return "OnInputCompleted=missing" end
    delay_ms = tonumber(delay_ms) or M._magic_attack.release_delay_ms or 80
    M._magic_attack.release_generation = (M._magic_attack.release_generation or 0) + 1
    local generation = M._magic_attack.release_generation

    local function complete_action()
        if generation ~= M._magic_attack.release_generation then
            print("[RSDWTools.attack.perform] magic action-release skipped stale generation")
            return true
        end
        local before_state = M._magic_attack.state_summary(comp)
        local ok_complete, complete_err = pcall(function()
            action_cdo:OnInputCompleted(pawn, trigger_data, action_instance)
        end)
        local after_state = M._magic_attack.state_summary(comp)
        local release_detail = ok_complete and "OnInputCompleted" or ("OnInputCompleted failed=" .. core.first_error_line(complete_err))
        print(string.format("[RSDWTools.attack.perform] magic action-release %s after %dms | before{%s} after{%s}",
            release_detail, delay_ms, before_state, after_state))
        return true
    end

    if LoopAsync then
        LoopAsync(delay_ms, complete_action)
        return "OnInputCompleted=scheduled(" .. tostring(delay_ms) .. "ms)"
    end

    local ok_now, now_err = pcall(complete_action)
    return ok_now and "OnInputCompleted=immediate(no LoopAsync)" or ("OnInputCompleted immediate failed=" .. core.first_error_line(now_err))
end

function M._magic_attack.trigger_player_action(pawn, comp, action_cdo, spell_data, request)
    if not action_cdo then return false, "magic action CDO unavailable" end
    if not action_cdo.OnInputTriggered then return false, "magic action OnInputTriggered missing: " .. core.value_label(action_cdo) end

    local equipment_hand = request and tonumber(request.equipment_hand) or ((request and request.magic_slot == "secondary") and 0 or 1)
    local action_input = (request and tonumber(request.input)) or 0
    local action_granter = request and request.action_granter or nil
    local action_instance = {
        Data = action_cdo,
        ActionGranter = action_granter,
        PlayerOwner = pawn,
        EquipmentHand = equipment_hand,
        ActionInputType = action_input,
    }
    local trigger_data = {}
    local before_state = M._magic_attack.state_summary(comp)
    local prep_detail = M._magic_attack.prepare_action_spell_state(comp, action_cdo, spell_data, request)
    local pretrigger_detail = "PreTrigger=missing"
    if action_cdo.PreTrigger then
        local ok_pre, pre_err = pcall(function() action_cdo:PreTrigger(pawn) end)
        pretrigger_detail = ok_pre and "PreTrigger" or ("PreTrigger failed=" .. core.first_error_line(pre_err))
    end
    local post_pretrigger_detail = nil
    if request and M._magic_attack.is_readable_uobject(request.magic_chain_target_spell) then
        local target_spell = request.magic_chain_target_spell
        local ok_target, target_err = pcall(function() action_cdo.CachedSpell = target_spell end)
        post_pretrigger_detail = ok_target and ("PostPreTriggerCachedSpell=" .. core.animation_short_name(core.value_label(target_spell)))
            or ("PostPreTriggerCachedSpell failed=" .. core.first_error_line(target_err))
    end

    local ok_trigger, trigger_err = pcall(function()
        action_cdo:OnInputTriggered(pawn, trigger_data, action_instance)
    end)
    if not ok_trigger then return false, "OnInputTriggered failed: " .. core.first_error_line(trigger_err) end

    local complete_detail = M._magic_attack.schedule_action_release(pawn, comp, action_cdo, trigger_data, action_instance, request and request.release_delay_ms)

    local after_state = M._magic_attack.state_summary(comp)
    local pretrigger_text = tostring(pretrigger_detail)
    if post_pretrigger_detail then pretrigger_text = pretrigger_text .. " | " .. tostring(post_pretrigger_detail) end
    local detail = string.format("action=%s spell=%s input=%d hand=%d granter=%s | %s | %s | OnInputTriggered | %s | before{%s} after{%s}",
        core.value_label(action_cdo), core.animation_short_name(core.value_label(spell_data)), action_input, equipment_hand, core.value_label(action_granter),
        tostring(prep_detail), pretrigger_text, tostring(complete_detail), before_state, after_state)
    print("[RSDWTools.attack.perform] magic action-trigger " .. detail)
    return true, detail
end

function M._magic_attack.trigger_modular_ability_direct(pawn, spell_data)
    local runtime = M._magic_attack.get_dominion_runtime_library()
    if not runtime then return false, "DominionRuntimeBlueprintLibrary CDO not found" end
    local trigger_modular_ability = runtime["TriggerModularAbilityForPlayer"]
    if not trigger_modular_ability then return false, "TriggerModularAbilityForPlayer missing" end
    local ok_trigger, trigger_err = pcall(function()
        trigger_modular_ability(runtime, pawn, spell_data)
    end)
    if not ok_trigger then return false, "TriggerModularAbilityForPlayer failed: " .. core.first_error_line(trigger_err) end
    return true, "TriggerModularAbilityForPlayer"
end

function M._magic_attack.resolve_weapon_special_action_granter(pawn, request)
    local origin = request and request.special_origin or nil
    if origin ~= "ranged" then origin = "melee" end
    local component_aliases = origin == "ranged" and RANGED_ALIASES or PLAYER_MELEE_ATTACK_ALIASES
    local comp, alias = core.get_component(pawn, component_aliases)
    if not comp then return nil, nil, nil, alias end
    local granter, source, hand, granter_err = resolve_action_granter_for_attack(pawn, comp, origin)
    if not granter then return nil, nil, nil, granter_err end
    return granter, tostring(source), tonumber(hand) or (origin == "ranged" and 0 or 1), nil
end

function M._magic_attack.perform(pawn, request)
    local comp, alias = core.get_component(pawn, COMBAT_MAGIC_ALIASES)
    if not comp then return false, alias end

    local action_cdo, action_err = resolve_action_cdo(request.action_path)
    if not action_cdo then
        print("[RSDWTools.attack.perform] magic action CDO unavailable: " .. tostring(action_err))
    end

    local starter_spell = nil
    local starter_detail = nil
    if request.spell_path then
        starter_spell, starter_detail = M._magic_attack.resolve_spell_object_path(request.spell_path)
        if not starter_spell then return false, starter_detail end
        local weapon_granter, granter_source, equipment_hand, granter_err = M._magic_attack.resolve_weapon_special_action_granter(pawn, request)
        if not weapon_granter then return false, granter_err end
        request.action_granter = weapon_granter
        request.equipment_hand = equipment_hand
        request.magic_chain_target_spell = starter_spell
        starter_detail = tostring(starter_detail) .. " weaponSpecialGranter=" .. tostring(granter_source) .. " hand=" .. tostring(equipment_hand)
    else
        local magic_ammo_granter = nil
        starter_spell, starter_detail, magic_ammo_granter = M._magic_attack.resolve_magic_starter_spell(pawn, comp, request.spell_map_field, action_cdo)
        if not starter_spell then return false, starter_detail end
        request.action_granter = magic_ammo_granter
    end

    local spell_data = starter_spell
    local ack_spell_data = starter_spell
    if request.combo_index then
        local combo_spell, seed_spell, combo_detail_or_err = M._magic_attack.select_magic_combo_target(starter_spell, request.combo_index)
        if not combo_spell then return false, combo_detail_or_err end
        ack_spell_data = combo_spell
        if tonumber(request.combo_index) and tonumber(request.combo_index) > 1 then
            request.magic_chain_seed_spell = seed_spell
            request.magic_chain_target_spell = combo_spell
            spell_data = combo_spell
            request.detail = string.format("%s/%s/seedLast=%s/target=%s", tostring(request.detail), tostring(combo_detail_or_err),
                core.animation_short_name(core.value_label(seed_spell)), core.animation_short_name(core.value_label(combo_spell)))
        else
            spell_data = combo_spell
            request.detail = string.format("%s/%s", tostring(request.detail), tostring(combo_detail_or_err))
        end
    end
    if request.reset_before then
        M._magic_attack.reset_magic_playback_before_perform(comp, request.hard_reset)
        request.detail = request.detail .. (request.hard_reset and "/reset" or "/fresh")
    end

    local ok_action, action_detail = M._magic_attack.trigger_player_action(pawn, comp, action_cdo, spell_data, request)
    local execution_detail = action_detail
    if not ok_action then
        print("[RSDWTools.attack.perform] magic action-trigger unavailable: " .. tostring(action_detail))
        local ok_direct, direct_detail = M._magic_attack.trigger_modular_ability_direct(pawn, spell_data)
        if not ok_direct then return false, tostring(action_detail) .. " | fallback " .. tostring(direct_detail) end
        execution_detail = tostring(direct_detail) .. " after action-trigger failed: " .. tostring(action_detail)
    end

    local spell_label = core.value_label(ack_spell_data)
    local detail = string.format("%s via %s (%s patch=%s action=%s starter=%s exec=%s)",
        core.animation_short_name(spell_label), alias, tostring(request.detail), tostring(M._magic_attack.patch_tag), core.value_label(action_cdo), tostring(starter_detail), tostring(execution_detail))
    print("[RSDWTools.attack.perform] magic " .. detail)
    return true, detail
end

local function build_player_action_instance(pawn, action_data, action_granter, equipment_hand, action_input_type)
    return {
        Data = action_data,
        ActionGranter = action_granter,
        PlayerOwner = pawn,
        EquipmentHand = equipment_hand or 0,
        ActionInputType = action_input_type or 0,
    }
end

local function rebuild_player_action_instance(pawn, source_instance)
    local ok_data, action_data = core.read_path(source_instance, "Data")
    local ok_granter, action_granter = core.read_path(source_instance, "ActionGranter")
    local ok_owner, player_owner = core.read_path(source_instance, "PlayerOwner")
    local ok_hand, equipment_hand = core.read_path(source_instance, "EquipmentHand")
    local ok_input, action_input_type = core.read_path(source_instance, "ActionInputType")
    if not ok_data or not core.is_valid_uobject(action_data) then return nil, "last action Data unavailable" end
    if not ok_owner or not core.is_valid_uobject(player_owner) then player_owner = pawn end
    if not ok_granter or not core.is_valid_uobject(action_granter) then action_granter = nil end
    return {
        Data = action_data,
        ActionGranter = action_granter,
        PlayerOwner = player_owner,
        EquipmentHand = (ok_hand and tonumber(equipment_hand)) or 1,
        ActionInputType = (ok_input and tonumber(action_input_type)) or 0,
    }, nil
end

local function perform_player_attack(comp, alias, attack_class, action_instance, detail_label, component_label)
    component_label = component_label or "attack"
    if not core.is_valid_uobject(attack_class) then return false, "attack class is invalid" end
    local membership = collection_membership(comp, attack_class)
    if not tostring(membership):find("^yes") then
        return false, "attack class is not in " .. tostring(component_label) .. " AttackDataCollection: " .. tostring(membership)
    end
    local ok_attack, attack_err = pcall(function()
        comp:BP_PerformAttack(attack_class, action_instance)
    end)
    if not ok_attack then return false, "BP_PerformAttack failed: " .. tostring(attack_err) end
    local class_label = core.value_label(attack_class)
    print(string.format("[RSDWTools.attack.perform] %s via %s %s | %s", tostring(detail_label), component_label, alias, class_label))
    return true, string.format("%s via %s (%s)", core.animation_short_name(class_label), alias, tostring(detail_label))
end

local function perform_melee_attack(comp, alias, attack_class, action_instance, detail_label)
    return perform_player_attack(comp, alias, attack_class, action_instance, detail_label, "melee")
end

local function clear_attack_struct_data(comp, struct_path)
    local ok_struct, attack_struct = core.read_path(comp, struct_path)
    if not ok_struct or attack_struct == nil then return tostring(struct_path) .. " unavailable" end
    local before = core.field_text(comp, tostring(struct_path) .. ".AttackData")
    local ok_clear, clear_err = pcall(function() attack_struct.AttackData = nil end)
    if not ok_clear then return tostring(struct_path) .. ".AttackData clear failed=" .. core.first_error_line(clear_err) end
    local after = core.field_text(comp, tostring(struct_path) .. ".AttackData")
    return string.format("%s.AttackData %s -> %s", tostring(struct_path), before, after)
end

local function clear_attack_chain_state(comp)
    local details = {
        clear_attack_struct_data(comp, "CurrentAttack"),
        clear_attack_struct_data(comp, "LastExecutedAttack"),
    }
    return table.concat(details, " | ")
end

local function reset_attack_playback_before_perform(comp, hard_reset)
    local details = {}
    if hard_reset then
        local ok_current, current_attack = core.read_path(comp, "CurrentAttack.AttackData")
        if ok_current and core.is_valid_uobject(current_attack) then
            local ok_end, end_err = pcall(function() comp:AttackEnded() end)
            details[#details + 1] = ok_end and ("AttackEnded=" .. core.animation_short_name(core.value_label(current_attack))) or ("AttackEnded failed=" .. tostring(end_err))
        end
        details[#details + 1] = clear_attack_chain_state(comp)
    end
    local anim, anim_err = core.get_player_anim_instance()
    if anim then
        local ok_stop, stop_err = pcall(function() anim:Montage_Stop(0.0, nil) end)
        details[#details + 1] = ok_stop and "Montage_Stop=0" or ("Montage_Stop failed=" .. tostring(stop_err))
    else
        details[#details + 1] = "Montage_Stop skipped=" .. tostring(anim_err)
    end
    if #details > 0 then
        print("[RSDWTools.attack.perform] pre-reset " .. table.concat(details, " | "))
    end
end

local function perform_last_player_attack(comp, alias, component_label)
    local ok_data, attack_data = core.read_path(comp, "LastExecutedAttack.AttackData")
    local ok_instance, source_instance = core.read_path(comp, "LastExecutedAttack.ActionInstance")
    if not ok_data or not core.is_valid_uobject(attack_data) then return false, "LastExecutedAttack.AttackData unavailable" end
    if not ok_instance or source_instance == nil then return false, "LastExecutedAttack.ActionInstance unavailable" end
    local attack_class = get_uobject_class(attack_data)
    if not attack_class then return false, "LastExecutedAttack.AttackData class unavailable" end
    local pawn = core.get_pawn()
    if not pawn then return false, "no local pawn" end
    local action_instance, instance_err = rebuild_player_action_instance(pawn, source_instance)
    if not action_instance then return false, instance_err end
    return perform_player_attack(comp, alias, attack_class, action_instance, "last", component_label or "attack")
end

local function resolve_attack_perform_request(pawn, first, rest)
    local lower_first = tostring(first or ""):lower()
    local lower_rest = tostring(rest or ""):lower()
    local mode = parse_attack_input_mode(first, rest)
    if first == "" then return nil, "usage: player.attack.perform <current|last|magic|action|attackData> [normal|primary|secondary|special|quick|full|combo#] [fresh|reset|chain]" end
    if lower_first == "last" or lower_rest:find("%f[%w]last%f[%W]") then
        return { kind = "last", component = (lower_rest:find("%f[%w]ranged%f[%W]") and "ranged" or "melee") }
    end

    local action_key = nil
    local attack_class = nil
    local implied_mode = nil
    local component = nil
    local detail = first
    local combo_index = nil
    local combo_short = false
    local combo_err = nil
    local reset_requested, hard_reset, chain_requested = parse_attack_reset_flags(tostring(first or "") .. " " .. tostring(rest or ""))

    if lower_first == "current" or lower_first == "primary" or lower_first == "normal" or lower_first == "secondary" or lower_first == "special"
        or lower_first == "quick" or lower_first == "full" or lower_first == "charged" or token_requests_current_combo(first) then
        action_key, detail = infer_current_action_key(pawn)
        if not action_key then return nil, "could not infer current player weapon: " .. tostring(detail) end
        combo_index, combo_short, combo_err = parse_attack_combo_index(token_requests_current_combo(first) and (tostring(first or "") .. " " .. tostring(rest or "")) or rest)
        if combo_err then return nil, combo_err end
        if lower_first == "secondary" then mode = "secondary" end
        if lower_first == "special" then mode = "special" end
        if lower_first == "quick" then mode = "quick" end
        if lower_first == "full" or lower_first == "charged" then mode = "full" end
        if lower_first == "normal" or lower_first == "primary" then mode = "normal" end
    elseif lower_first:find("bp_player", 1, true) or lower_first:find("/bp_player", 1, true) then
        attack_class = core.resolve_uclass(first)
        if not attack_class then return nil, "attack class not found: " .. core.normalize_uclass_path(first) end
        if looks_like_ranged_perform_path(first) then
            action_key, implied_mode = action_key_from_ranged_path(first)
            component = "ranged"
            if not action_key then return nil, "could not infer ranged action family from attack data" end
        else
            action_key, implied_mode = action_key_from_attack_data_path(first)
            if not action_key then return nil, implied_mode or "could not infer action family from attack data" end
        end
    elseif M._magic_attack.looks_like_perform_path(first) then
        action_key, implied_mode = M._magic_attack.action_key_from_path(first)
        if not action_key then return nil, "could not infer magic action family from action path" end
        component = "magic"
    elseif lower_first:find("/pa_ranged", 1, true) or lower_first:find("pa_ranged", 1, true) then
        action_key, implied_mode = action_key_from_ranged_path(first)
        if not action_key then return nil, "could not infer ranged action family from action path" end
        component = "ranged"
    else
        action_key = action_key_from_token(first)
        if not action_key and first:find("/", 1, true) then
            local ranged_key, ranged_mode = action_key_from_ranged_path(first)
            local magic_key, magic_mode = M._magic_attack.action_key_from_path(first)
            local selected_mode = mode or ranged_mode or "normal"
            if magic_key then selected_mode = mode or magic_mode or "normal" end
            local action_spec = nil
            local spec_component = nil
            if magic_key then
                action_spec, _, spec_component = selected_action_spec(magic_key, selected_mode)
            end
            return {
                kind = "action",
                component = magic_key and (spec_component or "magic") or (ranged_key and "ranged" or "melee"),
                action_key = magic_key or ranged_key,
                action_path = (magic_key and action_spec and action_spec.path) or first,
                mode = selected_mode,
                input = (action_spec and action_spec.input) or (selected_mode == "special" and 2) or (selected_mode == "secondary" and 1) or (selected_mode == "quick" and 1) or 0,
                attack_field = ranged_key and ranged_attack_field_for_mode(selected_mode) or nil,
                spell_map_field = (action_spec and action_spec.spell_map_field) or (magic_key and ((selected_mode == "secondary") and "EquippedMagicAmmoToSecondaryStarterSpell" or "EquippedMagicAmmoToPrimaryStarterSpell") or nil),
                spell_path = action_spec and action_spec.spell_path or nil,
                magic_slot = (action_spec and action_spec.magic_slot) or (magic_key and ((selected_mode == "secondary") and "secondary" or "primary") or nil),
                special_origin = action_spec and action_spec.special_origin or nil,
                equipment_hand = action_spec and action_spec.equipment_hand or nil,
                detail = first,
            }
        end
        if not action_key then return nil, "unknown player action token: " .. tostring(first) end
        combo_index, combo_short, combo_err = parse_attack_combo_index(rest)
        if combo_err then return nil, combo_err end
    end

    local selected_mode = mode or implied_mode or "normal"
    local action_spec, spec_err, spec_component = selected_action_spec(action_key, selected_mode)
    if not action_spec then return nil, spec_err end
    component = action_spec.component or component or spec_component or "melee"
    if combo_index and component == "ranged" then
        return nil, "combo index is only supported for melee and magic attacks"
    end
    if combo_index and component == "melee" and selected_mode ~= "normal" then
        return nil, "combo index is only supported for normal/primary melee attacks; use special without an index"
    end
    if combo_index and component == "magic" and selected_mode ~= "normal" and selected_mode ~= "secondary" then
        return nil, "combo index is only supported for primary/secondary magic attacks"
    end
    return {
        kind = "action",
        component = component,
        action_key = action_key,
        action_path = action_spec.path,
        attack_class = attack_class,
        mode = selected_mode,
        input = action_spec.input,
        attack_field = action_spec.attack_field,
        spell_map_field = action_spec.spell_map_field,
        spell_path = action_spec.spell_path,
        magic_slot = action_spec.magic_slot,
        special_origin = action_spec.special_origin,
        equipment_hand = action_spec.equipment_hand,
        combo_index = combo_index,
        combo_short = combo_short,
        reset_before = (reset_requested or combo_index ~= nil) and not chain_requested,
        hard_reset = hard_reset and not chain_requested,
        detail = string.format("%s/%s", tostring(action_key), tostring(selected_mode)),
    }
end

function M.attack_perform(value_str)
    local text = strip_animation_prefix(value_str, "attack")
    local first, rest = split_animation_arg(text)

    local pawn = core.get_pawn()
    if not pawn then return false, "no local pawn" end

    local request, request_err = resolve_attack_perform_request(pawn, first, rest)
    if not request then return false, request_err end
    local component_label = request.component or "melee"
    if component_label == "magic" then
        if request.kind == "last" then return false, "last is only supported for melee/ranged attack data" end
        return M._magic_attack.perform(pawn, request)
    end
    local component_aliases = component_label == "ranged" and RANGED_ALIASES or PLAYER_MELEE_ATTACK_ALIASES
    local comp, alias = core.get_component(pawn, component_aliases)
    if not comp then return false, alias end
    if not comp.BP_PerformAttack then return false, alias .. ".BP_PerformAttack missing" end
    if request.kind == "last" then return perform_last_player_attack(comp, alias, component_label) end

    local action_cdo, action_err = resolve_action_cdo(request.action_path)
    if not action_cdo then return false, action_err end

    local action_granter = nil
    local action_granter_source = nil
    local equipment_hand = nil
    if request.action_key ~= "unarmed" then
        local resolved_granter, resolved_source, resolved_hand, granter_err = resolve_action_granter_for_attack(pawn, comp, component_label)
        action_granter = resolved_granter
        action_granter_source = resolved_source
        equipment_hand = tonumber(resolved_hand) or 1
        if not action_granter then
            return false, granter_err
        end
        print(string.format("[RSDWTools.attack.perform] using ActionGranter from %s hand=%d: %s", tostring(action_granter_source), tonumber(equipment_hand) or 1, core.value_label(action_granter)))
    end

    local action_instance = build_player_action_instance(pawn, action_cdo, action_granter, equipment_hand or 1, request.input or 0)
    local attack_class = request.attack_class
    if component_label == "ranged" then
        if not attack_class then
            local resolved_attack_class, source_detail = resolve_ranged_attack_class(pawn, comp, request.attack_field or ranged_attack_field_for_mode(request.mode))
            attack_class = core.unwrap_param(resolved_attack_class)
            if not attack_class then return false, source_detail end
            request.detail = string.format("%s/%s", tostring(request.detail), tostring(source_detail))
        end
    elseif not attack_class then
        if not action_cdo.GetAttackDataClass then return false, "action has no GetAttackDataClass: " .. core.value_label(action_cdo) end
        local ok_data, data_class = pcall(function() return action_cdo:GetAttackDataClass(action_instance) end)
        if not ok_data then return false, "GetAttackDataClass failed: " .. tostring(data_class) end
        attack_class = core.unwrap_param(data_class)
        if not core.is_valid_uobject(attack_class) then return false, "GetAttackDataClass returned invalid attack class: " .. core.value_label(data_class) end
    end
    if request.combo_index then
        local combo_class, combo_detail_or_err = select_player_attack_combo_class(attack_class, request.combo_index, request.combo_short)
        if not combo_class then return false, combo_detail_or_err end
        attack_class = core.unwrap_param(combo_class)
        request.detail = string.format("%s/%s", tostring(request.detail), tostring(combo_detail_or_err))
    end
    if request.reset_before then
        reset_attack_playback_before_perform(comp, request.hard_reset)
        request.detail = request.detail .. (request.hard_reset and "/reset" or "/fresh")
    end

    local detail = string.format("%s action=%s granter=%s input=%d",
        tostring(request.detail), core.value_label(action_cdo), core.value_label(action_granter), tonumber(request.input) or 0)
    return perform_player_attack(comp, alias, attack_class, action_instance, detail, component_label)
end

function M.play_attack(value_str)
    local class_path = strip_animation_prefix(value_str, "attack")
    if class_path == "" then return false, "usage: player.attack <UPlayerAttackDataClassPath>" end

    local pawn = core.get_pawn()
    if not pawn then return false, "no local pawn" end

    local attack_class = core.resolve_uclass(class_path)
    if not attack_class then return false, "attack class not found: " .. core.normalize_uclass_path(class_path) end

    local primary_aliases = core.looks_like_ranged_attack(class_path) and RANGED_ALIASES or PLAYER_MELEE_ATTACK_ALIASES
    local fallback_aliases = core.looks_like_ranged_attack(class_path) and PLAYER_MELEE_ATTACK_ALIASES or RANGED_ALIASES

    local comp, alias = core.get_component(pawn, primary_aliases)
    if not comp then
        comp, alias = core.get_component(pawn, fallback_aliases)
    end
    if not comp then return false, alias end
    if not comp.BP_PerformAttack then return false, alias .. ".BP_PerformAttack missing" end

    local action_instance = build_player_action_instance(pawn)
    local ok_attack, attack_err = pcall(function()
        comp:BP_PerformAttack(attack_class, action_instance)
    end)
    if not ok_attack then return false, "BP_PerformAttack failed: " .. tostring(attack_err) end

    local normalized = core.normalize_uclass_path(class_path)
    print(string.format("[RSDWTools] player.attack %s via %s", normalized, alias))
    return true, core.animation_short_name(normalized)
end

return M
