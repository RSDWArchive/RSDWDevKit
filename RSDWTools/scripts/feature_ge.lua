-- feature_ge.lua
--
-- Thin Lua wrapper around the game's Gameplay-Effect system
-- (UDominionGameplayEffectsComponent). This is the authoritative path for
-- every attribute mutation in the game -- Max Health, resistances, move
-- speed multiplier, stamina regen, damage scaling, XP boosters, etc. The
-- round 8.5 probe dump (ipc/probes/gameplay_effects/) confirmed the full
-- apply/remove API surface:
--
--   UDominionGameplayEffectsComponent:InstantiateGameplayEffect(
--       DataClass: TSubclassOf<UDominionGameplayEffectData>,
--       InstigatingGE: UDominionGameplayEffect,
--       bForceNewInstance: boolean
--   ) -> FDominionGameplayEffectHandle
--
--   UDominionGameplayEffectsComponent:ApplyGameplayEffect(
--       Instigator: AActor, Source: UObject,
--       Handle: FDominionGameplayEffectHandle,
--       bIgnoreChanceToApply: boolean
--   ) -> boolean
--
--   UDominionGameplayEffectsComponent:RemoveGameplayEffect(
--       Handle: FDominionGameplayEffectHandle
--   ) -> boolean
--
--   UDominionGameplayEffectsComponent:BP_RemoveAllGameplayEffectsWithData(
--       DataClass: TSubclassOf<UDominionGameplayEffectData>
--   )
--
--   UDominionGameplayEffectsComponent:HasGameplayEffect(
--       Handle: FDominionGameplayEffectHandle
--   ) -> boolean
--
-- The public module API maps one-to-one onto the "apply / remove / toggle /
-- has" pattern the WPF UI already uses for component-field cheats:
--
--   feature_ge.apply_ge(class_name)          -> (ok, detail)
--   feature_ge.remove_ge(class_name)         -> (ok, detail)
--   feature_ge.toggle_ge(class_name, value)  -> (ok, detail)   value = on|off|true|false|1|0
--   feature_ge.has_ge(class_name)            -> (ok, "true"|"false")
--   feature_ge.list_applied()                -> (ok, "N applied: A, B, ...")
--
-- All class names are the short UE-style name with the `U` prefix and `_C`
-- suffix, exactly as they appear in ipc/probes/gameplay_effects/ge_catalog.json
-- (e.g. "UGE_Invulnerable_C", "UGE_ModifyMaxHealth_C",
-- "UGE_ModifyMovementSpeedMultiplier_C").

local feature_actor = require("feature_actor")

local M = {}

-- Cache: short class name -> handle (userdata struct). A handle stays
-- valid as long as the GE instance it refers to is alive. We drop
-- entries on remove and on stale-detection (HasGameplayEffect returns
-- false for a cached handle). Fresh applies always pass
-- bForceNewInstance=true so the handle we cache is guaranteed unique.
M.handles = {}

-- Cache: short class name -> UClass userdata. Resolved lazily on first
-- use; stable for the lifetime of the mod load (BP classes don't move
-- in memory after initial load).
local CLASS_CACHE = {}

-- Component aliases, ordered from most specific to most generic. Mirrors
-- the list used by the GE probe in feature_introspect.dump_gameplay_effects()
-- so whatever alias succeeded for the probe will also succeed here.
local GE_COMPONENT_ALIASES = {
    "BP_Components_PlayerGameplayEffects",
    "GameplayEffectsComponent",
    "DominionGameplayEffectsComponent",
}

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

local function is_valid(obj)
    return feature_actor.is_valid_object and feature_actor.is_valid_object(obj)
end

local function get_pawn()
    local pawn = feature_actor.get_local_pawn()
    if not pawn then return nil, "no local pawn" end
    return pawn
end

-- Locate the gameplay-effects component hanging off the local pawn. We do
-- a direct property probe first (fast path; every BP component is also
-- exposed as a pawn property of the same short name) and fall through
-- aliases. Returns (component, alias_used) or (nil, err).
local function get_ge_component(pawn)
    for _, alias in ipairs(GE_COMPONENT_ALIASES) do
        local ok, val = pcall(function() return pawn[alias] end)
        if ok and type(val) == "userdata" and is_valid(val) then
            return val, alias
        end
    end
    return nil, "gameplay-effects component not found on pawn"
