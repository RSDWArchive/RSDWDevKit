-- feature_assets.lua
--
-- Generic AssetRegistry browser. Generalizes the pattern proven in
-- feature_buildings.catalog_disk : resolve UAssetRegistryHelpers ->
-- IAssetRegistry, then sweep by class or path and serialize each
-- FAssetData row to a flat JSON record.
--
-- Verbs exposed:
--   world.assets.classes           -- enumerate UDataAsset / UDominionDataAsset
--                                     subclasses currently visible to the
--                                     AssetRegistry. Output : ipc/assets/_classes.json
--   world.assets.catalog <Class>   -- sweep every cooked asset of that class
--                                     (subclasses included) and dump
--                                     ipc/assets/_catalog_<Class>.json
--                                     <Class> may be bare (e.g. ItemData,
--                                     defaults to /Script/Dominion) or
--                                     fully qualified (Dominion.ItemData,
--                                     Engine.UserDefinedStruct, etc.)
--   world.assets.paths [root]      -- dump cached AssetRegistry paths under
--                                     the given root (default: /Game).
--                                     Output : ipc/assets/_paths_<root>.json
--
-- Design notes:
--   * Reuses the FAssetData -> record decode logic that the buildings
--     catalog already validated against UE5 cooked builds (legacy
--     AssetClass returns None ; we read AssetClassPath.AssetName).
--   * Output goes to a sibling `assets/` IPC folder so the building
--     feature's catalogs stay isolated from generic dumps.
--   * No filtering on the catalog verb -- the WPF side / downstream
--     scripts can post-filter. We do, however, capture asset_class on
--     every record so a misrouted asset is visible.

local M = {}

local mod_paths = require("mod_paths")

-- ---------------------------------------------------------------------------
-- ipc/assets folder. Mirrors mod_paths.buildings_dir (kept in mod_paths
-- itself) but we keep this thin shim local to avoid a churn in mod_paths
-- if assets ever needs subfolders. Falls back to mod_paths.assets_dir if
-- defined ; otherwise computes from ipc_dir() directly.
-- ---------------------------------------------------------------------------
local function assets_dir()
    if type(mod_paths.assets_dir) == "function" then
        return mod_paths.assets_dir()
    end
    local ipc = mod_paths.ipc_dir()
    if not ipc then return nil end
    local path = ipc .. "\\assets"
    pcall(os.execute, ('if not exist "%s" mkdir "%s"'):format(path, path))
    return path
end

-- ---------------------------------------------------------------------------
-- Validity helper -- some object handles come back as stale userdata after
-- a level transition. Mirrors feature_actor.is_valid_object minus the
-- feature_actor dep so this module is standalone-loadable from probes.
-- ---------------------------------------------------------------------------
local function is_valid(obj)
    if type(obj) ~= "userdata" then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    if ok and valid == false then return false end
    return true
end

-- ---------------------------------------------------------------------------
-- FName / TArray-element unwrap. UE4SS wraps reflected TArray<TStruct>
-- elements in LocalUnrealParam ; one or two :get() calls peel back to
-- the underlying userdata. fname_to_string also handles the rare case
-- where an FName field surfaces as a plain Lua string.
-- ---------------------------------------------------------------------------
local function unwrap_param(v)
    if type(v) ~= "userdata" then return v end
    for _ = 1, 2 do
        local has_get = false
        pcall(function() has_get = (type(v.get) == "function") end)
        if not has_get then return v end
        local ok, inner = pcall(function() return v:get() end)
        if not ok or inner == nil then return v end
        v = inner
        if type(v) ~= "userdata" then return v end
    end
    return v
end

