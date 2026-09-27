-- feature_persistence.lua
-- Small wrappers around high-value SaveGame surfaces on existing placed world objects.

local M = {}

local feature_field = require("feature_field")
local safety = require("safety")

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_valid(obj)
    return safety.is_uobject(obj)
end

local function class_name(obj)
    return safety.class_name_of(obj) or "UnknownClass"
end

local function parse_bool(value)
    local s = tostring(value or ""):lower()
    if s == "on" or s == "true" or s == "1" or s == "yes" then return true end
    if s == "off" or s == "false" or s == "0" or s == "no" then return false end
    return nil
end

local function read_text(obj, field)
    local ok, value = pcall(function() return obj[field] end)
    if not ok or value == nil then return "?" end
    local primitive = safety.read_primitive(value)
    if primitive ~= nil then return tostring(primitive) end
    return tostring(value)
end

local function resolve_reach(reach_spec)
    local spec = trim(reach_spec)
    if spec == "" then spec = "lookat" end
    local obj, err = feature_field.resolve_root(spec)
    if not obj then return nil, err end
    return obj, spec
end

local RESOURCE_ALIASES = { "ResourceRespawnComponent", "RespawnComponent" }

local function resolve_resource(args)
    local target, spec_or_err = resolve_reach(args)
    if not target then return nil, nil, spec_or_err end
    if class_name(target):find("ResourceRespawnComponent", 1, true) then
        return target, spec_or_err
    end
    for _, field in ipairs(RESOURCE_ALIASES) do
        local ok, comp = pcall(function() return target[field] end)
        if ok and comp ~= nil and is_valid(comp) then
            return comp, spec_or_err .. "." .. field
        end
    end
    return nil, nil, "no ResourceRespawnComponent on " .. spec_or_err .. " class=" .. class_name(target)
end

local function resource_summary(comp)
    local qty = "?"
    local ok_qty, q = pcall(function() return comp:GetQuantityAvailable() end)
    if ok_qty and q ~= nil then qty = tostring(q) end
    return string.format("class=%s qty=%s raw=%s paused=%s lastChangeTicks=%s blockers=%s",
        class_name(comp),
        qty,
        read_text(comp, "ResourcesAvailable"),
        read_text(comp, "bIsRespawningPaused"),
        read_text(comp, "PersistedTimeOfLastResourceChange"),
        read_text(comp, "RespawnPreventingBuildings"))
end

local function parse_reach_number(args, usage)
    local s = trim(args)
    if s == "" then return nil, nil, usage end
    local single = tonumber(s)
    if single ~= nil then return "lookat", single end
    local reach, value_text = s:match("^(%S+)%s+(.+)$")
    local value = tonumber(trim(value_text))
    if not reach or value == nil then return nil, nil, usage end
    return reach, value
end

local function parse_reach_bool(args, usage)
    local s = trim(args)
    if s == "" then return nil, nil, usage end
    local single = parse_bool(s)
    if single ~= nil then return "lookat", single end
    local reach, value_text = s:match("^(%S+)%s+(%S+)$")
    local value = parse_bool(value_text)
    if not reach or value == nil then return nil, nil, usage end
    return reach, value
end

function M.resource_probe(args)
    local comp, spec, err = resolve_resource(args)
    if not comp then return false, err end
    return true, spec .. " " .. resource_summary(comp)
end

function M.resource_set(args)
    local reach, amount, err = parse_reach_number(args, "usage: world.resource.set [reachSpec] <amount>")
    if not reach then return false, err end
    local comp, spec, rerr = resolve_resource(reach)
    if not comp then return false, rerr end
    local before = resource_summary(comp)
    local ok, call_err = pcall(function() comp:SetResourceAmount(math.floor(amount)) end)
    if not ok then return false, "SetResourceAmount failed: " .. tostring(call_err) end
    return true, spec .. " before={" .. before .. "} after={" .. resource_summary(comp) .. "}"
end

