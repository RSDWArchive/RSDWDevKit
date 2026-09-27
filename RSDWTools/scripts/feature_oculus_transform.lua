-- Oculus transform capture/apply support.
--
-- The repair-mode "Inspect Actor" hotkey already routes through camera.lookat.
-- This module lets that same click publish a lightweight IPC snapshot that the
-- WPF Oculus > Transforms page can read, cache, edit, and apply back to the
-- live actor.

local M = {}

local feature_actor = require("feature_actor")
local feature_field = require("feature_field")
local mod_paths = require("mod_paths")

local CAPTURE_CACHE = {}
local capture_counter = 0
local capture_enabled = false

local function is_valid(actor)
    return feature_actor.is_valid_object(actor)
end

local function num(v, fallback)
    local n = tonumber(v)
    if n == nil or n ~= n or n == math.huge or n == -math.huge then
        return fallback or 0
    end
    return n
end

local function encode_number(n)
    return string.format("%.9g", num(n, 0))
end

local function encode_string(s)
    local escaped = tostring(s or "")
        :gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("\n", "\\n")
        :gsub("\r", "\\r")
    return '"' .. escaped .. '"'
end

local function clean_label(name)
    local text = tostring(name or "")
    text = text:gsub("_UAID_[%x_]+$", "")
    return text ~= "" and text or "<unnamed>"
end

local function vec_json(v)
    v = v or {}
    return string.format('{"x":%s,"y":%s,"z":%s}',
        encode_number(v.X or v.x),
        encode_number(v.Y or v.y),
        encode_number(v.Z or v.z))
end

local function rot_json(r)
    r = r or {}
    return string.format('{"pitch":%s,"yaw":%s,"roll":%s}',
        encode_number(r.Pitch or r.pitch),
        encode_number(r.Yaw or r.yaw),
        encode_number(r.Roll or r.roll))
end

local function write_latest(payload)
    local dir = mod_paths.ipc_dir()
    if not dir then return false, "ipc dir unavailable" end
    local path = dir .. "\\oculus_transform_latest.json"
    return mod_paths.write_atomic(path, payload)
end

local function snapshot_body(token, actor, source)
    local loc = feature_actor.actor_location(actor) or { X = 0, Y = 0, Z = 0 }
    local rot = feature_actor.actor_rotation(actor) or { Pitch = 0, Yaw = 0, Roll = 0 }
    local scale = feature_actor.get_actor_scale3d(actor) or { X = 1, Y = 1, Z = 1 }
    local name = feature_actor.short_name_of(actor) or ""
    local class = feature_field.class_name_of(actor) or "<unknown>"

    return "{"
        .. '"ok":true'
        .. ',"token":' .. encode_string(token)
        .. ',"name":' .. encode_string(name)
        .. ',"label":' .. encode_string(clean_label(name))
        .. ',"class":' .. encode_string(class)
        .. ',"source":' .. encode_string(source or "lookat")
        .. ',"captured_unix":' .. tostring(os.time())
        .. ',"loc":' .. vec_json(loc)
        .. ',"rot":' .. rot_json(rot)
        .. ',"scale":' .. vec_json(scale)
        .. "}"
end

local function write_actor_snapshot(actor, source)
    if not is_valid(actor) then
        return false, "invalid actor"
    end
    capture_counter = capture_counter + 1
    local token = tostring(os.time()) .. "_" .. tostring(capture_counter)
    CAPTURE_CACHE[token] = actor
    local body = snapshot_body(token, actor, source or "lookat")
    local ok, path_or_err = write_latest(body)
    if not ok then
        return false, path_or_err
    end
    return true, token
end

function M.capture_actor(actor, source)
    if capture_enabled ~= true then
        return true, "disabled"
    end
    return write_actor_snapshot(actor, source)
end

function M.capture_actor_forced(actor, source)
    return write_actor_snapshot(actor, source)
end

