-- feature_field.lua
--
-- Generic write verbs for the Mods catalog (Round 30 rewrite).
--
-- Verb shape changed from (root,path) to (reachSpec, fieldPath, value):
--   player.field.set         <reachSpec> <fieldPath> <value>
--   player.field.set_index   <reachSpec> <containerPath> <index> <value>
--   player.field.set_key     <reachSpec> <containerPath> <key>   <value>
--   player.field.set_object  <reachSpec> <fieldPath> <ClassShortName>
--   player.field.add         <reachSpec> <containerPath> <value>
--   player.field.remove      <reachSpec> <containerPath> <indexOrValue>
--   player.field.clear       <reachSpec> <containerPath>
--   player.field.call        <reachSpec> <fieldPath> [args...]
--
-- reachSpec grammar:
--   <rootKey>                          one of the registered roots
--   <rootKey>.<step>.<step>...         walk into nested objects from that root
--   subsystem:<ClassShortName>         find a live USubsystem instance
--   subsystem:<ClassShortName>.<step>  walk into a subsystem
--
-- Registered root keys (all engine-level, fixed contract):
--   pawn           UGameplayStatics::GetPlayerPawn(0)
--   controller     GetPlayerController(0)
--   playerstate    PlayerController->PlayerState
--   gamemode       World->GetAuthGameMode()
--   gamestate      World->GetGameState()
--   gameinstance   World->GetGameInstance()
--   localplayer    Controller->Player (the ULocalPlayer)
--   hud            Controller->GetHUD()
--   world          GetWorld()
--   worldsettings  World->K2_GetWorldSettings()
--
-- Anything beyond these (game-specific subsystems, components, sub-objects)
-- is reached either via subsystem:<Name> or via property walk steps. The
-- catalog has already computed the reach paths for every class ; the WPF
-- passes one of those paths in as <reachSpec>.
--
-- Path grammar inside <fieldPath> (unchanged from previous rounds):
--   .Field   member access
--   [N]      TArray index, 1-based
--   {Key}    TMap key (literal stringified key)
--
-- Failure is data: when a write fails we return (false, "<reason>") and
-- the UI surfaces the reason next to the row. We never retry, fall back,
-- or pretend a write succeeded.

local M = {}

local feature_actor = require("feature_actor")
local safety        = require("safety")

-- Maximum number of property steps in a single walk. Keeps a runaway
-- field path or accidentally-cyclic structure from spinning the game
-- thread. The catalog BFS is capped at depth 6 so any legitimate path
-- fits well under this. Tunable if a real use case needs more.
local MAX_WALK_DEPTH = 16

-- ---------- coercion helpers ----------

local function parse_bool(v)
    if type(v) == "boolean" then return v end
    local s = tostring(v or ""):lower()
    if s == "on" or s == "1" or s == "true" or s == "yes" then return true end
    if s == "off" or s == "0" or s == "false" or s == "no" then return false end
    return nil
end

local function parse_number(v)
    return tonumber(v)
end

local function is_valid(obj)
    return feature_actor.is_valid_object(obj)
end

-- ---------- helpers shared by the resolver registry -----------------------

-- Pull the local player's PlayerController. Delegated to feature_net
-- so all consumers in the mod converge on the same strict
-- IsLocalController()-based resolver (multiplayer-correct).
local feature_net = require("feature_net")
local function get_pc()
    return feature_net.local_controller()
end

local function get_world()
    local ok_req, ue = pcall(require, "UEHelpers")
    if ok_req and type(ue) == "table" and ue.GetWorld then
        local ok, w = pcall(function() return ue.GetWorld() end)
        if ok and is_valid(w) then return w end
    end
    -- Fallback: walk from controller -> world.
    local pc = get_pc()
    if pc then
        local ok, w = pcall(function() return pc:GetWorld() end)
        if ok and is_valid(w) then return w end
    end
    return nil
end

