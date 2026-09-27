-- feature_probe.lua
--
-- Runtime resolver for catalog reach paths. The dumper computes every
-- statically-discoverable way to reach a class from an engine root ; this
-- module asks the live game whether each candidate path resolves to an
-- actual UObject, and if so reports its concrete class name.
--
-- Verbs:
--   probe.resolve <reachSpec>
--   probe.read    <reachSpec> <fieldPath>
--
-- reachSpec grammar matches feature_field.resolve_root() ; <fieldPath>
-- matches the field-path grammar used by the field write verbs.
--
-- ----- Crash-resilience model ------------------------------------------
--
-- UE4SS surfaces several kinds of values as `userdata` (FText, FName,
-- FString, native structs, lazy/soft refs) where the UObject method
-- shape DOES NOT apply. Calling :GetClass() on those is an unrecoverable
-- C++ access violation that pcall cannot catch ; the game process dies
-- and the user loses session state.
--
-- We mitigate this in two layers:
--   1. The `safety` module classifies any value before we touch it and
--      routes access through shape-appropriate accessors. New crash
--      classes get fixed by adding a rule there, never a name-based
--      deny list. See safety.lua for details.
--   2. Every probe writes a small sentinel file before doing the
--      actual call and clears it immediately after success. If the
--      mod boots and finds an unclean sentinel, that means the
--      previous probe took the engine down ; we record the offending
--      (verb, args) tuple to a crash log so the failure is visible
--      and we can add a classifier rule. The sentinel itself is never
--      consulted to decide what to skip ; it exists purely so failures
--      become loud instead of mysterious.
--
-- The WPF calls these verbs once per reachPath candidate per selected
-- class and uses the results to render the live-target strip + decide
-- which candidates to enable inline editors against. Cached per-session
-- at the WPF layer ; we don't cache here because state can change at
-- any moment (level streaming, subsystem teardown, etc.).

local M = {}

local feature_field = require("feature_field")
local safety        = require("safety")
local mod_paths     = require("mod_paths")

-- ---------- helpers -----------------------------------------------------

-- Trim leading/trailing whitespace ; some send paths add an extra space
-- between the verb and its arg and we don't want that to fail parsing.
local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ---------- sentinel + crash-log plumbing ------------------------------

-- The sentinel records exactly one in-flight probe at a time. Format is
-- a single line of `<unix_ts>\t<verb>\t<args>` so the boot-time check
-- can recover (verb, args) if we crashed mid-call. The body is small on
-- purpose: this file is rewritten on every probe and we don't want disk
-- I/O to dominate the probe cost.
local function sentinel_write(verb, args)
    local path = mod_paths.sentinel_file()
    if not path then return end
    local ts = tostring(os.time())
    local body = ts .. "\t" .. tostring(verb) .. "\t" .. tostring(args or "")
    pcall(function() mod_paths.write_atomic(path, body) end)
end

local function sentinel_clear()
    local path = mod_paths.sentinel_file()
    if not path then return end
    pcall(function() mod_paths.remove_file(path) end)
end

local function crash_log_append(line)
    local path = mod_paths.crash_log_file()
    if not path then return end
    pcall(function() mod_paths.append_line(path, line) end)
end

-- Module-private flag so we only do the boot-time sentinel sweep once
-- per game session, on the very first probe call. Doing it eagerly at
-- require() time would race the IterateGameDirectories availability
-- check inside mod_paths.
local _boot_check_done = false

-- (Round 32) In-memory set of (verb, args) tuples we've already seen
-- crash this install. Populated lazily from probe_crash.log on first
-- probe call ; new crashes get added in real time as they happen so
-- the same probe doesn't take the engine down twice in one session.
-- Key format: "<verb>\0<args>".
local _crash_skip = {}
local function crash_key(verb, args) return tostring(verb) .. "\0" .. tostring(args or "") end

