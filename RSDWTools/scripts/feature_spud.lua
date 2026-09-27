-- feature_spud.lua
-- Experimental access to SPUD's global-object registration hooks.

local M = {}

local feature_field = require("feature_field")
local safety = require("safety")

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function is_valid(obj)
    return safety.is_uobject(obj)
end

local function find_first_of(class_name)
    if not FindAllOf then return nil end
    local ok, list = pcall(FindAllOf, class_name)
    if not ok or not list then return nil end
    local n = 0
    pcall(function() n = #list end)
    if n == 0 then
        local ok_num, num_val = pcall(function() return list:Num() end)
        if ok_num and type(num_val) == "number" then n = num_val end
    end
    for i = 1, n do
        local eok, entry = pcall(function() return list[i] end)
        if eok and entry ~= nil and is_valid(entry) then return entry end
    end
    return nil
end

local function get_spud_subsystem()
    local sub = find_first_of("SpudSubsystem")
    if sub and is_valid(sub) then return sub end
    return nil, "no live SpudSubsystem"
end

function M.persist(args)
    local body = trim(args)
    local reach_spec, name = body:match("^(%S+)%s+(%S+)$")
    if not reach_spec or not name then
        return false, "usage: world.spud.persist <reachSpec> <stableName>"
    end
    local sub, serr = get_spud_subsystem()
    if not sub then return false, serr end
    local target, terr = feature_field.resolve_root(reach_spec)
    if not target or not is_valid(target) then
        return false, "target resolve failed: " .. tostring(terr)
    end
    local ok, err = pcall(function() sub:AddPersistentGlobalObjectWithName(target, name) end)
    if not ok then return false, "AddPersistentGlobalObjectWithName failed: " .. tostring(err) end
    return true, string.format("registered %s as %s", reach_spec, name)
end

function M.unpersist(args)
    local reach_spec = trim(args)
    if reach_spec == "" then return false, "usage: world.spud.unpersist <reachSpec>" end
    local sub, serr = get_spud_subsystem()
    if not sub then return false, serr end
    local target, terr = feature_field.resolve_root(reach_spec)
    if not target or not is_valid(target) then
        return false, "target resolve failed: " .. tostring(terr)
    end
    local ok, err = pcall(function() sub:RemovePersistentGlobalObject(target) end)
    if not ok then return false, "RemovePersistentGlobalObject failed: " .. tostring(err) end
    return true, "unregistered " .. reach_spec
end

return M