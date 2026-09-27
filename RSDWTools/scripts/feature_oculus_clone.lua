-- Oculus "clone" helper.
--
-- This is intentionally a class-level duplicate: pick the actor under the
-- freecam reticle, spawn another actor of that same class at the source
-- actor's current transform, then leave the duplicate in place. Building
-- pieces are handled by feature_oculus_duplicate.lua via build preview.

local M = {}

local feature_actor = require("feature_actor")
local feature_field = require("feature_field")
local feature_grab = require("feature_grab")
local feature_inventory = require("feature_inventory")
local feature_oculus_async = require("feature_oculus_async")
local feature_oculus_input_guard = require("feature_oculus_input_guard")
local feature_player_spawn = require("feature_player_spawn")
local feature_umg = require("feature_umg")

local CLONE_SPAWN_DELAY_MS = 50
local CLONE_RESOLVE_DELAY_MS = 100
local DEFERRED_TRANSFORM_DELAY_MS = 60
local DEFERRED_STABILIZE_DELAY_MS = 100
local CLONE_GRAB_SETTLE_RETRY_MS = 50
local CLONE_GRAB_SETTLE_TIMEOUT_SECONDS = 3.0
local pending_clone_token = 0
local pending_clone = nil

local function is_valid(obj)
    return feature_actor.is_valid_object(obj)
end

local function toast(message, duration)
    pcall(function() feature_umg.toast(message, duration or 1.5) end)
end

local function compact_label(label)
    local text = tostring(label or "actor")
    if #text > 72 then
        text = text:sub(1, 69) .. "..."
    end
    return text
end

local function full_name(obj)
    if not is_valid(obj) or not obj.GetFullName then return nil end
    local ok, value = pcall(function() return obj:GetFullName() end)
    if ok and type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

local function actor_class_handle(actor)
    if not is_valid(actor) then return nil, "invalid actor" end

    local cls = nil
    local ok_cls, err_cls = pcall(function()
        cls = actor.GetClass and actor:GetClass() or actor.Class
    end)
    if not ok_cls or not is_valid(cls) then
        return nil, "actor class unavailable: " .. tostring(err_cls)
    end

    local full = full_name(cls)
    local short
    if cls.GetName then
        local ok_name, value = pcall(function() return cls:GetName() end)
        if ok_name and type(value) == "string" and value ~= "" then short = value end
    end
    return cls, full or short or "<unknown class>"
end

local function object_short_name(obj)
    if not is_valid(obj) then return nil end
    local name = feature_actor.short_name_of(obj)
    if name and name ~= "" then return name end
    if obj.GetName then
        local ok, value = pcall(function() return obj:GetName() end)
        if ok and type(value) == "string" and value ~= "" then return value end
    end
    return nil
end

local function object_path(obj)
    local full = full_name(obj)
    if not full then return nil end
    local path = full:match("^%S+%s+(.+)$") or full
    path = tostring(path or ""):match("^%s*(.-)%s*$") or ""
    path = path:gsub("^'", ""):gsub("'$", "")
    if path == "" then return nil end
    return path
end

local function is_runtime_world_item(actor)
    if not is_valid(actor) then return false end
    local cls_name, obj_full
    pcall(function()
        local cls = actor:GetClass()
        if cls then
            if cls.GetFName then
                local fn = cls:GetFName()
                if fn and fn.ToString then cls_name = fn:ToString() end
            end
            if not cls_name and cls.GetName then cls_name = cls:GetName() end
        end
    end)
    pcall(function() obj_full = actor:GetFullName() end)
    local hay = ((cls_name or "") .. " " .. (obj_full or "")):lower()
    return hay:find("runtimespawnedworlditem", 1, true) ~= nil
        or hay:find("bp_runtimespawnedworlditem", 1, true) ~= nil
end

