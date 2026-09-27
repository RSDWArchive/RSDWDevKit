-- World-event probes.
--
-- The dumps expose AWorldEventManager:GetWorldEventManagerInstance(...) and
-- AWorldEventManager:StartEvent(TSoftClassPtr<AWorldEvent>, FTransform,
-- TArray<ADominionPlayerCharacter*>, FGameplayTag). These commands explore
-- that path directly, with confirm-gated mutating calls.

local M = {}

local feature_actor = require("feature_actor")
local feature_field = require("feature_field")
local feature_net = require("feature_net")
local player_core = require("feature_player_core")
local mod_paths = require("mod_paths")

local EVENT_ALIASES = {
    base_raid = "/Game/Gameplay/Events/BP_BaseRaidEvent_BM_1.BP_BaseRaidEvent_BM_1_C",
    baseraid = "/Game/Gameplay/Events/BP_BaseRaidEvent_BM_1.BP_BaseRaidEvent_BM_1_C",
    bm1 = "/Game/Gameplay/Events/BP_BaseRaidEvent_BM_1.BP_BaseRaidEvent_BM_1_C",
    bm2 = "/Game/Gameplay/Events/BP_BaseRaidEvent_BM_2.BP_BaseRaidEvent_BM_2_C",
    fh1 = "/Game/Gameplay/Events/BP_BaseRaidEvent_FH_1.BP_BaseRaidEvent_FH_1_C",
    gf1 = "/Game/Gameplay/Events/BP_BaseRaidEvent_GF_1.BP_BaseRaidEvent_GF_1_C",
    gf2 = "/Game/Gameplay/Events/BP_BaseRaidEvent_GF_2.BP_BaseRaidEvent_GF_2_C",
    hunted_bm1 = "/Game/Gameplay/Events/BP_HuntedEvent_BM_1.BP_HuntedEvent_BM_1_C",
    hunted_gf1 = "/Game/Gameplay/Events/BP_HuntedEvent_GF_1.BP_HuntedEvent_GF_1_C",
    hunted_gf2 = "/Game/Gameplay/Events/BP_HuntedEvent_GF_2.BP_HuntedEvent_GF_2_C",
    hunted_rotsworn_skeleton = "/Game/Gameplay/Events/BP_HuntedEvent_RotswornSkeletonAmbush_01.BP_HuntedEvent_RotswornSkeletonAmbush_01_C",
    hunted_rotsworn_zombie = "/Game/Gameplay/Events/BP_HuntedEvent_RotswornZombieAmbush_01.BP_HuntedEvent_RotswornZombieAmbush_01_C",
    hunted_skeleton = "/Game/Gameplay/Events/BP_HuntedEvent_SkeletonAmbush_01.BP_HuntedEvent_SkeletonAmbush_01_C",
    hunted_zombie = "/Game/Gameplay/Events/BP_HuntedEvent_ZombieAmbush_01.BP_HuntedEvent_ZombieAmbush_01_C",
}

local EVENT_CLASS_ALIASES = {
    bp_baseraidevent_bm_1_c = "/Game/Gameplay/Events/BP_BaseRaidEvent_BM_1.BP_BaseRaidEvent_BM_1_C",
    abp_baseraidevent_bm_1_c = "/Game/Gameplay/Events/BP_BaseRaidEvent_BM_1.BP_BaseRaidEvent_BM_1_C",
    bp_baseraidevent_bm_2_c = "/Game/Gameplay/Events/BP_BaseRaidEvent_BM_2.BP_BaseRaidEvent_BM_2_C",
    abp_baseraidevent_bm_2_c = "/Game/Gameplay/Events/BP_BaseRaidEvent_BM_2.BP_BaseRaidEvent_BM_2_C",
    bp_baseraidevent_fh_1_c = "/Game/Gameplay/Events/BP_BaseRaidEvent_FH_1.BP_BaseRaidEvent_FH_1_C",
    abp_baseraidevent_fh_1_c = "/Game/Gameplay/Events/BP_BaseRaidEvent_FH_1.BP_BaseRaidEvent_FH_1_C",
    bp_baseraidevent_gf_1_c = "/Game/Gameplay/Events/BP_BaseRaidEvent_GF_1.BP_BaseRaidEvent_GF_1_C",
    abp_baseraidevent_gf_1_c = "/Game/Gameplay/Events/BP_BaseRaidEvent_GF_1.BP_BaseRaidEvent_GF_1_C",
    bp_baseraidevent_gf_2_c = "/Game/Gameplay/Events/BP_BaseRaidEvent_GF_2.BP_BaseRaidEvent_GF_2_C",
    abp_baseraidevent_gf_2_c = "/Game/Gameplay/Events/BP_BaseRaidEvent_GF_2.BP_BaseRaidEvent_GF_2_C",
    bp_huntedevent_bm_1_c = "/Game/Gameplay/Events/BP_HuntedEvent_BM_1.BP_HuntedEvent_BM_1_C",
    abp_huntedevent_bm_1_c = "/Game/Gameplay/Events/BP_HuntedEvent_BM_1.BP_HuntedEvent_BM_1_C",
    bp_huntedevent_gf_1_c = "/Game/Gameplay/Events/BP_HuntedEvent_GF_1.BP_HuntedEvent_GF_1_C",
    abp_huntedevent_gf_1_c = "/Game/Gameplay/Events/BP_HuntedEvent_GF_1.BP_HuntedEvent_GF_1_C",
    bp_huntedevent_gf_2_c = "/Game/Gameplay/Events/BP_HuntedEvent_GF_2.BP_HuntedEvent_GF_2_C",
    abp_huntedevent_gf_2_c = "/Game/Gameplay/Events/BP_HuntedEvent_GF_2.BP_HuntedEvent_GF_2_C",
    bp_huntedevent_rotswornskeletonambush_01_c = "/Game/Gameplay/Events/BP_HuntedEvent_RotswornSkeletonAmbush_01.BP_HuntedEvent_RotswornSkeletonAmbush_01_C",
    bp_huntedevent_rotswornzombieambush_01_c = "/Game/Gameplay/Events/BP_HuntedEvent_RotswornZombieAmbush_01.BP_HuntedEvent_RotswornZombieAmbush_01_C",
    bp_huntedevent_skeletonambush_01_c = "/Game/Gameplay/Events/BP_HuntedEvent_SkeletonAmbush_01.BP_HuntedEvent_SkeletonAmbush_01_C",
    bp_huntedevent_zombieambush_01_c = "/Game/Gameplay/Events/BP_HuntedEvent_ZombieAmbush_01.BP_HuntedEvent_ZombieAmbush_01_C",
}

local EVENT_ID_ALIASES = {
    base_raid = "base_raid_bm_1",
    baseraid = "base_raid_bm_1",
    bm1 = "base_raid_bm_1",
    bm2 = "base_raid_bm_2",
    fh1 = "base_raid_fh_1",
    gf1 = "base_raid_gf_1",
    gf2 = "base_raid_gf_2",
    hunted_bm1 = "hunted_bm_1",
    hunted_gf1 = "hunted_gf_1",
    hunted_gf2 = "hunted_gf_2",
}

local EVENT_ID_TO_CLASS_PATH = {
    base_raid_bm_1 = EVENT_ALIASES.bm1,
    base_raid_bm_2 = EVENT_ALIASES.bm2,
    base_raid_fh_1 = EVENT_ALIASES.fh1,
    base_raid_gf_1 = EVENT_ALIASES.gf1,
    base_raid_gf_2 = EVENT_ALIASES.gf2,
    hunted_bm_1 = EVENT_ALIASES.hunted_bm1,
    hunted_gf_1 = EVENT_ALIASES.hunted_gf1,
    hunted_gf_2 = EVENT_ALIASES.hunted_gf2,
}

local EVENT_CLASS_PATH_PREFIXES = {
    "/Game/Gameplay/Events/",
    "/Game/Gameplay/Events/Ambush/",
    "/Game/Gameplay/Events/Ambushes/",
    "/Game/Gameplay/Events/AmbushRaid/",
    "/Game/Gameplay/Events/AmbushRaids/",
    "/Game/Gameplay/WorldEvents/",
    "/Game/Gameplay/WorldEvents/Ambush/",
    "/Game/Gameplay/WorldEvents/Ambushes/",
    "/Game/Gameplay/WorldEvents/AmbushRaid/",
    "/Game/Gameplay/WorldEvents/AmbushRaids/",
    "/FutureMajorVersion/Gameplay/Events/",
    "/FutureMajorVersion/Gameplay/Events/Ambush/",
    "/FutureMajorVersion/Gameplay/Events/Ambushes/",
    "/FutureMajorVersion/Gameplay/Events/AmbushRaid/",
    "/FutureMajorVersion/Gameplay/Events/AmbushRaids/",
    "/FutureMajorVersion/Gameplay/WorldEvents/",
    "/FutureMajorVersion/Gameplay/WorldEvents/Ambush/",
    "/FutureMajorVersion/Gameplay/WorldEvents/Ambushes/",
    "/DowdunReach/Gameplay/Events/",
    "/DowdunReach/Gameplay/Events/Ambush/",
    "/DowdunReach/Gameplay/Events/Ambushes/",
    "/DowdunReach/Gameplay/Events/AmbushRaid/",
    "/DowdunReach/Gameplay/Events/AmbushRaids/",
    "/DowdunReach/Gameplay/WorldEvents/",
    "/DowdunReach/Gameplay/WorldEvents/Ambush/",
    "/DowdunReach/Gameplay/WorldEvents/Ambushes/",
    "/Game/DowdunReach/Gameplay/Events/",
    "/Game/DowdunReach/Gameplay/Events/Ambush/",
    "/Game/DowdunReach/Gameplay/Events/Ambushes/",
    "/Game/DowdunReach/Gameplay/WorldEvents/",
}

local AI_CLASS_PATH_ALIASES = {
    BP_AI_MeleeGoblin_Character_C = "/Game/Gameplay/AI/GoblinFaction/MeleeGoblin/BP_AI_MeleeGoblin_Character.BP_AI_MeleeGoblin_Character_C",
    ABP_AI_MeleeGoblin_Character_C = "/Game/Gameplay/AI/GoblinFaction/MeleeGoblin/BP_AI_MeleeGoblin_Character.BP_AI_MeleeGoblin_Character_C",
    BP_AI_RangedGoblin_Character_C = "/Game/Gameplay/AI/GoblinFaction/RangedGoblin/BP_AI_RangedGoblin_Character.BP_AI_RangedGoblin_Character_C",
    ABP_AI_RangedGoblin_Character_C = "/Game/Gameplay/AI/GoblinFaction/RangedGoblin/BP_AI_RangedGoblin_Character.BP_AI_RangedGoblin_Character_C",
    BP_AI_RuntGoblin_Character_C = "/Game/Gameplay/AI/GoblinFaction/MeleeGoblin/RuntGoblinVariant/BP_AI_RuntGoblin_Character.BP_AI_RuntGoblin_Character_C",
    ABP_AI_RuntGoblin_Character_C = "/Game/Gameplay/AI/GoblinFaction/MeleeGoblin/RuntGoblinVariant/BP_AI_RuntGoblin_Character.BP_AI_RuntGoblin_Character_C",
    BP_AI_SentryGoblin_Character_C = "/Game/Gameplay/AI/GoblinFaction/RangedGoblin/SentryGoblin/BP_AI_SentryGoblin_Character.BP_AI_SentryGoblin_Character_C",
    ABP_AI_SentryGoblin_Character_C = "/Game/Gameplay/AI/GoblinFaction/RangedGoblin/SentryGoblin/BP_AI_SentryGoblin_Character.BP_AI_SentryGoblin_Character_C",
}

local LAST_TRIGGER_SCAN = {}
local LAST_SPAWNED_AI = {
    next_batch_id = 1,
    batches = {},
}

local function is_valid(obj)
    return feature_actor.is_valid_object(obj)
end

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function pattern_escape(value)
    return (tostring(value or ""):gsub("([^%w])", "%%%1"))
end

local function first_error_line(value)
    local text = tostring(value or "")
    return text:match("([^\r\n]+)") or text
end

local function object_name(obj)
    if not is_valid(obj) then return "<invalid>" end
    local ok, name = pcall(function() return obj:GetName() end)
    if ok and name and tostring(name) ~= "" then return tostring(name) end
    return "<unnamed>"
end

local function object_class(obj)
    local ok, class_name = pcall(function() return feature_field.class_name_of(obj) end)
    if ok and class_name then return class_name end
    local ok_cls, cls = pcall(function() return obj:GetClass() end)
    if ok_cls and cls ~= nil then
        local ok_name, name = pcall(function() return cls:GetName() end)
        if ok_name and name and tostring(name) ~= "" then return tostring(name) end
    end
    return "<unknown>"
end

local function object_label(obj)
    if not is_valid(obj) then return "<invalid>" end
    return object_name(obj) .. "[" .. object_class(obj) .. "]"
end

local function object_text_method(obj, method_name)
    if not is_valid(obj) then return nil end
    local ok_call, value
    if method_name == "GetFullName" then
        ok_call, value = pcall(function() return obj:GetFullName() end)
    elseif method_name == "GetPathName" then
        ok_call, value = pcall(function() return obj:GetPathName() end)
    elseif method_name == "GetName" then
        ok_call, value = pcall(function() return obj:GetName() end)
    else
        local ok_method, method = pcall(function() return obj[method_name] end)
        if not ok_method or method == nil then return nil end
        ok_call, value = pcall(function() return method(obj) end)
    end
    if not ok_call or value == nil then return nil end
    local text = tostring(value)
    if text ~= "" and text ~= "None" and text ~= "<userdata>" then return text end
    return nil
end

local function object_full_name(obj)
    return object_text_method(obj, "GetFullName")
        or object_text_method(obj, "GetPathName")
        or object_name(obj)
end

local function object_outer(obj)
    if not is_valid(obj) then return nil end
    local ok_outer, outer = pcall(function() return obj:GetOuter() end)
    if ok_outer and is_valid(outer) then return outer end
    return nil
end

local function object_unique_key(obj)
    local full = object_full_name(obj)
    if full and full ~= "" and full ~= "<unnamed>" and full ~= "<invalid>" then return full end
    return tostring(obj)
end

local function soft_path_of_safe(value)
    value = player_core.unwrap_param(value)
    if value == nil or type(value) ~= "userdata" then return nil end
    local object_id_ok, object_id = pcall(function() return value:GetObjectID() end)
    if not object_id_ok or object_id == nil then return nil end
    local asset_name_ok, asset_name = pcall(function() return object_id:GetAssetPathName() end)
    if not asset_name_ok or asset_name == nil then return nil end
    local string_ok, asset_path = pcall(function() return asset_name:ToString() end)
    if not string_ok or type(asset_path) ~= "string" or asset_path == "" or asset_path == "None" then
        return nil
    end
    local sub_ok, sub_path = pcall(function() return object_id:GetSubPathString() end)
    if sub_ok and sub_path ~= nil then
        local sub_string_ok, sub_string = pcall(function() return sub_path:ToString() end)
        if sub_string_ok and type(sub_string) == "string" and sub_string ~= "" then
            return asset_path .. ":" .. sub_string
        end
    end
    return asset_path
end

local function call_text_method(value, method_name)
    if type(value) ~= "userdata" then return nil end
    local ok_method, method = pcall(function() return value[method_name] end)
    if not ok_method or method == nil then return nil end
    local ok_call, result = pcall(function() return method(value) end)
    if not ok_call or result == nil then return nil end
    local text = tostring(result)
    if text ~= "" and text ~= "None" and text ~= "<userdata>" then return text end
    return nil
end

local function path_text(value, path)
    local ok_read, result = player_core.read_path(value, path)
    if not ok_read or result == nil then return nil end
    result = player_core.unwrap_param(result)
    if type(result) == "string" then return result ~= "" and result or nil end
    if type(result) == "boolean" or type(result) == "number" then return tostring(result) end
    if type(result) == "userdata" then
        local soft = soft_path_of_safe(result)
        if soft then return soft end
        for _, method_name in ipairs({ "ToString", "GetName", "GetFullName", "GetAssetName", "GetLongPackageName" }) do
            local text = call_text_method(result, method_name)
            if text then return text end
        end
        local ok_label, label = pcall(function() return player_core.value_label(result) end)
        if ok_label and label and tostring(label) ~= "<userdata>" then return tostring(label) end
    end
    return nil
end

local function value_text(value)
    value = player_core.unwrap_param(value)
    local kind = type(value)
    if value == nil then return "nil" end
    if kind == "boolean" or kind == "number" or kind == "string" then return tostring(value) end
    if kind == "userdata" then
        local soft = soft_path_of_safe(value)
        if soft then return soft end
        if is_valid(value) then return object_label(value) end
        for _, method_name in ipairs({ "ToString", "GetName", "GetFullName", "GetAssetName", "GetLongPackageName" }) do
            local text = call_text_method(value, method_name)
            if text then return text end
        end
        for _, path in ipairs({
            "TagName",
            "AssetPathName",
            "SubPathString",
            "ObjectID.AssetPathName",
            "ObjectID.SubPathString",
            "ObjectID.AssetPath.PackageName",
            "AssetPath.PackageName",
            "SoftObjectPtr.ObjectID.AssetPathName",
            "SoftObjectPtr.ObjectID.SubPathString",
        }) do
            local text = path_text(value, path)
            if text then return text end
        end
    end
    local ok, text = pcall(function() return player_core.value_label(value) end)
    if ok then return tostring(text) end
    return tostring(value)
end

local function json_escape(value)
    local text = tostring(value or "")
    text = text:gsub("\\", "\\\\"):gsub('"', '\\"')
    text = text:gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    text = text:gsub("[%z\1-\8\11\12\14-\31]", "")
    return text
end

local function is_array_table(value)
    local max_index, count = 0, 0
    for key, _ in pairs(value) do
        if type(key) ~= "number" then return false end
        if key > max_index then max_index = key end
        count = count + 1
    end
    return max_index == count
end

