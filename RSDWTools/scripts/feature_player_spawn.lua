local M = {}

local core = require("feature_player_core")

local function try_load_object(path)
    local load_object = rawget(_G, "LoadObject")
    if not load_object then return false, nil end
    return pcall(load_object, path)
end

-- Round 53 fix: Summon via the engine console exec instead of a direct
-- reflection call to UCheatManager::Summon. The reflection path takes the
-- short or long class path string and ultimately calls LoadObject<UClass>,
-- which fails ("Failed to find class.") on long object paths whose package
-- has not yet been loaded into memory. PlayerController:ConsoleCommand
-- routes through the same exec pipeline that the in-game `~` console uses
-- (UPlayer::Exec -> CallFunctionByNameWithArguments) which loads the
-- package on demand and resolves the trailing _C suffix correctly.
function M.summon(value_str)
    local s = value_str and value_str:match("^%s*(.-)%s*$") or ""
    if s == "" then return false, "usage: world.summon <ShortName_C | /Game/.../BP.BP_C>" end

    -- Resolve the local PlayerController via the canonical
    -- IsLocalController()-based resolver in feature_net. Was previously
    -- a UEHelpers-then-FindFirstOf walk, which on a multiplayer client
    -- could pick up the host PC and route the summon there.
    local feature_net = require("feature_net")
    local pc = feature_net.local_controller()
    if not pc then return false, "no player controller" end

    -- APlayerController::ConsoleCommand is a plain C++ method (not a
    -- UFunction), so UE4SS reflection can't bind a real `this` and the
    -- call traps with "UObject instance is nullptr". The reliable route
    -- is the BlueprintCallable UFunction
    -- UKismetSystemLibrary::ExecuteConsoleCommand(WorldContext, Cmd, SpecificPlayer).
    local ksl = StaticFindObject and StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") or nil
    if not (ksl and ksl:IsValid()) then
        return false, "KismetSystemLibrary CDO not found"
    end
    local cmd = "summon " .. s
    local execute_console_command = ksl["ExecuteConsoleCommand"]
    if not execute_console_command then return false, "ExecuteConsoleCommand missing" end
    local ok, err = pcall(function() execute_console_command(ksl, pc, cmd, pc) end)
    if not ok then return false, "ExecuteConsoleCommand failed: " .. tostring(err) end
    print(string.format("[RSDWTools] world.summon %s", s))
    return true, s
end

function M.load_class(value_str)
    local s = value_str and value_str:match("^%s*(.-)%s*$") or ""
    if s == "" then return false, "usage: world.class.load <ClassPath>" end

    local normalized = core.normalize_uclass_path(s)
    local already_loaded = nil
    if StaticFindObject then
        local ok_find, found = pcall(StaticFindObject, normalized)
        if ok_find and core.is_valid_uobject(found) then already_loaded = found end
    end

    local loaded_class, route, cp = core.resolve_uclass_via_kismet_softclass(s)
    if not loaded_class then
        if already_loaded then
            local detail = string.format("already loaded %s -> %s; soft-class probe failed: %s",
                normalized, core.safe_uobject_label(already_loaded), tostring(route))
            print("[RSDWTools] world.class.load " .. detail)
            return true, detail
        end
        return false, tostring(route) .. " (normalized: " .. tostring(cp or normalized) .. ")"
    end

    local state = already_loaded and "already loaded" or "loaded"
    local detail = string.format("%s %s -> %s via %s",
        state, cp, core.safe_uobject_label(loaded_class), route)
    print("[RSDWTools] world.class.load " .. detail)
    return true, detail
end

