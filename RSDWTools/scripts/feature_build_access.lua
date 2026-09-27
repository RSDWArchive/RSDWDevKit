-- 1.0 building data access. BuildingPieceHandle is not an AActor or actor facade.
local M = {}
local actors = require("feature_actor")
local net = require("feature_net")
local function valid(v) return actors.is_valid_object(v) end
local function read(obj, key)
    local ok, value = pcall(function() return obj[key] end)
    if ok then return value end
end
local function unwrap(value)
    local ok, result = pcall(function() return value:get() end)
    return ok and result or value
end
local function unwrap_object(value)
    local current = value
    for _ = 1, 3 do
        local advanced = false
        for _, method in ipairs({ "get", "ToObject" }) do
            local ok, result = pcall(function()
                if current and current[method] then return current[method](current) end
            end)
            if ok and result ~= nil and result ~= current then
                current, advanced = result, true
                break
            end
        end
        if not advanced then return valid(current) and current or nil end
    end
    return valid(current) and current or nil
end
local function finite(v) return type(v) == "number" and v == v and math.abs(v) < math.huge end
local function live(class)
    local ok, list = pcall(function() return FindAllOf(class) end)
    local out = {}
    if ok and type(list) == "table" then
        for _, obj in ipairs(list) do
            if valid(obj) then
                local named, name = pcall(function() return obj:GetFullName() end)
                if named and not name:find("Default__", 1, true) then out[#out + 1] = obj end
            end
        end
    end
    return out
end
local function count(container)
    local ok, n = pcall(function() return container:Num() end)
    if ok and type(n) == "number" then return n end
    ok, n = pcall(function() return #container end)
    if ok and type(n) == "number" then return n end
end

local function same_object(a, b)
    a, b = unwrap_object(a), unwrap_object(b)
    if not a or not b then return false end
    local ok_a, address_a = pcall(function() return a:GetAddress() end)
    local ok_b, address_b = pcall(function() return b:GetAddress() end)
    return ok_a and ok_b and address_a == address_b
end

local function resolve_piece_handle(context, resolver, interaction)
    context = unwrap(context)
    resolver = unwrap_object(resolver)
    if not finite(context) or not resolver then
        return nil, "building handle has no readable resolver/context"
    end

    local sub = live("BuildingSubsystem")[1]
    local registry = read(sub, "PieceIDToBuildingPieceActor")
    if not registry then return nil, "building handle registry unavailable" end
    local id
    local ok, err = pcall(function()
        registry:ForEach(function(key, value)
            local handle = unwrap(value)
            if read(handle, "Context") == context
                and same_object(read(handle, "PieceResolver"), resolver) then
                id = unwrap(key)
                return true
            end
        end)
    end)
    if not ok then return nil, "building handle lookup failed: " .. tostring(err) end
    if not finite(id) then return nil, "building handle not in registry" end

    local manager = live("GlobalBuildingManager")[1]
    local states = read(manager, "BuildingPieces")
    local state
    ok, err = pcall(function() state = unwrap(states:Find(id)) end)
    if not ok then return nil, "target state unavailable: " .. tostring(err) end
    local cv = read(state, "ClientVisible")
    local loc, index = read(cv, "Location"), read(cv, "BuildingPieceDataIndex")
    local x, y, z = read(loc, "X"), read(loc, "Y"), read(loc, "Z")
    if not finite(index) or index < 0 or not finite(x) or not finite(y) or not finite(z) then
        return nil, "target state is unreadable"
    end
    return {
        piece_id = id,
        piece_data_index = index,
        location = { X = x, Y = y, Z = z },
        interaction = interaction,
        context = context,
        resolver = resolver,
    }
end

function M.targeted_piece()
    local pc = net.local_controller()
    if not valid(pc) then return nil, "no local controller" end
    local bmc, bic
    pcall(function() bmc = pc:GetBuildModeComponent(); bic = pc:GetBuildInteractionComponent() end)
    if not valid(bic) or M.mode(bmc) ~= 3 then return nil, "targeted building requires Repair mode" end
    local target = read(bic, "TargetedPieceHandle")
    local piece, err = resolve_piece_handle(read(target, "Context"), read(target, "PieceResolver"), bic)
    if not piece then return nil, err == "building handle has no readable resolver/context"
        and "no live targeted building handle" or err end
    piece.source = "repair_target"
    return piece
end

-- Resolve a lightweight building directly from an FHitResult. UE 5.6 reports
-- these hits as FActorInstanceHandle.ReferenceObject + FHitResult.Item rather
-- than an AActor. That pair is the same resolver/context identity stored in
-- FBuildingPieceHandle, so an exact registry match is safe and unambiguous.
function M.piece_from_hit(details)
    local hit = type(details) == "table" and (details.hit or details) or nil
    if type(hit) ~= "table" and type(hit) ~= "userdata" then
        return nil, "trace supplied no FHitResult"
    end
    local object_handle = read(hit, "HitObjectHandle")
    local resolver = unwrap_object(read(object_handle, "ReferenceObject"))
    if not resolver then return nil, "trace hit has no readable lightweight resolver" end

    local pc = net.local_controller()
    local bic
    if valid(pc) then pcall(function() bic = pc:GetBuildInteractionComponent() end) end
    local contexts, seen, last_err = {}, {}
    for _, candidate in ipairs({ read(hit, "Item"), read(hit, "ElementIndex") }) do
        candidate = unwrap(candidate)
        if finite(candidate) and candidate >= 0 and not seen[candidate] then
            contexts[#contexts + 1], seen[candidate] = candidate, true
            local piece, err = resolve_piece_handle(candidate, resolver, bic)
            if piece then
                piece.source = "trace_handle"
                return piece
            end
            last_err = err
        end
    end
    return nil, string.format("lightweight trace handle did not match building registry (contexts=%s): %s",
        #contexts > 0 and table.concat(contexts, ",") or "none", tostring(last_err or "no usable context"))
end

function M.destroy_targeted(piece)
    if not piece or not valid(piece.interaction) then return false, "invalid building target" end
    local ok, err = pcall(function() piece.interaction:Server_Interact(piece.piece_id, 3, {}, piece.location) end)
    return ok, ok and ("building destroy dispatched id=" .. tostring(piece.piece_id)) or tostring(err)
end

function M.mode(bmc)
    local ok, mode = pcall(function() return bmc:GetCurrentBuildMode() end)
    if not ok then mode = read(bmc, "CurrentBuildMode") end
    if type(mode) == "number" then return mode end
    local name = tostring(mode)
    if name:find("RepairAndEdit", 1, true) then return 3 end
    if name:find("Placement", 1, true) then return 2 end
    if name:find("Selection", 1, true) then return 1 end
    if name:find("None", 1, true) then return 0 end
end

function M.selected_data(bmc)
    local pd = read(bmc, "CurrentlyPlacingPieceData")
    if not valid(pd) then pd = unwrap(pd) end
    return valid(pd) and pd or nil
end

function M.selection_matches(bmc, expected)
    local pd = M.selected_data(bmc)
    if M.mode(bmc) ~= 2 or not pd then return false end
    local ok, same = pcall(function() return pd:GetFullName() == expected:GetFullName() end)
    return ok and same == true
end

function M.preview_transform(bmc)
    if not valid(bmc) or M.mode(bmc) ~= 2 then return nil, "not in building placement mode" end
    local actor = unwrap(read(bmc, "PreviewPiece"))
    if valid(actor) then
        local ok, loc, rot = pcall(function() return actor:K2_GetActorLocation(), actor:K2_GetActorRotation() end)
        if ok and loc and rot then return { location = loc, rotation = rot, actor = actor, source = "preview_actor" } end
    end
    -- The 1.0 reflected API does not expose the lightweight preview transform.
    -- Never use PreviewSupportingPieceHandle: that is the supporting building.
    return nil, "unsupported preview transform on this build: lightweight preview has no reflected transform accessor; use world.buildings.import for original-position delivery; run compat.buildings"
end

function M.capture_records(snapshot_actor)
    local manager = live("GlobalBuildingManager")[1]
    if not manager then return nil, "GlobalBuildingManager unavailable (capture requires authoritative host state)" end
    local states = read(manager, "BuildingPieces")
    local expected = count(states)
    if expected == nil then return nil, "BuildingPieces map is not readable" end

    local data_by_index = {}
    local unassigned_data = 0
    for _, data in ipairs(live("BuildingPieceData")) do
        local index = read(data, "BuildingPieceDataIndex")
        local ok, name = pcall(function() return data:GetFullName() end)
        if finite(index) and index >= 0 and ok then
            if data_by_index[index] and data_by_index[index] ~= name then
                return nil, "ambiguous current BuildingPieceDataIndex " .. tostring(index)
            end
            data_by_index[index] = name
        elseif finite(index) and index < 0 then
            -- 1.0 keeps several loaded data assets at -1 to mean that they are
            -- not registered in the runtime build-piece table. They are not an
            -- identity and may legitimately repeat.
            unassigned_data = unassigned_data + 1
        end
    end
    local actor_by_id = {}
    for _, actor in ipairs(live("BaseBuildingActor")) do
        local id = read(actor, "BuildingPieceID")
        if finite(id) and read(actor, "bIsPreview") ~= true then actor_by_id[id] = actor end
    end

    local records, seen, failures = {}, {}, {}
    local visited, backed = 0, 0
    local ok, err = pcall(function()
        states:ForEach(function(key, value)
            visited = visited + 1
            local id, state = unwrap(key), unwrap(value)
            local cv = read(state, "ClientVisible")
            local loc = read(cv, "Location")
            local index, yaw = read(cv, "BuildingPieceDataIndex"), read(cv, "Yaw")
            local x, y, z = read(loc, "X"), read(loc, "Y"), read(loc, "Z")
            if not finite(id) or seen[id] or not finite(index) or index < 0 or not finite(yaw)
                or not finite(x) or not finite(y) or not finite(z) then
                failures[#failures + 1] = "unreadable/duplicate registry entry " .. tostring(id)
                return
            end
            seen[id] = true
            local actor = actor_by_id[id]
            local rec = actor and snapshot_actor(actor) or nil
            if actor and (not rec or not finite(rec.x) or not finite(rec.y) or not finite(rec.z)
                or not finite(rec.pitch) or not finite(rec.yaw) or not finite(rec.roll)
                or not finite(rec.scale_x) or not finite(rec.scale_y) or not finite(rec.scale_z)) then
                failures[#failures + 1] = "live actor transform unavailable " .. tostring(id)
                return
            end
            if rec and rec.piece_data_name and data_by_index[index]
                and rec.piece_data_name:lower() ~= data_by_index[index]:lower() then
                failures[#failures + 1] = "actor/registry identity mismatch " .. tostring(id)
                return
            end
            if rec then backed = backed + 1 else
                rec = {
                    piece_id = id, piece_data_index = index, x = x, y = y, z = z,
                    yaw = yaw, pitch = 0, roll = 0,
                    actual_rot = { pitch = 0, yaw = yaw, roll = 0 },
                    scale_x = 1, scale_y = 1, scale_z = 1,
                    actual_scale = { x = 1, y = 1, z = 1 },
                    short_name = "BuildingPiece_" .. tostring(id),
                    class_name = "LightweightBuildingPiece", capture_source = "manager_client_visible",
                }
            end
            rec.piece_id, rec.piece_data_index = id, index
            rec.piece_data_name = rec.piece_data_name or data_by_index[index]
            rec.is_preview = false
            rec.is_ghosted = read(cv, "bGhosted")
            rec.stability = read(cv, "StabilityValue")
            if type(rec.piece_data_name) ~= "string" or rec.piece_data_name == "" or type(rec.is_ghosted) ~= "boolean" then
                failures[#failures + 1] = "missing identity/ghost state for piece " .. tostring(id)
                return
            end
            records[#records + 1] = rec
        end)
    end)
    if not ok then return nil, "registry read failed: " .. tostring(err) end
    if visited ~= expected or count(states) ~= expected or #failures > 0 then
        return nil, string.format("capture incomplete: expected=%d visited=%d resolved=%d; %s", expected, visited, #records, table.concat(failures, "; ", 1, math.min(#failures, 5)))
    end
    table.sort(records, function(a, b) return a.piece_id < b.piece_id end)
    return records, string.format(
        "registry=%d actor_backed=%d state_backed=%d unassigned_data_ignored=%d source=manager (verify lightweight transforms with recapture)",
        expected, backed, expected - backed, unassigned_data)
end

function M.status()
    local pc = net.local_controller()
    if not valid(pc) then return false, "no local controller" end
    local bmc = read(pc, "BuildModeComponent")
    if not valid(bmc) then pcall(function() bmc = pc:GetBuildModeComponent() end) end
    local manager = live("GlobalBuildingManager")[1]
    local sub = live("BuildingSubsystem")[1]
    local preview, preview_err = M.preview_transform(bmc)
    local pd = M.selected_data(bmc)
    local selected = "none"
    if pd then pcall(function() selected = pd:GetFullName() end) end
    local targeted, target_error = M.targeted_piece()
    return true, string.format("building_access mode=%s manager_count=%s handle_count=%s selected=%s preview_transform=%s; %s",
        tostring(M.mode(bmc)), tostring(count(read(manager, "BuildingPieces"))), tostring(count(read(sub, "PieceIDToBuildingPieceActor"))), selected,
        preview and preview.source or "unsupported", (preview_err or "read-only") .. "; target=" ..
        (targeted and ("id=" .. targeted.piece_id .. " data_index=" .. targeted.piece_data_index) or tostring(target_error)))
end

return M
