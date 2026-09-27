-- Direct GAS attribute writes on the local pawn.
--
-- Background
-- ----------
-- The game stores its per-pawn float attributes in two parallel arrays on
-- UDominionAttributesComponent:
--
--   FloatAttributes        : TArray<UFloatAttribute>
--   AttributeValues        : TArray<float>
--
-- ...and a second pair for shared/global attributes:
--
--   SharedFloatAttributes  : TArray<UFloatAttribute>
--   SharedAttributeValues  : TArray<float>
--
-- The live values the game's combat/stamina/regen pipelines actually read
-- live in {Attribute,Shared}AttributeValues[i]. The matching array of
-- UFloatAttribute objects only tells us *what each slot represents* (via
-- the runtime class name of the object, e.g. "UMaxStaminaAttribute" or
-- "UMaxStaminaAttribute_C").
--
-- This is the same layout the round-21 GE probe walked to produce
-- attribute_values.json -- see feature_introspect.dump_gameplay_effects().
--
-- Why this is a NEW path
-- ----------------------
-- Several previous cheat attempts tried to mutate the same numbers via
-- (a) component-cache fields (e.g. UHealthComponent::ModifyMaxHealth -- §5),
-- (b) per-component scalar fields (e.g. UCriticalHitComponent.HeldEquipment
-- CriticalHitChance -- §13, §17), or
-- (c) the UDominionGameplayEffectsComponent apply path (§12, every GE).
-- Each of those failed for a different reason. Writing AttributeValues[i]
-- directly bypasses ALL of those layers and writes the attribute pool the
-- game's code reads on the very next tick. If the value gets clobbered
-- back, that tells us a GE is recomputing it; if it sticks, the cheat
-- works.
--
-- Wire format
-- -----------
--   player.attr.set <ClassName> <value>
--   player.attr.get <ClassName>
--
-- ClassName matching is case-insensitive and tries the supplied name
-- followed by a "U"-prefixed variant and a "_C" suffixed variant. This
-- lets the UI ship "MaxStaminaAttribute" and have it match the runtime
-- class name regardless of whether the loaded class is the C++ base
-- ("UMaxStaminaAttribute") or a BP subclass ("UMaxStaminaAttribute_C").

local M = {}

local feature_actor = require("feature_actor")

-- All known alias variants for the attributes component on the player pawn.
-- Mirrors ATTRIBUTES_COMPONENT_ALIASES in feature_introspect.lua so a single
-- source of truth isn't strictly necessary -- the alias list is short and
-- has been stable across every dump we've seen.
local ATTRIBUTES_COMPONENT_ALIASES = {
    "BP_Components_PlayerAttributesComponent",
    "AttributesComponent",
    "DominionAttributesComponent",
    "AttributesCmp",
    "Attributes",
}

local function get_pawn()
    local pawn = feature_actor.get_local_pawn()
    if not pawn or not feature_actor.is_valid_object(pawn) then
        return nil
    end
    return pawn
end

local function find_attr_component(pawn)
    for _, alias in ipairs(ATTRIBUTES_COMPONENT_ALIASES) do
        local ok, val = pcall(function() return pawn[alias] end)
        if ok and type(val) == "userdata" and feature_actor.is_valid_object(val) then
            return val, alias
        end
    end
    return nil, nil
end