-- =============================================================================
-- world.spawn : the deliberate, transform-aware counterpart to world.summon.
--
-- Routes through UGameplayStatics::BeginDeferredActorSpawnFromClass +
-- FinishSpawningActor (the engine pair that the BP `Spawn Actor From Class`
-- node compiles to). Two reasons this is preferable to the cheat-console
-- `summon` route :
--
--   1. We get a real transform : aim-trace impact point + pawn yaw, instead
--      of the actor materialising at PC origin with no rotation control.
--   2. The spawn is *deferred* : the actor exists but BeginPlay hasn't run
--      yet, so any required UPROPERTYs (`ItemData` on world items,
--      `Switchables` on switch bases, etc) can be written before construction
--      logic kicks in. Without this, e.g. a freshly-summoned
--      ABP_RuntimeSpawnedWorldItem_C constructs as an empty broken pickup
--      because BeginPlay reads its (null) ItemData.
--
-- Args (whitespace-separated, optional JSON tail) :
--     <ClassPath>                  ; spawn at aim trace, no field writes
--     <ClassPath> {"Field":value}  ; same + write fields between Begin/Finish
--
-- ClassPath accepts the same forms as world.summon :
--     /Game/.../BP_Foo.BP_Foo_C        (BPGC)
--     /Script/Dominion.SwitchableDoor  (native)
--     ShortName_C                      (resolved via StaticFindObject sweep)
--
-- JSON value coercion :
--     number        -> assigned directly (UE4SS coerces float/int)
--     bool          -> assigned directly
--     string "/..." -> LoadObject<UObject>(value), assigned as object ref
--     string other  -> assigned as FString
--   Arrays / structs / TSubclassOf NOT supported yet ; if you need one,
--   spawn bare then use probe.write to set it field-by-field.

-- The two GameplayStatics UFunctions we need. Cached after first lookup.
local _gpl_cdo = nil
local function get_gameplay_statics()
    if _gpl_cdo and _gpl_cdo.IsValid and _gpl_cdo:IsValid() then return _gpl_cdo end
    if not StaticFindObject then return nil end
    local ok, obj = pcall(StaticFindObject, "/Script/Engine.Default__GameplayStatics")
    if ok and obj and obj.IsValid and obj:IsValid() then
        _gpl_cdo = obj
        return _gpl_cdo
    end
    return nil
end

-- Camera-forward line trace, returns hit location (or pawn loc fallback) + yaw.
-- Self-contained ; doesn't import feature_grab to keep the dep graph clean.
local function compute_spawn_transform()
    local pawn = core.get_pawn()
    if not pawn then return nil, "no pawn" end
    local feature_net = require("feature_net")
    local pc = feature_net.local_controller()
    if not pc then return nil, "no controller" end

    -- Pull camera viewpoint from the controller (works for both first-person
    -- and the spectator/oculus cases ; controller.GetPlayerViewPoint follows
    -- the active view target).
    local cam_loc, cam_rot
    local ok = pcall(function()
        local l = { X = 0, Y = 0, Z = 0 }
        local r = { Pitch = 0, Yaw = 0, Roll = 0 }
        pc:GetPlayerViewPoint(l, r)
        cam_loc, cam_rot = l, r
    end)
    if not (ok and cam_loc and cam_rot) then
        -- Fallback : just use pawn location with pawn yaw, raise a touch.
        local ok2, l = pcall(function() return pawn:K2_GetActorLocation() end)
        local ok3, r = pcall(function() return pawn:K2_GetActorRotation() end)
        if not (ok2 and ok3 and l and r) then return nil, "no transform source" end
        return {
            loc = { X = l.X, Y = l.Y, Z = l.Z + 50.0 },
            rot = { Pitch = 0, Yaw = r.Yaw or 0, Roll = 0 },
        }, nil
    end

    local pitch = (cam_rot.Pitch or 0) * math.pi / 180.0
    local yaw   = (cam_rot.Yaw   or 0) * math.pi / 180.0
    local cp    = math.cos(pitch)
    local fx, fy, fz = cp * math.cos(yaw), cp * math.sin(yaw), math.sin(pitch)
    local DIST = 600.0
    local start_v = { X = cam_loc.X, Y = cam_loc.Y, Z = cam_loc.Z }
    local end_v   = {
        X = cam_loc.X + fx * DIST,
        Y = cam_loc.Y + fy * DIST,
        Z = cam_loc.Z + fz * DIST,
    }

    -- Trace via KismetSystemLibrary so the world-context arg is implicit.
    local ksl = StaticFindObject and StaticFindObject("/Script/Engine.Default__KismetSystemLibrary") or nil
    local hit_loc = end_v  -- default if trace misses : just use the end point
    if ksl and ksl:IsValid() then
        local world = (function()
            local feature_field = require("feature_field")
            local w = feature_field.resolve_root("world")
            return w
        end)()
        if world then
            local hit = {}
            local zcol = { R = 0, G = 0, B = 0, A = 0 }
            local ignore = { pawn }
            local line_trace_single = ksl["LineTraceSingle"]
            if line_trace_single then
                local ok_t, did_hit = pcall(function()
                    return line_trace_single(ksl, world, start_v, end_v, "TraceTypeQuery1",
                        false, ignore, "EDrawDebugTrace::None", hit, true,
                        zcol, zcol, 0.0)
                end)
                if ok_t and did_hit and hit.Location then
                    hit_loc = { X = hit.Location.X, Y = hit.Location.Y, Z = hit.Location.Z }
                end
            end
        end
    end

    return {
        loc = hit_loc,
        rot = { Pitch = 0, Yaw = (cam_rot.Yaw or 0), Roll = 0 },
    }, nil