-- find_first_of: scan FindAllOf(<className>) and return the first valid
-- live instance. Used both for subsystem resolution (subsystem:<Name>) and
-- by player.field.set_object's class-as-value path.
local function find_first_of(name)
    if not FindAllOf then return nil, "FindAllOf unavailable" end
    local ok, list = pcall(FindAllOf, name)
    if not ok or not list then return nil, "FindAllOf failed for " .. name end
    local n = 0
    pcall(function() n = #list end)
    if n == 0 then
        local ok_num, num_val = pcall(function() return list:Num() end)
        if ok_num and type(num_val) == "number" then n = num_val end
    end
    for i = 1, n do
        local eok, entry = pcall(function() return list[i] end)
        if eok and type(entry) == "userdata" and is_valid(entry) then
            return entry
        end
    end
    return nil, "no live instance of " .. name
end

-- Module-private handle to "the actor most recently spawned via
-- world.spawn / world.spawn.item". Set by feature_player calling
-- M.set_last_spawned() right after FinishSpawningActor / SpawnAndLaunch.
-- Used by the `lastspawned` reach root so reskin / configure verbs can
-- target the just-spawned actor without needing a stable handle path.
-- Cleared automatically when the handle becomes invalid (actor destroyed,
-- world torn down) so a stale read surfaces as "not currently live"
-- rather than crashing inside :GetClass().
local _last_spawned = nil

function M.set_last_spawned(actor)
    _last_spawned = actor
end

-- Named bookmarks for actor handles. Solves the wiring problem : after
-- spawning a second actor, `lastspawned` rolls over and the first one
-- becomes unreachable. `world.bookmark <slot>` stashes the current
-- lastspawned under <slot> ; the `slot:<name>` reach-root resolves it
-- back. Bookmarks are lost on save/reload (UObject pointers don't
-- survive) which is fine -- recipient .sav doesn't need them, only the
-- live wiring session does.
local _bookmarks = {}

local function valid_slot_name(name)
    if type(name) ~= "string" or name == "" then return false end
    return name:match("^[%w_][%w_%-]*$") ~= nil
end

function M.bookmark_last_spawned(slot)
    if not valid_slot_name(slot) then
        return false, "invalid slot name '" .. tostring(slot) .. "' (use [A-Za-z0-9_-])"
    end
    if not _last_spawned or not is_valid(_last_spawned) then
        return false, "no live lastspawned actor to bookmark"
    end
    _bookmarks[slot] = _last_spawned
    return true, slot
end

function M.forget_bookmark(slot)
    if not valid_slot_name(slot) then
        return false, "invalid slot name"
    end
    if _bookmarks[slot] == nil then return false, "no such slot: " .. slot end
    _bookmarks[slot] = nil
    return true, slot
end

function M.list_bookmarks()
    local out = {}
    for slot, actor in pairs(_bookmarks) do
        local alive = (actor ~= nil) and is_valid(actor)
        out[#out + 1] = slot .. "=" .. (alive and "live" or "dead")
        if not alive then _bookmarks[slot] = nil end
    end
    table.sort(out)
    return out
end

-- Engine-defined root keys. Each resolver returns (obj | nil).
-- Ordering is alphabetical except for `world` which several others depend
-- on -- those use get_world() directly so the table itself stays a flat
-- key->resolver map.
local ROOTS = {
    lastspawned = function()
        if not _last_spawned then return nil end
        if not is_valid(_last_spawned) then
            _last_spawned = nil
            return nil
        end
        return _last_spawned
    end,
    pawn = function()
        return feature_actor.get_local_pawn()
    end,
    controller = function()
        return get_pc()
    end,
    playerstate = function()
        local pc = get_pc()
        if not pc then return nil end
        local ok, ps = pcall(function() return pc.PlayerState end)
        if ok and is_valid(ps) then return ps end
        return nil
    end,
    gamemode = function()
        local w = get_world()
        if not w then return nil end
        local ok, gm = pcall(function() return w:GetAuthGameMode() end)
        if ok and is_valid(gm) then return gm end
        return nil
    end,
    gamestate = function()
        local w = get_world()
        if not w then return nil end
        local ok, gs = pcall(function() return w.GameState end)
        if ok and is_valid(gs) then return gs end
        return nil
    end,
    gameinstance = function()
        local w = get_world()
        if not w then return nil end
        local ok, gi = pcall(function() return w.OwningGameInstance end)
        if ok and is_valid(gi) then return gi end
        return nil
    end,
    localplayer = function()
        local pc = get_pc()
        if not pc then return nil end
        local ok, lp = pcall(function() return pc.Player end)
        if ok and is_valid(lp) then return lp end
        return nil
    end,
    hud = function()
        local pc = get_pc()
        if not pc then return nil end
        local ok, h = pcall(function() return pc:GetHUD() end)
        if ok and is_valid(h) then return h end
        return nil
    end,
    lookat = function()
        local ok_req, feature_grab = pcall(require, "feature_grab")
        if not ok_req or not feature_grab or not feature_grab.pick_actor_under_reticle then
            return nil
        end
        local actor = nil
        pcall(function() actor = select(1, feature_grab.pick_actor_under_reticle()) end)
        if is_valid(actor) then return actor end
        return nil
    end,
    world = function()
        return get_world()
    end,
    worldsettings = function()
        local w = get_world()
        if not w then return nil end
        local ok, ws = pcall(function() return w:K2_GetWorldSettings() end)
        if ok and is_valid(ws) then return ws end
        return nil
    end,
}

-- ---------- path parsing ----------

local function parse_path(path)
    local steps = {}
    local i = 1
    local n = #path
    local function read_member(start)
        local j = start
        while j <= n do
            local c = path:sub(j, j)
            if c:match("[%w_]") then j = j + 1 else break end
        end
        if j == start then return nil, "expected identifier at " .. start end
        steps[#steps + 1] = { kind = "member", name = path:sub(start, j - 1) }
        return j
    end
    local function read_bracket(start)
        local close = path:find("]", start + 1, true)
        if not close then return nil, "missing ']' starting at " .. start end
        local raw = path:sub(start + 1, close - 1)
        local idx = tonumber(raw)
        if not idx then return nil, "non-numeric index '" .. raw .. "'" end
        steps[#steps + 1] = { kind = "index", index = idx }
        return close + 1
    end
    local function read_brace(start)
        local close = path:find("}", start + 1, true)
        if not close then return nil, "missing '}' starting at " .. start end
        local raw = path:sub(start + 1, close - 1)
        if raw == "" then return nil, "empty {} key" end
        steps[#steps + 1] = { kind = "key", key = raw }
        return close + 1
    end

    if n == 0 then return nil, "empty path" end
    if not path:sub(1, 1):match("[%w_]") then
        return nil, "path must start with identifier"
    end
    local pos, perr = read_member(1)
    if not pos then return nil, perr end
    while pos <= n do
        local c = path:sub(pos, pos)
        if c == "." then
            pos, perr = read_member(pos + 1); if not pos then return nil, perr end
        elseif c == "[" then
            pos, perr = read_bracket(pos); if not pos then return nil, perr end
        elseif c == "{" then
            pos, perr = read_brace(pos); if not pos then return nil, perr end
        else
            return nil, "unexpected '" .. c .. "' at " .. pos
        end
    end
    return steps
end

local function step_into(obj, step)
    -- Round 54 hardening: never deref non-uobject userdata. The
    -- previous probe crash (BuildingAPI.PreviewBuildPiece walk) came
    -- from indexing a stale wrapper that pcall couldn't catch because
    -- the access violation was in C++ land. Cheap pre-check here cuts
    -- the whole class of crash.
    if type(obj) == "userdata" and not safety.is_uobject(obj) then
        local kind = safety.classify(obj) or "unknown"
        local safe_to_step = (kind == "soft_ref") or (kind == "tarray") or (kind == "text_like")
        if not safe_to_step then
            return nil, "refused to step into unsafe userdata (kind=" .. kind .. ")"
        end
    end
    -- If the current node is a soft/lazy ref wrapper, unwrap it once
    -- before reading the next step. Walking *into* the wrapper itself
    -- via `wrapper.Field` can dereference invalid memory ; the safe
    -- shape is `wrapper:Get()` then index the resolved object.
    if safety.classify(obj) == "soft_ref" then
        local ok_g, inner = safety.guard(function() return obj:Get() end)
        if ok_g and inner ~= nil then
            obj = inner
        end
    end
    if step.kind == "member" then
        local ok, v = pcall(function() return obj[step.name] end)
        if not ok then return nil, "read of '" .. step.name .. "' raised" end
        return v
    elseif step.kind == "index" then
        local ok, v = pcall(function() return obj[step.index] end)
        if not ok then return nil, "index [" .. step.index .. "] raised" end
        return v
    elseif step.kind == "key" then
        local ok, v = pcall(function() return obj[step.key] end)
        if ok and v ~= nil then return v end
        local ok2, v2 = pcall(function() return obj:Find(step.key) end)
        if ok2 and v2 ~= nil then return v2 end
        return nil, "key {" .. step.key .. "} not found"
    end
    return nil, "unknown step kind: " .. tostring(step.kind)
end

-- Walk all steps and return the final object (used by `add` / `remove` /
-- `clear` where the leaf IS the container) ; or walk all-but-last and
-- return (parent, leaf) (used by `set` / `set_object` / `call` where the
-- leaf is the assignment / call target).
--
-- Bounded by MAX_WALK_DEPTH so a malformed or pathological path can't
-- spin the game thread. Also tracks visited userdata pointers to break
-- accidental cycles (rare but possible via owner back-references).
local function walk_full(obj, steps)
    if #steps > MAX_WALK_DEPTH then
        return nil, "walk too deep: " .. #steps .. " > " .. MAX_WALK_DEPTH
    end
    local seen = {}
    local cur = obj
    for i = 1, #steps do
        if type(cur) == "userdata" then
            local id = tostring(cur)
            if seen[id] then
                return nil, "walk cycle detected at step " .. i
            end
            seen[id] = true
        end
        local nxt, err = step_into(cur, steps[i])
        if nxt == nil then
            return nil, "walk failed at step " .. i .. " (" .. (err or "nil") .. ")"
        end
        cur = nxt
    end
    return cur
end

local function walk_to_parent(obj, steps)
    if #steps == 0 then return nil, nil, "empty step list" end
    if #steps > MAX_WALK_DEPTH then
        return nil, nil, "walk too deep: " .. #steps .. " > " .. MAX_WALK_DEPTH
    end
    local seen = {}
    local cur = obj
    for i = 1, #steps - 1 do
        if type(cur) == "userdata" then
            local id = tostring(cur)
            if seen[id] then
                return nil, nil, "walk cycle detected at step " .. i
            end
            seen[id] = true
        end
        local nxt, err = step_into(cur, steps[i])
        if nxt == nil then
            return nil, nil, "walk failed at step " .. i .. " (" .. (err or "nil") .. ")"
        end
        cur = nxt
    end
    return cur, steps[#steps]
end

-- ---------- reachSpec resolution -----------------------------------------
--
-- reachSpec syntax: "<rootKey>" or "<rootKey>.<step>.<step>..."
-- The rootKey segment may itself contain a colon (subsystem:<Name>), but
-- never a dot. We split on the first dot to peel off the rootKey, then
-- re-parse the remainder as a normal field path.
--
-- Returns (live_obj | nil, err)

local function split_reach_spec(reach_spec)
    local first_dot = reach_spec:find(".", 1, true)
    if first_dot then
        return reach_spec:sub(1, first_dot - 1), reach_spec:sub(first_dot + 1)
    end
    return reach_spec, nil
end

local function resolve_root_key(root_key)
    if root_key:sub(1, 10) == "subsystem:" then
        local short = root_key:sub(11)
        if short == "" then return nil, "subsystem: missing class name" end
        local obj, err = find_first_of(short)
        if not obj then return nil, "subsystem '" .. short .. "': " .. tostring(err) end
        return obj
    end
    -- slot:<name> -- resolves to an actor previously stashed via
    -- `world.bookmark <name>`. Lets wiring verbs reference a non-
    -- lastspawned actor without needing GUID lookups. Stale slot
    -- (actor destroyed) auto-clears here so callers get a clean
    -- "no such slot" instead of a crash inside is_valid.
    if root_key:sub(1, 5) == "slot:" then
        local name = root_key:sub(6)
        if name == "" then return nil, "slot: missing name" end
        local obj = _bookmarks[name]
        if obj == nil then return nil, "no bookmark '" .. name .. "'" end
        if not is_valid(obj) then
            _bookmarks[name] = nil
            return nil, "bookmark '" .. name .. "' actor no longer live"
        end
        return obj
    end
    -- find:<ClassShortName> -- universal "any live instance" probe.
    -- Used as a fallback for classes that have no static reach path
    -- (multi-instance actors, components without a singleton owner,
    -- gameplay/data classes, blueprint subclasses created on the fly).
    -- Tries the name as given first, then with a `_C` suffix because
    -- blueprint UClasses usually live in the FindAllOf index under their
    -- compiled-class name. We never auto-strip `_C` so a literal
    -- `find:Foo_C` query keeps its precise form.
    if root_key:sub(1, 5) == "find:" then
        local short = root_key:sub(6)
        if short == "" then return nil, "find: missing class name" end
        local obj, err = find_first_of(short)
        if obj then return obj end
        -- Skip the `_C` retry when FindAllOf itself raised on the bare
        -- name. A raise indicates the name doesn't resolve to a real
        -- UClass (e.g. UScriptStruct named the same), and a second call
        -- with `_C` appended will likely take the engine down the same
        -- way. Only retry when the bare call cleanly reported "no live
        -- instance" -- that's the case where a blueprint compiled-class
        -- name might actually exist.
        local err_str = tostring(err or "")
        local find_raised = err_str:find("FindAllOf failed", 1, true) ~= nil
        if not find_raised and not short:find("_C$") then
            local obj2, err2 = find_first_of(short .. "_C")
            if obj2 then return obj2 end
            return nil, "find '" .. short .. "': " .. err_str ..
                " ; with _C: " .. tostring(err2)
        end
        return nil, "find '" .. short .. "': " .. err_str
    end
    local resolver = ROOTS[root_key]
    if not resolver then
        return nil, "unknown root key '" .. root_key .. "'"
    end
    local ok, obj = pcall(resolver)
    if not ok then return nil, "root '" .. root_key .. "': resolver raised: " .. tostring(obj) end
    if not obj then return nil, "root '" .. root_key .. "': not currently live" end
    if not is_valid(obj) then return nil, "root '" .. root_key .. "': resolved to invalid handle" end
    return obj
end

-- Public: WPF-side or feature_probe.lua call into here to get a live
-- target for any reachSpec the catalog produced.
function M.resolve_root(reach_spec)
    if not reach_spec or reach_spec == "" then
        return nil, "empty reachSpec"
    end
    local root_key, rest = split_reach_spec(reach_spec)
    local root_obj, rerr = resolve_root_key(root_key)
    if not root_obj then return nil, rerr end
    if not rest then return root_obj end

    local steps, perr = parse_path(rest)
    if not steps then return nil, "reach path parse: " .. perr end
    local final, walk_err = walk_full(root_obj, steps)
    if not final then return nil, walk_err end
    if not is_valid(final) then return nil, "reach walk: leaf is not a valid object" end
    return final
end

-- Convenience: also expose a class-name reader so the probe can describe
-- what the live target actually is. Delegates to the safety module so
-- non-UObject userdata (FText, FName, FString, native structs) can never
-- reach :GetClass(), which would be an unrecoverable C++ AV.
function M.class_name_of(obj)
    if not is_valid(obj) then return nil end
    return safety.class_name_of(obj)
end

-- Public: read the live value at <reachSpec> + <fieldPath>. Used by the
-- WPF to prefill row editors with what the field currently holds. Returns
-- (value | nil, err). The leaf goes through safety.read_primitive() so
-- text-shaped userdata (FText/FName/FString) becomes a flat string and
-- non-UObject userdata becomes a short descriptor instead of crashing.
function M.read(reach_spec, field_path)
    local target, rerr = M.resolve_root(reach_spec)
    if not target then return nil, rerr end
    if not field_path or field_path == "" then
        return M.class_name_of(target) or "<unknown>"
    end
    local steps, perr = parse_path(field_path)
    if not steps then return nil, "field path parse: " .. perr end
    local val, walk_err = walk_full(target, steps)
    if walk_err then return nil, walk_err end
    if val == nil then return nil, "field is nil" end
    local rv, _kind = safety.read_primitive(val)
    if rv == nil then return nil, "field is nil" end
    return rv
end

-- ---------- write helpers ----------

local function coerce_and_write(parent, leaf_step, raw_value)
    local function do_assign(v)
        if leaf_step.kind == "member" then
            return pcall(function() parent[leaf_step.name] = v end)
        elseif leaf_step.kind == "index" then
            return pcall(function() parent[leaf_step.index] = v end)
        elseif leaf_step.kind == "key" then
            return pcall(function() parent[leaf_step.key] = v end)
        end
        return false, "unknown leaf kind"
    end

    local b = parse_bool(raw_value)
    if b ~= nil then
        local ok, err = do_assign(b)
        if not ok then return false, "bool write failed: " .. tostring(err) end
        return true, "bool", b
    end
    local n = parse_number(raw_value)
    if n then
        local ok, err = do_assign(n)
        if not ok then return false, "number write failed: " .. tostring(err) end
        return true, "number", n
    end
    local ok, err = do_assign(tostring(raw_value))
    if not ok then return false, "string write failed: " .. tostring(err) end
    return true, "string", tostring(raw_value)
end

local function leaf_describe(leaf_step)
    if leaf_step.kind == "member" then return leaf_step.name end
    if leaf_step.kind == "index"  then return "[" .. leaf_step.index .. "]" end
    if leaf_step.kind == "key"    then return "{" .. leaf_step.key .. "}" end
    return "?"
end

local function coerce_token(s)
    local b = parse_bool(s);   if b ~= nil then return b end
    local n = parse_number(s); if n then return n end
    return s
end

-- ---------- public verbs ---------------------------------------------------

-- player.field.set <reachSpec> <fieldPath> <value>
function M.set(args_str)
    if not args_str or args_str == "" then
        return false, "usage: player.field.set <reachSpec> <fieldPath> <value>"
    end
    local reach_spec, field_path, value = args_str:match("^(%S+)%s+(%S+)%s+(.+)$")
    if not (reach_spec and field_path and value) then
        return false, "usage: player.field.set <reachSpec> <fieldPath> <value>"
    end
    local target, rerr = M.resolve_root(reach_spec)
    if not target then return false, rerr end
    local steps, perr = parse_path(field_path)
    if not steps then return false, "field path parse: " .. perr end
    local parent, leaf, walk_err = walk_to_parent(target, steps)
    if not parent then return false, walk_err end
    local ok, kind, coerced = coerce_and_write(parent, leaf, value)
    if not ok then return false, kind end
    if kind == "number" then
        return true, string.format("%s.%s = %.6g (%s)", reach_spec, field_path, coerced, kind)
    end
    return true, string.format("%s.%s = %s (%s)", reach_spec, field_path, tostring(coerced), kind)
end

-- player.field.set_index <reachSpec> <containerPath> <index> <value>
function M.set_index(args_str)
    if not args_str or args_str == "" then
        return false, "usage: player.field.set_index <reachSpec> <containerPath> <index> <value>"
    end
    local reach_spec, container_path, idx_str, value = args_str:match("^(%S+)%s+(%S+)%s+(%S+)%s+(.+)$")
    if not (reach_spec and container_path and idx_str and value) then
        return false, "usage: player.field.set_index <reachSpec> <containerPath> <index> <value>"
    end
    local idx = tonumber(idx_str)
    if not idx then return false, "index must be numeric (1-based)" end
    local synthetic = container_path .. "[" .. idx .. "]"
    return M.set(reach_spec .. " " .. synthetic .. " " .. value)
end

-- player.field.set_key <reachSpec> <containerPath> <key> <value>
function M.set_key(args_str)
    if not args_str or args_str == "" then
        return false, "usage: player.field.set_key <reachSpec> <containerPath> <key> <value>"
    end
    local reach_spec, container_path, key, value = args_str:match("^(%S+)%s+(%S+)%s+(%S+)%s+(.+)$")
    if not (reach_spec and container_path and key and value) then
        return false, "usage: player.field.set_key <reachSpec> <containerPath> <key> <value>"
    end
    if key:find("[{}]") then return false, "key cannot contain '{' or '}'" end
    local synthetic = container_path .. "{" .. key .. "}"
    return M.set(reach_spec .. " " .. synthetic .. " " .. value)
end

-- player.field.set_object <reachSpec> <fieldPath> <ClassShortName>
function M.set_object(args_str)
    if not args_str or args_str == "" then
        return false, "usage: player.field.set_object <reachSpec> <fieldPath> <ClassShortName>"
    end
    local reach_spec, field_path, class_name = args_str:match("^(%S+)%s+(%S+)%s+(%S+)$")
    if not (reach_spec and field_path and class_name) then
        return false, "usage: player.field.set_object <reachSpec> <fieldPath> <ClassShortName>"
    end
    local source, terr = find_first_of(class_name)
    if not source then return false, "target lookup: " .. tostring(terr) end
    local target, rerr = M.resolve_root(reach_spec)
    if not target then return false, rerr end
    local steps, perr = parse_path(field_path)
    if not steps then return false, "field path parse: " .. perr end
    local parent, leaf, walk_err = walk_to_parent(target, steps)
    if not parent then return false, walk_err end
    local ok, werr = pcall(function()
        if leaf.kind == "member" then parent[leaf.name]  = source
        elseif leaf.kind == "index" then parent[leaf.index] = source
        elseif leaf.kind == "key"   then parent[leaf.key]   = source
        end
    end)
    if not ok then return false, "object write failed: " .. tostring(werr) end
    return true, string.format("%s.%s = <%s>", reach_spec, field_path, class_name)
end

-- player.field.set_asset <reachSpec> <fieldPath> <assetPath>
--
-- LoadObject the asset at <assetPath> (e.g. /Game/.../SM_Foo.SM_Foo) and
-- assign the resulting UObject reference into <fieldPath>. This is the
-- backbone of approach A : reskin a spawned host actor by overwriting
-- its StaticMeshComponent.StaticMesh (or any other UObject* property).
--
-- Differs from set_object (which finds a live instance of a class) and
-- set (which writes coerced primitives). Asset-typed properties want a
-- pointer to the loaded asset object itself.
--
-- Example:
--   player.field.set_asset lastspawned StaticMeshComponent.StaticMesh \
--     /Game/Gameplay/World/Rocks/SM_Cliff_01.SM_Cliff_01
function M.set_asset(args_str)
    if not args_str or args_str == "" then
        return false, "usage: player.field.set_asset <reachSpec> <fieldPath> <assetPath>"
    end
    local reach_spec, field_path, asset_path = args_str:match("^(%S+)%s+(%S+)%s+(%S+)$")
    if not (reach_spec and field_path and asset_path) then
        return false, "usage: player.field.set_asset <reachSpec> <fieldPath> <assetPath>"
    end
    -- Resolve the asset. Three-stage : LoadObject (already-mounted
    -- package, fastest), LoadAsset (UE4SS-specific async loader that
    -- handles unmounted/streaming chunks ; required for assets in
    -- districts the player isn't currently in), then StaticFindObject
    -- as the no-load fallback. Without LoadAsset, anything outside the
    -- player's current chunk gets reported as "asset lookup failed".
    local asset
    if LoadObject then
        local ok, o = pcall(LoadObject, asset_path)
        if ok and o then asset = o end
    end
    if (not asset) and LoadAsset then
        local ok, o = pcall(LoadAsset, asset_path)
        if ok and o then asset = o end
    end
    if (not asset) and StaticFindObject then
        local ok, o = pcall(StaticFindObject, asset_path)
        if ok and o then asset = o end
    end
    if not asset or not is_valid(asset) then
        return false, "asset lookup failed (LoadObject + LoadAsset + StaticFindObject all returned nil): " .. tostring(asset_path)
    end
    local target, rerr = M.resolve_root(reach_spec)
    if not target then return false, rerr end
    local steps, perr = parse_path(field_path)
    if not steps then return false, "field path parse: " .. perr end
    local parent, leaf, walk_err = walk_to_parent(target, steps)
    if not parent then return false, walk_err end
    -- Direct field assignment writes the property but does NOT invalidate
    -- the component's cached render state, so the mesh keeps drawing the
    -- old asset. Component subobjects expose SetStaticMesh / SetSkeletalMesh
    -- methods that handle the render-state update for us. Try the setter
    -- first (most common case : leaf is `StaticMesh` or `SkeletalMesh` on
    -- a *Component parent), fall back to direct assignment for non-mesh
    -- asset properties (textures, materials, sound cues, etc.).
    local ok, werr = pcall(function()
        if leaf.kind == "member" then
            if leaf.name == "StaticMesh" and parent.SetStaticMesh then
                parent:SetStaticMesh(asset)
                return
            end
            if leaf.name == "SkeletalMesh" and parent.SetSkeletalMesh then
                parent:SetSkeletalMesh(asset, true)
                return
            end
            if leaf.name == "SkeletalMeshAsset" and parent.SetSkeletalMeshAsset then
                parent:SetSkeletalMeshAsset(asset, true)
                return
            end
            parent[leaf.name] = asset
        elseif leaf.kind == "index"  then parent[leaf.index] = asset
        elseif leaf.kind == "key"    then parent[leaf.key]   = asset
        end
    end)
    if not ok then return false, "asset write failed: " .. tostring(werr) end
    return true, string.format("%s.%s = <asset %s>", reach_spec, field_path, asset_path)
end

-- player.field.add <reachSpec> <containerPath> <value>
function M.add(args_str)
    if not args_str or args_str == "" then
        return false, "usage: player.field.add <reachSpec> <containerPath> <value>"
    end
    local reach_spec, container_path, value = args_str:match("^(%S+)%s+(%S+)%s+(.+)$")
    if not (reach_spec and container_path and value) then
        return false, "usage: player.field.add <reachSpec> <containerPath> <value>"
    end
    local target, rerr = M.resolve_root(reach_spec)
    if not target then return false, rerr end
    local steps, perr = parse_path(container_path)
    if not steps then return false, "container path parse: " .. perr end
    local container, walk_err = walk_full(target, steps)
    if not container then return false, walk_err end
    -- Round 55 : if `value` looks like a reach-root spec (lastspawned,
    -- slot:foo, pawn, etc.), resolve it to the live UObject before
    -- handing to TArray::Add. Otherwise object arrays get fed a bare
    -- string and UE4SS's TArray adapter interprets it as an index
    -- ("TArray index out of range"). Anything that doesn't resolve
    -- falls through to coerce_token so scalar arrays (FString, int,
    -- gameplay tag) still work as before.
    local v
    local resolved = M.resolve_root(value)
    if resolved ~= nil and is_valid(resolved) then
        v = resolved
    else
        v = coerce_token(value)
    end
    local ok, werr = pcall(function() container:Add(v) end)
    if ok then return true, string.format("%s.%s :Add(%s)", reach_spec, container_path, tostring(v)) end
    local ok2, werr2 = pcall(function() container:AddTag(v) end)
    if ok2 then return true, string.format("%s.%s :AddTag(%s)", reach_spec, container_path, tostring(v)) end
    -- Round 55b : UE4SS TArray adapter doesn't expose :Add for plain
    -- TArray<UObject*> -- the method-name lookup falls through to the
    -- numeric __index handler and raises "TArray index out of range".
    -- Fall back to append-via-indexed-write : container[Num+1] = v.
    -- UE4SS auto-grows the TArray when assigning past the current end.
    local n
    local ok_n, num = pcall(function() return container:Num() end)
    if ok_n and type(num) == "number" then n = num else n = 0 end
    local ok3, werr3 = pcall(function() container[n + 1] = v end)
    if ok3 then return true, string.format("%s.%s [%d] = %s (appended)", reach_spec, container_path, n + 1, tostring(v)) end
    return false, "add failed: " .. tostring(werr) .. " / " .. tostring(werr2) .. " / " .. tostring(werr3)
end

-- player.field.remove <reachSpec> <containerPath> <indexOrValue>
function M.remove(args_str)
    if not args_str or args_str == "" then
        return false, "usage: player.field.remove <reachSpec> <containerPath> <indexOrValue>"
    end
    local reach_spec, container_path, arg = args_str:match("^(%S+)%s+(%S+)%s+(.+)$")
    if not (reach_spec and container_path and arg) then
        return false, "usage: player.field.remove <reachSpec> <containerPath> <indexOrValue>"
    end
    local target, rerr = M.resolve_root(reach_spec)
    if not target then return false, rerr end
    local steps, perr = parse_path(container_path)
    if not steps then return false, "container path parse: " .. perr end
    local container, walk_err = walk_full(target, steps)
    if not container then return false, walk_err end
    local idx = tonumber(arg)
    if idx then
        local zero = math.floor(idx) - 1
        local ok, werr = pcall(function() container:RemoveAt(zero) end)
        if ok then return true, string.format("%s.%s :RemoveAt(%d)", reach_spec, container_path, idx) end
        return false, "RemoveAt failed: " .. tostring(werr)
    end
    local v = coerce_token(arg)
    local ok, werr = pcall(function() container:Remove(v) end)
    if ok then return true, string.format("%s.%s :Remove(%s)", reach_spec, container_path, tostring(v)) end
    local ok2, werr2 = pcall(function() container:RemoveTag(v) end)
    if ok2 then return true, string.format("%s.%s :RemoveTag(%s)", reach_spec, container_path, tostring(v)) end
    return false, "remove failed: " .. tostring(werr) .. " / " .. tostring(werr2)
end

-- player.field.clear <reachSpec> <containerPath>
function M.clear(args_str)
    if not args_str or args_str == "" then
        return false, "usage: player.field.clear <reachSpec> <containerPath>"
    end
    local reach_spec, container_path = args_str:match("^(%S+)%s+(%S+)$")
    if not (reach_spec and container_path) then
        return false, "usage: player.field.clear <reachSpec> <containerPath>"
    end
    local target, rerr = M.resolve_root(reach_spec)
    if not target then return false, rerr end
    local steps, perr = parse_path(container_path)
    if not steps then return false, "container path parse: " .. perr end
    local container, walk_err = walk_full(target, steps)
    if not container then return false, walk_err end
    local ok, werr = pcall(function() container:Empty() end)
    if ok then return true, string.format("%s.%s :Empty()", reach_spec, container_path) end
    local ok2, werr2 = pcall(function() container:Reset() end)
    if ok2 then return true, string.format("%s.%s :Reset()", reach_spec, container_path) end
    return false, "clear failed: " .. tostring(werr) .. " / " .. tostring(werr2)
end

-- player.field.call <reachSpec> <fieldPath> [args...]
function M.call(args_str)
    if not args_str or args_str == "" then
        return false, "usage: player.field.call <reachSpec> <fieldPath> [args...]"
    end
    local reach_spec, rest = args_str:match("^(%S+)%s+(.+)$")
    if not (reach_spec and rest) then
        return false, "usage: player.field.call <reachSpec> <fieldPath> [args...]"
    end
    local field_path, tail = rest:match("^(%S+)%s*(.*)$")
    if not field_path or field_path == "" then return false, "missing path" end

    local target, rerr = M.resolve_root(reach_spec)
    if not target then return false, rerr end
    local steps, perr = parse_path(field_path)
    if not steps then return false, "field path parse: " .. perr end
    local parent, leaf, walk_err = walk_to_parent(target, steps)
    if not parent then return false, walk_err end
    if leaf.kind ~= "member" then
        return false, "callable leaf must be a method name (member)"
    end

    local arg_strs = {}
    for tok in tail:gmatch("%S+") do arg_strs[#arg_strs + 1] = tok end
    local coerced = {}
    for i, s in ipairs(arg_strs) do
        local resolved = M.resolve_root(s)
        if resolved ~= nil and is_valid(resolved) then
            coerced[i] = resolved
        else
            local b = parse_bool(s)
            if b ~= nil then coerced[i] = b
            else
                local n = parse_number(s)
                if n then coerced[i] = n
                else coerced[i] = s end
            end
        end
    end

    local ok, ret = pcall(function()
        local fn = parent[leaf.name]
        if type(fn) == "function" then
            return fn(parent, table.unpack(coerced))
        end
        return parent[leaf.name](parent, table.unpack(coerced))
    end)
    if not ok then return false, "call failed: " .. tostring(ret) end
    return true, string.format("%s.%s(...) = %s", reach_spec, field_path, tostring(ret))
end

return M
