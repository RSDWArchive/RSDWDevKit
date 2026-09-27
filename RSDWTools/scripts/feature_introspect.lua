-- Feature: actor introspection (Scan -> Inspect drilldown).
--
-- Restored in Round 30+ after the Round 29 catalog refactor stripped the
-- per-system dumpers. The Scan tab's "Inspect" right-click button still
-- expects the same JSON shape it always did:
--
--   {
--     "name":  "<actor short name>",
--     "class": "<runtime UClass FName>",
--     "class_chain": { "0": "TopMost", "1": "Super", ... },
--     "groups": {
--       "0": {
--         "class":   "<class FName for this strut>",
--         "resolved": true,
--         "fields":  { "0": { "name", "type", "value", "readable" }, ... },
--         "methods": { "0": { "name", "signature" }, ... }
--       },
--       "1": { ... }
--     }
--   }
--
-- Groups are emitted top-down from runtime class -> ... -> UObject so the
-- WPF tree shows the most-specific class first.
--
-- Two router verbs land here:
--   actor.info <short-name>
--     -> dump the named actor.
--   actor.info.field <short-name> <segment>[.<segment>...]
--     -> walk one or more nested UObject* fields starting at the named
--        actor and dump the leaf object. Each segment is a property name
--        on the object reached by the previous segment. Falls back to a
--        single-flat dump of the parent + an explanatory message in the
--        ack if a segment isn't readable as an object.
--
-- The dump file is written atomically to <modroot>/ipc/actor_info.json and
-- WPF picks it up by polling the mtime (see RunInspect / WaitForActorInfo
-- in MainWindow.xaml.cs). All native touches are pcall-guarded ; an AV
-- inside Lua-bound UE reflection still kills the process, but Lua-level
-- type errors / missing methods will be reported back via the ack instead
-- of crashing the game thread.

local M = {}

local feature_actor = require("feature_actor")
local mod_paths = require("mod_paths")

-- Set INTROSPECT_VERBOSE = true to log every property + method as
-- they're enumerated. Costly (large classes get noisy), but the log
-- breadcrumb is the only way to identify which field crashed the
-- game thread when a non-pcall'able native AV hits. Toggled here
-- because Lua reflection AVs are reproducible per-actor-class but
-- *not* discoverable any other way.
-- DEFAULT ON until inspect is proven stable across the actor zoo ;
-- flip to false once we've added enough class names to the deny set.
-- Round 31: flipped OFF. Per-property prints made AiHealthComponent
-- (and presumably any UActorComponent-derived) dumps slow enough that
-- the C# 12s mtime-poll window was timing out before the JSON landed.
-- Re-enable temporarily if a new crash class appears.
local INTROSPECT_VERBOSE = false

-- ============================================================
-- JSON encoding
-- ============================================================