-- Pull the runtime class short-name off a UObject. Used to identify which
-- UFloatAttribute subclass occupies each FloatAttributes[i] slot.
--
-- Round 23 fix: previously this only tried `:GetClass():GetName()`. In some
-- game sessions that returned nil/empty for every UFloatAttribute slot
-- (124 + 9 = 133 nil_class hits, scan=0) which broke every player.attr.set.
-- The introspect dump path (feature_introspect.get_runtime_class_name)
-- already had the full fallback chain that successfully produced
-- attribute_values.json with proper names, so we mirror it here:
--   1) GetClass():GetName()
--   2) GetClass():GetFName():ToString()
--   3) tail of GetClass():GetFullName() after the last "." or "/"
local function runtime_class_name(obj)
    if not obj or not obj.GetClass then return nil end
    local ok_cls, cls = pcall(function() return obj:GetClass() end)
    if not ok_cls or not cls then return nil end

    if cls.GetName then
        local ok, name = pcall(function() return cls:GetName() end)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    if cls.GetFName then
        local ok, fn = pcall(function() return cls:GetFName() end)
        if ok and fn and fn.ToString then
            local ok2, s = pcall(function() return fn:ToString() end)
            if ok2 and type(s) == "string" and s ~= "" then return s end
        end
    end
    if cls.GetFullName then
        local ok, full = pcall(function() return cls:GetFullName() end)
        if ok and type(full) == "string" and full ~= "" then
            local tail = full:match("([^%.%s/]+)$")
            if tail and tail ~= "" then return tail end
        end
    end
    return nil
end

-- Returns true if `candidate` matches `target` ignoring case, with optional
-- "U" prefix and "_C" suffix on either side. Examples that all match
-- "MaxStaminaAttribute":
--   MaxStaminaAttribute
--   maxstaminaattribute
--   UMaxStaminaAttribute
--   UMaxStaminaAttribute_C
--   MaxStaminaAttribute_C
local function names_match(candidate, target)
    if not candidate or not target then return false end
    local c = string.lower(candidate)
    local t = string.lower(target)
    -- Strip optional leading "u" and trailing "_c" from each side so we
    -- can compare the "core" attribute name.
    local function core(s)
        if s:sub(1, 1) == "u" then s = s:sub(2) end
        if s:sub(-2) == "_c" then s = s:sub(1, -3) end
        return s
    end
    return core(c) == core(t)
end

