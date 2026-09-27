-- safety.lua
--
-- Value classifier and safe accessors for runtime UE values touched by
-- the probe + field verbs. The point of this module is to centralize
-- "is it safe to do X with this value" decisions so that the rest of
-- the code never directly calls UE methods on values whose memory
-- layout it can't be sure of.
--
-- Why this exists:
--   UE4SS exposes many things to lua as `userdata`. A few of those
--   (UObject, UClass, USubsystem, ...) are full lua-mt-wrapped objects
--   where calling :GetClass() / :GetName() / :IsA() is well-defined.
--   Others (FText, FName, FString, FVector, FGameplayTag, native
--   structs, lazy/soft object refs, ...) are also `userdata` but
--   calling UObject-shaped methods on them dereferences fields that
--   don't exist and produces an unrecoverable C++ access violation.
--   `pcall` does NOT catch access violations ; the engine just dies.
--
-- The fix is shape-based, not name-based: classify the value by the
-- methods it actually has and the result of cheap probing, then route
-- access through accessors that only call methods appropriate for that
-- shape. New crash classes get fixed by adding a rule here, never by
-- adding a class- or field-name to a deny list.
--
-- Public API:
--   safety.classify(val)            -> kind string + capability table
--   safety.is_uobject(val)          -> bool ; passes :IsA() shape test
--   safety.describe(val)            -> short string for display ; never crashes
--   safety.read_primitive(val)      -> (value, kind) | (nil, reason)
--                                     value is a lua boolean/number/string
--                                     when kind is one of those ; otherwise
--                                     a short descriptor like "<obj:Foo>".
--   safety.guard(fn, ...)           -> pcall-wrapped fn() that always
--                                     returns (ok, result_or_err) ; used
--                                     as the single chokepoint for any
--                                     UE method call we do.
--
-- Kinds returned by classify():
--   "nil"            value was nil
--   "boolean"        plain lua boolean
--   "number"         plain lua number
--   "string"         plain lua string
--   "table"          plain lua table (containers from UE4SS often appear
--                    as tables once iterated ; callers walk these
--                    themselves and are out of scope here)
--   "uobject"        userdata that responds to :IsA() ; safe for the
--                    full UObject method set
--   "text_like"      userdata that exposes :ToString() but NOT :IsA() ;
--                    covers FText, FName, FString. Use :ToString() only.
--   "soft_ref"       userdata that exposes :Get() ; covers TSoftObjectPtr,
--                    TLazyObjectPtr. Try :Get() then re-classify ; never
--                    walk into the wrapper itself.
--   "unsafe_ud"      userdata with no recognized accessors. Treat as
--                    opaque ; describe as "<userdata>" and never traverse.
--   "unknown"        anything else
--
-- The classifier deliberately uses cheap, side-effect-free probes
-- (`type(...)` and reading a function-valued field) before doing any
-- actual call. Reading `obj.IsA` is itself wrapped in pcall because some
-- userdata types raise on missing field access.

local M = {}

-- ---------- core guard --------------------------------------------------

-- Wrap any UE call in this. Returns (true, result) on success, or
-- (false, err_string) on a lua error. Cannot save us from a C++ access
-- violation ; that's what classify() upstream is for.
function M.guard(fn, ...)
    local args = { ... }
    local ok, result = pcall(function()
        return fn(table.unpack(args))
    end)
    if ok then return true, result end
    return false, tostring(result)
end

-- ---------- shape probes ------------------------------------------------

-- Safe field-presence check. Returns true iff `obj[name]` reads back as
-- a function. Wrapped in pcall because some userdata types raise on
-- absent field access instead of returning nil.
local function has_method(obj, name)
    local present = false
    pcall(function() present = (type(obj[name]) == "function") end)
    return present
end