end

-- Attempt to apply a field-write table { name = value } to the deferred actor.
-- Object-ref strings (leading '/') get LoadObject'd. Everything else is
-- assigned directly and we let UE4SS's binding sort out coercion ; if a write
-- traps we just record it in the warnings list and keep going.
local function apply_field_writes(actor, fields)
    local warnings = {}
    if type(fields) ~= "table" then return warnings end
    for name, value in pairs(fields) do
        local resolved = value
        if type(value) == "string" and value:sub(1, 1) == "/" then
            local ok_o, obj = false, nil
            ok_o, obj = try_load_object(value)
            if not (ok_o and obj and obj.IsValid and obj:IsValid()) and StaticFindObject then
                ok_o, obj = pcall(StaticFindObject, value)
            end
            if ok_o and obj and obj.IsValid and obj:IsValid() then
                resolved = obj
            else
                warnings[#warnings + 1] = string.format(
                    "field %q : object path %q did not resolve "..
                    "(LoadObject + StaticFindObject both failed ; "..
                    "verify against tools/cache/asset_index.json)",
                    name, value)
                resolved = nil
            end
        end
        if resolved ~= nil then
            local ok_w, err = pcall(function() actor[name] = resolved end)
            if not ok_w then
                warnings[#warnings + 1] = string.format("field %q write failed: %s",
                    name, tostring(err))
            end
        end
    end
    return warnings
end