local function json_value(value)
    local kind = type(value)
    if value == nil then return "null" end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then return tostring(value) end
    if kind == "string" then return '"' .. json_escape(value) .. '"' end
    if kind ~= "table" then return '"' .. json_escape(tostring(value)) .. '"' end
    local parts = {}
    if is_array_table(value) then
        parts[#parts + 1] = "["
        for i = 1, #value do
            if i > 1 then parts[#parts + 1] = "," end
            parts[#parts + 1] = json_value(value[i])
        end
        parts[#parts + 1] = "]"
    else
        local keys = {}
        for key, _ in pairs(value) do keys[#keys + 1] = tostring(key) end
        table.sort(keys)
        parts[#parts + 1] = "{"
        for i = 1, #keys do
            local key = keys[i]
            if i > 1 then parts[#parts + 1] = "," end
            parts[#parts + 1] = '"' .. json_escape(key) .. '":' .. json_value(value[key])
        end
        parts[#parts + 1] = "}"
    end
    return table.concat(parts)
end

local function write_report(file_stem, report, lines)
    local dir = mod_paths.ipc_dir()
    if not dir then return false, "ipc dir unavailable" end
    pcall(os.execute, ('if not exist "%s" mkdir "%s"'):format(dir, dir))
    local json_path = dir .. "\\" .. file_stem .. ".json"
    local text_path = dir .. "\\" .. file_stem .. ".txt"
    local ok_json, json_result = mod_paths.write_atomic(json_path, json_value(report))
    local ok_text, text_result = mod_paths.write_atomic(text_path, table.concat(lines, "\n") .. "\n")
    if ok_json and ok_text then return true, json_result .. " ; " .. text_result end
    return false, tostring(json_result) .. " ; " .. tostring(text_result)
end

local function container_count(value)
    if type(value) == "table" then return #value end
    if type(value) ~= "userdata" then return 0 end
    local ok_len, len = pcall(function() return #value end)
    if ok_len and type(len) == "number" then return len end
    local ok_num, num = pcall(function() return value:Num() end)
    if ok_num and type(num) == "number" then return num end
    return 0
end

local function container_item(value, index)
    if type(value) == "table" then return value[index] end
    local ok_index, item = pcall(function() return value[index] end)
    if ok_index then return item end
    local ok_get, got = pcall(function() return value:Get(index) end)
    if ok_get then return got end
    return nil
end

local function find_first_valid(class_name)
    if not FindAllOf then return nil end
    local ok, list = pcall(FindAllOf, class_name)
    if not ok or not list then return nil end
    local count = container_count(list)
    for i = 1, count do
        local entry = container_item(list, i)
        if is_valid(entry) then return entry end
    end
    return nil
end

local function find_manager_via_scan()
    for _, class_name in ipairs({ "WorldEventManager", "BP_WorldEventManager_C" }) do
        local manager = find_first_valid(class_name)
        if is_valid(manager) then return manager, "FindAllOf(" .. class_name .. ")" end
    end
    return nil, "not found"
end

local function find_manager_via_static()
    if not StaticFindObject then return nil, "StaticFindObject unavailable" end
    local ok, cdo = pcall(StaticFindObject, "/Script/Dominion.Default__WorldEventManager")
    if not ok or not is_valid(cdo) then return nil, "WorldEventManager CDO not found" end
    local pc = feature_net.local_controller()
    local pawn = feature_net.local_pawn()
    for _, context in ipairs({ pawn, pc }) do
        if is_valid(context) and cdo.GetWorldEventManagerInstance then
            local ok_call, manager = pcall(function() return cdo:GetWorldEventManagerInstance(context) end)
            if ok_call and is_valid(manager) then return manager, "GetWorldEventManagerInstance" end
        end
    end
    return nil, "GetWorldEventManagerInstance returned no manager"
end

local function find_manager()
    local manager, route = find_manager_via_scan()
    if is_valid(manager) then return manager, route end
    return find_manager_via_static()
end

local function actor_location(actor)
    local loc = feature_actor.actor_location(actor)
    if loc then return loc end
    return { X = 0, Y = 0, Z = 0 }
end

local function actor_rotation(actor)
    local rot = feature_actor.actor_rotation(actor)
    if rot then return rot end
    return { Pitch = 0, Yaw = 0, Roll = 0 }
end

local function rotator_to_quat(rot)
    rot = rot or {}
    local pitch = (tonumber(rot.Pitch or rot.X) or 0) * math.pi / 360.0
    local yaw   = (tonumber(rot.Yaw   or rot.Y) or 0) * math.pi / 360.0
    local roll  = (tonumber(rot.Roll  or rot.Z) or 0) * math.pi / 360.0
    local sp, cp = math.sin(pitch), math.cos(pitch)
    local sy, cy = math.sin(yaw), math.cos(yaw)
    local sr, cr = math.sin(roll), math.cos(roll)
    return {
        X = cr * sp * sy - sr * cp * cy,
        Y = -cr * sp * cy - sr * cp * sy,
        Z = cr * cp * sy - sr * sp * cy,
        W = cr * cp * cy + sr * sp * sy,
    }
end

local function build_transform_from_actor(actor)
    local loc = actor_location(actor)
    local rot = actor_rotation(actor)
    return {
        Rotation = rotator_to_quat(rot),
        Translation = { X = loc.X or 0, Y = loc.Y or 0, Z = loc.Z or 0 },
        Scale3D = { X = 1, Y = 1, Z = 1 },
    }
end

local function transform_text(xform)
    local loc = xform and xform.Translation or {}
    return string.format("(%.1f,%.1f,%.1f)", tonumber(loc.X) or 0, tonumber(loc.Y) or 0, tonumber(loc.Z) or 0)
end

local function normalize_event_path(token)
    local raw = trim(token)
    if raw == "" then return "" end
    local key = raw:lower()
    return EVENT_ALIASES[key] or EVENT_CLASS_ALIASES[key] or EVENT_ID_TO_CLASS_PATH[key] or raw
end

local function event_short_class(value)
    local text = trim(value)
    if text == "" or text == "nil" then return "" end
    local short = text:match("([%w_]+_C)$")
        or text:match("%.([%w_]+_C)$")
        or text:match("([%w_]+_C)")
        or text:match("([%w_]+)$")
    if not short or short == "" then return "" end
    if not short:find("_C$") and short:match("^BP_") then short = short .. "_C" end
    return short
end

local function event_asset_path(prefix, short_class)
    local base = trim(short_class):gsub("_C$", "")
    if base == "" then return "" end
    return tostring(prefix or "") .. base .. "." .. base .. "_C"
end

local function add_event_candidate(candidates, seen, path, reason)
    local candidate = trim(path)
    if candidate == "" then return end
    local key = candidate:lower()
    if seen[key] then return end
    seen[key] = true
    candidates[#candidates + 1] = { path = candidate, reason = tostring(reason or "candidate") }
end

local function catalog_event_runtime_path_for_class(short_class)
    local short = trim(short_class)
    if short == "" then return nil end
    local root = mod_paths.mod_root()
    if not root then return nil end
    local body = mod_paths.read_file(root .. "\\json\\SpawnCatalog.json")
    if type(body) ~= "string" or body == "" then return nil end
    local variants = { short }
    if short:sub(1, 1) == "A" then
        variants[#variants + 1] = short:sub(2)
    else
        variants[#variants + 1] = "A" .. short
    end
    local no_c = short:gsub("_C$", "")
    variants[#variants + 1] = no_c
    variants[#variants + 1] = no_c:gsub("^A", "")
    for _, needle in ipairs(variants) do
        if needle and needle ~= "" then
            local pos = body:find('"' .. needle .. '"', 1, true)
            if pos then
                local end_pos = math.min(#body, pos + 2200)
                local chunk = body:sub(pos, end_pos)
                local category = chunk:match('"category"%s*:%s*"([^"]+)"')
                local runtime = chunk:match('"runtimePath"%s*:%s*"([^"]+)"')
                local runtime_lower = tostring(runtime or ""):lower()
                local needle_lower = tostring(needle or ""):lower()
                local short_lower = tostring(short or ""):lower()
                local is_dragon_event =
                    runtime_lower:find("dragonevent", 1, true)
                    or runtime_lower:find("imaruevent", 1, true)
                    or needle_lower:find("dragonevent", 1, true)
                    or short_lower:find("dragonevent", 1, true)
                if runtime and runtime ~= "" and (category == "Event" or runtime:find("/Events/", 1, true) or is_dragon_event) then
                    return runtime, "SpawnCatalog near " .. needle
                end
            end
        end
    end
    return nil
end

local function event_class_candidates(raw_class_path, rec)
    local candidates, seen = {}, {}
    local raw = trim(raw_class_path)
    local persistence = tostring((rec or {}).PersistenceID or ""):lower()
    local direct = normalize_event_path(raw)
    if direct ~= "" then add_event_candidate(candidates, seen, direct, "direct") end
    if persistence ~= "" then
        add_event_candidate(candidates, seen, EVENT_ID_TO_CLASS_PATH[persistence], "definition_id_alias")
    end

    local short = event_short_class(direct ~= "" and direct or raw)
    if short ~= "" then
        add_event_candidate(candidates, seen, EVENT_CLASS_ALIASES[short:lower()], "class_alias")
        local catalog_path, catalog_route = catalog_event_runtime_path_for_class(short)
        add_event_candidate(candidates, seen, catalog_path, catalog_route or "SpawnCatalog")
        for _, prefix in ipairs(EVENT_CLASS_PATH_PREFIXES) do
            add_event_candidate(candidates, seen, event_asset_path(prefix, short), "prefix:" .. prefix)
        end
    end
    return candidates
end

local function definition_class_path(rec)
    rec = rec or {}
    local persistence = tostring(rec.PersistenceID or ""):lower()
    local direct = normalize_event_path(tostring(rec.WorldEventClassPath or rec.WorldEventClass or ""))
    if direct ~= "" and direct:sub(1, 1) == "/" then return direct end
    local by_id = EVENT_ID_TO_CLASS_PATH[persistence]
    if by_id and by_id ~= "" then return by_id end
    return direct
end

local function make_soft_class_ref(class_path)
    local cp = player_core.normalize_uclass_path(class_path)
    local ksl = player_core.get_kismet_system_library()
    if not ksl then return nil, "KismetSystemLibrary CDO not found", cp end
    local ok_path, soft_path = pcall(function() return ksl:MakeSoftClassPath(cp) end)
    if not ok_path or soft_path == nil then return nil, "MakeSoftClassPath failed: " .. first_error_line(soft_path), cp end
    local ok_ref, soft_ref = pcall(function() return ksl:Conv_SoftClassPathToSoftClassRef(soft_path) end)
    if not ok_ref or soft_ref == nil then return nil, "Conv_SoftClassPathToSoftClassRef failed: " .. first_error_line(soft_ref), cp end
    return soft_ref, "soft_ref", cp
end

local function make_gameplay_tag(tag_name)
    local tag = trim(tag_name)
    if tag == "" or tag:lower() == "none" or tag:lower() == "nil" then return nil end
    if FName then
        local ok, fname = pcall(FName, tag)
        if ok and fname ~= nil then return { TagName = fname } end
    end
    return { TagName = tag }
end

local function has_confirm(args)
    return tostring(args or ""):lower():find("%f[%w]confirm%f[%W]") ~= nil
end

local function strip_confirm(args)
    return trim((tostring(args or ""):gsub("%f[%w]confirm%f[%W]", "")))
end

local function split_words(args)
    local words = {}
    for word in tostring(args or ""):gmatch("%S+") do words[#words + 1] = word end
    return words
end

local function truncate_text(value, limit)
    local text = tostring(value or "")
    limit = tonumber(limit) or 240
    if #text <= limit then return text end
    return text:sub(1, limit) .. "...<+" .. tostring(#text - limit) .. " chars>"
end

local function definition_record(def, index)
    local rec = { index = index }
    for _, field in ipairs({
        "DebugName",
        "PersistenceID",
        "WorldEventClass",
        "EventGroupContainer",
        "EventFrequencyScaleTag",
        "bOverrideSpawnTransform",
        "SpawnTransformOverride",
        "Triggers",
    }) do
        local ok, value = pcall(function() return def[field] end)
        rec[field] = ok and value_text(value) or ("<read failed: " .. first_error_line(value) .. ">")
        if ok and field == "WorldEventClass" then
            rec.WorldEventClassPath = soft_path_of_safe(value)
                or path_text(value, "ObjectID.AssetPathName")
                or path_text(value, "SoftObjectPtr.ObjectID.AssetPathName")
                or rec[field]
        end
    end
    return rec
end

local function definition_start_alias(rec)
    local persistence = tostring((rec or {}).PersistenceID or ""):lower()
    for alias, id in pairs(EVENT_ID_ALIASES) do
        if tostring(id):lower() == persistence then return alias end
    end
    if persistence ~= "" and persistence ~= "nil" then return persistence end
    return tostring((rec or {}).index or "")
end

local function definition_kind(rec)
    local text = (tostring((rec or {}).WorldEventClassPath or (rec or {}).WorldEventClass or "")
        .. " " .. tostring((rec or {}).PersistenceID or "")
        .. " " .. tostring((rec or {}).DebugName or "")):lower()
    if text:find("baseraid", 1, true) or text:find("base_raid", 1, true) then return "base_raid" end
    if text:find("huntedevent", 1, true) or text:find("hunted", 1, true) then return "hunted" end
    if text:find("dragonevent", 1, true) or text:find("dragon", 1, true) then return "dragon" end
    return "unknown"
end

local function definition_at(index)
    local manager, route = find_manager()
    if not is_valid(manager) then return nil, nil, nil, "WorldEventManager not found: " .. tostring(route) end
    local ok_defs, defs = pcall(function() return manager.WorldEventDefinitions end)
    if not ok_defs or defs == nil then return nil, nil, nil, "definitions unavailable: " .. tostring(ok_defs and "nil" or first_error_line(defs)) end
    local count = container_count(defs)
    if index < 1 or index > count then return nil, nil, nil, "definition index out of range: " .. tostring(index) .. " > " .. tostring(count) end
    local def = container_item(defs, index)
    if def == nil then return nil, nil, nil, "definition nil at index " .. tostring(index) end
    return manager, def, count, nil, index
end

local function normalize_event_id_token(token)
    local raw = trim(token)
    if raw == "" then return "" end
    return EVENT_ID_ALIASES[raw:lower()] or raw
end

local function definition_by_token(token)
    local raw = trim(token)
    if raw == "" then return nil, nil, nil, "missing definition index/name" end
    local index = tonumber(raw)
    if index then return definition_at(index) end
    local wanted = normalize_event_id_token(raw):lower()
    local manager, route = find_manager()
    if not is_valid(manager) then return nil, nil, nil, "WorldEventManager not found: " .. tostring(route) end
    local ok_defs, defs = pcall(function() return manager.WorldEventDefinitions end)
    if not ok_defs or defs == nil then return nil, nil, nil, "definitions unavailable: " .. tostring(ok_defs and "nil" or first_error_line(defs)) end
    local count = container_count(defs)
    for i = 1, count do
        local def = container_item(defs, i)
        if def ~= nil then
            local rec = definition_record(def, i)
            local persistence = tostring(rec.PersistenceID or ""):lower()
            local debug_name = tostring(rec.DebugName or ""):lower()
            if persistence == wanted or debug_name == wanted or debug_name:gsub("%s+", "_") == wanted then
                return manager, def, count, nil, i
            end
        end
    end
    return nil, nil, nil, "definition not found for token: " .. tostring(raw)
end

local function lua_pattern_escape(text)
    return tostring(text or ""):gsub("([^%w])", "%%%1")
end

local function manager_definitions_json(manager)
    if not is_valid(manager) then return nil, "invalid manager" end
    local ok, value = pcall(function() return manager.DefinitionsJSONData end)
    if not ok then return nil, first_error_line(value) end
    local text = value_text(value)
    if type(text) ~= "string" or text == "" or text == "nil" then return nil, "DefinitionsJSONData empty/unavailable" end
    return text, nil
end

local function find_event_json_block(json_text, event_name)
    if type(json_text) ~= "string" or json_text == "" then return nil end
    local event_pat = '"EventName"%s*:%s*"' .. lua_pattern_escape(event_name) .. '"'
    local start_pos, end_pos = json_text:find(event_pat)
    if not start_pos then return nil end
    local next_pos = json_text:find('"EventName"%s*:%s*"', end_pos + 1)
    if next_pos then return json_text:sub(start_pos, next_pos - 1) end
    return json_text:sub(start_pos)
end

local function parse_event_json_triggers(block)
    local out = {}
    if type(block) ~= "string" then return out end
    for trigger_name, data in block:gmatch('"TriggerName"%s*:%s*"([^"]+)"%s*,%s*"TriggerData"%s*:%s*%{(.-)%}') do
        local current_word = data:match('"CurrentValue"%s*:%s*(%a+)')
        local current = nil
        if current_word == "true" then current = true end
        if current_word == "false" then current = false end
        out[#out + 1] = {
            name = trigger_name,
            current = current,
            current_text = current_word or "<none>",
            trigger_time = data:match('"TriggerTime"%s*:%s*"([^"]+)"') or "<none>",
        }
    end
    return out
end

local function manager_compact_snapshot(manager, event_name)
    local snap = {
        manager = object_label(manager),
        manager_full_name = object_full_name(manager),
        event_name = event_name,
        fields = {},
        event_triggers = {},
    }
    for _, field in ipairs({ "LastEventStartTimespan", "GroupTagToEventStartMap", "WorldEventDefinitions" }) do
        local ok, value = pcall(function() return manager[field] end)
        snap.fields[field] = {
            value = ok and truncate_text(value_text(value), 240) or ("<read failed: " .. first_error_line(value) .. ">"),
            count = (ok and value ~= nil) and container_count(value) or nil,
        }
    end
    local json_text = manager_definitions_json(manager)
    if json_text then
        snap.definitions_json_len = #json_text
        if event_name and event_name ~= "" then
            local block = find_event_json_block(json_text, event_name)
            snap.event_block_found = block ~= nil
            snap.event_triggers = parse_event_json_triggers(block)
        end
    end
    return snap
end

local function active_snapshot(limit)
    local ok, detail = M.active(tostring(limit or 25))
    local count = 0
    if ok and type(detail) == "string" then count = tonumber(detail:match("active=(%d+)")) or 0 end
    return { ok = ok and true or false, detail = tostring(detail), active_count = count }
end

local TRIGGER_EXTRA_FIELDS = {
    "bShouldPrioritizeContext",
    "bRequirePlayersToNotBeInBase",
    "MinRequiredNumberOfPlayersInBase",
    "MaxRangeFromABedToBeConsideredInABase",
    "bOnlyConsiderClaimedBeds",
    "MinRequiredNumberOfPlayersInRegion",
    "RequiredCombatStatus",
    "RequiredShelterStatus",
    "bRequireBossDefeated",
    "AIDataClass",
    "bRequireDragonInWorld",
    "ChanceOfTriggering",
    "TriggeredPeriod",
    "Duration",
    "Since",
    "TagQuery",
    "MinRequiredNumberOfPlayersWithTags",
    "QuestData",
    "bTrueIfCompleted",
    "bCheckQuestState",
    "TestState",
}

local function trigger_value(trigger)
    if not is_valid(trigger) then return nil, "invalid trigger" end
    local ok_method, method = pcall(function() return trigger.GetCurrentValue end)
    if not ok_method or method == nil then return nil, "missing GetCurrentValue" end
    local ok_call, value = pcall(function() return trigger:GetCurrentValue() end)
    if not ok_call then return nil, first_error_line(value) end
    return value and true or false, nil
end

local function triggers_for_definition(def)
    local ok_triggers, triggers = pcall(function() return def.Triggers end)
    if not ok_triggers or triggers == nil then return nil, ok_triggers and "nil" or first_error_line(triggers) end
    return triggers, nil
end

local function trigger_record(trigger, index)
    local outer = object_outer(trigger)
    local rec = {
        index = index,
        name = object_name(trigger),
        class = object_class(trigger),
        label = object_label(trigger),
        full_name = object_full_name(trigger),
        outer = outer and object_label(outer) or "<none>",
        outer_full_name = outer and object_full_name(outer) or "<none>",
    }
    for _, field in ipairs({ "DebugName", "PersistenceID" }) do
        local ok, value = pcall(function() return trigger[field] end)
        rec[field] = ok and value_text(value) or ("<read failed: " .. first_error_line(value) .. ">")
    end
    local current, current_err = trigger_value(trigger)
    rec.current = current
    rec.current_error = current_err
    rec.extra = {}
    for _, field in ipairs(TRIGGER_EXTRA_FIELDS) do
        local ok, value = pcall(function() return trigger[field] end)
        if ok and value ~= nil then
            local text = value_text(value)
            if text ~= "nil" and text ~= "<userdata>" then
                rec.extra[field] = text
            end
        end
    end
    return rec
end

local function trigger_summary_text(rec)
    local extras = {}
    for key, value in pairs(rec.extra or {}) do extras[#extras + 1] = key .. "=" .. tostring(value) end
    table.sort(extras)
    local suffix = #extras > 0 and (" " .. table.concat(extras, " ")) or ""
    return string.format("#%d %s DebugName=%s PersistenceID=%s current=%s%s",
        tonumber(rec.index) or 0,
        tostring(rec.class),
        tostring(rec.DebugName),
        tostring(rec.PersistenceID),
        rec.current_error and ("<err:" .. tostring(rec.current_error) .. ">") or tostring(rec.current),
        suffix)
end

local function get_trigger_selection(def, selection)
    local triggers, err = triggers_for_definition(def)
    if not triggers then return nil, err end
    local count = container_count(triggers)
    local token = trim(selection)
    if token == "" or token:lower() == "all" then
        local out = {}
        for i = 1, count do
            local trigger = container_item(triggers, i)
            if is_valid(trigger) then out[#out + 1] = { index = i, trigger = trigger } end
        end
        return out, nil, count
    end
    local index = tonumber(token)
    if not index then return nil, "trigger selection must be index or all" end
    if index < 1 or index > count then return nil, "trigger index out of range: " .. tostring(index) .. " > " .. tostring(count) end
    local trigger = container_item(triggers, index)
    if not is_valid(trigger) then return nil, "trigger invalid at index " .. tostring(index) end
    return { { index = index, trigger = trigger } }, nil, count
end

function M.probe(args)
    local limit = tonumber(trim(args):match("(%d+)")) or 40
    if limit < 1 then limit = 1 end
    if limit > 200 then limit = 200 end
    local manager, route = find_manager()
    if not is_valid(manager) then return false, "WorldEventManager not found: " .. tostring(route) end

    local report = {
        generated_unix = os.time(),
        manager = object_label(manager),
        route = route,
        definitions = {},
        definition_count = 0,
    }
    local lines = {
        "World Event Probe",
        "manager=" .. report.manager,
        "route=" .. tostring(route),
    }
    local ok_defs, defs = pcall(function() return manager.WorldEventDefinitions end)
    if ok_defs and defs ~= nil then
        local count = container_count(defs)
        report.definition_count = count
        lines[#lines + 1] = "definitions=" .. tostring(count)
        for i = 1, math.min(limit, count) do
            local def = container_item(defs, i)
            local rec = definition_record(def, i)
            report.definitions[#report.definitions + 1] = rec
            lines[#lines + 1] = string.format("#%d DebugName=%s PersistenceID=%s EventClass=%s Group=%s Triggers=%s",
                i,
                tostring(rec.DebugName),
                tostring(rec.PersistenceID),
                tostring(rec.WorldEventClassPath or rec.WorldEventClass),
                tostring(rec.EventGroupContainer),
                tostring(rec.Triggers))
        end
    else
        report.definitions_error = ok_defs and "nil" or first_error_line(defs)
        lines[#lines + 1] = "definitions_error=" .. tostring(report.definitions_error)
    end
    local ok_write, path_or_err = write_report("world_event_probe", report, lines)
    if not ok_write then return false, path_or_err end
    return true, "manager=" .. report.manager .. " definitions=" .. tostring(report.definition_count) .. " wrote " .. path_or_err
end

function M.list(args)
    local limit = tonumber(trim(args):match("(%d+)")) or 80
    if limit < 1 then limit = 1 end
    if limit > 200 then limit = 200 end
    local manager, route = find_manager()
    if not is_valid(manager) then return false, "WorldEventManager not found: " .. tostring(route) end
    local ok_defs, defs = pcall(function() return manager.WorldEventDefinitions end)
    if not ok_defs or defs == nil then return false, "definitions unavailable: " .. tostring(ok_defs and "nil" or first_error_line(defs)) end
    local count = container_count(defs)
    local json_text = manager_definitions_json(manager)
    local report = {
        generated_unix = os.time(),
        manager = object_label(manager),
        route = route,
        definition_count = count,
        shown = math.min(limit, count),
        events = {},
    }
    local lines = {
        "World Event Startable List",
        "manager=" .. report.manager,
        "route=" .. tostring(route),
        "definitions=" .. tostring(count) .. " shown=" .. tostring(report.shown),
        "Use: world.event.startlive <token> confirm",
    }
    for i = 1, math.min(limit, count) do
        local def = container_item(defs, i)
        local rec = definition_record(def, i)
        local event_name = tostring(rec.PersistenceID or "")
        local block = json_text and find_event_json_block(json_text, event_name) or nil
        local triggers = parse_event_json_triggers(block)
        local start_token = definition_start_alias(rec)
        local item = {
            index = i,
            kind = definition_kind(rec),
            start_token = start_token,
            start_command = "world.event.startlive " .. tostring(start_token) .. " confirm",
            definition = rec,
            trigger_count = #triggers,
            triggers = triggers,
        }
        report.events[#report.events + 1] = item
        local trigger_bits = {}
        for _, trigger in ipairs(triggers) do
            trigger_bits[#trigger_bits + 1] = tostring(trigger.name) .. "=" .. tostring(trigger.current_text)
        end
        lines[#lines + 1] = string.format("#%d [%s] token=%s DebugName=%s PersistenceID=%s Class=%s triggers=%d %s",
            i,
            tostring(item.kind),
            tostring(start_token),
            tostring(rec.DebugName),
            tostring(rec.PersistenceID),
            tostring(rec.WorldEventClassPath or rec.WorldEventClass),
            #triggers,
            #trigger_bits > 0 and ("[" .. table.concat(trigger_bits, ", ") .. "]") or "")
    end
    local ok_write, path_or_err = write_report("world_event_list", report, lines)
    local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
    return true, string.format("definitions=%d shown=%d%s", count, math.min(limit, count), wrote)
end

function M.definition(args)
    local index = tonumber(trim(args):match("(%d+)")) or 1
    if index < 1 then index = 1 end
    local _manager, def, count, err = definition_at(index)
    if not def then return false, err end
    local rec = definition_record(def, index)
    return true, string.format(
        "#%d/%d DebugName=%s PersistenceID=%s EventClass=%s Group=%s Frequency=%s Override=%s Triggers=%s",
        index,
        count,
        tostring(rec.DebugName),
        tostring(rec.PersistenceID),
        tostring(rec.WorldEventClassPath or rec.WorldEventClass),
        tostring(rec.EventGroupContainer),
        tostring(rec.EventFrequencyScaleTag),
        tostring(rec.bOverrideSpawnTransform),
        tostring(rec.Triggers))
end

function M.definition_state(args)
    local token = trim(args)
    if token == "" then return false, "usage: world.event.defstate <definition_index|persistence_id|alias>" end
    local manager, def, count, err, index = definition_by_token(token)
    if not def then return false, err end
    local rec = definition_record(def, index or 0)
    local event_name = tostring(rec.PersistenceID or "")
    local json_text, json_err = manager_definitions_json(manager)
    local block = json_text and find_event_json_block(json_text, event_name) or nil
    local triggers = parse_event_json_triggers(block)
    local report = {
        generated_unix = os.time(),
        definition_index = index,
        definition_count = count,
        definition = rec,
        event_name = event_name,
        manager = object_label(manager),
        manager_full_name = object_full_name(manager),
        definitions_json_error = json_err,
        event_block_found = block ~= nil,
        triggers = triggers,
    }
    local lines = {
        "World Event Definition State",
        string.format("definition #%s/%s DebugName=%s PersistenceID=%s EventClass=%s",
            tostring(index or "?"),
            tostring(count or "?"),
            tostring(rec.DebugName),
            tostring(rec.PersistenceID),
            tostring(rec.WorldEventClassPath or rec.WorldEventClass)),
        "manager=" .. object_label(manager),
        "manager_full=" .. tostring(object_full_name(manager)),
        "event_block_found=" .. tostring(block ~= nil),
    }
    if json_err then lines[#lines + 1] = "definitions_json_error=" .. tostring(json_err) end
    if #triggers == 0 then
        lines[#lines + 1] = "triggers=<none parsed>"
    else
        for i, trigger in ipairs(triggers) do
            lines[#lines + 1] = string.format("#%d %s current=%s trigger_time=%s",
                i,
                tostring(trigger.name),
                tostring(trigger.current_text),
                tostring(trigger.trigger_time))
        end
    end
    local ok_write, path_or_err = write_report("world_event_defstate", report, lines)
    local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
    return true, string.format("#%s %s triggers=%d block=%s%s",
        tostring(index or "?"),
        tostring(event_name),
        #triggers,
        tostring(block ~= nil),
        wrote)
end

function M.triggers(args)
    local index = tonumber(trim(args):match("(%d+)")) or 1
    if index < 1 then index = 1 end
    local _manager, def, count, err = definition_at(index)
    if not def then return false, err end
    local rec = definition_record(def, index)
    local report = {
        generated_unix = os.time(),
        definition_index = index,
        definition_count = count,
        definition = rec,
        note = "Direct FWorldEventDefinition.Triggers enumeration disabled after native crash; use world.event.triggerscan.",
    }
    local lines = {
        "World Event Trigger Definition Probe",
        string.format("definition #%d/%d DebugName=%s PersistenceID=%s EventClass=%s",
            index,
            count,
            tostring(rec.DebugName),
            tostring(rec.PersistenceID),
            tostring(rec.WorldEventClassPath or rec.WorldEventClass)),
        "TriggersField=" .. tostring(rec.Triggers),
        "note=direct Triggers TArray enumeration is unsafe in UE4SS here; use world.event.triggerscan [limit] [fields|value|full]",
    }
    local ok_write, path_or_err = write_report("world_event_triggers", report, lines)
    local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
    return true, string.format("#%d/%d %s TriggersField=%s ; direct enumeration disabled after native crash ; use world.event.triggerscan%s",
        index,
        count,
        tostring(rec.DebugName),
        tostring(rec.Triggers),
        wrote)
end

function M.manager_state(args)
    local manager, route = find_manager()
    if not is_valid(manager) then return false, "WorldEventManager not found: " .. tostring(route) end
    local fields = {}
    for _, field in ipairs({
        "LastEventStartTimespan",
        "GroupTagToEventStartMap",
        "DefinitionsJSONData",
        "WorldEventDefinitions",
    }) do
        local ok, value = pcall(function() return manager[field] end)
        local text = ok and value_text(value) or ("<read failed: " .. first_error_line(value) .. ">")
        local count = nil
        if ok and value ~= nil then count = container_count(value) end
        fields[#fields + 1] = {
            name = field,
            value = truncate_text(text, 600),
            count = count,
        }
    end
    local report = {
        generated_unix = os.time(),
        route = route,
        manager = object_label(manager),
        manager_full_name = object_full_name(manager),
        fields = fields,
    }
    local lines = {
        "World Event Manager State",
        "manager=" .. object_label(manager),
        "full=" .. tostring(object_full_name(manager)),
        "route=" .. tostring(route),
    }
    for _, rec in ipairs(fields) do
        local count_suffix = rec.count and (" count=" .. tostring(rec.count)) or ""
        lines[#lines + 1] = tostring(rec.name) .. "=" .. tostring(rec.value) .. count_suffix
    end
    local ok_write, path_or_err = write_report("world_event_managerstate", report, lines)
    local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
    return true, string.format("manager=%s route=%s%s", object_label(manager), tostring(route), wrote)
end

local TRIGGER_CLASSES = {
    "WorldEventTrigger",
    "TimerBasedWorldEventTrigger",
    "AfterDurationWorldEventTrigger",
    "BossDefeatedWorldEventTrigger",
    "DragonPresenceWorldEventTrigger",
    "LastEventCooldownWorldEventTrigger",
    "PeriodicPercentageChanceWorldEventTrigger",
    "PlayersHaveTagWorldEventTrigger",
    "PlayersInBaseWorldEventTrigger",
    "PlayersInRegionWorldEventTrigger",
    "QuestCheckWorldEventTrigger",
    "TimeOfDayWorldEventTrigger",
}

local function add_trigger_extra_fields(rec, trigger)
    rec.extra = {}
    for _, field in ipairs(TRIGGER_EXTRA_FIELDS) do
        local ok, value = pcall(function() return trigger[field] end)
        if ok and value ~= nil then
            local text = value_text(value)
            if text ~= "nil" and text ~= "<userdata>" then
                rec.extra[field] = text
            end
        end
    end
end

local function light_trigger_record(trigger, index, mode)
    local outer = object_outer(trigger)
    local rec = {
        index = index,
        name = object_name(trigger),
        class = object_class(trigger),
        label = object_label(trigger),
        full_name = object_full_name(trigger),
        outer = outer and object_label(outer) or "<none>",
        outer_full_name = outer and object_full_name(outer) or "<none>",
        key = object_unique_key(trigger),
    }
    if mode == "fields" or mode == "value" or mode == "full" then
        for _, field in ipairs({ "DebugName", "PersistenceID" }) do
            local ok, value = pcall(function() return trigger[field] end)
            rec[field] = ok and value_text(value) or ("<read failed: " .. first_error_line(value) .. ">")
        end
    end
    if mode == "value" or mode == "full" then
        local current, current_err = trigger_value(trigger)
        rec.current = current
        rec.current_error = current_err
    end
    if mode == "full" then add_trigger_extra_fields(rec, trigger) end
    return rec
end

local function light_trigger_line(rec, mode)
    local parts = {
        "#" .. tostring(rec.index),
        tostring(rec.label),
    }
    if mode == "fields" or mode == "value" or mode == "full" then
        parts[#parts + 1] = "DebugName=" .. tostring(rec.DebugName)
        parts[#parts + 1] = "PersistenceID=" .. tostring(rec.PersistenceID)
    end
    if mode == "value" or mode == "full" then
        parts[#parts + 1] = "current=" .. (rec.current_error and ("<err:" .. tostring(rec.current_error) .. ">") or tostring(rec.current))
    end
    if mode == "full" then
        local extras = {}
        for key, value in pairs(rec.extra or {}) do extras[#extras + 1] = key .. "=" .. tostring(value) end
        table.sort(extras)
        parts[#parts + 1] = "full=" .. tostring(rec.full_name)
        parts[#parts + 1] = "outer=" .. tostring(rec.outer_full_name)
        if #extras > 0 then parts[#parts + 1] = "extra{" .. table.concat(extras, ",") .. "}" end
    end
    return table.concat(parts, " ")
end

local function collect_trigger_objects(limit, mode)
    local seen, out, notes = {}, {}, {}
    if not FindAllOf then return out, { "FindAllOf unavailable" } end
    for _, class_name in ipairs(TRIGGER_CLASSES) do
        local ok_find, list = pcall(FindAllOf, class_name)
        if ok_find and list ~= nil then
            local count = container_count(list)
            notes[#notes + 1] = class_name .. "=" .. tostring(count)
            for i = 1, count do
                local trigger = container_item(list, i)
                if is_valid(trigger) then
                    local key = object_unique_key(trigger)
                    if not seen[key] then
                        seen[key] = true
                        out[#out + 1] = trigger
                        if limit and #out >= limit then return out, notes end
                    end
                end
            end
        else
            notes[#notes + 1] = class_name .. "=<err:" .. first_error_line(list) .. ">"
        end
    end
    return out, notes
end

function M.trigger_scan(args)
    local words = split_words(args)
    local limit = tonumber(words[1] or "") or 80
    if limit < 1 then limit = 1 end
    if limit > 250 then limit = 250 end
    local mode = tostring(words[2] or "light"):lower()
    if mode ~= "light" and mode ~= "fields" and mode ~= "value" and mode ~= "full" then mode = "light" end

    local triggers, notes = collect_trigger_objects(limit, mode)
    LAST_TRIGGER_SCAN = {}
    local report = {
        generated_unix = os.time(),
        mode = mode,
        trigger_count = #triggers,
        class_notes = notes,
        triggers = {},
    }
    local lines = {
        "World Event Trigger Object Scan",
        "mode=" .. mode,
        "found=" .. tostring(#triggers),
        "classes=" .. table.concat(notes or {}, " ; "),
    }
    for i, trigger in ipairs(triggers) do
        LAST_TRIGGER_SCAN[i] = trigger
        local rec = light_trigger_record(trigger, i, mode)
        report.triggers[#report.triggers + 1] = rec
        lines[#lines + 1] = light_trigger_line(rec, mode)
    end
    local ok_write, path_or_err = write_report("world_event_triggerscan", report, lines)
    local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
    return true, string.format("trigger objects found=%d mode=%s%s", #triggers, mode, wrote)
end

local function trigger_from_scan_index(index)
    local trigger = LAST_TRIGGER_SCAN[tonumber(index or 0) or 0]
    if is_valid(trigger) then return trigger, nil end
    return nil, "no cached trigger at index " .. tostring(index) .. " ; run world.event.triggerscan first"
end

function M.trigger_value(args)
    local index = tonumber(trim(args):match("(%d+)"))
    if not index then return false, "usage: world.event.triggervalue <scan_index>" end
    local trigger, err = trigger_from_scan_index(index)
    if not trigger then return false, err end
    local rec = light_trigger_record(trigger, index, "value")
    return true, light_trigger_line(rec, "value")
end

local function parse_trigger_mutation(args, usage)
    local raw = trim(args)
    if raw == "" then return nil, usage end
    if not has_confirm(raw) then return nil, usage .. " confirm" end
    local clean = strip_confirm(raw)
    local words = split_words(clean)
    local def_index = tonumber(words[1] or "")
    if not def_index then return nil, usage end
    local selection = words[2] or "all"
    local state_word = tostring(words[3] or "on"):lower()
    local enabled = nil
    if state_word == "on" or state_word == "true" or state_word == "1" then enabled = true end
    if state_word == "off" or state_word == "false" or state_word == "0" then enabled = false end
    if enabled == nil then return nil, usage end
    return { definition_index = def_index, selection = selection, enabled = enabled }, nil
end

function M.fire_trigger(args)
    return false, "disabled: direct FWorldEventDefinition.Triggers enumeration caused a native crash; use world.event.triggerscan then world.event.fireobject <scan_index> <on|off> confirm"
end

function M.fire_object(args)
    local raw = trim(args)
    if raw == "" then return false, "usage: world.event.fireobject <scan_index> <on|off> confirm" end
    if not has_confirm(raw) then return false, "world.event.fireobject is mutating; append confirm" end
    local clean = strip_confirm(raw)
    local words = split_words(clean)
    local index = tonumber(words[1] or "")
    if not index then return false, "usage: world.event.fireobject <scan_index> <on|off> confirm" end
    local state_word = tostring(words[2] or "on"):lower()
    local enabled = nil
    if state_word == "on" or state_word == "true" or state_word == "1" then enabled = true end
    if state_word == "off" or state_word == "false" or state_word == "0" then enabled = false end
    if enabled == nil then return false, "usage: world.event.fireobject <scan_index> <on|off> confirm" end
    local trigger, err = trigger_from_scan_index(index)
    if not trigger then return false, err end
    local attempts = {}
    local before, before_err = trigger_value(trigger)
    local ok_fire, fire_err = pcall(function()
        return trigger:FireWorldEventTrigger(enabled)
    end)
    local after, after_err = trigger_value(trigger)
    attempts[#attempts + 1] = string.format("#%d %s before=%s after=%s fire=%s",
        index,
        object_label(trigger),
        before_err and ("<err:" .. tostring(before_err) .. ">") or tostring(before),
        after_err and ("<err:" .. tostring(after_err) .. ">") or tostring(after),
        ok_fire and "ok" or first_error_line(fire_err))
    local ok_active, active_detail = M.active("10")
    local active_suffix = ok_active and (" ; active_after=" .. tostring(active_detail)) or (" ; active_after_error=" .. tostring(active_detail))
    return true, string.format("trigger object fired %s ; %s%s",
        enabled and "on" or "off",
        table.concat(attempts, " ; "),
        active_suffix)
end

function M.reset_trigger(args)
    return false, "disabled: direct FWorldEventDefinition.Triggers enumeration caused a native crash; use world.event.triggerscan then world.event.resetobject <scan_index> confirm"
end

function M.reset_object(args)
    local raw = trim(args)
    if raw == "" then return false, "usage: world.event.resetobject <scan_index> confirm" end
    if not has_confirm(raw) then return false, "world.event.resetobject is mutating; append confirm" end
    local clean = strip_confirm(raw)
    local index = tonumber(clean:match("(%d+)"))
    if not index then return false, "usage: world.event.resetobject <scan_index> confirm" end
    local trigger, err = trigger_from_scan_index(index)
    if not trigger then return false, err end
    local ok_reset, reset_err = pcall(function() return trigger:Reset() end)
    local value, value_err = trigger_value(trigger)
    return true, string.format("#%d %s reset=%s current=%s",
        index,
        object_label(trigger),
        ok_reset and "ok" or first_error_line(reset_err),
        value_err and ("<err:" .. tostring(value_err) .. ">") or tostring(value))
end

local EVENT_ACTOR_CLASSES_TO_SCAN = {
    "WorldEvent",
    "BaseRaidEvent",
    "BP_BaseRaidEvent_BM_1_C",
    "BP_BaseRaidEvent_BM_2_C",
    "BP_BaseRaidEvent_FH_1_C",
    "BP_BaseRaidEvent_GF_1_C",
    "BP_BaseRaidEvent_GF_2_C",
    "HuntedEvent",
    "BP_HuntedEvent_BM_1_C",
    "BP_HuntedEvent_GF_1_C",
    "BP_HuntedEvent_GF_2_C",
    "BP_HuntedEvent_RotswornSkeletonAmbush_01_C",
    "BP_HuntedEvent_RotswornZombieAmbush_01_C",
    "BP_HuntedEvent_SkeletonAmbush_01_C",
    "BP_HuntedEvent_ZombieAmbush_01_C",
    "DragonEvent",
}

local function actor_is_being_destroyed_for_scan(actor)
    if not is_valid(actor) then return true end
    if actor.IsActorBeingDestroyed then
        local ok, value = pcall(function() return actor:IsActorBeingDestroyed() end)
        if ok and value then return true end
    end
    local ok_field, value = pcall(function() return actor.bActorIsBeingDestroyed end)
    if ok_field and value then return true end
    return false
end

local function actor_instance_number(actor)
    local full = object_full_name(actor) or object_name(actor)
    return tonumber(tostring(full):match("_(%d+)$")) or 0
end

local function collect_event_actor_entries()
    local seen, entries = {}, {}
    for _, class_name in ipairs(EVENT_ACTOR_CLASSES_TO_SCAN) do
        if FindAllOf then
            local ok, list = pcall(FindAllOf, class_name)
            if ok and list then
                local count = container_count(list)
                for i = 1, count do
                    local actor = container_item(list, i)
                    if is_valid(actor) and not actor_is_being_destroyed_for_scan(actor) then
                        local key = object_unique_key(actor)
                        if not seen[key] then
                            seen[key] = true
                            entries[#entries + 1] = {
                                actor = actor,
                                label = object_label(actor),
                                full_name = object_full_name(actor),
                                class = object_class(actor),
                                instance = actor_instance_number(actor),
                            }
                        end
                    end
                end
            end
        end
    end
    table.sort(entries, function(a, b)
        if (a.instance or 0) ~= (b.instance or 0) then return (a.instance or 0) > (b.instance or 0) end
        return tostring(a.full_name) > tostring(b.full_name)
    end)
    return entries
end

function M.active(args)
    local limit = tonumber(trim(args):match("(%d+)")) or 30
    if limit < 1 then limit = 1 end
    if limit > 100 then limit = 100 end
    local found = collect_event_actor_entries()
    local entries = {}
    for _, entry in ipairs(found) do entries[#entries + 1] = tostring(entry.label) end
    local shown = {}
    for i = 1, math.min(limit, #entries) do shown[#shown + 1] = entries[i] end
    return true, string.format("active=%d shown=%d ; %s", #entries, #shown, table.concat(shown, " ; "))
end

local function select_event_actor(selector)
    local token = trim(selector)
    if token == "" or token:lower() == "latest" or token:lower() == "last" then token = "1" end
    local entries = collect_event_actor_entries()
    if #entries == 0 then return nil, "no live WorldEvent/BaseRaid/Hunted/Dragon actors found" end
    local index = tonumber(token)
    if index then
        if index < 1 or index > #entries then return nil, "event actor index out of range: " .. tostring(index) .. " > " .. tostring(#entries) end
        return entries[index], nil, entries
    end
    local needle = token:lower()
    for _, entry in ipairs(entries) do
        local hay = (tostring(entry.label) .. " " .. tostring(entry.full_name) .. " " .. tostring(entry.class)):lower()
        if hay:find(needle, 1, true) then return entry, nil, entries end
    end
    return nil, "no live event actor matched: " .. tostring(token)
end

local function destroy_actor_safe(actor)
    if not is_valid(actor) then return false, "invalid" end
    if actor.K2_DestroyActor then
        local ok, err = pcall(function() actor:K2_DestroyActor() end)
        if ok then return true, "K2_DestroyActor" end
        return false, first_error_line(err)
    end
    if actor.DestroyActor then
        local ok, err = pcall(function() actor:DestroyActor() end)
        if ok then return true, "DestroyActor" end
        return false, first_error_line(err)
    end
    return false, "no destroy method"
end

local function vector_text(vec)
    vec = vec or {}
    return string.format("(%.2f,%.2f,%.2f)",
        tonumber(vec.X or vec.x) or 0,
        tonumber(vec.Y or vec.y) or 0,
        tonumber(vec.Z or vec.z) or 0)
end

local function rotator_text(rot)
    rot = rot or {}
    return string.format("(P%.2f,Y%.2f,R%.2f)",
        tonumber(rot.Pitch or rot.pitch or rot.X) or 0,
        tonumber(rot.Yaw or rot.yaw or rot.Y) or 0,
        tonumber(rot.Roll or rot.roll or rot.Z) or 0)
end

local function actor_transform_snapshot(actor)
    local loc = actor_location(actor)
    local rot = actor_rotation(actor)
    local scale = feature_actor.get_actor_scale3d(actor)
    return {
        location = {
            X = loc and (loc.X or loc.x) or 0,
            Y = loc and (loc.Y or loc.y) or 0,
            Z = loc and (loc.Z or loc.z) or 0,
        },
        rotation = {
            Pitch = rot and (rot.Pitch or rot.pitch or rot.X) or 0,
            Yaw = rot and (rot.Yaw or rot.yaw or rot.Y) or 0,
            Roll = rot and (rot.Roll or rot.roll or rot.Z) or 0,
        },
        scale = {
            X = scale and (scale.X or scale.x) or 1,
            Y = scale and (scale.Y or scale.y) or 1,
            Z = scale and (scale.Z or scale.z) or 1,
        },
    }
end

local function actor_destroying_state(actor)
    if not is_valid(actor) then return nil end
    if actor.IsActorBeingDestroyed then
        local ok, value = pcall(function() return actor:IsActorBeingDestroyed() end)
        if ok then return value and true or false end
    end
    local ok_field, value = pcall(function() return actor.bActorIsBeingDestroyed end)
    if ok_field and type(value) == "boolean" then return value end
    return nil
end

local function field_snapshot(obj, field)
    local rec = { name = field }
    if not is_valid(obj) then
        rec.ok = false
        rec.error = "invalid object"
        return rec
    end
    local ok, value = pcall(function() return obj[field] end)
    rec.ok = ok and true or false
    if not ok then
        rec.error = first_error_line(value)
        return rec
    end
    rec.value = truncate_text(value_text(value), 320)
    local count = container_count(value)
    if count and count > 0 then rec.count = count end
    value = player_core.unwrap_param(value)
    if type(value) == "userdata" and is_valid(value) then
        rec.object = object_label(value)
        rec.object_full_name = object_full_name(value)
    end
    return rec
end

local EVENT_ACTOR_FIELDS = {
    "Role",
    "RemoteRole",
    "Owner",
    "Instigator",
    "bHidden",
    "bActorIsBeingDestroyed",
    "bReplicates",
    "bAlwaysRelevant",
    "bNetLoadOnClient",
    "NetDormancy",
    "SpawnCollisionHandlingMethod",
    "InitialLifeSpan",
    "CustomTimeDilation",
}

local BASE_RAID_FIELDS = {
    "EventDuration",
    "MaximumPauseDuration",
    "EventRadius",
    "AISpawnRadius",
    "MinAngleBetweenWaves",
    "AISpreadRadius",
    "SpawnPointNavMeshProjectionExtents",
    "SpawnPointNavMeshProjectionMaxRetries",
    "MaxPlayerDistanceFromSpawnRadiusForConsideration",
    "IntervalBetweenPlayerAggroApplication",
    "Waves",
    "DelayAfterFinalWaveBeforeDismissingAISecs",
    "VariationInDismissalTimeSecs",
    "StartOfEventSound",
    "EndOfEventSound",
    "DamageConfigs",
    "AIWaveSpawnComponent",
    "EventTimerInGameSecsRemaining",
    "PauseTimerInGameEndTime",
    "LastPlayerAggroTime",
    "bHasEventActuallyStarted",
    "LastCompletedWaveIndex",
    "SpudGuid",
}

local HUNTED_FIELDS = {
    "AIToSpawn",
    "AISpawnRadius",
    "AISpreadRadius",
    "MinTimeBetweenSpawnsSecs",
    "AIDespawnBehaviour",
    "StartOfEventNotificationTag",
    "SpawnPointNavMeshProjectionExtents",
    "SpawnPointNavMeshProjectionMaxRetries",
    "MaxPlayerDistanceFromSpawnRadiusForConsideration",
    "bOverridePointsToSample",
    "PointsToSample",
    "bOverrideDistanceToPointsOfInterestWeight",
    "DistanceToPointsOfInterestWeight",
    "bOverrideMaxFOVAngularDistanceWeight",
    "MaxFOVAngularDistanceWeight",
    "bOverrideThresholdForConsideration",
    "ThresholdForConsideration",
    "bOverrideFOV",
    "FOV",
    "AIWaveSpawnComponent",
}

local DRAGON_FIELDS = {
    "EventHeight",
    "bSkipStore",
    "EndOfEventSound",
    "DragonActorClass",
    "EntryStage",
    "EventStages",
    "LeaveStage",
    "StartEventDelaySecs",
    "DestroyEventDelaySecs",
    "AudioIdentifier",
    "SpudGuid",
    "WorldProgressManager",
    "LastStageActor",
    "CurrentStageActor",
    "PreviousCharactersInRange",
    "CurrentStageIndex",
    "DragonActor",
    "EventStartInGameSecs",
    "StageTransform",
    "EventStartServerSecs",
    "bForceEndStage",
    "ForceEndStageServerSecs",
    "bHasStarted",
    "PrimaryPlayerTarget",
    "CurrentStageStartServerSecs",
    "CurrentStageDuration",
    "NumStages",
}

local function event_actor_snapshot(actor)
    local snap = {
        valid = is_valid(actor),
        label = object_label(actor),
        full_name = object_full_name(actor),
        name = object_name(actor),
        class = object_class(actor),
        destroying = actor_destroying_state(actor),
        transform = actor_transform_snapshot(actor),
        fields = {},
        base_raid_fields = {},
        hunted_fields = {},
        dragon_fields = {},
    }
    if not snap.valid then return snap end
    for _, field in ipairs(EVENT_ACTOR_FIELDS) do
        snap.fields[field] = field_snapshot(actor, field)
    end
    for _, field in ipairs(BASE_RAID_FIELDS) do
        local rec = field_snapshot(actor, field)
        if rec.ok or rec.error ~= "invalid object" then snap.base_raid_fields[field] = rec end
    end
    for _, field in ipairs(HUNTED_FIELDS) do
        local rec = field_snapshot(actor, field)
        if rec.ok or rec.error ~= "invalid object" then snap.hunted_fields[field] = rec end
    end
    for _, field in ipairs(DRAGON_FIELDS) do
        local rec = field_snapshot(actor, field)
        if rec.ok or rec.error ~= "invalid object" then snap.dragon_fields[field] = rec end
    end
    return snap
end

local function event_actor_summary_lines(prefix, snap)
    prefix = prefix or "actor"
    local lines = {}
    if not snap or not snap.valid then
        lines[#lines + 1] = prefix .. "=<invalid>"
        return lines
    end
    local xform = snap.transform or {}
    lines[#lines + 1] = string.format("%s=%s full=%s", prefix, tostring(snap.label), tostring(snap.full_name))
    lines[#lines + 1] = string.format("%s_transform loc=%s rot=%s scale=%s destroying=%s",
        prefix,
        vector_text(xform.location),
        rotator_text(xform.rotation),
        vector_text(xform.scale),
        tostring(snap.destroying))
    local interesting = {}
    for _, pair in ipairs({
        { "base_raid_fields", "bHasEventActuallyStarted" },
        { "base_raid_fields", "EventTimerInGameSecsRemaining" },
        { "base_raid_fields", "LastCompletedWaveIndex" },
        { "base_raid_fields", "Waves" },
        { "base_raid_fields", "AIWaveSpawnComponent" },
        { "hunted_fields", "AIToSpawn" },
        { "hunted_fields", "AIWaveSpawnComponent" },
        { "dragon_fields", "bHasStarted" },
        { "dragon_fields", "DragonActor" },
        { "dragon_fields", "CurrentStageIndex" },
        { "dragon_fields", "NumStages" },
        { "dragon_fields", "CurrentStageActor" },
    }) do
        local bucket, field = pair[1], pair[2]
        local rec = snap[bucket] and snap[bucket][field]
        if rec and rec.ok then
            local suffix = rec.count and (" count=" .. tostring(rec.count)) or ""
            interesting[#interesting + 1] = field .. "=" .. tostring(rec.value) .. suffix
        end
    end
    if #interesting > 0 then lines[#lines + 1] = prefix .. "_key_fields " .. table.concat(interesting, " ; ") end
    return lines
end

local function read_raw_field(obj, field)
    if obj == nil then return nil, false, "nil object" end
    local ok, value = pcall(function() return obj[field] end)
    if not ok then return nil, false, first_error_line(value) end
    return player_core.unwrap_param(value), true, nil
end

local function read_path_text_safe(obj, path)
    if obj == nil then return nil end
    local ok, value = player_core.read_path(obj, path)
    if not ok or value == nil then return nil end
    return value_text(value)
end

local function compact_field(obj, field)
    local value, ok, err = read_raw_field(obj, field)
    local rec = { name = field, ok = ok and true or false }
    if not ok then
        rec.error = tostring(err)
        return rec
    end
    rec.value = truncate_text(value_text(value), 320)
    local count = container_count(value)
    if count and count > 0 then rec.count = count end
    return rec
end

local function compact_field_value(obj, field)
    local rec = compact_field(obj, field)
    if rec.ok then return rec.value end
    return "<err:" .. tostring(rec.error) .. ">"
end

local function wave_entry_snapshot(entry, index, entry_kind)
    local rec = {
        index = index,
        kind = entry_kind,
        fields = {},
        ai = {},
    }
    for _, field in ipairs({ "BudgetCostPerAI", "Weight", "NumberSpawnedToWeight" }) do
        local field_rec = compact_field(entry, field)
        if field_rec.ok or field_rec.error ~= "nil object" then rec.fields[field] = field_rec end
    end

    local details, ok_details, details_err = read_raw_field(entry, "AISpawnDetails")
    rec.ai.details_ok = ok_details and true or false
    if not ok_details then rec.ai.details_error = details_err end
    if ok_details and details ~= nil then
        rec.ai.AIClass = compact_field_value(details, "AIClass")
        rec.ai.PowerLevel = compact_field_value(details, "PowerLevel")
    else
        rec.ai.AIClass = read_path_text_safe(entry, "AISpawnDetails.AIClass") or "<none>"
        rec.ai.PowerLevel = read_path_text_safe(entry, "AISpawnDetails.PowerLevel") or "<none>"
    end
    return rec
end

local function wave_entry_line(rec)
    local fields = {}
    for _, field in ipairs({ "BudgetCostPerAI", "Weight", "NumberSpawnedToWeight" }) do
        local field_rec = rec.fields and rec.fields[field]
        if field_rec and field_rec.ok then fields[#fields + 1] = field .. "=" .. tostring(field_rec.value) end
    end
    fields[#fields + 1] = "AIClass=" .. tostring(rec.ai and rec.ai.AIClass or "<none>")
    fields[#fields + 1] = "PowerLevel=" .. tostring(rec.ai and rec.ai.PowerLevel or "<none>")
    return string.format("    %s#%d %s", tostring(rec.kind), tonumber(rec.index) or 0, table.concat(fields, " "))
end

local function wave_snapshot(wave, index, mode)
    local rec = {
        index = index,
        fields = {},
        filler_count = 0,
        special_count = 0,
        fillers = {},
        specials = {},
    }
    for _, field in ipairs({ "SpawnBudget", "StartOfWaveSecs", "DurationOfWaveSecs", "IntervalBetweenSpawnsSecs" }) do
        local field_rec = compact_field(wave, field)
        if field_rec.ok or field_rec.error ~= "nil object" then rec.fields[field] = field_rec end
    end

    local fillers = nil
    local specials = nil
    local ok_fillers, ok_specials
    fillers, ok_fillers = read_raw_field(wave, "SpawnFillers")
    specials, ok_specials = read_raw_field(wave, "SpawnSpecials")
    if ok_fillers then rec.filler_count = container_count(fillers) end
    if ok_specials then rec.special_count = container_count(specials) end
    local include_entries = mode == "fields" or mode == "full"
    local entry_limit = mode == "full" and 25 or 12
    if include_entries and ok_fillers then
        for i = 1, math.min(rec.filler_count or 0, entry_limit) do
            local entry = container_item(fillers, i)
            rec.fillers[#rec.fillers + 1] = wave_entry_snapshot(entry, i, "filler")
        end
    end
    if include_entries and ok_specials then
        for i = 1, math.min(rec.special_count or 0, entry_limit) do
            local entry = container_item(specials, i)
            rec.specials[#rec.specials + 1] = wave_entry_snapshot(entry, i, "special")
        end
    end
    return rec
end

local function wave_line(rec, source)
    local bits = {}
    for _, field in ipairs({ "SpawnBudget", "StartOfWaveSecs", "DurationOfWaveSecs", "IntervalBetweenSpawnsSecs" }) do
        local field_rec = rec.fields and rec.fields[field]
        if field_rec and field_rec.ok then bits[#bits + 1] = field .. "=" .. tostring(field_rec.value) end
    end
    bits[#bits + 1] = "fillers=" .. tostring(rec.filler_count or 0)
    bits[#bits + 1] = "specials=" .. tostring(rec.special_count or 0)
    return string.format("  %s wave#%d %s", tostring(source), tonumber(rec.index) or 0, table.concat(bits, " "))
end

local function wave_array_snapshot(actor, field, source, mode)
    local waves, ok, err = read_raw_field(actor, field)
    local rec = {
        field = field,
        source = source,
        ok = ok and true or false,
        error = ok and nil or tostring(err),
        count = 0,
        shown = 0,
        waves = {},
    }
    if not ok then return rec end
    rec.count = container_count(waves)
    local wave_limit = mode == "full" and 12 or 8
    rec.shown = math.min(rec.count or 0, wave_limit)
    for i = 1, rec.shown do
        local wave = container_item(waves, i)
        rec.waves[#rec.waves + 1] = wave_snapshot(wave, i, mode)
    end
    return rec
end

local function wave_single_snapshot(actor, field, source, mode)
    local wave, ok, err = read_raw_field(actor, field)
    local rec = {
        field = field,
        source = source,
        ok = ok and true or false,
        error = ok and nil or tostring(err),
        count = 0,
        shown = 0,
        waves = {},
    }
    if not ok or wave == nil then return rec end
    local snap = wave_snapshot(wave, 1, mode)
    local has_shape = false
    for _, field_rec in pairs(snap.fields or {}) do
        if field_rec and field_rec.ok then
            has_shape = true
            break
        end
    end
    if not has_shape and (snap.filler_count or 0) <= 0 and (snap.special_count or 0) <= 0 then
        rec.error = "field present but did not expose FSpawnWave shape"
        return rec
    end
    rec.count = 1
    rec.shown = 1
    rec.waves[#rec.waves + 1] = snap
    return rec
end

local EVENT_WAVE_KNOB_FIELDS = {
    base_raid = {
        "EventDuration",
        "MaximumPauseDuration",
        "EventRadius",
        "AISpawnRadius",
        "MinAngleBetweenWaves",
        "AISpreadRadius",
        "SpawnPointNavMeshProjectionExtents",
        "SpawnPointNavMeshProjectionMaxRetries",
        "MaxPlayerDistanceFromSpawnRadiusForConsideration",
        "IntervalBetweenPlayerAggroApplication",
        "DelayAfterFinalWaveBeforeDismissingAISecs",
        "VariationInDismissalTimeSecs",
        "EventTimerInGameSecsRemaining",
        "LastCompletedWaveIndex",
    },
    hunted = {
        "AISpawnRadius",
        "AISpreadRadius",
        "MinTimeBetweenSpawnsSecs",
        "AIDespawnBehaviour",
        "StartOfEventNotificationTag",
        "SpawnPointNavMeshProjectionExtents",
        "SpawnPointNavMeshProjectionMaxRetries",
        "MaxPlayerDistanceFromSpawnRadiusForConsideration",
    },
}

local function event_wave_report(actor, selector, mode)
    local kind = definition_kind({ WorldEventClass = object_class(actor), PersistenceID = object_name(actor), DebugName = object_full_name(actor) })
    local report = {
        generated_unix = os.time(),
        selector = selector,
        mode = mode,
        target = {
            label = object_label(actor),
            full_name = object_full_name(actor),
            class = object_class(actor),
            inferred_kind = kind,
        },
        fields = {},
        base_raid = wave_array_snapshot(actor, "Waves", "base_raid", mode),
        hunted = wave_single_snapshot(actor, "AIToSpawn", "hunted", mode),
    }
    for bucket, fields in pairs(EVENT_WAVE_KNOB_FIELDS) do
        report.fields[bucket] = {}
        for _, field in ipairs(fields) do
            local rec = compact_field(actor, field)
            if rec.ok then report.fields[bucket][field] = rec end
        end
    end
    return report
end

local function event_wave_lines(report)
    local lines = {
        "World Event Wave/Spawn Probe",
        "target=" .. tostring(report.target and report.target.label),
        "full=" .. tostring(report.target and report.target.full_name),
        "class=" .. tostring(report.target and report.target.class),
        "mode=" .. tostring(report.mode),
    }
    for bucket, fields in pairs(report.fields or {}) do
        local bits = {}
        for key, rec in pairs(fields or {}) do
            if rec and rec.ok then bits[#bits + 1] = tostring(key) .. "=" .. tostring(rec.value) end
        end
        table.sort(bits)
        if #bits > 0 then lines[#lines + 1] = bucket .. "_knobs " .. table.concat(bits, " ; ") end
    end
    for _, pack in ipairs({ report.base_raid, report.hunted }) do
        if pack and pack.ok then
            lines[#lines + 1] = string.format("%s field=%s waves=%d shown=%d",
                tostring(pack.source),
                tostring(pack.field),
                tonumber(pack.count) or 0,
                tonumber(pack.shown) or 0)
            for _, wave in ipairs(pack.waves or {}) do
                lines[#lines + 1] = wave_line(wave, pack.source)
                for _, entry in ipairs(wave.fillers or {}) do lines[#lines + 1] = wave_entry_line(entry) end
                for _, entry in ipairs(wave.specials or {}) do lines[#lines + 1] = wave_entry_line(entry) end
            end
        else
            lines[#lines + 1] = string.format("%s field=%s unavailable=%s",
                tostring(pack and pack.source or "?"),
                tostring(pack and pack.field or "?"),
                tostring(pack and pack.error or "unknown"))
        end
    end
    return lines
end

function M.waves(args)
    local raw = trim(args)
    local words = split_words(raw)
    local selector = words[1] or "latest"
    local mode = tostring(words[2] or "light"):lower()
    if selector == "light" or selector == "fields" or selector == "full" then
        mode = selector
        selector = "latest"
    end
    local valid_modes = { light = true, fields = true, full = true }
    if not valid_modes[mode] then return false, "usage: world.event.waves <latest|index|name> [light|fields|full]" end
    local entry, select_err = select_event_actor(selector)
    if not entry then
        local _manager, def, _count, def_err, index = definition_by_token(selector)
        if def then
            local rec = definition_record(def, index or 0)
            local start_token = definition_start_alias(rec)
            return false, "definition token resolved, but wave data needs a live actor. Run: world.event.startlive " .. tostring(start_token) .. " confirm ; then: world.event.waves latest fields"
        end
        return false, select_err .. " ; " .. tostring(def_err or "")
    end
    local report = event_wave_report(entry.actor, selector, mode)
    local lines = event_wave_lines(report)
    local ok_write, path_or_err = write_report("world_event_waves", report, lines)
    local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
    return true, string.format("target=%s base_waves=%d hunted_waves=%d mode=%s%s",
        tostring(entry.label),
        tonumber(report.base_raid and report.base_raid.count) or 0,
        tonumber(report.hunted and report.hunted.count) or 0,
        tostring(mode),
        wrote)
end

function M.event_state(args)
    local limit = tonumber(trim(args):match("(%d+)")) or 10
    if limit < 1 then limit = 1 end
    if limit > 50 then limit = 50 end
    local entries = collect_event_actor_entries()
    local report = {
        generated_unix = os.time(),
        event_count = #entries,
        shown = math.min(limit, #entries),
        events = {},
    }
    local lines = {
        "World Event Actor State",
        "events=" .. tostring(#entries) .. " shown=" .. tostring(math.min(limit, #entries)),
    }
    for i = 1, math.min(limit, #entries) do
        local entry = entries[i]
        local snap = event_actor_snapshot(entry.actor)
        snap.index = i
        report.events[#report.events + 1] = snap
        lines[#lines + 1] = string.format("#%d %s full=%s", i, tostring(snap.label), tostring(snap.full_name))
        for _, line in ipairs(event_actor_summary_lines("  event", snap)) do lines[#lines + 1] = line end
    end
    local ok_write, path_or_err = write_report("world_event_eventstate", report, lines)
    local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
    return true, string.format("events=%d shown=%d%s", #entries, math.min(limit, #entries), wrote)
end

local call_actor_noargs

local AI_WAVE_COMPONENT_FIELDS = {
    "NavigationSeedLookupExtents",
    "MaxNumAttemptsToDetermineWaveSpawnLocation",
    "MaxNumAttemptsToDetermineAISpawnTransform",
    "MinTimeBetweenAttemptsToDetermineWaveSpawnLocation",
    "AiDirector",
    "OwningWorldEvent",
    "bAutoActivate",
    "bIsActive",
    "bRegistered",
    "PrimaryComponentTick",
}

local function component_method_value(component, method_name)
    if not is_valid(component) then return { method = method_name, ok = false, error = "invalid component" } end
    local ok_method, method = pcall(function() return component[method_name] end)
    if not ok_method or method == nil then
        return { method = method_name, ok = false, present = false, error = "missing" }
    end
    local ok_call, result = pcall(function() return method(component) end)
    local rec = {
        method = method_name,
        present = true,
        ok = ok_call and true or false,
    }
    if ok_call then
        rec.value = truncate_text(value_text(result), 320)
        result = player_core.unwrap_param(result)
        if type(result) == "userdata" and is_valid(result) then
            rec.object = object_label(result)
            rec.object_full_name = object_full_name(result)
        end
    else
        rec.error = first_error_line(result)
    end
    return rec
end

local function component_call_noargs(component, method_name)
    if not is_valid(component) then return { method = method_name, ok = false, error = "invalid component" } end
    local ok_method, method = pcall(function() return component[method_name] end)
    if not ok_method or method == nil then
        return { method = method_name, present = false, ok = false, error = "missing" }
    end
    local ok_call, result = pcall(function() return method(component) end)
    return {
        method = method_name,
        present = true,
        ok = ok_call and true or false,
        error = ok_call and nil or first_error_line(result),
        result = ok_call and truncate_text(value_text(result), 240) or nil,
    }
end

local function component_call_bool(component, method_name, value)
    if not is_valid(component) then return { method = method_name, ok = false, error = "invalid component" } end
    local ok_method, method = pcall(function() return component[method_name] end)
    if not ok_method or method == nil then
        return { method = method_name, present = false, ok = false, error = "missing" }
    end
    local ok_call, result = pcall(function() return method(component, value and true or false) end)
    return {
        method = method_name,
        value = value and "true" or "false",
        present = true,
        ok = ok_call and true or false,
        error = ok_call and nil or first_error_line(result),
        result = ok_call and truncate_text(value_text(result), 240) or nil,
    }
end

local function write_component_field(component, field, value)
    local before = field_snapshot(component, field)
    local ok_write, err = pcall(function() component[field] = value end)
    local after = field_snapshot(component, field)
    return {
        field = field,
        value = value_text(value),
        ok = ok_write and true or false,
        error = ok_write and nil or first_error_line(err),
        before = before,
        after = after,
    }
end

local function get_ai_wave_component(actor)
    if not is_valid(actor) then return nil, "invalid event actor" end
    local comp, ok, err = read_raw_field(actor, "AIWaveSpawnComponent")
    if ok and is_valid(comp) then return comp, "AIWaveSpawnComponent field" end
    if ok and comp ~= nil then return nil, "AIWaveSpawnComponent field is not valid: " .. value_text(comp) end

    if StaticFindObject and actor.GetComponentByClass then
        local ok_class, cls = pcall(StaticFindObject, "/Script/Dominion.WorldEventAIWaveSpawnComponent")
        if ok_class and is_valid(cls) then
            local ok_get, found = pcall(function() return actor:GetComponentByClass(cls) end)
            if ok_get and is_valid(found) then return found, "GetComponentByClass(WorldEventAIWaveSpawnComponent)" end
        end
    end
    return nil, "AIWaveSpawnComponent unavailable: " .. tostring(err)
end

local function find_ai_director()
    for _, class_name in ipairs({ "BP_AiDirector_C", "AiDirector" }) do
        local director = find_first_valid(class_name)
        if is_valid(director) then return director, "FindAllOf(" .. class_name .. ")" end
    end
    if StaticFindObject then
        local ok_cdo, cdo = pcall(StaticFindObject, "/Script/Dominion.Default__AiDirector")
        if ok_cdo and is_valid(cdo) and cdo.Get then
            for _, context in ipairs({ feature_net.local_pawn(), feature_net.local_controller(), feature_field.resolve_root("world") }) do
                if is_valid(context) then
                    local ok_get, director = pcall(function() return cdo:Get(context) end)
                    if ok_get and is_valid(director) then return director, "AiDirector.Get(" .. object_label(context) .. ")" end
                end
            end
        end
    end
    return nil, "not found"
end

local function ai_wave_component_snapshot(actor, component)
    component = component or select(1, get_ai_wave_component(actor))
    local snap = {
        valid = is_valid(component),
        label = object_label(component),
        full_name = object_full_name(component),
        class = object_class(component),
        actor = {
            label = object_label(actor),
            full_name = object_full_name(actor),
            class = object_class(actor),
        },
        fields = {},
        methods = {},
    }
    if not snap.valid then return snap end

    local owner_rec = component_method_value(component, "GetOwner")
    snap.owner = owner_rec
    local outer = object_outer(component)
    snap.outer = is_valid(outer) and {
        label = object_label(outer),
        full_name = object_full_name(outer),
        class = object_class(outer),
    } or nil

    for _, field in ipairs(AI_WAVE_COMPONENT_FIELDS) do
        snap.fields[field] = field_snapshot(component, field)
    end
    for _, method_name in ipairs({
        "IsRegistered",
        "IsActive",
        "HasBegunPlay",
        "IsComponentTickEnabled",
        "GetComponentTickInterval",
        "GetOwner",
        "GetWorld",
    }) do
        snap.methods[method_name] = component_method_value(component, method_name)
    end
    local director, director_route = find_ai_director()
    snap.detected_ai_director = is_valid(director) and {
        label = object_label(director),
        full_name = object_full_name(director),
        class = object_class(director),
        route = director_route,
    } or { route = director_route }
    return snap
end

local function method_bool_value(snapshot, method_name)
    local rec = snapshot and snapshot.methods and snapshot.methods[method_name]
    if not rec or not rec.ok then return nil end
    local text = tostring(rec.value or ""):lower()
    if text == "true" or text == "1" then return true end
    if text == "false" or text == "0" then return false end
    return nil
end

local function ai_component_report_lines(title, selector, report)
    local lines = {
        title,
        "selector=" .. tostring(selector),
        "target=" .. tostring(report.target and report.target.label),
        "target_full=" .. tostring(report.target and report.target.full_name),
    }
    local component = report.component or {}
    lines[#lines + 1] = string.format("component=%s full=%s class=%s valid=%s",
        tostring(component.label),
        tostring(component.full_name),
        tostring(component.class),
        tostring(component.valid))
    if component.outer then
        lines[#lines + 1] = "outer=" .. tostring(component.outer.label) .. " full=" .. tostring(component.outer.full_name)
    end
    if component.owner then
        lines[#lines + 1] = string.format("owner ok=%s value=%s object=%s full=%s",
            tostring(component.owner.ok),
            tostring(component.owner.value),
            tostring(component.owner.object),
            tostring(component.owner.object_full_name))
    end
    if component.detected_ai_director then
        lines[#lines + 1] = "detected_ai_director route=" .. tostring(component.detected_ai_director.route)
            .. " value=" .. tostring(component.detected_ai_director.label)
    end
    for _, field in ipairs(AI_WAVE_COMPONENT_FIELDS) do
        local rec = component.fields and component.fields[field]
        if rec then
            local extra = rec.object and (" object=" .. tostring(rec.object) .. " full=" .. tostring(rec.object_full_name)) or ""
            lines[#lines + 1] = string.format("field %s ok=%s value=%s%s",
                tostring(field),
                tostring(rec.ok),
                tostring(rec.ok and rec.value or rec.error),
                extra)
        end
    end
    for _, method_name in ipairs({
        "IsRegistered",
        "IsActive",
        "HasBegunPlay",
        "IsComponentTickEnabled",
        "GetComponentTickInterval",
    }) do
        local rec = component.methods and component.methods[method_name]
        if rec then
            lines[#lines + 1] = string.format("method %s present=%s ok=%s value=%s error=%s",
                tostring(method_name),
                tostring(rec.present),
                tostring(rec.ok),
                tostring(rec.value),
                tostring(rec.error or ""))
        end
    end
    for i, action in ipairs(report.actions or {}) do
        if action.method then
            lines[#lines + 1] = string.format("action#%d call %s present=%s ok=%s value=%s error=%s",
                i,
                tostring(action.method),
                tostring(action.present),
                tostring(action.ok),
                tostring(action.value or action.result or ""),
                tostring(action.error or ""))
        elseif action.field then
            lines[#lines + 1] = string.format("action#%d write %s=%s ok=%s before=%s after=%s error=%s",
                i,
                tostring(action.field),
                tostring(action.value),
                tostring(action.ok),
                action.before and tostring(action.before.value) or "<none>",
                action.after and tostring(action.after.value) or "<none>",
                tostring(action.error or ""))
        else
            lines[#lines + 1] = string.format("action#%d %s", i, tostring(action.note or action.error or "<unknown>"))
        end
    end
    if report.after_component then
        lines[#lines + 1] = "after_component:"
        for _, field in ipairs({ "AiDirector", "OwningWorldEvent" }) do
            local rec = report.after_component.fields and report.after_component.fields[field]
            if rec then
                lines[#lines + 1] = string.format("after field %s ok=%s value=%s object=%s full=%s",
                    field,
                    tostring(rec.ok),
                    tostring(rec.ok and rec.value or rec.error),
                    tostring(rec.object),
                    tostring(rec.object_full_name))
            end
        end
        for _, method_name in ipairs({ "IsRegistered", "IsActive", "IsComponentTickEnabled" }) do
            local rec = report.after_component.methods and report.after_component.methods[method_name]
            if rec then
                lines[#lines + 1] = string.format("after method %s ok=%s value=%s error=%s",
                    method_name,
                    tostring(rec.ok),
                    tostring(rec.value),
                    tostring(rec.error or ""))
            end
        end
    end
    if report.active_after then lines[#lines + 1] = "active_after=" .. tostring(report.active_after.detail) end
    return lines
end

function M.ai_component(args)
    local selector = trim(args)
    if selector == "" then selector = "latest" end
    local entry, select_err = select_event_actor(selector)
    if not entry then return false, select_err end
    local component, component_route = get_ai_wave_component(entry.actor)
    local report = {
        generated_unix = os.time(),
        selector = selector,
        target = {
            label = entry.label,
            full_name = entry.full_name,
            class = entry.class,
            instance = entry.instance,
        },
        component_route = component_route,
        component = ai_wave_component_snapshot(entry.actor, component),
    }
    local lines = ai_component_report_lines("World Event AI Wave Component", selector, report)
    lines[#lines + 1] = "component_route=" .. tostring(component_route)
    local ok_write, path_or_err = write_report("world_event_aicomponent", report, lines)
    local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
    return true, string.format("target=%s component=%s route=%s%s",
        tostring(entry.label),
        tostring(report.component and report.component.label),
        tostring(component_route),
        wrote)
end

function M.ai_component_link(args)
    local raw = trim(args)
    if raw == "" then return false, "usage: world.event.aicomponent.link <latest|index|name> confirm" end
    if not has_confirm(raw) then return false, "world.event.aicomponent.link is mutating; append confirm" end
    local selector = strip_confirm(raw)
    if selector == "" then selector = "latest" end
    local entry, select_err = select_event_actor(selector)
    if not entry then return false, select_err end
    local component, component_route = get_ai_wave_component(entry.actor)
    if not is_valid(component) then return false, "AIWaveSpawnComponent missing: " .. tostring(component_route) end
    local director, director_route = find_ai_director()
    local report = {
        generated_unix = os.time(),
        selector = selector,
        target = {
            label = entry.label,
            full_name = entry.full_name,
            class = entry.class,
            instance = entry.instance,
        },
        component_route = component_route,
        director_route = director_route,
        component = ai_wave_component_snapshot(entry.actor, component),
        actions = {},
    }
    report.actions[#report.actions + 1] = write_component_field(component, "OwningWorldEvent", entry.actor)
    if is_valid(director) then
        report.actions[#report.actions + 1] = write_component_field(component, "AiDirector", director)
    else
        report.actions[#report.actions + 1] = { note = "AiDirector not written; " .. tostring(director_route) }
    end

    local was_registered = method_bool_value(report.component, "IsRegistered")
    local was_active = method_bool_value(report.component, "IsActive")
    local was_tick_enabled = method_bool_value(report.component, "IsComponentTickEnabled")
    if was_registered == true then
        report.actions[#report.actions + 1] = { note = "RegisterComponent skipped; already registered" }
    else
        report.actions[#report.actions + 1] = component_call_noargs(component, "RegisterComponent")
    end
    if was_active == true then
        report.actions[#report.actions + 1] = { note = "Activate skipped; already active" }
    else
        report.actions[#report.actions + 1] = component_call_bool(component, "Activate", true)
    end
    if was_tick_enabled == true then
        report.actions[#report.actions + 1] = { note = "SetComponentTickEnabled skipped; already enabled" }
    else
        report.actions[#report.actions + 1] = component_call_bool(component, "SetComponentTickEnabled", true)
    end
    report.actions[#report.actions + 1] = call_actor_noargs(entry.actor, "OnEventStart")
    report.after_component = ai_wave_component_snapshot(entry.actor, component)
    report.after_event = event_actor_snapshot(entry.actor)
    report.active_after = active_snapshot(50)

    local lines = ai_component_report_lines("World Event AI Wave Component Link Probe", selector, report)
    local ok_write, path_or_err = write_report("world_event_aicomponent_link", report, lines)
    local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
    return true, string.format("target=%s component=%s actions=%d director=%s active=%d%s",
        tostring(entry.label),
        tostring(report.component and report.component.label),
        #report.actions,
        tostring(is_valid(director) and object_label(director) or director_route),
        tonumber(report.active_after and report.active_after.active_count) or 0,
        wrote)
end

function call_actor_noargs(actor, method_name)
    if not is_valid(actor) then return { method = method_name, present = false, ok = false, error = "invalid actor" } end
    local ok_read, method = pcall(function() return actor[method_name] end)
    if not ok_read or method == nil then return { method = method_name, present = false, ok = false, error = "missing" } end
    local ok_call, result = pcall(function() return method(actor) end)
    return {
        method = method_name,
        present = true,
        ok = ok_call and true or false,
        error = ok_call and nil or first_error_line(result),
        result = ok_call and truncate_text(value_text(result), 240) or nil,
    }
end

local function write_actor_field(actor, field, value)
    local before = field_snapshot(actor, field)
    local ok_write, err = pcall(function() actor[field] = value end)
    local after = field_snapshot(actor, field)
    return {
        field = field,
        value = value_text(value),
        ok = ok_write and true or false,
        error = ok_write and nil or first_error_line(err),
        before = before,
        after = after,
    }
end

local function call_controller_bool(method_name, value)
    local pc = feature_net.local_controller()
    if not is_valid(pc) then return { method = method_name, present = false, ok = false, error = "no local controller" } end
    local ok_read, method = pcall(function() return pc[method_name] end)
    if not ok_read or method == nil then return { method = method_name, present = false, ok = false, error = "missing" } end
    local ok_call, result = pcall(function() return method(pc, value and true or false) end)
    return {
        method = method_name,
        target = "local_controller",
        arg = value and true or false,
        present = true,
        ok = ok_call and true or false,
        error = ok_call and nil or first_error_line(result),
        result = ok_call and truncate_text(value_text(result), 240) or nil,
    }
end

local function numeric_actor_field(actor, field, fallback)
    local ok, value = pcall(function() return actor[field] end)
    if ok then
        local n = tonumber(value)
        if n then return n end
    end
    return fallback
end

local function kick_write_start_fields(actor)
    local duration = numeric_actor_field(actor, "EventDuration", nil)
    if not duration or duration <= 0 then duration = numeric_actor_field(actor, "MinTimeBetweenSpawnsSecs", 300) end
    local actions = {}
    actions[#actions + 1] = write_actor_field(actor, "bHasEventActuallyStarted", true)
    actions[#actions + 1] = write_actor_field(actor, "EventTimerInGameSecsRemaining", duration)
    actions[#actions + 1] = write_actor_field(actor, "LastCompletedWaveIndex", -1)
    actions[#actions + 1] = write_actor_field(actor, "LastPlayerAggroTime", -999999)
    return actions
end

local function apply_event_start_actions(actor, include_impl)
    local actions = kick_write_start_fields(actor)
    actions[#actions + 1] = call_actor_noargs(actor, "OnEventStart")
    if include_impl then actions[#actions + 1] = call_actor_noargs(actor, "OnEventStart_Implementation") end
    return actions
end

local function dragon_lifecycle_actions(actor, mode)
    mode = tostring(mode or "start"):lower()
    if mode == "lifecycle" or mode == "all" then mode = "full" end
    local actions = {}
    for _, action in ipairs(apply_event_start_actions(actor, mode == "full")) do actions[#actions + 1] = action end
    if mode == "start" then return actions end

    local player = feature_net.local_pawn()
    if mode == "client" or mode == "timer" or mode == "full" then
        actions[#actions + 1] = call_controller_bool("Client_SetIsInDragonEvent", true)
        actions[#actions + 1] = call_actor_noargs(actor, "OnEventStartClient")
    end
    if mode == "rep" or mode == "timer" or mode == "full" then
        if is_valid(player) then actions[#actions + 1] = write_actor_field(actor, "PrimaryPlayerTarget", player) end
        actions[#actions + 1] = write_actor_field(actor, "bHasStarted", 1.0)
        actions[#actions + 1] = call_actor_noargs(actor, "OnRep_HasStarted")
    end
    if mode == "timer" or mode == "full" then
        actions[#actions + 1] = call_actor_noargs(actor, "OnEventTimer")
    end
    return actions
end

function M.kick(args)
    local raw = trim(args)
    if raw == "" then return false, "usage: world.event.kick <latest|index|name> <auto|start|fields|timer|beginplay|all> confirm" end
    if not has_confirm(raw) then return false, "world.event.kick is mutating; append confirm" end
    local clean = strip_confirm(raw)
    local words = split_words(clean)
    local selector = words[1] or "latest"
    local mode = tostring(words[2] or "auto"):lower()
    if selector == "auto" or selector == "start" or selector == "fields" or selector == "timer" or selector == "beginplay" or selector == "all" then
        mode = selector
        selector = "latest"
    end
    local valid_modes = { auto = true, start = true, fields = true, timer = true, beginplay = true, all = true }
    if not valid_modes[mode] then return false, "usage: world.event.kick <latest|index|name> <auto|start|fields|timer|beginplay|all> confirm" end
    local entry, select_err, entries = select_event_actor(selector)
    if not entry then return false, select_err end
    local actor = entry.actor
    local report = {
        generated_unix = os.time(),
        selector = selector,
        mode = mode,
        live_event_count = entries and #entries or nil,
        target = {
            label = entry.label,
            full_name = entry.full_name,
            class = entry.class,
            instance = entry.instance,
        },
        before = event_actor_snapshot(actor),
        actions = {},
    }
    local lines = {
        "World Event Kick Probe",
        string.format("target=%s full=%s mode=%s", tostring(entry.label), tostring(entry.full_name), tostring(mode)),
    }
    for _, line in ipairs(event_actor_summary_lines("before", report.before)) do lines[#lines + 1] = line end

    local do_fields = mode == "auto" or mode == "fields" or mode == "all"
    local do_start = mode == "auto" or mode == "start" or mode == "all"
    local do_timer = mode == "timer" or mode == "all"
    local do_beginplay = mode == "beginplay" or mode == "all"

    if do_fields then
        local field_actions = kick_write_start_fields(actor)
        for _, action in ipairs(field_actions) do report.actions[#report.actions + 1] = action end
    end
    if do_start then
        local methods = mode == "all" and { "OnEventStart", "OnEventStart_Implementation" } or { "OnEventStart" }
        for _, method_name in ipairs(methods) do
            report.actions[#report.actions + 1] = call_actor_noargs(actor, method_name)
        end
    end
    if do_beginplay then
        for _, method_name in ipairs({ "ReceiveBeginPlay", "K2_ReceiveBeginPlay" }) do
            report.actions[#report.actions + 1] = call_actor_noargs(actor, method_name)
        end
    end
    if do_timer then
        for _, method_name in ipairs({ "OnEventTimer", "OnPauseTimer" }) do
            report.actions[#report.actions + 1] = call_actor_noargs(actor, method_name)
        end
    end

    for i, action in ipairs(report.actions) do
        if action.method then
            lines[#lines + 1] = string.format("#%d call %s present=%s ok=%s error=%s result=%s",
                i,
                tostring(action.method),
                tostring(action.present),
                tostring(action.ok),
                tostring(action.error or ""),
                tostring(action.result or ""))
        else
            lines[#lines + 1] = string.format("#%d write %s=%s ok=%s error=%s before=%s after=%s",
                i,
                tostring(action.field),
                tostring(action.value),
                tostring(action.ok),
                tostring(action.error or ""),
                action.before and tostring(action.before.value) or "<none>",
                action.after and tostring(action.after.value) or "<none>")
        end
    end
    report.after = event_actor_snapshot(actor)
    report.active_after = active_snapshot(50)
    for _, line in ipairs(event_actor_summary_lines("after", report.after)) do lines[#lines + 1] = line end
    lines[#lines + 1] = "active_after=" .. tostring(report.active_after.detail)
    local ok_write, path_or_err = write_report("world_event_kick", report, lines)
    local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
    return true, string.format("target=%s mode=%s actions=%d active=%d%s",
        tostring(entry.label),
        tostring(mode),
        #report.actions,
        tonumber(report.active_after.active_count) or 0,
        wrote)
end

local function resolve_event_uclass(class_path)
    local normalized = player_core.normalize_uclass_path(class_path)
    local cls, route, cp = player_core.resolve_uclass_via_kismet_softclass(normalized)
    if is_valid(cls) then return cls, route, cp or normalized end
    local load_error = route
    local direct = player_core.resolve_uclass(normalized)
    if is_valid(direct) then return direct, "resolve_uclass after " .. tostring(load_error), normalized end
    return nil, tostring(load_error or "resolve_uclass failed"), normalized
end

local function resolve_event_uclass_candidates(class_path, rec, full_scan)
    local attempts = {}
    local found_cls, found_route, found_path = nil, nil, nil
    local candidates = event_class_candidates(class_path, rec)
    if #candidates == 0 and trim(class_path) ~= "" then
        candidates = { { path = trim(class_path), reason = "raw" } }
    end

    for i, candidate in ipairs(candidates) do
        local cls, route, normalized = resolve_event_uclass(candidate.path)
        local ok = is_valid(cls)
        local attempt = {
            index = i,
            path = candidate.path,
            reason = candidate.reason,
            normalized = normalized,
            route = route,
            ok = ok and true or false,
        }
        if ok then
            attempt.class_label = object_label(cls)
            if not found_cls then
                found_cls = cls
                found_route = tostring(candidate.reason) .. " via " .. tostring(route)
                found_path = normalized or candidate.path
            end
        end
        attempts[#attempts + 1] = attempt
        if ok and not full_scan then break end
    end

    if found_cls then return found_cls, found_route, found_path, attempts end
    local last = attempts[#attempts]
    local detail = "all class candidates failed"
    if last then detail = detail .. "; last=" .. tostring(last.route) end
    return nil, detail, last and last.normalized or player_core.normalize_uclass_path(class_path), attempts
end

local function spawn_event_actor(class_obj, source_actor)
    if not is_valid(class_obj) then return nil, "invalid event class" end
    local world = feature_field.resolve_root("world")
    if not is_valid(world) then return nil, "UWorld unavailable" end
    if not world.SpawnActor then return nil, "UWorld:SpawnActor missing" end
    local loc = actor_location(source_actor) or { X = 0, Y = 0, Z = 0 }
    local rot = actor_rotation(source_actor) or { Pitch = 0, Yaw = 0, Roll = 0 }
    local spawn_loc = { X = loc.X or loc.x or 0, Y = loc.Y or loc.y or 0, Z = loc.Z or loc.z or 0 }
    local spawn_rot = { Pitch = rot.Pitch or rot.pitch or 0, Yaw = rot.Yaw or rot.yaw or 0, Roll = rot.Roll or rot.roll or 0 }
    local actor
    local ok, err = pcall(function() actor = world:SpawnActor(class_obj, spawn_loc, spawn_rot) end)
    if not ok then return nil, "SpawnActor failed: " .. first_error_line(err) end
    if not is_valid(actor) then return nil, "SpawnActor returned invalid" end
    return actor, nil, spawn_loc, spawn_rot
end

local function catalog_runtime_path_for_class(short_class)
    local short = trim(short_class)
    if short == "" then return nil end
    local root = mod_paths.mod_root()
    if not root then return nil end
    local body = mod_paths.read_file(root .. "\\json\\SpawnCatalog.json")
    if type(body) ~= "string" or body == "" then return nil end
    local variants = { short }
    if short:sub(1, 1) == "A" then
        variants[#variants + 1] = short:sub(2)
    else
        variants[#variants + 1] = "A" .. short
    end
    local no_c = short:gsub("_C$", "")
    variants[#variants + 1] = no_c
    variants[#variants + 1] = no_c:gsub("^A", "")
    for _, needle in ipairs(variants) do
        if needle and needle ~= "" then
            local pos = body:find('"' .. needle .. '"', 1, true)
            if pos then
                local end_pos = math.min(#body, pos + 2200)
                local chunk = body:sub(pos, end_pos)
                local runtime = chunk:match('"runtimePath"%s*:%s*"([^"]+)"')
                if runtime and runtime ~= "" then return runtime, "SpawnCatalog near " .. needle end
            end
        end
    end
    return nil
end

local function ai_class_path_from_text(raw_text)
    local text = trim(raw_text)
    if text == "" or text == "nil" or text == "<none>" then return "", "empty" end
    local direct = text:match("(/[%w_./]+_C)") or text:match("(/[%w_./]+)")
    if direct and direct ~= "" then return direct, "raw_soft_path" end
    local short = text:match("([%w_]+_C)") or text:match("([%w_]+)$") or text
    local alias = AI_CLASS_PATH_ALIASES[short]
    if alias then return alias, "built_in_alias:" .. short end
    local catalog, catalog_route = catalog_runtime_path_for_class(short)
    if catalog then return catalog, catalog_route end
    return text, "raw_text"
end

local function number_from_field(obj, field, fallback)
    local value, ok = read_raw_field(obj, field)
    if ok then
        local n = tonumber(value_text(value))
        if n then return n end
    end
    return fallback
end

local function wave_entry_details(entry)
    local details, ok_details, details_err = read_raw_field(entry, "AISpawnDetails")
    local rec = {
        entry = wave_entry_snapshot(entry, 1, "selected"),
        details_ok = ok_details and true or false,
        details_error = ok_details and nil or tostring(details_err),
    }
    if ok_details and details ~= nil then
        local ai_class_value, ok_class, class_err = read_raw_field(details, "AIClass")
        rec.raw_ai_class = ok_class and value_text(ai_class_value) or ("<err:" .. tostring(class_err) .. ">")
        rec.power_level = number_from_field(details, "PowerLevel", 1)
    else
        rec.raw_ai_class = read_path_text_safe(entry, "AISpawnDetails.AIClass") or ""
        rec.power_level = tonumber(read_path_text_safe(entry, "AISpawnDetails.PowerLevel")) or 1
    end
    rec.class_path, rec.class_path_route = ai_class_path_from_text(rec.raw_ai_class)
    rec.budget_cost = number_from_field(entry, "BudgetCostPerAI", nil)
    rec.weight = number_from_field(entry, "Weight", nil)
    rec.number_spawned_to_weight = number_from_field(entry, "NumberSpawnedToWeight", nil)
    return rec
end

local function collect_wave_entries(container, kind)
    local entries = {}
    local count = container_count(container)
    for i = 1, count do
        local entry = container_item(container, i)
        if entry ~= nil then
            entries[#entries + 1] = {
                entry = entry,
                entry_kind = kind,
                entry_index = i,
                details = wave_entry_details(entry),
            }
        end
    end
    return entries
end

local function append_entries(target, source)
    for _, entry in ipairs(source or {}) do target[#target + 1] = entry end
end

local function choose_first_wave_entries(source, wave, wave_index)
    local fillers, ok_fillers = read_raw_field(wave, "SpawnFillers")
    local filler_entries = ok_fillers and collect_wave_entries(fillers, "filler") or {}
    if #filler_entries > 0 then
        return {
            source = source,
            wave_index = wave_index,
            entry_kind = filler_entries[1].entry_kind,
            entry_index = filler_entries[1].entry_index,
            wave = wave_snapshot(wave, wave_index, "fields"),
            details = filler_entries[1].details,
            entries = filler_entries,
        }
    end

    local specials, ok_specials = read_raw_field(wave, "SpawnSpecials")
    local special_entries = ok_specials and collect_wave_entries(specials, "special") or {}
    if #special_entries > 0 then
        return {
            source = source,
            wave_index = wave_index,
            entry_kind = special_entries[1].entry_kind,
            entry_index = special_entries[1].entry_index,
            wave = wave_snapshot(wave, wave_index, "fields"),
            details = special_entries[1].details,
            entries = special_entries,
        }
    end
    return nil
end

local function choose_wave_entry(actor)
    local waves, ok_waves = read_raw_field(actor, "Waves")
    if ok_waves and container_count(waves) > 0 then
        local wave = container_item(waves, 1)
        local chosen = choose_first_wave_entries("base_raid", wave, 1)
        if chosen then return chosen end
        return nil, "base raid wave exists but has no SpawnFillers/SpawnSpecials entries"
    end

    local hunted_wave, ok_hunted = read_raw_field(actor, "AIToSpawn")
    if ok_hunted and hunted_wave ~= nil then
        local chosen = choose_first_wave_entries("hunted", hunted_wave, 1)
        if chosen then return chosen end
    end
    return nil, "no readable wave entries on Waves or AIToSpawn"
end

local function yaw_between(from_loc, to_loc)
    local dx = (to_loc.X or 0) - (from_loc.X or 0)
    local dy = (to_loc.Y or 0) - (from_loc.Y or 0)
    local radians
    if math.atan2 then radians = math.atan2(dy, dx) else radians = math.atan(dy, dx) end
    return radians * 180.0 / math.pi
end

local function spawn_ai_actor(class_obj, player, index, total)
    if not is_valid(class_obj) then return nil, "invalid AI class" end
    local world = feature_field.resolve_root("world")
    if not is_valid(world) then return nil, "UWorld unavailable" end
    if not world.SpawnActor then return nil, "UWorld:SpawnActor missing" end
    local origin = actor_location(player)
    local prot = actor_rotation(player)
    local yaw = tonumber(prot and prot.Yaw) or 0
    local angle_offset = ((tonumber(index) or 1) - ((tonumber(total) or 1) + 1) / 2) * 22.5
    local angle = (yaw + angle_offset) * math.pi / 180.0
    local dist = 900.0
    local loc = {
        X = (origin.X or 0) + math.cos(angle) * dist,
        Y = (origin.Y or 0) + math.sin(angle) * dist,
        Z = (origin.Z or 0) + 50.0,
    }
    local rot = { Pitch = 0, Yaw = yaw_between(loc, origin), Roll = 0 }
    local actor
    local ok, err = pcall(function() actor = world:SpawnActor(class_obj, loc, rot) end)
    if not ok then return nil, "SpawnActor failed: " .. first_error_line(err), loc, rot end
    if not is_valid(actor) then return nil, "SpawnActor returned invalid", loc, rot end
    return actor, nil, loc, rot
end

local function spawn_ai_post_actions(actor, player, power_level)
    local actions = {}
    actions[#actions + 1] = write_actor_field(actor, "PowerLevel", tonumber(power_level) or 1)
    actions[#actions + 1] = write_actor_field(actor, "bSpawnedByAiDirector", true)
    actions[#actions + 1] = write_actor_field(actor, "Instigator", player)
    actions[#actions + 1] = call_actor_noargs(actor, "SpawnDefaultController")
    return actions
end

local function auto_wave_count(chosen)
    local details = chosen and chosen.details or {}
    local budget = nil
    local wave = chosen and chosen.wave
    local spawn_budget = wave and wave.fields and wave.fields.SpawnBudget
    if spawn_budget and spawn_budget.ok then budget = tonumber(spawn_budget.value) end
    local cost = tonumber(details.budget_cost)
    if budget and cost and cost > 0 then
        return math.floor(budget / cost), "SpawnBudget/BudgetCostPerAI"
    end
    local special_count = tonumber(details.number_spawned_to_weight)
    if special_count and special_count > 0 then
        return math.floor(special_count), "NumberSpawnedToWeight"
    end
    return 3, "fallback"
end

local function wave_count_from_spec(spec, chosen, default_count)
    local raw = trim(spec)
    local lower = raw:lower()
    local count
    local route
    if raw == "" then
        count = tonumber(default_count) or 3
        route = "default"
    elseif lower == "auto" or lower == "full" or lower == "configured" or lower == "wave" then
        count, route = auto_wave_count(chosen)
    else
        count = tonumber(raw)
        route = "explicit"
    end
    if not count then return nil, "count must be a number or auto/full/configured" end
    if count < 1 then count = 1 end
    if count > 24 then count = 24 end
    return math.floor(count), route
end

local function parse_count_and_spawn_mode(words, first_index, default_count_spec)
    local count_spec = tostring(default_count_spec or "auto")
    local spawn_mode = "single"
    for i = first_index or 1, #(words or {}) do
        local word = tostring(words[i] or "")
        local lower = word:lower()
        if lower == "mixed" or lower == "mix" or lower == "weighted" or lower == "allfillers" or lower == "all" then
            spawn_mode = "mixed"
        elseif lower == "single" or lower == "first" or lower == "default" then
            spawn_mode = "single"
        elseif word ~= "" then
            count_spec = word
        end
    end
    return count_spec, spawn_mode
end

local function entry_effective_weight(entry)
    local details = entry and entry.details or {}
    local weight = tonumber(details.weight) or 1
    local cost = tonumber(details.budget_cost) or 1
    if weight <= 0 then weight = 1 end
    if cost <= 0 then cost = 1 end
    return weight / cost
end

local function build_spawn_plan(chosen, count, spawn_mode)
    local entries = {}
    if spawn_mode == "mixed" then
        for _, entry in ipairs((chosen and chosen.entries) or {}) do
            entries[#entries + 1] = entry
        end
    end
    if #entries == 0 and chosen then
        entries[#entries + 1] = {
            entry_kind = chosen.entry_kind,
            entry_index = chosen.entry_index,
            details = chosen.details,
        }
    end

    local total_weight = 0
    for _, entry in ipairs(entries) do total_weight = total_weight + entry_effective_weight(entry) end
    if total_weight <= 0 then total_weight = #entries end

    local plan = {}
    local assigned = 0
    for i, entry in ipairs(entries) do
        local exact = (tonumber(count) or 0) * (entry_effective_weight(entry) / total_weight)
        local amount = math.floor(exact)
        plan[#plan + 1] = {
            entry = entry,
            count = amount,
            remainder = exact - amount,
            order = i,
        }
        assigned = assigned + amount
    end
    table.sort(plan, function(a, b)
        if (a.remainder or 0) ~= (b.remainder or 0) then return (a.remainder or 0) > (b.remainder or 0) end
        return (a.order or 0) < (b.order or 0)
    end)
    local remaining = (tonumber(count) or 0) - assigned
    local idx = 1
    while remaining > 0 and #plan > 0 do
        plan[idx].count = (plan[idx].count or 0) + 1
        remaining = remaining - 1
        idx = idx + 1
        if idx > #plan then idx = 1 end
    end
    table.sort(plan, function(a, b) return (a.order or 0) < (b.order or 0) end)
    return plan
end

local function remember_spawn_batch(selector, spawned_refs)
    local refs = {}
    for _, rec in ipairs(spawned_refs or {}) do
        if is_valid(rec.actor) then
            refs[#refs + 1] = rec
        end
    end
    if #refs == 0 then return nil end
    local batch = {
        id = LAST_SPAWNED_AI.next_batch_id,
        generated_unix = os.time(),
        selector = selector,
        actors = refs,
    }
    LAST_SPAWNED_AI.next_batch_id = (LAST_SPAWNED_AI.next_batch_id or 1) + 1
    LAST_SPAWNED_AI.batches[#LAST_SPAWNED_AI.batches + 1] = batch
    return batch
end

local function spawned_batch_status()
    local live_batches, live_actors = 0, 0
    for _, batch in ipairs(LAST_SPAWNED_AI.batches or {}) do
        local batch_live = 0
        for _, rec in ipairs(batch.actors or {}) do
            if is_valid(rec.actor) and not actor_is_being_destroyed_for_scan(rec.actor) then
                batch_live = batch_live + 1
            end
        end
        if batch_live > 0 then
            live_batches = live_batches + 1
            live_actors = live_actors + batch_live
        end
    end
    return live_batches, live_actors
end

local function spawn_wave_for_actor(actor, selector, count_spec, default_count, file_stem, header, report_extra, lines_extra, spawn_mode)
    local player = feature_net.local_pawn()
    if not is_valid(player) then return false, "no local player pawn" end
    spawn_mode = (spawn_mode == "mixed") and "mixed" or "single"
    local chosen, choose_err = choose_wave_entry(actor)
    local report = {
        generated_unix = os.time(),
        selector = selector,
        requested_count = tostring(count_spec or ""),
        spawn_mode = spawn_mode,
        target = {
            label = object_label(actor),
            full_name = object_full_name(actor),
            class = object_class(actor),
        },
        chosen = chosen,
        spawned = {},
    }
    if report_extra then
        for key, value in pairs(report_extra) do report[key] = value end
    end
    local lines = {
        header or "World Event Wave Spawn Fallback Probe",
        "selector=" .. tostring(selector),
        "target=" .. tostring(object_label(actor)),
        "target_full=" .. tostring(object_full_name(actor)),
        "requested_count=" .. tostring(count_spec or ""),
        "spawn_mode=" .. tostring(spawn_mode),
    }
    for _, line in ipairs(lines_extra or {}) do lines[#lines + 1] = line end
    if not chosen then
        report.error = choose_err
        lines[#lines + 1] = "choose_error=" .. tostring(choose_err)
        local ok_write, path_or_err = write_report(file_stem or "world_event_spawnwave", report, lines)
        local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
        return false, tostring(choose_err) .. wrote
    end

    local count, count_route = wave_count_from_spec(count_spec, chosen, default_count)
    if not count then return false, tostring(count_route) end
    report.count = count
    report.count_route = count_route
    local plan = build_spawn_plan(chosen, count, spawn_mode)
    report.plan = {}
    lines[#lines + 1] = "count=" .. tostring(count) .. " route=" .. tostring(count_route)
    lines[#lines + 1] = string.format("chosen source=%s wave=%s entry=%s#%s entries=%d",
        tostring(chosen.source),
        tostring(chosen.wave_index),
        tostring(chosen.entry_kind),
        tostring(chosen.entry_index),
        #((chosen and chosen.entries) or {}))

    local spawned_refs = {}
    local global_index = 0
    for plan_index, plan_entry in ipairs(plan) do
        local entry = plan_entry.entry or {}
        local details = entry.details or {}
        local class_obj, class_route, normalized_path = resolve_event_uclass(details.class_path)
        local plan_rec = {
            index = plan_index,
            entry_kind = entry.entry_kind,
            entry_index = entry.entry_index,
            count = plan_entry.count or 0,
            raw_ai_class = details.raw_ai_class,
            class_path = details.class_path,
            class_route = class_route,
            normalized_path = normalized_path,
            ok = is_valid(class_obj),
            power_level = details.power_level,
            budget_cost = details.budget_cost,
            weight = details.weight,
        }
        report.plan[#report.plan + 1] = plan_rec
        lines[#lines + 1] = string.format("plan#%d entry=%s#%s count=%d raw_class=%s class=%s route=%s ok=%s power=%s budget=%s weight=%s",
            plan_index,
            tostring(entry.entry_kind),
            tostring(entry.entry_index),
            tonumber(plan_entry.count) or 0,
            tostring(details.raw_ai_class),
            tostring(details.class_path),
            tostring(class_route),
            tostring(is_valid(class_obj)),
            tostring(details.power_level),
            tostring(details.budget_cost),
            tostring(details.weight))
        if (plan_entry.count or 0) > 0 and not is_valid(class_obj) then
            local ok_write, path_or_err = write_report(file_stem or "world_event_spawnwave", report, lines)
            local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
            return false, "class resolution failed: " .. tostring(class_route) .. " (" .. tostring(normalized_path) .. ")" .. wrote
        end
        local spawn_count_for_entry = tonumber(plan_entry.count) or 0
        for _ = 1, spawn_count_for_entry do
            global_index = global_index + 1
            local actor, spawn_err, loc, rot = spawn_ai_actor(class_obj, player, global_index, count)
            local spawn_rec = {
                index = global_index,
                plan_index = plan_index,
                entry_kind = entry.entry_kind,
                entry_index = entry.entry_index,
                class_path = details.class_path,
                ok = is_valid(actor),
                error = spawn_err,
                location = loc,
                rotation = rot,
                actions = {},
            }
            if is_valid(actor) then
                spawn_rec.label = object_label(actor)
                spawn_rec.full_name = object_full_name(actor)
                spawn_rec.actions = spawn_ai_post_actions(actor, player, details.power_level)
                spawned_refs[#spawned_refs + 1] = {
                    actor = actor,
                    label = spawn_rec.label,
                    full_name = spawn_rec.full_name,
                    class_path = details.class_path,
                    selector = selector,
                }
                lines[#lines + 1] = string.format("#%d spawned=%s entry=%s#%s loc=(%.1f,%.1f,%.1f) yaw=%.1f actions=%d",
                    global_index,
                    object_label(actor),
                    tostring(entry.entry_kind),
                    tostring(entry.entry_index),
                    tonumber(loc and loc.X) or 0,
                    tonumber(loc and loc.Y) or 0,
                    tonumber(loc and loc.Z) or 0,
                    tonumber(rot and rot.Yaw) or 0,
                    #(spawn_rec.actions or {}))
            else
                lines[#lines + 1] = string.format("#%d spawn_error=%s", global_index, tostring(spawn_err))
            end
            report.spawned[#report.spawned + 1] = spawn_rec
        end
    end
    local batch = remember_spawn_batch(selector, spawned_refs)
    if batch then
        report.spawn_batch = { id = batch.id, count = #batch.actors }
        lines[#lines + 1] = string.format("spawn_batch id=%d tracked=%d", tonumber(batch.id) or 0, #batch.actors)
    end
    report.active_after = active_snapshot(50)
    lines[#lines + 1] = "active_after=" .. tostring(report.active_after.detail)
    local ok_write, path_or_err = write_report(file_stem or "world_event_spawnwave", report, lines)
    local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
    local spawned_count = 0
    for _, rec in ipairs(report.spawned) do if rec.ok then spawned_count = spawned_count + 1 end end
    return true, string.format("source=%s mode=%s entry=%s#%s spawned=%d/%d classes=%d%s",
        tostring(chosen.source),
        tostring(spawn_mode),
        tostring(chosen.entry_kind),
        tostring(chosen.entry_index),
        spawned_count,
        count,
        #(report.plan or {}),
        wrote)
end

function M.spawn_wave(args)
    local raw = trim(args)
    if raw == "" then return false, "usage: world.event.spawnwave <latest|index|name> [count|auto] confirm" end
    if not has_confirm(raw) then return false, "world.event.spawnwave is mutating; append confirm" end
    local clean = strip_confirm(raw)
    local words = split_words(clean)
    local selector = words[1] or "latest"
    local count_spec, spawn_mode = parse_count_and_spawn_mode(words, 2, "")
    local entry, select_err = select_event_actor(selector)
    if not entry then return false, select_err end
    return spawn_wave_for_actor(entry.actor, selector, count_spec, 3, "world_event_spawnwave", nil, nil, nil, spawn_mode)
end

local function compact_spawn_batch(batch)
    local live = 0
    local actors = {}
    for _, rec in ipairs((batch and batch.actors) or {}) do
        local valid = is_valid(rec.actor) and not actor_is_being_destroyed_for_scan(rec.actor)
        if valid then live = live + 1 end
        actors[#actors + 1] = {
            label = rec.label or object_label(rec.actor),
            full_name = rec.full_name or object_full_name(rec.actor),
            class_path = rec.class_path,
            selector = rec.selector,
            valid = valid,
        }
    end
    return {
        id = batch and batch.id,
        generated_unix = batch and batch.generated_unix,
        selector = batch and batch.selector,
        live = live,
        actors = actors,
    }
end

local function prune_spawn_batches()
    local kept = {}
    for _, batch in ipairs(LAST_SPAWNED_AI.batches or {}) do
        local live_actors = {}
        for _, rec in ipairs(batch.actors or {}) do
            if is_valid(rec.actor) and not actor_is_being_destroyed_for_scan(rec.actor) then
                live_actors[#live_actors + 1] = rec
            end
        end
        if #live_actors > 0 then
            batch.actors = live_actors
            kept[#kept + 1] = batch
        end
    end
    LAST_SPAWNED_AI.batches = kept
end

function M.cleanup_spawned(args)
    local raw = trim(args)
    local clean = strip_confirm(raw)
    local words = split_words(clean)
    local selector = words[1] or "status"
    if selector == "" then selector = "status" end
    local lower = selector:lower()

    if lower == "status" or lower == "list" then
        prune_spawn_batches()
        local live_batches, live_actors = spawned_batch_status()
        local report = {
            generated_unix = os.time(),
            next_batch_id = LAST_SPAWNED_AI.next_batch_id,
            live_batches = live_batches,
            live_actors = live_actors,
            batches = {},
        }
        local lines = {
            "World Event Spawned AI Status",
            string.format("live_batches=%d live_actors=%d next_batch_id=%d",
                live_batches,
                live_actors,
                tonumber(LAST_SPAWNED_AI.next_batch_id) or 1),
        }
        for _, batch in ipairs(LAST_SPAWNED_AI.batches or {}) do
            local rec = compact_spawn_batch(batch)
            report.batches[#report.batches + 1] = rec
            lines[#lines + 1] = string.format("batch#%s selector=%s live=%d total=%d",
                tostring(rec.id),
                tostring(rec.selector),
                tonumber(rec.live) or 0,
                #(rec.actors or {}))
        end
        local ok_write, path_or_err = write_report("world_event_cleanupspawned", report, lines)
        local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
        return true, string.format("tracked batches=%d actors=%d%s", live_batches, live_actors, wrote)
    end

    if not has_confirm(raw) then
        return false, "world.event.cleanupspawned is mutating; use status, or append confirm"
    end

    prune_spawn_batches()
    local targets = {}
    if lower == "all" then
        for _, batch in ipairs(LAST_SPAWNED_AI.batches or {}) do targets[#targets + 1] = batch end
    elseif lower == "latest" or lower == "last" then
        local latest = LAST_SPAWNED_AI.batches[#LAST_SPAWNED_AI.batches]
        if latest then targets[#targets + 1] = latest end
    else
        local id = tonumber(selector)
        if not id then return false, "usage: world.event.cleanupspawned <status|latest|all|batch_id> [confirm]" end
        for _, batch in ipairs(LAST_SPAWNED_AI.batches or {}) do
            if tonumber(batch.id) == id then targets[#targets + 1] = batch end
        end
    end
    local report = {
        generated_unix = os.time(),
        selector = selector,
        destroyed = {},
    }
    local lines = {
        "World Event Spawned AI Cleanup",
        "selector=" .. tostring(selector),
    }
    if #targets == 0 then
        report.after = { live_batches = 0, live_actors = 0 }
        lines[#lines + 1] = "no tracked spawned AI matched; cleanup is already clear"
        lines[#lines + 1] = "after live_batches=0 live_actors=0"
        local ok_write, path_or_err = write_report("world_event_cleanupspawned", report, lines)
        local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
        return true, "destroyed=0 tracked_after=0/0" .. wrote
    end
    local destroyed = 0
    for _, batch in ipairs(targets) do
        lines[#lines + 1] = string.format("batch#%s selector=%s", tostring(batch.id), tostring(batch.selector))
        for _, rec in ipairs(batch.actors or {}) do
            local ok_destroy, detail
            if is_valid(rec.actor) and not actor_is_being_destroyed_for_scan(rec.actor) then
                ok_destroy, detail = destroy_actor_safe(rec.actor)
            else
                ok_destroy, detail = false, "invalid or already destroying"
            end
            if ok_destroy then destroyed = destroyed + 1 end
            local row = {
                batch_id = batch.id,
                label = rec.label or object_label(rec.actor),
                full_name = rec.full_name or object_full_name(rec.actor),
                class_path = rec.class_path,
                ok = ok_destroy and true or false,
                detail = tostring(detail),
            }
            report.destroyed[#report.destroyed + 1] = row
            lines[#lines + 1] = string.format("  %s destroy=%s:%s",
                tostring(row.label),
                ok_destroy and "ok" or "err",
                tostring(detail))
        end
    end
    prune_spawn_batches()
    local live_batches, live_actors = spawned_batch_status()
    report.after = { live_batches = live_batches, live_actors = live_actors }
    lines[#lines + 1] = string.format("after live_batches=%d live_actors=%d", live_batches, live_actors)
    local ok_write, path_or_err = write_report("world_event_cleanupspawned", report, lines)
    local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
    return true, string.format("destroyed=%d tracked_after=%d/%d%s", destroyed, live_batches, live_actors, wrote)
end

local function forget_spawn_batches_from(start_id)
    local threshold = tonumber(start_id)
    if not threshold then return 0, 0 end
    local kept, forgotten_batches, forgotten_actors = {}, 0, 0
    for _, batch in ipairs(LAST_SPAWNED_AI.batches or {}) do
        if (tonumber(batch.id) or 0) >= threshold then
            forgotten_batches = forgotten_batches + 1
            forgotten_actors = forgotten_actors + #((batch and batch.actors) or {})
        else
            kept[#kept + 1] = batch
        end
    end
    LAST_SPAWNED_AI.batches = kept
    return forgotten_batches, forgotten_actors
end

function M.spawn_probe(args)
    local raw = trim(args)
    if raw == "" then return false, "usage: world.event.spawnprobe <definition_index|persistence_id|alias> [keep|destroy] confirm" end
    if not has_confirm(raw) then return false, "world.event.spawnprobe is mutating; append confirm" end
    local clean = strip_confirm(raw)
    local words = split_words(clean)
    local token = words[1] or ""
    local cleanup_mode = tostring(words[2] or "destroy"):lower()
    local keep_spawned = cleanup_mode == "keep" or cleanup_mode == "live"
    if cleanup_mode ~= "" and cleanup_mode ~= "destroy" and cleanup_mode ~= "cleanup" and cleanup_mode ~= "keep" and cleanup_mode ~= "live" then
        return false, "usage: world.event.spawnprobe <definition_index|persistence_id|alias> [keep|destroy] confirm"
    end

    local manager, def, count, err, index = definition_by_token(token)
    if not def then return false, err end
    local rec = definition_record(def, index or 0)
    local class_path = definition_class_path(rec)
    if class_path == "" or class_path == "nil" then return false, "definition has no WorldEventClass path" end

    local player = feature_net.local_pawn()
    if not is_valid(player) then return false, "no local player pawn" end
    local event_name = tostring(rec.PersistenceID or "")
    local before_active = active_snapshot(50)
    local class_obj, class_route, normalized_path, class_attempts = resolve_event_uclass_candidates(class_path, rec, false)
    local report = {
        generated_unix = os.time(),
        definition_index = index,
        definition_count = count,
        definition = rec,
        event_name = event_name,
        class_path = class_path,
        normalized_class_path = normalized_path,
        class_route = class_route,
        class_attempts = class_attempts,
        manager = object_label(manager),
        manager_full_name = object_full_name(manager),
        cleanup_mode = keep_spawned and "keep" or "destroy",
        before = {
            active = before_active,
            manager = manager_compact_snapshot(manager, event_name),
        },
    }
    local lines = {
        "World Event Direct Spawn Probe",
        string.format("definition #%s/%s DebugName=%s PersistenceID=%s EventClass=%s",
            tostring(index or "?"),
            tostring(count or "?"),
            tostring(rec.DebugName),
            event_name,
            class_path),
        "manager=" .. object_label(manager),
        "class_route=" .. tostring(class_route) .. " normalized=" .. tostring(normalized_path),
        "cleanup_mode=" .. (keep_spawned and "keep" or "destroy"),
        "before_active=" .. tostring(before_active.detail),
    }
    if class_attempts and #class_attempts > 0 then
        for _, attempt in ipairs(class_attempts) do
            lines[#lines + 1] = string.format("class_attempt#%d %s ok=%s reason=%s route=%s",
                tonumber(attempt.index) or 0,
                tostring(attempt.normalized or attempt.path),
                tostring(attempt.ok),
                tostring(attempt.reason),
                tostring(attempt.route))
        end
    end
    if not is_valid(class_obj) then
        report.spawn_ok = false
        report.spawn_error = "class resolution failed"
        local ok_write, path_or_err = write_report("world_event_spawnprobe", report, lines)
        local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
        return false, "class resolution failed: " .. tostring(class_route) .. " (" .. tostring(normalized_path) .. ")" .. wrote
    end

    local actor, spawn_err, spawn_loc, spawn_rot = spawn_event_actor(class_obj, player)
    report.spawn = {
        ok = is_valid(actor),
        error = spawn_err,
        location = spawn_loc,
        rotation = spawn_rot,
    }
    if not is_valid(actor) then
        lines[#lines + 1] = "spawn_error=" .. tostring(spawn_err)
        report.after = {
            active = active_snapshot(50),
            manager = manager_compact_snapshot(manager, event_name),
        }
        local ok_write, path_or_err = write_report("world_event_spawnprobe", report, lines)
        local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
        return false, tostring(spawn_err) .. wrote
    end

    report.spawned = event_actor_snapshot(actor)
    for _, line in ipairs(event_actor_summary_lines("spawned", report.spawned)) do lines[#lines + 1] = line end
    report.live_after_spawn = {
        active = active_snapshot(50),
        manager = manager_compact_snapshot(manager, event_name),
    }
    lines[#lines + 1] = "active_after_spawn=" .. tostring(report.live_after_spawn.active.detail)

    if keep_spawned then
        report.destroy = { skipped = true }
        report.after = report.live_after_spawn
        lines[#lines + 1] = "destroy=skipped keep"
    else
        local ok_destroy, destroy_detail = destroy_actor_safe(actor)
        report.destroy = { ok = ok_destroy and true or false, detail = tostring(destroy_detail) }
        lines[#lines + 1] = "destroy=" .. (ok_destroy and "ok:" or "err:") .. tostring(destroy_detail)
        report.after = {
            active = active_snapshot(50),
            manager = manager_compact_snapshot(manager, event_name),
        }
        lines[#lines + 1] = "active_after_destroy=" .. tostring(report.after.active.detail)
    end

    local ok_write, path_or_err = write_report("world_event_spawnprobe", report, lines)
    local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
    local active_after_spawn = tonumber(report.live_after_spawn.active.active_count) or 0
    local active_after_final = tonumber(report.after.active.active_count) or 0
    return true, string.format("#%s %s spawn=%s active_after_spawn=%d final_active=%d cleanup=%s%s",
        tostring(index or "?"),
        event_name,
        object_label(actor),
        active_after_spawn,
        active_after_final,
        keep_spawned and "keep" or tostring(report.destroy.detail),
        wrote)
end

function M.start_probe(args)
    local raw = trim(args)
    if raw == "" then return false, "usage: world.event.startprobe <definition_index|persistence_id|alias> [groupTag|none] confirm" end
    if not has_confirm(raw) then return false, "world.event.startprobe is mutating; append confirm" end
    local clean = strip_confirm(raw)
    local words = split_words(clean)
    local token = words[1] or ""
    local group_token = words[2] or ""
    local manager, def, count, err, index = definition_by_token(token)
    if not def then return false, err end

    local rec = definition_record(def, index or 0)
    local event_name = tostring(rec.PersistenceID or "")
    local ok_class, definition_event_class = pcall(function() return def.WorldEventClass end)
    if not ok_class or definition_event_class == nil then
        return false, "definition has no WorldEventClass: " .. tostring(ok_class and "nil" or first_error_line(definition_event_class))
    end

    local player = feature_net.local_pawn()
    if not is_valid(player) then return false, "no local player pawn" end
    local transform = build_transform_from_actor(player)
    local report = {
        generated_unix = os.time(),
        definition_index = index,
        definition_count = count,
        definition = rec,
        event_name = event_name,
        manager = object_label(manager),
        manager_full_name = object_full_name(manager),
        transform = transform,
        before = {
            manager = manager_compact_snapshot(manager, event_name),
            active = active_snapshot(25),
        },
        attempts = {},
    }
    local lines = {
        "World Event Start Probe",
        string.format("definition #%s/%s DebugName=%s PersistenceID=%s EventClass=%s",
            tostring(index or "?"),
            tostring(count or "?"),
            tostring(rec.DebugName),
            event_name,
            tostring(rec.WorldEventClassPath or rec.WorldEventClass)),
        "manager=" .. object_label(manager),
        "loc=" .. transform_text(transform),
        "before_active=" .. tostring(report.before.active.detail),
    }

    local event_class_variants = {
        { label = "definition_softptr", value = definition_event_class },
    }
    local soft_ref, soft_route = nil, nil
    local normalized_definition_class_path = definition_class_path(rec)
    if normalized_definition_class_path and tostring(normalized_definition_class_path) ~= "" then
        soft_ref, soft_route = make_soft_class_ref(tostring(normalized_definition_class_path))
        if soft_ref ~= nil then
            event_class_variants[#event_class_variants + 1] = {
                label = "rebuilt_softref:" .. tostring(soft_route),
                value = soft_ref,
            }
        end
    end

    local target_variants = {
        { label = "targets_player_table", value = { player } },
        { label = "targets_empty_table", value = {} },
    }
    local group_variants = {}
    local explicit_group = make_gameplay_tag(group_token)
    if explicit_group ~= nil then
        group_variants[#group_variants + 1] = { label = "explicit_tag:" .. tostring(group_token), value = explicit_group }
    end
    group_variants[#group_variants + 1] = { label = "nil_tag", value = nil }
    group_variants[#group_variants + 1] = { label = "empty_tag_table", value = {} }

    local stopped_after_success = false
    for _, class_variant in ipairs(event_class_variants) do
        if stopped_after_success then break end
        for _, target_variant in ipairs(target_variants) do
            if stopped_after_success then break end
            for _, group_variant in ipairs(group_variants) do
                local attempt = {
                    class_variant = class_variant.label,
                    target_variant = target_variant.label,
                    group_variant = group_variant.label,
                }
                local ok_call, call_err = pcall(function()
                    manager:StartEvent(class_variant.value, transform, target_variant.value, group_variant.value)
                end)
                attempt.call_ok = ok_call and true or false
                attempt.call_error = ok_call and nil or first_error_line(call_err)
                attempt.active = active_snapshot(25)
                attempt.manager = manager_compact_snapshot(manager, event_name)
                report.attempts[#report.attempts + 1] = attempt
                lines[#lines + 1] = string.format("#%d class=%s targets=%s group=%s call=%s active=%s",
                    #report.attempts,
                    tostring(attempt.class_variant),
                    tostring(attempt.target_variant),
                    tostring(attempt.group_variant),
                    ok_call and "ok" or ("err:" .. tostring(attempt.call_error)),
                    tostring(attempt.active.detail))
                if ok_call and (tonumber(attempt.active.active_count) or 0) > 0 then
                    stopped_after_success = true
                    lines[#lines + 1] = "stopped_after_success=true"
                    break
                end
            end
        end
    end

    report.after = {
        manager = manager_compact_snapshot(manager, event_name),
        active = active_snapshot(50),
        stopped_after_success = stopped_after_success,
    }
    lines[#lines + 1] = "after_active=" .. tostring(report.after.active.detail)
    lines[#lines + 1] = "stopped_after_success=" .. tostring(stopped_after_success)
    local ok_write, path_or_err = write_report("world_event_startprobe", report, lines)
    local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
    return true, string.format("#%s %s attempts=%d active_after=%d stopped_after_success=%s%s",
        tostring(index or "?"),
        event_name,
        #report.attempts,
        tonumber(report.after.active.active_count) or 0,
        tostring(stopped_after_success),
        wrote)
end

function M.resolve(args)
    local raw = trim(args)
    if raw == "" then return false, "usage: world.event.resolve <definition_index|persistence_id|alias|class_path> [first|full]" end
    local words = split_words(raw)
    local token = words[1] or ""
    local mode = tostring(words[2] or "first"):lower()
    local full_scan = mode == "full" or mode == "all"

    local manager, def, count, err, index = nil, nil, nil, nil, nil
    if token:sub(1, 1) ~= "/" and not token:match("_C$") then
        manager, def, count, err, index = definition_by_token(token)
    end
    local rec = def and definition_record(def, index or 0) or nil
    local class_path = rec and definition_class_path(rec) or normalize_event_path(token)
    if class_path == "" or class_path == "nil" then
        return false, "no class path candidate from token: " .. tostring(token)
    end

    local class_obj, class_route, normalized_path, attempts = resolve_event_uclass_candidates(class_path, rec, full_scan)
    local report = {
        generated_unix = os.time(),
        token = token,
        mode = full_scan and "full" or "first",
        definition_index = index,
        definition_count = count,
        definition_error = def and nil or err,
        definition = rec,
        class_path = class_path,
        normalized_class_path = normalized_path,
        class_route = class_route,
        resolved = is_valid(class_obj),
        resolved_class = is_valid(class_obj) and object_label(class_obj) or nil,
        attempts = attempts,
        manager = is_valid(manager) and object_label(manager) or nil,
    }
    local lines = {
        "World Event Class Resolve Probe",
        "token=" .. tostring(token),
        "mode=" .. tostring(report.mode),
        "definition_index=" .. tostring(index or "<none>") .. " definition_error=" .. tostring(err or ""),
        "class_path=" .. tostring(class_path),
        "result=" .. tostring(report.resolved) .. " route=" .. tostring(class_route) .. " normalized=" .. tostring(normalized_path),
    }
    for _, attempt in ipairs(attempts or {}) do
        lines[#lines + 1] = string.format("class_attempt#%d %s ok=%s reason=%s route=%s",
            tonumber(attempt.index) or 0,
            tostring(attempt.normalized or attempt.path),
            tostring(attempt.ok),
            tostring(attempt.reason),
            tostring(attempt.route))
    end
    local safe_token = tostring(token):gsub("[^%w_%-]+", "_"):sub(1, 80)
    if safe_token == "" then safe_token = "token" end
    local ok_write, path_or_err = write_report("world_event_resolve_" .. safe_token, report, lines)
    local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
    if is_valid(class_obj) then
        return true, string.format("resolved token=%s path=%s route=%s attempts=%d%s",
            tostring(token),
            tostring(normalized_path),
            tostring(class_route),
            #(attempts or {}),
            wrote)
    end
    return false, string.format("unresolved token=%s attempts=%d last=%s%s",
        tostring(token),
        #(attempts or {}),
        tostring(class_route),
        wrote)
end

function M.start_live(args)
    local raw = trim(args)
    if raw == "" then return false, "usage: world.event.startlive <definition_index|persistence_id|alias> confirm" end
    if not has_confirm(raw) then return false, "world.event.startlive is mutating; append confirm" end
    local clean = strip_confirm(raw)
    local words = split_words(clean)
    local token = words[1] or ""
    local manager, def, count, err, index = definition_by_token(token)
    if not def then return false, err end
    local rec = definition_record(def, index or 0)
    local class_path = definition_class_path(rec)
    if class_path == "" or class_path == "nil" then return false, "definition has no WorldEventClass path" end

    local player = feature_net.local_pawn()
    if not is_valid(player) then return false, "no local player pawn" end
    local event_name = tostring(rec.PersistenceID or "")
    local class_obj, class_route, normalized_path, class_attempts = resolve_event_uclass_candidates(class_path, rec, false)
    if not is_valid(class_obj) then return false, "class resolution failed: " .. tostring(class_route) .. " (" .. tostring(normalized_path) .. ")" end

    local report = {
        generated_unix = os.time(),
        definition_index = index,
        definition_count = count,
        definition = rec,
        event_name = event_name,
        class_path = class_path,
        normalized_class_path = normalized_path,
        class_route = class_route,
        class_attempts = class_attempts,
        manager = object_label(manager),
        manager_full_name = object_full_name(manager),
        before = {
            active = active_snapshot(50),
            manager = manager_compact_snapshot(manager, event_name),
        },
        actions = {},
    }
    local lines = {
        "World Event Start Live",
        string.format("definition #%s/%s DebugName=%s PersistenceID=%s EventClass=%s",
            tostring(index or "?"),
            tostring(count or "?"),
            tostring(rec.DebugName),
            event_name,
            class_path),
        "manager=" .. object_label(manager),
        "class_route=" .. tostring(class_route) .. " normalized=" .. tostring(normalized_path),
        "before_active=" .. tostring(report.before.active.detail),
    }
    if class_attempts and #class_attempts > 0 then
        for _, attempt in ipairs(class_attempts) do
            lines[#lines + 1] = string.format("class_attempt#%d %s ok=%s reason=%s route=%s",
                tonumber(attempt.index) or 0,
                tostring(attempt.normalized or attempt.path),
                tostring(attempt.ok),
                tostring(attempt.reason),
                tostring(attempt.route))
        end
    end

    local actor, spawn_err, spawn_loc, spawn_rot = spawn_event_actor(class_obj, player)
    report.spawn = {
        ok = is_valid(actor),
        error = spawn_err,
        location = spawn_loc,
        rotation = spawn_rot,
    }
    if not is_valid(actor) then
        lines[#lines + 1] = "spawn_error=" .. tostring(spawn_err)
        local ok_write, path_or_err = write_report("world_event_startlive", report, lines)
        local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
        return false, tostring(spawn_err) .. wrote
    end

    report.spawned_before_start = event_actor_snapshot(actor)
    for _, line in ipairs(event_actor_summary_lines("spawned_before_start", report.spawned_before_start)) do lines[#lines + 1] = line end
    local actions = apply_event_start_actions(actor, false)
    for _, action in ipairs(actions) do report.actions[#report.actions + 1] = action end
    for i, action in ipairs(report.actions) do
        if action.method then
            lines[#lines + 1] = string.format("#%d call %s present=%s ok=%s error=%s result=%s",
                i,
                tostring(action.method),
                tostring(action.present),
                tostring(action.ok),
                tostring(action.error or ""),
                tostring(action.result or ""))
        else
            lines[#lines + 1] = string.format("#%d write %s=%s ok=%s error=%s before=%s after=%s",
                i,
                tostring(action.field),
                tostring(action.value),
                tostring(action.ok),
                tostring(action.error or ""),
                action.before and tostring(action.before.value) or "<none>",
                action.after and tostring(action.after.value) or "<none>")
        end
    end

    report.after = {
        event = event_actor_snapshot(actor),
        active = active_snapshot(50),
        manager = manager_compact_snapshot(manager, event_name),
    }
    for _, line in ipairs(event_actor_summary_lines("after", report.after.event)) do lines[#lines + 1] = line end
    lines[#lines + 1] = "active_after=" .. tostring(report.after.active.detail)
    local ok_write, path_or_err = write_report("world_event_startlive", report, lines)
    local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
    return true, string.format("#%s %s started=%s active=%d%s",
        tostring(index or "?"),
        event_name,
        object_label(actor),
        tonumber(report.after.active.active_count) or 0,
        wrote)
end

function M.dragon_probe(args)
    local raw = trim(args)
    if raw == "" then
        return false, "usage: world.event.dragonprobe <definition_index|persistence_id|alias> [inspect|start|client|rep|timer|full|lifecycle] [confirm]"
    end
    local clean = strip_confirm(raw)
    local words = split_words(clean)
    local token = words[1] or ""
    local mode = tostring(words[2] or "inspect"):lower()
    if mode == "" then mode = "inspect" end
    local valid_modes = {
        inspect = true,
        status = true,
        start = true,
        client = true,
        rep = true,
        timer = true,
        full = true,
        lifecycle = true,
        all = true,
    }
    if not valid_modes[mode] then
        return false, "usage: world.event.dragonprobe <definition_index|persistence_id|alias> [inspect|start|client|rep|timer|full|lifecycle] [confirm]"
    end
    local mutating_mode = mode ~= "inspect" and mode ~= "status"
    if mutating_mode and not has_confirm(raw) then
        return false, "world.event.dragonprobe " .. tostring(mode) .. " is mutating; append confirm"
    end

    local manager, def, count, err, index = definition_by_token(token)
    if not def then return false, err end
    local rec = definition_record(def, index or 0)
    local class_path = definition_class_path(rec)
    if class_path == "" or class_path == "nil" then return false, "definition has no WorldEventClass path" end

    local event_name = tostring(rec.PersistenceID or "")
    local class_obj, class_route, normalized_path, class_attempts = resolve_event_uclass_candidates(class_path, rec, not mutating_mode)
    local report = {
        generated_unix = os.time(),
        token = token,
        mode = mode,
        definition_index = index,
        definition_count = count,
        definition = rec,
        event_name = event_name,
        class_path = class_path,
        normalized_class_path = normalized_path,
        class_route = class_route,
        class_attempts = class_attempts,
        resolved = is_valid(class_obj),
        manager = object_label(manager),
        manager_full_name = object_full_name(manager),
        before = {
            active = active_snapshot(50),
            manager = manager_compact_snapshot(manager, event_name),
        },
        actions = {},
    }
    local lines = {
        "World Event Dragon Probe",
        string.format("definition #%s/%s DebugName=%s PersistenceID=%s EventClass=%s",
            tostring(index or "?"),
            tostring(count or "?"),
            tostring(rec.DebugName),
            event_name,
            class_path),
        "mode=" .. tostring(mode),
        "manager=" .. object_label(manager),
        "class_route=" .. tostring(class_route) .. " normalized=" .. tostring(normalized_path),
        "before_active=" .. tostring(report.before.active.detail),
    }
    for _, attempt in ipairs(class_attempts or {}) do
        lines[#lines + 1] = string.format("class_attempt#%d %s ok=%s reason=%s route=%s",
            tonumber(attempt.index) or 0,
            tostring(attempt.normalized or attempt.path),
            tostring(attempt.ok),
            tostring(attempt.reason),
            tostring(attempt.route))
    end
    if not is_valid(class_obj) then
        report.error = "class resolution failed"
        lines[#lines + 1] = "error=class resolution failed"
        local ok_write, path_or_err = write_report("world_event_dragonprobe", report, lines)
        local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
        return false, "class resolution failed: " .. tostring(class_route) .. " (" .. tostring(normalized_path) .. ")" .. wrote
    end

    if not mutating_mode then
        local ok_write, path_or_err = write_report("world_event_dragonprobe", report, lines)
        local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
        return true, string.format("resolved dragon candidate #%s %s path=%s route=%s%s",
            tostring(index or "?"),
            event_name,
            tostring(normalized_path),
            tostring(class_route),
            wrote)
    end

    local player = feature_net.local_pawn()
    if not is_valid(player) then return false, "no local player pawn" end
    local actor, spawn_err, spawn_loc, spawn_rot = spawn_event_actor(class_obj, player)
    report.event_spawn = {
        ok = is_valid(actor),
        error = spawn_err,
        location = spawn_loc,
        rotation = spawn_rot,
    }
    if not is_valid(actor) then
        lines[#lines + 1] = "event_spawn_error=" .. tostring(spawn_err)
        local ok_write, path_or_err = write_report("world_event_dragonprobe", report, lines)
        local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
        return false, tostring(spawn_err) .. wrote
    end

    report.spawned_before_start = event_actor_snapshot(actor)
    for _, line in ipairs(event_actor_summary_lines("spawned_before_start", report.spawned_before_start)) do
        lines[#lines + 1] = line
    end
    local actions = dragon_lifecycle_actions(actor, mode)
    for _, action in ipairs(actions) do report.actions[#report.actions + 1] = action end
    for i, action in ipairs(report.actions) do
        if action.method then
            lines[#lines + 1] = string.format("start#%d call %s present=%s ok=%s error=%s result=%s",
                i,
                tostring(action.method),
                tostring(action.present),
                tostring(action.ok),
                tostring(action.error or ""),
                tostring(action.result or ""))
        else
            lines[#lines + 1] = string.format("start#%d write %s=%s ok=%s error=%s before=%s after=%s",
                i,
                tostring(action.field),
                tostring(action.value),
                tostring(action.ok),
                tostring(action.error or ""),
                action.before and tostring(action.before.value) or "<none>",
                action.after and tostring(action.after.value) or "<none>")
        end
    end
    report.after = {
        event = event_actor_snapshot(actor),
        active = active_snapshot(50),
        manager = manager_compact_snapshot(manager, event_name),
    }
    for _, line in ipairs(event_actor_summary_lines("after", report.after.event)) do lines[#lines + 1] = line end
    lines[#lines + 1] = "active_after=" .. tostring(report.after.active.detail)
    local ok_write, path_or_err = write_report("world_event_dragonprobe", report, lines)
    local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
    return true, string.format("#%s %s dragonprobe started=%s active=%d%s",
        tostring(index or "?"),
        event_name,
        object_label(actor),
        tonumber(report.after.active.active_count) or 0,
        wrote)
end

function M.dragon_kick(args)
    local raw = trim(args)
    if raw == "" then
        return false, "usage: world.event.dragonkick <latest|index|name> <client|rep|timer|full|lifecycle> confirm"
    end
    if not has_confirm(raw) then return false, "world.event.dragonkick is mutating; append confirm" end
    local clean = strip_confirm(raw)
    local words = split_words(clean)
    local selector = words[1] or "latest"
    local mode = tostring(words[2] or "full"):lower()
    if selector == "client" or selector == "rep" or selector == "timer" or selector == "full" or selector == "lifecycle" or selector == "all" then
        mode = selector
        selector = "latest"
    end
    local valid_modes = { client = true, rep = true, timer = true, full = true, lifecycle = true, all = true }
    if not valid_modes[mode] then return false, "usage: world.event.dragonkick <latest|index|name> <client|rep|timer|full|lifecycle> confirm" end
    local entry, select_err, entries = select_event_actor(selector)
    if not entry then return false, select_err end
    local report = {
        generated_unix = os.time(),
        selector = selector,
        mode = mode,
        live_event_count = entries and #entries or nil,
        target = {
            label = entry.label,
            full_name = entry.full_name,
            class = entry.class,
            instance = entry.instance,
        },
        before = event_actor_snapshot(entry.actor),
        actions = {},
    }
    local lines = {
        "World Event Dragon Lifecycle Kick",
        string.format("target=%s full=%s mode=%s", tostring(entry.label), tostring(entry.full_name), tostring(mode)),
    }
    for _, line in ipairs(event_actor_summary_lines("before", report.before)) do lines[#lines + 1] = line end
    local actions = dragon_lifecycle_actions(entry.actor, mode)
    for _, action in ipairs(actions) do report.actions[#report.actions + 1] = action end
    for i, action in ipairs(report.actions) do
        if action.method then
            lines[#lines + 1] = string.format("kick#%d call %s target=%s arg=%s present=%s ok=%s error=%s result=%s",
                i,
                tostring(action.method),
                tostring(action.target or "actor"),
                tostring(action.arg or ""),
                tostring(action.present),
                tostring(action.ok),
                tostring(action.error or ""),
                tostring(action.result or ""))
        else
            lines[#lines + 1] = string.format("kick#%d write %s=%s ok=%s error=%s before=%s after=%s",
                i,
                tostring(action.field),
                tostring(action.value),
                tostring(action.ok),
                tostring(action.error or ""),
                action.before and tostring(action.before.value) or "<none>",
                action.after and tostring(action.after.value) or "<none>")
        end
    end
    report.after = {
        event = event_actor_snapshot(entry.actor),
        active = active_snapshot(50),
    }
    for _, line in ipairs(event_actor_summary_lines("after", report.after.event)) do lines[#lines + 1] = line end
    lines[#lines + 1] = "active_after=" .. tostring(report.after.active.detail)
    local ok_write, path_or_err = write_report("world_event_dragonkick", report, lines)
    local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
    return true, string.format("target=%s mode=%s active=%d%s",
        tostring(entry.label),
        tostring(mode),
        tonumber(report.after.active.active_count) or 0,
        wrote)
end

function M.dragon_manager(args)
    local raw = trim(args)
    if raw == "" then
        return false, "usage: world.event.dragonmanager <definition_index|persistence_id|alias> [definition|soft|class|all] [groupTag|none] confirm"
    end
    if not has_confirm(raw) then return false, "world.event.dragonmanager is mutating; append confirm" end
    local clean = strip_confirm(raw)
    local words = split_words(clean)
    local token = words[1] or ""
    local mode = tostring(words[2] or "definition"):lower()
    local group_token = words[3] or ""
    local valid_modes = { definition = true, soft = true, class = true, all = true }
    if not valid_modes[mode] then
        group_token = words[2] or ""
        mode = "definition"
    end

    local manager, def, count, err, index = definition_by_token(token)
    if not def then return false, err end
    local rec = definition_record(def, index or 0)
    local event_name = tostring(rec.PersistenceID or "")
    local class_path = definition_class_path(rec)
    if class_path == "" or class_path == "nil" then return false, "definition has no WorldEventClass path" end

    local player = feature_net.local_pawn()
    if not is_valid(player) then return false, "no local player pawn" end
    local transform = build_transform_from_actor(player)
    local group_tag = make_gameplay_tag(group_token)
    local targets = { player }

    local ok_definition_class, definition_event_class = pcall(function() return def.WorldEventClass end)
    -- Keep dragon manager starts narrow. The catalog/definition route already
    -- gives us the real class path, and broad failed class loads can destabilize
    -- the game while testing dragon events.
    local class_obj, class_route, normalized_path, class_attempts = resolve_event_uclass_candidates(class_path, rec, false)
    local soft_ref, soft_route, soft_path = nil, nil, nil
    if normalized_path and tostring(normalized_path):sub(1, 1) == "/" then
        soft_ref, soft_route, soft_path = make_soft_class_ref(normalized_path)
    end

    local report = {
        generated_unix = os.time(),
        token = token,
        mode = mode,
        group_token = group_token,
        definition_index = index,
        definition_count = count,
        definition = rec,
        event_name = event_name,
        manager = object_label(manager),
        manager_full_name = object_full_name(manager),
        transform = transform,
        targets = { object_label(player) },
        class_path = class_path,
        normalized_class_path = normalized_path,
        class_route = class_route,
        class_attempts = class_attempts,
        soft_route = soft_route,
        soft_path = soft_path,
        before = {
            active = active_snapshot(50),
            manager = manager_compact_snapshot(manager, event_name),
        },
        attempts = {},
    }
    local lines = {
        "World Event Dragon Manager Probe",
        string.format("definition #%s/%s DebugName=%s PersistenceID=%s EventClass=%s",
            tostring(index or "?"),
            tostring(count or "?"),
            tostring(rec.DebugName),
            event_name,
            class_path),
        "mode=" .. tostring(mode),
        "group=" .. tostring(group_token == "" and "<none>" or group_token),
        "manager=" .. object_label(manager),
        "loc=" .. transform_text(transform),
        "class_route=" .. tostring(class_route) .. " normalized=" .. tostring(normalized_path),
        "soft_route=" .. tostring(soft_route or "<none>") .. " soft_path=" .. tostring(soft_path or "<none>"),
        "before_active=" .. tostring(report.before.active.detail),
    }
    for _, attempt in ipairs(class_attempts or {}) do
        lines[#lines + 1] = string.format("class_attempt#%d %s ok=%s reason=%s route=%s",
            tonumber(attempt.index) or 0,
            tostring(attempt.normalized or attempt.path),
            tostring(attempt.ok),
            tostring(attempt.reason),
            tostring(attempt.route))
    end

    local variants = {}
    if mode == "definition" or mode == "all" then
        if ok_definition_class and definition_event_class ~= nil then
            variants[#variants + 1] = { label = "definition_softptr", value = definition_event_class }
        else
            lines[#lines + 1] = "definition_softptr unavailable=" .. tostring(ok_definition_class and "nil" or first_error_line(definition_event_class))
        end
    end
    if mode == "soft" or mode == "all" then
        if soft_ref ~= nil then
            variants[#variants + 1] = { label = "resolved_softref:" .. tostring(soft_route), value = soft_ref }
        else
            lines[#lines + 1] = "resolved_softref unavailable=" .. tostring(soft_route or "no normalized path")
        end
    end
    if mode == "class" or mode == "all" then
        if is_valid(class_obj) then
            variants[#variants + 1] = { label = "resolved_uclass:" .. tostring(class_route), value = class_obj }
        else
            lines[#lines + 1] = "resolved_uclass unavailable=" .. tostring(class_route)
        end
    end
    if #variants == 0 then
        report.error = "no usable StartEvent class variant"
        local ok_write, path_or_err = write_report("world_event_dragonmanager", report, lines)
        local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
        return false, "no usable StartEvent class variant" .. wrote
    end

    for _, variant in ipairs(variants) do
        local attempt = { variant = variant.label }
        local ok_call, call_err = pcall(function()
            manager:StartEvent(variant.value, transform, targets, group_tag)
        end)
        attempt.call_ok = ok_call and true or false
        attempt.call_error = ok_call and nil or first_error_line(call_err)
        attempt.active = active_snapshot(50)
        attempt.manager = manager_compact_snapshot(manager, event_name)
        report.attempts[#report.attempts + 1] = attempt
        lines[#lines + 1] = string.format("#%d variant=%s call=%s active=%s",
            #report.attempts,
            tostring(attempt.variant),
            ok_call and "ok" or ("err:" .. tostring(attempt.call_error)),
            tostring(attempt.active.detail))
        if ok_call and mode ~= "all" then break end
        if ok_call and (tonumber(attempt.active.active_count) or 0) > (tonumber(report.before.active.active_count) or 0) then break end
    end

    report.after = {
        active = active_snapshot(50),
        manager = manager_compact_snapshot(manager, event_name),
    }
    lines[#lines + 1] = "after_active=" .. tostring(report.after.active.detail)
    local latest_entry = select_event_actor("latest")
    if latest_entry and latest_entry.actor then
        report.latest_event = {
            label = latest_entry.label,
            full_name = latest_entry.full_name,
            snapshot = event_actor_snapshot(latest_entry.actor),
        }
        for _, line in ipairs(event_actor_summary_lines("latest_event", report.latest_event.snapshot)) do
            lines[#lines + 1] = line
        end
    else
        lines[#lines + 1] = "latest_event=<none>"
    end

    local ok_write, path_or_err = write_report("world_event_dragonmanager", report, lines)
    local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
    return true, string.format("#%s %s dragonmanager mode=%s attempts=%d active=%d%s",
        tostring(index or "?"),
        event_name,
        tostring(mode),
        #report.attempts,
        tonumber(report.after.active.active_count) or 0,
        wrote)
end

function M.start_wave(args)
    local raw = trim(args)
    if raw == "" then return false, "usage: world.event.startwave <definition_index|persistence_id|alias> [count|auto] [single|mixed] confirm" end
    if not has_confirm(raw) then return false, "world.event.startwave is mutating; append confirm" end
    local clean = strip_confirm(raw)
    local words = split_words(clean)
    local token = words[1] or ""
    local count_spec, spawn_mode = parse_count_and_spawn_mode(words, 2, "auto")
    local manager, def, count, err, index = definition_by_token(token)
    if not def then return false, err end
    local rec = definition_record(def, index or 0)
    local class_path = definition_class_path(rec)
    if class_path == "" or class_path == "nil" then return false, "definition has no WorldEventClass path" end

    local player = feature_net.local_pawn()
    if not is_valid(player) then return false, "no local player pawn" end
    local event_name = tostring(rec.PersistenceID or "")
    local class_obj, class_route, normalized_path, class_attempts = resolve_event_uclass_candidates(class_path, rec, false)
    local start_report = {
        definition_index = index,
        definition_count = count,
        definition = rec,
        event_name = event_name,
        class_path = class_path,
        normalized_class_path = normalized_path,
        class_route = class_route,
        class_attempts = class_attempts,
        manager = object_label(manager),
        manager_full_name = object_full_name(manager),
        before = {
            active = active_snapshot(50),
            manager = manager_compact_snapshot(manager, event_name),
        },
        start_actions = {},
    }
    local start_lines = {
        string.format("definition #%s/%s DebugName=%s PersistenceID=%s EventClass=%s",
            tostring(index or "?"),
            tostring(count or "?"),
            tostring(rec.DebugName),
            event_name,
            class_path),
        "manager=" .. object_label(manager),
        "class_route=" .. tostring(class_route) .. " normalized=" .. tostring(normalized_path),
        "before_active=" .. tostring(start_report.before.active.detail),
    }
    if class_attempts and #class_attempts > 0 then
        for _, attempt in ipairs(class_attempts) do
            start_lines[#start_lines + 1] = string.format("class_attempt#%d %s ok=%s reason=%s route=%s",
                tonumber(attempt.index) or 0,
                tostring(attempt.normalized or attempt.path),
                tostring(attempt.ok),
                tostring(attempt.reason),
                tostring(attempt.route))
        end
    end
    if not is_valid(class_obj) then
        start_report.error = "class resolution failed"
        local lines = { "World Event Start + Wave Spawn" }
        for _, line in ipairs(start_lines) do lines[#lines + 1] = line end
        lines[#lines + 1] = "error=class resolution failed"
        local ok_write, path_or_err = write_report("world_event_startwave", start_report, lines)
        local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
        return false, "class resolution failed: " .. tostring(class_route) .. " (" .. tostring(normalized_path) .. ")" .. wrote
    end

    local actor, spawn_err, spawn_loc, spawn_rot = spawn_event_actor(class_obj, player)
    start_report.event_spawn = {
        ok = is_valid(actor),
        error = spawn_err,
        location = spawn_loc,
        rotation = spawn_rot,
    }
    if not is_valid(actor) then
        local lines = { "World Event Start + Wave Spawn" }
        for _, line in ipairs(start_lines) do lines[#lines + 1] = line end
        lines[#lines + 1] = "event_spawn_error=" .. tostring(spawn_err)
        local ok_write, path_or_err = write_report("world_event_startwave", start_report, lines)
        local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
        return false, tostring(spawn_err) .. wrote
    end

    start_report.spawned_before_start = event_actor_snapshot(actor)
    for _, line in ipairs(event_actor_summary_lines("spawned_before_start", start_report.spawned_before_start)) do
        start_lines[#start_lines + 1] = line
    end
    local actions = apply_event_start_actions(actor, false)
    for _, action in ipairs(actions) do start_report.start_actions[#start_report.start_actions + 1] = action end
    for i, action in ipairs(start_report.start_actions) do
        if action.method then
            start_lines[#start_lines + 1] = string.format("start#%d call %s present=%s ok=%s error=%s result=%s",
                i,
                tostring(action.method),
                tostring(action.present),
                tostring(action.ok),
                tostring(action.error or ""),
                tostring(action.result or ""))
        else
            start_lines[#start_lines + 1] = string.format("start#%d write %s=%s ok=%s error=%s before=%s after=%s",
                i,
                tostring(action.field),
                tostring(action.value),
                tostring(action.ok),
                tostring(action.error or ""),
                action.before and tostring(action.before.value) or "<none>",
                action.after and tostring(action.after.value) or "<none>")
        end
    end
    start_report.after_start = {
        event = event_actor_snapshot(actor),
        active = active_snapshot(50),
        manager = manager_compact_snapshot(manager, event_name),
    }
    start_lines[#start_lines + 1] = "active_after_start=" .. tostring(start_report.after_start.active.detail)

    local ok, detail = spawn_wave_for_actor(
        actor,
        event_name,
        count_spec,
        3,
        "world_event_startwave",
        "World Event Start + Wave Spawn",
        { start = start_report },
        start_lines,
        spawn_mode)
    if not ok then return false, detail end
    return true, string.format("#%s %s started=%s ; %s",
        tostring(index or "?"),
        event_name,
        object_label(actor),
        tostring(detail))
end

function M.destroy_live(args)
    local raw = trim(args)
    if raw == "" then return false, "usage: world.event.destroy <latest|index|name|all> confirm" end
    if not has_confirm(raw) then return false, "world.event.destroy is mutating; append confirm" end
    local selector = trim(strip_confirm(raw))
    if selector == "" then selector = "latest" end
    local entries = collect_event_actor_entries()
    if #entries == 0 then
        if selector:lower() == "all" then
            local report = {
                generated_unix = os.time(),
                selector = selector,
                before_active = active_snapshot(50),
                destroyed = {},
                noop = true,
            }
            local lines = {
                "World Event Destroy Live",
                "selector=" .. tostring(selector),
                "before_active=" .. tostring(report.before_active.detail),
                "noop=true no live WorldEvent/BaseRaid/Hunted/Dragon actors found",
            }
            local ok_write, path_or_err = write_report("world_event_destroy", report, lines)
            local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
            return true, "destroyed=0 active_after=0 noop=true" .. wrote
        end
        return false, "no live WorldEvent/BaseRaid/Hunted/Dragon actors found"
    end
    local targets = {}
    if selector:lower() == "all" then
        targets = entries
    else
        local entry, select_err = select_event_actor(selector)
        if not entry then return false, select_err end
        targets = { entry }
    end
    local report = {
        generated_unix = os.time(),
        selector = selector,
        before_active = active_snapshot(50),
        destroyed = {},
    }
    local lines = {
        "World Event Destroy Live",
        "selector=" .. tostring(selector),
        "before_active=" .. tostring(report.before_active.detail),
    }
    for i, entry in ipairs(targets) do
        local ok_destroy, detail = destroy_actor_safe(entry.actor)
        local rec = {
            index = i,
            label = entry.label,
            full_name = entry.full_name,
            ok = ok_destroy and true or false,
            detail = tostring(detail),
        }
        report.destroyed[#report.destroyed + 1] = rec
        lines[#lines + 1] = string.format("#%d %s full=%s destroy=%s:%s",
            i,
            tostring(entry.label),
            tostring(entry.full_name),
            ok_destroy and "ok" or "err",
            tostring(detail))
    end
    report.after_active = active_snapshot(50)
    lines[#lines + 1] = "after_active=" .. tostring(report.after_active.detail)
    local ok_write, path_or_err = write_report("world_event_destroy", report, lines)
    local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
    return true, string.format("destroyed=%d active_after=%d%s",
        #report.destroyed,
        tonumber(report.after_active.active_count) or 0,
        wrote)
end

local DRAGON_LIGHT_ALIASES = {
    meteor = "dragon_velgar_meteors",
    meteors = "dragon_velgar_meteors",
    velgar_meteor = "dragon_velgar_meteors",
    velgar_meteors = "dragon_velgar_meteors",
    dragon_meteors = "dragon_velgar_meteors",
    poison = "dragon_velgar_poison_breath",
    poison_breath = "dragon_velgar_poison_breath",
    velgar_poison = "dragon_velgar_poison_breath",
    velgar_poison_breath = "dragon_velgar_poison_breath",
    imaru = "dragon_imaru_breath",
    imaru_breath = "dragon_imaru_breath",
}

local function light_dragon_token(token)
    local raw = trim(token)
    if raw == "" then return "" end
    return DRAGON_LIGHT_ALIASES[raw:lower()] or raw
end

function M.light_wave(args)
    local raw = trim(args)
    if raw == "" then
        return false, "usage: world.wave <event_token> [auto|count] [single|mixed] [tracked|untracked] confirm"
    end
    if not has_confirm(raw) then return false, "world.wave is mutating; append confirm" end
    local clean = strip_confirm(raw)
    local words = split_words(clean)
    local token = words[1] or ""
    if token == "" then return false, "usage: world.wave <event_token> [auto|count] [single|mixed] [tracked|untracked] confirm" end
    local count_spec = "auto"
    local spawn_mode = ""
    local track = true
    for i = 2, #words do
        local word = tostring(words[i] or "")
        local lower = word:lower()
        if lower == "single" or lower == "mixed" then
            spawn_mode = lower
        elseif lower == "untracked" or lower == "forget" or lower == "notrack" or lower == "no_track" or lower == "survival" then
            track = false
        elseif lower == "tracked" or lower == "track" or lower == "cleanup" then
            track = true
        elseif word ~= "" then
            count_spec = word
        end
    end
    local start_batch_id = LAST_SPAWNED_AI.next_batch_id
    local command = token .. " " .. count_spec
    if spawn_mode ~= "" then command = command .. " " .. spawn_mode end
    command = command .. " confirm"
    local ok, detail = M.start_wave(command)
    if ok and not track then
        local forgotten_batches, forgotten_actors = forget_spawn_batches_from(start_batch_id)
        detail = tostring(detail) .. string.format(" ; tracking=off forgotten_batches=%d forgotten_actors=%d", forgotten_batches, forgotten_actors)
    elseif ok then
        detail = tostring(detail) .. " ; tracking=on"
    end
    return ok, detail
end

function M.light_dragon(args)
    local raw = trim(args)
    if raw == "" then return false, "usage: world.dragon <meteors|poison|imaru|token> confirm" end
    if not has_confirm(raw) then return false, "world.dragon is mutating; append confirm" end
    local clean = strip_confirm(raw)
    local words = split_words(clean)
    local token = light_dragon_token(words[1] or "")
    if token == "" then return false, "usage: world.dragon <meteors|poison|imaru|token> confirm" end
    local ok, detail = M.dragon_manager(token .. " definition confirm")
    if ok then detail = tostring(detail) .. " ; lightweight=dragonmanager.definition" end
    return ok, detail
end

function M.encounter_stop(args)
    local raw = trim(args)
    local clean = strip_confirm(raw)
    local words = split_words(clean)
    local mode = tostring(words[1] or "all"):lower()
    if mode == "" then mode = "all" end
    if not has_confirm(raw) then return false, "world.encounter.stop is mutating; append confirm" end
    if mode ~= "all" and mode ~= "events" and mode ~= "event" and mode ~= "spawned" and mode ~= "ai" and mode ~= "enemies" then
        return false, "usage: world.encounter.stop [all|events|spawned] confirm"
    end
    local parts = {}
    local ok_all = true
    if mode == "all" or mode == "spawned" or mode == "ai" or mode == "enemies" then
        local ok_spawned, detail_spawned = M.cleanup_spawned("all confirm")
        ok_all = ok_all and ok_spawned
        parts[#parts + 1] = "spawned=" .. tostring(ok_spawned and detail_spawned or ("err:" .. tostring(detail_spawned)))
    end
    if mode == "all" or mode == "events" or mode == "event" then
        local ok_events, detail_events = M.destroy_live("all confirm")
        ok_all = ok_all and ok_events
        parts[#parts + 1] = "events=" .. tostring(ok_events and detail_events or ("err:" .. tostring(detail_events)))
    end
    return ok_all, table.concat(parts, " ; ")
end

function M.start(args)
    local raw = trim(args)
    if raw == "" then
        return false, "usage: world.event.start <base_raid|bm1|bm2|fh1|gf1|gf2|/Game/...Event_C> [groupTag|none] confirm"
    end
    if not has_confirm(raw) then
        return false, "world.event.start is mutating; append confirm"
    end
    local clean = strip_confirm(raw)
    local words = split_words(clean)
    local class_token = words[1] or ""
    local group_token = words[2] or ""
    local class_path = normalize_event_path(class_token)
    if class_path == "" then return false, "missing event class path/alias" end

    local manager, manager_route = find_manager()
    if not is_valid(manager) then return false, "WorldEventManager not found: " .. tostring(manager_route) end
    local player = feature_net.local_pawn()
    if not is_valid(player) then return false, "no local player pawn" end
    local transform = build_transform_from_actor(player)
    local soft_ref, soft_route, normalized_path = make_soft_class_ref(class_path)
    if not soft_ref then return false, tostring(soft_route) .. " (" .. tostring(normalized_path) .. ")" end

    -- Best effort preload. StartEvent takes a soft class ref, but loading here
    -- makes failures louder and gives us a route in the ack.
    local loaded_class, load_route = player_core.resolve_uclass_via_kismet_softclass(normalized_path)
    local group_tag = make_gameplay_tag(group_token)
    local targets = { player }
    local attempts = {}

    local function attempt(label, event_class_arg, group_arg)
        local ok, err = pcall(function()
            manager:StartEvent(event_class_arg, transform, targets, group_arg)
        end)
        attempts[#attempts + 1] = label .. "=" .. (ok and "ok" or first_error_line(err))
        return ok
    end

    local started = attempt("soft+tag", soft_ref, group_tag)
    if not started and group_tag ~= nil then started = attempt("soft+niltag", soft_ref, nil) end
    if not started then started = attempt("soft+emptytag", soft_ref, {}) end
    if not started and is_valid(loaded_class) then started = attempt("class+tag", loaded_class, group_tag) end

    if not started then
        return false, "StartEvent failed " .. table.concat(attempts, " | ")
    end
    local ok_active, active_detail = M.active("10")
    local active_suffix = ok_active and (" ; active_after=" .. tostring(active_detail)) or (" ; active_after_error=" .. tostring(active_detail))
    return true, string.format("started %s via %s manager=%s loc=%s load=%s attempts=%s%s",
        normalized_path,
        tostring(soft_route),
        object_label(manager),
        transform_text(transform),
        tostring(load_route or "<not loaded>"),
        table.concat(attempts, " | "),
        active_suffix)
end

function M.start_definition(args)
    local raw = trim(args)
    if raw == "" then return false, "usage: world.event.startdef <definition_index> [groupTag|none] confirm" end
    if not has_confirm(raw) then return false, "world.event.startdef is mutating; append confirm" end
    local clean = strip_confirm(raw)
    local words = split_words(clean)
    local index = tonumber(words[1] or "")
    if not index then return false, "usage: world.event.startdef <definition_index> [groupTag|none] confirm" end
    local group_token = words[2] or ""
    local manager, def, count, err = definition_at(index)
    if not def then return false, err end
    local ok_class, event_class = pcall(function() return def.WorldEventClass end)
    if not ok_class or event_class == nil then
        return false, "definition #" .. tostring(index) .. " has no WorldEventClass: " .. tostring(ok_class and "nil" or first_error_line(event_class))
    end
    local player = feature_net.local_pawn()
    if not is_valid(player) then return false, "no local player pawn" end
    local transform = build_transform_from_actor(player)
    local group_tag = make_gameplay_tag(group_token)
    local targets = { player }
    local attempts = {}
    local rec = definition_record(def, index)

    local function attempt(label, event_class_arg, group_arg)
        local ok, call_err = pcall(function()
            manager:StartEvent(event_class_arg, transform, targets, group_arg)
        end)
        attempts[#attempts + 1] = label .. "=" .. (ok and "ok" or first_error_line(call_err))
        return ok
    end

    local started = attempt("definition+tag", event_class, group_tag)
    if not started and group_tag ~= nil then started = attempt("definition+niltag", event_class, nil) end
    if not started then started = attempt("definition+emptytag", event_class, {}) end
    if not started then return false, "StartEvent definition #" .. tostring(index) .. " failed " .. table.concat(attempts, " | ") end

    local ok_active, active_detail = M.active("10")
    local active_suffix = ok_active and (" ; active_after=" .. tostring(active_detail)) or (" ; active_after_error=" .. tostring(active_detail))
    return true, string.format("started definition #%d/%d %s (%s) manager=%s loc=%s attempts=%s%s",
        index,
        count,
        tostring(rec.DebugName),
        tostring(rec.WorldEventClassPath or rec.WorldEventClass),
        object_label(manager),
        transform_text(transform),
        table.concat(attempts, " | "),
        active_suffix)
end

function M.client_flag(args)
    local raw = trim(args)
    if raw == "" then
        return false, "usage: world.event.clientflag <hunted|base|dragon> <on|off> confirm"
    end
    if not has_confirm(raw) then return false, "client flag probe is mutating UI/audio state; append confirm" end
    local clean = strip_confirm(raw)
    local words = split_words(clean)
    local flag = tostring(words[1] or ""):lower()
    local state_word = tostring(words[2] or ""):lower()
    local enabled = nil
    if state_word == "on" or state_word == "true" or state_word == "1" then enabled = true end
    if state_word == "off" or state_word == "false" or state_word == "0" then enabled = false end
    if enabled == nil then return false, "usage: world.event.clientflag <hunted|base|dragon> <on|off> confirm" end
    local pc = feature_net.local_controller()
    if not is_valid(pc) then return false, "no local controller" end
    local method_name = nil
    if flag == "hunted" or flag == "hunt" then method_name = "Client_SetIsBeingHunted" end
    if flag == "base" or flag == "raid" or flag == "base_raid" or flag == "baseraid" then method_name = "Client_SetIsInBaseRaid" end
    if flag == "dragon" then method_name = "Client_SetIsInDragonEvent" end
    if not method_name then return false, "unknown flag: " .. tostring(flag) end
    if not pc[method_name] then return false, method_name .. " missing" end
    local ok, err = pcall(function() pc[method_name](pc, enabled) end)
    if not ok then return false, method_name .. " failed: " .. first_error_line(err) end
    return true, string.format("%s=%s (client flag only; not a full event start)", method_name, enabled and "on" or "off")
end

return M