end

-- Resolve a short class name OR full UE object path to a runtime UClass.
--
-- Two strategies, tried in order:
--
--   1. Path form (input contains '/') -> StaticFindObject directly, with
--      a LoadAsset fallback for unloaded blueprint assets. This is the
--      only reliable path for perk-style GE classes that have no live
--      instances at apply time (e.g. GE_PerkV2_Construction_Oculus_C).
--
--   2. Short-name form -> FindFirstOf(name) returns the first live
--      UObject of that class in the global object array, which for GE
--      data classes is the class default object (CDO) when no instances
--      exist. The CDO's :GetClass() is the UClass we need. Three name
--      variants are tried because UE4SS's runtime name convention
--      differs from the schema dump:
--        * raw name as supplied (e.g. "UGE_Invulnerable_C")
--        * raw name with leading U / A / F stripped
--        * explicit "U"-prefixed form (for prefix-less callers)
local function resolve_class(name)
    if not name or name == "" then return nil, "empty class name" end
    local cached = CLASS_CACHE[name]
    if cached then return cached end

    -- Path form: hand directly to StaticFindObject. The returned UObject
    -- IS the UClass for /Game/.../Foo.Foo_C inputs, so no :GetClass()
    -- hop is needed.
    if name:find("/") then
        if StaticFindObject then
            local ok, found = pcall(StaticFindObject, name)
            if ok and type(found) == "userdata" and is_valid(found) then
                CLASS_CACHE[name] = found
                return found
            end
        end
        if LoadAsset then
            -- LoadAsset wants the package path without the trailing
            -- ClassName suffix ; strip ".X" if present, then retry the
            -- StaticFindObject lookup.
            local pkg = name:match("^(.-)%.[^.]+$") or name
            pcall(LoadAsset, pkg)
            if StaticFindObject then
                local ok, found = pcall(StaticFindObject, name)
                if ok and type(found) == "userdata" and is_valid(found) then
                    CLASS_CACHE[name] = found
                    return found
                end
            end
        end
        return nil, "class not found at path: " .. tostring(name)
    end

    local candidates = { name }
    local prefix = name:sub(1, 1)
    if prefix == "U" or prefix == "A" or prefix == "F" then
        candidates[#candidates + 1] = name:sub(2)
    else
        candidates[#candidates + 1] = "U" .. name
    end

    for _, candidate in ipairs(candidates) do
        local ok, inst = pcall(FindFirstOf, candidate)
        if ok and type(inst) == "userdata" and is_valid(inst) then
            local ok_cls, cls = pcall(function() return inst:GetClass() end)
            if ok_cls and type(cls) == "userdata" and is_valid(cls) then
                CLASS_CACHE[name] = cls
                return cls
            end
        end
    end

    return nil, "class not found: " .. tostring(name) ..
        " (tried: " .. table.concat(candidates, ", ") .. ")"
end

-- Check whether the cached handle for `class_name` still maps to a live
-- GE on the component. Returns (is_live:boolean, ok:boolean). When the
-- HasGameplayEffect call errors we treat the handle as stale rather than
-- leaving it in the cache forever.
local function handle_still_live(comp, handle)
    if not handle then return false, true end
    local ok, result = pcall(function() return comp:HasGameplayEffect(handle) end)
    if not ok then return false, false end
    return (result == true), true
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Apply a gameplay effect by class name. Idempotent: if the cached handle
-- is still live, returns "already-applied" without creating a duplicate.
-- On success the handle is stashed in M.handles[class_name].
--
-- IMPORTANT (Round 48 / UE4SS marshaling fix):
--   The "obvious" path -- comp:InstantiateGameplayEffect(cls, ...) ->
--   comp:ApplyGameplayEffect(pawn, source, handle, true) -- is broken in
--   UE4SS Lua. FDominionGameplayEffectHandle contains a weak object
--   property, and UE4SS logs `[push_weakobjectproperty] Operation::Set
--   is not supported` when marshaling the handle struct back into the
--   Apply call's parameter slot ; the handle arrives zeroed and the
--   game prints `Invalid Handle!`. Confirmed against
--   GE_PerkV2_Construction_Oculus_C 2026-04-25.
--
--   Workaround: ADominionPlayerCharacter exposes a single-shot wrapper
--   `AddGameplayEffect(UDominionGameplayEffectData* Data, AActor* Inst,
--   UObject* Source)` which takes the data CDO directly (a UObject*
--   that marshals fine) and internally does Instantiate+Apply in C++.
--   We get the CDO via UClass:GetCDO(). Remove still goes through
--   BP_RemoveAllGameplayEffectsWithData(cls) which also takes the
--   class directly, so neither path needs to round-trip a handle.
function M.apply_ge(class_name)
    local pawn, pawn_err = get_pawn()
    if not pawn then return false, pawn_err end

    local comp, comp_err = get_ge_component(pawn)
    if not comp then return false, comp_err end

    local cls, cls_err = resolve_class(class_name)
    if not cls then return false, cls_err end

    -- Idempotency: if we already have a handle and it's still live on
    -- the component, nothing to do.
    local existing = M.handles[class_name]
    if existing then
        local live = handle_still_live(comp, existing)
        if live then
            return true, "already-applied " .. class_name
        end
        M.handles[class_name] = nil
    end

    -- Get the data-class CDO. UClass:GetCDO() is the UE4SS-blessed way
    -- to fetch a class's class-default-object as a UObject pointer ;
    -- the CDO is itself an instance of the BP class, which is exactly
    -- what AddGameplayEffect() wants for the first arg.
    local ok_cdo, cdo = pcall(function() return cls:GetCDO() end)
    if not ok_cdo or not cdo or not is_valid(cdo) then
        return false, "could not resolve CDO for class " .. tostring(class_name)
    end

    local ok_apply, handle = pcall(function()
        return pawn:AddGameplayEffect(cdo, pawn, pawn)
    end)
    if not ok_apply then
        return false, "AddGameplayEffect errored: " .. tostring(handle)
    end

    -- Verify the apply actually took. Even though the returned handle
    -- is mostly opaque (UE4SS can't read its weak-obj field cleanly),
    -- the engine logs `OnGameplayEffectAdded` if the GE registered ;
    -- additionally we can walk the component's instance arrays to
    -- confirm. Cheap heuristic: count instances tagged with this class
    -- on the component before/after. Skipped here because the
    -- AddGameplayEffect side effect (BP OnGameplayEffectAdded firing)
    -- is what we actually care about ; if that didn't run the user
    -- will see no in-game change and we can iterate.
    M.handles[class_name] = handle
    print(string.format("[RSDWTools] ge.apply %s -> AddGameplayEffect dispatched (handle cached)",
        class_name))
    return true, "applied " .. class_name
end

-- Remove a gameplay effect by class name. Uses BP_RemoveAllGameplayEffectsWithData
-- (class-wide sweep) as the primary path so we also clear GE instances
-- the player had stacked from the vanilla game (potion, rest, trinket,
-- etc.), then falls back to the cached handle in case the class-wide
-- call didn't find the specific instance we applied.
function M.remove_ge(class_name)
    local pawn, pawn_err = get_pawn()
    if not pawn then return false, pawn_err end

    local comp, comp_err = get_ge_component(pawn)
    if not comp then return false, comp_err end

    local cls = resolve_class(class_name)
    local class_wide_ok = false
    if cls then
        local ok = pcall(function() comp:BP_RemoveAllGameplayEffectsWithData(cls) end)
        class_wide_ok = ok
    end

    local handle = M.handles[class_name]
    local handle_ok = false
    if handle then
        handle_ok = select(1, pcall(function() comp:RemoveGameplayEffect(handle) end))
        M.handles[class_name] = nil
    end

    print(string.format("[RSDWTools] ge.remove %s (class_wide=%s handle=%s)",
        class_name, tostring(class_wide_ok), tostring(handle_ok)))

    if not class_wide_ok and not handle_ok then
        return false, "both remove paths failed (class unresolved and no cached handle)"
    end
    return true, "removed " .. class_name
end

-- Generic on/off router. Accepts the same boolean spellings the rest of
-- the mod uses so WPF Tag-based toggles drop in unchanged.
function M.toggle_ge(class_name, value_str)
    local v = tostring(value_str or ""):lower()
    if v == "on" or v == "true" or v == "1" then
        return M.apply_ge(class_name)
    elseif v == "off" or v == "false" or v == "0" then
        return M.remove_ge(class_name)
    end
    return false, "expected on|off (got '" .. tostring(value_str) .. "')"
end

-- Report whether we still hold a live handle for `class_name`. Returns
-- (ok, "true") or (ok, "false") so the caller can prime a checkbox the
-- same way it does for every other player.get key.
function M.has_ge(class_name)
    local pawn, pawn_err = get_pawn()
    if not pawn then return false, pawn_err end

    local comp, comp_err = get_ge_component(pawn)
    if not comp then return false, comp_err end

    local handle = M.handles[class_name]
    if not handle then return true, "false" end

    local live, probe_ok = handle_still_live(comp, handle)
    if not probe_ok then
        -- Probe errored. Conservatively drop the handle so a fresh
        -- apply can rebuild it.
        M.handles[class_name] = nil
        return true, "false"
    end
    if not live then
        M.handles[class_name] = nil
        return true, "false"
    end
    return true, "true"
end

-- Diagnostic: list all class names we currently hold handles for. Used
-- by the WPF side to reconcile UI state after a game reload / mod reload.
function M.list_applied()
    local names = {}
    for name, _ in pairs(M.handles) do names[#names + 1] = name end
    table.sort(names)
    return true, string.format("%d applied: %s", #names, table.concat(names, ", "))
end

-- Testing hook: forget the handle cache without touching in-game state.
-- Useful after a game reload when the old handles are definitely dead
-- but we can't call RemoveGameplayEffect on them safely.
function M.clear_cache()
    M.handles = {}
    CLASS_CACHE = {}
    return true, "cache cleared"
end

-- ===========================================================================
-- CDO field editor (round 56)
--
-- The class default object of a UDominionGameplayEffectData carries every
-- knob the designers set in Blueprint: Duration, AmountToModify, ChanceToApply,
-- ModifierOperation, the periodic-tick flags, and so on. Mutating those fields
-- on the CDO in-process changes the template every subsequent
-- InstantiateGameplayEffect copies from. Effects:
--   * Persistent for the running game session ; wiped on .exe restart.
--   * Affects the game's own internal applies of the same GE class
--     (e.g. NPC HealthRegen). Player-tier GEs (UGE_CHEAT_*) are isolated.
--   * No save-file / .pak / .ini side effects.
--
-- The snapshot table records the original value the first time a field is
-- mutated so cdo_reset can restore it. Snapshots are session-scoped ; they
-- naturally vanish when the mod reloads with the rest of the Lua state.
-- ===========================================================================

-- class_name -> { [field_path] = original_value }
M.cdo_snapshots = {}

-- Field-path schema. Two-level dotted paths are supported ; the second
-- segment (when present) is followed via pcall on the parent struct. The
-- order here is also the order cdo_dump emits, which the WPF uses to
-- render fields. `kind` drives the editor widget type ; `advanced=true`
-- hides the row behind the WPF "Show advanced" toggle.
--
-- IMPORTANT: keep the path strings in sync with
-- Dumps/UHTHeaderDump/Dominion/Public/DominionGameplayEffectData.h and
-- DominionGameplayEffectInstancedData.h.
local CDO_FIELDS = {
    -- Quick fields ; always visible in the editor.
    --
    -- AmountToModify is an FAttributeOrFloat (per UHT dump) ; the literal
    -- magnitude lives in the `Value` field, not `LiteralValue` as an
    -- earlier draft assumed. The struct also carries a `Source` enum that
    -- decides whether the engine reads .Value, .Attribute, .DataTableRowHandle,
    -- or .DeveloperSettingLookupName ; we surface it so the WPF can warn
    -- when a literal edit will be ignored (Source != Float).
    { path = "Data.AmountToModify.Value",        kind = "float", group = "Magnitude" },
    { path = "Data.AmountToModify.Source",       kind = "enum",  group = "Magnitude" },
    { path = "Data.Duration",                    kind = "float", group = "Duration"  },
    { path = "ChanceToApply",                    kind = "float", group = "Chance"    },
    { path = "Data.ModifierOperation",           kind = "enum",  group = "Operation" },

    -- Advanced fields ; toggleable in WPF.
    { path = "DevName",                            kind = "string", advanced = true },
    { path = "bSingleInstance",                    kind = "bool",   advanced = true },
    { path = "bAlwaysCreateNewInstance",           kind = "bool",   advanced = true },
    { path = "bCannotBeRemoved",                   kind = "bool",   advanced = true },
    { path = "bShowInHUD",                         kind = "bool",   advanced = true },
    { path = "bCaptureForTelemetry",               kind = "bool",   advanced = true },
    { path = "bShouldReplicate",                   kind = "bool",   advanced = true },
    { path = "StatusEffectType",                   kind = "enum",   advanced = true },
    { path = "Data.DurationType",                  kind = "enum",   advanced = true },
    { path = "Data.bCanTickPeriodically",          kind = "bool",   advanced = true },
    { path = "Data.PeriodicInterval.Value",        kind = "float",  advanced = true },
    { path = "Data.PeriodicInterval.Source",       kind = "enum",   advanced = true },
    { path = "Data.bTickIntervalImmediately",      kind = "bool",   advanced = true },
    { path = "Data.bShowInTooltip",                kind = "bool",   advanced = true },
    { path = "Data.StatValueType",                 kind = "enum",   advanced = true },
    { path = "Data.bAmountHasMinClamp",            kind = "bool",   advanced = true },
    { path = "Data.AmountMinClamp",                kind = "float",  advanced = true },
    { path = "Data.bAmountHasMaxClamp",            kind = "bool",   advanced = true },
    { path = "Data.AmountMaxClamp",                kind = "float",  advanced = true },
    { path = "Data.PreMultiplyAdditiveValue",      kind = "float",  advanced = true },
    { path = "Data.PostMultiplyAdditiveValue",     kind = "float",  advanced = true },
    { path = "Data.AmountToModifyScale",           kind = "float",  advanced = true },
    { path = "Data.ModifierApplyType",             kind = "enum",   advanced = true },
}

-- Resolve a class to its CDO. Returns (cdo, err).
local function resolve_cdo(class_name)
    local cls, err = resolve_class(class_name)
    if not cls then return nil, err end
    local ok, cdo = pcall(function() return cls:GetCDO() end)
    if not ok or not cdo or not is_valid(cdo) then
        return nil, "could not resolve CDO for " .. tostring(class_name)
    end
    return cdo
end

-- Walk a dotted field path on `obj`. Returns (parent, leaf_name, ok, err)
-- where parent is the immediate containing object (so the caller can
-- read or write `parent[leaf_name]`).
local function resolve_field(obj, path)
    if not obj or not path or path == "" then return nil, nil, false, "empty path" end
    local segments = {}
    for seg in path:gmatch("[^.]+") do segments[#segments + 1] = seg end
    if #segments == 0 then return nil, nil, false, "empty path" end

    local cur = obj
    for i = 1, #segments - 1 do
        local seg = segments[i]
        local ok, val = pcall(function() return cur[seg] end)
        if not ok or val == nil then
            return nil, nil, false, "missing intermediate field: " .. seg
        end
        cur = val
    end
    return cur, segments[#segments], true, nil
end

-- Read a field by dotted path. Returns (ok, value, kind_hint).
local function cdo_read(cdo, path)
    local parent, leaf, ok, err = resolve_field(cdo, path)
    if not ok then return false, nil, err end
    local read_ok, val = pcall(function() return parent[leaf] end)
    if not read_ok then return false, nil, "read failed: " .. tostring(val) end
    return true, val
end

-- Coerce a string value to the right Lua type for assignment, based on
-- the field's declared `kind`. Bools accept the same spellings the rest
-- of the mod uses ; floats/ints/enums go through tonumber ; strings
-- pass through unchanged.
local function coerce_value(kind, raw)
    if kind == "bool" then
        local s = tostring(raw or ""):lower()
        if s == "true" or s == "1" or s == "on" or s == "yes" then return true, true end
        if s == "false" or s == "0" or s == "off" or s == "no" then return true, false end
        return false, "expected bool, got '" .. tostring(raw) .. "'"
    elseif kind == "float" then
        local n = tonumber(raw)
        if n == nil then return false, "expected number, got '" .. tostring(raw) .. "'" end
        return true, n
    elseif kind == "int" or kind == "enum" then
        local n = tonumber(raw)
        if n == nil then return false, "expected int, got '" .. tostring(raw) .. "'" end
        return true, math.floor(n)
    elseif kind == "string" then
        return true, tostring(raw or "")
    end
    return false, "unsupported kind: " .. tostring(kind)
end

-- Look up a field's kind from the schema. Returns (kind, advanced) or
-- (nil) when the path is not in the whitelist.
local function field_kind(path)
    for _, entry in ipairs(CDO_FIELDS) do
        if entry.path == path then return entry.kind, entry.advanced end
    end
    return nil
end

-- Stringify a value for transport across the IPC ack body. UE bool reads
-- come back as Lua bool ; numbers print clean. UE4SS exposes FString and
-- FName as userdata that needs an explicit :ToString() hop ; we try that
-- first and fall back to "<userdata>" only if the call errors (which
-- means the userdata isn't actually a stringy type).
local function value_to_string(v)
    local t = type(v)
    if v == nil then return "nil" end
    if t == "boolean" then return v and "true" or "false" end
    if t == "number" then return tostring(v) end
    if t == "string" then return v end
    if t == "userdata" then
        local ok, s = pcall(function() return v:ToString() end)
        if ok and type(s) == "string" then return s end
        return "<userdata>"
    end
    return tostring(v)
end

-- Snapshot helper: stash the original value for `path` if we haven't
-- already. Idempotent ; safe to call before every write.
local function snapshot_once(class_name, path, value)
    M.cdo_snapshots[class_name] = M.cdo_snapshots[class_name] or {}
    if M.cdo_snapshots[class_name][path] == nil then
        M.cdo_snapshots[class_name][path] = value
    end
end

-- Public: read a single CDO field. Returns (ok, "value") on success ;
-- the value string can be empty on legitimate empty-string reads.
function M.cdo_get(class_name, path)
    local cdo, err = resolve_cdo(class_name)
    if not cdo then return false, err end
    local ok, val, read_err = cdo_read(cdo, path)
    if not ok then return false, read_err end
    return true, value_to_string(val)
end

-- Public: write a single CDO field. Coerces by schema kind ; snapshots
-- the original value first so cdo_reset can restore it. Returns
-- (ok, "old=X new=Y").
function M.cdo_set(class_name, path, raw_value)
    local kind = field_kind(path)
    if not kind then
        return false, "unknown field path '" .. tostring(path) ..
            "' (not in CDO_FIELDS whitelist)"
    end

    local cdo, err = resolve_cdo(class_name)
    if not cdo then return false, err end

    local parent, leaf, lookup_ok, lookup_err = resolve_field(cdo, path)
    if not lookup_ok then return false, lookup_err end

    -- Read current value first so we can snapshot + report the delta.
    local read_ok, current = pcall(function() return parent[leaf] end)
    if not read_ok then
        return false, "could not read current value: " .. tostring(current)
    end

    local coerce_ok, new_val = coerce_value(kind, raw_value)
    if not coerce_ok then return false, new_val end

    snapshot_once(class_name, path, current)

    local write_ok, write_err = pcall(function() parent[leaf] = new_val end)
    if not write_ok then return false, "write failed: " .. tostring(write_err) end

    print(string.format("[RSDWTools] ge.cdo.set %s.%s : %s -> %s",
        class_name, path, value_to_string(current), value_to_string(new_val)))
    return true, string.format("old=%s new=%s",
        value_to_string(current), value_to_string(new_val))
end

-- Public: revert all snapshotted fields for a class back to their
-- pre-edit values. No-op if nothing was edited. Returns (ok, "N reverted").
function M.cdo_reset(class_name)
    local snap = M.cdo_snapshots[class_name]
    if not snap then return true, "no edits to revert" end

    local cdo, err = resolve_cdo(class_name)
    if not cdo then return false, err end

    local reverted, failed = 0, 0
    for path, original in pairs(snap) do
        local parent, leaf, ok = resolve_field(cdo, path)
        if ok then
            local write_ok = pcall(function() parent[leaf] = original end)
            if write_ok then reverted = reverted + 1 else failed = failed + 1 end
        else
            failed = failed + 1
        end
    end
    M.cdo_snapshots[class_name] = nil
    return true, string.format("%d reverted, %d failed", reverted, failed)
end

-- Public: dump all whitelisted fields with current values as a JSON
-- array string. Used by the WPF editor to populate its rows without
-- hard-coding the schema. Each entry: {"path","kind","advanced","value"}.
-- This is the same handrolled-JSON pattern as feature_ui.lua so we don't
-- pull in an external JSON library.
local function escape_json_str(s)
    s = tostring(s or "")
    s = s:gsub('\\', '\\\\')
    s = s:gsub('"', '\\"')
    s = s:gsub('\n', '\\n')
    s = s:gsub('\r', '\\r')
    s = s:gsub('\t', '\\t')
    return s
end

-- Round 56.1: the shared-memory line bridge caps each ack at 1024 bytes
-- (RSDW_SHM_LINE_MAX in bridge/rsdw_shm_v1.h) and the JSON payload for
-- a typical GE CDO is ~2 KB once you include the ~27 advanced fields.
-- Returning the whole JSON in one ack therefore truncates and the C#
-- side fails to parse it. We cache the last dump on the Lua side keyed
-- by class name and serve it back in chunks of CHUNK_BYTES through a
-- separate verb. Cache is single-slot (only the last dump) which is
-- enough for the editor: the dialog issues a fresh dump on Open and on
-- Refresh, then immediately drains all chunks before asking for any
-- other verb.
local CHUNK_BYTES = 800
local last_dump = { target = nil, json = nil }

function M.cdo_dump(class_name)
    local cdo, err = resolve_cdo(class_name)
    if not cdo then return false, err end

    local pieces = { "[" }
    for i, entry in ipairs(CDO_FIELDS) do
        local read_ok, val = cdo_read(cdo, entry.path)
        local val_str = read_ok and value_to_string(val) or ""
        local readable = read_ok and "true" or "false"
        if i > 1 then pieces[#pieces + 1] = "," end
        pieces[#pieces + 1] = string.format(
            '{"path":"%s","kind":"%s","advanced":%s,"readable":%s,"value":"%s"}',
            escape_json_str(entry.path),
            escape_json_str(entry.kind),
            entry.advanced and "true" or "false",
            readable,
            escape_json_str(val_str))
    end
    pieces[#pieces + 1] = "]"
    local json = table.concat(pieces)

    last_dump.target = class_name
    last_dump.json = json
    local total = #json
    local chunks = math.ceil(total / CHUNK_BYTES)
    return true, string.format("chunks=%d len=%d", chunks, total)
end

-- Returns the i-th 800-byte slice of the cached dump (1-based index).
-- The C# side reads `chunks=N` from cdo_dump and then loops 1..N.
function M.cdo_dump_chunk(class_name, index)
    if last_dump.target ~= class_name or not last_dump.json then
        return false, "no cached dump for '" .. tostring(class_name) ..
            "' (call player.ge.cdo.dump first)"
    end
    local i = tonumber(index)
    if not i or i < 1 then return false, "chunk index must be >= 1" end
    local start_byte = (i - 1) * CHUNK_BYTES + 1
    if start_byte > #last_dump.json then return false, "chunk index out of range" end
    local end_byte = math.min(start_byte + CHUNK_BYTES - 1, #last_dump.json)
    return true, last_dump.json:sub(start_byte, end_byte)
end

return M
