-- feature_world_settings.lua
--
-- Unlock every "Edit Settings" toggle in the Main Menu World Select +
-- World Create flows, regardless of EWorldGameMode (Standard, Hardcore,
-- Custom, Creative).
--
-- Mechanism:
--   The Advanced Settings UI (UMainMenuWorldAdvancedSettingsSubWidget)
--   is data-driven. Each setting row corresponds to a UDifficultySettingData
--   instance with two gating fields :
--       EWorldSettingUserAdjustability PlayerAdjustable
--           Never (0) / OnlyCustom (1) / CustomAndCreative (2) / AllModes (3)
--       bool bCanBeChangedAfterWorldCreation
--   The widget compares those against the current world's mode to decide
--   visibility + interactability. There is NO per-mode special casing in
--   code -- it's all driven off these fields.
--
--   So : flip every loaded UDifficultySettingData to AllModes (3) and
--   bCanBeChangedAfterWorldCreation = true, and the menu naturally lights
--   up every option for every world.
--
--   We ALSO patch the per-setting tooltip object (USettingsTooltipContent)
--   so the "Cannot be changed after world creation" sub-label disappears.
--
-- Reversibility:
--   We snapshot the original (PlayerAdjustable, bCanBeChangedAfterWorldCreation,
--   tooltip.bCanEditAfterWorldCreation) per asset on first apply. restore()
--   walks the snapshot and writes the original values back.
--
-- Re-application:
--   apply() is idempotent and cheap. The WPF Settings checkbox calls it
--   once on app launch ; the user can also re-fire it via the verb if more
--   data assets get streamed in later (none observed in practice -- they
--   appear all-loaded by the time the main menu is up).
--
-- No native hooks, no widget surgery, no save-game tampering. The actual
-- gameplay slider values still come from whatever the user picks in the
-- now-unlocked UI.

local M = {}

local feature_actor = require("feature_actor")

local function is_valid(obj)
    return feature_actor.is_valid_object(obj)
end

-- EWorldSettingUserAdjustability::AllModes
local ADJ_ALL_MODES = 3

-- Per-asset snapshot keyed by FullName. Lets restore() walk back without
-- making us re-implement reflection. We also keep a count for status output.
local _snapshot = {}
local _snapshot_count = 0

