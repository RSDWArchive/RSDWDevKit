-- Actor feature: operations keyed by exact actor short name (GetName()).
--
-- These entry points are called from command_line_router.lua for the actor.*
-- verbs the WPF scan tab emits. Every public function:
--   * runs on whatever thread the router is on; it wraps its own
--     ExecuteInGameThread where necessary and returns a (ok, detail) tuple
--   * resolves the actor by matching GetName() (short, instance-unique, no
--     spaces) against FindAllOf("Actor"), which is exactly what scan emits
--
-- Action verbs (all take a name string):
--   goto_actor(name)              -- teleport player above the actor
--   bring_actor(name)             -- teleport actor in front of player
--   delete_actor(name)            -- destroy actor
--   set_visibility(name, on)      -- explicit on/off/toggle (nil = toggle)
--   set_collision(name, on)       -- explicit on/off/toggle (nil = toggle)
--   get_scale_uniform(name)       -- returns X component as string "1.000"
--   set_scale_uniform(name, v)    -- sets uniform scale

local M = {}

-- Offsets chosen to match old RSDTools behaviour so muscle memory carries over.
local OFFSET_UP_GOTO = 300.0      -- goto: stack player this far above target
local OFFSET_FORWARD = 250.0      -- bring: this far in front of player
local OFFSET_UP_SPAWN = 50.0      -- bring: plus this far up so actor doesn't clip