-- Parse one line from the crash log into (verb, args) if it looks like
-- a known shape. We tolerate any leading text up to and including the
-- first occurrence of one of our verb names ; the rest is the args.
-- Returns nil if the line is informational and shouldn't seed the set.
local function parse_crash_line(line)
    if not line or line == "" then return nil end
    -- Boot-time prior-crash record:
    --   "[<ts>] PRIOR CRASH probe sentinel survived: <unix>\t<verb>\t<args>"
    local v, a = line:match("PRIOR CRASH probe sentinel survived:%s*%S+%s+(%S+)%s+(.*)$")
    if v then return v, (a or ""):gsub("%s+$", "") end
    -- Lua-error record:
    --   "[<ts>] LUA ERROR <verb> '<args>' -> <err>"
    v, a = line:match("LUA ERROR%s+(%S+)%s+'(.-)'")
    if v then return v, a end
    return nil
end

local function load_crash_skip()
    local path = mod_paths.crash_log_file()
    if not path then return end
    local body = mod_paths.read_file(path)
    if not body or body == "" then return end
    for line in body:gmatch("[^\r\n]+") do
        local v, a = parse_crash_line(line)
        if v then _crash_skip[crash_key(v, a)] = true end
    end
end
local function ensure_boot_check()
    if _boot_check_done then return end
    _boot_check_done = true
    -- Seed the in-memory skip set from any prior session's crash log
    -- BEFORE we look at the sentinel, so a survived sentinel adds to
    -- a populated set rather than starting from empty.
    load_crash_skip()
    local path = mod_paths.sentinel_file()
    if not path then return end
    local body = mod_paths.read_file(path)
    if not body or body == "" then return end
    -- A non-empty sentinel at boot means the previous probe took the
    -- engine down before it could clear the file. Record it so the
    -- failure mode is visible and a classifier rule can be added.
    local stamp = os.date("%Y-%m-%d %H:%M:%S")
    local line  = "[" .. stamp .. "] PRIOR CRASH probe sentinel survived: " .. body
    crash_log_append(line)
    -- Also seed the skip set directly so we don't have to re-parse.
    local _, verb, args = body:match("^(%S+)%s+(%S+)%s+(.*)$")
    if verb then _crash_skip[crash_key(verb, args or "")] = true end
    if RSDWTOOLS_PROBE_DEBUG then
        print("[RSDWTools][probe] " .. line)
    end
    pcall(function() mod_paths.remove_file(path) end)
end

-- Wrap the actual probe body. Writes sentinel, runs `body()`, clears
-- sentinel on return. `body()` must return the (ok, detail) tuple the
-- public verb is expected to return ; we forward it unchanged.
local function with_sentinel(verb, args, body)
    ensure_boot_check()
    -- (Round 32) Refuse to repeat a probe whose (verb, args) tuple has
    -- previously taken the engine down. The skip set is loaded from
    -- probe_crash.log on first call ; user can wipe the log to retry.
    -- This is the WPF row's signal to render the row as "Skipped".
    if _crash_skip[crash_key(verb, args)] then
        return false, "skipped: prior crash on this probe (clear probe_crash.log to retry)"
    end
    sentinel_write(verb, args)
    local ok, a, b = pcall(body)
    sentinel_clear()
    if not ok then
        crash_log_append(string.format("[%s] LUA ERROR %s '%s' -> %s",
            os.date("%Y-%m-%d %H:%M:%S"), verb, tostring(args), tostring(a)))
        _crash_skip[crash_key(verb, args)] = true
        return false, "probe raised: " .. tostring(a)
    end
    return a, b
end

-- ---------- public verbs ------------------------------------------------

function M.resolve(args_str)
    local reach_spec = trim(args_str)
    if reach_spec == "" then
        return false, "usage: probe.resolve <reachSpec>"
    end
    return with_sentinel("probe.resolve", reach_spec, function()
        local obj, err = feature_field.resolve_root(reach_spec)
        if not obj then return false, err end
        local class_name = safety.class_name_of(obj) or "UnknownClass"
        return true, class_name
    end)
end

-- probe.read <reachSpec> <fieldPath>
--
-- Returns the live value at the given field as a flat ack body, so the
-- WPF can prefill its row editor with the current in-game value the
-- moment a Live target is selected. The body shape is just the rendered
-- value (no leading key) ; failure surfaces as (false, "<reason>") and
-- the WPF leaves the editor blank in that case.
function M.read(args_str)
    local s = trim(args_str)
    if s == "" then
        return false, "usage: probe.read <reachSpec> <fieldPath>"
    end
    local reach_spec, field_path = s:match("^(%S+)%s+(.+)$")
    if not reach_spec then
        return false, "usage: probe.read <reachSpec> <fieldPath>"
    end
    return with_sentinel("probe.read", s, function()
        local val, err = feature_field.read(reach_spec, field_path)
        if val == nil then return false, err end
        if type(val) == "boolean" then return true, val and "true" or "false" end
        if type(val) == "number"  then return true, tostring(val) end
        return true, tostring(val)
    end)
