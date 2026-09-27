-- Enemy aggression probes.
--
-- These verbs are intentionally small and explicit. The dumps show
-- ADominionAICharacter exposes SetSpecifiedTargetOverride(actor facade) plus
-- readbacks for specified target/current target/alertness, while the
-- controller exposes GetThreatSystem(). This module probes those surfaces
-- without trying to rewrite the AI blackboard or behavior tree.

local M = {}

local feature_actor = require("feature_actor")
local facade = require("feature_actor_facade")
local feature_field = require("feature_field")
local feature_net = require("feature_net")
local feature_grab = require("feature_grab")
local feature_scan = require("feature_scan")
local mod_paths = require("mod_paths")

local function is_valid(obj)
    return feature_actor.is_valid_object(obj)
end

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function first_error_line(value)
    local text = tostring(value or "")
    return text:match("([^\r\n]+)") or text
end

local function object_name(obj)
    if not is_valid(obj) then return "<invalid>" end
    local ok, name = pcall(function() return obj:GetName() end)
    if ok and name and tostring(name) ~= "" then return tostring(name) end
    return feature_actor.short_name_of(obj) or "<unnamed>"
end

local function object_class(obj)
    return feature_field.class_name_of(obj) or "<unknown>"
end

local function object_label(obj)
    if not is_valid(obj) then return "<invalid>" end
    return object_name(obj) .. "[" .. object_class(obj) .. "]"
end

local function method_exists(obj, name)
    if not is_valid(obj) then return false end
    local ok, value = pcall(function() return obj[name] end)
    return ok and value ~= nil
end

local function ai_controller(ai)
    if not is_valid(ai) then return nil end
    local ctrl = nil
    local ok_getter, getter = pcall(function() return ai.GetController end)
    if ok_getter and getter then
        local ok, value = pcall(function() return ai:GetController() end)
        if ok and is_valid(value) then ctrl = value end
    end
    if not ctrl then
        local ok, value = pcall(function() return ai.Controller end)
        if ok and is_valid(value) then ctrl = value end
    end
    return ctrl
end

local function get_ai_function_library()
    if not StaticFindObject then return nil, "StaticFindObject unavailable" end
    local ok_find, object = pcall(StaticFindObject, "/Script/Dominion.Default__DominionAiFunctionLibrary")
    if ok_find and is_valid(object) then return object, "Default__DominionAiFunctionLibrary" end
    return nil, ok_find and "DominionAiFunctionLibrary CDO not found" or first_error_line(object)
end

local function alertness_component(ai)
    local ctrl = ai_controller(ai)
    if not is_valid(ctrl) then return nil, "no controller" end
    local ok_get, component = pcall(function() return ctrl:GetAlertnessComponent() end)
    if ok_get and is_valid(component) then return component, "GetAlertnessComponent" end
    local ok_field, field_component = pcall(function() return ctrl.AIAlertnessComponent end)
    if ok_field and is_valid(field_component) then return field_component, "AIAlertnessComponent" end
    return nil, ok_get and "missing/invalid alertness component" or first_error_line(component)
end

local function active_ai_check(actor)
    if not is_valid(actor) then return false, "invalid actor" end
    if not method_exists(actor, "SetSpecifiedTargetOverride") then
        return false, "missing SetSpecifiedTargetOverride"
    end
    if not is_valid(ai_controller(actor)) then
        return false, "no AI controller"
    end
    return true, nil
end

local function actor_location_text(actor)
    local loc = feature_actor.actor_location(actor)
    if not loc then return "" end
    return string.format("(%.1f,%.1f,%.1f)", tonumber(loc.X) or 0, tonumber(loc.Y) or 0, tonumber(loc.Z) or 0)
end

local function distance_sq(a, b)
    if not a or not b then return math.huge end
    local dx = (tonumber(a.X) or 0) - (tonumber(b.X) or 0)
    local dy = (tonumber(a.Y) or 0) - (tonumber(b.Y) or 0)
    local dz = (tonumber(a.Z) or 0) - (tonumber(b.Z) or 0)
    return dx * dx + dy * dy + dz * dz
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

local function json_escape(value)
    local text = tostring(value or "")
    text = text:gsub("\\", "\\\\"):gsub('"', '\\"')
    text = text:gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    text = text:gsub("[%z\1-\8\11\12\14-\31]", "")
    return text
end

