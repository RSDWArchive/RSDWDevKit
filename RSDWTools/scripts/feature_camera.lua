-- feature_camera.lua
--
-- Camera kit diagnostics. The first target is Unreal's stock
-- ADebugCameraController, reached through UCheatManager.ToggleDebugCamera.
-- This deliberately avoids the old RSDTools freecam path, which was unstable.

local M = {}

local DEFAULT_CAMERA_PATH = "spline"

local feature_net = require("feature_net")
local feature_actor = require("feature_actor")
local mod_paths = require("mod_paths")

local POSES = {}
local POSE_ORDER = {}
local LOOKAT_ACTOR_NAME = nil
local PLAY = { active = false, id = 0, handle = nil, driver = nil, step_fn = nil, engine_tick_started = false }
local STREAMING_SNAPSHOT = { sources = {}, grids = {}, grid_objects = {} }
local LOD_SNAPSHOT = { components = {} }
local ROLL_STATE = { key = nil, requested = nil, step = 5.0 }

local function is_valid(obj)
    if type(obj) ~= "userdata" then return false end
    if not obj.IsValid then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v and true or false
end

local function read_field(obj, field)
    if not is_valid(obj) then return nil end
    local ok, value = pcall(function() return obj[field] end)
    if ok then return value end
    return nil
end

local function write_field(obj, field, value)
    if not is_valid(obj) then return false, "invalid object" end
    local ok, err = pcall(function() obj[field] = value end)
    if ok then return true end
    return false, tostring(err)
end

local function method_exists(obj, method)
    if not is_valid(obj) then return false end
    local fn = nil
    pcall(function() fn = obj[method] end)
    return type(fn) == "function"
end

local function call_method(obj, method, ...)
    if not is_valid(obj) then return false, "invalid object" end
    if not method_exists(obj, method) then return false, method .. " not exposed" end
    local args = { ... }
    local ok, value = pcall(function() return obj[method](obj, table.unpack(args)) end)
    if ok then return true, value end
    return false, tostring(value)
end

local function call0(obj, method)
    if not is_valid(obj) then return nil end
    local ok, value = call_method(obj, method)
    if ok then return value end
    return nil
end

local function object_name(obj)
    if not is_valid(obj) then return "nil" end
    local ok_n, name = pcall(function() return obj:GetName() end)
    if ok_n and type(name) == "string" and name ~= "" then return name end
    local ok_f, fname = pcall(function() return obj:GetFName():ToString() end)
    if ok_f and type(fname) == "string" and fname ~= "" then return fname end
    return tostring(obj)
end

local function full_name(obj)
    if not is_valid(obj) then return "nil" end
    local ok, value = pcall(function() return obj:GetFullName() end)
    if ok and type(value) == "string" and value ~= "" then return value end
    return tostring(obj)
end

local function class_name(obj)
    if not is_valid(obj) then return "nil" end
    local ok_c, cls = pcall(function() return obj:GetClass() end)
    if not (ok_c and cls) then return "unknown" end
    local ok_n, name = pcall(function() return cls:GetName() end)
    if ok_n and type(name) == "string" and name ~= "" then return name end
    local ok_f, fname = pcall(function() return cls:GetFName():ToString() end)
    if ok_f and type(fname) == "string" and fname ~= "" then return fname end
    return "unknown"
end

local function label(obj)
    if not is_valid(obj) then return "nil" end
    return class_name(obj) .. ":" .. object_name(obj)
end

local function object_key(obj)
    if not is_valid(obj) then return nil end
    return tostring(obj)
end

local function clear_roll_state()
    ROLL_STATE.key = nil
    ROLL_STATE.requested = nil
end

local function is_debug_controller(pc)
    local cls = class_name(pc)
    return cls == "DebugCameraController" or cls:find("DebugCameraController", 1, true) ~= nil
end

local function is_cdo(obj)
    local name = object_name(obj)
    return name:sub(1, 9) == "Default__"
end

local function refresh_local_controller()
    if feature_net.invalidate_cache then pcall(function() feature_net.invalidate_cache() end) end
    return feature_net.local_controller()
end

local function debug_ref_from_controller(pc)
    if not is_valid(pc) then return nil end
    local cm = read_field(pc, "CheatManager")
    if not is_valid(cm) then return nil end
    local ref = read_field(cm, "DebugCameraControllerRef")
    if is_valid(ref) and is_debug_controller(ref) and not is_cdo(ref) then return ref end
    return nil
end

local function debug_ref_from_known_controllers(primary)
    local ref = debug_ref_from_controller(primary)
    if is_valid(ref) then return ref end
    if FindAllOf then
        local ok_p, pcs = pcall(FindAllOf, "PlayerController")
        if ok_p and type(pcs) == "table" then
            for _, pc in pairs(pcs) do
                if is_valid(pc) and not is_cdo(pc) and not is_debug_controller(pc) then
                    ref = debug_ref_from_controller(pc)
                    if is_valid(ref) then return ref end
                end
            end
        end
    end
    return nil
end

local function clear_debug_refs(only_inactive)
    local seen = {}
    local cleared = 0
    local function consider(pc)
        if not is_valid(pc) or is_cdo(pc) or is_debug_controller(pc) then return end
        local key = tostring(pc)
        if seen[key] then return end
        seen[key] = true
        local cm = read_field(pc, "CheatManager")
        if not is_valid(cm) then return end
        local ref = read_field(cm, "DebugCameraControllerRef")
        if not (is_valid(ref) and is_debug_controller(ref)) then return end
        if only_inactive and is_valid(read_field(ref, "Player")) then return end
        local ok = write_field(cm, "DebugCameraControllerRef", nil)
        if ok then cleared = cleared + 1 end
    end
    consider(refresh_local_controller())
    if FindAllOf then
        local ok_p, pcs = pcall(FindAllOf, "PlayerController")
        if ok_p and type(pcs) == "table" then
            for _, pc in pairs(pcs) do consider(pc) end
        end
    end
    if cleared > 0 and feature_net.invalidate_cache then pcall(function() feature_net.invalidate_cache() end) end
    return cleared
end

local function find_debug_controller(primary)
    local ref = debug_ref_from_known_controllers(primary)
    if is_valid(ref) then return ref end

    local best = nil
    local function consider(pc)
        if not is_valid(pc) or is_cdo(pc) or not is_debug_controller(pc) then return end
        local player = read_field(pc, "Player")
        if is_valid(player) then
            best = pc
            return true
        end
        if pc.IsLocalController then
            local ok, mine = pcall(function() return pc:IsLocalController() end)
            if ok and mine then
                best = pc
                return true
            end
        end
        if not best then best = pc end
        return false
    end

    if FindAllOf then
        local ok_d, list = pcall(FindAllOf, "DebugCameraController")
        if ok_d and type(list) == "table" then
            for _, pc in pairs(list) do
                if consider(pc) then return best end
            end
        end
        local ok_p, pcs = pcall(FindAllOf, "PlayerController")
        if ok_p and type(pcs) == "table" then
            for _, pc in pairs(pcs) do
                if consider(pc) then return best end
            end
        end
    end
    return best
end

local function original_controller(debug_pc, fallback_pc)
    if is_valid(debug_pc) then
        local orig = read_field(debug_pc, "OriginalControllerRef")
        if is_valid(orig) then return orig end
    end
    if is_valid(fallback_pc) and not is_debug_controller(fallback_pc) then return fallback_pc end
    return nil
end

local function resolve_controllers()
    local pc = refresh_local_controller()
    local debug_pc = is_debug_controller(pc) and pc or find_debug_controller(pc)
    local orig = original_controller(debug_pc, pc)
    if not is_valid(orig) and is_valid(pc) and not is_debug_controller(pc) then orig = pc end
    return pc, debug_pc, orig
end

local function get_cheat_manager(pc)
    if not is_valid(pc) then return nil end
    local cm = read_field(pc, "CheatManager")
    if is_valid(cm) then return cm end
    if pc.EnableCheats then
        pcall(function() pc:EnableCheats() end)
        cm = read_field(pc, "CheatManager")
        if is_valid(cm) then return cm end
    end
    return nil
end

local function execute_console(pc, command)
    if is_valid(pc) and pc.SendToConsole then
        local ok = pcall(function() pc:SendToConsole(command) end)
        if ok then return true, "SendToConsole" end
    end

    local ksl = nil
    if StaticFindObject then
        local ok, obj = pcall(StaticFindObject, "/Script/Engine.Default__KismetSystemLibrary")
        if ok and is_valid(obj) then ksl = obj end
    end
    if ksl and ksl.ExecuteConsoleCommand and is_valid(pc) then
        local ok = pcall(function() ksl:ExecuteConsoleCommand(pc, command, pc) end)
        if ok then return true, "ExecuteConsoleCommand" end
    end
    return false, "no console execution path"
end

local function get_view_target(pc)
    if not is_valid(pc) then return nil end
    if pc.GetViewTarget then
        local ok, value = pcall(function() return pc:GetViewTarget() end)
        if ok and is_valid(value) then return value end
    end
    return nil
end

local function get_pawn(pc)
    if not is_valid(pc) then return nil end
    local pawn = read_field(pc, "Pawn")
    if is_valid(pawn) then return pawn end
    if pc.K2_GetPawn then
        local ok, value = pcall(function() return pc:K2_GetPawn() end)
        if ok and is_valid(value) then return value end
    end
    return nil
end