-- Same conservative escape as feature_ui.escape_json. Strips control bytes
-- so the WPF JsonDocument parser never trips on a stray 0x01 in a property
-- name (UE FNames can contain them on corrupted slots).
local function escape_json(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
    s = s:gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    s = s:gsub("[%z\1-\8\11\12\14-\31]", "")
    return s
end

local function jstr(s) return '"' .. escape_json(s) .. '"' end
local function jbool(b) return b and "true" or "false" end

-- Emit an ordered map keyed by stringified indices ("0","1",...). The C#
-- parser rebuilds the order from those keys (see ParseInspectGroup), so
-- as long as we hand out monotonic indices the WPF tree shows fields in
-- the order we walked them.
local function emit_indexed_map(parts, items, item_to_json)
    local n = #items
    parts[#parts + 1] = "{"
    for i = 1, n do
        if i > 1 then parts[#parts + 1] = "," end
        parts[#parts + 1] = '"' .. tostring(i - 1) .. '":'
        parts[#parts + 1] = item_to_json(items[i])
    end
    parts[#parts + 1] = "}"
end

-- ============================================================
-- UE reflection helpers
-- ============================================================

local function is_valid(obj)
    return obj and obj.IsValid and obj:IsValid()
end

local function safe_fname(obj, getter)
    -- getter is the method name on `obj` returning an FName. Returns the
    -- string form, or "" if the call fails / the FName is None.
    if not obj then return "" end
    local ok, fname = pcall(function() return obj[getter](obj) end)
    if not ok or fname == nil then return "" end
    local ok2, name = pcall(function()
        if fname.ToString then return fname:ToString() end
        return tostring(fname)
    end)
    if not ok2 or not name then return "" end
    return name
end

-- Returns the class FName of an arbitrary UObject (or "").
local function obj_class_name(obj)
    if not obj then return "" end
    local ok, cls = pcall(function() return obj:GetClass() end)
    if not ok or not cls then return "" end
    return safe_fname(cls, "GetFName")
end

-- Walk the class chain starting at obj's runtime class up through every
-- super struct. Returns an ordered list of UStruct handles (most-derived
-- first).
--
-- Termination strategy mirrors the official UE4SS ConsoleCommandsMod
-- dump_object.lua: keep walking while the struct's :IsValid() is true.
-- The earlier attempt that compared the returned super against nil /
-- against the current pointer was the AV: GetSuperStruct() hands back
-- an INVALID userdata (not nil) at the top of the chain, and any further
-- vtable call on it crashes in native code. :IsValid() is the safe probe
-- because UE4SS implements it on the wrapper without dispatching into
-- the underlying object.
local function build_class_chain(obj)
    local chain = {}
    if not obj then return chain end
    local ok_cls, cls = pcall(function() return obj:GetClass() end)
    if not ok_cls or not cls then return chain end
    local current = cls
    for _ = 1, 64 do
        local ok_valid, valid = pcall(function() return current:IsValid() end)
        if not ok_valid or not valid then break end
        chain[#chain + 1] = current
        local ok_super, super = pcall(function() return current:GetSuperStruct() end)
        if not ok_super or not super then break end
        current = super
    end
    return chain
end

-- Stringify a value read off a property. Numeric / bool / string types
-- print directly. UObject-typed values get class + short name. Everything
-- else falls back to type(...) + tostring(...) and gets truncated so the
-- WPF tree doesn't have to render multi-MB structs.
local MAX_VALUE_LEN = 240

local function stringify_value(v)
    if v == nil then return "nil" end
    local t = type(v)
    if t == "string" then
        if #v > MAX_VALUE_LEN then return v:sub(1, MAX_VALUE_LEN) .. "..." end
        return v
    end
    if t == "number" then
        if v ~= v then return "nan" end          -- NaN
        if v == math.huge then return "inf" end
        if v == -math.huge then return "-inf" end
        -- Trim trailing zeros on floats so 1.0 doesn't show as "1.0000000".
        local s = tostring(v)
        return s
    end
    if t == "boolean" then return v and "true" or "false" end
    if t == "userdata" then
        -- Probe IsValid FIRST. ObjectProperty reads on Actor::Owner /
        -- AttachParent / similar can return an invalid userdata wrapper
        -- (NOT nil). Calling :GetClass() / :GetFName() on that wrapper
        -- AVs in native code. IsValid() is implemented on the wrapper
        -- itself and is safe regardless of underlying pointer state.
        local ok_valid, valid = pcall(function() return v:IsValid() end)
        if not ok_valid or not valid then return "<invalid>" end
        local cls = obj_class_name(v)
        -- Prefer GetFullName : returns "ClassName /Path.To.Asset" which
        -- contains everything the deep-dump walker needs to LoadAsset
        -- the referenced object. Falls back to "Class 'LeafName'" when
        -- GetFullName isn't available (some BP wrappers) so we never
        -- regress to a less-informative output.
        local ok_full, full = pcall(function() return v:GetFullName() end)
        if ok_full and type(full) == "string" and full ~= "" then
            -- Strip the leading class name : the walker only needs the
            -- path. Format is "ClassName /Game/Foo/Bar.Bar" with a
            -- single space ; degrade gracefully if the shape changes.
            local path = full:match("^%S+%s+(.+)$") or full
            if cls ~= "" then
                local out = cls .. " '" .. path .. "'"
                if #out > MAX_VALUE_LEN then return out:sub(1, MAX_VALUE_LEN) .. "..." end
                return out
            end
            if #full > MAX_VALUE_LEN then return full:sub(1, MAX_VALUE_LEN) .. "..." end
            return full
        end
        local nm = safe_fname(v, "GetFName")
        if cls ~= "" and nm ~= "" then return cls .. " '" .. nm .. "'" end
        if cls ~= "" then return cls end
        local ok_str, s = pcall(tostring, v)
        if ok_str and s then
            if #s > MAX_VALUE_LEN then return s:sub(1, MAX_VALUE_LEN) .. "..." end
            return s
        end
        return "<userdata>"
    end
    if t == "table" then return "<table>" end
    local ok_str, s = pcall(tostring, v)
    if not ok_str or not s then return "<" .. t .. ">" end
    if #s > MAX_VALUE_LEN then return s:sub(1, MAX_VALUE_LEN) .. "..." end
    return s
end

-- Property classes whose values we trust ourselves to read off a live
-- UObject via `obj[name]`. Anything outside this set gets type-only
-- output (value shows "<unsupported>", readable=false). This is a
-- crash-avoidance whitelist: AV'd a Redberry bush dump in the wild
-- because some non-scalar / non-object property hit unmarshalable
-- memory inside UE4SS. Containers (Array/Map/Set), structs, and
-- delegates are the usual offenders ; expand this set deliberately
-- once a given class has been smoke-tested.
--
-- DO NOT add TextProperty / NameProperty / StrProperty back without a
-- proven-safe reader: marshalling FText / FName / FString back to Lua
-- routes through the userdata wrapper layer and AVs on certain BP
-- properties (confirmed: WorldActor::DisplayName, 2026-05-03). The
-- safety.lua module documents the same shape hazard for these types.
local READABLE_PROPERTY_CLASSES = {
    BoolProperty       = true,
    ByteProperty       = true,
    Int8Property       = true,
    Int16Property      = true,
    IntProperty        = true,
    Int64Property      = true,
    UInt16Property     = true,
    UInt32Property     = true,
    UInt64Property     = true,
    FloatProperty      = true,
    DoubleProperty     = true,
    EnumProperty       = true,
    ObjectProperty     = true,
    WeakObjectProperty = true,
    LazyObjectProperty = true,
    SoftObjectProperty = true,
    ClassProperty      = true,
    SoftClassProperty  = true,
    InterfaceProperty  = true,
    -- Container reads route through dedicated paths in try_read_field
    -- and only handle scalar element types ; element-wise crash hazards
    -- are caught by per-element pcall + element-class check.
    ArrayProperty      = true,
}

-- Property class names of array elements we are willing to dereference.
-- Mirrors the readable-scalars set above minus container types ; struct
-- / delegate / text / name / string elements stay opaque to avoid the
-- same FText/FName marshalling AVs that bit us on scalars.
local READABLE_ARRAY_ELEMENT_CLASSES = {
    BoolProperty       = true,
    ByteProperty       = true,
    Int8Property       = true,
    Int16Property      = true,
    IntProperty        = true,
    Int64Property      = true,
    UInt16Property     = true,
    UInt32Property     = true,
    UInt64Property     = true,
    FloatProperty      = true,
    DoubleProperty     = true,
    EnumProperty       = true,
    ObjectProperty     = true,
    WeakObjectProperty = true,
    LazyObjectProperty = true,
    SoftObjectProperty = true,
    ClassProperty      = true,
    SoftClassProperty  = true,
    InterfaceProperty  = true,
}

-- Hard cap on rendered array elements ; arrays larger than this get
-- their tail elided. Keeps WPF tree happy and the JSON file bounded
-- when someone dumps a CDO that holds a few thousand-row array.
local MAX_ARRAY_ELEMENTS = 64

-- Pull the element-property class off an FArrayProperty. UE4SS
-- exposes the inner property via :GetInner() on the wrapper. We
-- read the inner's runtime class FName to gate element rendering
-- (only whitelisted element types are dereferenced ; everything
-- else stays opaque, just like at the top level).
local function array_inner_class(prop)
    local ok, inner = pcall(function() return prop:GetInner() end)
    if not ok or not inner then return "" end
    return obj_class_name(inner)
end

-- Render a TSoftObjectPtr to its asset path. Tries every shape we've
-- seen UE4SS expose across builds : the standard
-- :ToSoftObjectPath():ToString() chain, the AssetPathName field, the
-- GetUniqueID handle, and finally raw tostring (some wrappers have a
-- __tostring that returns the path). Returns nil when nothing
-- recovers a path.
--
-- IMPORTANT : the caller MUST pass the unwrapped value, not a
-- RemoteUnrealParam wrapper. RemoteUnrealParam only exposes
-- get() / set() / type() ; calling soft-ref methods on it raises
-- "attempt to call a RemoteUnrealParam value". The unwrap happens at
-- the array-element layer in _render_array.
local function _soft_path_of(v)
    if v == nil then return nil end
    local function clean(s)
        if type(s) ~= "string" then return nil end
        if s == "" or s == "None" or s == "<invalid>" then return nil end
        -- Reject Lua error strings that bubble up out of pcall when
        -- the wrong wrapper is passed in. Errors always contain a
        -- file:line prefix from the source location.
        if s:find(":%d+:%s*attempt") then return nil end
        return s
    end
    local methods = {
        -- UE4SS community / 4.3.x exposes TSoftObjectPtr as
        -- TSoftObjectPtrUserdata with three methods : GetWeakPtr,
        -- GetTagAtLastTest, GetObjectID. The last returns
        -- FSoftObjectPathUserdata which has GetAssetPathName (FName)
        -- and GetSubPathString (FString). FName supports :ToString().
        -- This is the canonical chain for the build we're on.
        function()
            local sop = v:GetObjectID()
            local apn = sop:GetAssetPathName():ToString()
            local sub = sop:GetSubPathString():ToString()
            if sub and sub ~= "" then return apn .. ":" .. sub end
            return apn
        end,
        function() return v:ToSoftObjectPath():ToString() end,
        function() return v:GetAssetPathString() end,
        function() return v:GetAssetPathName():ToString() end,
        function() return v:GetLongPackageName() end,
        function() return v:GetUniqueID():ToString() end,
        function() return v:GetPathName() end,
        function() return v:GetPath() end,
    }
    for _, fn in ipairs(methods) do
        local ok, s = pcall(fn)
        if ok then
            local c = clean(s)
            if c then return c end
        end
    end
    local field_chains = {
        function() return v.AssetPathName:ToString() end,
        function() return v.ObjectID.AssetPathName:ToString() end,
        function() return v.ObjectID:ToString() end,
        function() return v.AssetPath:ToString() end,
    }
    for _, fn in ipairs(field_chains) do
        local ok, s = pcall(fn)
        if ok then
            local c = clean(s)
            if c then return c end
        end
    end
    local ok, s = pcall(tostring, v)
    if ok then
        local c = clean(s)
        if c and c:find("/") then return c end
    end
    return nil
end

-- Render a TSoftObjectPtr element to its asset path, falling back to
-- the userdata stringification. Same strategy as the top-level soft
-- ref reader in try_read_field ; factored so the array path can use
-- it on each element.
local function _stringify_soft_ref(v)
    local p = _soft_path_of(v)
    if p then return p end
    return stringify_value(v)
end

-- Walk a TArray wrapper and produce a stringified "[a, b, c]" value.
-- Per-element rendering is wrapped in pcall so a single bad element
-- can't take the whole dump down. element_cls comes from the
-- ArrayProperty inner ; it dictates whether we use the soft-ref
-- enrichment path or the generic stringifier.
local function _render_array(arr, element_cls)
    if not arr then return "[]", 0 end
    local count = 0
    local ok_n, n = pcall(function() return arr:GetArrayNum() end)
    if ok_n and type(n) == "number" then count = n end
    if count == 0 then return "[]", 0 end

    local parts = {}
    local rendered = 0
    local soft = (element_cls == "SoftObjectProperty"
        or element_cls == "SoftClassProperty")
    local ok_iter = pcall(function()
        arr:ForEach(function(idx, elem_wrapper)
            if rendered >= MAX_ARRAY_ELEMENTS then return true end
            rendered = rendered + 1
            local ok_get, elem = pcall(function()
                if type(elem_wrapper) == "userdata" then
                    local ok_g, g = pcall(function() return elem_wrapper:get() end)
                    if ok_g and g ~= nil then return g end
                end
                return elem_wrapper
            end)
            local s
            if not ok_get or elem == nil then
                s = "<read error>"
            elseif soft then
                -- elem is the result of elem_wrapper:get(). For a
                -- TSoftObjectPtr<X> array, that should be the inner
                -- soft-ref struct (or a userdata wrapper around it).
                -- Calling soft-ref methods on the RemoteUnrealParam
                -- wrapper itself raises "attempt to call a
                -- RemoteUnrealParam value" -- only the unwrapped
                -- value is safe to probe.
                s = _soft_path_of(elem) or "<unresolved soft ref>"
                if INTROSPECT_VERBOSE and s == "<unresolved soft ref>" then
                    print(string.format(
                        "[RSDWTools] soft elem unresolved : type=%s tostring=%s",
                        type(elem), tostring(elem)))
                    if type(elem) == "userdata" then
                        local mt = getmetatable(elem)
                        if mt then
                            print("[RSDWTools]   metatable keys:")
                            for k, _ in pairs(mt) do
                                print("[RSDWTools]     " .. tostring(k))
                            end
                            if type(mt.__index) == "table" then
                                print("[RSDWTools]   __index keys:")
                                for k, _ in pairs(mt.__index) do
                                    print("[RSDWTools]     " .. tostring(k))
                                end
                            end
                        end
                    end
                end
            else
                s = stringify_value(elem)
            end
            parts[#parts + 1] = s
        end)
    end)

    if not ok_iter then
        -- ForEach not available on this wrapper shape : fall back to
        -- indexed access. UE4SS arrays accept :Get(i) (1-based on
        -- some versions, 0-based on others) ; try both before giving
        -- up so we don't silently render an empty array for a
        -- populated one.
        parts = {}
        rendered = 0
        for base = 0, 1 do
            if rendered > 0 then break end
            for i = base, count - 1 + base do
                if rendered >= MAX_ARRAY_ELEMENTS then break end
                local ok_g, elem = pcall(function() return arr:Get(i) end)
                if not ok_g or elem == nil then break end
                rendered = rendered + 1
                local s
                if soft then s = _stringify_soft_ref(elem)
                else s = stringify_value(elem) end
                parts[#parts + 1] = s
            end
        end
    end

    local joined = table.concat(parts, ", ")
    if count > MAX_ARRAY_ELEMENTS then
        joined = joined .. ", ... (+" .. (count - MAX_ARRAY_ELEMENTS) .. " more)"
    end
    return "[" .. joined .. "]", count
end


-- Try to read property `name` off the live object. Returns
-- (ok_bool, value_or_nil, value_string). ok_bool is the true/false the
-- WPF "readable" flag will use ; when ok is false the value string is
-- the error text so the user sees *why* the field couldn't be read.
-- prop_class_name is the FName of the UProperty's runtime class ; we
-- consult the whitelist before even attempting the read.
-- prop is the UProperty wrapper itself, used to inspect container
-- inners (ArrayProperty -> Inner). Optional ; legacy callers can
-- pass nil and just lose container element rendering.
local function try_read_field(obj, name, prop_class_name, prop)
    if not obj or not name or name == "" then return false, nil, "no property name" end
    if prop_class_name and prop_class_name ~= "" and not READABLE_PROPERTY_CLASSES[prop_class_name] then
        return false, nil, "<unsupported: " .. prop_class_name .. ">"
    end
    local ok, value = pcall(function() return obj[name] end)
    if not ok then return false, nil, "<read error: " .. tostring(value) .. ">" end

    if prop_class_name == "ArrayProperty" then
        -- Element-class gate : if the inner type is outside our safe
        -- set, expose count only and leave readable=false so diff /
        -- snap doesn't pretend to have captured anything useful.
        local element_cls = prop and array_inner_class(prop) or ""
        if element_cls == "" or not READABLE_ARRAY_ELEMENT_CLASSES[element_cls] then
            local n = 0
            local ok_n, num = pcall(function()
                if value then return value:GetArrayNum() end
            end)
            if ok_n and type(num) == "number" then n = num end
            return false, value, string.format("<array %s [%d]>",
                (element_cls ~= "" and element_cls or "?"), n)
        end
        local rendered, count = _render_array(value, element_cls)
        return true, value, string.format("[%d] %s", count, rendered)
    end

    -- SoftObjectProperty enrichment : the bare userdata stringifies
    -- to "<invalid>" when the asset isn't loaded, but the path is
    -- still in the FSoftObjectPtr storage. Try to recover it via
    -- ToSoftObjectPath():ToString(). All wrapped in pcall because
    -- TSoftObjectPtr<UType> shapes vary across BP / native classes.
    -- Fall back silently to the original stringification on failure.
    if prop_class_name == "SoftObjectProperty" or prop_class_name == "SoftClassProperty" then
        local original = stringify_value(value)
        local ok_path, path_str = pcall(function()
            -- TSoftObjectPtr<X> exposes :ToSoftObjectPath() -> FSoftObjectPath
            -- FSoftObjectPath exposes :ToString() -> "/Game/Foo/Bar.Bar"
            local sop = value:ToSoftObjectPath()
            if not sop then return nil end
            return sop:ToString()
        end)
        if ok_path and type(path_str) == "string" and path_str ~= "" then
            -- Empty-path soft refs stringify to "" or "None" ; only
            -- replace when we got something useful.
            if path_str ~= "None" then
                return true, value, path_str
            end
        end
        return true, value, original
    end

    return true, value, stringify_value(value)
end

-- Iterate properties on a UStruct. Calls the canonical UE4SS API
-- directly ; probing `struct.ForEachProperty` via dot-lookup before
-- calling it returns nil on UE4SS userdata (methods aren't exposed
-- as table fields), which silently dropped us into the empty-fallback
-- and produced fields=0 dumps.
local function iter_properties(struct, callback)
    if not struct then return end
    pcall(function()
        struct:ForEachProperty(function(p)
            callback(p)
            -- Don't return anything ; ForEachProperty treats truthy
            -- returns as "stop iterating".
        end)
    end)
end

-- Iterate functions declared on a UStruct. Same direct-call rationale
-- as iter_properties.
local function iter_functions(struct, callback)
    if not struct then return end
    pcall(function()
        struct:ForEachFunction(function(f)
            callback(f)
        end)
    end)
end

-- Property type display string. Just the UProperty's runtime class
-- FName ("FloatProperty", "ObjectProperty", ...). We deliberately
-- DO NOT introspect PropertyClass / Inner anymore: reading those
-- fields on the wrong UProperty subclass dereferences uninitialised
-- storage and AVs the game thread (Lua pcall does not catch native
-- crashes). The downside is users only see "ObjectProperty" instead
-- of "ObjectProperty<UFooClass>" ; acceptable cost for not crashing.
local function property_type_string(prop)
    if not prop then return "" end
    return obj_class_name(prop)
end

-- Static signature table loaded from ipc/function_signatures.json.
-- Built offline by tools/Build-FunctionSignatures.py from the C++
-- header dump. Lazy-loaded on first call so mod startup stays cheap
-- and we never re-parse the 1.8 MiB JSON. nil means "not loaded yet" ;
-- false means "tried and failed" (we don't retry).
local _sig_table = nil
local function _load_sig_table()
    if _sig_table ~= nil then return _sig_table end
    _sig_table = false  -- pessimistic default ; flip to table on success
    local d = mod_paths.ipc_dir()
    if not d then return _sig_table end
    local body = mod_paths.read_file(d .. "\\function_signatures.json")
    if not body or body == "" then return _sig_table end
    -- Tiny JSON parser : the file is machine-generated nested-string-map
    -- shape only ({ "Class": { "Method": "sig", ... }, ... }) so we can
    -- afford to require dkjson / cjson if available, otherwise hand-parse.
    local ok_dkjson, dkjson = pcall(require, "dkjson")
    if ok_dkjson and dkjson and dkjson.decode then
        local parsed, _, err = dkjson.decode(body)
        if parsed then _sig_table = parsed end
        return _sig_table
    end
    -- Fallback : naive line-by-line parser since we control the writer.
    -- Output is sorted, indent=0, so each entry is on its own line as
    -- `"Method": "sig",`. We track the enclosing class via lines like
    -- `"ClassName": {`.
    local cur_cls
    local map = {}
    for raw in body:gmatch("[^\r\n]+") do
        local cls = raw:match('^%s*"([^"]+)"%s*:%s*{%s*$')
        if cls then
            cur_cls = cls
            map[cls] = {}
        elseif cur_cls then
            local k, v = raw:match('^%s*"([^"]+)"%s*:%s*"(.-)"%s*,?%s*$')
            if k then
                -- Unescape \" -> " and \\ -> \
                v = v:gsub('\\"', '"'):gsub('\\\\', '\\')
                map[cur_cls][k] = v
            elseif raw:match('^%s*}%s*,?%s*$') then
                cur_cls = nil
            end
        end
    end
    _sig_table = map
    return _sig_table
end

-- Build a UFunction signature string. Class-aware : we look up the
-- function name in the static signature table built from the C++
-- header dump. Falls back to "Name(...)" when the class isn't in the
-- table (uncooked / mod-only classes) or when the function name is
-- a UE-generated trampoline that doesn't appear in headers.
--
-- We deliberately do NOT walk the UFunction's ChildProperties at
-- runtime : that has cratered the game thread on certain BP function
-- objects in the past (Lua pcall doesn't catch native crashes).
local function function_signature(fn, owner_class_name)
    if not fn then return "" end
    local name = safe_fname(fn, "GetFName")
    if name == "" then return "(...)" end
    local sigs = _load_sig_table()
    if sigs and owner_class_name then
        -- The static table is keyed by C++ class name (UFoo / AFoo /
        -- FFoo) but GetFName() returns the bare reflected name (Foo).
        -- Try the bare key first (handles BP-only / mod-only types
        -- that lack a prefix), then the U/A/F variants.
        local candidates = {
            owner_class_name,
            "U" .. owner_class_name,
            "A" .. owner_class_name,
            "F" .. owner_class_name,
        }
        for _, key in ipairs(candidates) do
            local class_map = sigs[key]
            if class_map then
                local s = class_map[name]
                if s then
                    -- The static table stores "ret(args)". UI prefers
                    -- "name(args) -> ret" when ret isn't void. Try to
                    -- split on the first '('.
                    local ret, args = s:match("^(.-)%((.*)%)%s*$")
                    if ret and args ~= nil then
                        ret = ret:gsub("%s+$", "")
                        if ret == "" or ret == "void" then
                            return name .. "(" .. args .. ")"
                        end
                        return name .. "(" .. args .. ") -> " .. ret
                    end
                    return name .. " " .. s   -- defensive fallback
                end
                break  -- found the class but not the method ; don't
                       -- keep guessing other prefixes (would be wrong).
            end
        end
    end
    return name .. "(...)"
end

-- ============================================================
-- Group / field / method serialisers
-- ============================================================

local function field_to_json(f)
    return "{"
        .. '"name":' .. jstr(f.name)
        .. ',"type":' .. jstr(f.type)
        .. ',"value":' .. jstr(f.value)
        .. ',"readable":' .. jbool(f.readable)
        .. "}"
end

local function method_to_json(m)
    return "{"
        .. '"name":' .. jstr(m.name)
        .. ',"signature":' .. jstr(m.signature)
        .. "}"
end

local function group_to_json(g)
    local parts = { "{" }
    parts[#parts + 1] = '"class":' .. jstr(g.class_name)
    parts[#parts + 1] = ',"resolved":' .. jbool(g.resolved)
    parts[#parts + 1] = ',"fields":'
    emit_indexed_map(parts, g.fields, field_to_json)
    parts[#parts + 1] = ',"methods":'
    emit_indexed_map(parts, g.methods, method_to_json)
    parts[#parts + 1] = "}"
    return table.concat(parts)
end

-- Builds the per-class group for a single UStruct in the chain. obj is the
-- live UObject we read field values from ; struct is the class layer we
-- enumerate properties / functions on.
local function build_group(obj, struct)
    local group = {
        class_name = safe_fname(struct, "GetFName"),
        resolved = true,                    -- always true for live walks
        fields = {},
        methods = {},
    }
    iter_properties(struct, function(p)
        pcall(function()
            local nm = safe_fname(p, "GetFName")
            if nm == "" then return end
            local prop_class = obj_class_name(p)
            if INTROSPECT_VERBOSE then
                print(string.format("[RSDWTools] introspect: prop %s::%s : %s",
                    group.class_name, nm, prop_class))
            end
            local tp = property_type_string(p)
            local readable, _, sval = try_read_field(obj, nm, prop_class, p)
            group.fields[#group.fields + 1] = {
                name = nm,
                type = tp,
                value = sval or "",
                readable = readable == true,
            }
        end)
    end)
    iter_functions(struct, function(fn)
        pcall(function()
            local nm = safe_fname(fn, "GetFName")
            if nm == "" then return end
            group.methods[#group.methods + 1] = {
                name = nm,
                signature = function_signature(fn, group.class_name),
            }
        end)
    end)
    -- Stable alphabetical sort within a class layer keeps the WPF tree
    -- predictable across runs (UE iteration order is not guaranteed).
    table.sort(group.fields, function(a, b) return a.name < b.name end)
    table.sort(group.methods, function(a, b) return a.name < b.name end)
    return group
end

-- ============================================================
-- Top-level dump
-- ============================================================

-- Returns the resolved short name to display in the WPF target label.
-- For follow-field dumps we synthesise "<actor>.<seg>.<seg>" so the user
-- sees the breadcrumb-aware label.
local function build_display_name(actor_name, path_segments)
    if not path_segments or #path_segments == 0 then return actor_name end
    return actor_name .. "." .. table.concat(path_segments, ".")
end

-- Walk path_segments (a list of property names) starting at root_obj.
-- Returns (final_obj, err_or_nil). Stops as soon as a step yields nil /
-- non-userdata ; that's reported back through the ack.
local function walk_field_path(root_obj, path_segments)
    local cur = root_obj
    for i, seg in ipairs(path_segments) do
        print(string.format("[RSDWTools] introspect: walk step %d/%d seg=%s",
            i, #path_segments, tostring(seg)))
        if not is_valid(cur) then
            print("[RSDWTools] introspect: walk FAIL parent invalid")
            return nil, "step " .. i .. " (" .. seg .. "): parent invalid"
        end
        local ok, val = pcall(function() return cur[seg] end)
        if not ok then
            print("[RSDWTools] introspect: walk FAIL read error: " .. tostring(val))
            return nil, "step " .. i .. " (" .. seg .. "): read error: " .. tostring(val)
        end
        if val == nil then
            print("[RSDWTools] introspect: walk FAIL nil at " .. seg)
            return nil, "step " .. i .. " (" .. seg .. "): nil"
        end
        if type(val) ~= "userdata" then
            print("[RSDWTools] introspect: walk FAIL non-object (" .. type(val) .. ") at " .. seg)
            return nil, "step " .. i .. " (" .. seg .. "): not an object (" .. type(val) .. ")"
        end
        -- Probe the wrapper for validity BEFORE we hand it to the next
        -- iteration ; an invalid userdata wrapper passes type(...) ==
        -- "userdata" but AVs on any vtable call.
        local ok_v, v_ok = pcall(function() return val:IsValid() end)
        if not ok_v or not v_ok then
            print("[RSDWTools] introspect: walk FAIL invalid wrapper at " .. seg)
            return nil, "step " .. i .. " (" .. seg .. "): invalid object"
        end
        cur = val
    end
    print("[RSDWTools] introspect: walk OK")
    return cur, nil
end

local function info_path()
    local d = mod_paths.ipc_dir()
    if not d then return nil end
    return d .. "\\actor_info.json"
end

-- Serialise the full payload + atomically write it. Returns
-- (true, path) or (false, err).  `out_path` is optional ; when nil
-- the dump goes to the canonical actor_info.json so the WPF Inspect
-- tab picks it up. Bulk-dump verbs override this to write per-class
-- files under ipc/cdo/.
local function emit_dump(target_obj, display_name, out_path)
    if not is_valid(target_obj) then
        return false, "target object invalid"
    end
    print("[RSDWTools] introspect: stage=valid target=" .. tostring(display_name))
    local class_name = obj_class_name(target_obj)
    print("[RSDWTools] introspect: stage=class_name='" .. class_name .. "'")
    local chain = build_class_chain(target_obj)
    print("[RSDWTools] introspect: stage=chain_built depth=" .. tostring(#chain))

    local groups = {}
    for ci, struct in ipairs(chain) do
        local sn = safe_fname(struct, "GetFName")
        print(string.format("[RSDWTools] introspect: stage=group_begin %d/%d class=%s",
            ci, #chain, sn))
        groups[#groups + 1] = build_group(target_obj, struct)
        print(string.format("[RSDWTools] introspect: stage=group_end %d/%d fields=%d methods=%d",
            ci, #chain, #(groups[#groups].fields), #(groups[#groups].methods)))
    end
    print("[RSDWTools] introspect: stage=serialise")

    local parts = { "{" }
    parts[#parts + 1] = '"name":' .. jstr(display_name)
    parts[#parts + 1] = ',"class":' .. jstr(class_name)
    parts[#parts + 1] = ',"class_chain":'
    -- class_chain emitted as the indexed map the C# parser already
    -- understands (see TryLoadAndRenderInspect's chainElem handling).
    do
        local chain_names = {}
        for _, st in ipairs(chain) do
            chain_names[#chain_names + 1] = safe_fname(st, "GetFName")
        end
        emit_indexed_map(parts, chain_names, function(s) return jstr(s) end)
    end
    parts[#parts + 1] = ',"groups":'
    emit_indexed_map(parts, groups, group_to_json)
    parts[#parts + 1] = "}"

    local body = table.concat(parts)
    local p = out_path or info_path()
    if not p then return false, "ipc dir unavailable" end
    local ok_write, path_or_err = mod_paths.write_atomic(p, body)
    if not ok_write then return false, "write failed: " .. tostring(path_or_err) end
    return true, path_or_err
end

-- ============================================================
-- Public API (called from command_line_router)
-- ============================================================

-- actor.info <name>
function M.dump_actor(name)
    if not name or name == "" then return false, "usage: actor.info <name>" end
    local obj = feature_actor.resolve_actor_by_name(name)
    if not obj then return false, "actor not found: " .. tostring(name) end
    local ok, detail = emit_dump(obj, name)
    if not ok then return false, detail end
    return true, "wrote " .. tostring(detail)
end

-- actor.info.field <name> <seg>[.<seg>...]
function M.dump_actor_field(name, path_str)
    print(string.format("[RSDWTools] introspect: dump_actor_field name=%s path=%s",
        tostring(name), tostring(path_str)))
    if not name or name == "" then return false, "usage: actor.info.field <name> <segments>" end
    if not path_str or path_str == "" then
        -- No segments: behave like a plain dump.
        return M.dump_actor(name)
    end
    local segments = {}
    for seg in string.gmatch(path_str, "[^%.]+") do
        segments[#segments + 1] = seg
    end
    if #segments == 0 then return M.dump_actor(name) end
    local root = feature_actor.resolve_actor_by_name(name)
    if not root then
        print("[RSDWTools] introspect: dump_actor_field FAIL actor not found")
        return false, "actor not found: " .. tostring(name)
    end
    local target, err = walk_field_path(root, segments)
    if not target then
        print("[RSDWTools] introspect: dump_actor_field FAIL " .. tostring(err))
        return false, "follow-field failed at " .. (err or "?")
    end
    local display = build_display_name(name, segments)
    local ok, detail = emit_dump(target, display)
    if not ok then return false, detail end
    return true, "wrote " .. tostring(detail)
end

-- ============================================================
-- CDO dump : reuse the actor-info reflection pipeline against a class's
-- Default Object so the WPF Inspect tab can browse settings classes
-- (UDeveloperSettings, UDataAsset, etc.) the same way it browses live
-- actors.
--
-- Accepts either :
--   world.cdo.dump BuildingSettings
--   world.cdo.dump UBuildingSettings
--   world.cdo.dump /Script/Dominion.BuildingSettings
--   world.cdo.dump /Script/Dominion.Default__BuildingSettings
--
-- Path form is preferred -- it's unambiguous and matches the .ini
-- section format `[/Script/Module.Class]`. Short-name form falls back
-- to FindFirstOf, which only works if the class has a live instance
-- (true for most UDeveloperSettings since the CDO is the instance).
-- ============================================================

-- Try to coerce a `.Class` path into a `.Default__Class` path.
-- Returns the input unchanged if it already names a Default__ object.
local function path_to_cdo_path(path)
    -- Find the last segment after the final '.'
    local prefix, leaf = path:match("^(.-)%.([^.]+)$")
    if not prefix or not leaf then return path end
    if leaf:sub(1, 9) == "Default__" then return path end
    return prefix .. ".Default__" .. leaf
end

-- Resolve a class-name argument to a CDO UObject.
-- Returns (cdo, nil) on success or (nil, err) on failure.
local function resolve_cdo_arg(arg)
    if not arg or arg == "" then return nil, "empty class name" end

    -- Path form : try Default__-rewritten path first, then verbatim.
    if arg:find("/", 1, true) then
        if not StaticFindObject then
            return nil, "StaticFindObject unavailable"
        end
        local cdo_path = path_to_cdo_path(arg)
        local ok, found = pcall(StaticFindObject, cdo_path)
        if ok and type(found) == "userdata" and is_valid(found) then
            return found
        end
        -- Last-ditch : try the input verbatim in case the user passed
        -- something exotic like a /Game/... blueprint asset path.
        local ok2, found2 = pcall(StaticFindObject, arg)
        if ok2 and type(found2) == "userdata" and is_valid(found2) then
            return found2
        end
        return nil, "CDO not found at path: " .. tostring(cdo_path)
    end

    -- Short-name form : try the name and the U/A-stripped variant.
    local candidates = { arg }
    local p = arg:sub(1, 1)
    if p == "U" or p == "A" or p == "F" then
        candidates[#candidates + 1] = arg:sub(2)
    else
        candidates[#candidates + 1] = "U" .. arg
        candidates[#candidates + 1] = "A" .. arg
    end
    for _, cand in ipairs(candidates) do
        local ok, inst = pcall(FindFirstOf, cand)
        if ok and type(inst) == "userdata" and is_valid(inst) then
            local ok_cls, cls = pcall(function() return inst:GetClass() end)
            if ok_cls and is_valid(cls) then
                local ok_cdo, cdo = pcall(function() return cls:GetCDO() end)
                if ok_cdo and is_valid(cdo) then
                    return cdo
                end
            end
        end
    end

    -- Settings classes (and any CDO with no live instance) need a
    -- direct StaticFindObject path lookup. Try the most common module
    -- prefixes so users don't have to remember which DLL a class lives
    -- in. Order matters : Dominion is the project module so put it
    -- first to keep the failure message helpful when nothing matches.
    if StaticFindObject then
        local modules = {
            "/Script/Dominion",
            "/Script/Engine",
            "/Script/CoreUObject",
            "/Script/UMG",
            "/Script/GameplayAbilities",
        }
        for _, mod in ipairs(modules) do
            local cdo_path = mod .. ".Default__" .. arg
            local ok, found = pcall(StaticFindObject, cdo_path)
            if ok and type(found) == "userdata" and is_valid(found) then
                return found
            end
        end
    end

    return nil, "class not found: " .. tostring(arg) ..
        " (tried: " .. table.concat(candidates, ", ") ..
        ") -- pass full path like /Script/Dominion." .. arg
end

-- world.cdo.dump <ClassName | /Script/Module.Class>
function M.dump_cdo(class_arg)
    if not class_arg or class_arg == "" then
        return false, "usage: world.cdo.dump <ClassName|/Script/Module.Class>"
    end
    local cdo, err = resolve_cdo_arg(class_arg)
    if not cdo then return false, err end
    -- Build a friendly display name : the class FName, falling back to
    -- the input arg.
    local display = obj_class_name(cdo)
    if display == "" then display = class_arg end
    local ok, detail = emit_dump(cdo, display)
    if not ok then return false, detail end
    return true, "wrote " .. tostring(detail)
end

-- ============================================================
-- world.cdo.dump.deep <ClassName> [maxDepth=2]
-- ============================================================
--
-- Recursive variant : dump the requested class, then for each field
-- whose value points at another resolvable thing (soft path, hard
-- object ref, blueprint class ref) follow it and dump that too,
-- depth-limited and cycle-protected. The forest of dumps lands in
-- ipc/cdo/ (for class refs) and ipc/asset/ (for soft / object paths)
-- so the WPF side can browse the whole graph by listing those dirs.
--
-- Default depth is 2 : root + one hop. Each additional level can
-- explode quickly (one settings class often references 30+ presets,
-- each of which references several GE classes...) so we cap conservatively.
--
-- Why this isn't free in build_group : a normal dump only stringifies
-- references. Following them needs LoadAsset (frame stalls), class
-- resolution, and visited tracking -- all opt-in cost the regular
-- dump can't pay.
local function _looks_like_game_path(s)
    if type(s) ~= "string" then return false end
    return s:sub(1, 6) == "/Game/" or s:sub(1, 8) == "/Script/"
end

-- Match strings like "BlueprintGeneratedClass 'BP_Foo_C'", "Class
-- 'DebugCameraController'", or post-GetFullName-enrichment forms like
-- "BuildPieceCatalogue '/Game/Foo/DA_X.DA_X'". Returns (inner, kind)
-- where kind is "asset" when inner contains a path-like '/', else "cdo".
-- Returns nil when the value isn't a recognised object reference.
local function _extract_class_ref(s)
    if type(s) ~= "string" then return nil end
    local inner = s:match("^[%w_]+ '([^']+)'$")
    if not inner then return nil end
    if inner:find("/", 1, true) then
        return inner, "asset"
    end
    return inner, "cdo"
end

-- Visited set is keyed by canonical id so the same target only
-- dumps once across the whole walk regardless of how it's referenced.
-- For CDO dumps we route to ipc/cdo/<Class>.json (matching dump_cdo_all)
-- instead of the shared actor_info.json slot used by single-shot
-- dump_cdo, so the whole walk's output survives the recursion.
local function _deep_dump_one(target_id, kind, depth, max_depth, visited, log)
    if visited[target_id] then return end
    visited[target_id] = true
    if depth > max_depth then return end

    local d = mod_paths.ipc_dir()
    if not d then return end

    local ok, detail
    local json_path
    if kind == "cdo" then
        local cdo, err = resolve_cdo_arg(target_id)
        if not cdo then
            log[#log + 1] = string.format("[%d] cdo %s : RESOLVE FAIL %s",
                depth, target_id, tostring(err))
            return
        end
        local display = obj_class_name(cdo)
        if display == "" then display = target_id end
        local cdo_dir = d .. "\\cdo"
        -- Best-effort mkdir : write_atomic does NOT create dirs.
        pcall(function() os.execute('mkdir "' .. cdo_dir .. '" 2>nul') end)
        json_path = cdo_dir .. "\\" .. display .. ".json"
        ok, detail = emit_dump(cdo, display, json_path)
    else
        ok, detail = M.dump_asset(target_id)
        json_path = d .. "\\asset\\" .. sanitize_filename(target_id) .. ".json"
    end
    log[#log + 1] = string.format("[%d] %s %s : %s",
        depth, kind, target_id, ok and "ok" or ("FAIL " .. tostring(detail)))
    if not ok then return end

    local body = mod_paths.read_file(json_path)
    if not body then return end

    -- Collect refs first, then recurse. Pattern-scrape "value":"..."
    -- entries ; the JSON shape is fixed by emit_dump so we don't need
    -- a real parser. Class refs (e.g. "BlueprintGeneratedClass 'BP_Foo_C'")
    -- queue as cdo ; /Game/ or /Script/ paths queue as asset.
    local queue = {}
    for v in body:gmatch('"value":"([^"]*)"') do
        local unescaped = v:gsub('\\"', '"'):gsub("\\\\", "\\")
        local ref, kind = _extract_class_ref(unescaped)
        if ref then
            queue[#queue + 1] = { id = ref, kind = kind }
        elseif _looks_like_game_path(unescaped) then
            queue[#queue + 1] = { id = unescaped, kind = "asset" }
        end
    end
    for _, q in ipairs(queue) do
        _deep_dump_one(q.id, q.kind, depth + 1, max_depth, visited, log)
    end
end

function M.dump_cdo_deep(arg)
    if not arg or arg == "" then
        return false, "usage: world.cdo.dump.deep <ClassName> [maxDepth=2]"
    end
    local parts = {}
    for tok in arg:gmatch("%S+") do parts[#parts + 1] = tok end
    local class_arg = parts[1]
    local max_depth = tonumber(parts[2]) or 2
    if max_depth < 1 then max_depth = 1 end
    if max_depth > 5 then max_depth = 5 end  -- hard guard, runaway protection

    local visited = {}
    local log = {}
    _deep_dump_one(class_arg, "cdo", 0, max_depth, visited, log)

    -- Persist the walk log so the user can audit what got dumped.
    local d = mod_paths.ipc_dir()
    if d then
        mod_paths.write_atomic(d .. "\\cdo_deep_log.txt",
            table.concat(log, "\n"))
    end
    local n = 0
    for _ in pairs(visited) do n = n + 1 end
    return true, string.format("deep-dumped %d target(s), depth=%d -- see ipc/cdo_deep_log.txt",
        n, max_depth)
end

-- world.cdo.dump.all
--
-- Bulk variant : enumerate every UDeveloperSettings instance (each one
-- IS its own CDO since UDeveloperSettings is singleton-per-class), then
-- run the same emit_dump pipeline against each. Output goes to one file
-- per class under ipc/cdo/<ClassName>.json so the C# side can iterate
-- the directory rather than parsing one giant blob.
--
-- Why UDeveloperSettings specifically : that's the base class for every
-- `[/Script/Module.XSettings]` section the .ini system reads from. It
-- maps 1:1 to the entries in tools/out/cvar-database/ini-database.json
-- (where `bucket="settings"`).
-- world.cdo.dump.all
--
-- Bulk variant : dump every settings-style CDO listed in the shipped
-- manifest at <modroot>/ipc/cdo_manifest.txt. The manifest is produced
-- by tools/Generate-IniDumps.py from the UHT header dump and contains
-- one `/Script/Module.Class` path per line -- the same set of classes
-- that drive `[/Script/Module.Class]` sections in the .ini system.
--
-- Why a manifest instead of a runtime walk : `FindAllOf("Class")` on
-- the metaclass destabilises the engine (the codebase already refuses
-- it for "Object" / "Actor" via feature_foreach.BLOCKED_CLASSES), so
-- a static class list is the only reliable enumerator.
--
-- Output : one file per class under ipc/cdo/<ClassName>.json. Format
-- matches single-class dumps, so the existing WPF Inspect tab can
-- browse any of them by reading the directory.
function M.dump_cdo_all()
    local d = mod_paths.ipc_dir()
    if not d then return false, "ipc dir unavailable" end
    local cdo_dir = d .. "\\cdo"
    pcall(function()
        os.execute('cmd /c if not exist "' .. cdo_dir .. '" mkdir "' .. cdo_dir .. '"')
    end)

    local manifest_path = d .. "\\cdo_manifest.txt"
    local body = mod_paths.read_file(manifest_path)
    if not body then
        return false, "manifest missing : " .. manifest_path ..
            " (run tools/Generate-IniDumps.py + Sync-ModPayload.ps1)"
    end

    if not StaticFindObject then
        return false, "StaticFindObject unavailable"
    end

    local seen = {}
    local written, missing, failed = 0, 0, 0
    local fail_examples = {}

    for raw_line in body:gmatch("[^\r\n]+") do
        local path = raw_line:gsub("^%s+", ""):gsub("%s+$", "")
        if path ~= "" and path:sub(1, 1) ~= "#" then
            -- Strip the leading `/Script/Module.` to derive the class
            -- short name we use for the output filename.
            local cls_name = path:match("%.([^%.]+)$") or path
            if not seen[cls_name] then
                seen[cls_name] = true
                -- Rewrite to Default__ form (CDO path).
                local cdo_path = path_to_cdo_path(path)
                local ok_sfo, cdo = pcall(StaticFindObject, cdo_path)
                if not (ok_sfo and is_valid(cdo)) then
                    -- Class not loaded (no live instance touched it
                    -- this session) -- not an error per se.
                    missing = missing + 1
                else
                    local out_path = cdo_dir .. "\\" .. cls_name .. ".json"
                    local ok_emit, detail = emit_dump(cdo, cls_name, out_path)
                    if ok_emit then
                        written = written + 1
                    else
                        failed = failed + 1
                        if #fail_examples < 3 then
                            fail_examples[#fail_examples + 1] =
                                cls_name .. ":" .. tostring(detail)
                        end
                    end
                end
            end
        end
    end

    local msg = string.format("written=%d missing=%d failed=%d dir=%s",
        written, missing, failed, cdo_dir)
    if #fail_examples > 0 then
        msg = msg .. " errs=" .. table.concat(fail_examples, "|")
    end
    print("[RSDWTools] world.cdo.dump.all : " .. msg)
    return true, msg
end

-- world.asset.dump <SoftPath | /Game/Foo/Bar.Bar>
--
-- Resolve a soft asset path, force-load it, and run the same
-- emit_dump pipeline against the resulting UObject. This is how
-- we crack open the asset graph that the in-class CDO leaves as
-- soft refs : `BuildPieceCatalogueRef` -> `/Game/.../DA_BuildPieceCatalogue_Default`
-- gives us a real UObject we can introspect.
--
-- Output goes to ipc/asset/<sanitized>.json. Sanitisation strips
-- everything not safe for a Windows filename. The full path is
-- preserved inside the JSON so you can correlate back.
--
-- Why this is a separate verb from world.cdo.dump : the CDO loop
-- only ever reads class default storage, never the live asset.
-- Dereferencing a soft ref REQUIRES LoadAsset which compiles BP /
-- streams chunks ; it can stall the game thread for a frame, so
-- we keep it opt-in.
local function sanitize_filename(s)
    local out = (s or ""):gsub("[\\/:*?\"<>|]", "_")
    out = out:gsub("^_+", ""):gsub("_+$", "")
    if out == "" then out = "asset" end
    if #out > 120 then out = out:sub(1, 120) end
    return out
end

function M.dump_asset(arg)
    if not arg or arg == "" then
        return false, "usage: world.asset.dump </Game/Path/To/Asset.Asset | SoftPath>"
    end

    -- Normalise : "/Game/Foo/Bar" -> "/Game/Foo/Bar.Bar". UE asset
    -- paths need the trailing `.Name` to disambiguate the package
    -- from the asset object inside it.
    local path = arg:gsub("^%s+", ""):gsub("%s+$", "")
    if not path:find("%.") then
        local leaf = path:match("([^/]+)$")
        if leaf then path = path .. "." .. leaf end
    end

    -- LoadAsset is the canonical UE4SS API for forcing a soft asset
    -- to load. Wrapped in pcall because asset load can throw on
    -- malformed paths or unmounted /Game/Mods/ chunks.
    local loaded
    if LoadAsset then
        local ok, ret = pcall(LoadAsset, path)
        if ok then loaded = ret end
    end

    -- Fallback : maybe the asset is already loaded ; StaticFindObject
    -- will see it. Cheaper than LoadAsset when it works.
    if not is_valid(loaded) and StaticFindObject then
        local ok, ret = pcall(StaticFindObject, path)
        if ok then loaded = ret end
    end

    if not is_valid(loaded) then
        return false, "asset not found / load failed : " .. path
    end

    -- Display name : leaf of path, used for both the JSON `name`
    -- and the filename. Fall back to class name on weird paths.
    local display = path:match("([^/.]+)$") or obj_class_name(loaded)
    local d = mod_paths.ipc_dir()
    if not d then return false, "ipc dir unavailable" end
    local asset_dir = d .. "\\asset"
    pcall(function()
        os.execute('cmd /c if not exist "' .. asset_dir .. '" mkdir "' .. asset_dir .. '"')
    end)

    local fname = sanitize_filename(display) .. ".json"
    local out_path = asset_dir .. "\\" .. fname

    local ok, detail = emit_dump(loaded, display, out_path)
    if not ok then return false, detail end
    return true, "wrote " .. tostring(detail) .. " (path=" .. path .. ")"
end

-- ============================================================
-- world.func.call <Target> <Method> [arg1 arg2 ...]
-- ============================================================
--
-- Resolve a UObject by class short-name OR full path, look up the
-- named UFunction, coerce each space-separated arg into a Lua
-- primitive (bool / number / string -- keep it simple), and call.
-- Pcall-wrapped : a malformed call should not crash the game thread.
--
-- Special target shortcuts :
--   "cheatmgr"          first UDominionCheatManager instance
--   "player"            owning ADominionPlayerControllerBase
--
-- Examples (in chat/console) :
--   world.func.call cheatmgr domSetTime 12.0
--   world.func.call cheatmgr domAddItem CoinPouch 100 100
--   world.func.call cheatmgr domGod
--
-- Why per-class FindFirstOf and not metaclass walks : same hazard
-- as feature_foreach.BLOCKED_CLASSES -- FindAllOf("Class") destabilises
-- the engine. FindFirstOf on a concrete (non-metaclass) class is safe.
local function _coerce_arg(s)
    if s == "true" then return true end
    if s == "false" then return false end
    local n = tonumber(s)
    if n ~= nil then return n end
    return s   -- pass through as string
end

local function _resolve_target(spec)
    if spec == "cheatmgr" then
        -- Prefer the local PlayerController's CheatManager : that's
        -- the instance whose OwningPlayerController is wired and
        -- whose cheats actually mutate the player. FindFirstOf as
        -- a last resort can return a stale / server-side instance
        -- with a null owner -- the call succeeds but no-ops in-game,
        -- which is exactly the symptom we hit.
        local pc, _ = _resolve_target("player")
        if is_valid(pc) then
            local ok_cm, cm = pcall(function() return pc.CheatManager end)
            if ok_cm and is_valid(cm) then return cm end
        end
        if FindFirstOf then
            local ok, inst = pcall(FindFirstOf, "DominionCheatManager")
            if ok and is_valid(inst) then return inst end
            ok, inst = pcall(FindFirstOf, "CheatManager")
            if ok and is_valid(inst) then return inst end
        end
        return nil, "cheatmgr not found (no live PC.CheatManager and no UCheatManager)"
    end
    if spec == "player" then
        if FindFirstOf then
            local ok, inst = pcall(FindFirstOf, "DominionPlayerControllerBase")
            if ok and is_valid(inst) then return inst end
            ok, inst = pcall(FindFirstOf, "PlayerController")
            if ok and is_valid(inst) then return inst end
        end
        return nil, "player controller not found"
    end
    if spec:sub(1, 1) == "/" then
        if not StaticFindObject then return nil, "StaticFindObject unavailable" end
        local ok, found = pcall(StaticFindObject, spec)
        if ok and is_valid(found) then return found end
        return nil, "StaticFindObject failed for " .. spec
    end
    -- Bare short-name -> FindFirstOf with U/A prefix variants.
    if FindFirstOf then
        for _, cand in ipairs({ spec, "U" .. spec, "A" .. spec }) do
            local ok, inst = pcall(FindFirstOf, cand)
            if ok and is_valid(inst) then return inst end
        end
    end
    return nil, "no live instance of " .. spec
end

function M.func_call(arg)
    if not arg or arg == "" then
        return false, "usage: world.func.call <Target> <Method> [args...]"
    end
    local parts = {}
    for tok in arg:gmatch("%S+") do parts[#parts + 1] = tok end
    if #parts < 2 then
        return false, "need at least <Target> <Method>"
    end
    local target_spec, method = parts[1], parts[2]
    local target, err = _resolve_target(target_spec)
    if not target then return false, err end

    local coerced = {}
    for i = 3, #parts do coerced[#coerced + 1] = _coerce_arg(parts[i]) end

    -- Sanity-check that the method exists on the resolved object's
    -- class chain. We use the static signature table (built from the
    -- C++ headers) as the primary source of truth -- it's authoritative
    -- and cheap. If the class isn't in the table (mod-only / BP-only),
    -- we fall back to walking ForEachFunction. We deliberately do NOT
    -- use UClass:FindFunctionByName : empirically it returns invalid
    -- for plenty of methods that actually exist (probably an FName
    -- pool / case mismatch), which produced false-negative errors.
    local cls_name = obj_class_name(target)
    local exists = false
    local sigs = _load_sig_table()
    if sigs then
        for _, key in ipairs({ cls_name, "U" .. cls_name, "A" .. cls_name }) do
            local m = sigs[key]
            if m and m[method] then exists = true ; break end
        end
    end
    if not exists then
        -- Walk live class chain. Cheap because UClass already has
        -- the function map in memory.
        pcall(function()
            local cls = target:GetClass()
            while is_valid(cls) and not exists do
                iter_functions(cls, function(fn)
                    if exists then return end
                    local n = safe_fname(fn, "GetFName")
                    if n == method then exists = true end
                end)
                if exists then break end
                local nxt = nil
                pcall(function() nxt = cls:GetSuperStruct() end)
                if not is_valid(nxt) or nxt == cls then break end
                cls = nxt
            end
        end)
    end
    if not exists then
        return false, string.format(
            "method '%s' not found on %s (resolved as %s)",
            method, target_spec, cls_name)
    end

    -- Call. UE4SS exposes UFunctions as methods on the userdata, so
    -- target:Method(...) Just Works for most cases. Pcall guards
    -- against arity / type mismatches.
    local ok, result = pcall(function()
        return target[method](target, table.unpack(coerced))
    end)
    if not ok then
        return false, "call failed : " .. tostring(result)
    end

    local ack = string.format("called %s.%s(%d args)",
        target_spec, method, #coerced)
    if result ~= nil then
        ack = ack .. " -> " .. tostring(result)
    end
    print("[RSDWTools] world.func.call : " .. ack)
    return true, ack
end

-- ============================================================
-- world.cheat.exec <method> [args...]
-- ============================================================
--
-- Convenience wrapper around func_call : prefixes "cheatmgr" so the
-- caller can write `world.cheat.exec domFullHeal` instead of
-- `world.func.call cheatmgr domFullHeal`. We do NOT route through
-- APlayerController:ConsoleCommand even though that's the canonical
-- UE entry point -- ConsoleCommand is a plain C++ method, not a
-- UFUNCTION, so UE4SS can't bind it (we get a nullptr error).
--
-- Limitation : if the underlying cheat is `#if !UE_BUILD_SHIPPING`'d
-- out, the call still succeeds at the reflection layer but the body
-- is empty. Use world.diff.cdo.snap / .compare around the call to
-- detect no-op cheats.
function M.cheat_exec(arg)
    if not arg or arg == "" then
        return false, "usage: world.cheat.exec <method> [args...]"
    end
    return M.func_call("cheatmgr " .. arg)
end

-- ============================================================
-- world.diff.cdo.snap <ClassName>
-- world.diff.cdo.compare <ClassName>
-- ============================================================
--
-- Snapshot a class's CDO field values, then later re-dump and emit
-- the delta. Used to discover what a cheat actually mutated :
--   1. world.diff.cdo.snap DominionPlayerCharacter
--   2. world.func.call cheatmgr domAddCriticalChance 50.0
--   3. world.diff.cdo.compare DominionPlayerCharacter
-- The compare verb writes ipc/cdo_diff_<class>.json with one entry
-- per changed field { name, before, after }.
--
-- Snapshots live in module-local memory (not on disk) -- they're
-- meant to bracket a single in-game experiment, not survive
-- restarts.

-- Snapshot store. Keyed by "<kind>:<id>" so cdo and actor snaps with
-- the same name don't collide. Module-local memory only -- not on disk.
local _snapshots = {}

-- Walk every group in the class chain and flatten readable fields
-- into a single name -> stringified-value map. Includes parent-class
-- fields so a live actor diff catches inherited state changes.
-- Field names are prefixed with the owning class to disambiguate
-- when a name appears at multiple chain levels.
--
-- When recurse > 0, also flatten each ObjectProperty sub-object whose
-- value is a live nested UObject (AbilitySystemComponent, AttributeSets,
-- inventory components ...). This is what catches GE-applied attribute
-- changes -- Health / Stamina live in an AttributeSet UObject reachable
-- from the pawn, NOT in the pawn's own properties. Output keys for
-- recursed fields are "Owner.SubObjectName::Class::Field".
local function _flatten_obj_chain(obj, prefix, out, visited)
    if not is_valid(obj) then return end
    local id_ok, id_str = pcall(function() return tostring(obj) end)
    if id_ok and visited[id_str] then return end
    if id_ok then visited[id_str] = true end

    local cls = nil
    pcall(function() cls = obj:GetClass() end)
    if not is_valid(cls) then return end

    local cur = cls
    local guard = 0
    while is_valid(cur) and guard < 32 do
        guard = guard + 1
        local g = build_group(obj, cur)
        for _, f in ipairs(g.fields or {}) do
            if f.readable then
                out[prefix .. g.class_name .. "::" .. f.name] = f.value
            end
        end
        local nxt = nil
        pcall(function() nxt = cur:GetSuperStruct() end)
        if not is_valid(nxt) or nxt == cur then break end
        cur = nxt
    end
end

local function _flatten_obj_full(obj, recurse)
    local out = {}
    local visited = {}
    _flatten_obj_chain(obj, "", out, visited)
    if not recurse or recurse < 1 then return out end

    -- One-hop sub-object recursion. We re-walk the class chain
    -- looking for ObjectProperty fields whose live value is a nested
    -- UObject ; flatten each into the same map under its field name.
    -- Bounded to 1 hop by default : deeper walks balloon (every
    -- subobject references the world / outer / class) and the
    -- attribute-set use case only needs depth 1.
    local cls = nil
    pcall(function() cls = obj:GetClass() end)
    if not is_valid(cls) then return out end
    local cur = cls
    local guard = 0
    while is_valid(cur) and guard < 32 do
        guard = guard + 1
        iter_properties(cur, function(p)
            pcall(function()
                local pcls = obj_class_name(p)
                if pcls ~= "ObjectProperty" then return end
                local nm = safe_fname(p, "GetFName")
                if nm == "" then return end
                local sub = obj[nm]
                if not is_valid(sub) then return end
                -- Skip self-references and outer/world links that
                -- explode the walk without adding diff value.
                if sub == obj then return end
                if nm == "Outer" or nm == "World" or nm == "Owner"
                    or nm == "Instigator" or nm == "Class"
                    or nm == "Pawn" or nm == "PlayerController" then
                    return
                end
                _flatten_obj_chain(sub, nm .. ".", out, visited)
            end)
        end)
        local nxt = nil
        pcall(function() nxt = cur:GetSuperStruct() end)
        if not is_valid(nxt) or nxt == cur then break end
        cur = nxt
    end
    return out
end

-- Generic snapshot/compare engine. kind is "cdo" or "actor". Resolver
-- maps a user-supplied id to (live UObject, canonical key, err).
local function _resolve_snap_target(kind, id)
    if kind == "cdo" then
        local cdo, err = resolve_cdo_arg(id)
        if not cdo then return nil, nil, err end
        local key = obj_class_name(cdo)
        if key == "" then key = id end
        return cdo, key, nil
    end
    -- actor : support shortcuts plus name-based resolve.
    --   player    : the local PlayerController
    --   pawn      : PC.Pawn (the live character) -- this is where
    --               health / stamina / inventory live, NOT the PC
    --   cheatmgr  : the live CheatManager (PC.CheatManager)
    if id == "player" or id == "cheatmgr" then
        local obj, err = _resolve_target(id)
        if not obj then return nil, nil, err end
        return obj, id, nil
    end
    if id == "pawn" then
        local pc, perr = _resolve_target("player")
        if not is_valid(pc) then return nil, nil, perr or "no PC" end
        local ok, pawn = pcall(function() return pc.Pawn end)
        if not ok or not is_valid(pawn) then
            -- Fallback : some games park the character on K2_GetPawn
            -- or on a custom field. Try ACharacter chain via FindFirstOf
            -- as a last-ditch.
            if FindFirstOf then
                local ok2, p2 = pcall(FindFirstOf, "DominionPlayerCharacter")
                if ok2 and is_valid(p2) then return p2, "pawn", nil end
            end
            return nil, nil, "pawn not found (PC.Pawn invalid)"
        end
        return pawn, "pawn", nil
    end
    if id:sub(1, 1) == "/" and StaticFindObject then
        local ok, obj = pcall(StaticFindObject, id)
        if ok and is_valid(obj) then
            return obj, sanitize_filename(id), nil
        end
    end
    -- First-class actor lookup (works for placed actors with display
    -- names). For class-typed singletons like AWorldSettings the
    -- actor resolver returns nil, so we then try FindFirstOf with
    -- standard prefix variants -- same approach as _resolve_target.
    local obj = feature_actor.resolve_actor_by_name(id)
    if obj then return obj, id, nil end
    if FindFirstOf then
        for _, cand in ipairs({ id, "U" .. id, "A" .. id }) do
            local ok, inst = pcall(FindFirstOf, cand)
            if ok and is_valid(inst) then return inst, id, nil end
        end
    end
    return nil, nil, "actor not found: " .. tostring(id)
end

-- arg shape : "<target> [+deep] [+raw]"
--   +deep : one-hop subobject recursion (needed for AttributeSets).
--   +raw  : disable the noise filter on compare (show ambient drift).
-- Recursion depth is sticky : snap+deep then compare without +deep
-- is meaningless. The snap call doesn't filter -- the snapshot is
-- always complete -- the filter only suppresses changed entries on
-- the compare side.
local function _parse_snap_args(arg)
    local target, rest = arg:match("^(%S+)%s*(.-)$")
    local recurse = 0
    local raw = false
    if rest then
        if rest:find("%+deep") then recurse = 1 end
        if rest:find("%+raw")  then raw = true end
    end
    return target, recurse, raw
end

-- Field-name patterns that drift every tick on every actor and would
-- otherwise drown the cheat-effect signal. Matched as Lua patterns
-- against the full key (e.g. "Mesh.SkeletalMeshComponent::LastPoseTickFrame").
-- Override per-call with the +raw flag.
local _DIFF_NOISE_PATTERNS = {
    "::LastPoseTickFrame$",
    "::AccumulatedSimTimeSeconds$",
    "::AccumulatedWallTimeSeconds$",
    "::DecayBuffer$",
    "::CurrentDelta$",
    "::LastRenderTime$",
    "::LastRenderTimeOnScreen$",
    "::LastSubmitTime$",
    "::ComponentVelocity$",
    "::AccumulatedTorque$",
    "::AccumulatedForce$",
}

local function _is_noise(name)
    for _, p in ipairs(_DIFF_NOISE_PATTERNS) do
        if name:find(p) then return true end
    end
    return false
end

local function _snap(kind, arg)
    if not arg or arg == "" then
        return false, "usage: world.diff." .. kind .. ".snap <target> [+deep]"
    end
    local id, recurse = _parse_snap_args(arg)
    local obj, key, err = _resolve_snap_target(kind, id)
    if not obj then return false, err end
    local snap = _flatten_obj_full(obj, recurse)
    _snapshots[kind .. ":" .. key] = snap
    local n = 0 ; for _ in pairs(snap) do n = n + 1 end
    return true, string.format("snapped %s%s : %d field(s)",
        key, (recurse > 0 and " (+deep)" or ""), n)
end

local function _compare(kind, arg)
    if not arg or arg == "" then
        return false, "usage: world.diff." .. kind .. ".compare <target> [+deep] [+raw]"
    end
    local id, recurse, raw = _parse_snap_args(arg)
    local obj, key, err = _resolve_snap_target(kind, id)
    if not obj then return false, err end
    local before = _snapshots[kind .. ":" .. key]
    if not before then
        return false, "no snapshot for " .. kind .. ":" .. key ..
            " (run world.diff." .. kind .. ".snap " .. id .. " first)"
    end
    local after = _flatten_obj_full(obj, recurse)

    local changed, seen = {}, {}
    local filtered = 0
    local function push(entry)
        if (not raw) and _is_noise(entry.name) then
            filtered = filtered + 1
            return
        end
        changed[#changed + 1] = entry
    end
    for k, v in pairs(before) do
        seen[k] = true
        local v2 = after[k]
        if v2 == nil then
            push({ name = k, before = v, after = "<absent>" })
        elseif v2 ~= v then
            push({ name = k, before = v, after = v2 })
        end
    end
    for k, v in pairs(after) do
        if not seen[k] then
            push({ name = k, before = "<absent>", after = v })
        end
    end
    table.sort(changed, function(a, b) return a.name < b.name end)

    local d = mod_paths.ipc_dir()
    if not d then return false, "ipc dir unavailable" end
    local out_path = d .. "\\" .. kind .. "_diff_" .. sanitize_filename(key) .. ".json"
    local parts = { '{"kind":', jstr(kind), ',"target":', jstr(key), ',"changed":[' }
    for i, c in ipairs(changed) do
        if i > 1 then parts[#parts + 1] = "," end
        parts[#parts + 1] = "{\"name\":" .. jstr(c.name)
            .. ",\"before\":" .. jstr(c.before)
            .. ",\"after\":" .. jstr(c.after) .. "}"
    end
    parts[#parts + 1] = "]}"
    local ok_w, path_or_err = mod_paths.write_atomic(out_path, table.concat(parts))
    if not ok_w then return false, "write failed: " .. tostring(path_or_err) end

    return true, string.format("%s : %d changed field(s)%s -> %s",
        key, #changed,
        (filtered > 0 and string.format(" (%d noise filtered, +raw to show)", filtered) or ""),
        out_path)
end

function M.diff_cdo_snap(arg)    return _snap("cdo", arg) end
function M.diff_cdo_compare(arg) return _compare("cdo", arg) end
function M.diff_actor_snap(arg)    return _snap("actor", arg) end
function M.diff_actor_compare(arg) return _compare("actor", arg) end

-- (kept below) router uses M.dump_actor_field above this point.

return M