local function json_value(value)
    local kind = type(value)
    if value == nil then return "null" end
    if kind == "boolean" then return value and "true" or "false" end
    if kind == "number" then return tostring(value) end
    if kind == "string" then return '"' .. json_escape(value) .. '"' end
    if kind ~= "table" then return '"' .. json_escape(tostring(value)) .. '"' end
    local is_array = true
    local max_index, count = 0, 0
    for key, _ in pairs(value) do
        if type(key) ~= "number" then is_array = false end
        if type(key) == "number" and key > max_index then max_index = key end
        count = count + 1
    end
    local parts = {}
    if is_array and max_index == count then
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
        for i, key in ipairs(keys) do
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
    local json_path = dir .. "\\" .. file_stem .. ".json"
    local text_path = dir .. "\\" .. file_stem .. ".txt"
    local ok_json, json_result = mod_paths.write_atomic(json_path, json_value(report))
    local ok_text, text_result = mod_paths.write_atomic(text_path, table.concat(lines, "\n") .. "\n")
    if ok_json and ok_text then return true, json_result .. " ; " .. text_result end
    return false, tostring(json_result) .. " ; " .. tostring(text_result)
end

local AI_CLASS_NAMES = {
    -- Base classes first. If UE4SS returns subclasses for these, this catches
    -- most live AI without touching every Actor in the level.
    "DominionAICharacter",
    "BP_DominionAICharacter_C",
    "BP_AI_Biped_Base_C",
    "BP_AI_Wolf_Character_C",
    "BP_AI_MeleeGoblin_Character_C",
    -- Known/common concrete classes used by our current probes and dungeon work.
    "BP_AI_Kebbit_Character_02_C",
    "BP_AI_SkeletalWarrior_Character_C",
    "BP_AI_RotswornWarrior_Character_C",
    "BP_AI_RotswornMarauder_Character_C",
    "BP_AI_RotswornNecromancer_Character_C",
    "BP_AI_MeleeBlackKnight_Character_C",
    "BP_AI_BlackKnightRanged_Character_C",
    "BP_AI_Melee2HBlackKnight_Character_C",
    "BP_AI_RangedGoblin_Character_C",
    "BP_AI_RuntGoblin_Character_C",
    "BP_AI_SentryGoblin_Character_C",
    "BP_AI_MediumBeast_Character_C",
    "BP_AI_RangedBeast_Character_C",
    "BP_AI_MagicBeast_Character_C",
    "BP_AI_HellHound_Character_C",
    "BP_AI_DragonWolf_Character_C",
}