-- Walks one (attrs, values) pair looking for a slot whose UFloatAttribute
-- runtime class matches `target_name`. Returns (index, current_value) or nil.
-- The `diag` argument (optional table) is populated with debugging
-- breadcrumbs so the caller can build a useful error string when nothing
-- matches: scan_count (slots actually inspected), invalid_count (slots
-- skipped because feature_actor.is_valid_object rejected them),
-- nil_class_count (slots whose runtime class name was unresolvable), and
-- a sample[] of up to 5 resolved class names from this array (for the
-- "but I see these instead" hint in the error).
local function find_slot(attr_comp, attrs_field, values_field, target_name, diag)
    local ok_a, attrs = pcall(function() return attr_comp[attrs_field] end)
    local ok_v, values = pcall(function() return attr_comp[values_field] end)
    if not ok_a or not attrs then
        if diag then diag.array_error = (diag.array_error or "") .. attrs_field .. ":missing " end
        return nil
    end
    if not ok_v or not values then
        if diag then diag.array_error = (diag.array_error or "") .. values_field .. ":missing " end
        return nil
    end
    local n_a = 0; pcall(function() n_a = #attrs end)
    local n_v = 0; pcall(function() n_v = #values end)
    local n = math.min(n_a, n_v)
    if diag then
        diag.lengths = (diag.lengths or "") ..
            string.format("%s=%d/%s=%d ", attrs_field, n_a, values_field, n_v)
    end
    for i = 1, n do
        local eok, attr_obj = pcall(function() return attrs[i] end)
        if eok and type(attr_obj) == "userdata" then
            if feature_actor.is_valid_object(attr_obj) then
                local cn = runtime_class_name(attr_obj)
                if cn then
                    if diag then
                        diag.scan_count = (diag.scan_count or 0) + 1
                        if diag.sample and #diag.sample < 5 then
                            diag.sample[#diag.sample + 1] = cn
                        end
                    end
                    if names_match(cn, target_name) then
                        local vok, val = pcall(function() return values[i] end)
                        return i, vok and val or nil, attrs, values, cn
                    end
                else
                    if diag then diag.nil_class_count = (diag.nil_class_count or 0) + 1 end
                end
            else
                if diag then diag.invalid_count = (diag.invalid_count or 0) + 1 end
            end
        else
            if diag then diag.bad_index_count = (diag.bad_index_count or 0) + 1 end
        end
    end
    return nil
end

-- Resolves a class-name -> (which-array, index, current-value) on the local
-- pawn's attributes component. `which` is either "pawn" or "shared" so the
-- caller knows which values array to write into.
local function locate(class_name)
    local pawn = get_pawn()
    if not pawn then return nil, "no local pawn" end
    local attr_comp, comp_alias = find_attr_component(pawn)
    if not attr_comp then return nil, "no attributes component on pawn" end

    local diag = { sample = {} }
    local idx, cur, attrs, values, resolved =
        find_slot(attr_comp, "FloatAttributes", "AttributeValues", class_name, diag)
    if idx then
        return {
            which = "pawn",
            index = idx,
            current = cur,
            values = values,
            attrs = attrs,
            resolved_class = resolved,
        }
    end
    idx, cur, attrs, values, resolved =
        find_slot(attr_comp, "SharedFloatAttributes", "SharedAttributeValues", class_name, diag)
    if idx then
        return {
            which = "shared",
            index = idx,
            current = cur,
            values = values,
            attrs = attrs,
            resolved_class = resolved,
        }
    end

    -- Build a verbose error so we can see why nothing matched. Most likely
    -- failure modes:
    --   scan_count=0 + invalid_count=124 -> is_valid_object rejecting them
    --   scan_count=0 + nil_class_count=124 -> GetClass()/GetName() returning nothing
    --   scan_count=124 + sample shows different names -> our names_match logic is wrong
    --   array_error set -> couldn't get the FloatAttributes field at all
    local sample_str = "(none)"
    if diag.sample and #diag.sample > 0 then
        sample_str = table.concat(diag.sample, ",")
    end
    local err = string.format(
        "attribute '%s' not found on pawn (comp=%s scan=%d invalid=%d nil_class=%d bad_idx=%d arr_err=%s lens=%s sample=%s)",
        tostring(class_name),
        tostring(comp_alias),
        diag.scan_count or 0,
        diag.invalid_count or 0,
        diag.nil_class_count or 0,
        diag.bad_index_count or 0,
        tostring(diag.array_error or "none"),
        tostring(diag.lengths or "none"),
        sample_str)
    return nil, err
end

function M.set_attribute(class_name, value_str)
    if not class_name or class_name == "" then
        return false, "usage: player.attr.set <ClassName> <value>"
    end
    local n = tonumber(value_str)
    if not n then
        return false, "value must be a number"
    end
    local hit, err = locate(class_name)
    if not hit then return false, err end

    local before = hit.current
    local ok_w, werr = pcall(function() hit.values[hit.index] = n end)
    if not ok_w then
        return false, "write failed: " .. tostring(werr)
    end

    local after = n
    local ok_r, rv = pcall(function() return hit.values[hit.index] end)
    if ok_r and type(rv) == "number" then after = rv end

    print(string.format("[RSDWTools] attr.set %s [%s #%d] %s -> %s",
        hit.resolved_class or class_name, hit.which, hit.index,
        tostring(before), tostring(after)))

    return true, string.format("%s=%s (%s #%d, was %s)",
        hit.resolved_class or class_name, tostring(after),
        hit.which, hit.index, tostring(before))
end

function M.get_attribute(class_name)
    if not class_name or class_name == "" then
        return false, "usage: player.attr.get <ClassName>"
    end
    local hit, err = locate(class_name)
    if not hit then return false, err end
    return true, string.format("%s=%s (%s #%d)",
        hit.resolved_class or class_name,
        tostring(hit.current),
        hit.which, hit.index)
end

return M