-- Tiny object JSON parser. Supports exactly what the spawn verbs need : a
-- top-level object whose values are string / number / boolean / null, plus
-- arrays of those primitives for world.spawn.transform's loc/rot/scale.
-- No nested objects and no escape-heavy strings (just \" and \\). Hand-rolled
-- so the mod has zero third-party Lua dependencies (dkjson isn't shipped in
-- this UE4SS build).
-- Returns ( table, nil ) on success or ( nil, errstring ) on failure.
local function _parse_flat_json_object(src)
    local i, n = 1, #src
    local function skip_ws()
        while i <= n do
            local c = src:sub(i, i)
            if c == " " or c == "\t" or c == "\n" or c == "\r" then i = i + 1
            else break end
        end
    end
    local function expect(ch)
        skip_ws()
        if src:sub(i, i) ~= ch then
            return false, string.format("expected %q at %d, got %q", ch, i, src:sub(i, i))
        end
        i = i + 1
        return true
    end
    local function parse_string()
        if src:sub(i, i) ~= '"' then return nil, "string must start with \"" end
        i = i + 1
        local buf = {}
        while i <= n do
            local c = src:sub(i, i)
            if c == '"' then i = i + 1; return table.concat(buf) end
            if c == "\\" then
                local nx = src:sub(i + 1, i + 1)
                if     nx == '"' then buf[#buf + 1] = '"'
                elseif nx == "\\" then buf[#buf + 1] = "\\"
                elseif nx == "/"  then buf[#buf + 1] = "/"
                elseif nx == "n"  then buf[#buf + 1] = "\n"
                elseif nx == "t"  then buf[#buf + 1] = "\t"
                elseif nx == "r"  then buf[#buf + 1] = "\r"
                else return nil, "unsupported escape \\" .. nx end
                i = i + 2
            else
                buf[#buf + 1] = c; i = i + 1
            end
        end
        return nil, "unterminated string"
    end
    local parse_value
    local function parse_array()
        if src:sub(i, i) ~= "[" then return nil, "array must start with [" end
        i = i + 1
        local out = {}
        skip_ws()
        if src:sub(i, i) == "]" then i = i + 1; return out end
        while true do
            local val, verr = parse_value()
            if val == nil and verr then return nil, verr end
            out[#out + 1] = val
            skip_ws()
            local sep = src:sub(i, i)
            if sep == "," then i = i + 1
            elseif sep == "]" then i = i + 1; return out
            else return nil, "expected , or ] after array value, got " .. sep end
        end
    end
    parse_value = function()
        skip_ws()
        local c = src:sub(i, i)
        if c == '"' then return parse_string() end
        if c == "[" then return parse_array() end
        if c == "t" and src:sub(i, i + 3) == "true"  then i = i + 4; return true end
        if c == "f" and src:sub(i, i + 4) == "false" then i = i + 5; return false end
        if c == "n" and src:sub(i, i + 3) == "null"  then i = i + 4; return nil end
        -- number : grab the longest numeric run, let tonumber validate.
        local s, e = src:find("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
        if s == i then
            local nstr = src:sub(s, e)
            local num = tonumber(nstr)
            if not num then return nil, "bad number " .. nstr end
            i = e + 1
            return num
        end
        return nil, "unexpected token at " .. i
    end

    skip_ws()
    if not expect("{") then return nil, "root must be object {...}" end
    local out = {}
    skip_ws()
    if src:sub(i, i) == "}" then i = i + 1; return out end
    while true do
        skip_ws()
        local key, kerr = parse_string()
        if not key then return nil, "key: " .. tostring(kerr) end
        local ok_c, cerr = expect(":")
        if not ok_c then return nil, cerr end
        local val, verr = parse_value()
        if val == nil and verr then return nil, "value for "..key..": "..verr end
        out[key] = val
        skip_ws()
        local sep = src:sub(i, i)
        if sep == "," then i = i + 1
        elseif sep == "}" then i = i + 1; return out
        else return nil, "expected , or } after value, got " .. sep end
    end
end

local function split_class_and_json_tail(s)
    local class_path, json_tail
    local brace_at = s:find("%s+{")
    if brace_at then
        class_path = s:sub(1, brace_at - 1):match("^%s*(.-)%s*$")
        json_tail  = s:sub(brace_at):match("^%s*(.*)$")
    else
        class_path = s
        json_tail  = nil
    end
    return class_path, json_tail
end

local function contains_array_value(fields)
    if type(fields) ~= "table" then return false end
    for _, value in pairs(fields) do
        if type(value) == "table" then return true end
    end
    return false
end

local function get_ci_field(tbl, names)
    if type(tbl) ~= "table" then return nil end
    for key, value in pairs(tbl) do
        local lower_key = tostring(key):lower()
        for _, name in ipairs(names) do
            if lower_key == name then return value end
        end
    end
    return nil
end

local function is_transform_json_key(key)
    local k = tostring(key):lower()
    return k == "loc" or k == "location"
        or k == "rot" or k == "rotation"
        or k == "scale"
end

local function vector3_from_array(value, field_name)
    if type(value) ~= "table" then
        return nil, field_name .. " must be [x,y,z]"
    end
    local x, y, z = tonumber(value[1]), tonumber(value[2]), tonumber(value[3])
    if x == nil or y == nil or z == nil then
        return nil, field_name .. " must contain three numbers"
    end
    return { X = x, Y = y, Z = z }, nil
end

local function scale3_from_value(value)
    if value == nil then return { X = 1, Y = 1, Z = 1 }, nil end
    if type(value) == "number" then return { X = value, Y = value, Z = value }, nil end
    return vector3_from_array(value, "scale")
end

local function parse_explicit_spawn_transform(parsed)
    local loc_value = get_ci_field(parsed, { "loc", "location" })
    if loc_value == nil then
        return nil, nil, "JSON requires loc:[x,y,z]"
    end

    local loc, loc_err = vector3_from_array(loc_value, "loc")
    if not loc then return nil, nil, loc_err end

    local rot = { Pitch = 0, Yaw = 0, Roll = 0 }
    local rot_value = get_ci_field(parsed, { "rot", "rotation" })
    if rot_value ~= nil then
        local rot_vec, rot_err = vector3_from_array(rot_value, "rot")
        if not rot_vec then return nil, nil, rot_err end
        rot = { Pitch = rot_vec.X, Yaw = rot_vec.Y, Roll = rot_vec.Z }
    end

    local scale_value = get_ci_field(parsed, { "scale" })
    local scale, scale_err = scale3_from_value(scale_value)
    if not scale then return nil, nil, scale_err end

    local fields = {}
    for key, value in pairs(parsed) do
        if not is_transform_json_key(key) then
            if type(value) == "table" then
                return nil, nil, "field " .. tostring(key) .. " uses an array; only loc/rot/scale accept arrays"
            end
            fields[key] = value
        end
    end
    if next(fields) == nil then fields = nil end

    return { loc = loc, rot = rot, scale = scale }, fields, nil
end

local function rotator_to_quat(rot)
    rot = rot or {}
    local pitch = (tonumber(rot.Pitch or rot.X) or 0) * math.pi / 360.0
    local yaw   = (tonumber(rot.Yaw   or rot.Y) or 0) * math.pi / 360.0
    local roll  = (tonumber(rot.Roll  or rot.Z) or 0) * math.pi / 360.0

    local sp, cp = math.sin(pitch), math.cos(pitch)
    local sy, cy = math.sin(yaw),   math.cos(yaw)
    local sr, cr = math.sin(roll),  math.cos(roll)

    return {
        X = cr * sp * sy - sr * cp * cy,
        Y = -cr * sp * cy - sr * cp * sy,
        Z = cr * cp * sy - sr * sp * cy,
        W = cr * cp * cy + sr * sp * sy,
    }
end

local function build_spawn_xform(xform)
    local loc = xform.loc
    local scale = xform.scale or { X = 1, Y = 1, Z = 1 }
    return {
        Rotation    = rotator_to_quat(xform.rot),
        Translation = { X = loc.X, Y = loc.Y, Z = loc.Z },
        Scale3D     = { X = scale.X or 1, Y = scale.Y or 1, Z = scale.Z or 1 },
    }
end

local function spawn_detail(class_path, xform, include_full_transform)
    local loc = xform.loc
    if not include_full_transform then
        return string.format("%s @ (%.1f,%.1f,%.1f)", class_path, loc.X, loc.Y, loc.Z)
    end

    local rot = xform.rot or { Pitch = 0, Yaw = 0, Roll = 0 }
    local scale = xform.scale or { X = 1, Y = 1, Z = 1 }
    return string.format("%s @ loc(%.1f,%.1f,%.1f) rot(%.1f,%.1f,%.1f) scale(%.3g,%.3g,%.3g)",
        class_path,
        loc.X, loc.Y, loc.Z,
        rot.Pitch or 0, rot.Yaw or 0, rot.Roll or 0,
        scale.X or 1, scale.Y or 1, scale.Z or 1)
end

local function spawn_actor_deferred(class_path, fields, xform, log_verb, include_full_transform)
    if class_path == "" then return false, "empty class path" end

    local uclass = core.resolve_uclass(class_path)
    if not uclass then return false, "could not resolve class : " .. class_path end

    local feature_net = require("feature_net")
    local pc = feature_net.local_controller()
    if not pc then return false, "no player controller" end

    local gpl = get_gameplay_statics()
    if not gpl then return false, "GameplayStatics CDO not found" end

    local spawn_xform = build_spawn_xform(xform)

    local actor
    local begin_deferred_spawn = gpl["BeginDeferredActorSpawnFromClass"]
    if not begin_deferred_spawn then return false, "BeginDeferredActorSpawnFromClass missing" end
    local ok_b, err_b = pcall(function()
        actor = begin_deferred_spawn(
            gpl, pc, uclass, spawn_xform,
            2,                  -- AdjustIfPossibleButAlwaysSpawn
            pc,                 -- Owner
            0                   -- TransformScaleMethod
        )
    end)
    if not ok_b then
        return false, "BeginDeferredActorSpawnFromClass trapped: " .. tostring(err_b)
    end
    if not (actor and actor.IsValid and actor:IsValid()) then
        return false, "BeginDeferredActorSpawnFromClass returned null"
    end

    pcall(function() actor.bRegisterAsRuntimeSpawned = true end)

    local warnings = {}
    if fields then
        warnings = apply_field_writes(actor, fields)
    end

    local finish_spawning_actor = gpl["FinishSpawningActor"]
    if not finish_spawning_actor then return false, "FinishSpawningActor missing" end
    local ok_f, err_f = pcall(function()
        finish_spawning_actor(gpl, actor, spawn_xform, 0)
    end)
    if not ok_f then
        return false, "FinishSpawningActor trapped: " .. tostring(err_f)
    end

    pcall(function()
        local feature_field = require("feature_field")
        feature_field.set_last_spawned(actor)
    end)

    local detail = spawn_detail(class_path, xform, include_full_transform)
    if #warnings > 0 then
        detail = detail .. string.format(" [%d field warnings]", #warnings)
        for _, w in ipairs(warnings) do
            print("[RSDWTools] " .. log_verb .. " warn: " .. w)
        end
    end
    print(string.format("[RSDWTools] %s %s", log_verb, detail))
    return true, detail
end

-- world.spawn implementation.
function M.spawn(value_str)
    local s = value_str and value_str:match("^%s*(.-)%s*$") or ""
    if s == "" then
        return false, "usage: world.spawn <ClassPath> [{json fields}]"
    end

    local class_path, json_tail = split_class_and_json_tail(s)

    if class_path == "" then return false, "empty class path" end

    local fields = nil
    if json_tail and json_tail ~= "" then
        local parsed, perr = _parse_flat_json_object(json_tail)
        if not parsed then return false, "JSON parse failed: " .. tostring(perr) end
        if contains_array_value(parsed) then
            return false, "JSON arrays are supported only by world.spawn.transform loc/rot/scale"
        end
        fields = parsed
    end

    local xform, err = compute_spawn_transform()
    if not xform then return false, "transform: " .. tostring(err) end

    return spawn_actor_deferred(class_path, fields, xform, "world.spawn", false)
end

function M.spawn_transform(value_str)
    local s = value_str and value_str:match("^%s*(.-)%s*$") or ""
    if s == "" then
        return false, "usage: world.spawn.transform <ClassPath> {\"loc\":[x,y,z],\"rot\":[pitch,yaw,roll],\"scale\":[x,y,z]}"
    end

    local class_path, json_tail = split_class_and_json_tail(s)
    if class_path == "" then return false, "empty class path" end
    if not (json_tail and json_tail ~= "") then
        return false, "world.spawn.transform requires JSON with loc:[x,y,z]"
    end

    local parsed, perr = _parse_flat_json_object(json_tail)
    if not parsed then return false, "JSON parse failed: " .. tostring(perr) end

    local xform, fields, xerr = parse_explicit_spawn_transform(parsed)
    if not xform then return false, "transform: " .. tostring(xerr) end

    return spawn_actor_deferred(class_path, fields, xform, "world.spawn.transform", true)
end

function M.spawn_safe(value_str)
    local s = value_str and value_str:match("^%s*(.-)%s*$") or ""
    if s == "" then
        return false, "usage: world.spawn.safe <ClassPath>"
    end

    local has_field_tail = s:find("%s+{") ~= nil
    local ok_spawn, spawn_detail = M.spawn(s)
    if ok_spawn then
        return true, "spawn " .. tostring(spawn_detail)
    end

    local spawn_error = tostring(spawn_detail)
    if has_field_tail then
        return false, "spawn failed and summon fallback skipped because JSON field writes would be lost: " .. spawn_error
    end
    if spawn_error:find("FinishSpawningActor", 1, true) then
        return false, "spawn failed after deferred actor creation; summon fallback skipped: " .. spawn_error
    end

    local ok_summon, summon_detail = M.summon(s)
    if ok_summon then
        return true, "fallback=summon spawn failed (" .. spawn_error .. "); summon " .. tostring(summon_detail)
    end
    return false, "spawn failed (" .. spawn_error .. "); summon fallback failed: " .. tostring(summon_detail)
end

-- =============================================================================
-- world.spawn.item : the *correct* path for spawning AWorldItem pickups.
--
-- world.spawn (the generic verb) constructs a bare AWorldItem, which means
-- the result has a mesh/icon but isn't enrolled with UWorldItemSubsystem :
-- the collect prompt appears but doesn't actually grant the item, magnet
-- pull doesn't work, and the pickup is invisible to inventory queries.
-- The internal API the game uses for its own loot drops is :
--
--   UItemHelperLibrary::SpawnAndLaunchItem_Sync(WorldContext, Params, OutFail)
--                                                  -> AWorldItem*
--
-- where Params is FItemSpawnParameters (Dumps/CXXHeaderDump/Dominion.hpp:3357).
-- That function does the full subsystem enrolment, transform-snap, optional
-- magnet binding, optional launch impulse, and returns the actor + a failure
-- reason string we can echo back into the ack.
--
-- Args :
--     <ItemDataPath>                ; spawn 1 of this item at aim, default class
--     <ItemDataPath> <count>        ; spawn N
--     <ItemDataPath> <count> <ItemActorClass>
--                                    ; override the AWorldItem subclass
--                                      (default: ABP_RuntimeSpawnedWorldItem_C)
--
-- All numbers are decimal int. Count clamps to >= 1.

-- Hard-default item-actor class. The base RuntimeSpawnedWorldItem BP : works
-- for every standard pickup (resources, equipment, consumables). Override
-- with the third arg if you specifically want the no-delay-magnet variant
-- or the processing-station output variant.
local DEFAULT_ITEM_ACTOR_CLASS_PATH =
    "/Game/Gameplay/WorldItems/BP_RuntimeSpawnedWorldItem.BP_RuntimeSpawnedWorldItem_C"

local _ihl_cdo = nil
local function get_item_helper_library()
    if _ihl_cdo and _ihl_cdo.IsValid and _ihl_cdo:IsValid() then return _ihl_cdo end
    if not StaticFindObject then return nil end
    local ok, obj = pcall(StaticFindObject, "/Script/Dominion.Default__ItemHelperLibrary")
    if ok and obj and obj.IsValid and obj:IsValid() then
        _ihl_cdo = obj
        return _ihl_cdo
    end
    return nil
end

function M.spawn_item(value_str)
    local s = value_str and value_str:match("^%s*(.-)%s*$") or ""
    if s == "" then
        return false, "usage: world.spawn.item <ItemDataPath> [count] [ItemActorClass]"
    end

    -- Whitespace-tokenise. Item paths never contain spaces so this is
    -- unambiguous : 1st token = ItemData, 2nd = optional count int,
    -- 3rd = optional class path/short-name.
    local tokens = {}
    for tok in s:gmatch("%S+") do tokens[#tokens + 1] = tok end
    local item_data_path  = tokens[1]
    local count_arg       = tonumber(tokens[2])
    local class_path_arg  = tokens[3]

    local count = count_arg or 1
    if count < 1 then count = 1 end

    -- Resolve the AWorldItem subclass. Default to the standard runtime-
    -- spawned BP unless the caller specified one.
    local class_path = class_path_arg or DEFAULT_ITEM_ACTOR_CLASS_PATH
    local item_class = core.resolve_uclass(class_path)
    if not item_class then
        return false, "could not resolve item actor class : " .. class_path
    end

    -- Resolve the ItemData asset. LoadObject -> StaticFindObject fallback.
    local function resolve_obj(path)
        local ok, o = try_load_object(path)
        if ok and o and o.IsValid and o:IsValid() then return o end
        if StaticFindObject then
            ok, o = pcall(StaticFindObject, path)
            if ok and o and o.IsValid and o:IsValid() then return o end
        end
        return nil
    end
    local item_data = resolve_obj(item_data_path)
    if not item_data then
        return false, "could not resolve ItemData : " .. item_data_path ..
                      "  (verify against tools/cache/asset_index.json by_leaf)"
    end

    local feature_net = require("feature_net")
    local pc = feature_net.local_controller()
    if not pc then return false, "no player controller" end

    local ihl = get_item_helper_library()
    if not ihl then return false, "ItemHelperLibrary CDO not found" end

    -- World context : pawn works (it's an AActor in a level). Using PC
    -- can hit edge cases when the controller is between possessions.
    local pawn = core.get_pawn()
    if not pawn then return false, "no pawn" end

    local xform, err = compute_spawn_transform()
    if not xform then return false, "transform: " .. tostring(err) end

    -- Quat from yaw (half-angle) ; same conversion as world.spawn.
    local yaw_rad = (xform.rot.Yaw or 0) * math.pi / 360.0
    local sin_y, cos_y = math.sin(yaw_rad), math.cos(yaw_rad)

    -- Build FItemSpawnParameters. UE4SS marshals Lua tables into structs by
    -- field name, so we mirror the C++ layout exactly. Every field is set
    -- (even no-op ones) so we don't accidentally inherit garbage from the
    -- caller's stack frame :
    local params = {
        ItemClass                            = item_class,
        bCreateItem                          = true,
        bMagnetize                           = false,    -- player has to walk over to pick it up
        SpawnedItemData                      = item_data,
        CopiedItem                           = nil,
        Count                                = count,
        Transform = {
            Rotation    = { X = 0, Y = 0, Z = sin_y, W = cos_y },
            Translation = { X = xform.loc.X, Y = xform.loc.Y, Z = xform.loc.Z + 50.0 },
            Scale3D     = { X = 1, Y = 1, Z = 1 },
        },
        LaunchDirection                      = { X = 0, Y = 0, Z = 1 },
        LaunchSpeed                          = 0.0,
        LaunchAngleVariance                  = 0.0,
        bSkipFloorSafetyCheck                = false,
        OwnerController                      = pc,
        bSpawnOnlyForController              = false,
        PlayerControllerThatDroppedItem      = pc,
    }

    -- Out-param : SpawnAndLaunchItem_Sync writes a failure reason string
    -- into a FString&. UE4SS marshals out-FStrings via a {} table reference ;
    -- passing a bare Lua string raises "no table was on the stack". The
    -- written value is read back from the return tuple.
    local spawned_actor, fail_reason
    local spawn_and_launch_item = ihl["SpawnAndLaunchItem_Sync"]
    if not spawn_and_launch_item then return false, "SpawnAndLaunchItem_Sync missing" end
    local ok_s, err_s = pcall(function()
        local fail = {}
        spawned_actor, fail_reason = spawn_and_launch_item(ihl, pawn, params, fail)
    end)
    if not ok_s then
        return false, "SpawnAndLaunchItem_Sync trapped: " .. tostring(err_s)
    end

    -- The function may legitimately return nil with a non-empty fail_reason
    -- (e.g. the floor-safety check rejected the location). Surface both.
    if not (spawned_actor and spawned_actor.IsValid and spawned_actor:IsValid()) then
        local why = (fail_reason and tostring(fail_reason)) or "unknown reason"
        if why == "" then why = "(empty failure reason)" end
        return false, "ItemHelper returned null : " .. why
    end

    -- Persistence opt-in : SpawnAndLaunchItem_Sync constructs the actor
    -- via NewObject + DispatchBeginPlay internally, so we don't have a
    -- deferred init window here. Set the flag *after* BeginPlay ; the
    -- save subsystem checks the flag at save-time, not at spawn-time, so
    -- a post-construction write still enrolls the actor.
    pcall(function() spawned_actor.bRegisterAsRuntimeSpawned = true end)

    -- Stash for the `lastspawned` reach root (see M.spawn).
    pcall(function()
        local feature_field = require("feature_field")
        feature_field.set_last_spawned(spawned_actor)
    end)

    local detail = string.format("%dx %s @ (%.1f,%.1f,%.1f)",
        count, item_data_path, xform.loc.X, xform.loc.Y, xform.loc.Z)
    print(string.format("[RSDWTools] world.spawn.item %s", detail))
    return true, detail
end

return M