local function read_world_item_data(actor)
    if not is_valid(actor) then return nil end
    for _, method_name in ipairs({ "BP_GetItemData", "GetSpawnedItemData", "GetPrimaryAssociatedItemData" }) do
        local fn = actor[method_name]
        if fn then
            local ok, value = pcall(function() return fn(actor) end)
            if ok and is_valid(value) then return value, method_name end
        end
    end
    for _, field_name in ipairs({ "ItemData", "SpawnedItemData", "PrimaryAssociatedItemData" }) do
        local ok, value = pcall(function() return actor[field_name] end)
        if ok and is_valid(value) then return value, field_name end
    end
    return nil
end

local function actor_transform(actor)
    return {
        loc = feature_actor.actor_location(actor) or { X = 0, Y = 0, Z = 0 },
        rot = feature_actor.actor_rotation(actor) or { Pitch = 0, Yaw = 0, Roll = 0 },
        scale = feature_actor.get_actor_scale3d(actor) or { X = 1, Y = 1, Z = 1 },
    }
end

local function apply_actor_transform(actor, xform)
    if not is_valid(actor) then return false, "spawned actor unavailable" end
    xform = xform or {}
    local loc = xform.loc or {}
    local rot = xform.rot or {}
    local scale = xform.scale or {}

    feature_actor.force_actor_movable(actor)
    local ok_loc, loc_detail = feature_actor.move_actor(actor, {
        X = loc.X or loc.x or 0,
        Y = loc.Y or loc.y or 0,
        Z = loc.Z or loc.z or 0,
    })
    if not ok_loc then return false, "move failed: " .. tostring(loc_detail) end

    local ok_rot = feature_actor.set_actor_rotation(actor, {
        Pitch = rot.Pitch or rot.pitch or 0,
        Yaw = rot.Yaw or rot.yaw or 0,
        Roll = rot.Roll or rot.roll or 0,
    })
    if not ok_rot then return false, "rotation copy failed" end

    local ok_scale = feature_actor.set_actor_scale3d(actor, {
        X = scale.X or scale.x or 1,
        Y = scale.Y or scale.y or 1,
        Z = scale.Z or scale.z or 1,
    })
    if not ok_scale then return false, "scale copy failed" end

    return true
end

local function spawn_loaded_class_actor(class_obj, class_label, xform)
    if not is_valid(class_obj) then return nil, "invalid actor class" end
    xform = xform or {}
    local loc = xform.loc or {}
    local rot = xform.rot or {}

    local world
    pcall(function() world = feature_field.resolve_root("world") end)
    if not is_valid(world) then return nil, "no UWorld" end
    if not world.SpawnActor then return nil, "UWorld:SpawnActor missing" end

    local spawn_loc = {
        X = loc.X or loc.x or 0,
        Y = loc.Y or loc.y or 0,
        Z = loc.Z or loc.z or 0,
    }
    local spawn_rot = {
        Pitch = rot.Pitch or rot.pitch or 0,
        Yaw = rot.Yaw or rot.yaw or 0,
        Roll = rot.Roll or rot.roll or 0,
    }

    local actor
    local ok_spawn, spawn_err = pcall(function()
        actor = world:SpawnActor(class_obj, spawn_loc, spawn_rot)
    end)
    if not ok_spawn then
        return nil, "World:SpawnActor failed: " .. tostring(spawn_err)
    end
    if not is_valid(actor) then
        return nil, "World:SpawnActor returned nil/invalid"
    end

    pcall(function() actor.bRegisterAsRuntimeSpawned = true end)
    pcall(function() feature_field.set_last_spawned(actor) end)

    return actor, string.format("loaded-class SpawnActor %s @ (%.1f,%.1f,%.1f)",
        tostring(class_label or "<class>"),
        spawn_loc.X or 0,
        spawn_loc.Y or 0,
        spawn_loc.Z or 0)
end

local function schedule_delay(delay_ms, fn)
    return feature_oculus_async.schedule_game_thread(delay_ms, function()
        local ok, err = pcall(fn)
        if not ok then
            print("[RSDWTools.oculus.clone] deferred step failed: " .. tostring(err))
        end
    end)
end

local function clone_pending_label()
    if not pending_clone then return nil end
    return tostring(pending_clone.label or "clone")
end

local function release_guard_token(token, reason)
    if token then
        pcall(function() feature_oculus_input_guard.release(token, reason or "clone") end)
    end
