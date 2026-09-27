-- feature_foreach.lua
--
-- Bulk per-class operations. Lets the user apply one mutation across
-- every live instance of a UClass in a single verb -- the "loop" gap
-- the existing single-target Mod model can't express.
--
-- Verbs (registered by command_line_router):
--   world.findall <ClassName>
--       Returns "<n> instances" -- diagnostic, also warms the FindAllOf
--       cache so a follow-up foreach is faster.
--   world.foreach <ClassName> set <Field> <Value>
--       Per-instance scalar/bool/string field write. Same coercion
--       semantics as player.field.set.
--   world.foreach <ClassName> call <Method> [args...]
--       Per-instance method call. Args are coerced (bool / number /
--       string). The instance itself is the implicit `self`. The
--       literal token "$it" inside args is replaced by the iteration
--       target -- lets you write things like
--           world.foreach BuildingPieceData call ProgressComponent.UnlockBuilding $it
--       (though for now $it only works as a top-level arg).
--   world.foreach <ClassName> clear <Field>
--       Calls :Empty() / :Reset() on the named array field of every
--       instance.
--
-- Safety
--   * Hard cap on iteration: MAX_ITER (10000). We bail with a message
--     so a malformed class name like "Object" doesn't freeze the game.
--   * Every per-instance op runs in pcall ; first 5 failures are
--     captured and returned in the ack body, rest are counted only.
--   * Refuses to iterate "Object" / "Actor" / "UObject" / "AActor"
--     (the universal supertypes) -- those return tens of thousands
--     of items and almost certainly crash the engine if every one
--     gets a property write.
--
-- Returns ack body shape:
--   "applied=<N> skipped=<N> errors=<N> [first error: ...]"

local M = {}

local feature_field = require("feature_field")
local safety        = require("safety")

local MAX_ITER = 10000
local MAX_REPORTED_ERRORS = 5

-- Refuse to iterate these -- the result set is enormous and any
-- broadcast write almost certainly destabilises the engine.
local BLOCKED_CLASSES = {
    ["object"]  = true,
    ["uobject"] = true,
    ["actor"]   = true,
    ["aactor"]  = true,
    ["pawn"]    = true,
    ["apawn"]   = true,
}

local function trim(s)
    if type(s) ~= "string" then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function parse_bool(v)
    if type(v) == "boolean" then return v end
    local s = tostring(v or ""):lower()
    if s == "true" or s == "1" or s == "on" or s == "yes" then return true end
    if s == "false" or s == "0" or s == "off" or s == "no" then return false end
    return nil
end

local function coerce_token(s)
    local b = parse_bool(s);   if b ~= nil then return b end
    local n = tonumber(s);     if n     then return n end
    return s
end