-- Does the value pass the UObject shape test? UObjects in UE4SS reliably
-- respond to :GetClass() returning a UClass userdata ; FText/FName/FString
-- do not. We previously tested via has_method(val, "IsA"), but UE4SS
-- only exposes IsA through colon-dispatch on a metatable __index FUNCTION,
-- not a method table -- so raw indexing for "IsA" returns nil even for
-- valid UObjects, making every chip render as "UnknownClass". Calling
-- :GetClass() through pcall is a cheap, definitive shape probe and
-- doubles as the data we'd fetch next anyway.
function M.is_uobject(val)
    if type(val) ~= "userdata" then return false end
    local ok, cls = pcall(function() return val:GetClass() end)
    return ok and cls ~= nil
end

-- Does the value look like a UE4SS-exposed TArray? TArray userdata
-- supports `#val` (length operator) ; non-array userdata raises on #.
-- pcall is required because lua converts the # error into a hard
-- raise rather than a nil return.
function M.is_tarray(val)
    if type(val) ~= "userdata" then return false end
    local ok, n = pcall(function() return #val end)
    return ok and type(n) == "number" and n >= 0
end

-- ---------- main classifier ---------------------------------------------

function M.classify(val)
    local t = type(val)
    if t == "nil"     then return "nil"     end
    if t == "boolean" then return "boolean" end
    if t == "number"  then return "number"  end
    if t == "string"  then return "string"  end
    if t == "table"   then return "table"   end

    if t == "userdata" then
        if M.is_uobject(val) then
            return "uobject"
        end
        if has_method(val, "ToString") then
            return "text_like"
        end
        if has_method(val, "Get") then
            return "soft_ref"
        end
        if M.is_tarray(val) then
            return "tarray"
        end
        return "unsafe_ud"
    end

    return "unknown"
end

-- ---------- safe describe -----------------------------------------------

-- One-liner human-readable string for any value. Never raises, never
-- triggers a C++ AV. Safe to call from anywhere, including the inside
-- of error handlers.
-- Try to recover the asset path of a TSoftObjectPtr-like value on
-- this UE4SS build : the wrapper itself stringifies to "<invalid>",
-- but `GetObjectID():GetAssetPathName():ToString()` (plus optional
-- `GetSubPathString()`) yields the leaf asset name. Mirrors the
-- chain used by feature_introspect's CDO/actor dumpers so the
-- Discover-tab Read button surfaces the same shape. Returns the
-- string path or nil on any failure.
local function _soft_path_of_safe(v)
    if v == nil then return nil end
    local ok_oid, oid = pcall(function() return v:GetObjectID() end)
    if not ok_oid or oid == nil then return nil end
    local ok_an, an = pcall(function() return oid:GetAssetPathName() end)
    if not ok_an or an == nil then return nil end
    local ok_str, s = pcall(function() return an:ToString() end)
    if not ok_str or type(s) ~= "string" or s == "" or s == "None" then
        return nil
    end
    local ok_sub, sub = pcall(function() return oid:GetSubPathString() end)
    if ok_sub and sub ~= nil then
        local ok_ss, ss = pcall(function() return sub:ToString() end)
        if ok_ss and type(ss) == "string" and ss ~= "" then
            return s .. ":" .. ss
        end
    end
    return s
end

function M.describe(val)
    local kind = M.classify(val)
    if kind == "nil"     then return "<nil>"   end
    if kind == "boolean" then return tostring(val) end
    if kind == "number"  then return tostring(val) end
    if kind == "string"  then return val           end
    if kind == "table"   then return "<table>"     end

    if kind == "uobject" then
        local ok_cls, cls = M.guard(function() return val:GetClass() end)
        if ok_cls and cls then
            local ok_name, name = M.guard(function() return cls:GetName() end)
            if ok_name and type(name) == "string" then return "<obj:" .. name .. ">" end
        end
        local ok_n, n = M.guard(function() return val:GetName() end)
        if ok_n and type(n) == "string" then return "<obj:" .. n .. ">" end
        return "<obj>"
    end

    if kind == "text_like" then
        local ok_ts, ts = M.guard(function() return val:ToString() end)
        if ok_ts and type(ts) == "string" then return ts end
        return "<text>"
    end

    if kind == "soft_ref" then
        local ok_g, inner = M.guard(function() return val:Get() end)
        if ok_g and inner ~= nil then return M.describe(inner) end
        return "<unloaded>"
    end

    if kind == "tarray" then
        -- Enumerate so probe.read on TArray<UObject*> shows the actual
        -- pointers + classes the user needs (e.g. for grabbing a
        -- UDominionGameplayEffect* out of GameplayEffectsComponent
        -- .ReplicatedInstances). Caps the printout so a 5000-element
        -- AnimNotifyGEs array can't blow the IPC ack budget.
        --
        -- For TSoftObjectPtr<X> arrays we recover the per-element
        -- asset path via _soft_path_of_safe ; that's the same chain
        -- the CDO dumper uses and is what makes the Discover-tab
        -- "Read" button on (e.g.) UCheatManagerDeveloperSettings
        -- .GearPresets surface "DT_GearPreset_TierN" instead of a
        -- column of "<unloaded>" sentinels.
        local n = 0
        pcall(function() n = #val end)
        if n == 0 then return "TArray[0]: []" end
        local cap = 64
        local parts = {}
        for i = 1, math.min(n, cap) do
            local el
            local ok_get = pcall(function() el = val[i] end)
            local repr
            if not ok_get then
                repr = "<read-fail>"
            elseif el == nil then
                repr = "<nil>"
            elseif type(el) == "userdata" then
                -- Try the soft-ref path first ; falls through cleanly
                -- on non-soft-ref shapes.
                local soft_path = _soft_path_of_safe(el)
                if soft_path then
                    repr = soft_path
                else
                    local elem_kind = M.classify(el)
                    if elem_kind == "uobject" then
                        local cls = M.class_name_of(el) or "?"
                        local ok_ts, ts = pcall(function() return tostring(el) end)
                        local ptr = ok_ts and ts or "<ptr?>"
                        repr = string.format("%s (%s)", ptr, cls)
                    elseif elem_kind == "text_like" then
                        local ok_ts, ts = M.guard(function() return el:ToString() end)
                        repr = (ok_ts and type(ts) == "string") and ts or "<text>"
                    else
                        repr = M.describe(el)
                    end
                end
            else
                repr = tostring(el)
            end
            parts[#parts + 1] = string.format("[%d]=%s", i, repr)
        end
        local more = n > cap and string.format(" ... +%d more", n - cap) or ""
        return string.format("TArray[%d]: %s%s", n, table.concat(parts, ", "), more)
    end

    if kind == "unsafe_ud" then return "<userdata>" end
    return "<unknown>"
end

-- ---------- primitive read for prefill ----------------------------------

-- Returns (value, kind) suitable for prefilling a WPF row editor.
--   * For boolean/number/string the value is the primitive itself.
--   * For text_like values the value is the unwrapped lua string.
--   * For uobject/soft_ref/unsafe_ud the value is a short descriptor
--     string (so the WPF can show *something* without trying to edit it).
--   * For nil the value is nil and kind is "nil".
-- Never raises, never triggers a C++ AV.
function M.read_primitive(val)
    local kind = M.classify(val)
    if kind == "nil"     then return nil,                              "nil" end
    if kind == "boolean" then return val,                              "boolean" end
    if kind == "number"  then return val,                              "number" end
    if kind == "string"  then return val,                              "string" end
    if kind == "text_like" then
        local ok_ts, ts = M.guard(function() return val:ToString() end)
        if ok_ts and type(ts) == "string" then return ts, "text" end
        return "<text>", "text"
    end
    return M.describe(val), kind
end

-- ---------- uobject class name (safe) ----------------------------------

-- Returns the short class name of `val` if and only if `val` passes the
-- UObject shape test. Returns nil for anything else, including
-- text_like / soft_ref / unsafe_ud where calling :GetClass() can crash.
function M.class_name_of(val)
    if not M.is_uobject(val) then return nil end
    local ok_cls, cls = M.guard(function() return val:GetClass() end)
    if not ok_cls or not cls then return nil end
    local ok_n, name = M.guard(function() return cls:GetName() end)
    if ok_n and type(name) == "string" then return name end
    return nil
end

return M