function M.resource_pause(args)
    local reach, value, err = parse_reach_bool(args, "usage: world.resource.pause [reachSpec] <on|off>")
    if not reach then return false, err end
    local comp, spec, rerr = resolve_resource(reach)
    if not comp then return false, rerr end
    local before = read_text(comp, "bIsRespawningPaused")
    local ok, write_err = pcall(function() comp.bIsRespawningPaused = value and true or false end)
    if not ok then return false, "bIsRespawningPaused write failed: " .. tostring(write_err) end
    return true, string.format("%s paused %s -> %s qty=%s", spec, before, read_text(comp, "bIsRespawningPaused"), read_text(comp, "ResourcesAvailable"))
end

function M.resource_take(args)
    local comp, spec, err = resolve_resource(args)
    if not comp then return false, err end
    local before = resource_summary(comp)
    local ok, call_err = pcall(function() comp:TakeResource() end)
    if not ok then return false, "TakeResource failed: " .. tostring(call_err) end
    return true, spec .. " before={" .. before .. "} after={" .. resource_summary(comp) .. "}"
end

local CHEST_STATES = {
    unopened = 0,
    opened = 1,
    emptied = 2,
}

local function parse_chest_state(value)
    local s = tostring(value or ""):lower()
    local n = tonumber(s)
    if n ~= nil and n >= 0 and n <= 2 then return math.floor(n) end
    return CHEST_STATES[s]
end

local function resolve_chest(args)
    local target, spec_or_err = resolve_reach(args)
    if not target then return nil, nil, spec_or_err end
    local cls = class_name(target)
    if cls:find("Chest", 1, true) then return target, spec_or_err end
    return nil, nil, "target is not a chest: " .. spec_or_err .. " class=" .. cls
end

local function chest_summary(chest)
    local getter = "?"
    local ok_state, state = pcall(function() return chest:GetChestState() end)
    if ok_state and state ~= nil then getter = tostring(state) end
    return string.format("class=%s state=%s field=%s respawnDisabled=%s respawnStartTicks=%s",
        class_name(chest),
        getter,
        read_text(chest, "ChestState"),
        read_text(chest, "bRespawnDisabled"),
        read_text(chest, "RespawnTimerInGameTimeStartTicks"))
end

function M.chest_probe(args)
    local chest, spec, err = resolve_chest(args)
    if not chest then return false, err end
    return true, spec .. " " .. chest_summary(chest)
end

function M.chest_state(args)
    local s = trim(args)
    if s == "" then return false, "usage: world.chest.state [reachSpec] <unopened|opened|emptied|0|1|2>" end
    local state = parse_chest_state(s)
    local reach = "lookat"
    if state == nil then
        local a, b = s:match("^(%S+)%s+(%S+)$")
        reach = a or ""
        state = parse_chest_state(b)
    end
    if state == nil then return false, "unknown chest state; use unopened|opened|emptied|0|1|2" end
    local chest, spec, err = resolve_chest(reach)
    if not chest then return false, err end
    local before = chest_summary(chest)
    local ok, write_err = pcall(function() chest.ChestState = state end)
    if not ok then return false, "ChestState write failed: " .. tostring(write_err) end
    pcall(function() chest:OnRep_ChestState() end)
    pcall(function() chest:UpdateChestFX(state) end)
    return true, spec .. " before={" .. before .. "} after={" .. chest_summary(chest) .. "}"
end

function M.chest_respawn_disabled(args)
    local reach, value, err = parse_reach_bool(args, "usage: world.chest.respawn_disabled [reachSpec] <on|off>")
    if not reach then return false, err end
    local chest, spec, rerr = resolve_chest(reach)
    if not chest then return false, rerr end
    local before = chest_summary(chest)
    local ok, call_err = pcall(function() chest:SetRespawnDisabled(value and true or false) end)
    if not ok then
        local ok_write, write_err = pcall(function() chest.bRespawnDisabled = value and true or false end)
        if not ok_write then return false, "SetRespawnDisabled failed: " .. tostring(call_err) .. "; raw write failed: " .. tostring(write_err) end
    end
    return true, spec .. " before={" .. before .. "} after={" .. chest_summary(chest) .. "}"
end

return M