end

local function grab_settle_message()
    if feature_grab.is_modal_active and feature_grab.is_modal_active() then
        return "grab active or pending"
    end
    if type(feature_grab.restart_cooldown_message) == "function" then
        local ok, msg = pcall(function() return feature_grab.restart_cooldown_message() end)
        if ok and msg then return tostring(msg) end
    end
    return nil
end

local function after_grab_settled(token, finish, fn)
    if not pending_clone or pending_clone.token ~= token then return end
    local settle = grab_settle_message()
    if settle then
        local started = tonumber(pending_clone.started_clock) or os.clock()
        if (os.clock() - started) > CLONE_GRAB_SETTLE_TIMEOUT_SECONDS then
            finish(false, "timed out waiting for grab to settle: " .. tostring(settle))
            return
        end
        if pending_clone.settle_logged ~= true then
            pending_clone.settle_logged = true
            print("[RSDWTools.oculus.clone] waiting for grab settle: " .. tostring(settle))
        end
        schedule_delay(CLONE_GRAB_SETTLE_RETRY_MS, function()
            after_grab_settled(token, finish, fn)
        end)
        return
    end
    fn()
end

local function begin_pending_clone(label, guard_token)
    if pending_clone then
        return false, "clone already pending for " .. tostring(clone_pending_label())
    end

    pending_clone_token = pending_clone_token + 1
    local token = pending_clone_token
    local final_label = tostring(label or "clone")
    pending_clone = { token = token, label = final_label, started_clock = os.clock() }
    local finished = false

    local function finish(ok, detail)
        if finished then return end
        finished = true
        release_guard_token(guard_token, "clone.finish")
        if pending_clone and pending_clone.token == token then
            pending_clone = nil
        end
        local prefix = ok and "deferred clone ready: " or "deferred clone failed: "
        print("[RSDWTools.oculus.clone] " .. prefix .. tostring(final_label) .. " ; " .. tostring(detail))
        if ok then
            toast("Duplicated: " .. compact_label(final_label), 1.5)
        else
            toast("Duplicate failed: " .. compact_label(final_label), 2.0)
        end
    end

    return true, token, final_label, finish
end

