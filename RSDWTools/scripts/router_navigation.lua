local support = require("router_support")
local lazy_feature = support.lazy_feature

local feature_teleport = lazy_feature("feature_teleport")
local feature_scan = lazy_feature("feature_scan")

local M = {}

local function parse_tele(line)
    local x, y, z = line:match("^tele%s+([%-%d%.]+)%s+([%-%d%.]+)%s+([%-%d%.]+)%s*$")
    if not x then
        return nil, "usage: tele <x> <y> <z>"
    end
    local xn, yn, zn = tonumber(x), tonumber(y), tonumber(z)
    if not xn or not yn or not zn then
        return nil, "tele args must be numbers"
    end
    return xn, yn, zn
end

local function parse_scan(line)
    local body = line:match("^scan%s+(.+)$")
    if not body then
        return nil, nil, "usage: scan <name_part> [radius|all]"
    end
    local query, mode = body:match("^([^%s]+)%s*(.-)%s*$")
    if not query or query == "" then
        return nil, nil, "usage: scan <name_part> [radius|all]"
    end
    return query, mode or "", nil
end

local VALID_DIRECTIONS = {
    left = true, right = true, forward = true, backward = true, up = true, down = true,
}

local function parse_tele_dir(line)
    local dir, rest = line:match("^tele%.dir%s+([%w]+)%s*(.-)%s*$")
    if not dir or dir == "" then
        return nil, nil, "usage: tele.dir <left|right|forward|backward|up|down> [step]"
    end
    dir = string.lower(dir)
    if not VALID_DIRECTIONS[dir] then
        return nil, nil, "tele.dir direction must be left|right|forward|backward|up|down"
    end
    local step = nil
    if rest and rest ~= "" then
        step = tonumber(rest)
        if not step then
            return nil, nil, "tele.dir step must be a number"
        end
    end
    return dir, step, nil
end

function M.try_handle(line)
    if line:sub(1, 8) == "tele.dir" then
        local dir, step, perr = parse_tele_dir(line)
        if not dir then
            return true, false, perr
        end
        local ok, result = feature_teleport.apply_directional(dir, step)
        if ok then
            return true, true, "ok tele.dir " .. dir .. " " .. tostring(result or "")
        end
        return true, false, "tele.dir failed: " .. tostring(result)
    end

    if line:sub(1, 4) == "tele" then
        local x, y, z = parse_tele(line)
        if not x then
            return true, false, y
        end
        local ok, err = feature_teleport.teleport_now(x, y, z)
        if ok then
            return true, true, string.format("ok tele %.3f %.3f %.3f", x, y, z)
        end
        return true, false, "tele failed: " .. tostring(err)
    end

    if line:sub(1, 4) == "scan" then
        local query, mode, perr = parse_scan(line)
        if not query then
            return true, false, perr
        end
        local ok_scan, result = feature_scan.run_scan(query, mode)
        if ok_scan then
            return true, true, tostring(result or "ok scan")
        end
        return true, false, tostring(result or "scan failed")
    end

    return false, nil, nil
end

return M