local function fname_to_string(v)
    if v == nil then return nil end
    if type(v) == "string" then return v end
    if type(v) == "userdata" then
        for _ = 1, 2 do
            if type(v) == "userdata" then
                local has_get = false
                pcall(function() has_get = (type(v.get) == "function") end)
                if has_get then
                    local ok, inner = pcall(function() return v:get() end)
                    if ok and inner ~= nil then v = inner else break end
                else
                    break
                end
            else
                break
            end
        end
        if type(v) == "string" then return v end
        if type(v) == "userdata" then
            for _, m in ipairs({ "ToString", "GetName", "GetPlainNameString" }) do
                local ok, s = pcall(function() return v[m](v) end)
                if ok and type(s) == "string" and s ~= "" then return s end
            end
        end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- AssetRegistry handle resolution. Same call site BPModLoaderMod uses --
-- find the helpers CDO, then ask it for the live registry. We return
-- both because a few of the helper APIs we want (IsAssetLoaded,
-- GetTagValue) live on the helpers CDO rather than the registry.
-- ---------------------------------------------------------------------------
local function resolve_registry()
    if not StaticFindObject then
        return nil, nil, "StaticFindObject unavailable"
    end
    local helpers = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers")
    if not is_valid(helpers) then
        return nil, nil, "UAssetRegistryHelpers CDO not found"
    end
    local ok, reg = pcall(function() return helpers:GetAssetRegistry() end)
    if not ok or not is_valid(reg) then
        return nil, helpers, "GetAssetRegistry failed: " .. tostring(reg)
    end
    return reg, helpers, nil
end

-- ---------------------------------------------------------------------------
-- JSON helpers (hand-rolled to match the rest of the mod, no cjson).
-- ---------------------------------------------------------------------------
local function json_escape_str(s)
    local escaped = tostring(s or "")
        :gsub("\\", "\\\\")
        :gsub('"', '\\"')
        :gsub("\n", "\\n")
        :gsub("\r", "\\r")
        :gsub("\t", "\\t")
    return '"' .. escaped .. '"'
end

local function json_str_or_null(v)
    if v == nil then return "null" end
    return json_escape_str(v)
end