local function queue_transform_finish_for_actor(token, actor, source_transform, context, finish, options)
    if not is_valid(actor) then
        finish(false, "spawned actor unavailable")
        return
    end
    options = options or {}

    schedule_delay(DEFERRED_TRANSFORM_DELAY_MS, function()
        if not pending_clone or pending_clone.token ~= token then return end
        if not is_valid(actor) then
            finish(false, "spawned actor became invalid before transform copy")
            return
        end

        local ok_xform, xform_detail = apply_actor_transform(actor, source_transform)
        if not ok_xform then
            finish(false, "transform copy failed: " .. tostring(xform_detail))
            return
        end

        if options.stabilize_runtime_item == true then
            schedule_delay(DEFERRED_STABILIZE_DELAY_MS, function()
                if not pending_clone or pending_clone.token ~= token then return end
                if not is_valid(actor) then
                    finish(false, "spawned item became invalid before stabilize")
                    return
                end
                if type(feature_inventory.stabilize_runtime_world_item_fast) ~= "function" then
                    finish(true, tostring(context or "clone") .. " transform copied; item stabilize unavailable")
                    return
                end
                local ok_call, ok_stable, stable_result = pcall(function()
                    return feature_inventory.stabilize_runtime_world_item_fast(actor)
                end)
                if not ok_call then
                    finish(false, "item stabilize raised: " .. tostring(ok_stable))
                    return
                end
                if not ok_stable then
                    local err = stable_result and stable_result.error or "stabilize failed"
                    finish(false, "item stabilize failed: " .. tostring(err))
                    return
                end
                local actions = stable_result and stable_result.actions or {}
                local failures = stable_result and stable_result.failures or {}
                finish(true, string.format("%s transform copied; item stabilized actions=%d failures=%d",
                    tostring(context or "clone.item"), #actions, #failures))
            end)
            return
        end

        finish(true, tostring(context or "clone.actor") .. " transform copied; no auto-grab")
    end)
end

local function queue_actor_clone_spawn(class_obj, class_label, source_transform, label, source, guard_token)
    local ok_pending, token_or_detail, final_label, finish = begin_pending_clone(label, guard_token)
    if not ok_pending then
        return false, token_or_detail
    end

    local token = token_or_detail
    schedule_delay(CLONE_SPAWN_DELAY_MS, function()
        if not pending_clone or pending_clone.token ~= token then return end
        after_grab_settled(token, finish, function()
            if not pending_clone or pending_clone.token ~= token then return end
            local actor, spawn_detail = spawn_loaded_class_actor(class_obj, class_label, source_transform)
            if not is_valid(actor) then
                finish(false, string.format("loaded-class spawn failed for %s (%s): %s",
                    tostring(final_label), tostring(class_label), tostring(spawn_detail)))
                return
            end

            schedule_delay(CLONE_RESOLVE_DELAY_MS, function()
                if not pending_clone or pending_clone.token ~= token then return end
                if not is_valid(actor) then
                    finish(false, string.format("spawned %s from %s, but actor was invalid after settle",
                        tostring(class_label), tostring(final_label)))
                    return
                end
                queue_transform_finish_for_actor(token, actor, source_transform, "clone.actor", function(ok, detail)
                    finish(ok, string.format("%s [%s]; %s", tostring(spawn_detail), tostring(source or "trace"), tostring(detail)))
                end)
            end)
        end)
    end)

    return true, string.format("queued deferred clone spawn+copy for %s over ~%dms",
        final_label, CLONE_SPAWN_DELAY_MS + CLONE_RESOLVE_DELAY_MS + DEFERRED_TRANSFORM_DELAY_MS)
end

local function queue_item_clone_spawn(item_name, item_path, source_transform, label, guard_token)
    local ok_pending, token_or_detail, final_label, finish = begin_pending_clone(label or item_name, guard_token)
    if not ok_pending then
        return false, token_or_detail
    end

    local token = token_or_detail
    schedule_delay(CLONE_SPAWN_DELAY_MS, function()
        if not pending_clone or pending_clone.token ~= token then return end
        after_grab_settled(token, finish, function()
            if not pending_clone or pending_clone.token ~= token then return end
            local ok_give, give_detail = feature_inventory.give(tostring(item_name) .. " 1")
            if not ok_give and item_path and item_path ~= "" then
                ok_give, give_detail = feature_player_spawn.spawn_item(tostring(item_path) .. " 1")
            end
            if not ok_give then
                finish(false, string.format("item duplicate failed for %s: %s", tostring(item_name), tostring(give_detail)))
                return
            end

            schedule_delay(CLONE_RESOLVE_DELAY_MS, function()
                if not pending_clone or pending_clone.token ~= token then return end
                local actor
                pcall(function() actor = feature_field.resolve_root("lastspawned") end)
                if not is_valid(actor) then
                    finish(false, string.format("duplicated item %s, but lastspawned was not resolvable after settle",
                        tostring(item_name)))
                    return
                end
                queue_transform_finish_for_actor(token, actor, source_transform, "clone.item", function(ok, detail)
                    finish(ok, tostring(give_detail) .. "; " .. tostring(detail))
                end, { stabilize_runtime_item = true })
            end)
        end)
    end)

    return true, string.format("queued deferred item clone+copy for %s over ~%dms",
        final_label, CLONE_SPAWN_DELAY_MS + CLONE_RESOLVE_DELAY_MS + DEFERRED_TRANSFORM_DELAY_MS + DEFERRED_STABILIZE_DELAY_MS)
end

local function oculus_pawn()
    local ok, obj = pcall(function()
        return feature_field.resolve_root("pawn.OculusComponent.OculusPawn")
    end)
    if ok and is_valid(obj) then return obj end
    return nil
end

local function refused_self(actor)
    local pawn = feature_actor.get_local_pawn()
    if is_valid(pawn) and actor == pawn then
        return "refusing to clone local player pawn"
    end
    local opawn = oculus_pawn()
    if is_valid(opawn) and actor == opawn then
        return "refusing to clone oculus pawn"
    end
    return nil
end

local function clone_runtime_world_item(actor, source, guard_token)
    local item_data, item_source = read_world_item_data(actor)
    if not is_valid(item_data) then
        return false, "runtime world item has no readable ItemData"
    end

    local item_name = object_short_name(item_data)
    local item_path = object_path(item_data)
    if not item_name or item_name == "" then
        return false, "runtime world item ItemData has no readable asset name"
    end

    local source_transform = actor_transform(actor)
    local short = feature_actor.short_name_of(actor) or "<unnamed item>"
    local ok_queue, queue_detail = queue_item_clone_spawn(
        item_name,
        item_path,
        source_transform,
        tostring(item_name),
        guard_token)
    if not ok_queue then
        return false, string.format("queued item duplicate %s, but deferred spawn failed: %s",
            tostring(item_name), tostring(queue_detail))
    end

    return true, string.format(
        "queued item duplicate %s from %s [%s via %s]; copied loc=(%.1f,%.1f,%.1f) rot=(%.1f,%.1f,%.1f) scale=(%.3f,%.3f,%.3f); %s",
        tostring(item_name),
        tostring(short),
        tostring(source or "trace"),
        tostring(item_source or "ItemData"),
        source_transform.loc.X or 0,
        source_transform.loc.Y or 0,
        source_transform.loc.Z or 0,
        source_transform.rot.Pitch or 0,
        source_transform.rot.Yaw or 0,
        source_transform.rot.Roll or 0,
        source_transform.scale.X or 1,
        source_transform.scale.Y or 1,
        source_transform.scale.Z or 1,
        tostring(queue_detail))
end

function M.clone()
    if feature_grab.is_modal_active and feature_grab.is_modal_active() then
        return false, "release the current grabbed actor first"
    end
    if feature_grab.is_active and feature_grab.is_active() then
        return false, "release the current grabbed actor first"
    end
    if pending_clone then
        return false, "clone already pending for " .. tostring(clone_pending_label())
    end

    local actor, source = feature_grab.pick_actor_under_reticle()
    if not is_valid(actor) then
        return false, "no actor under reticle"
    end

    local self_err = refused_self(actor)
    if self_err then return false, self_err end

    local guard_token = feature_oculus_input_guard.acquire("clone")
    local guard_transferred = false
    local function fail(detail)
        if not guard_transferred then release_guard_token(guard_token, "clone.fail") end
        return false, detail
    end

    if is_runtime_world_item(actor) then
        local ok_item, item_detail = clone_runtime_world_item(actor, source, guard_token)
        if ok_item then
            guard_transferred = true
            return ok_item, item_detail
        end
        return fail(item_detail)
    end

    local class_obj, class_label = actor_class_handle(actor)
    if not class_obj then return fail(tostring(class_label)) end

    local source_transform = actor_transform(actor)
    local short = feature_actor.short_name_of(actor) or "<unnamed>"
    local ok_queue, queue_detail = queue_actor_clone_spawn(
        class_obj,
        class_label,
        source_transform,
        short,
        source,
        guard_token)
    if not ok_queue then
        return fail(string.format("queued spawn %s from %s, but deferred clone failed: %s",
            tostring(class_label), tostring(short), tostring(queue_detail)))
    end
    guard_transferred = true

    return true, string.format(
        "queued clone %s via loaded-class %s [%s]; copied loc=(%.1f,%.1f,%.1f) rot=(%.1f,%.1f,%.1f) scale=(%.3f,%.3f,%.3f); %s",
        tostring(short), tostring(class_label), tostring(source or "trace"),
        source_transform.loc.X or 0,
        source_transform.loc.Y or 0,
        source_transform.loc.Z or 0,
        source_transform.rot.Pitch or 0,
        source_transform.rot.Yaw or 0,
        source_transform.rot.Roll or 0,
        source_transform.scale.X or 1,
        source_transform.scale.Y or 1,
        source_transform.scale.Z or 1,
        tostring(queue_detail))
end

return M