-- Walk a dotted field path on `obj` and return the leaf object plus
-- the final member name. Used by `call` so a path like
-- "ProgressComponent.UnlockBuilding" resolves to the right target.
-- Returns (parent, leaf_name) or (nil, err).
local function walk_member_path(obj, path)
    local cur = obj
    local parts = {}
    for tok in path:gmatch("[^%.]+") do parts[#parts + 1] = tok end
    if #parts == 0 then return nil, "empty path" end
    for i = 1, #parts - 1 do
        local nxt
        local ok = pcall(function() nxt = cur[parts[i]] end)
        if not ok or nxt == nil then
            return nil, "missing intermediate: " .. parts[i]
        end
        cur = nxt
    end
    return cur, parts[#parts]
end

-- Enumerate live instances. Returns a table of valid userdata, plus
-- (optionally) an error string if FindAllOf raised. Hard-bounded
-- to MAX_ITER to keep the game thread responsive.
local function find_all(class_name)
    if type(FindAllOf) ~= "function" then
        return nil, "FindAllOf unavailable"
    end
    local ok, list = pcall(FindAllOf, class_name)
    if not ok or not list then
        return nil, "FindAllOf raised for '" .. class_name .. "'"
    end
    local n = 0
    pcall(function() n = #list end)
    if n == 0 then
        local ok_num, num_val = pcall(function() return list:Num() end)
        if ok_num and type(num_val) == "number" then n = num_val end
    end
    local out = {}
    local kept = 0
    for i = 1, math.min(n, MAX_ITER) do
        local ok_e, entry = pcall(function() return list[i] end)
        if ok_e and type(entry) == "userdata" and safety.is_uobject(entry) then
            kept = kept + 1
            out[kept] = entry
        end
    end
    if n > MAX_ITER then
        return out, string.format("warn: capped at MAX_ITER=%d (raw count=%d)", MAX_ITER, n)
    end
    return out
end

local function format_summary(applied, skipped, errors, errs, extra)
    local body = string.format("applied=%d skipped=%d errors=%d", applied, skipped, errors)
    if errs and #errs > 0 then
        body = body .. " | first error: " .. errs[1]
    end
    if extra and extra ~= "" then
        body = body .. " | " .. extra
    end
    return body
end

-- ---------- public verbs ------------------------------------------------

-- world.findall <ClassName>
function M.findall(args_str)
    local class_name = trim(args_str)
    if class_name == "" then
        return false, "usage: world.findall <ClassName>"
    end
    if BLOCKED_CLASSES[class_name:lower()] then
        return false, "refusing to enumerate '" .. class_name .. "' (universal supertype)"
    end
    local items, warn = find_all(class_name)
    if not items then return false, warn end
    return true, string.format("%d instances of %s%s",
        #items, class_name, warn and (" (" .. warn .. ")") or "")
end

-- world.foreach <ClassName> set <Field> <Value>
local function foreach_set(class_name, args_str)
    local field, value = args_str:match("^(%S+)%s+(.+)$")
    if not field then return false, "usage: world.foreach <Class> set <Field> <Value>" end

    local items, warn = find_all(class_name)
    if not items then return false, warn end
    if #items == 0 then return false, "no live instances of " .. class_name end

    local applied, skipped, errors = 0, 0, 0
    local errs = {}

    -- Coerce ONCE so all iterations write the same Lua value.
    local b = parse_bool(value)
    local coerced
    if b ~= nil then coerced = b
    else
        local n = tonumber(value)
        if n then coerced = n else coerced = tostring(value) end
    end

    for _, inst in ipairs(items) do
        local parent, leaf = walk_member_path(inst, field)
        if not parent then
            skipped = skipped + 1
        else
            local ok, werr = pcall(function() parent[leaf] = coerced end)
            if ok then
                applied = applied + 1
            else
                errors = errors + 1
                if #errs < MAX_REPORTED_ERRORS then
                    errs[#errs + 1] = tostring(werr)
                end
            end
        end
    end

    return true, format_summary(applied, skipped, errors, errs, warn)
end

-- world.foreach <ClassName> call <Method> [args...]
local function foreach_call(class_name, args_str)
    local field, tail = args_str:match("^(%S+)%s*(.*)$")
    if not field then return false, "usage: world.foreach <Class> call <Method> [args...]" end

    local items, warn = find_all(class_name)
    if not items then return false, warn end
    if #items == 0 then return false, "no live instances of " .. class_name end

    local raw_args = {}
    for tok in (tail or ""):gmatch("%S+") do raw_args[#raw_args + 1] = tok end

    local applied, skipped, errors = 0, 0, 0
    local errs = {}

    for _, inst in ipairs(items) do
        local parent, leaf = walk_member_path(inst, field)
        if not parent then
            skipped = skipped + 1
        else
            -- Re-coerce per iteration so $it can resolve to the live target.
            local coerced = {}
            for i, s in ipairs(raw_args) do
                if s == "$it" then
                    coerced[i] = inst
                else
                    coerced[i] = coerce_token(s)
                end
            end
            local ok, werr = pcall(function()
                local fn = parent[leaf]
                if type(fn) == "function" then
                    return fn(parent, table.unpack(coerced))
                end
                return parent[leaf](parent, table.unpack(coerced))
            end)
            if ok then
                applied = applied + 1
            else
                errors = errors + 1
                if #errs < MAX_REPORTED_ERRORS then
                    errs[#errs + 1] = tostring(werr)
                end
            end
        end
    end

    return true, format_summary(applied, skipped, errors, errs, warn)
end

-- world.foreach <ClassName> clear <Field>
local function foreach_clear(class_name, args_str)
    local field = trim(args_str)
    if field == "" then return false, "usage: world.foreach <Class> clear <Field>" end

    local items, warn = find_all(class_name)
    if not items then return false, warn end
    if #items == 0 then return false, "no live instances of " .. class_name end

    local applied, skipped, errors = 0, 0, 0
    local errs = {}

    for _, inst in ipairs(items) do
        local parent, leaf = walk_member_path(inst, field)
        if not parent then
            skipped = skipped + 1
        else
            local container
            local ok_g = pcall(function() container = parent[leaf] end)
            if not ok_g or container == nil then
                skipped = skipped + 1
            else
                local cleared = false
                local last_err
                local ok = pcall(function() container:Empty(); cleared = true end)
                if not ok then
                    last_err = "Empty failed"
                    ok = pcall(function() container:Reset(); cleared = true end)
                    if not ok then last_err = "Reset failed too" end
                end
                if cleared then
                    applied = applied + 1
                else
                    errors = errors + 1
                    if #errs < MAX_REPORTED_ERRORS then
                        errs[#errs + 1] = tostring(last_err or "unknown")
                    end
                end
            end
        end
    end

    return true, format_summary(applied, skipped, errors, errs, warn)
end

-- world.foreach <ClassName> <verb> <args...>
function M.foreach(args_str)
    local s = trim(args_str)
    if s == "" then
        return false, "usage: world.foreach <ClassName> <set|call|clear> <args...>"
    end
    local class_name, verb, rest = s:match("^(%S+)%s+(%S+)%s*(.*)$")
    if not (class_name and verb) then
        return false, "usage: world.foreach <ClassName> <set|call|clear> <args...>"
    end
    if BLOCKED_CLASSES[class_name:lower()] then
        return false, "refusing to iterate '" .. class_name .. "' (universal supertype)"
    end
    verb = verb:lower()
    if verb == "set" then
        return foreach_set(class_name, rest)
    elseif verb == "call" then
        return foreach_call(class_name, rest)
    elseif verb == "clear" then
        return foreach_clear(class_name, rest)
    end
    return false, "unknown foreach verb '" .. verb .. "' (expected: set | call | clear)"
end

return M