function M.capture(args)
    local mode = tostring(args or ""):match("^%s*(.-)%s*$"):lower()
    if mode == "" or mode == "status" then
        return true, "capture=" .. (capture_enabled and "on" or "off")
    end
    if mode == "on" or mode == "true" or mode == "1" or mode == "enabled" or mode == "enable" then
        capture_enabled = true
    elseif mode == "off" or mode == "false" or mode == "0" or mode == "disabled" or mode == "disable" then
        capture_enabled = false
    elseif mode == "toggle" then
        capture_enabled = not capture_enabled
    else
        return false, "usage: camera.oculus.transform.capture <on|off|toggle|status>"
    end
    return true, "capture=" .. (capture_enabled and "on" or "off")
end

function M.capture_enabled()
    return capture_enabled == true
end

local function parse_apply_args(args)
    local parts = {}
    for part in tostring(args or ""):gmatch("%S+") do
        parts[#parts + 1] = part
    end
    if #parts < 11 then
        return nil, "usage: camera.oculus.transform.apply <token> <actor_name> <x> <y> <z> <pitch> <yaw> <roll> <sx> <sy> <sz>"
    end

    local values = {}
    for i = 3, 11 do
        local n = tonumber(parts[i])
        if not n then
            return nil, "numeric transform value expected at argument " .. tostring(i)
        end
        values[#values + 1] = n
    end

    return {
        token = parts[1],
        name = parts[2],
        loc = { X = values[1], Y = values[2], Z = values[3] },
        rot = { Pitch = values[4], Yaw = values[5], Roll = values[6] },
        scale = { X = values[7], Y = values[8], Z = values[9] },
    }, nil
end

local function parse_reload_args(args)
    local parts = {}
    for part in tostring(args or ""):gmatch("%S+") do
        parts[#parts + 1] = part
    end
    if #parts < 2 then
        return nil, nil, "usage: camera.oculus.transform.reload <token> <actor_name>"
    end
    return parts[1], parts[2], nil
end

local function resolve_cached_or_named(token, name)
    local actor = CAPTURE_CACHE[token]
    if is_valid(actor) then return actor end
    if token and CAPTURE_CACHE[token] ~= nil then
        CAPTURE_CACHE[token] = nil
    end
    if name and name ~= "" then
        return feature_actor.resolve_actor_by_name(name)
    end
    return nil
end

function M.reload(args)
    local token, name, err = parse_reload_args(args)
    if err then return false, err end

    local actor = resolve_cached_or_named(token, name)
    if not is_valid(actor) then
        return false, "actor no longer available: " .. tostring(name or token)
    end

    local ok, detail = M.capture_actor_forced(actor, "reload")
    if not ok then return false, detail end
    return true, string.format("reloaded %s token=%s", tostring(name), tostring(detail))
end

function M.apply(args)
    local parsed, err = parse_apply_args(args)
    if not parsed then return false, err end

    local actor = resolve_cached_or_named(parsed.token, parsed.name)
    if not is_valid(actor) then
        return false, "actor no longer available: " .. tostring(parsed.name or parsed.token)
    end

    feature_actor.force_actor_movable(actor)
    local ok_loc, loc_err = feature_actor.move_actor(actor, parsed.loc)
    local ok_rot = feature_actor.set_actor_rotation(actor, parsed.rot)
    local ok_scale = feature_actor.set_actor_scale3d(actor, parsed.scale)

    if not (ok_loc and ok_rot and ok_scale) then
        return false, string.format("partial transform apply failed: loc=%s rot=%s scale=%s%s",
            tostring(ok_loc), tostring(ok_rot), tostring(ok_scale),
            loc_err and (" loc_err=" .. tostring(loc_err)) or "")
    end

    M.capture_actor_forced(actor, "apply")
    return true, string.format("applied %s loc=(%.2f,%.2f,%.2f) rot=(%.2f,%.2f,%.2f) scale=(%.3f,%.3f,%.3f)",
        tostring(parsed.name),
        parsed.loc.X, parsed.loc.Y, parsed.loc.Z,
        parsed.rot.Pitch, parsed.rot.Yaw, parsed.rot.Roll,
        parsed.scale.X, parsed.scale.Y, parsed.scale.Z)
end

return M