end

-- probe.find_class <objectPath>
--
-- Locates a UClass by full UE object path (works for both /Script/...
-- native classes and /Game/... blueprint-generated classes) and prints
-- the live UObject pointer plus its short class name. Used to grab the
-- class handle that callers can then feed into UFUNCTIONs taking a
-- TSubclassOf<...> parameter (e.g. UDominionGameplayEffectsComponent
-- ::InstantiateGameplayEffect).
--
-- Examples:
--   probe.find_class /Script/Dominion.OculusComponent
--   probe.find_class /Game/Gameplay/GameplayEffects/PerksV2/GE_PerkV2_Construction_Oculus.GE_PerkV2_Construction_Oculus_C
--
-- Falls back to LoadAsset() if StaticFindObject() returns nil, so an
-- unloaded blueprint asset still resolves on first call.
function M.find_class(args_str)
    local path = trim(args_str)
    if path == "" then
        return false, "usage: probe.find_class <objectPath>"
    end
    return with_sentinel("probe.find_class", path, function()
        local cls
        if StaticFindObject then
            local ok, found = pcall(StaticFindObject, path)
            if ok and found and safety.is_uobject(found) then cls = found end
        end
        if not cls and LoadAsset then
            -- LoadAsset takes a /Game/... package path without the
            -- trailing class suffix ; strip the ".ClassName" tail if
            -- present so we can retry. Round-trips back through
            -- StaticFindObject after the load completes.
            local pkg = path:match("^(.-)%.[^.]+$") or path
            pcall(LoadAsset, pkg)
            if StaticFindObject then
                local ok, found = pcall(StaticFindObject, path)
                if ok and found and safety.is_uobject(found) then cls = found end
            end
        end
        if not cls then
            return false, "class not found at path (try the full /Game/... or /Script/... path with .ClassName suffix)"
        end
        local short = safety.class_name_of(cls) or "UnknownClass"
        return true, string.format("%s (%s)", tostring(cls), short)
    end)
end

-- ---------- widget spawning --------------------------------------------
--
-- probe.widget.spawn <objectPath> [zorder]
-- probe.widget.remove [tag]
-- probe.widget.list
--
-- Construct a UserWidget from a /Game/... blueprint class and push it
-- to the player's viewport. Used to test whether dev menus and other
-- UI assets the catalog surfaces (e.g. WBP_DebugMenu_AIPage) actually
-- render in shipping builds when their normal cheat-gated input path
-- has been #if'd out. We don't bind keys ; we just construct the
-- widget directly and add it to the viewport so any visible content
-- becomes immediately clickable.
--
-- Spawned widgets are tracked by tag so probe.widget.remove can take
-- them back down. The tag defaults to the asset leaf name ; pass an
-- explicit tag (third whitespace-separated token) to keep multiple
-- copies straight. probe.widget.list reports current tags.

local _spawned_widgets = {}  -- tag -> {widget = <userdata>, path = string}

local function _resolve_widget_class(path)
    if not StaticFindObject then return nil, "StaticFindObject unavailable" end
    local cls
    local ok, found = pcall(StaticFindObject, path)
    if ok and found and safety.is_uobject(found) then cls = found end
    if not cls and LoadAsset then
        local pkg = path:match("^(.-)%.[^.]+$") or path
        pcall(LoadAsset, pkg)
        local ok2, found2 = pcall(StaticFindObject, path)
        if ok2 and found2 and safety.is_uobject(found2) then cls = found2 end
    end
    if not cls then
        return nil, "class not found (need the full /Game/...Widget.Widget_C path)"
    end
    return cls
end