local function find_all_live(class_name)
    local out = {}
    if not FindAllOf then return out end
    local ok, list = pcall(FindAllOf, class_name)
    if not ok or not list then return out end

    -- Match the proven iteration pattern from feature_buildings.lua :
    -- UE4SS's TArray wrapper exposes #list and list[i] reliably ; the
    -- fancier ForEach helper isn't always present on every build.
    local n = 0
    pcall(function() n = #list end)
    if n == 0 then
        local ok_num, num_val = pcall(function() return list:Num() end)
        if ok_num and type(num_val) == "number" then n = num_val end
    end
    for i = 1, n do
        local eok, entry = pcall(function() return list[i] end)
        if eok and type(entry) == "userdata" and is_valid(entry) then
            local fn
            pcall(function() fn = entry:GetFullName() end)
            if type(fn) == "string" and not fn:find("Default__", 1, true) then
                out[#out + 1] = entry
            end
        end
    end
    return out
end

-- Fallback enumerator : the game's own UDifficultyDataSubsystem caches
-- every loaded UDifficultySettingData in CachedSettingTagToSettingData
-- (TMap<FGameplayTag, UDifficultySettingData*>). When FindAllOf returns
-- nothing -- e.g. if the asset class string didn't resolve, or the
-- subsystem-owned references are the only ones keeping them alive --
-- we walk the subsystem's map. Returns the deduped union of both paths.
local function collect_via_subsystem(seen_set)
    local out = {}
    if not FindAllOf then return out end
    local ok, list = pcall(FindAllOf, "DifficultyDataSubsystem")
    if not ok or not list then return out end
    local n = 0
    pcall(function() n = #list end)
    if n == 0 then
        local ok_num, num_val = pcall(function() return list:Num() end)
        if ok_num and type(num_val) == "number" then n = num_val end
    end
    for i = 1, n do
        local sok, sub = pcall(function() return list[i] end)
        if sok and is_valid(sub) then
            local mok, m = pcall(function() return sub.CachedSettingTagToSettingData end)
            if mok and m then
                -- TMap iteration via ForEach pair callback is the stable UE4SS
                -- shape ; if it isn't present the map will simply yield nothing
                -- and the FindAllOf path will still cover us.
                pcall(function()
                    m:ForEach(function(_key, _value)
                        local v = _value and _value:get() or nil
                        if is_valid(v) then
                            -- Probe with a real reflection call : is_valid
                            -- only checks the wrapper, but TMap entries can
                            -- still resolve to a stale UObject* whose vtable
                            -- segfaults the moment we call GetName / read a
                            -- property. GetFullName is the cheapest probe.
                            local fn
                            local ok = pcall(function() fn = v:GetFullName() end)
                            if ok and type(fn) == "string"
                                and not fn:find("Default__", 1, true)
                                and not seen_set[fn] then
                                seen_set[fn] = true
                                out[#out + 1] = v
                            end
                        end
                    end)
                end)
            end
        end
    end
    return out
end

-- Combined enumerator : FindAllOf union UDifficultyDataSubsystem cache.
local function collect_assets()
    local primary = find_all_live("DifficultySettingData")
    local seen = {}
    for _, a in ipairs(primary) do
        local fn
        pcall(function() fn = a:GetFullName() end)
        if fn then seen[fn] = true end
    end
    local extra = collect_via_subsystem(seen)
    for _, a in ipairs(extra) do primary[#primary + 1] = a end
    return primary
end

-- Read a single setting's current state without raising. Returns
-- (player_adjustable, can_after, tooltip_obj_or_nil, tooltip_can_after_or_nil).
local function read_state(asset)
    local pa, ca = nil, nil
    pcall(function() pa = asset.PlayerAdjustable end)
    pcall(function() ca = asset.bCanBeChangedAfterWorldCreation end)
    local tip, tip_ca = nil, nil
    pcall(function() tip = asset.SettingsTooltipContent end)
    if is_valid(tip) then
        pcall(function() tip_ca = tip.bCanEditAfterWorldCreation end)
    else
        tip = nil
    end
    return pa, ca, tip, tip_ca
end

-- Public : flip every loaded UDifficultySettingData to fully unlocked.
-- Returns (true, "patched=N seen=M") on success.
function M.apply()
    local assets = collect_assets()
    local seen, patched, dead = 0, 0, 0
    for _, asset in ipairs(assets) do
        seen = seen + 1
        -- Sanity-check the asset by asking for FullName once before we
        -- touch property reflection. A stale wrapper segfaults on any
        -- :Get* / property access ; pcall'd FullName is the cheapest
        -- liveness check we have.
        local fn
        local fn_ok = pcall(function() fn = asset:GetFullName() end)
        if not (fn_ok and fn) then
            dead = dead + 1
        else
        local pa, ca, tip, tip_ca = read_state(asset)

        -- Snapshot once, before we mutate anything.
        if fn and not _snapshot[fn] then
            _snapshot[fn] = {
                ref          = asset,         -- weak-ish ; UE4SS keeps it alive
                player_adj   = pa,
                can_after    = ca,
                tooltip      = tip,
                tip_can_after = tip_ca,
            }
            _snapshot_count = _snapshot_count + 1
        end

        local did_one = false
        if pa ~= ADJ_ALL_MODES then
            local ok = pcall(function() asset.PlayerAdjustable = ADJ_ALL_MODES end)
            if ok then did_one = true end
        end
        if ca ~= true then
            local ok = pcall(function() asset.bCanBeChangedAfterWorldCreation = true end)
            if ok then did_one = true end
        end
        if tip and tip_ca ~= true then
            local ok = pcall(function() tip.bCanEditAfterWorldCreation = true end)
            if ok then did_one = true end
        end
        if did_one then patched = patched + 1 end
        end -- live-asset block
    end

    print(string.format("[RSDWTools] world.settings.unlock_all : seen=%d patched=%d dead=%d snapshot=%d",
        seen, patched, dead, _snapshot_count))
    return true, string.format("seen=%d patched=%d dead=%d snapshot=%d", seen, patched, dead, _snapshot_count)
end

-- Public : write originally-snapshotted values back. Assets that have
-- since been GC'd are skipped silently.
function M.restore()
    if _snapshot_count == 0 then
        return true, "nothing to restore (no snapshot)"
    end
    local restored, gone = 0, 0
    for fn, snap in pairs(_snapshot) do
        local asset = snap.ref
        if is_valid(asset) then
            pcall(function() asset.PlayerAdjustable = snap.player_adj end)
            pcall(function() asset.bCanBeChangedAfterWorldCreation = snap.can_after end)
            if is_valid(snap.tooltip) and snap.tip_can_after ~= nil then
                pcall(function() snap.tooltip.bCanEditAfterWorldCreation = snap.tip_can_after end)
            end
            restored = restored + 1
        else
            gone = gone + 1
        end
        _snapshot[fn] = nil
    end
    local was = _snapshot_count
    _snapshot_count = 0
    print(string.format("[RSDWTools] world.settings.restore : restored=%d gone=%d (snapshot was %d)",
        restored, gone, was))
    return true, string.format("restored=%d gone=%d", restored, gone)
end

-- Cache a name + state row in pcall so any stale UObject is dropped
-- before we touch table.sort (whose comparator can't recover from a
-- thrown C error).
local function safe_name(asset)
    local ok, n = pcall(function() return asset:GetName() end)
    if ok and type(n) == "string" then return n end
    return nil
end

-- Public : print and return per-setting current state (for verification).
function M.list()
    local assets = collect_assets()
    local rows = {}
    for _, asset in ipairs(assets) do
        local name = safe_name(asset)
        if name then
            local pa, ca = read_state(asset)
            rows[#rows + 1] = { name = name, pa = pa, ca = ca }
        end
    end
    table.sort(rows, function(a, b) return a.name < b.name end)
    print(string.format("[RSDWTools] world.settings.list : %d UDifficultySettingData", #rows))
    for _, r in ipairs(rows) do
        print(string.format("  %s : PlayerAdjustable=%s bCanBeChangedAfterWorldCreation=%s",
            r.name, tostring(r.pa), tostring(r.ca)))
    end
    return true, string.format("count=%d", #rows)
end

function M.snapshot_count() return _snapshot_count end

-- ===========================================================================
-- Scan / Set : the World Service tab uses these to enumerate every loaded
-- UDifficultySettingData (with metadata + current value) and to mutate the
-- live custom value the world will read on next session-load.
--
-- "Live" value lookup :
--   The game stores per-setting overrides in
--     UDifficultyDataSubsystem.CachedSettingDataToCustomValue  (TMap<UDS*, float>)
--   When that map has no entry for a setting the engine falls back to the
--   asset's PresetDefaults[CurrentDifficultyMode]. We surface both so the
--   user always sees a number ; if the override is unset we report the
--   preset default and tag it `current_source = "preset"`. If the override
--   is set we report it and tag `current_source = "override"`.
--
-- Set path :
--   We write the float into CachedSettingDataToCustomValue keyed by the
--   asset pointer. UE's TMap from Lua (UE4SS) supports `m[key] = value`
--   for object-keyed maps. Worst case we fall back to a Add-then-Set
--   sequence. Either way the next call to GetSettingValueAsFloatByData
--   will return the new value.
-- ===========================================================================

-- id -> { ref = asset } map across calls. The WPF UI passes the id back
-- on Apply ; we look the asset back up by id so we don't need to resolve
-- by FullName (which can contain spaces and is awkward to round-trip
-- through the IPC line protocol).
local _scan_index = {}
local _scan_count = 0

-- Tiny JSON-string escaper (matches feature_ui.lua exactly).
local function escape_json(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
    s = s:gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    s = s:gsub("[%z\1-\8\11\12\14-\31]", "")
    return s
end

local function get_win64_base()
    if not IterateGameDirectories then return nil end
    local ok, dirs = pcall(IterateGameDirectories)
    if not ok or type(dirs) ~= "table" then return nil end
    if type(dirs.Game) == "table" and dirs.Game.Binaries and dirs.Game.Binaries.Win64 then
        local p = dirs.Game.Binaries.Win64.__absolute_path
        if type(p) == "string" and #p > 0 then return p end
    end
    for _, e in pairs(dirs) do
        if type(e) == "table" and e.Binaries and e.Binaries.Win64 then
            local p = e.Binaries.Win64.__absolute_path
            if type(p) == "string" and #p > 0 and not p:find("\\Engine\\", 1, true) then
                return p
            end
        end
    end
    return nil
end

local function get_world_settings_json_path()
    local base = get_win64_base()
    if not base then return nil end
    local sep = "\\"
    return base .. sep .. "ue4ss" .. sep .. "Mods" .. sep .. "RSDWTools"
        .. sep .. "ipc" .. sep .. "world_settings.json"
end

local function write_atomic(path, body)
    if not path then return false, "no path" end
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then return false, "open tmp failed: " .. tostring(err) end
    local ok = pcall(function() f:write(body); f:close() end)
    if not ok then return false, "write tmp failed" end
    os.remove(path)
    if not os.rename(tmp, path) then return false, "rename failed" end
    return true, path
end

-- Resolve the (singleton) UDifficultyDataSubsystem instance, or nil if
-- the game instance hasn't created it yet (pre-main-menu).
local function get_difficulty_subsystem()
    if not FindAllOf then return nil end
    local ok, list = pcall(FindAllOf, "DifficultyDataSubsystem")
    if not ok or not list then return nil end
    local n = 0
    pcall(function() n = #list end)
    for i = 1, n do
        local sub
        pcall(function() sub = list[i] end)
        if is_valid(sub) then
            -- Skip the CDO ; we want the live game-instance subsystem.
            local fn
            pcall(function() fn = sub:GetFullName() end)
            if type(fn) == "string" and not fn:find("Default__", 1, true) then
                return sub
            end
        end
    end
    return nil
end

-- Best-effort live-value read. Tries (1) the override map, then (2) the
-- preset defaults map keyed on the subsystem's current difficulty mode.
-- Returns (value_or_nil, source_string).
local function read_current_value(asset, sub)
    -- (1) override map
    if is_valid(sub) then
        local m
        pcall(function() m = sub.CachedSettingDataToCustomValue end)
        if m then
            local v
            pcall(function() v = m[asset] end)
            if type(v) == "number" then return v, "override" end
        end
    end
    -- (2) preset defaults : asset.PresetDefaults[sub.CurrentDifficultyMode]
    if is_valid(sub) then
        local mode
        pcall(function() mode = sub.CurrentDifficultyMode end)
        local pd
        pcall(function() pd = asset.PresetDefaults end)
        if pd and mode ~= nil then
            local v
            pcall(function() v = pd[mode] end)
            if type(v) == "number" then return v, "preset" end
        end
    end
    return nil, "unknown"
end

-- Read FrontEndSliderData (min/max + decimals/postfix). Per
-- Dominion.hpp this struct only exposes MinValue/MaxValue/
-- AmountGamepadSteps/AmountDecimalPlaces/Postfix -- there is no
-- DefaultValue or StepSize on it (the per-mode default lives in
-- PresetDefaults instead).
local function read_slider(asset)
    local fe
    pcall(function() fe = asset.FrontEndSliderData end)
    if not fe then return nil end
    local out = {}
    pcall(function() out.min       = fe.MinValue end)
    pcall(function() out.max       = fe.MaxValue end)
    pcall(function() out.decimals  = fe.AmountDecimalPlaces end)
    pcall(function()
        local p = fe.Postfix
        if p ~= nil then out.postfix = tostring(p) end
    end)
    if out.min == nil and out.max == nil then return nil end
    return out
end

-- FText / FName / FString / FGameplayTag all expose :ToString() in
-- UE4SS. Plain tostring() on the userdata gives back the
-- "FText: 0xDEAD" garbage we definitely don't want surfacing in the UI,
-- so route every text-ish read through this single helper.
local function text_to_str(v)
    if v == nil then return nil end
    local ok, s = pcall(function() return v:ToString() end)
    if ok and type(s) == "string" and #s > 0 then return s end
    return nil
end

local function read_display_name(asset)
    local t
    pcall(function() t = asset.SettingName end)
    return text_to_str(t)
end

local function read_section(asset)
    local t
    pcall(function() t = asset.SettingsSection end)
    return text_to_str(t)
end

local function read_tag(asset)
    local tag
    pcall(function() tag = asset.SettingTag end)
    if not tag then return nil end
    -- FGameplayTag exposes ToString directly (returns "GameTag.Foo.Bar").
    local s = text_to_str(tag)
    if s then return s end
    -- Fallback : pull TagName (FName) and route through ToString.
    local nm
    pcall(function() nm = tag.TagName end)
    return text_to_str(nm)
end

-- Public : enumerate every loaded UDifficultySettingData, dump metadata +
-- current value to ipc/world_settings.json, and stash an id->asset map for
-- subsequent set_value calls.
function M.scan()
    _scan_index = {}
    _scan_count = 0

    local sub = get_difficulty_subsystem()
    local assets = collect_assets()

    -- Build rows in a single pass. Skip dead wrappers via the same
    -- GetFullName pcall that apply() uses.
    local rows = {}
    for _, asset in ipairs(assets) do
        local fn
        local fn_ok = pcall(function() fn = asset:GetFullName() end)
        if fn_ok and fn then
            local name    = safe_name(asset) or fn
            local display = read_display_name(asset)
            local pa, ca  = read_state(asset)
            local tag     = read_tag(asset)
            local slider  = read_slider(asset)
            local digital
            pcall(function() digital = asset.bDigitalValue end)
            local section = read_section(asset)
            local cur_val, cur_src = read_current_value(asset, sub)

            rows[#rows + 1] = {
                ref = asset, fn = fn, name = name, display = display,
                pa = pa, ca = ca, tag = tag, slider = slider,
                digital = digital, section = section,
                current = cur_val, current_source = cur_src,
            }
        end
    end

    -- Sort by display name (falls back to internal name) so the WPF
    -- list reads alphabetically the same way the in-game menu does.
    table.sort(rows, function(a, b)
        return (a.display or a.name) < (b.display or b.name)
    end)

    local entries = {}
    for i, r in ipairs(rows) do
        _scan_index[i] = { ref = r.ref, fn = r.fn, name = r.name }
        _scan_count = i

        local slider_json = "null"
        if r.slider then
            slider_json = string.format(
                '{"min":%s,"max":%s,"decimals":%s,"postfix":"%s"}',
                tostring(r.slider.min or "null"),
                tostring(r.slider.max or "null"),
                tostring(r.slider.decimals or "null"),
                escape_json(r.slider.postfix or ""))
        end
        local current_json = (type(r.current) == "number") and tostring(r.current) or "null"

        entries[#entries + 1] = string.format(
            '{"id":%d,"name":"%s","display":"%s","full_name":"%s","tag":"%s","section":"%s",'
            .. '"player_adj":%s,"can_after_create":%s,"digital":%s,'
            .. '"current":%s,"current_source":"%s","slider":%s}',
            i,
            escape_json(r.name),
            escape_json(r.display or r.name),
            escape_json(r.fn),
            escape_json(r.tag or ""),
            escape_json(r.section or ""),
            tostring(r.pa or "null"),
            (r.ca == true) and "true" or "false",
            (r.digital == true) and "true" or "false",
            current_json,
            r.current_source or "unknown",
            slider_json)
    end

    local body = '{"generated_unix":' .. tostring(os.time())
        .. ',"count":' .. tostring(#entries)
        .. ',"settings":[' .. table.concat(entries, ",") .. "]}"
    local path = get_world_settings_json_path()
    local wok, werr = write_atomic(path, body)
    if not wok then return false, werr end
    print(string.format("[RSDWTools] world.settings.scan : count=%d -> %s",
        #entries, tostring(path)))
    return true, "count=" .. tostring(#entries)
end

-- Public : overwrite the FrontEndSliderData range on a setting asset
-- so the in-game World Settings UI lets the user pick values outside
-- the developer-defined min/max. The actual current value is left to
-- the in-game slider -- we're only widening the bounds it operates in.
--
-- Argument format : "<id> <min> <max>"  (id from the last scan).
function M.set_range(args_str)
    local raw = (args_str or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local id_s, min_s, max_s = raw:match("^(%S+)%s+(%S+)%s+(%S+)$")
    if not id_s then
        return false, "usage: world.settings.set_range <id> <min> <max>"
    end
    local id   = tonumber(id_s)
    local mn   = tonumber(min_s)
    local mx   = tonumber(max_s)
    if not id or not mn or not mx then
        return false, "id, min and max must be numeric"
    end
    if mx < mn then
        return false, "max must be >= min"
    end
    local entry = _scan_index[id]
    if not entry or not is_valid(entry.ref) then
        return false, "id " .. tostring(id) .. " not in scan (rescan?)"
    end
    local asset = entry.ref

    local fe
    pcall(function() fe = asset.FrontEndSliderData end)
    if not fe then
        return false, "asset has no FrontEndSliderData"
    end

    -- Read prior bounds for the status line.
    local prev_min, prev_max
    pcall(function() prev_min = fe.MinValue end)
    pcall(function() prev_max = fe.MaxValue end)

    -- Struct fields on a UObject are writeable directly through UE4SS.
    local wok_min, werr_min = pcall(function() fe.MinValue = mn end)
    local wok_max, werr_max = pcall(function() fe.MaxValue = mx end)
    if not wok_min or not wok_max then
        return false, "slider write failed: "
            .. tostring(werr_min) .. " / " .. tostring(werr_max)
    end

    -- Verify the writes stuck (some UE4SS struct accessors copy back
    -- silently on failure ; reading the values again proves the change).
    local now_min, now_max
    pcall(function() now_min = asset.FrontEndSliderData.MinValue end)
    pcall(function() now_max = asset.FrontEndSliderData.MaxValue end)

    print(string.format(
        "[RSDWTools] world.settings.set_range id=%d %s : [%s..%s] -> [%s..%s]",
        id, tostring(entry.name),
        tostring(prev_min), tostring(prev_max),
        tostring(now_min),  tostring(now_max)))
    return true, string.format("id=%d %s : [%s..%s] -> [%s..%s]",
        id, tostring(entry.name),
        tostring(prev_min), tostring(prev_max),
        tostring(now_min),  tostring(now_max))
end

return M
