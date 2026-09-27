-- Actor facade conversion for the 1.0 AI APIs. Never fabricate native handles.
local M = {}
local actors = require("feature_actor")
local library_path = "/Script/JagexEngine.Default__ActorFacadeBlueprintLibrary"
local function call(name, ...)
    if not StaticFindObject then return false, "StaticFindObject unavailable" end
    local args = table.pack(...)
    local ok, result = pcall(function()
        local lib = StaticFindObject(library_path)
        -- Resolve the UFunction explicitly: IsValid also names a UE4SS UObject method.
        local fn = StaticFindObject("/Script/JagexEngine.ActorFacadeBlueprintLibrary:" .. name)
        if not lib or not fn then error("actor facade API unavailable: " .. name) end
        return fn(lib, table.unpack(args, 1, args.n))
    end)
    if not ok then return false, tostring(result) end
    return true, result
end

function M.from_actor(actor)
    if actor ~= nil and not actors.is_valid_object(actor) then return false, "invalid actor" end
    local ok, handle = call("ToFacade", actor)
    if not ok or handle == nil then return false, handle or "ToFacade returned nil" end
    local checked, valid = call("IsValid", handle)
    if not checked then return false, valid end
    if (actor ~= nil) ~= (valid == true) then return false, "facade validity did not match actor" end
    return true, handle
end

function M.to_actor(handle)
    if handle == nil then return nil, "empty facade" end
    local ok, actor = call("ToActor", handle)
    if not ok then return nil, actor end
    if not actors.is_valid_object(actor) then return nil, "facade has no live actor" end
    return actor
end

function M.snapshot(ai)
    if not actors.is_valid_object(ai) then return false, "invalid AI" end
    local ok, handle = pcall(function() return ai:GetSpecifiedTargetOverride() end)
    if not ok or handle == nil then return false, tostring(handle or "target handle unavailable") end
    local checked, valid = call("IsValid", handle)
    if not checked then return false, valid end
    return true, { handle = handle, had_target = valid == true }
end

function M.set_target(ai, target)
    if not actors.is_valid_object(ai) then return false, "invalid AI" end
    local ok, handle = M.from_actor(target)
    if not ok then return false, handle end
    return pcall(function() ai:SetSpecifiedTargetOverride(handle) end)
end

function M.restore(ai, snapshot)
    if not actors.is_valid_object(ai) then return false, "invalid AI" end
    if not snapshot or snapshot.handle == nil then return false, "missing target snapshot" end
    local ok, valid = call("IsValid", snapshot.handle)
    if not ok then return false, valid end
    if not valid then return M.set_target(ai, nil) end
    return pcall(function() ai:SetSpecifiedTargetOverride(snapshot.handle) end)
end

function M.status()
    local pawn = actors.get_local_pawn()
    if not actors.is_valid_object(pawn) then return false, "no local pawn" end
    local ok, facade = M.from_actor(pawn)
    if not ok then return false, facade end
    local roundtrip = M.to_actor(facade)
    local empty_ok, empty = M.from_actor(nil)
    if not roundtrip or roundtrip ~= pawn then return false, "actor facade round-trip mismatch" end
    if not empty_ok then return false, "empty facade: " .. tostring(empty) end
    return true, "actor_facade roundtrip=ok empty_handle=ok (read-only)"
end

return M