local function _resolve_player_controller()
    local UEHelpers
    do
        local ok, mod = pcall(require, "UEHelpers")
        if ok and type(mod) == "table" then UEHelpers = mod end
    end
    if UEHelpers and UEHelpers.GetPlayerController then
        local ok, pc = pcall(UEHelpers.GetPlayerController)
        if ok and pc and safety.is_uobject(pc) then return pc end
    end
    if UEHelpers and UEHelpers.GetGameInstance then
        local ok, gi = pcall(UEHelpers.GetGameInstance)
        if ok and gi then return gi end
    end
    return nil, "no PlayerController / GameInstance owner available"
end

function M.widget_spawn(args_str)
    local s = trim(args_str)
    if s == "" then
        return false, "usage: probe.widget.spawn <objectPath> [zorder] [tag]"
    end
    -- Parse up to 3 whitespace-separated tokens : path, zorder, tag.
    local path, rest = s:match("^(%S+)%s*(.*)$")
    if not path or path == "" then
        return false, "usage: probe.widget.spawn <objectPath> [zorder] [tag]"
    end
    local z_str, tag = rest:match("^(%S+)%s*(.*)$")
    local zorder = tonumber(z_str) or 100
    if not tag or tag == "" then
        -- Default tag = asset leaf, lowercased for case-insensitive
        -- match against the remove verb. Falls back to the full path
        -- when the leaf can't be extracted.
        tag = (path:match("([^/]+)$") or path):lower()
        tag = tag:gsub("%..*", "")  -- strip trailing .ClassName_C
    end
    return with_sentinel("probe.widget.spawn", s, function()
        local cls, cls_err = _resolve_widget_class(path)
        if not cls then return false, cls_err end
        local owner, owner_err = _resolve_player_controller()
        if not owner then return false, owner_err end
        -- Prefer UWidgetBlueprintLibrary.Create when available -- it
        -- handles owning-player wiring correctly. Fall back to a
        -- direct StaticConstructObject for builds where the helper
        -- isn't exposed.
        local widget
        local wbl = StaticFindObject and StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
        if wbl then
            local ok_c, w = pcall(function() return wbl:Create(owner, cls, owner) end)
            if ok_c and w and safety.is_uobject(w) then widget = w end
        end
        if not widget then
            local ok_ctor, w2 = pcall(function()
                return StaticConstructObject(cls, owner, FName("RSDWToolsWidget_" .. tag))
            end)
            if ok_ctor and w2 and safety.is_uobject(w2) then widget = w2 end
        end
        if not widget then
            return false, "construction failed (class resolved but no widget returned)"
        end
        local ok_av = pcall(function() widget:AddToViewport(zorder) end)
        if not ok_av then
            return false, "AddToViewport raised (widget constructed but not shown)"
        end
        _spawned_widgets[tag] = { widget = widget, path = path, zorder = zorder }
        return true, string.format("spawned tag=%s z=%d cls=%s",
            tag, zorder, safety.class_name_of(widget) or "?")
    end)
end

function M.widget_remove(args_str)
    local tag = trim(args_str)
    if tag == "" then
        -- No tag : remove everything we spawned. Returns the count.
        local removed = 0
        for t, entry in pairs(_spawned_widgets) do
            if entry.widget and safety.is_uobject(entry.widget) then
                pcall(function() entry.widget:RemoveFromParent() end)
            end
            _spawned_widgets[t] = nil
            removed = removed + 1
        end
        return true, string.format("removed %d widget(s)", removed)
    end
    tag = tag:lower()
    local entry = _spawned_widgets[tag]
    if not entry then
        return false, "no spawned widget with tag '" .. tag .. "'"
    end
    if entry.widget and safety.is_uobject(entry.widget) then
        local ok_rm = pcall(function() entry.widget:RemoveFromParent() end)
        if not ok_rm then
            _spawned_widgets[tag] = nil
            return false, "RemoveFromParent raised (entry cleared anyway)"
        end
    end
    _spawned_widgets[tag] = nil
    return true, "removed tag=" .. tag
end

function M.widget_list(_args_str)
    local n = 0
    local parts = {}
    for tag, entry in pairs(_spawned_widgets) do
        n = n + 1
        local alive = entry.widget and safety.is_uobject(entry.widget) and "live" or "dead"
        parts[#parts + 1] = string.format("%s=%s(%s)", tag, alive, entry.path)
    end
    if n == 0 then return true, "no spawned widgets" end
    return true, string.format("%d spawned : %s", n, table.concat(parts, ", "))
end

return M