local function array_count(arr)
    if not arr then return 0 end
    local ok_len, len = pcall(function() return #arr end)
    if ok_len and type(len) == "number" and len > 0 then return len end
    local ok_num, num = pcall(function() return arr:Num() end)
    if ok_num and type(num) == "number" then return num end
    local ok_array, array_num = pcall(function() return arr:GetArrayNum() end)
    if ok_array and type(array_num) == "number" then return array_num end
    return ok_len and tonumber(len) or 0
end

local function array_get(arr, index)
    if not arr then return nil end
    local ok, value = pcall(function() return arr[index] end)
    if ok then return value end
    return nil
end

local function get_acknowledged_pawn(pc)
    if not is_valid(pc) then return nil end
    local pawn = read_field(pc, "AcknowledgedPawn")
    if is_valid(pawn) then return pawn end
    return get_pawn(pc)
end

local function get_camera_line(pc)
    if not is_valid(pc) then return "view=nil" end
    local loc, rot = nil, nil
    if pc.GetPlayerViewPoint then
        pcall(function()
            local l = { X = 0, Y = 0, Z = 0 }
            local r = { Pitch = 0, Yaw = 0, Roll = 0 }
            pc:GetPlayerViewPoint(l, r)
            loc, rot = l, r
        end)
    end
    local fov = nil
    local pcm = read_field(pc, "PlayerCameraManager")
    if is_valid(pcm) and pcm.GetFOVAngle then
        local ok, value = pcall(function() return pcm:GetFOVAngle() end)
        if ok and type(value) == "number" then fov = value end
    end
    if fov == nil and is_valid(pcm) then
        local value = read_field(pcm, "DefaultFOV")
        if type(value) == "number" then fov = value end
    end
    if loc and rot then
        return string.format("view=(%.1f,%.1f,%.1f) rot=(%.1f,%.1f,%.1f) fov=%s",
            tonumber(loc.X) or 0, tonumber(loc.Y) or 0, tonumber(loc.Z) or 0,
            tonumber(rot.Pitch) or 0, tonumber(rot.Yaw) or 0, tonumber(rot.Roll) or 0,
            fov and string.format("%.1f", fov) or "?")
    end
    return "view=nil fov=" .. (fov and string.format("%.1f", fov) or "?")
end

local function debug_active()
    local pc, debug_pc = resolve_controllers()
    if is_valid(pc) and is_debug_controller(pc) then return true, pc end
    if is_valid(debug_pc) then
        local player = read_field(debug_pc, "Player")
        if is_valid(player) then return true, debug_pc end
    end
    return false, debug_pc
end

local function camera_manager_for(pc)
    local pcm = read_field(pc, "PlayerCameraManager")
    if is_valid(pcm) then return pcm end
    return nil
end

local function repair_widened_roll_bounds(pc)
    local pcm = camera_manager_for(pc)
    if not is_valid(pcm) then return false, "no PlayerCameraManager" end
    local min_v = tonumber(read_field(pcm, "ViewRollMin"))
    local max_v = tonumber(read_field(pcm, "ViewRollMax"))
    if not (min_v and max_v and min_v <= -179.9 and max_v >= 179.9) then
        return true, string.format("unchanged [%s,%s]", tostring(min_v or "?"), tostring(max_v or "?"))
    end
    local ok_min, err_min = write_field(pcm, "ViewRollMin", -89.9)
    local ok_max, err_max = write_field(pcm, "ViewRollMax", 89.9)
    if ok_min and ok_max then return true, "repaired [-180,180] -> [-89.9,89.9]" end
    return false, "repair failed min=" .. tostring(err_min) .. " max=" .. tostring(err_max)
end

local function short_status()
    local active = debug_active()
    local _, detail = M.status()
    return active, detail
end

local function request_toggle(owner, pc)
    local cm = get_cheat_manager(owner)
    if is_valid(cm) and cm.ToggleDebugCamera then
        local ok, err = pcall(function() cm:ToggleDebugCamera() end)
        if ok then
            if feature_net.invalidate_cache then pcall(function() feature_net.invalidate_cache() end) end
            local _, detail = M.status()
            return true, "toggle requested via CheatManager; " .. tostring(detail)
        end
        local ok_c, via = execute_console(owner or pc, "ToggleDebugCamera")
        if ok_c then return true, "toggle requested via " .. via .. " after direct call failed: " .. tostring(err) end
        return false, "ToggleDebugCamera failed: " .. tostring(err)
    end
    local ok_c, via = execute_console(owner or pc, "ToggleDebugCamera")
    if ok_c then return true, "toggle requested via " .. via end
    return false, "no CheatManager.ToggleDebugCamera and " .. tostring(via)
end

local function direct_disable_via(cm, label_text)
    local ok, err = call_method(cm, "DisableDebugCamera")
    if not ok then return false, label_text .. ": " .. tostring(err) end
    if feature_net.invalidate_cache then pcall(function() feature_net.invalidate_cache() end) end
    local active, detail = short_status()
    if not active then return true, label_text .. "; " .. tostring(detail) end
    return false, label_text .. " returned but DebugCamera still active; " .. tostring(detail)
end

local function console_disable_via(pc, command, label_text)
    local ok, via = execute_console(pc, command)
    if not ok then return false, label_text .. ": " .. tostring(via) end
    if feature_net.invalidate_cache then pcall(function() feature_net.invalidate_cache() end) end
    local active, detail = short_status()
    if not active then return true, label_text .. " via " .. via .. "; " .. tostring(detail) end
    return false, label_text .. " via " .. via .. " returned but DebugCamera still active; " .. tostring(detail)
end

function M.status()
    local pc, debug_pc, orig = resolve_controllers()
    local cm = get_cheat_manager(orig or pc)
    local ref = read_field(cm, "DebugCameraControllerRef")
    local active = debug_active()
    local speed = read_field(debug_pc, "SpeedScale")
    local selected = call0(debug_pc, "GetSelectedActor")
    local view_pc = (active and is_valid(debug_pc)) and debug_pc or pc
    local parts = {
        "active=" .. tostring(active and true or false),
        "pc=" .. label(pc),
        "orig=" .. label(orig),
        "debug=" .. label(debug_pc),
        "ref=" .. label(ref),
        "pawn=" .. label(get_pawn(view_pc)),
        "target=" .. label(get_view_target(view_pc)),
        "selected=" .. label(selected),
        "speed=" .. tostring(speed or "?"),
        get_camera_line(view_pc),
    }
    return true, table.concat(parts, " ")
end

function M.toggle()
    local active = debug_active()
    if active then return M.disable() end
    local pc, _, orig = resolve_controllers()
    local owner = orig or pc
    return request_toggle(owner, pc)
end

function M.enable()
    local active = debug_active()
    if active then
        local _, detail = M.status()
        return true, "already active; " .. tostring(detail)
    end
    clear_debug_refs(true)
    local pc, _, orig = resolve_controllers()
    return request_toggle(orig or pc, pc)
end

function M.disable()
    local active, debug_pc = debug_active()
    if not active then
        clear_roll_state()
        local _, detail = M.status()
        return true, "already inactive; " .. tostring(detail)
    end
    repair_widened_roll_bounds(debug_pc)

    local pc, _, orig = resolve_controllers()
    local attempts = {}

    local orig_cm = get_cheat_manager(orig or pc)
    local ok_o, detail_o = direct_disable_via(orig_cm, "original CheatManager.DisableDebugCamera")
    if ok_o then clear_roll_state(); return true, detail_o end
    attempts[#attempts + 1] = detail_o

    local debug_cm = get_cheat_manager(debug_pc)
    local ok_d, detail_d = direct_disable_via(debug_cm, "debug CheatManager.DisableDebugCamera")
    if ok_d then clear_roll_state(); return true, detail_d end
    attempts[#attempts + 1] = detail_d

    local ok_ct, detail_ct = console_disable_via(debug_pc, "ToggleDebugCamera", "debug controller ToggleDebugCamera")
    if ok_ct then clear_roll_state(); return true, detail_ct end
    attempts[#attempts + 1] = detail_ct

    local ok_cd, detail_cd = console_disable_via(debug_pc, "DisableDebugCamera", "debug controller DisableDebugCamera")
    if ok_cd then clear_roll_state(); return true, detail_cd end
    attempts[#attempts + 1] = detail_cd

    local ok_force, detail_force = M.force_restore()
    if ok_force then
        clear_roll_state()
        return true, "force_restore fallback after engine disable failed; " .. tostring(detail_force)
    end
    attempts[#attempts + 1] = "force_restore: " .. tostring(detail_force)
    return false, "engine disable paths and force_restore failed. attempts: " .. table.concat(attempts, " | ")
end

function M.force_restore()
    local active, debug_pc = debug_active()
    local pc, _, orig = resolve_controllers()
    if not active then
        local cleared = clear_debug_refs(true)
        clear_roll_state()
        local _, detail = M.status()
        return true, "already inactive; cleared_refs=" .. tostring(cleared) .. "; " .. tostring(detail)
    end
    if not is_valid(debug_pc) then return false, "no DebugCamera controller" end
    repair_widened_roll_bounds(debug_pc)
    if not is_valid(orig) then orig = pc end
    if not is_valid(orig) then return false, "no original player controller" end

    local steps = {}
    local player = read_field(debug_pc, "OriginalPlayer") or read_field(debug_pc, "Player")
    local pawn = get_pawn(orig) or get_acknowledged_pawn(orig)

    if is_valid(debug_pc) and debug_pc.ReceiveOnDeactivate then
        local ok = pcall(function() debug_pc:ReceiveOnDeactivate(orig) end)
        steps[#steps + 1] = "ReceiveOnDeactivate=" .. tostring(ok)
    end

    if is_valid(player) then
        local ok_lp = write_field(player, "PlayerController", orig)
        local ok_op = write_field(orig, "Player", player)
        local ok_dp = write_field(debug_pc, "Player", nil)
        steps[#steps + 1] = "player.PlayerController=" .. tostring(ok_lp)
        steps[#steps + 1] = "orig.Player=" .. tostring(ok_op)
        steps[#steps + 1] = "debug.Player=nil:" .. tostring(ok_dp)
    else
        steps[#steps + 1] = "player=nil"
    end

    if is_valid(pawn) then
        if orig.Possess then
            local ok = pcall(function() orig:Possess(pawn) end)
            steps[#steps + 1] = "Possess=" .. tostring(ok)
        end
        if orig.ClientRestart then
            local ok = pcall(function() orig:ClientRestart(pawn) end)
            steps[#steps + 1] = "ClientRestart=" .. tostring(ok)
        end
        if orig.SetViewTargetWithBlend then
            local ok = pcall(function() orig:SetViewTargetWithBlend(pawn, 0.0, 0, 0.0, false) end)
            steps[#steps + 1] = "SetViewTarget=" .. tostring(ok)
        end
    else
        steps[#steps + 1] = "pawn=nil"
    end

    local cm = get_cheat_manager(orig)
    if is_valid(cm) then
        local ok_ref = write_field(cm, "DebugCameraControllerRef", nil)
        steps[#steps + 1] = "DebugCameraControllerRef=nil:" .. tostring(ok_ref)
    end
    steps[#steps + 1] = "cleared_refs=" .. tostring(clear_debug_refs(false))

    if feature_net.invalidate_cache then pcall(function() feature_net.invalidate_cache() end) end
    local _, detail = M.status()
    clear_roll_state()
    return true, table.concat(steps, " ") .. "; " .. tostring(detail)
end

function M.speed(value_str)
    local n = tonumber((value_str or ""):match("^%s*(.-)%s*$"))
    if not n then return false, "usage: camera.debug.speed <scale>" end
    if n < 0.01 then n = 0.01 end
    if n > 100.0 then n = 100.0 end
    local active, debug_pc = debug_active()
    if not active or not is_valid(debug_pc) then return false, "DebugCamera is not active" end
    if debug_pc.SetPawnMovementSpeedScale then
        local ok, err = pcall(function() debug_pc:SetPawnMovementSpeedScale(n) end)
        if not ok then return false, "SetPawnMovementSpeedScale failed: " .. tostring(err) end
    else
        local ok, err = pcall(function() debug_pc.SpeedScale = n end)
        if not ok then return false, "SpeedScale write failed: " .. tostring(err) end
    end
    return true, string.format("%.3g", n)
end

function M.display()
    local active, debug_pc = debug_active()
    if not active or not is_valid(debug_pc) then return false, "DebugCamera is not active" end
    if not debug_pc.ToggleDisplay then return false, "DebugCamera.ToggleDisplay not exposed" end
    local ok, err = pcall(function() debug_pc:ToggleDisplay() end)
    if not ok then return false, "ToggleDisplay failed: " .. tostring(err) end
    return true, "toggled"
end

function M.selected()
    local active, debug_pc = debug_active()
    if not active or not is_valid(debug_pc) then return false, "DebugCamera is not active" end
    local selected = call0(debug_pc, "GetSelectedActor")
    return true, label(selected)
end

-- ---------- Camera rig v1 ----------

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function unwrap_value(value)
    if type(value) == "userdata" then
        local ok, unwrapped = pcall(function()
            local getter = value.get
            if type(getter) ~= "function" then return nil end
            return getter(value)
        end)
        if ok and unwrapped ~= nil then return unwrapped end
    end
    return value
end

local function text_value(value)
    value = unwrap_value(value)
    if value == nil then return "nil" end
    if type(value) == "boolean" or type(value) == "number" or type(value) == "string" then return tostring(value) end
    if type(value) == "userdata" then
        local ok_ts, ts = pcall(function() return value:ToString() end)
        if ok_ts and type(ts) == "string" and ts ~= "" then return ts end
        local ok_fn, fn = pcall(function() return value:GetFName():ToString() end)
        if ok_fn and type(fn) == "string" and fn ~= "" then return fn end
        local ok_name, name = pcall(function() return value:GetName() end)
        if ok_name and type(name) == "string" and name ~= "" then return name end
    end
    return tostring(value)
end

local function read_member(obj, field)
    if obj == nil then return nil end
    local ok, value = pcall(function() return obj[field] end)
    if ok then return unwrap_value(value) end
    return nil
end

local function write_member(obj, field, value)
    if obj == nil then return false, "nil target" end
    local ok, err = pcall(function() obj[field] = value end)
    if ok then return true end
    return false, tostring(err)
end

local function first_number(args, fallback)
    local token = trim(args):match("^(%S+)")
    local n = tonumber(token)
    if not n then return fallback end
    return n
end

local function number_after_first(args)
    local rest = trim(args):match("^%S+%s+(.+)$") or ""
    return tonumber(rest:match("^(%S+)") or "")
end

local function find_live_objects(class_name)
    local out = {}
    if not FindAllOf then return out end
    local ok, list = pcall(FindAllOf, class_name)
    if not ok or not list then return out end
    local n = array_count(list)
    if n > 0 then
        for i = 1, n do
            local obj = array_get(list, i)
            if is_valid(obj) and not is_cdo(obj) then out[#out + 1] = obj end
        end
    else
        for _, obj in pairs(list) do
            if is_valid(obj) and not is_cdo(obj) then out[#out + 1] = obj end
        end
    end
    return out
end

local function find_world_settings()
    for _, class in ipairs({ "DominionWorldSettings", "WorldSettings" }) do
        local list = find_live_objects(class)
        for _, ws in ipairs(list) do
            if is_valid(read_field(ws, "WorldPartition")) then return ws end
        end
        if #list > 0 then return list[1] end
    end
    return nil
end

local function find_runtime_hash()
    local ws = find_world_settings()
    local wp = read_field(ws, "WorldPartition")
    local hash = read_field(wp, "RuntimeHash")
    return ws, wp, hash
end

local function streaming_locrot(source)
    local loc = { X = 0, Y = 0, Z = 0 }
    local rot = { Pitch = 0, Yaw = 0, Roll = 0 }
    if not (is_valid(source) and source.GetStreamingSourceLocationAndRotation) then return "loc=? rot=?" end
    local ok = pcall(function() source:GetStreamingSourceLocationAndRotation(loc, rot) end)
    if not ok then return "loc=? rot=?" end
    return string.format("loc=(%.0f,%.0f,%.0f) rot=(%.0f,%.0f,%.0f)",
        tonumber(loc.X) or 0, tonumber(loc.Y) or 0, tonumber(loc.Z) or 0,
        tonumber(rot.Pitch) or 0, tonumber(rot.Yaw) or 0, tonumber(rot.Roll) or 0)
end

local function read_shapes(source)
    local direct = read_field(source, "StreamingSourceShapes")
    local direct_n = array_count(direct)
    local out = {}
    if is_valid(source) and source.GetStreamingSourceShapes then
        pcall(function() source:GetStreamingSourceShapes(out) end)
    end
    return direct, direct_n, out, array_count(out)
end

local function shape_to_record(shape)
    if not shape then return nil end
    return {
        bUseGridLoadingRange = read_member(shape, "bUseGridLoadingRange"),
        LoadingRangeScale = read_member(shape, "LoadingRangeScale"),
        Radius = read_member(shape, "Radius"),
        bIsSector = read_member(shape, "bIsSector"),
        SectorAngle = read_member(shape, "SectorAngle"),
        Location = read_member(shape, "Location"),
        Rotation = read_member(shape, "Rotation"),
    }
end

local function record_to_shape(record)
    return {
        bUseGridLoadingRange = record.bUseGridLoadingRange == true,
        LoadingRangeScale = tonumber(record.LoadingRangeScale) or 1.0,
        Radius = tonumber(record.Radius) or 0.0,
        bIsSector = record.bIsSector == true,
        SectorAngle = tonumber(record.SectorAngle) or 360.0,
        Location = record.Location or { X = 0.0, Y = 0.0, Z = 0.0 },
        Rotation = record.Rotation or { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 },
    }
end

local function shape_summary(shape)
    local rec = shape_to_record(shape)
    if not rec then return "nil" end
    return string.format("grid=%s scale=%s radius=%s sector=%s angle=%s",
        tostring(rec.bUseGridLoadingRange), tostring(rec.LoadingRangeScale), tostring(rec.Radius),
        tostring(rec.bIsSector), tostring(rec.SectorAngle))
end

local function streaming_source_summary(name, source)
    if not is_valid(source) then return name .. "=nil" end
    local direct_shapes, direct_n, out_shapes, out_n = read_shapes(source)
    local shape = direct_n > 0 and array_get(direct_shapes, 1) or array_get(out_shapes, 1)
    local enabled = call0(source, "IsStreamingSourceEnabled")
    local activate = call0(source, "StreamingSourceShouldActivate")
    local block = call0(source, "StreamingSourceShouldBlockOnSlowStreaming")
    local priority = call0(source, "GetStreamingSourcePriority")
    return string.format(
        "%s=%s enabled=%s activate=%s block=%s priority=%s fields={enable=%s activate=%s block=%s priority=%s} shapes=direct:%d/out:%d first={%s} %s",
        name, label(source), tostring(enabled), tostring(activate), tostring(block), text_value(priority),
        tostring(read_field(source, "bEnableStreamingSource")),
        tostring(read_field(source, "bStreamingSourceShouldActivate")),
        tostring(read_field(source, "bStreamingSourceShouldBlockOnSlowStreaming")),
        text_value(read_field(source, "StreamingSourcePriority")),
        direct_n, out_n, shape_summary(shape), streaming_locrot(source))
end

local function snapshot_source(source)
    if not is_valid(source) then return end
    local key = full_name(source)
    if STREAMING_SNAPSHOT.sources[key] then return end
    local shapes, n = read_field(source, "StreamingSourceShapes"), 0
    n = array_count(shapes)
    local snap_shapes = {}
    for i = 1, n do
        snap_shapes[#snap_shapes + 1] = shape_to_record(array_get(shapes, i))
    end
    STREAMING_SNAPSHOT.sources[key] = {
        object = source,
        bEnableStreamingSource = read_field(source, "bEnableStreamingSource"),
        bStreamingSourceShouldActivate = read_field(source, "bStreamingSourceShouldActivate"),
        bStreamingSourceShouldBlockOnSlowStreaming = read_field(source, "bStreamingSourceShouldBlockOnSlowStreaming"),
        StreamingSourcePriority = read_field(source, "StreamingSourcePriority"),
        shapes = snap_shapes,
    }
end

local function set_shape_fields(shape, scale, radius)
    local writes, errs = 0, {}
    local fields = {
        { "bUseGridLoadingRange", true },
        { "LoadingRangeScale", scale },
        { "Radius", radius },
        { "bIsSector", false },
        { "SectorAngle", 360.0 },
        { "Location", { X = 0.0, Y = 0.0, Z = 0.0 } },
        { "Rotation", { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 } },
    }
    for _, item in ipairs(fields) do
        local ok, err = write_member(shape, item[1], item[2])
        if ok then writes = writes + 1 else errs[#errs + 1] = item[1] .. ":" .. tostring(err) end
    end
    return writes, table.concat(errs, ",")
end

local function set_shape_record(shape, record)
    local restored = record_to_shape(record or {})
    local fields = {
        { "bUseGridLoadingRange", restored.bUseGridLoadingRange },
        { "LoadingRangeScale", restored.LoadingRangeScale },
        { "Radius", restored.Radius },
        { "bIsSector", restored.bIsSector },
        { "SectorAngle", restored.SectorAngle },
        { "Location", restored.Location },
        { "Rotation", restored.Rotation },
    }
    local writes, errs = 0, {}
    for _, item in ipairs(fields) do
        local ok, err = write_member(shape, item[1], item[2])
        if ok then writes = writes + 1 else errs[#errs + 1] = item[1] .. ":" .. tostring(err) end
    end
    return writes, table.concat(errs, ",")
end

local function append_streaming_shape(shapes, scale, radius)
    local shape = {
        bUseGridLoadingRange = true,
        LoadingRangeScale = scale,
        Radius = radius,
        bIsSector = false,
        SectorAngle = 360.0,
        Location = { X = 0.0, Y = 0.0, Z = 0.0 },
        Rotation = { Pitch = 0.0, Yaw = 0.0, Roll = 0.0 },
    }
    local ok_add, err_add = pcall(function() shapes:Add(shape) end)
    if ok_add then return true, ":Add" end
    local n = array_count(shapes)
    local ok_idx, err_idx = pcall(function() shapes[n + 1] = shape end)
    if ok_idx then return true, "indexed" end
    return false, tostring(err_add) .. " / " .. tostring(err_idx)
end

local function apply_source_streaming_scale(source, scale, radius)
    if not is_valid(source) then return false, "nil source" end
    snapshot_source(source)
    local results = {}
    for _, item in ipairs({
        { "bEnableStreamingSource", true },
        { "bStreamingSourceShouldActivate", true },
        { "bStreamingSourceShouldBlockOnSlowStreaming", true },
        { "StreamingSourcePriority", 0 },
    }) do
        local ok, err = write_field(source, item[1], item[2])
        results[#results + 1] = item[1] .. "=" .. (ok and "ok" or tostring(err))
    end

    local shapes = read_field(source, "StreamingSourceShapes")
    if not shapes then return true, label(source) .. " fields only; shapes unreadable; " .. table.concat(results, ",") end
    local n = array_count(shapes)
    if n == 0 then
        local ok, detail = append_streaming_shape(shapes, scale, radius)
        results[#results + 1] = "append_shape=" .. tostring(ok) .. ":" .. tostring(detail)
        n = array_count(shapes)
    end
    local shaped = 0
    for i = 1, n do
        local shape = array_get(shapes, i)
        local writes, errs = set_shape_fields(shape, scale, radius)
        if writes > 0 then shaped = shaped + 1 end
        if errs ~= "" then results[#results + 1] = "shape" .. tostring(i) .. "_errs=" .. errs end
    end
    results[#results + 1] = "shapes_written=" .. tostring(shaped)
    return true, label(source) .. " " .. table.concat(results, ",")
end

local function grid_name(grid, index)
    local name = read_member(grid, "GridName")
    local text = text_value(name)
    if text == "nil" or text == "" then return "grid" .. tostring(index) end
    return text
end

local function collect_streaming_grids()
    local _, _, hash = find_runtime_hash()
    local grids = read_field(hash, "StreamingGrids")
    local out = {}
    local n = array_count(grids)
    for i = 1, n do
        local grid = array_get(grids, i)
        if grid then out[#out + 1] = { index = i, grid = grid, name = grid_name(grid, i) } end
    end
    return out, hash
end

local function snapshot_grid(hash, item)
    if not (is_valid(hash) and item and item.grid) then return end
    local key = full_name(hash) .. "#" .. tostring(item.index)
    if STREAMING_SNAPSHOT.grids[key] then return end
    STREAMING_SNAPSHOT.grids[key] = {
        LoadingRange = read_member(item.grid, "LoadingRange"),
        bBlockOnSlowStreaming = read_member(item.grid, "bBlockOnSlowStreaming"),
    }
    STREAMING_SNAPSHOT.grid_objects[key] = item.grid
end

local function apply_grid_range(range)
    local grids, hash = collect_streaming_grids()
    local wrote, errs = 0, {}
    for _, item in ipairs(grids) do
        snapshot_grid(hash, item)
        local ok_r, err_r = write_member(item.grid, "LoadingRange", range)
        local ok_b, err_b = write_member(item.grid, "bBlockOnSlowStreaming", true)
        if ok_r then wrote = wrote + 1 else errs[#errs + 1] = item.name .. ":range:" .. tostring(err_r) end
        if not ok_b then errs[#errs + 1] = item.name .. ":block:" .. tostring(err_b) end
    end
    return wrote, #grids, table.concat(errs, ",")
end

local function max_grid_range()
    local grids = collect_streaming_grids()
    local max_range = 0
    for _, item in ipairs(grids) do
        local value = tonumber(read_member(item.grid, "LoadingRange")) or 0
        if value > max_range then max_range = value end
    end
    return max_range
end

local function baseline_grid_range()
    local snap_range = 0
    for _, snap in pairs(STREAMING_SNAPSHOT.grids or {}) do
        local value = tonumber(snap.LoadingRange) or 0
        if value > snap_range then snap_range = value end
    end
    if snap_range > 0 then return snap_range end
    return max_grid_range()
end

local function dispatch_streaming_console(command)
    local pc, _, orig = resolve_controllers()
    local ok, via = execute_console(orig or pc, command)
    return ok, tostring(via)
end

local function streaming_component_summary()
    local parts = {}
    local comps = find_live_objects("WorldPartitionStreamingSourceComponent")
    for i = 1, math.min(#comps, 4) do
        local comp = comps[i]
        local shapes = read_field(comp, "Shapes")
        local enabled = call0(comp, "IsStreamingSourceEnabled")
        local completed = call0(comp, "IsStreamingCompleted")
        parts[#parts + 1] = string.format("%s enabled=%s completed=%s priority=%s state=%s shapes=%d",
            label(comp), tostring(enabled), tostring(completed), text_value(read_field(comp, "Priority")),
            text_value(read_field(comp, "TargetState")), array_count(shapes))
    end
    if #comps > 4 then parts[#parts + 1] = "..." .. tostring(#comps - 4) .. " more" end
    if #parts == 0 then return "streaming_components=0" end
    return "streaming_components=" .. tostring(#comps) .. " [" .. table.concat(parts, " | ") .. "]"
end

local function world_partition_summary()
    local ws, wp, hash = find_runtime_hash()
    if not is_valid(ws) then return "world_settings=nil" end
    if not is_valid(wp) then return "world_settings=" .. label(ws) .. " world_partition=nil" end
    local parts = {
        "world_settings=" .. label(ws),
        "wp=" .. label(wp),
        "wp_enable=" .. tostring(read_field(wp, "bEnableStreaming")),
        "hash=" .. label(hash),
        "hash_zcull=" .. tostring(read_field(hash, "bEnableZCulling")),
    }
    local grids = collect_streaming_grids()
    local grid_parts = {}
    for _, item in ipairs(grids) do
        grid_parts[#grid_parts + 1] = string.format("%d:%s cell=%s range=%s block=%s clientOnly=%s",
            item.index, item.name,
            tostring(read_member(item.grid, "CellSize")), tostring(read_member(item.grid, "LoadingRange")),
            tostring(read_member(item.grid, "bBlockOnSlowStreaming")), tostring(read_member(item.grid, "bClientOnlyVisible")))
    end
    parts[#parts + 1] = "grids=" .. tostring(#grid_parts) .. " [" .. table.concat(grid_parts, " | ") .. "]"
    return table.concat(parts, " ")
end

local function streaming_class_counts()
    local names = {
        "WorldPartitionStreamingSourceComponent",
        "CullDistanceVolume",
        "VolumeActorCulling",
        "InteractableFoliageSubsystem",
        "InteractableFoliageManager",
        "NearbyFoliageConverterComponent",
        "WorldPartitionAwareComponent",
        "DomNetworkStreamingSubsystem",
    }
    local parts = {}
    for _, name in ipairs(names) do parts[#parts + 1] = name .. "=" .. tostring(#find_live_objects(name)) end
    return table.concat(parts, " ")
end

function M.streaming_status()
    local pc, debug_pc, orig = resolve_controllers()
    local active = debug_active()
    local active_source = active and debug_pc or pc
    local parts = {
        "active_debug=" .. tostring(active and true or false),
        "active_source=" .. label(active_source),
        streaming_source_summary("pc", pc),
        streaming_source_summary("orig", orig),
        streaming_source_summary("debug", debug_pc),
        world_partition_summary(),
        streaming_component_summary(),
        streaming_class_counts(),
    }
    return true, table.concat(parts, " ; ")
end

function M.streaming_scale(args)
    local scale = first_number(args, 4.0)
    if scale < 0.1 then scale = 0.1 end
    if scale > 64.0 then scale = 64.0 end
    local base_range = baseline_grid_range()
    local range = number_after_first(args) or ((base_range > 0 and base_range or 64000.0) * scale)
    if range < 1000.0 then range = 1000.0 end

    local pc, debug_pc, orig = resolve_controllers()
    local targets, seen = {}, {}
    local function add_target(obj)
        if not is_valid(obj) then return end
        local key = full_name(obj)
        if seen[key] then return end
        seen[key] = true
        targets[#targets + 1] = obj
    end
    if debug_active() then add_target(debug_pc) end
    add_target(pc)
    add_target(orig)
    if #targets == 0 then return false, "no player/debug controller found" end

    local source_results = {}
    for _, source in ipairs(targets) do
        local ok, detail = apply_source_streaming_scale(source, scale, range)
        source_results[#source_results + 1] = (ok and "ok:" or "fail:") .. tostring(detail)
    end

    local grids_written, grid_count, grid_errs = apply_grid_range(range)
    local c1_ok, c1_via = dispatch_streaming_console("wp.Runtime.OverrideRuntimeSpatialHashLoadingRange " .. tostring(math.floor(range)))
    local _, status = M.streaming_status()
    return true, string.format("scale=%.3g base=%.0f range=%.0f sources={%s} grids=%d/%d grid_errs=%s console={range:%s/%s} ; %s",
        scale, base_range, range, table.concat(source_results, " | "), grids_written, grid_count, grid_errs ~= "" and grid_errs or "none",
        tostring(c1_ok), c1_via, status)
end

function M.streaming_reset()
    local restored_sources, restored_grids, errs = 0, 0, {}
    for key, snap in pairs(STREAMING_SNAPSHOT.sources) do
        local source = snap.object
        if is_valid(source) then
            for _, item in ipairs({
                { "bEnableStreamingSource", snap.bEnableStreamingSource },
                { "bStreamingSourceShouldActivate", snap.bStreamingSourceShouldActivate },
                { "bStreamingSourceShouldBlockOnSlowStreaming", snap.bStreamingSourceShouldBlockOnSlowStreaming },
                { "StreamingSourcePriority", snap.StreamingSourcePriority },
            }) do
                if item[2] ~= nil then
                    local ok, err = write_field(source, item[1], item[2])
                    if not ok then errs[#errs + 1] = key .. ":" .. item[1] .. ":" .. tostring(err) end
                end
            end
            local shapes = read_field(source, "StreamingSourceShapes")
            if shapes then
                local cleared = false
                pcall(function() shapes:Empty(); cleared = true end)
                if not cleared then pcall(function() shapes:Reset(); cleared = true end) end
                if cleared then
                    for _, rec in ipairs(snap.shapes or {}) do
                        local ok, err = append_streaming_shape(shapes, tonumber(rec.LoadingRangeScale) or 1.0, tonumber(rec.Radius) or 0.0)
                        if ok then
                            local shape = array_get(shapes, array_count(shapes))
                            if shape then set_shape_record(shape, rec) end
                        else
                            errs[#errs + 1] = key .. ":restore_shape:" .. tostring(err)
                        end
                    end
                else
                    errs[#errs + 1] = key .. ":clear_shapes_failed"
                end
            end
            restored_sources = restored_sources + 1
        end
    end
    for key, snap in pairs(STREAMING_SNAPSHOT.grids) do
        local grid = STREAMING_SNAPSHOT.grid_objects[key]
        if grid then
            local ok_r, err_r = write_member(grid, "LoadingRange", snap.LoadingRange)
            local ok_b, err_b = write_member(grid, "bBlockOnSlowStreaming", snap.bBlockOnSlowStreaming)
            if ok_r or ok_b then restored_grids = restored_grids + 1 end
            if not ok_r then errs[#errs + 1] = key .. ":range:" .. tostring(err_r) end
            if not ok_b then errs[#errs + 1] = key .. ":block:" .. tostring(err_b) end
        end
    end
    dispatch_streaming_console("wp.Runtime.OverrideRuntimeSpatialHashLoadingRange -1")
    STREAMING_SNAPSHOT = { sources = {}, grids = {}, grid_objects = {} }
    local _, status = M.streaming_status()
    return true, string.format("restored_sources=%d restored_grids=%d errs=%s ; %s",
        restored_sources, restored_grids, #errs > 0 and table.concat(errs, " | ") or "none", status)
end

local function parse_word_tail(args)
    local s = trim(args)
    if s == "" then return nil, "" end
    local word, tail = s:match("^(%S+)%s*(.-)%s*$")
    return word, trim(tail)
end

local function json_skip_ws(s, i)
    while i <= #s do
        local c = s:sub(i, i)
        if c ~= " " and c ~= "\t" and c ~= "\n" and c ~= "\r" then return i end
        i = i + 1
    end
    return i
end

local json_decode_value

local function json_decode_string(s, i)
    local out = {}
    while i <= #s do
        local c = s:sub(i, i)
        if c == '"' then
            return table.concat(out), i + 1
        elseif c == '\\' then
            local nx = s:sub(i + 1, i + 1)
            if nx == '"' or nx == '\\' or nx == '/' then out[#out + 1] = nx; i = i + 2
            elseif nx == 'n' then out[#out + 1] = '\n'; i = i + 2
            elseif nx == 't' then out[#out + 1] = '\t'; i = i + 2
            elseif nx == 'r' then out[#out + 1] = '\r'; i = i + 2
            elseif nx == 'b' then out[#out + 1] = '\b'; i = i + 2
            elseif nx == 'f' then out[#out + 1] = '\f'; i = i + 2
            elseif nx == 'u' then
                local cp = tonumber(s:sub(i + 2, i + 5), 16) or 0
                if cp < 0x80 then
                    out[#out + 1] = string.char(cp)
                elseif cp < 0x800 then
                    out[#out + 1] = string.char(0xC0 + math.floor(cp / 0x40), 0x80 + (cp % 0x40))
                else
                    out[#out + 1] = string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + (cp % 0x40))
                end
                i = i + 6
            else
                return nil, "bad escape \\" .. tostring(nx)
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    return nil, "unterminated string"
end

local function json_decode_number(s, i)
    local start = i
    if s:sub(i, i) == '-' then i = i + 1 end
    while i <= #s do
        local c = s:sub(i, i)
        if (c >= '0' and c <= '9') or c == '.' or c == 'e' or c == 'E' or c == '+' or c == '-' then i = i + 1 else break end
    end
    local num = tonumber(s:sub(start, i - 1))
    if not num then return nil, "bad number" end
    return num, i
end

local function json_decode_array(s, i)
    local out = {}
    i = json_skip_ws(s, i)
    if s:sub(i, i) == ']' then return out, i + 1 end
    while true do
        local v, j, err = json_decode_value(s, i)
        if v == nil and err then return nil, err end
        out[#out + 1] = v
        i = json_skip_ws(s, j)
        local c = s:sub(i, i)
        if c == ',' then i = json_skip_ws(s, i + 1)
        elseif c == ']' then return out, i + 1
        else return nil, "expected ',' or ']' in array" end
    end
end

local function json_decode_object(s, i)
    local out = {}
    i = json_skip_ws(s, i)
    if s:sub(i, i) == '}' then return out, i + 1 end
    while true do
        if s:sub(i, i) ~= '"' then return nil, "expected key string in object" end
        local key, j, err = json_decode_string(s, i + 1)
        if not key then return nil, err end
        i = json_skip_ws(s, j)
        if s:sub(i, i) ~= ':' then return nil, "expected ':' after key" end
        i = json_skip_ws(s, i + 1)
        local v, k2, verr = json_decode_value(s, i)
        if v == nil and verr then return nil, verr end
        out[key] = v
        i = json_skip_ws(s, k2)
        local c = s:sub(i, i)
        if c == ',' then i = json_skip_ws(s, i + 1)
        elseif c == '}' then return out, i + 1
        else return nil, "expected ',' or '}' in object" end
    end
end

json_decode_value = function(s, i)
    i = json_skip_ws(s, i)
    local c = s:sub(i, i)
    if c == '{' then return json_decode_object(s, i + 1) end
    if c == '[' then return json_decode_array(s, i + 1) end
    if c == '"' then return json_decode_string(s, i + 1) end
    if c == 't' and s:sub(i, i + 3) == 'true' then return true, i + 4 end
    if c == 'f' and s:sub(i, i + 4) == 'false' then return false, i + 5 end
    if c == 'n' and s:sub(i, i + 3) == 'null' then return nil, i + 4 end
    if c == '-' or (c >= '0' and c <= '9') then return json_decode_number(s, i) end
    return nil, "unexpected character at position " .. tostring(i)
end

local function json_decode(text)
    if type(text) ~= "string" or #text == 0 then return nil, "empty" end
    local v, _, err = json_decode_value(text, 1)
    if v == nil and err then return nil, err end
    return v
end

local function safe_ipc_filename(raw, fallback)
    local name = trim(raw)
    if name == "" then name = fallback end
    if name:find("/", 1, true) or name:find("\\", 1, true) or name:find(":", 1, true) or name:find("..", 1, true) then
        return nil, "bad filename"
    end
    if name:find("[^%w%._%-]") then return nil, "bad filename" end
    return name
end

local function read_ipc_json(filename)
    local d = mod_paths.ipc_dir()
    if not d then return nil, "ipc dir unavailable" end
    local f, err = io.open(d .. "\\" .. filename, "rb")
    if not f then return nil, "open failed: " .. tostring(err) end
    local body = f:read("*a")
    f:close()
    if not body or #body == 0 then return nil, "file empty" end
    local doc, derr = json_decode(body)
    if not doc then return nil, "parse failed: " .. tostring(derr) end
    return doc
end

local function json_num(tbl, fallback, ...)
    if type(tbl) ~= "table" then return fallback end
    local keys = { ... }
    for _, key in ipairs(keys) do
        local value = tbl[key]
        if value ~= nil then
            local n = tonumber(value)
            if n ~= nil then return n end
        end
    end
    return fallback
end

local function pose_from_json_item(item, index)
    if type(item) ~= "table" then return nil, "bad pose at " .. tostring(index) end
    local name = trim(item.name or "")
    if name == "" then return nil, "pose missing name at " .. tostring(index) end
    local loc = item.loc or item.location
    local rot = item.rot or item.rotation
    if type(loc) ~= "table" then return nil, "pose missing loc at " .. tostring(index) end
    if type(rot) ~= "table" then return nil, "pose missing rot at " .. tostring(index) end
    return name, {
        source = tostring(item.source or "Project"),
        loc = {
            X = json_num(loc, 0, "x", "X"),
            Y = json_num(loc, 0, "y", "Y"),
            Z = json_num(loc, 0, "z", "Z"),
        },
        rot = {
            Pitch = json_num(rot, 0, "pitch", "Pitch"),
            Yaw = json_num(rot, 0, "yaw", "Yaw"),
            Roll = json_num(rot, 0, "roll", "Roll"),
        },
        fov = tonumber(item.fov) or 80,
    }
end

local function load_poses_from_doc(doc, required)
    if type(doc) ~= "table" then return false, "bad camera file" end
    local raw_poses = doc.poses
    if type(raw_poses) ~= "table" then
        if required then return false, "camera file missing poses" end
        return true, "poses=unchanged"
    end

    local next_poses = {}
    local next_order = {}
    for i, item in ipairs(raw_poses) do
        local name, pose_or_err = pose_from_json_item(item, i)
        if not name then return false, pose_or_err end
        if not next_poses[name] then next_order[#next_order + 1] = name end
        next_poses[name] = pose_or_err
    end
    POSES = next_poses
    POSE_ORDER = next_order
    return true, "poses=" .. tostring(#next_order)
end

local function json_escape(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
    s = s:gsub("\r", "\\r"):gsub("\n", "\\n"):gsub("\t", "\\t")
    s = s:gsub("[%z\1-\31]", "")
    return s
end

local function jstr(s)
    return '"' .. json_escape(s) .. '"'
end

local function jnum(n)
    n = tonumber(n)
    if not n then return "0" end
    return string.format("%.6f", n)
end

local function pose_to_json(name, pose)
    return table.concat({
        "{",
        '"name":', jstr(name), ",",
        '"source":', jstr(pose.source or ""), ",",
        '"fov":', jnum(pose.fov or 80), ",",
        '"loc":{"x":', jnum(pose.loc.X), ',"y":', jnum(pose.loc.Y), ',"z":', jnum(pose.loc.Z), "},",
        '"rot":{"pitch":', jnum(pose.rot.Pitch), ',"yaw":', jnum(pose.rot.Yaw), ',"roll":', jnum(pose.rot.Roll), "}",
        "}"
    })
end

local function write_poses_json()
    local d = mod_paths.ipc_dir()
    if not d then return false, "ipc dir unavailable" end
    local parts = { '{"poses":[' }
    for i, name in ipairs(POSE_ORDER) do
        if i > 1 then parts[#parts + 1] = "," end
        parts[#parts + 1] = pose_to_json(name, POSES[name])
    end
    parts[#parts + 1] = "]}"
    return mod_paths.write_atomic(d .. "\\camera_poses.json", table.concat(parts))
end

local function pose_count()
    local n = 0
    for _, name in ipairs(POSE_ORDER) do
        if POSES[name] then n = n + 1 end
    end
    return n
end

local function remember_pose(name, pose)
    if not POSES[name] then POSE_ORDER[#POSE_ORDER + 1] = name end
    POSES[name] = pose
    return write_poses_json()
end

local function active_camera_controller()
    local active, debug_pc = debug_active()
    if active and is_valid(debug_pc) then return debug_pc, true end
    local pc = refresh_local_controller()
    return pc, false
end

local function read_camera_pose(pc, source)
    if not is_valid(pc) then return nil, "no camera controller" end
    if not pc.GetPlayerViewPoint then return nil, "GetPlayerViewPoint not exposed" end
    local loc, rot = { X = 0, Y = 0, Z = 0 }, { Pitch = 0, Yaw = 0, Roll = 0 }
    local ok, err = pcall(function() pc:GetPlayerViewPoint(loc, rot) end)
    if not ok then return nil, "GetPlayerViewPoint failed: " .. tostring(err) end

    local fov = nil
    local pcm = read_field(pc, "PlayerCameraManager")
    if is_valid(pcm) and pcm.GetFOVAngle then
        local ok_f, value = pcall(function() return pcm:GetFOVAngle() end)
        if ok_f and type(value) == "number" then fov = value end
    end
    if fov == nil and is_valid(pcm) then
        local value = read_field(pcm, "DefaultFOV")
        if type(value) == "number" then fov = value end
    end
    if fov == nil then fov = 80.0 end

    return {
        source = source or label(pc),
        loc = { X = tonumber(loc.X) or 0, Y = tonumber(loc.Y) or 0, Z = tonumber(loc.Z) or 0 },
        rot = { Pitch = tonumber(rot.Pitch) or 0, Yaw = tonumber(rot.Yaw) or 0, Roll = tonumber(rot.Roll) or 0 },
        fov = tonumber(fov) or 80.0,
    }
end

local function ensure_debug_camera(speed_arg)
    local active = debug_active()
    if not active then
        local ok, detail = M.enable()
        if not ok then return nil, "enable failed: " .. tostring(detail) end
    end
    if speed_arg and trim(speed_arg) ~= "" then
        M.speed(speed_arg)
    end
    local active2, debug_pc = debug_active()
    if not active2 or not is_valid(debug_pc) then return nil, "DebugCamera did not become active" end
    repair_widened_roll_bounds(debug_pc)
    return debug_pc
end

local function rig_target(debug_pc)
    local target = get_view_target(debug_pc)
    if is_valid(target) then return target end
    return get_pawn(debug_pc)
end

local function set_fov(pc, fov)
    fov = tonumber(fov)
    if not fov or not is_valid(pc) then return false end
    if pc.FOV then pcall(function() pc:FOV(fov) end) end
    local pcm = read_field(pc, "PlayerCameraManager")
    if is_valid(pcm) then pcall(function() pcm.DefaultFOV = fov end) end
    return true
end

local function set_actor_pose(actor, pose)
    if not is_valid(actor) then return false, "invalid rig target" end
    local hit = {}
    if actor.K2_SetActorLocationAndRotation then
        local ok, result = pcall(function()
            return actor:K2_SetActorLocationAndRotation(pose.loc, pose.rot, false, hit, true)
        end)
        if ok and result ~= false then return true end
    end
    if actor.K2_TeleportTo then
        local ok, result = pcall(function() return actor:K2_TeleportTo(pose.loc, pose.rot) end)
        if ok and result ~= false then return true end
    end
    if actor.K2_SetActorLocation then
        pcall(function() actor:K2_SetActorLocation(pose.loc, false, hit, true) end)
    end
    if actor.K2_SetActorRotation then
        pcall(function() actor:K2_SetActorRotation(pose.rot, true) end)
        return true
    end
    return false, "no reflected actor transform setter accepted pose"
end

local function apply_pose(debug_pc, pose)
    if not is_valid(debug_pc) then return false, "no DebugCamera controller" end
    local target = rig_target(debug_pc)
    local ok, err = set_actor_pose(target, pose)
    if not ok then return false, err end
    if debug_pc.SetControlRotation then pcall(function() debug_pc:SetControlRotation(pose.rot) end) end
    if debug_pc.ClientSetLocation then pcall(function() debug_pc:ClientSetLocation(pose.loc, pose.rot) end) end
    set_fov(debug_pc, pose.fov)
    return true, label(target)
end

local function atan2(y, x)
    if math.atan2 then return math.atan2(y, x) end
    return math.atan(y, x)
end

local function rotation_looking_at(from_loc, to_loc)
    local dx = (to_loc.X or 0) - (from_loc.X or 0)
    local dy = (to_loc.Y or 0) - (from_loc.Y or 0)
    local dz = (to_loc.Z or 0) - (from_loc.Z or 0)
    local yaw = math.deg(atan2(dy, dx))
    local horiz = math.sqrt(dx * dx + dy * dy)
    local pitch = math.deg(atan2(dz, horiz))
    return { Pitch = pitch, Yaw = yaw, Roll = 0 }
end

local function apply_lookat_if_needed(pose)
    if not LOOKAT_ACTOR_NAME then return pose end
    local actor = feature_actor.resolve_actor_by_name(LOOKAT_ACTOR_NAME)
    if not feature_actor.is_valid_object(actor) then return pose end
    local loc = feature_actor.actor_location(actor)
    if not loc then return pose end
    local rot = rotation_looking_at(pose.loc, loc)
    rot.Roll = tonumber(pose.rot and pose.rot.Roll) or 0
    return {
        source = pose.source,
        loc = pose.loc,
        rot = rot,
        fov = pose.fov,
    }
end

local function normalize_angle_delta(delta)
    while delta > 180 do delta = delta - 360 end
    while delta < -180 do delta = delta + 360 end
    return delta
end

local function lerp_angle(a, b, t)
    return a + normalize_angle_delta(b - a) * t
end

local function clamp01(t)
    t = tonumber(t) or 0
    if t < 0 then return 0 end
    if t > 1 then return 1 end
    return t
end

local function smoothstep(t)
    t = clamp01(t)
    return t * t * (3 - 2 * t)
end

local function smootherstep(t)
    t = clamp01(t)
    return t * t * t * (t * (t * 6 - 15) + 10)
end

local function ease_value(t, curve)
    curve = tostring(curve or "linear"):lower():gsub("%s+", "_"):gsub("-", "_")
    t = clamp01(t)
    if curve == "linear" then return t end
    if curve == "ease_in" or curve == "easein" then return t * t end
    if curve == "ease_out" or curve == "easeout" then return 1 - ((1 - t) * (1 - t)) end
    if curve == "ease_in_out" or curve == "easeinout" or curve == "smooth" or curve == "smoothstep" then return smoothstep(t) end
    if curve == "cinematic" or curve == "smoother" or curve == "smootherstep" then return smootherstep(t) end
    if curve == "hold_start" then
        if t < 0.25 then return 0 end
        return smoothstep((t - 0.25) / 0.75)
    end
    if curve == "hold_end" then
        if t > 0.75 then return 1 end
        return smoothstep(t / 0.75)
    end
    return smoothstep(t)
end

local function lerp_num(a, b, t)
    return (a or 0) + ((b or 0) - (a or 0)) * t
end

local function lerp_loc(a, b, t)
    return {
        X = lerp_num(a.X, b.X, t),
        Y = lerp_num(a.Y, b.Y, t),
        Z = lerp_num(a.Z, b.Z, t),
    }
end

local function loc_distance(a, b)
    local dx = (b.X or 0) - (a.X or 0)
    local dy = (b.Y or 0) - (a.Y or 0)
    local dz = (b.Z or 0) - (a.Z or 0)
    return math.sqrt(dx * dx + dy * dy + dz * dz)
end

local LOD_COMPONENT_CLASSES = {
    "StaticMeshComponent",
    "InstancedStaticMeshComponent",
    "HierarchicalInstancedStaticMeshComponent",
    "HLODInstancedStaticMeshComponent",
    "SkeletalMeshComponent",
    "SkinnedMeshComponent",
    "LandscapeComponent",
}

local LOD_SNAPSHOT_FIELDS = {
    "ForcedLodModel",
    "ForcedLOD",
    "MinLOD",
    "MinLodModel",
    "LODBias",
    "bOverrideMinLod",
    "bOverrideMinLOD",
    "StreamingDistanceMultiplier",
    "InstanceLODDistanceScale",
    "InstanceStartCullDistance",
    "InstanceEndCullDistance",
    "MinDrawDistance",
    "LDMaxDrawDistance",
    "CachedMaxDrawDistance",
    "bNeverDistanceCull",
}

local function vector_to_loc(value)
    value = unwrap_value(value)
    if type(value) ~= "table" and type(value) ~= "userdata" then return nil end
    local x = tonumber(read_member(value, "X"))
    local y = tonumber(read_member(value, "Y"))
    local z = tonumber(read_member(value, "Z"))
    if not (x and y and z) then return nil end
    return { X = x, Y = y, Z = z }
end

local function lod_call(obj, method, ...)
    if not is_valid(obj) then return false, "invalid object" end
    local args = { ... }
    local ok, value = pcall(function() return obj[method](obj, table.unpack(args)) end)
    if ok then return true, value end
    return false, tostring(value)
end

local function component_location(comp)
    local ok_loc, value = lod_call(comp, "K2_GetComponentLocation")
    if ok_loc then
        local loc = vector_to_loc(value)
        if loc then return loc end
    end
    local ok_owner, owner = lod_call(comp, "GetOwner")
    if ok_owner and is_valid(owner) then
        local ok_actor, actor_loc = lod_call(owner, "K2_GetActorLocation")
        if ok_actor then return vector_to_loc(actor_loc) end
    end
    return nil
end

local function lod_kind(comp)
    local cls = class_name(comp)
    if cls:find("LandscapeComponent", 1, true) then return "landscape" end
    if cls:find("SkeletalMeshComponent", 1, true) or cls:find("SkinnedMeshComponent", 1, true) then return "skeletal" end
    if cls:find("InstancedStaticMeshComponent", 1, true) or cls:find("HLODInstancedStaticMeshComponent", 1, true) then return "instanced" end
    if cls:find("StaticMeshComponent", 1, true) then return "static" end
    return "mesh"
end

local function parse_lod_args(args, default_radius, default_lod, default_limit)
    local radius_word, rest = parse_word_tail(args or "")
    local lod_word, rest2 = parse_word_tail(rest or "")
    local limit_word = parse_word_tail(rest2 or "")
    local radius = tonumber(radius_word or "") or default_radius
    local lod_index = tonumber(lod_word or "") or default_lod
    local limit = tonumber(limit_word or "") or default_limit
    if radius < 1000 then radius = 1000 end
    if radius > 2000000 then radius = 2000000 end
    if lod_index < 0 then lod_index = 0 end
    if lod_index > 7 then lod_index = 7 end
    lod_index = math.floor(lod_index)
    if limit < 1 then limit = 1 end
    if limit > 10000 then limit = 10000 end
    return radius, lod_index, math.floor(limit)
end

local function parse_lod_status_args(args, default_radius, default_limit)
    local radius_word, rest = parse_word_tail(args or "")
    local limit_word = parse_word_tail(rest or "")
    local radius = tonumber(radius_word or "") or default_radius
    local limit = tonumber(limit_word or "") or default_limit
    if radius < 1000 then radius = 1000 end
    if radius > 2000000 then radius = 2000000 end
    if limit < 1 then limit = 1 end
    if limit > 10000 then limit = 10000 end
    return radius, math.floor(limit)
end

local function collect_lod_components(camera_loc, radius)
    local items, seen = {}, {}
    local stats = { scanned = 0, no_loc = 0, in_radius = 0, counts = {} }
    for _, class in ipairs(LOD_COMPONENT_CLASSES) do
        for _, comp in ipairs(find_live_objects(class)) do
            local key = full_name(comp)
            if not seen[key] then
                seen[key] = true
                stats.scanned = stats.scanned + 1
                local loc = component_location(comp)
                if loc then
                    local dist = loc_distance(camera_loc, loc)
                    if dist <= radius then
                        local kind = lod_kind(comp)
                        stats.in_radius = stats.in_radius + 1
                        stats.counts[kind] = (stats.counts[kind] or 0) + 1
                        items[#items + 1] = { comp = comp, key = key, loc = loc, dist = dist, kind = kind }
                    end
                else
                    stats.no_loc = stats.no_loc + 1
                end
            end
        end
    end
    table.sort(items, function(a, b) return a.dist < b.dist end)
    return items, stats
end

local function table_count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

local function count_text(counts)
    local keys = { "static", "instanced", "skeletal", "landscape", "mesh" }
    local parts, used, extra = {}, {}, {}
    for _, key in ipairs(keys) do
        used[key] = true
        if counts[key] and counts[key] > 0 then parts[#parts + 1] = key .. "=" .. tostring(counts[key]) end
    end
    for key, value in pairs(counts or {}) do
        if not used[key] and tonumber(value) and tonumber(value) > 0 then extra[#extra + 1] = tostring(key) end
    end
    table.sort(extra)
    for _, key in ipairs(extra) do
        parts[#parts + 1] = key .. "=" .. tostring(counts[key])
    end
    if #parts == 0 then return "none" end
    return table.concat(parts, ",")
end

local function lod_sample_text(items, limit)
    local parts = {}
    for i = 1, math.min(#items, limit or 5) do
        local item = items[i]
        parts[#parts + 1] = string.format("%s:%.0f:%s", item.kind, item.dist, object_name(item.comp))
    end
    if #items > (limit or 5) then parts[#parts + 1] = "..." .. tostring(#items - (limit or 5)) .. " more" end
    if #parts == 0 then return "none" end
    return table.concat(parts, " | ")
end

local function snapshot_lod_component(comp)
    if not is_valid(comp) then return end
    local key = full_name(comp)
    if LOD_SNAPSHOT.components[key] then return end
    local fields = {}
    for _, field in ipairs(LOD_SNAPSHOT_FIELDS) do fields[field] = read_field(comp, field) end
    LOD_SNAPSHOT.components[key] = { object = comp, class = class_name(comp), fields = fields }
end

local function call_or_write(comp, method, field, value)
    local ok = false
    if method then ok = lod_call(comp, method, value) end
    local ok_w = false
    if field then ok_w = write_field(comp, field, value) end
    return ok or ok_w
end

local function apply_lod_component(comp, lod_index)
    if not is_valid(comp) then return false, "invalid" end
    snapshot_lod_component(comp)
    local kind = lod_kind(comp)
    local ops = {}
    local forced_model = lod_index + 1
    if kind == "landscape" then
        if call_or_write(comp, "SetForcedLOD", "ForcedLOD", lod_index) then ops[#ops + 1] = "landscape_lod" end
    else
        local forced = false
        if lod_call(comp, "SetForcedLodModel", forced_model) then forced = true end
        if lod_call(comp, "SetForcedLOD", forced_model) then forced = true end
        if write_field(comp, "ForcedLodModel", forced_model) then forced = true end
        if forced then ops[#ops + 1] = "forced_lod" end
    end
    if lod_call(comp, "SetCullDistance", 0.0) then ops[#ops + 1] = "cull0" end
    if write_field(comp, "bNeverDistanceCull", true) then ops[#ops + 1] = "never_cull" end
    if write_field(comp, "MinDrawDistance", 0.0) then ops[#ops + 1] = "min_draw0" end
    if write_field(comp, "LDMaxDrawDistance", 0.0) then ops[#ops + 1] = "ldmax0" end
    if write_field(comp, "CachedMaxDrawDistance", 0.0) then ops[#ops + 1] = "cachedmax0" end
    if lod_call(comp, "SetLODDistanceScale", 0.01) then ops[#ops + 1] = "inst_lodscale" end
    if write_field(comp, "InstanceLODDistanceScale", 0.01) then ops[#ops + 1] = "inst_lodscale_field" end
    if lod_call(comp, "SetCullDistances", 0, 0) then ops[#ops + 1] = "inst_cull0" end
    if lod_call(comp, "PrestreamMeshLODs", 60.0) then ops[#ops + 1] = "prestream_lods" end
    if lod_call(comp, "PrestreamTextures", 60.0, true, 3) then ops[#ops + 1] = "prestream_tex" end
    return #ops > 0, table.concat(ops, "+")
end

local function restore_lod_component(key, snap)
    local comp = snap and snap.object
    if not is_valid(comp) then return false, key .. ":invalid" end
    local fields = snap.fields or {}
    local errs = {}
    if fields.ForcedLOD ~= nil then lod_call(comp, "SetForcedLOD", fields.ForcedLOD) end
    if fields.ForcedLodModel ~= nil then
        lod_call(comp, "SetForcedLodModel", fields.ForcedLodModel)
        lod_call(comp, "SetForcedLOD", fields.ForcedLodModel)
    end
    if fields.InstanceLODDistanceScale ~= nil then lod_call(comp, "SetLODDistanceScale", fields.InstanceLODDistanceScale) end
    if fields.InstanceStartCullDistance ~= nil and fields.InstanceEndCullDistance ~= nil then
        lod_call(comp, "SetCullDistances", fields.InstanceStartCullDistance, fields.InstanceEndCullDistance)
    end
    if fields.LDMaxDrawDistance ~= nil then lod_call(comp, "SetCullDistance", fields.LDMaxDrawDistance) end
    for _, field in ipairs(LOD_SNAPSHOT_FIELDS) do
        if fields[field] ~= nil then
            local ok, err = write_field(comp, field, fields[field])
            if not ok then errs[#errs + 1] = field .. ":" .. tostring(err) end
        end
    end
    if #errs > 0 then return false, key .. ":" .. table.concat(errs, ",") end
    return true, key
end

function M.lod_status(args)
    local radius, limit = parse_lod_status_args(args, 150000.0, 200)
    local pc = active_camera_controller()
    local pose, err = read_camera_pose(pc, "lod_status")
    if not pose then return false, tostring(err) end
    local items, stats = collect_lod_components(pose.loc, radius)
    return true, string.format("radius=%.0f scanned=%d in_radius=%d no_loc=%d snapshot=%d counts={%s} samples={%s}",
        radius, stats.scanned, stats.in_radius, stats.no_loc, table_count(LOD_SNAPSHOT.components),
        count_text(stats.counts), lod_sample_text(items, math.min(limit, 8)))
end

function M.lod_force(args)
    return false, "disabled: forcing LOD on live render components crashed in Shipping. Use cvars.filming on plus camera.streaming.scale instead while we investigate safer global/config controls."
end

function M.lod_force_unsafe(args)
    local radius, lod_index, limit = parse_lod_args(args, 150000.0, 0, 800)
    local pc = active_camera_controller()
    local pose, err = read_camera_pose(pc, "lod_force")
    if not pose then return false, tostring(err) end
    local items, stats = collect_lod_components(pose.loc, radius)
    local applied, failed, op_counts = 0, 0, {}
    local max_apply = math.min(#items, limit)
    for i = 1, max_apply do
        local ok, detail = apply_lod_component(items[i].comp, lod_index)
        if ok then
            applied = applied + 1
            for op in tostring(detail):gmatch("[^+]+") do op_counts[op] = (op_counts[op] or 0) + 1 end
        else
            failed = failed + 1
        end
    end
    return true, string.format("radius=%.0f lod=%d forcedModel=%d applied=%d/%d failed=%d limited=%s scanned=%d in_radius=%d counts={%s} ops={%s} samples={%s}",
        radius, lod_index, lod_index + 1, applied, stats.in_radius, failed, tostring(stats.in_radius > limit),
        stats.scanned, stats.in_radius, count_text(stats.counts), count_text(op_counts), lod_sample_text(items, 6))
end

function M.lod_reset()
    local restored, failed, errs = 0, 0, {}
    for key, snap in pairs(LOD_SNAPSHOT.components) do
        local ok, detail = restore_lod_component(key, snap)
        if ok then restored = restored + 1 else failed = failed + 1; errs[#errs + 1] = tostring(detail) end
    end
    LOD_SNAPSHOT = { components = {} }
    return true, string.format("restored=%d failed=%d errs=%s", restored, failed, #errs > 0 and table.concat(errs, " | ") or "none")
end

local function catmull_num(p0, p1, p2, p3, t)
    local t2, t3 = t * t, t * t * t
    return 0.5 * ((2 * p1) + (-p0 + p2) * t + (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 + (-p0 + 3 * p1 - 3 * p2 + p3) * t3)
end

local function unwrap_angle_near(value, reference)
    return (reference or 0) + normalize_angle_delta((value or 0) - (reference or 0))
end

local function catmull_angle(p0, p1, p2, p3, t)
    local a1 = p1 or 0
    local a0 = unwrap_angle_near(p0 or a1, a1)
    local a2 = unwrap_angle_near(p2 or a1, a1)
    local a3 = unwrap_angle_near(p3 or a2, a2)
    return catmull_num(a0, a1, a2, a3, t)
end

local function catmull_loc(p0, p1, p2, p3, t)
    return {
        X = catmull_num(p0.X or 0, p1.X or 0, p2.X or 0, p3.X or 0, t),
        Y = catmull_num(p0.Y or 0, p1.Y or 0, p2.Y or 0, p3.Y or 0, t),
        Z = catmull_num(p0.Z or 0, p1.Z or 0, p2.Z or 0, p3.Z or 0, t),
    }
end

local function playback_loc(a, b, t, opts)
    opts = opts or {}
    local path = tostring(opts.path or DEFAULT_CAMERA_PATH):lower():gsub("%s+", "_"):gsub("-", "_")
    if path == "spline" then
        local prev = (opts.prev and opts.prev.loc) or a.loc
        local nextp = (opts.next and opts.next.loc) or b.loc
        return catmull_loc(prev, a.loc, b.loc, nextp, t)
    end
    local loc = lerp_loc(a.loc, b.loc, t)
    if path == "arc" or path == "high_arc" then
        local dist = loc_distance(a.loc, b.loc)
        local scale = path == "high_arc" and 0.30 or 0.16
        local lift = dist * scale
        if lift < 50 then lift = 50 end
        if lift > 2500 then lift = 2500 end
        loc.Z = loc.Z + math.sin(math.pi * t) * lift
    end
    return loc
end

local function playback_fov(a, b, t, opts)
    opts = opts or {}
    local fov_a = tonumber(opts.fov_a) or tonumber(a.fov) or 80
    local fov_b = tonumber(opts.fov_b) or tonumber(b.fov) or fov_a
    local lens = tostring(opts.lens or "blend"):lower():gsub("%s+", "_"):gsub("-", "_")
    if lens == "hold_from" then return fov_a end
    if lens == "hold_to" then return fov_b end
    if lens == "snap_end" then return t >= 1 and fov_b or fov_a end
    return fov_a + (fov_b - fov_a) * t
end

local function playback_rot(a, b, t, opts)
    opts = opts or {}
    local mode = tostring(opts.rot or opts.rotation or "blend"):lower():gsub("%s+", "_"):gsub("-", "_")
    if mode == "hold_from" then return a.rot end
    if mode == "hold_to" then return b.rot end
    if mode == "snap_end" then return t >= 1 and b.rot or a.rot end
    if mode == "smooth" or mode == "spline" or mode == "track" then
        local prev = opts.prev or a
        local nextp = opts.next or b
        return {
            Pitch = catmull_angle(prev.rot.Pitch, a.rot.Pitch, b.rot.Pitch, nextp.rot.Pitch, t),
            Yaw = catmull_angle(prev.rot.Yaw, a.rot.Yaw, b.rot.Yaw, nextp.rot.Yaw, t),
            Roll = catmull_angle(prev.rot.Roll, a.rot.Roll, b.rot.Roll, nextp.rot.Roll, t),
        }
    end
    return {
        Pitch = lerp_angle(a.rot.Pitch, b.rot.Pitch, t),
        Yaw = lerp_angle(a.rot.Yaw, b.rot.Yaw, t),
        Roll = lerp_angle(a.rot.Roll, b.rot.Roll, t),
    }
end

local function lerp_pose(a, b, t, opts)
    opts = opts or {}
    t = clamp01(t)
    return {
        source = "playback",
        loc = playback_loc(a, b, t, opts),
        rot = playback_rot(a, b, t, opts),
        fov = playback_fov(a, b, t, opts),
    }
end

local function current_debug_camera_pose()
    local active, debug_pc = debug_active()
    if not active or not is_valid(debug_pc) then return nil, nil, "DebugCamera is not active" end
    local pose, err = read_camera_pose(debug_pc, "DebugCamera")
    if not pose then return nil, nil, err end
    return pose, debug_pc
end

local function set_live_camera_roll(roll)
    roll = tonumber(roll)
    if not roll then return false, "usage: camera.rig.roll.set <degrees>" end
    roll = normalize_angle_delta(roll)
    local pose, debug_pc, err = current_debug_camera_pose()
    if not pose then return false, err end
    local repaired, repair_detail = repair_widened_roll_bounds(debug_pc)
    if not repaired then return false, tostring(repair_detail) end
    pose.rot.Roll = roll
    local ok, detail = apply_pose(debug_pc, apply_lookat_if_needed(pose))
    if not ok then return false, detail end
    ROLL_STATE.key = object_key(debug_pc)
    ROLL_STATE.requested = roll
    local after = read_camera_pose(debug_pc, "DebugCamera")
    local actual = after and after.rot and tonumber(after.rot.Roll) or nil
    if actual == nil then
        return true, string.format("requested=%.1f readback=? via %s; %s", roll, tostring(detail), tostring(repair_detail))
    end
    return true, string.format("requested=%.1f readback=%.1f via %s; %s", roll, actual, tostring(detail), tostring(repair_detail))
end

local function current_roll_step()
    local step = tonumber(ROLL_STATE.step) or 5.0
    if step <= 0 then return 5.0 end
    return step
end

local function cancel_playback_loop()
    -- Playback stop is cooperative. The engine-tick driver is a single
    -- permanent loop and is intentionally never cancelled in Shipping.
    PLAY.id = (tonumber(PLAY.id) or 0) + 1
    PLAY.step_fn = nil
    PLAY.driver = nil
end

local function start_playback_loop(id, step_fn)
    local function run_step()
        if not PLAY.active or PLAY.id ~= id then return true end
        local ok, done = pcall(step_fn)
        if not ok then
            PLAY.active = false
            print("[RSDWTools.camera] playback step failed: " .. tostring(done))
            return true
        end
        return done and true or false
    end

    if EngineTickAvailable == true and type(LoopInGameThreadAfterFrames) == "function" then
        PLAY.step_fn = run_step
        PLAY.driver = "engine_tick"
        if not PLAY.engine_tick_started then
            local handle = nil
            local ok, err = pcall(function()
                handle = LoopInGameThreadAfterFrames(1, function()
                    local tick = PLAY.step_fn
                    if not tick then return end
                    if tick() then
                        PLAY.step_fn = nil
                        if PLAY.driver == "engine_tick" then PLAY.driver = nil end
                    end
                end)
            end)
            if ok and handle then
                PLAY.handle = handle
                PLAY.engine_tick_started = true
                return true, "engine_tick"
            end
            PLAY.step_fn = nil
            PLAY.driver = nil
            print("[RSDWTools.camera] playback engine tick unavailable: " .. tostring(err))
        else
            return true, "engine_tick"
        end
    end

    if not LoopAsync then return false, "LoopAsync unavailable" end
    LoopAsync(16, function()
        local done = run_step()
        if done and PLAY.driver == "loop_async" then PLAY.driver = nil end
        return done
    end)
    PLAY.handle = nil
    PLAY.driver = "loop_async"
    return true, "loop_async"
end

local function start_playback(from_pose, to_pose, seconds, label_text, opts)
    seconds = tonumber(seconds) or 3.0
    if seconds < 0.05 then seconds = 0.05 end
    opts = opts or {}
    local debug_pc, err = ensure_debug_camera(nil)
    if not debug_pc then return false, err end

    cancel_playback_loop()
    PLAY.id = PLAY.id + 1
    PLAY.active = true
    PLAY.label = label_text or "playback"
    PLAY.started = os.clock()
    PLAY.duration = seconds
    local id = PLAY.id
    local started = PLAY.started

    local ok_loop, driver = start_playback_loop(id, function()
        local active, live_debug = debug_active()
        if not active or not is_valid(live_debug) then
            PLAY.active = false
            return true
        end
        local elapsed = os.clock() - started
        local t = elapsed / seconds
        if t < 0 then t = 0 end
        if t > 1 then t = 1 end
        local eased = ease_value(t, opts.curve)
        local pose = apply_lookat_if_needed(lerp_pose(from_pose, to_pose, eased, opts))
        apply_pose(live_debug, pose)
        if t >= 1 then
            PLAY.active = false
            return true
        end
        return false
    end)
    if not ok_loop then
        PLAY.active = false
        return false, driver
    end
    return true, string.format("%s %.2fs curve=%s path=%s lens=%s rot=%s driver=%s", PLAY.label, seconds, tostring(opts.curve or "linear"), tostring(opts.path or DEFAULT_CAMERA_PATH), tostring(opts.lens or "blend"), tostring(opts.rot or "blend"), tostring(driver))
end

local function start_chain_playback(segments)
    if type(segments) ~= "table" or #segments == 0 then return false, "no segments" end
    local debug_pc, err = ensure_debug_camera(nil)
    if not debug_pc then return false, err end

    local total = 0
    for _, seg in ipairs(segments) do
        seg.seconds = tonumber(seg.seconds) or 3.0
        if seg.seconds < 0.05 then seg.seconds = 0.05 end
        seg.start_time = total
        total = total + seg.seconds
        seg.end_time = total
    end
    for i, seg in ipairs(segments) do
        seg.opts = seg.opts or {}
        if not seg.opts.prev then seg.opts.prev = (i > 1 and segments[i - 1].a) or seg.a end
        if not seg.opts.next then seg.opts.next = (i < #segments and segments[i + 1].b) or seg.b end
    end

    cancel_playback_loop()
    PLAY.id = PLAY.id + 1
    PLAY.active = true
    PLAY.label = "sequence"
    PLAY.started = os.clock()
    PLAY.duration = total
    local id = PLAY.id
    local started = PLAY.started

    local ok_loop, driver = start_playback_loop(id, function()
        local active, live_debug = debug_active()
        if not active or not is_valid(live_debug) then
            PLAY.active = false
            return true
        end
        local elapsed = os.clock() - started
        if elapsed < 0 then elapsed = 0 end
        if elapsed > total then elapsed = total end

        local seg = segments[#segments]
        for _, candidate in ipairs(segments) do
            if elapsed <= candidate.end_time then
                seg = candidate
                break
            end
        end

        local local_t = 1
        if seg.seconds > 0 then local_t = (elapsed - seg.start_time) / seg.seconds end
        local_t = clamp01(local_t)
        local eased = ease_value(local_t, seg.opts.curve)
        local pose = apply_lookat_if_needed(lerp_pose(seg.a, seg.b, eased, seg.opts))
        apply_pose(live_debug, pose)

        if elapsed >= total then
            PLAY.active = false
            return true
        end
        return false
    end)
    if not ok_loop then
        PLAY.active = false
        return false, driver
    end
    return true, string.format("sequence segments=%d %.2fs driver=%s", #segments, total, tostring(driver))
end

local function pose_summary(name, pose)
    return string.format("%s=(%.1f,%.1f,%.1f rot %.1f,%.1f,%.1f fov %.1f)",
        name,
        pose.loc.X, pose.loc.Y, pose.loc.Z,
        pose.rot.Pitch, pose.rot.Yaw, pose.rot.Roll,
        pose.fov or 80.0)
end

function M.rig_start(args)
    local speed_arg = trim(args)
    local debug_pc, err = ensure_debug_camera(speed_arg ~= "" and speed_arg or nil)
    if not debug_pc then return false, err end
    return true, "active " .. label(rig_target(debug_pc))
end

function M.rig_stop()
    PLAY.active = false
    cancel_playback_loop()
    return M.disable()
end

function M.rig_status()
    local active, debug_pc = debug_active()
    local target = active and rig_target(debug_pc) or nil
    return true, string.format("active=%s playback=%s driver=%s poses=%d lookat=%s target=%s",
        tostring(active and true or false),
        PLAY.active and tostring(PLAY.label or "playing") or "false",
        PLAY.active and tostring(PLAY.driver or "unknown") or "false",
        pose_count(),
        LOOKAT_ACTOR_NAME or "off",
        label(target))
end

function M.rig_capture(args)
    local name = trim(args)
    if name == "" then return false, "usage: camera.rig.capture <name>" end
    local pc, is_debug = active_camera_controller()
    local pose, err = read_camera_pose(pc, is_debug and "DebugCamera" or "PlayerCamera")
    if not pose then return false, err end
    local ok_w, detail_w = remember_pose(name, pose)
    local suffix = ok_w and (" wrote " .. tostring(detail_w)) or (" write_failed " .. tostring(detail_w))
    return true, pose_summary(name, pose) .. suffix
end

function M.rig_pose_set(args)
    local name, tail = parse_word_tail(args)
    if not name then
        return false, "usage: camera.rig.pose.set <name> <x> <y> <z> <pitch> <yaw> <roll> <fov>"
    end
    local vals = {}
    for token in tostring(tail or ""):gmatch("%S+") do vals[#vals + 1] = tonumber(token) end
    if #vals < 7 then
        return false, "usage: camera.rig.pose.set <name> <x> <y> <z> <pitch> <yaw> <roll> <fov>"
    end
    local pose = {
        source = "Project",
        loc = { X = vals[1], Y = vals[2], Z = vals[3] },
        rot = { Pitch = vals[4], Yaw = vals[5], Roll = vals[6] },
        fov = vals[7],
    }
    local ok_w, detail_w = remember_pose(name, pose)
    local suffix = ok_w and (" wrote " .. tostring(detail_w)) or (" write_failed " .. tostring(detail_w))
    return true, pose_summary(name, pose) .. suffix
end

function M.rig_delete(args)
    local name = trim(args)
    if name == "" then return false, "usage: camera.rig.delete <name>" end
    if not POSES[name] then return false, "unknown pose: " .. name end
    POSES[name] = nil
    local next_order = {}
    for _, existing in ipairs(POSE_ORDER) do
        if existing ~= name then next_order[#next_order + 1] = existing end
    end
    POSE_ORDER = next_order
    write_poses_json()
    return true, name
end

function M.rig_clear()
    POSES = {}
    POSE_ORDER = {}
    PLAY.active = false
    cancel_playback_loop()
    write_poses_json()
    return true, "cleared"
end

function M.rig_list()
    if pose_count() == 0 then return true, "0 poses" end
    local parts = {}
    for _, name in ipairs(POSE_ORDER) do
        if POSES[name] then parts[#parts + 1] = pose_summary(name, POSES[name]) end
    end
    return true, table.concat(parts, " | ")
end

function M.rig_goto(args)
    local name, tail = parse_word_tail(args)
    if not name then return false, "usage: camera.rig.goto <name> [seconds]" end
    local pose = POSES[name]
    if not pose then return false, "unknown pose: " .. tostring(name) end
    local debug_pc, err = ensure_debug_camera(nil)
    if not debug_pc then return false, err end
    local seconds = tonumber(tail)
    if seconds and seconds > 0 then
        local current, perr = read_camera_pose(debug_pc, "DebugCamera")
        if not current then return false, perr end
        return start_playback(current, pose, seconds, "goto " .. name)
    end
    local ok, detail = apply_pose(debug_pc, apply_lookat_if_needed(pose))
    if not ok then return false, detail end
    return true, "goto " .. pose_summary(name, pose) .. " via " .. tostring(detail)
end

function M.rig_play(args)
    local a_name, tail = parse_word_tail(args)
    local b_name, tail2 = parse_word_tail(tail)
    if not a_name or not b_name then return false, "usage: camera.rig.play <from> <to> [seconds] [curve] [path] [fovFrom] [fovTo] [lens] [prev] [next] [rot]" end
    local a, b = POSES[a_name], POSES[b_name]
    if not a then return false, "unknown pose: " .. tostring(a_name) end
    if not b then return false, "unknown pose: " .. tostring(b_name) end
    local seconds_s, tail3 = parse_word_tail(tail2)
    local curve, tail4 = parse_word_tail(tail3)
    local path, tail5 = parse_word_tail(tail4)
    local fov_a, tail6 = parse_word_tail(tail5)
    local fov_b, tail7 = parse_word_tail(tail6)
    local lens, tail8 = parse_word_tail(tail7)
    local prev_name, tail9 = parse_word_tail(tail8)
    local next_name, tail10 = parse_word_tail(tail9)
    local rot_mode = parse_word_tail(tail10)
    local opts = {
        curve = curve or "linear",
        path = path or DEFAULT_CAMERA_PATH,
        fov_a = tonumber(fov_a),
        fov_b = tonumber(fov_b),
        lens = lens or "blend",
        prev = prev_name and POSES[prev_name] or nil,
        next = next_name and POSES[next_name] or nil,
        rot = rot_mode or "blend",
    }
    return start_playback(a, b, tonumber(seconds_s) or 3.0, a_name .. "->" .. b_name, opts)
end

function M.rig_goto_file(args)
    local filename_raw, tail = parse_word_tail(args)
    local pose_name, seconds_tail = parse_word_tail(tail)
    if not filename_raw or not pose_name then return false, "usage: camera.rig.goto.file <filename> <name> [seconds]" end
    local filename, ferr = safe_ipc_filename(filename_raw, "camera_sequence.json")
    if not filename then return false, ferr end
    local doc, derr = read_ipc_json(filename)
    if not doc then return false, derr end
    local ok_p, detail_p = load_poses_from_doc(doc, true)
    if not ok_p then return false, detail_p end
    local command = pose_name
    if seconds_tail and seconds_tail ~= "" then command = command .. " " .. seconds_tail end
    local ok_g, detail_g = M.rig_goto(command)
    if not ok_g then return false, detail_g end
    return true, tostring(detail_g) .. " " .. tostring(detail_p)
end

function M.rig_poses_file(args)
    local filename, ferr = safe_ipc_filename(args, "camera_sequence.json")
    if not filename then return false, ferr end
    local doc, derr = read_ipc_json(filename)
    if not doc then return false, derr end
    return load_poses_from_doc(doc, true)
end

function M.rig_play_chain(args)
    local raw = trim(args)
    if raw == "" then return false, "usage: camera.rig.play.chain <from,to,seconds,curve,path,fovFrom,fovTo,lens,rot;...>" end
    local segments = {}
    for spec in raw:gmatch("[^;]+") do
        local parts = {}
        for part in tostring(spec):gmatch("[^,]+") do parts[#parts + 1] = trim(part) end
        local from_name, to_name = parts[1], parts[2]
        if not from_name or not to_name or from_name == "" or to_name == "" then
            return false, "bad segment spec: " .. tostring(spec)
        end
        local a, b = POSES[from_name], POSES[to_name]
        if not a then return false, "unknown pose: " .. tostring(from_name) end
        if not b then return false, "unknown pose: " .. tostring(to_name) end
        segments[#segments + 1] = {
            from_name = from_name,
            to_name = to_name,
            a = a,
            b = b,
            seconds = tonumber(parts[3]) or 3.0,
            opts = {
                curve = parts[4] ~= "" and parts[4] or "linear",
                path = parts[5] ~= "" and parts[5] or "direct",
                fov_a = tonumber(parts[6]),
                fov_b = tonumber(parts[7]),
                lens = parts[8] ~= "" and parts[8] or "blend",
                rot = parts[9] ~= "" and parts[9] or "blend",
            },
        }
    end
    return start_chain_playback(segments)
end

function M.rig_play_file(args)
    local filename, ferr = safe_ipc_filename(args, "camera_sequence.json")
    if not filename then return false, ferr end
    local doc, derr = read_ipc_json(filename)
    if not doc then return false, derr end
    local ok_p, detail_p = load_poses_from_doc(doc, false)
    if not ok_p then return false, detail_p end
    local raw_segments = doc.segments
    if type(raw_segments) ~= "table" then return false, "sequence file missing segments" end

    local segments = {}
    for i, item in ipairs(raw_segments) do
        if type(item) ~= "table" then return false, "bad segment at " .. tostring(i) end
        local from_name = tostring(item.from or "")
        local to_name = tostring(item.to or "")
        if from_name == "" or to_name == "" then return false, "bad segment names at " .. tostring(i) end
        local a, b = POSES[from_name], POSES[to_name]
        if not a then return false, "unknown pose: " .. tostring(from_name) end
        if not b then return false, "unknown pose: " .. tostring(to_name) end
        local prev_name = trim(item.prev or item.previous or "")
        local next_name = trim(item.next or "")
        segments[#segments + 1] = {
            from_name = from_name,
            to_name = to_name,
            a = a,
            b = b,
            seconds = tonumber(item.seconds) or 3.0,
            opts = {
                curve = tostring(item.curve or "linear"),
                path = tostring(item.path or DEFAULT_CAMERA_PATH),
                fov_a = tonumber(item.fovFrom or item.fovA or item.fov_a),
                fov_b = tonumber(item.fovTo or item.fovB or item.fov_b),
                lens = tostring(item.lens or "blend"),
                rot = tostring(item.rot or item.rotation or item.rotationMode or "blend"),
                prev = prev_name ~= "" and POSES[prev_name] or nil,
                next = next_name ~= "" and POSES[next_name] or nil,
            },
        }
    end
    local ok_chain, detail_chain = start_chain_playback(segments)
    if not ok_chain then return false, detail_chain end
    return true, tostring(detail_chain) .. " " .. tostring(detail_p)
end

function M.rig_play_stop()
    if not PLAY.active then
        cancel_playback_loop()
        return true, "not playing"
    end
    PLAY.active = false
    cancel_playback_loop()
    return true, "stopped"
end

function M.rig_fov(args)
    local n = tonumber(trim(args))
    if not n then return false, "usage: camera.rig.fov <degrees>" end
    if n < 5 then n = 5 end
    if n > 170 then n = 170 end
    local debug_pc, err = ensure_debug_camera(nil)
    if not debug_pc then return false, err end
    set_fov(debug_pc, n)
    return true, string.format("%.1f", n)
end

function M.is_debug_camera_active()
    local active = debug_active()
    return active and true or false
end

function M.debug_camera_viewpoint()
    local pose, _debug_pc, err = current_debug_camera_pose()
    if not pose then return nil, nil, tostring(err or "DebugCamera is not active") end
    return {
        X = tonumber(pose.loc and pose.loc.X) or 0,
        Y = tonumber(pose.loc and pose.loc.Y) or 0,
        Z = tonumber(pose.loc and pose.loc.Z) or 0,
    }, {
        Pitch = tonumber(pose.rot and pose.rot.Pitch) or 0,
        Yaw = tonumber(pose.rot and pose.rot.Yaw) or 0,
        Roll = tonumber(pose.rot and pose.rot.Roll) or 0,
    }, nil
end

function M.active_controller()
    local pc, is_debug = active_camera_controller()
    return pc, is_debug
end

function M.controllers()
    return resolve_controllers()
end

function M.rig_roll_step_value()
    return current_roll_step()
end

function M.rig_roll_step(args)
    local step = tonumber(trim(args))
    if not step then return false, "usage: camera.rig.roll.step <degrees>" end
    step = math.abs(step)
    if step < 0.1 then step = 0.1 end
    if step > 180.0 then step = 180.0 end
    ROLL_STATE.step = step
    return true, string.format("%.3g", step)
end

function M.rig_roll_add(args)
    local delta = tonumber(trim(args))
    if not delta then return false, "usage: camera.rig.roll.add <degrees>" end
    local pose, debug_pc, err = current_debug_camera_pose()
    if not pose then return false, err end
    local base = tonumber(pose.rot.Roll) or 0
    if ROLL_STATE.key ~= nil and ROLL_STATE.key == object_key(debug_pc) and ROLL_STATE.requested ~= nil then
        base = ROLL_STATE.requested
    end
    return set_live_camera_roll(base + delta)
end

function M.rig_roll_set(args)
    return set_live_camera_roll(tonumber(trim(args)))
end

function M.rig_roll_reset()
    return set_live_camera_roll(0)
end

function M.rig_roll_status()
    local active, debug_pc = debug_active()
    local step = current_roll_step()
    if not active or not is_valid(debug_pc) then return true, string.format("active=false step=%.3g", step) end
    local pose = read_camera_pose(debug_pc, "DebugCamera")
    local pcm = camera_manager_for(debug_pc)
    local min_v = is_valid(pcm) and tonumber(read_field(pcm, "ViewRollMin")) or nil
    local max_v = is_valid(pcm) and tonumber(read_field(pcm, "ViewRollMax")) or nil
    local roll = pose and pose.rot and tonumber(pose.rot.Roll) or 0
    local requested = nil
    if ROLL_STATE.key ~= nil and ROLL_STATE.key == object_key(debug_pc) then requested = ROLL_STATE.requested end
    if requested ~= nil then
        return true, string.format("active=true roll=%.1f requested=%.1f step=%.3g bounds=[%s,%s]", roll, requested, step, tostring(min_v or "?"), tostring(max_v or "?"))
    end
    return true, string.format("active=true roll=%.1f step=%.3g bounds=[%s,%s]", roll, step, tostring(min_v or "?"), tostring(max_v or "?"))
end

function M.fps(args)
    local raw = trim(args):lower()
    local n = nil
    if raw == "" then return false, "usage: camera.fps <number|unlock>" end
    if raw == "unlock" or raw == "unlimited" or raw == "0" then
        n = 0
    else
        n = tonumber(raw)
        if not n then return false, "usage: camera.fps <number|unlock>" end
        if n < 15 then n = 15 end
        if n > 1000 then n = 1000 end
    end
    local pc, _, orig = resolve_controllers()
    local cmd = "t.MaxFPS " .. tostring(n)
    local ok, via = execute_console(orig or pc, cmd)
    if not ok then return false, tostring(via) end
    return true, cmd .. " via " .. tostring(via)
end

function M.vsync(args)
    local raw = trim(args):lower()
    local value = (raw == "on" or raw == "1" or raw == "true") and "1" or "0"
    local pc, _, orig = resolve_controllers()
    local cmd = "r.VSync " .. value
    local ok, via = execute_console(orig or pc, cmd)
    if not ok then return false, tostring(via) end
    return true, cmd .. " via " .. tostring(via)
end

function M.rig_lookat(args)
    local name = trim(args)
    if name == "" then
        return true, LOOKAT_ACTOR_NAME or "off"
    end
    if name == "off" or name == "none" or name == "clear" then
        LOOKAT_ACTOR_NAME = nil
        return true, "off"
    end
    local actor = feature_actor.resolve_actor_by_name(name)
    if not feature_actor.is_valid_object(actor) then return false, "no matching actor" end
    LOOKAT_ACTOR_NAME = name
    local active, debug_pc = debug_active()
    if active and is_valid(debug_pc) then
        local pose = read_camera_pose(debug_pc, "DebugCamera")
        if pose then apply_pose(debug_pc, apply_lookat_if_needed(pose)) end
    end
    return true, name
end

return M