local function collect_class(class_name, out, seen)
    if not FindAllOf then return end
    local ok, list = pcall(FindAllOf, class_name)
    if not ok or not list then return end
    local count = container_count(list)
    for i = 1, count do
        local entry = container_item(list, i)
        local ok_ai = false
        if is_valid(entry) then
            ok_ai = active_ai_check(entry)
        end
        if ok_ai then
            local name = object_name(entry)
            if not seen[name] then
                seen[name] = true
                out[#out + 1] = entry
            end
        end
    end
end

local function collect_ai_candidates(include_actor_sweep)
    local out, seen, notes = {}, {}, {}
    for _, class_name in ipairs(AI_CLASS_NAMES) do
        collect_class(class_name, out, seen)
    end
    if include_actor_sweep and FindAllOf then
        notes[#notes + 1] = "full Actor sweep disabled; use look/name, or add a concrete AI class to the safe list"
    end
    table.sort(out, function(a, b) return object_name(a) < object_name(b) end)
    return out, notes
end

local function local_player()
    local pawn = feature_net.local_pawn()
    if not is_valid(pawn) then return nil, "no local pawn" end
    return pawn, nil
end

local function nearest_ai()
    local pawn, err = local_player()
    if not pawn then return nil, err end
    local pawn_loc = feature_actor.actor_location(pawn)
    local best, best_dist = nil, math.huge
    local candidates = collect_ai_candidates(false)
    for _, ai in ipairs(candidates) do
        local d = distance_sq(pawn_loc, feature_actor.actor_location(ai))
        if d < best_dist then
            best, best_dist = ai, d
        end
    end
    if not best then return nil, "no safe AI candidates found; aim at an AI and use enemy.aggro.status look" end
    return best, string.format("nearest %.1fcm", math.sqrt(best_dist))
end

local function ai_from_look()
    local actor, _loc, source, err = feature_grab.pick_target_under_reticle()
    if not is_valid(actor) then return nil, tostring(err or "no actor under reticle") end
    local ok_ai, reason = active_ai_check(actor)
    if not ok_ai then
        return nil, "reticle target is not an active Dominion AI (" .. tostring(reason) .. "): " .. object_label(actor)
    end
    return actor, source or "look"
end

local function resolve_ai_selector(selector)
    local sel = trim(selector)
    if sel == "" or sel == "look" or sel == "reticle" then
        return ai_from_look()
    end
    if sel == "nearest" then
        return nearest_ai()
    end
    local actor = feature_actor.resolve_actor_by_name(sel)
    if not is_valid(actor) then return nil, "actor not found: " .. tostring(sel) end
    local ok_ai, reason = active_ai_check(actor)
    if not ok_ai then
        return nil, "actor is not an active Dominion AI (" .. tostring(reason) .. "): " .. object_label(actor)
    end
    return actor, "name"
end

local function read_method_object(obj, method_name)
    if not is_valid(obj) then return nil, "invalid object" end
    local ok_method, method = pcall(function() return obj[method_name] end)
    if not ok_method or method == nil then return nil, "missing " .. method_name end
    local ok_call, result = pcall(function() return method(obj) end)
    if not ok_call then return nil, first_error_line(result) end
    if method_name == "GetSpecifiedTargetOverride" or method_name == "GetHighestThreatActor" then
        return facade.to_actor(result)
    end
    if is_valid(result) then return result, nil end
    return nil, "returned invalid"
end

local function read_field_object(obj, field_name)
    if not is_valid(obj) then return nil, "invalid object" end
    local ok, value = pcall(function() return obj[field_name] end)
    if ok and field_name == "CurrentTarget" then return facade.to_actor(value) end
    if ok and is_valid(value) then return value, nil end
    return nil, ok and "nil/invalid" or first_error_line(value)
end

local function threat_system(ai)
    local ctrl = ai_controller(ai)
    if not is_valid(ctrl) then return nil, nil, "no controller" end
    local ts, err = read_method_object(ctrl, "GetThreatSystem")
    return ts, ctrl, err
end

local function vector_text(vec)
    if type(vec) ~= "table" and type(vec) ~= "userdata" then return "<none>" end
    local ok_x, x = pcall(function() return vec.X end)
    local ok_y, y = pcall(function() return vec.Y end)
    local ok_z, z = pcall(function() return vec.Z end)
    if not ok_x then x = 0 end
    if not ok_y then y = 0 end
    if not ok_z then z = 0 end
    x = tonumber(x) or 0
    y = tonumber(y) or 0
    z = tonumber(z) or 0
    return string.format("(%.1f,%.1f,%.1f)", x, y, z)
end

local function method_value_text(obj, method_name)
    if not is_valid(obj) then return "<none:invalid object>" end
    local ok_method, method = pcall(function() return obj[method_name] end)
    if not ok_method or method == nil then return "<none:missing " .. method_name .. ">" end
    local ok_call, result = pcall(function() return method(obj) end)
    if not ok_call then return "<err:" .. first_error_line(result) .. ">" end
    if is_valid(result) then return object_label(result) end
    if type(result) == "table" or type(result) == "userdata" then return vector_text(result) end
    return tostring(result)
end

local function threat_summary(ai)
    local ts, ctrl, err = threat_system(ai)
    if not is_valid(ctrl) then return "controller=<none>" end
    if not is_valid(ts) then return "controller=" .. object_label(ctrl) .. " threat=<none:" .. tostring(err) .. ">" end
    local highest, highest_err = read_method_object(ts, "GetHighestThreatActor")
    local all_count = "?"
    local ok_all, all_targets = pcall(function() return ts:GetAllThreatTargets() end)
    if ok_all and all_targets ~= nil then all_count = tostring(container_count(all_targets)) end
    return "controller=" .. object_label(ctrl)
        .. " highest=" .. (highest and object_label(highest) or ("<none:" .. tostring(highest_err) .. ">"))
        .. " threat_count=" .. all_count
        .. " last=" .. method_value_text(ts, "GetLastKnownLocation")
        .. " suspicious=" .. method_value_text(ts, "GetSuspiciousLocation")
end

local function status_for_ai(ai, source)
    local parts = {
        "ai=" .. object_label(ai),
        "source=" .. tostring(source or ""),
    }
    local loc = actor_location_text(ai)
    if loc ~= "" then parts[#parts + 1] = "loc=" .. loc end

    local specified, specified_err = read_method_object(ai, "GetSpecifiedTargetOverride")
    parts[#parts + 1] = "specified=" .. (specified and object_label(specified) or ("<none:" .. tostring(specified_err) .. ">"))

    local lib = get_ai_function_library()
    if is_valid(lib) and lib.GetAiCurrentTarget then
        local ok_lib_current, lib_current = pcall(function() return lib:GetAiCurrentTarget(ai) end)
        if ok_lib_current then lib_current = facade.to_actor(lib_current) end
        parts[#parts + 1] = "lib_current=" .. ((ok_lib_current and is_valid(lib_current)) and object_label(lib_current) or ("<none:" .. tostring(ok_lib_current and "nil/invalid" or first_error_line(lib_current)) .. ">"))
    end

    local current, current_err = read_field_object(ai, "CurrentTarget")
    parts[#parts + 1] = "current=" .. (current and object_label(current) or ("<none:" .. tostring(current_err) .. ">"))

    local alert = nil
    if method_exists(ai, "GetCurrentAlertnessState") then
        local ok, value = pcall(function() return ai:GetCurrentAlertnessState() end)
        if ok then alert = tostring(value) else alert = "<err:" .. first_error_line(value) .. ">" end
    else
        local ok, value = pcall(function() return ai.CurrentAlertnessState end)
        if ok then alert = tostring(value) end
    end
    parts[#parts + 1] = "alertness=" .. tostring(alert or "<unknown>")
    local alert_comp, alert_route = alertness_component(ai)
    if is_valid(alert_comp) then
        local ok_state, state = pcall(function() return alert_comp:GetState() end)
        parts[#parts + 1] = "alert_component=" .. tostring(ok_state and state or ("<err:" .. first_error_line(state) .. ">")) .. " via " .. tostring(alert_route)
    else
        parts[#parts + 1] = "alert_component=<none:" .. tostring(alert_route) .. ">"
    end
    parts[#parts + 1] = threat_summary(ai)
    return table.concat(parts, " ; ")
end

local function require_confirm(args)
    return tostring(args or ""):lower():find("%f[%w]confirm%f[%W]") ~= nil
end

local function npc_inspect_scan_filter(short_name)
    local text = tostring(short_name or ""):lower()
    return text:sub(1, 6) == "bp_ai_" and text:find("character", 1, true) ~= nil
end

function M.scan(args)
    local s = trim(args)
    local limit = tonumber(s:match("(%d+)")) or 20
    if limit < 1 then limit = 1 end
    if limit > 100 then limit = 100 end
    local lower = s:lower()
    local wants_all = lower:find("%f[%w]all%f[%W]") ~= nil or lower:find("dangerall", 1, true) ~= nil
    local list, notes = collect_ai_candidates(wants_all)
    local report = {
        generated_unix = os.time(),
        mode = "active_ai",
        candidates = {},
        candidate_count = #list,
        notes = notes or {},
    }
    local lines = {
        "Enemy Aggro Active AI Scan",
        "candidates=" .. tostring(#list),
    }
    local shown = {}
    for i, ai in ipairs(list) do
        local name = object_name(ai)
        local class_name = object_class(ai)
        local loc = actor_location_text(ai)
        report.candidates[#report.candidates + 1] = {
            index = i,
            name = name,
            class = class_name,
            location = loc,
            controller = object_label(ai_controller(ai)),
        }
        lines[#lines + 1] = string.format("#%d %s[%s] loc=%s controller=%s",
            i, name, class_name, loc, object_label(ai_controller(ai)))
    end
    local ok_write, path_or_err = write_report("enemy_aggro_scan", report, lines)
    for i = 1, math.min(math.min(limit, 8), #list) do
        local ai = list[i]
        shown[#shown + 1] = string.format("#%d %s loc=%s", i, object_label(ai), actor_location_text(ai))
    end
    local note = ""
    if notes and #notes > 0 then note = " ; note=" .. table.concat(notes, " ; ") end
    local wrote = ok_write and (" ; wrote " .. tostring(path_or_err)) or (" ; write_failed=" .. tostring(path_or_err))
    if #shown == 0 then return true, "candidates=0" .. note .. wrote end
    return true, string.format("candidates=%d shown=%d ; %s%s%s", #list, #shown, table.concat(shown, " ; "), note, wrote)
end

function M.discover(args)
    local words = {}
    for word in tostring(args or ""):gmatch("%S+") do words[#words + 1] = word end
    local query = words[1] or "BP_AI_"
    local mode = words[2] or "all"
    if query == "*" then query = "BP_AI_" end
    local ok, detail = feature_scan.run_scan(query, mode, npc_inspect_scan_filter)
    if not ok then return false, detail end
    return true, tostring(detail) .. " ; npc-inspect style discovery wrote scan_results.json"
end

function M.status(args)
    local ai, source_or_err = resolve_ai_selector(args)
    if not ai then return false, source_or_err end
    return true, status_for_ai(ai, source_or_err)
end

function M.target(args)
    local s = trim(args)
    if not require_confirm(s) then
        return false, "usage: enemy.aggro.target <look|nearest|actor_name> confirm"
    end
    s = trim((s:gsub("%f[%w]confirm%f[%W]", "")))
    local ai, source_or_err = resolve_ai_selector(s)
    if not ai then return false, source_or_err end
    local player, player_err = local_player()
    if not player then return false, player_err end
    if not method_exists(ai, "SetSpecifiedTargetOverride") then return false, "SetSpecifiedTargetOverride missing" end
    local ok, err = facade.set_target(ai, player)
    if not ok then return false, "SetSpecifiedTargetOverride(player) failed: " .. first_error_line(err) end
    return true, "set target=" .. object_label(player) .. " ; " .. status_for_ai(ai, source_or_err)
end

local function parse_confirmed_selector_range(args, usage, default_range)
    local s = trim(args)
    if not require_confirm(s) then return nil, nil, usage end
    s = trim((s:gsub("%f[%w]confirm%f[%W]", "")))
    local words = {}
    for word in s:gmatch("%S+") do words[#words + 1] = word end
    local selector = words[1] or "look"
    local range = tonumber(words[2] or "")
    if tonumber(selector) then
        range = tonumber(selector)
        selector = "look"
    end
    if not range then range = default_range or 3500 end
    if range < 100 then range = 100 end
    if range > 50000 then range = 50000 end
    return selector, range, nil
end

local function try_call(label, attempts, callback)
    local ok, result = pcall(callback)
    attempts[#attempts + 1] = label .. "=" .. (ok and "ok" or first_error_line(result))
    return ok, result
end

function M.draw(args)
    local selector, range, usage_err = parse_confirmed_selector_range(
        args,
        "usage: enemy.aggro.draw <look|nearest|actor_name> [range_cm] confirm",
        3500)
    if not selector then return false, usage_err end
    local ai, source_or_err = resolve_ai_selector(selector)
    if not ai then return false, source_or_err end
    local player, player_err = local_player()
    if not player then return false, player_err end
    local lib, lib_err = get_ai_function_library()
    if not is_valid(lib) then return false, lib_err end
    local attempts = {}
    try_call("DrawAgroOnBehalfOfPlayer(player,ai," .. tostring(range) .. ")", attempts, function()
        return lib:DrawAgroOnBehalfOfPlayer(player, ai, range)
    end)
    return true, table.concat(attempts, " ; ") .. " ; " .. status_for_ai(ai, source_or_err)
end

function M.force(args)
    local selector, range, usage_err = parse_confirmed_selector_range(
        args,
        "usage: enemy.aggro.force <look|nearest|actor_name> [range_cm] confirm",
        3500)
    if not selector then return false, usage_err end
    local ai, source_or_err = resolve_ai_selector(selector)
    if not ai then return false, source_or_err end
    local player, player_err = local_player()
    if not player then return false, player_err end
    local lib = get_ai_function_library()
    local ctrl = ai_controller(ai)
    local alert_comp = alertness_component(ai)
    local ts = threat_system(ai)
    local attempts = {}

    if is_valid(lib) then
        try_call("SetAllowAlertnessStateChange(true)", attempts, function()
            return lib:SetAllowAlertnessStateChange(ai, true)
        end)
        try_call("SetOverrideCanEngageForAI(true)", attempts, function()
            return lib:SetOverrideCanEngageForAI(ai, true)
        end)
        try_call("SetOverrideMemoryDurationForAI(60)", attempts, function()
            return lib:SetOverrideMemoryDurationForAI(ai, 60.0)
        end)
        if is_valid(ctrl) then
            try_call("SetOverrideMemoryDurationForAIController(60)", attempts, function()
                return lib:SetOverrideMemoryDurationForAIController(ctrl, 60.0)
            end)
        end
        try_call("SetOverrideTetherRangeForAI(" .. tostring(range) .. ")", attempts, function()
            return lib:SetOverrideTetherRangeForAI(ai, range)
        end)
    else
        attempts[#attempts + 1] = "DominionAiFunctionLibrary=<missing>"
    end

    if is_valid(alert_comp) then
        try_call("AlertnessComponent.AllowStateChange(true)", attempts, function()
            return alert_comp:AllowStateChange(true)
        end)
    end
    if method_exists(ai, "SetSpecifiedTargetOverride") then
        try_call("SetSpecifiedTargetOverride(player)", attempts, function()
            local ok, err = facade.set_target(ai, player)
            if not ok then error(err) end
        end)
    end
    if is_valid(lib) then
        try_call("DrawAgroOnBehalfOfPlayer(player,ai," .. tostring(range) .. ")", attempts, function()
            return lib:DrawAgroOnBehalfOfPlayer(player, ai, range)
        end)
        local player_loc = feature_actor.actor_location(player) or feature_actor.actor_location(ai) or { X = 0, Y = 0, Z = 0 }
        try_call("MakeNoise(1,player,playerLoc," .. tostring(range) .. ")", attempts, function()
            return lib:MakeNoise(1.0, player, player_loc, range)
        end)
    end
    if is_valid(ts) then
        try_call("ThreatSystem.RateLimitedTick(0.2)", attempts, function()
            return ts:RateLimitedTick(0.2)
        end)
    end
    return true, table.concat(attempts, " ; ") .. " ; " .. status_for_ai(ai, source_or_err)
end

function M.clear(args)
    local s = trim(args)
    if not require_confirm(s) then
        return false, "usage: enemy.aggro.clear <look|nearest|actor_name> confirm"
    end
    s = trim((s:gsub("%f[%w]confirm%f[%W]", "")))
    local ai, source_or_err = resolve_ai_selector(s)
    if not ai then return false, source_or_err end
    if not method_exists(ai, "SetSpecifiedTargetOverride") then return false, "SetSpecifiedTargetOverride missing" end
    local ok, err = facade.set_target(ai, nil)
    if not ok then return false, "SetSpecifiedTargetOverride(nil) failed: " .. first_error_line(err) end
    return true, "cleared ; " .. status_for_ai(ai, source_or_err)
end

function M.restore(args)
    local s = trim(args)
    if not require_confirm(s) then
        return false, "usage: enemy.aggro.restore <look|nearest|actor_name> confirm"
    end
    s = trim((s:gsub("%f[%w]confirm%f[%W]", "")))
    local ai, source_or_err = resolve_ai_selector(s)
    if not ai then return false, source_or_err end
    local lib = get_ai_function_library()
    local attempts = {}
    if method_exists(ai, "SetSpecifiedTargetOverride") then
        try_call("SetSpecifiedTargetOverride(nil)", attempts, function()
            local ok, err = facade.set_target(ai, nil)
            if not ok then error(err) end
        end)
    end
    if is_valid(lib) then
        try_call("UnsetOverrideCanEngageForAI", attempts, function()
            return lib:UnsetOverrideCanEngageForAI(ai)
        end)
        try_call("UnsetOverrideMemoryDurationForAI", attempts, function()
            return lib:UnsetOverrideMemoryDurationForAI(ai)
        end)
        local ctrl = ai_controller(ai)
        if is_valid(ctrl) then
            try_call("UnsetOverrideMemoryDurationForAIController", attempts, function()
                return lib:UnsetOverrideMemoryDurationForAIController(ctrl)
            end)
        end
        try_call("UnsetOverrideTetherRangeForAI", attempts, function()
            return lib:UnsetOverrideTetherRangeForAI(ai)
        end)
    else
        attempts[#attempts + 1] = "DominionAiFunctionLibrary=<missing>"
    end
    return true, table.concat(attempts, " ; ") .. " ; " .. status_for_ai(ai, source_or_err)
end

return M