-- ---------------------------------------------------------------------------
-- FAssetData -> flat record. Same field set as buildings.catalog.disk
-- so downstream consumers can share the decoder.
-- ---------------------------------------------------------------------------
local function asset_data_to_record(entry, helpers)
    local rec = { errors = {} }
    local function try(field, fn)
        local ok, err = pcall(fn)
        if not ok then rec.errors[#rec.errors + 1] = field .. ":" .. tostring(err) end
    end
    try("PackageName", function() rec.package_name = fname_to_string(entry.PackageName) end)
    try("PackagePath", function() rec.package_path = fname_to_string(entry.PackagePath) end)
    try("AssetName",   function() rec.asset_name   = fname_to_string(entry.AssetName) end)
    try("AssetClass",  function() rec.asset_class_legacy = fname_to_string(entry.AssetClass) end)
    try("AssetClassPath.PackageName", function()
        rec.asset_class_package = fname_to_string(entry.AssetClassPath.PackageName)
    end)
    try("AssetClassPath.AssetName", function()
        rec.asset_class = fname_to_string(entry.AssetClassPath.AssetName)
    end)
    if not rec.asset_class and rec.asset_class_legacy
        and rec.asset_class_legacy ~= "" and rec.asset_class_legacy ~= "None" then
        rec.asset_class = rec.asset_class_legacy
    end
    if rec.package_name and rec.asset_name then
        rec.object_path = rec.package_name .. "." .. rec.asset_name
    end
    if helpers and is_valid(helpers) then
        try("IsAssetLoaded", function() rec.loaded = helpers:IsAssetLoaded(entry) end)
    end
    return rec
end

-- ---------------------------------------------------------------------------
-- Filename sanitizer. Same rules as feature_buildings.sanitize_name --
-- letters / digits / dash / underscore ; everything else collapses to _.
-- ---------------------------------------------------------------------------
local function sanitize_name(name)
    local s = tostring(name or ""):gsub("^%s+", ""):gsub("%s+$", "")
    s = s:gsub("%.[Jj][Ss][Oo][Nn]$", "")
    if s == "" then return "default" end
    return (s:gsub("[^%w%-_]", "_"))
end

-- ---------------------------------------------------------------------------
-- Class spec parser. Accepts:
--   "ItemData"               -> { pkg = "/Script/Dominion", name = "ItemData" }
--   "Dominion.ItemData"      -> { pkg = "/Script/Dominion", name = "ItemData" }
--   "Engine.PrimaryAssetLabel" -> { pkg = "/Script/Engine", name = "PrimaryAssetLabel" }
--   "/Script/Foo.Bar"        -> { pkg = "/Script/Foo", name = "Bar" }
-- A leading 'U' is stripped to make `UItemData` (header style) work.
-- ---------------------------------------------------------------------------
local function parse_class_spec(spec)
    local s = (spec or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if s == "" then return nil, "empty class spec" end
    local pkg, name
    if s:sub(1, 1) == "/" then
        pkg, name = s:match("^(.*)%.([^%.]+)$")
        if not pkg then return nil, "expected /Script/Pkg.Name form" end
    elseif s:find("%.") then
        local short_pkg
        short_pkg, name = s:match("^([^%.]+)%.(.+)$")
        pkg = "/Script/" .. short_pkg
    else
        pkg = "/Script/Dominion"
        name = s
    end
    -- Tolerate UPascalCase header form.
    if #name > 1 and name:sub(1, 1) == "U" and name:sub(2, 2):match("%u") then
        name = name:sub(2)
    end
    return { pkg = pkg, name = name }
end

-- ===========================================================================
-- world.assets.catalog <ClassName>
--
-- Two-phase sweep:
--   1. GetAssetsByClass(target, OutAssetData, bSearchSubClasses=true) --
--      catches every native subclass + the small subset of BP classes
--      that the registry maps under the native parent (e.g. ItemData
--      already pulls 26 subclass buckets including BP_Consumables_*).
--   2. GetDerivedClassNames(target) -> for every derived class we did
--      not already cover, GetAssetsByClass(derived, ..., false). This
--      catches Blueprint generated classes (e.g. BP_AI_Wolf_Data_C)
--      whose assets are filed under the BP class itself in cooked
--      builds, not under their native ancestor.
--
-- Records are deduped by object_path across phases so an asset that
-- appears in both sweeps only ends up once.
-- ===========================================================================

-- Forward decl : scan_derived is also used by M.classes further down
-- and is defined there to keep its docs near classes(). We hoist a
-- local stub here so M.catalog can call it without reordering the file.
local scan_derived

-- Sweep one class. Returns (records[], err). Records are FAssetData
-- decoded via asset_data_to_record.
local function sweep_one_class(registry, helpers, pkg, name, search_subclasses)
    local class_path = { PackageName = FName(pkg), AssetName = FName(name) }
    local out = {}
    local ok, err = pcall(function()
        registry:GetAssetsByClass(class_path, out, search_subclasses)
    end)
    if not ok then return nil, "GetAssetsByClass failed: " .. tostring(err) end
    local n = 0
    pcall(function() n = #out end)
    local recs = {}
    for i = 1, n do
        local entry = unwrap_param(out[i])
        if entry then
            recs[#recs + 1] = asset_data_to_record(entry, helpers)
        end
    end
    return recs, nil
end

function M.catalog(args_str)
    local raw = (args_str or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if raw == "" then
        return false, "usage: world.assets.catalog <ClassName>  (e.g. ItemData)"
    end
    local spec, perr = parse_class_spec(raw)
    if not spec then return false, perr end

    local dir = assets_dir()
    if not dir then
        return false, "could not resolve mod ipc directory (game not loaded?)"
    end
    local out_path = dir .. "\\_catalog_" .. sanitize_name(spec.name) .. ".json"

    local registry, helpers, rerr = resolve_registry()
    if not registry then return false, rerr end

    local kept = {}
    local seen = {} -- object_path -> true
    local class_hist = {}
    local error_hist = {}

    local function ingest(recs, source_label)
        for _, rec in ipairs(recs) do
            for _, err in ipairs(rec.errors) do
                local k = err:match("^([^:]+)") or err
                error_hist[k] = (error_hist[k] or 0) + 1
            end
            local key = rec.object_path
            if key and not seen[key] then
                seen[key] = true
                rec.via = source_label
                kept[#kept + 1] = rec
                local cls = rec.asset_class or "<nil>"
                class_hist[cls] = (class_hist[cls] or 0) + 1
            end
        end
    end

    -- Phase 1: native sweep with subclasses.
    local phase1, e1 = sweep_one_class(registry, helpers, spec.pkg, spec.name, true)
    if not phase1 then return false, e1 end
    ingest(phase1, "native")

    -- Phase 2: enumerate derived classes (catches BP classes the native
    -- sweep missed) and sweep each. We pass bSearchSubClasses=false to
    -- avoid overlap with phase 1 -- the derived list already includes
    -- the full transitive closure.
    local derived_count = 0
    local derived_swept = 0
    local derived_err = nil
    local derived_list, derr = scan_derived(registry, spec.pkg, spec.name)
    if derr then
        derived_err = derr
    elseif derived_list then
        derived_count = #derived_list
        for _, c in ipairs(derived_list) do
            if c.package and c.name then
                -- Skip self : the native sweep already covers it.
                if not (c.package == spec.pkg and c.name == spec.name) then
                    local recs, e = sweep_one_class(registry, helpers, c.package, c.name, false)
                    if recs then
                        ingest(recs, c.full)
                        derived_swept = derived_swept + 1
                    end
                end
            end
        end
    end

    table.sort(kept, function(a, b)
        return (a.object_path or "") < (b.object_path or "")
    end)

    local body_parts = {}
    body_parts[#body_parts + 1] = '{"schema":"rsdwtools.assets.catalog.v2"'
    body_parts[#body_parts + 1] = ',"generated_unix":' .. tostring(os.time())
    body_parts[#body_parts + 1] = ',"class_package":' .. json_escape_str(spec.pkg)
    body_parts[#body_parts + 1] = ',"class_name":' .. json_escape_str(spec.name)
    body_parts[#body_parts + 1] = ',"include_subclasses":true'
    body_parts[#body_parts + 1] = ',"derived_classes":' .. tostring(derived_count)
    body_parts[#body_parts + 1] = ',"derived_classes_swept":' .. tostring(derived_swept)
    if derived_err then
        body_parts[#body_parts + 1] = ',"derived_classes_error":' .. json_escape_str(derived_err)
    end
    body_parts[#body_parts + 1] = ',"count":' .. tostring(#kept)
    body_parts[#body_parts + 1] = ',"class_histogram":{'
    do
        local first = true
        for cls, n in pairs(class_hist) do
            if not first then body_parts[#body_parts + 1] = "," end
            first = false
            body_parts[#body_parts + 1] = json_str_or_null(cls) .. ":" .. tostring(n)
        end
    end
    body_parts[#body_parts + 1] = '},"error_histogram":{'
    do
        local first = true
        for f, n in pairs(error_hist) do
            if not first then body_parts[#body_parts + 1] = "," end
            first = false
            body_parts[#body_parts + 1] = json_str_or_null(f) .. ":" .. tostring(n)
        end
    end
    body_parts[#body_parts + 1] = '},"assets":['
    for i = 1, #kept do
        if i > 1 then body_parts[#body_parts + 1] = "," end
        local r = kept[i]
        body_parts[#body_parts + 1] = "{"
            .. '"object_path":'  .. json_str_or_null(r.object_path)
            .. ',"package_name":' .. json_str_or_null(r.package_name)
            .. ',"package_path":' .. json_str_or_null(r.package_path)
            .. ',"asset_name":'   .. json_str_or_null(r.asset_name)
            .. ',"asset_class":'  .. json_str_or_null(r.asset_class)
            .. ',"asset_class_package":' .. json_str_or_null(r.asset_class_package)
            .. ',"loaded":'       .. (r.loaded == true and "true" or "false")
            .. "}"
    end
    body_parts[#body_parts + 1] = "]}"
    local body = table.concat(body_parts)

    local ok_w, detail = mod_paths.write_atomic(out_path, body)
    if not ok_w then
        return false, "write failed: " .. tostring(detail)
    end
    print(string.format("[RSDWTools] assets.catalog: class=%s.%s count=%d -> %s",
        spec.pkg, spec.name, #kept, out_path))
    return true, string.format("class=%s.%s count=%d path=%s",
        spec.pkg, spec.name, #kept, out_path)
end

-- ===========================================================================
-- world.assets.classes
--
-- Discovery: enumerate every direct/indirect subclass of UDataAsset
-- (and UDominionDataAsset for clarity) that the AssetRegistry knows
-- about. Useful before committing to a class for catalog ; the runtime
-- set may differ from the cxx header dump because some classes are
-- editor-only and stripped from the cooked build.
--
-- Mechanism: GetDerivedClassNames(InClassNames, ExcludedClassNames,
--                                OutDerivedClassNames).
-- We seed two scans (DataAsset + DominionDataAsset) so the result file
-- carries both lists distinctly ; the union is implicitly the DataAsset
-- scan, but the Dominion-only subset is the more interesting one for
-- gameplay catalogs.
-- ===========================================================================
local function scan_derived_impl(registry, parent_pkg, parent_name)
    local in_arr = {
        { PackageName = FName(parent_pkg), AssetName = FName(parent_name) },
    }
    local excluded = {}
    local out_set = {}
    local ok, err = pcall(function()
        registry:GetDerivedClassNames(in_arr, excluded, out_set)
    end)
    if not ok then return nil, "GetDerivedClassNames failed: " .. tostring(err) end

    -- TSet output marshaling: try # then :Num(). UE4SS exposes set
    -- iteration as either Lua array-style or via :Num() + index.
    local n = 0
    pcall(function() n = #out_set end)
    if n == 0 then
        pcall(function() local v = out_set:Num(); if type(v) == "number" then n = v end end)
    end
    local list = {}
    for i = 1, n do
        local entry = unwrap_param(out_set[i])
        if entry ~= nil then
            local rec = {}
            pcall(function() rec.package = fname_to_string(entry.PackageName) end)
            pcall(function() rec.name    = fname_to_string(entry.AssetName) end)
            if rec.package or rec.name then
                rec.full = (rec.package or "") .. "." .. (rec.name or "")
                list[#list + 1] = rec
            end
        end
    end
    table.sort(list, function(a, b) return (a.full or "") < (b.full or "") end)
    return list, nil
end

-- Bind the forward-declared upvalue so M.catalog (defined earlier) can
-- call scan_derived. Lua resolves locals lexically at call time, but the
-- assignment must happen before the first call ; module require returns
-- M only after both definitions have run, so the timing is correct.
scan_derived = scan_derived_impl

function M.classes()
    local dir = assets_dir()
    if not dir then return false, "could not resolve mod ipc directory" end

    local registry, _helpers, rerr = resolve_registry()
    if not registry then return false, rerr end

    local scans = {
        { label = "DataAsset",         pkg = "/Script/Engine",   name = "DataAsset" },
        { label = "PrimaryDataAsset",  pkg = "/Script/Engine",   name = "PrimaryDataAsset" },
        { label = "DominionDataAsset", pkg = "/Script/Dominion", name = "DominionDataAsset" },
    }
    local results = {}
    for _, s in ipairs(scans) do
        local list, err = scan_derived(registry, s.pkg, s.name)
        results[#results + 1] = {
            label = s.label, pkg = s.pkg, name = s.name,
            list = list or {}, err = err,
        }
    end

    local body = { '{"schema":"rsdwtools.assets.classes.v1"' }
    body[#body + 1] = ',"generated_unix":' .. tostring(os.time())
    body[#body + 1] = ',"scans":['
    for si, s in ipairs(results) do
        if si > 1 then body[#body + 1] = "," end
        body[#body + 1] = "{"
            .. '"label":'   .. json_escape_str(s.label)
            .. ',"parent":' .. json_escape_str(s.pkg .. "." .. s.name)
            .. ',"count":'  .. tostring(#s.list)
            .. ',"error":'  .. json_str_or_null(s.err)
            .. ',"classes":['
        for i, c in ipairs(s.list) do
            if i > 1 then body[#body + 1] = "," end
            body[#body + 1] = "{"
                .. '"package":' .. json_str_or_null(c.package)
                .. ',"name":'   .. json_str_or_null(c.name)
                .. ',"full":'   .. json_str_or_null(c.full)
                .. "}"
        end
        body[#body + 1] = "]}"
    end
    body[#body + 1] = "]}"

    local out_path = dir .. "\\_classes.json"
    local ok, detail = mod_paths.write_atomic(out_path, table.concat(body))
    if not ok then return false, "write failed: " .. tostring(detail) end

    -- Mirror the per-scan counts to stdout so the log scrape sees them.
    for _, s in ipairs(results) do
        print(string.format("[RSDWTools] assets.classes: %s -> %d subclasses%s",
            s.label, #s.list, s.err and (" (err: " .. s.err .. ")") or ""))
    end
    print("[RSDWTools] assets.classes: wrote " .. out_path)
    return true, string.format("scans=%d path=%s", #results, out_path)
end

-- ===========================================================================
-- world.assets.paths [root]
--
-- Dumps GetSubPaths(root, recursive=true) ; useful for discovering where
-- a class lives on disk before deciding whether to scope a catalog by
-- path. Default root is /Game.
-- ===========================================================================
function M.paths(args_str)
    local raw = (args_str or ""):gsub("^%s+", ""):gsub("%s+$", "")
    local root = raw == "" and "/Game" or raw

    local dir = assets_dir()
    if not dir then return false, "could not resolve mod ipc directory" end

    local registry, _helpers, rerr = resolve_registry()
    if not registry then return false, rerr end

    local out_arr = {}
    local ok, err = pcall(function()
        registry:GetSubPaths(root, out_arr, true)
    end)
    if not ok then return false, "GetSubPaths failed: " .. tostring(err) end

    local n = 0
    pcall(function() n = #out_arr end)
    local list = {}
    for i = 1, n do
        local v = unwrap_param(out_arr[i])
        local s
        if type(v) == "string" then
            s = v
        elseif type(v) == "userdata" then
            pcall(function() s = v:ToString() end)
            if not s then pcall(function() s = tostring(v) end) end
        end
        if type(s) == "string" and s ~= "" then
            list[#list + 1] = s
        end
    end
    table.sort(list)

    local out_path = dir .. "\\_paths_" .. sanitize_name(root) .. ".json"
    local body = { '{"schema":"rsdwtools.assets.paths.v1"' }
    body[#body + 1] = ',"generated_unix":' .. tostring(os.time())
    body[#body + 1] = ',"root":' .. json_escape_str(root)
    body[#body + 1] = ',"count":' .. tostring(#list)
    body[#body + 1] = ',"paths":['
    for i, p in ipairs(list) do
        if i > 1 then body[#body + 1] = "," end
        body[#body + 1] = json_escape_str(p)
    end
    body[#body + 1] = "]}"

    local ok_w, detail = mod_paths.write_atomic(out_path, table.concat(body))
    if not ok_w then return false, "write failed: " .. tostring(detail) end
    print(string.format("[RSDWTools] assets.paths: root=%s count=%d -> %s",
        root, #list, out_path))
    return true, string.format("root=%s count=%d path=%s", root, #list, out_path)
end

return M