-- Per-name toggle-state caches, keyed by the instance-unique short name. We
-- rely on these rather than the engine-reported actor flags because on this
-- build GetActorEnableCollision() has been observed to always return the
-- "default" value (the SetActorEnableCollision call succeeds but subsequent
-- reads don't reflect it), which caused every collision toggle to land on
-- "on". The cache gives us deterministic flip semantics: first toggle reads
-- whatever the engine reports (if anything) to anchor our starting state, and
-- subsequent toggles just invert what we last set. Identity of the actor
-- short name is stable per instance so this is safe across scans as long as
-- the same actor is still alive.
local VIS_STATE = {}
local COL_STATE = {}

-- Handle cache keyed by actor short name. After the first successful lookup,
-- we stash the userdata so subsequent action verbs on the same actor can skip
-- the FindAllOf("Actor") + full array walk entirely. Re-enumerating the whole
-- UObject array (often 8-10k+ entries) on every click is both slow and a
-- native-AV risk whenever the world is volatile (post-teleport, after
-- hide/destroy, during streaming). UE4SS userdata carries object index +
-- serial number so calling IsValid() on a stale handle returns false safely
-- without native crash. Entries are invalidated on delete and on any lookup
-- that reveals a stale handle.
local HANDLE_CACHE = {}

-- Safer validity check. Never calls into native code without pcall, and guards
-- against non-userdata entries slipping out of FindAllOf (has happened on
-- pending-kill objects mid-GC). Mirrors the pattern proven stable in
-- feature_scan.lua's iteration loop.
local function is_valid(obj)
    if type(obj) ~= "userdata" then return false end
    local ok_method, method = pcall(function() return obj.IsValid end)
    if not ok_method or not method then return false end
    local ok, v = pcall(function() return obj:IsValid() end)
    return ok and v and true or false
end

local function deg2rad(d)
    return d * math.pi / 180.0
end

-- ---------- player resolution ----------

-- Delegated to feature_net so every consumer in the mod ends up at
-- the same strict IsLocalController()-based resolver. The previous
-- in-file walk used pawn:IsPlayerControlled() as its match test,
-- which is true for *any* human-driven pawn -- in multiplayer that
-- could return a remote PC and silently mis-route every cheat.
-- See feature_net.lua header for the full rationale.
local feature_net = require("feature_net")

local function get_local_player_controller()
    return feature_net.local_controller()
end

local function get_local_pawn()
    return feature_net.local_pawn()
end

-- ---------- actor location/rotation utils ----------

local function actor_location(actor)
    if not is_valid(actor) then return nil end
    if actor.K2_GetActorLocation then
        local ok, v = pcall(function() return actor:K2_GetActorLocation() end)
        if ok and v then return v end
    end
    if actor.GetActorLocation then
        local ok, v = pcall(function() return actor:GetActorLocation() end)
        if ok and v then return v end
    end
    return nil
end

local function actor_rotation(actor)
    if not is_valid(actor) then return nil end
    if actor.K2_GetActorRotation then
        local ok, v = pcall(function() return actor:K2_GetActorRotation() end)
        if ok and v then return v end
    end
    if actor.GetActorRotation then
        local ok, v = pcall(function() return actor:GetActorRotation() end)
        if ok and v then return v end
    end
    return nil
end

local function actor_forward_unit(actor)
    local rot = actor_rotation(actor)
    if not rot then
        return { X = 1, Y = 0, Z = 0 }
    end
    local yaw = deg2rad(rot.Yaw or 0)
    return { X = math.cos(yaw), Y = math.sin(yaw), Z = 0 }
end

local function vec_add(a, b)
    return { X = (a.X or 0) + (b.X or 0), Y = (a.Y or 0) + (b.Y or 0), Z = (a.Z or 0) + (b.Z or 0) }
end

local function location_above_actor(target, up)
    local base = actor_location(target)
    if not base then return nil end
    return vec_add(base, { X = 0, Y = 0, Z = up })
end

local function location_in_front_of(pawn, forward_dist, up)
    local base = actor_location(pawn)
    if not base then return nil end
    local f = actor_forward_unit(pawn)
    return vec_add(base, { X = f.X * forward_dist, Y = f.Y * forward_dist, Z = up })
end

-- ---------- mutation helpers ----------

local function move_actor(actor, loc)
    if not is_valid(actor) then return false, "invalid actor" end
    if actor.K2_SetActorLocation then
        local ok_call, result = pcall(function()
            local hit = {}
            return actor:K2_SetActorLocation(loc, false, hit, true)
        end)
        if ok_call then
            return result ~= false, result == false and "K2_SetActorLocation returned false" or nil
        end
    end
    if actor.SetActorLocation then
        local ok_call, result = pcall(function() return actor:SetActorLocation(loc) end)
        if ok_call then
            return result ~= false, result == false and "SetActorLocation returned false" or nil
        end
    end
    return false, "no actor location setter"
end

local function force_actor_movable(actor)
    if not is_valid(actor) then return end
    local root = actor.RootComponent
    if not is_valid(root) then return end
    if root.SetMobility then
        pcall(function() root:SetMobility("EComponentMobility::Movable") end)
        pcall(function() root:SetMobility(2) end)
    end
    if root.SetSimulatePhysics then
        pcall(function() root:SetSimulatePhysics(false) end)
    end
end

local function destroy_actor(actor)
    if not is_valid(actor) then return false end
    if actor.K2_DestroyActor then
        local ok = pcall(function() actor:K2_DestroyActor() end)
        if ok then return true end
    end
    if actor.DestroyActor then
        local ok = pcall(function() actor:DestroyActor() end)
        if ok then return true end
    end
    return false
end

local function read_actor_hidden(actor)
    if not actor then return nil end
    if actor.IsHidden then
        local ok, v = pcall(function() return actor:IsHidden() end)
        if ok and type(v) == "boolean" then return v end
    end
    local ok, v = pcall(function() return actor.bHidden end)
    if ok and type(v) == "boolean" then return v end
    ok, v = pcall(function() return actor.Hidden end)
    if ok and type(v) == "boolean" then return v end
    return nil
end

local function set_actor_hidden(actor, hidden_value)
    if not is_valid(actor) then return false end
    if actor.SetActorHiddenInGame then
        local ok = pcall(function() actor:SetActorHiddenInGame(hidden_value and true or false) end)
        return ok
    end
    return false
end

local function read_actor_collision_enabled(actor)
    if not actor then return nil end
    if actor.GetActorEnableCollision then
        local ok, v = pcall(function() return actor:GetActorEnableCollision() end)
        if ok and type(v) == "boolean" then return v end
    end
    local ok, v = pcall(function() return actor.bActorEnableCollision end)
    if ok and type(v) == "boolean" then return v end
    return nil
end

local function set_actor_collision_enabled(actor, enabled)
    if not is_valid(actor) then return false end
    local touched = false
    if actor.SetActorEnableCollision then
        local ok = pcall(function() actor:SetActorEnableCollision(enabled and true or false) end)
        if ok then touched = true end
    end
    local root = actor.RootComponent
    if is_valid(root) then
        if root.SetCollisionEnabled then
            local mode = enabled and "ECollisionEnabled::QueryAndPhysics" or "ECollisionEnabled::NoCollision"
            local ok = pcall(function() root:SetCollisionEnabled(mode) end)
            if not ok then
                local numeric = enabled and 3 or 0
                pcall(function() root:SetCollisionEnabled(numeric) end)
            end
            touched = true
        end
    end
    return touched
end

local function get_actor_scale3d(actor)
    if not is_valid(actor) then return nil end
    if actor.K2_GetActorScale3D then
        local ok, v = pcall(function() return actor:K2_GetActorScale3D() end)
        if ok and v then return v end
    end
    if actor.GetActorScale3D then
        local ok, v = pcall(function() return actor:GetActorScale3D() end)
        if ok and v then return v end
    end
    return nil
end

local function set_actor_scale3d(actor, vec)
    if not is_valid(actor) or not vec then return false end
    if actor.K2_SetActorScale3D then
        local ok = pcall(function() actor:K2_SetActorScale3D(vec) end)
        if ok then return true end
    end
    if actor.SetActorScale3D then
        local ok = pcall(function() actor:SetActorScale3D(vec) end)
        if ok then return true end
    end
    return false
end

-- ---------- actor lookup ----------
--
-- Matching strategy: feature_scan.lua emits the short instance name derived
-- from GetFullName() via short_name_from_full(). We must use the *same*
-- derivation here or the names won't match. Calling GetName() directly has
-- been observed to crash on some objects on this build (hard AV, not a
-- catchable Lua error), while GetFullName() has been stable across 6976+
-- actors in scan, so we go through GetFullName() exclusively.

local function actor_full_name_safe(actor)
    if not actor.GetFullName then return nil end
    local ok, n = pcall(function() return actor:GetFullName() end)
    if ok and type(n) == "string" and n ~= "" then
        return n
    end
    return nil
end

-- Mirrors short_name_from_full in feature_scan.lua. Kept as a standalone copy
-- (rather than requiring feature_scan) because feature_scan pulls in IO paths
-- we don't need on the action verb path.
local function short_name_from_full(full_name)
    if type(full_name) ~= "string" or full_name == "" then
        return nil
    end
    local after_dot = full_name:match("%.([^%.]+)$")
    if after_dot and after_dot ~= "" then
        return after_dot
    end
    local tail = full_name:match("([^%s]+)$") or full_name
    local piece = tail:match("%.([^%.]+)$")
    return piece and piece ~= "" and piece or tail
end

local function find_actor_by_exact_short_name(name)
    local target_name = tostring(name or "")
    if target_name == "" then return nil end

    local actors
    local ok_find = pcall(function()
        actors = FindAllOf and FindAllOf("Actor") or nil
        if type(actors) ~= "table" then
            actors = FindAllOf and FindAllOf("AActor") or nil
        end
    end)
    if not ok_find or type(actors) ~= "table" then
        return nil
    end

    local total = #actors
    print(string.format("[RSDWTools] actor lookup: scanning %d actors for '%s'",
        total, target_name))

    local PROGRESS_STEP = 1000
    local skipped = 0
    local found = nil

    -- Per-object work is pcall-wrapped and userdata-gated, identical to the
    -- loop shape proven stable by feature_scan. A single bad UObject must
    -- never take down the whole lookup.
    for i, obj in ipairs(actors) do
        if (i % PROGRESS_STEP) == 0 then
            print(string.format("[RSDWTools] actor lookup: progress %d/%d (skipped=%d)",
                i, total, skipped))
        end

        local ok_iter = pcall(function()
            if not is_valid(obj) then return end

            local full = actor_full_name_safe(obj)
            if not full then return end
            local short = short_name_from_full(full)
            if short == target_name then
                found = obj
            end
        end)
        if not ok_iter then
            skipped = skipped + 1
        end
        if found then
            print(string.format("[RSDWTools] actor lookup: matched at index %d (skipped=%d)",
                i, skipped))
            return found
        end
    end

    print(string.format("[RSDWTools] actor lookup: no match (skipped=%d of %d)",
        skipped, total))
    return nil
end

-- Primary actor lookup used by every public verb. Prefer the cached handle
-- (populated by a previous successful lookup) and only fall back to the full
-- FindAllOf walk when the cache is empty or the cached handle has gone stale.
--
-- Rationale: re-enumerating the entire UObject array on every action click
-- caused hard native AVs when the world was volatile (observed: after a
-- teleport followed by rapid vis toggles, FindAllOf itself crashed on the
-- second toggle of the same actor, before even returning to Lua). UE4SS
-- userdata is safe to hold on to across calls -- it internally tracks
-- (index, serial) and is_valid() will cleanly return false for destroyed or
-- reused slots without AVing.
local function resolve_actor(name)
    local cached = HANDLE_CACHE[name]
    if cached and is_valid(cached) then
        return cached
    end
    if cached then
        HANDLE_CACHE[name] = nil
    end
    local found = find_actor_by_exact_short_name(name)
    if found then
        HANDLE_CACHE[name] = found
    end
    return found
end

-- Exposed so sister features (e.g. feature_introspect) can reuse the cache
-- and validity guarantees without duplicating the lookup walk or the defensive
-- is_valid handling.
function M.resolve_actor_by_name(name)
    return resolve_actor(name)
end

function M.get_local_pawn()
    return get_local_pawn()
end

function M.is_valid_object(obj)
    return is_valid(obj)
end

-- Boolean coercion helper shared by visibility/collision verbs. Returns
-- true/false for explicit on/off, or nil for "toggle" when mode is missing.
local function parse_onoff(mode)
    if mode == nil then return nil end
    local m = tostring(mode):lower()
    if m == "on" or m == "1" or m == "true" then return true end
    if m == "off" or m == "0" or m == "false" then return false end
    return nil
end

-- ---------- public verbs ----------
--
-- CONTRACT: every verb below MUST be called from the game thread. The bridge
-- command dispatch in main.lua already runs router handlers inside
-- ExecuteInGameThread, so calling these directly from the router is correct.
-- Do NOT wrap the body in ExecuteInGameThread here: that call is asynchronous
-- and would cause this function to return immediately with nil before the
-- inner work has run, which was the original "actor.goto failed: nil" bug.

function M.goto_actor(name)
    print("[RSDWTools] actor.goto: enter name='" .. tostring(name) .. "'")
    local target = resolve_actor(name)
    if not target then
        return false, "no matching actor"
    end
    print("[RSDWTools] actor.goto: resolving local pawn")
    local pawn = get_local_pawn()
    if not pawn then
        return false, "no local pawn"
    end
    print("[RSDWTools] actor.goto: computing destination")
    local dest = location_above_actor(target, OFFSET_UP_GOTO)
    if not dest then
        return false, "could not compute destination"
    end
    print(string.format("[RSDWTools] actor.goto: moving pawn to %.2f %.2f %.2f",
        dest.X or 0, dest.Y or 0, dest.Z or 0))
    local ok_move, err = move_actor(pawn, dest)
    if not ok_move then
        return false, tostring(err or "move failed")
    end
    return true, name
end

function M.bring_actor(name)
    local target = resolve_actor(name)
    if not target then
        return false, "no matching actor"
    end
    local pawn = get_local_pawn()
    if not pawn then
        return false, "no local pawn"
    end
    local dest = location_in_front_of(pawn, OFFSET_FORWARD, OFFSET_UP_SPAWN)
    if not dest then
        return false, "could not compute destination"
    end
    local ok_move = select(1, move_actor(target, dest))
    if not ok_move then
        -- Some actors ship with a Static mobility root. Force to Movable and retry.
        force_actor_movable(target)
        ok_move = select(1, move_actor(target, dest))
    end
    if not ok_move then
        return false, "move failed"
    end
    return true, name
end

function M.delete_actor(name)
    local target = resolve_actor(name)
    if not target then
        return false, "no matching actor"
    end
    local pawn = get_local_pawn()
    if pawn and target == pawn then
        return false, "refusing to delete local pawn"
    end
    local ok = destroy_actor(target)
    if not ok then
        return false, "destroy failed"
    end
    -- Actor is gone; drop any cached state so a future actor that happens to
    -- land on the same name starts from a clean slate.
    VIS_STATE[name] = nil
    COL_STATE[name] = nil
    HANDLE_CACHE[name] = nil
    return true, name
end

function M.set_visibility(name, mode)
    local target = resolve_actor(name)
    if not target then
        return false, "no matching actor"
    end
    local explicit = parse_onoff(mode)
    local next_visible
    if explicit == nil then
        -- Toggle: prefer our own cached state. If the cache is empty (first
        -- toggle), anchor on the engine-reported state; if that's also
        -- unreadable, assume the actor is currently visible (the common case)
        -- so the first toggle predictably hides it.
        local cached = VIS_STATE[name]
        if cached == nil then
            local before_hidden = read_actor_hidden(target)
            if before_hidden == nil then
                cached = true
            else
                cached = not before_hidden
            end
        end
        next_visible = not cached
    else
        next_visible = explicit
    end
    local ok = set_actor_hidden(target, not next_visible)
    if not ok then
        return false, "hide call failed"
    end
    VIS_STATE[name] = next_visible
    return true, (next_visible and "visible" or "hidden")
end

function M.set_collision(name, mode)
    local target = resolve_actor(name)
    if not target then
        return false, "no matching actor"
    end
    local explicit = parse_onoff(mode)
    local next_enabled
    if explicit == nil then
        local cached = COL_STATE[name]
        if cached == nil then
            local before = read_actor_collision_enabled(target)
            if before == nil then
                cached = true
            else
                cached = before
            end
        end
        next_enabled = not cached
    else
        next_enabled = explicit
    end
    local ok = set_actor_collision_enabled(target, next_enabled)
    if not ok then
        return false, "collision call failed"
    end
    COL_STATE[name] = next_enabled
    return true, (next_enabled and "on" or "off")
end

function M.get_scale_uniform(name)
    local target = resolve_actor(name)
    if not target then
        return false, "no matching actor"
    end
    local scale = get_actor_scale3d(target)
    if not scale then
        return false, "could not read actor scale"
    end
    local x = tonumber(scale.X) or 0
    return true, string.format("%.6g", x)
end

function M.set_scale_uniform(name, value)
    local numeric = tonumber(value)
    if not numeric then
        return false, "scale value must be a number"
    end
    local target = resolve_actor(name)
    if not target then
        return false, "no matching actor"
    end
    local ok = set_actor_scale3d(target, { X = numeric, Y = numeric, Z = numeric })
    if not ok then
        return false, "scale call failed"
    end
    return true, string.format("%.6g", numeric)
end

-- ---------- Spectator camera (Round 11) ----------
-- APlayerController::SetViewTargetWithBlend lets us point the player's camera
-- at any actor in the world. Movement input still drives the actual pawn in
-- the background; this just detaches the render view. Calling it with our
-- own pawn (or nil) restores first-person / follow-cam.
--
-- Signature from the 67_PlayerController.json dump:
--   SetViewTargetWithBlend(NewViewTarget: AActor, BlendTime: float,
--                          BlendFunc: EViewTargetBlendFunction,
--                          BlendExp: float, bLockOutgoing: boolean)
-- EViewTargetBlendFunction::VTBlend_Linear = 0 (used here).

local function set_view_target(target, blend_time)
    local pc = get_local_player_controller()
    if not is_valid(pc) then return false, "no player controller" end
    local ok, err = pcall(function()
        pc:SetViewTargetWithBlend(target, blend_time or 0.5, 0, 0.0, false)
    end)
    if not ok then return false, "SetViewTargetWithBlend failed: " .. tostring(err) end
    return true
end

function M.spectate_actor(name)
    local target = resolve_actor(name)
    if not target then return false, "no matching actor" end
    local ok, err = set_view_target(target, 0.5)
    if not ok then return false, err end
    return true, "spectating " .. tostring(name)
end

function M.spectate_reset()
    -- Blending back to the local pawn snaps the camera home; the game's
    -- normal follow-cam logic takes over from the first tick.
    local pawn = get_local_pawn()
    if not is_valid(pawn) then return false, "no local pawn" end
    local ok, err = set_view_target(pawn, 0.3)
    if not ok then return false, err end
    return true, "reset"
end

-- Round 31: low-level transform helpers exposed for feature_grab.lua. These
-- are the same single-call paths used internally by goto_actor / bring_actor
-- / set_scale_uniform ; lifting them to the M. surface lets the grab loop
-- avoid re-resolving the actor by name on every tick.
function M.actor_location(actor) return actor_location(actor) end
function M.actor_rotation(actor) return actor_rotation(actor) end
function M.move_actor(actor, loc) return move_actor(actor, loc) end
function M.force_actor_movable(actor) force_actor_movable(actor) end
function M.set_actor_rotation(actor, rot)
    if not is_valid(actor) or not rot then return false end
    if actor.K2_SetActorRotation then
        local ok = pcall(function() actor:K2_SetActorRotation(rot, true) end)
        if ok then return true end
    end
    if actor.SetActorRotation then
        local ok = pcall(function() actor:SetActorRotation(rot) end)
        if ok then return true end
    end
    return false
end
function M.get_actor_scale3d(actor) return get_actor_scale3d(actor) end
function M.set_actor_scale3d(actor, vec) return set_actor_scale3d(actor, vec) end

-- Round 31: short-name extractor for an arbitrary actor handle. Used by
-- feature_grab to label actors picked up via line trace (no name was
-- typed by the user, so we derive one from GetFullName the same way the
-- scan output does).
function M.short_name_of(actor)
    local full = actor_full_name_safe(actor)
    if not full then return nil end
    return short_name_from_full(full)
end

return M
