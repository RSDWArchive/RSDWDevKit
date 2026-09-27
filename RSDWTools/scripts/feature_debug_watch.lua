-- feature_debug_watch.lua
--
-- Live actor-property overlays. Builds on top of feature_debug_hud.AddDebugText:
-- AddDebugText is a one-shot snapshot, but if we Remove + Add the same
-- entry every ~250ms with a freshly-formatted string, the player sees
-- the value tick in real time. This is the standard UE pattern for
-- "live debug overlay" and the engine's native PostRender does the
-- per-frame painting for us, so no HUD hook is required.
--
-- Verbs (registered in command_line_router.lua):
--   debug.watch.probe <name|@>
--       -> walk the actor, find anything that looks like a health
--          stat (property name contains "health" / "hp" or an
--          ObjectProperty whose class name contains "health"), dump
--          findings to ipc/debug_watch_probe.json AND ack a quick
--          summary so the user can copy/paste a property path into
--          debug.watch.add.
--   debug.watch.add <name|@> [<expr>]
--       -> register the actor for live overlay. With no <expr> we
--          auto-pick the best health expression discovered by probe
--          (current/max if both exist, single value otherwise). With
--          <expr> the caller specifies it explicitly:
--               <single-path>            ->  "label: <val>"
--               <path>/<path>            ->  "label: <cur>/<max>"
--          paths are dot-walked: "Health.CurrentHealth" -> actor.Health.CurrentHealth
--   debug.watch.list
--   debug.watch.remove <name|@>
--   debug.watch.clear
--
-- The "@" sentinel means "use the actor under the reticle" (delegated
-- to feature_grab.pick_actor_under_reticle). Lets the user target
-- anything they're looking at without alt-tabbing to the Scan tab.

local M = {}

local feature_actor     = require("feature_actor")
local feature_debug_hud = require("feature_debug_hud")
local feature_grab      = require("feature_grab")
local mod_paths         = require("mod_paths")

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function is_valid(o) return feature_actor.is_valid_object(o) end

local function trim(s)
    if not s then return "" end
    return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

local function escape_json(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
    s = s:gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    s = s:gsub("[%z\1-\8\11\12\14-\31]", "")
    return s
end
local function jstr(s) return '"' .. escape_json(s) .. '"' end
local function jnum(n) return tostring(tonumber(n) or 0) end
local function jbool(b) return b and "true" or "false" end

local function safe_class_name(obj)
    if not obj then return "" end
    local ok, cls = pcall(function() return obj:GetClass() end)
    if not ok or not cls then return "" end
    local ok2, fn = pcall(function() return cls:GetFName() end)
    if not ok2 or not fn then return "" end
    local ok3, name = pcall(function() return fn:ToString() end)
    if not ok3 or not name then return "" end
    return name
end

-- Render any value sensibly for a one-line overlay. Handles the cases
-- the auto-discovery actually produces:
--   number   -> integer (no trailing zeros for whole values)
--   FText    -> :ToString() (UserReadableName etc.)
--   FName    -> :ToString()
--   AActor   -> short class+id name (CurrentTarget)
--   enum     -> tostring (UE4SS gives "EFoo::Bar")
--   bool     -> true/false
-- Falls through to tostring() so we never blow up on an unexpected type.
local function format_value(v)
    if v == nil then return "nil" end
    local t = type(v)
    if t == "number" then
        if v == math.floor(v) then return string.format("%d", v) end
        return string.format("%.1f", v)
    end
    if t == "boolean" then return v and "true" or "false" end
    if t == "string" then return v end
    if t == "userdata" then
        -- FText / FName expose ToString directly.
        local ok, s = pcall(function() return v:ToString() end)
        if ok and type(s) == "string" and s ~= "" then return s end
        -- AActor / UObject -> short name.
        local ok2, fn = pcall(function() return v:GetFName() end)
        if ok2 and fn then
            local ok3, n = pcall(function() return fn:ToString() end)
            if ok3 and type(n) == "string" and n ~= "" then return n end
        end
        return tostring(v)
    end
    return tostring(v)
end

-- "@" / "look" / "@look" sentinel: pull from the camera reticle. Any
-- other name resolves through feature_actor.resolve_actor_by_name.
local function resolve_target(name)
    local n = trim(name or "")
    if n == "" then return nil, "missing actor name" end
    local low = n:lower()
    if low == "@" or low == "look" or low == "@look" then
        local a, src = feature_grab.pick_actor_under_reticle()
        if not is_valid(a) then return nil, src or "no reticle target" end
        return a, "reticle:" .. tostring(src)
    end
    local a = feature_actor.resolve_actor_by_name(n)
    if not is_valid(a) then return nil, "actor not found: " .. n end
    return a, "name"
end

-- Stable key for a watch entry. UE4SS userdata wrappers don't survive
-- direct table-key comparison reliably, so we hash by short_name + class
-- which is unique enough for a debug overlay registry.
local function watch_key(actor)
    local short = feature_actor.short_name_of(actor) or "?"
    local cls   = safe_class_name(actor)
    return cls .. "|" .. short
end

-- ---------------------------------------------------------------------------
-- Property walker (dot-path "Foo.Bar.Baz" -> actor.Foo.Bar.Baz)
-- ---------------------------------------------------------------------------

local function split_path(s)
    local out = {}
    for seg in string.gmatch(s, "[^%.]+") do out[#out + 1] = seg end
    return out
end

-- Returns (value_or_nil, err_or_nil). Last segment may be a scalar
-- (number/bool); intermediate segments must be live UObjects. A
-- segment ending in "()" is invoked as a no-arg UFunction call instead
-- of a property read -- needed because some Dominion attributes only
-- have correct values via their BP-pure getter (e.g. UHealthComponent's
-- AuthoritativeHealth field is 0 on attribute-driven characters but
-- GetMaxHealth() returns the real value).
local function read_path(root, path_str)
    local segments = split_path(path_str)
    if #segments == 0 then return nil, "empty path" end
    local cur = root
    for i, seg in ipairs(segments) do
        if not is_valid(cur) and i > 1 then
            return nil, string.format("step %d (%s): parent invalid", i, seg)
        end
        local is_call = false
        local name = seg
        if seg:sub(-2) == "()" then
            is_call = true
            name = seg:sub(1, -3)
        end
        local ok, v
        if is_call then
            ok, v = pcall(function() return cur[name](cur) end)
        else
            ok, v = pcall(function() return cur[name] end)
        end
        if not ok then return nil, string.format("step %d (%s): %s error: %s", i, seg, is_call and "call" or "read", tostring(v)) end
        if v == nil then return nil, string.format("step %d (%s): nil", i, seg) end
        cur = v
        -- If this isn't the last segment and we got a userdata, validate
        -- the wrapper before next iteration. If it's the last segment
        -- we accept whatever type came back (number/bool/userdata).
        if i < #segments and type(cur) == "userdata" then
            local ok_v, valid = pcall(function() return cur:IsValid() end)
            if not ok_v or not valid then
                return nil, string.format("step %d (%s): invalid object", i, seg)
            end
        end
    end
    return cur, nil
end

-- ---------------------------------------------------------------------------
-- Probe (find Health-ish surface area on an actor)
-- ---------------------------------------------------------------------------

-- Common property names worth checking before resorting to a property
-- iteration. Cheap, predictable, and covers >90% of UE projects'
-- conventions for stat-bearing components. Dominion-specific names
-- (AiHealthComponent, etc.) live alongside generic ones because the
-- BP property is exposed under whatever name the parent class chose.
local CANDIDATE_COMPONENTS = {
    "HealthComponent",          -- ADominionAICharacter / DominionPlayer
    "Health",
    "HealthComp",
    "PlayerHealthComponent",
    "WorldActorHealthComponent",
    "AiHealthComponent",
    "BP_AiHitPointsComponent",  -- per-bone hit points (no aggregate val)
    "HitPointsComponent",
    "Stats",
    "StatsComponent",
    "AttributeSet",
    "Attributes",
    "AIAttributesComponent",
    "DominionHealth",
    "BP_Health",
}

-- Field names to look for on a candidate component. Order matters: the
-- first hit wins for the current/max auto-discovery. Dominion's
-- UHealthComponent uses AuthoritativeHealth (replicated server value);
-- LocalHealth is the client-predicted mirror.
local CANDIDATE_CURRENT_FIELDS = {
    "AuthoritativeHealth", "LocalHealth",
    "CurrentHealth", "Health", "HP", "CurrentHP", "Current", "Value",
}
local CANDIDATE_MAX_FIELDS = {
    "MaxHealth", "MaxHP", "Max", "MaximumHealth", "BaseHealth",
}

-- Getter UFunctions to try BEFORE raw fields on a candidate component.
-- The attribute-driven path (UHealthFromAttributeComponent) leaves the
-- raw replicated fields at 0 because the real value lives in the
-- AttributesComponent; only the BP-pure getters resolve to it. We try
-- these first so auto-detect doesn't latch onto a 0 reading.
local CANDIDATE_CURRENT_GETTERS = {
    "GetLocalHealth", "GetAuthoritativeHealth",
}
local CANDIDATE_MAX_GETTERS = {
    "GetMaxHealth",
}

-- Top-level actor getters used to build a multi-line overlay. Each is
-- BlueprintPure on ADominionAICharacter, so calling them with no args
-- via the "()" expr DSL is safe. We probe each one before including
-- it in the auto-expr so non-AI actors (props, players) get a slimmer
-- overlay rather than a wall of "<step 1: nil>".
local CANDIDATE_NAME_GETTERS  = { "GetUserReadableName" }
local CANDIDATE_POWER_GETTERS = { "GetAIPowerLevel" }
local CANDIDATE_STATE_GETTERS = { "GetCurrentAlertnessState" }
local CANDIDATE_TARGET_FIELDS = { "CurrentTarget" }

local function looks_numeric(v)
    if type(v) == "number" then return true end
    -- UE4SS sometimes wraps small ints as userdata for enums ; we don't
    -- want those for health.
    return false
end

-- Return list of {component_path, current_field, max_field_or_nil,
--                 current_value, max_value_or_nil, component_class}.
local function discover_health(actor)
    local hits = {}
    for _, comp_name in ipairs(CANDIDATE_COMPONENTS) do
        local ok, comp = pcall(function() return actor[comp_name] end)
        if ok and comp ~= nil then
            -- comp could be a scalar (then comp_name itself is the
            -- value -- e.g. actor.Health is a float). Cover that case.
            if looks_numeric(comp) then
                hits[#hits + 1] = {
                    component_path = comp_name,
                    current_field  = nil,         -- the path IS the value
                    max_field      = nil,
                    current_value  = comp,
                    max_value      = nil,
                    component_class = "<scalar>",
                }
            elseif type(comp) == "userdata" and is_valid(comp) then
                local cls = safe_class_name(comp)
                local cur_field, cur_val
                local max_field, max_val
                -- Try BP-pure getters first ; raw fields are 0 on the
                -- attribute-driven health path. Getter "name" is stored
                -- with trailing "()" so the expr DSL routes it through
                -- read_path's call branch.
                for _, g in ipairs(CANDIDATE_CURRENT_GETTERS) do
                    local ok2, v = pcall(function() return comp[g](comp) end)
                    if ok2 and looks_numeric(v) then
                        cur_field, cur_val = g .. "()", v
                        break
                    end
                end
                if not cur_field then
                    for _, f in ipairs(CANDIDATE_CURRENT_FIELDS) do
                        local ok2, v = pcall(function() return comp[f] end)
                        if ok2 and looks_numeric(v) then
                            cur_field, cur_val = f, v
                            break
                        end
                    end
                end
                for _, g in ipairs(CANDIDATE_MAX_GETTERS) do
                    local ok2, v = pcall(function() return comp[g](comp) end)
                    if ok2 and looks_numeric(v) then
                        max_field, max_val = g .. "()", v
                        break
                    end
                end
                if not max_field then
                    for _, f in ipairs(CANDIDATE_MAX_FIELDS) do
                        local ok2, v = pcall(function() return comp[f] end)
                        if ok2 and looks_numeric(v) then
                            max_field, max_val = f, v
                            break
                        end
                    end
                end
                if cur_field then
                    hits[#hits + 1] = {
                        component_path = comp_name,
                        current_field  = cur_field,
                        max_field      = max_field,
                        current_value  = cur_val,
                        max_value      = max_val,
                        component_class = cls,
                    }
                else
                    -- Component existed but no candidate current-field
                    -- matched. Record a partial hit so the JSON tells
                    -- the user *what* was found and what fields it had,
                    -- letting them paste an explicit expr into add.
                    hits[#hits + 1] = {
                        component_path = comp_name,
                        current_field  = nil,
                        max_field      = nil,
                        current_value  = nil,
                        max_value      = nil,
                        component_class = cls,
                        note = "component found but no candidate current-field matched ; see Scan tab for fields",
                    }
                end
            end
        end
    end
    return hits
end

-- Build the auto-pick expression from the first health hit. Returns
-- (expr_string, label). Expr matches the format read_expr understands.
local function expr_from_hit(hit)
    if hit.current_field == nil then
        return hit.component_path, "HP"
    end
    local cur = hit.component_path .. "." .. hit.current_field
    if hit.max_field then
        return cur .. "/" .. hit.component_path .. "." .. hit.max_field, "HP"
    end
    return cur, "HP"
end

-- Probe a single getter / field on `actor` ; returns the value if it
-- resolved to non-nil, else nil. Used by build_default_expr to drop
-- fields the actor doesn't expose, so the overlay never shows
-- "<step 1: nil>" placeholders for missing meta-getters.
local function try_call(actor, getter)
    local ok, v = pcall(function() return actor[getter](actor) end)
    if ok and v ~= nil then return v end
    return nil
end
local function try_get(actor, field)
    local ok, v = pcall(function() return actor[field] end)
    if ok and v ~= nil then return v end
    return nil
end

-- Build a multi-line overlay expr from whatever this actor exposes.
-- Order matters -- it's the rendered line order (Name first, HP next,
-- then meta-stats). Empty result means nothing useful was found.
local function build_default_expr(actor, hits)
    local fields = {}
    for _, g in ipairs(CANDIDATE_NAME_GETTERS) do
        if try_call(actor, g) ~= nil then
            fields[#fields + 1] = "Name=" .. g .. "()"
            break
        end
    end
    for _, h in ipairs(hits) do
        if h.current_field then
            local cur = h.component_path .. "." .. h.current_field
            local ex = h.max_field
                and (cur .. "/" .. h.component_path .. "." .. h.max_field)
                or cur
            fields[#fields + 1] = "HP=" .. ex
            break
        end
    end
    for _, g in ipairs(CANDIDATE_POWER_GETTERS) do
        if try_call(actor, g) ~= nil then
            fields[#fields + 1] = "Power=" .. g .. "()"
            break
        end
    end
    for _, g in ipairs(CANDIDATE_STATE_GETTERS) do
        if try_call(actor, g) ~= nil then
            fields[#fields + 1] = "State=" .. g .. "()"
            break
        end
    end
    for _, f in ipairs(CANDIDATE_TARGET_FIELDS) do
        local v = try_get(actor, f)
        -- Only include Target if it's a live actor ; an explicitly-nil
        -- field is more confusing than missing.
        if v ~= nil and type(v) == "userdata" and is_valid(v) then
            fields[#fields + 1] = "Target=" .. f
            break
        end
    end
    -- Tag/affinity builders iterate TArray + TMap via UE4SS's ForEach.
    -- That used to be a per-tick crash risk, but the 5s builder cache
    -- (CACHE_TTL) means each one only runs once every 5 seconds even
    -- when the ticker fires every 250ms -- safe enough to make them
    -- part of the default card. Each builder returns "-" cleanly when
    -- the actor has no data for that field, so they don't pollute
    -- non-AI overlays either.
    fields[#fields + 1] = "Tags=$tags"
    fields[#fields + 1] = "Wk=$weakness"
    fields[#fields + 1] = "Res=$resistance"
    fields[#fields + 1] = "Imm=$immunity"
    if #fields == 0 then return nil end
    return table.concat(fields, ";")
end

local function probe_path()
    local d = mod_paths.ipc_dir()
    if not d then return nil end
    return d .. "\\debug_watch_probe.json"
end

local function emit_probe_json(actor, source, hits)
    local p = probe_path()
    if not p then return false, "ipc dir unavailable" end
    local short = feature_actor.short_name_of(actor) or "?"
    local parts = { "{",
        '"actor":', jstr(short), ',',
        '"class":', jstr(safe_class_name(actor)), ',',
        '"source":', jstr(source), ',',
        '"hits":[',
    }
    for i, h in ipairs(hits) do
        if i > 1 then parts[#parts + 1] = "," end
        parts[#parts + 1] = "{"
            .. '"component":' .. jstr(h.component_path)
            .. ',"component_class":' .. jstr(h.component_class)
            .. ',"current_field":' .. (h.current_field and jstr(h.current_field) or "null")
            .. ',"current_value":' .. (h.current_value ~= nil and jnum(h.current_value) or "null")
            .. ',"max_field":' .. (h.max_field and jstr(h.max_field) or "null")
            .. ',"max_value":' .. (h.max_value and jnum(h.max_value) or "null")
            .. ',"note":' .. (h.note and jstr(h.note) or "null")
            .. "}"
    end
    parts[#parts + 1] = "]}"
    local ok, err = mod_paths.write_atomic(p, table.concat(parts))
    if not ok then return false, "write failed: " .. tostring(err) end
    return true, err
end

function M.probe(arg)
    local actor, src = resolve_target(arg)
    if not actor then return false, src end
    local hits = discover_health(actor)
    local ok, path_or_err = emit_probe_json(actor, src, hits)
    if not ok then return false, path_or_err end
    if #hits == 0 then
        return true, string.format("no health-like fields found ; dump=%s", path_or_err)
    end
    -- Prefer a hit with a real current_field for the ack summary ; if
    -- only partial (component-found-but-no-field) hits exist, surface
    -- that fact instead so the user knows to look at the JSON.
    local pick
    for _, h in ipairs(hits) do
        if h.current_field then pick = h ; break end
    end
    if not pick then
        local first = hits[1]
        return true, string.format(
            "%d component(s) found but no current-field matched ; first=%s class=%s ; dump=%s",
            #hits, first.component_path, first.component_class, path_or_err)
    end
    local expr, _label = expr_from_hit(pick)
    return true, string.format("found %d hit(s) ; pick=%s expr='%s' (cur=%s%s) ; dump=%s",
        #hits, pick.component_path, expr,
        tostring(pick.current_value),
        pick.max_value and ("/" .. tostring(pick.max_value)) or "",
        path_or_err)
end

-- ---------------------------------------------------------------------------
-- Tag helpers (used by diag verb and by $-builders below)
-- ---------------------------------------------------------------------------

-- Pull the short tag form (last "."-segment) for human display. Full
-- tags get long fast ("DamageType.Slash" -> "Slash").
local function tag_short(full)
    if not full or full == "" then return "" end
    local last_dot
    for i = #full, 1, -1 do
        if full:sub(i, i) == "." then last_dot = i ; break end
    end
    if last_dot then return full:sub(last_dot + 1) end
    return full
end

-- FGameplayTag wrapper -> tag-name string. Tag's TagName is an FName.
-- For tags read from UPROPERTY containers (e.g. LoadedData.GameplayTags)
-- the wrapper is a proper FStruct and `tag.TagName:ToString()` works.
-- For tags inside a return-by-value FGameplayTagContainer (e.g.
-- BP_GetOwnedGameplayTags()), UE4SS wraps them as opaque
-- LocalUnrealParam buffers and the property path can't be resolved --
-- in that case we fall back to the GetTagName UFUNCTION (return-by-
-- value FName, safe).
local function tag_to_string(tag)
    if tag == nil then return "" end
    -- Path 1: property-style read (works for UPROPERTY containers).
    local ok, fn = pcall(function() return tag.TagName end)
    if ok and fn then
        local ok2, s = pcall(function() return fn:ToString() end)
        if ok2 and type(s) == "string" and s ~= "" and s ~= "None" then
            return s
        end
    end
    -- Path 2: UFUNCTION GetTagName (return-by-value FName, safe).
    local ok3, fn2 = pcall(function() return tag:GetTagName() end)
    if ok3 and fn2 then
        local ok4, s2 = pcall(function() return fn2:ToString() end)
        if ok4 and type(s2) == "string" and s2 ~= "" and s2 ~= "None" then
            return s2
        end
    end
    return ""
end

-- ---------------------------------------------------------------------------
-- Diagnostic dumper (debug.watch.diag <name|@>)
-- ---------------------------------------------------------------------------
--
-- Walks the actor's class properties and dumps anything that looks
-- relevant to gameplay-tags / damage-affinities / faction. Use this
-- when $tags / $weakness / etc come back empty -- the dump shows
-- which fields actually exist on the live actor and what shape they
-- have (TArray length, TMap entries, ObjectProperty class name).

local function diag_path()
    local d = mod_paths.ipc_dir()
    if not d then return nil end
    return d .. "\\debug_watch_diag.json"
end

-- Try every "tag-ish" UPROPERTY name we know of. Returns array of
-- { name, kind, count, sample } records. kind is "container" (a
-- GameplayTagContainer-shaped thing whose .GameplayTags is iterable)
-- or "scalar" (FGameplayTag) or "unknown".
local TAG_FIELD_CANDIDATES = {
    "OwnedGameplayTags", "GameplayTags", "SavedGameplayTags",
    "ReplicatedGameplayTags", "GameplayTagContainer",
    "ActiveGameplayTags", "BlockedAbilityTags",
    -- ADominionAICharacter.LoadedData (UAIDataAsset*) carries the
    -- static gameplay tags defined in the AI's data asset. Path
    -- syntax is supported by inspect_tag_field below.
    "LoadedData.GameplayTags",
}

local function inspect_tag_field(actor, name)
    -- Allow dotted paths like "LoadedData.GameplayTags".
    local v = actor
    for seg in string.gmatch(name, "[^.]+") do
        local ok, nv = pcall(function() return v[seg] end)
        if not ok or nv == nil then return nil end
        v = nv
    end
    -- Container shape: has a .GameplayTags inner TArray.
    local arr
    pcall(function() arr = v.GameplayTags end)
    if arr then
        local n
        pcall(function() n = arr:GetArrayNum() end)
        if not n then pcall(function() n = #arr end) end
        n = n or 0
        local sample = {}
        local cap = math.min(n, 5)
        for i = 1, cap do
            local elem
            pcall(function() elem = arr[i] end)
            local s = elem and tag_to_string(elem) or ""
            if s ~= "" then sample[#sample + 1] = s end
        end
        return { name = name, kind = "container", count = n, sample = sample }
    end
    -- Scalar shape: a single FGameplayTag with .TagName.
    local tname
    pcall(function() tname = v.TagName end)
    if tname then
        local s
        pcall(function() s = tname:ToString() end)
        return { name = name, kind = "scalar", count = 1, sample = { s or "" } }
    end
    return { name = name, kind = "unknown", count = 0, sample = {} }
end

-- Try a return-by-value UFUNCTION that yields a tag container. We
-- explicitly skip out-param ones (unsafe under UE4SS marshaling).
local TAG_GETTER_CANDIDATES = {
    "BP_GetOwnedGameplayTags",
}

local function inspect_tag_getter(actor, name)
    local ok, v = pcall(function() return actor[name](actor) end)
    if not ok or v == nil then return nil end
    local arr
    pcall(function() arr = v.GameplayTags end)
    if not arr then
        return { name = name .. "()", kind = "callable_no_arr", count = 0, sample = {} }
    end
    local n
    pcall(function() n = arr:GetArrayNum() end)
    if not n then pcall(function() n = #arr end) end
    n = n or 0
    local sample = {}
    local cap = math.min(n, 5)
    for i = 1, cap do
        local elem
        pcall(function() elem = arr[i] end)
        local s = elem and tag_to_string(elem) or ""
        if s ~= "" then sample[#sample + 1] = s end
    end
    return { name = name .. "()", kind = "container", count = n, sample = sample }
end

-- Inspect AIAttributesComponent.DamageTypeAffinities. Returns
-- { found, class, entry_count, sample={ "Tag=Level", ... } }.
local function inspect_affinities(actor)
    local result = { found = false, class = "", entry_count = 0, sample = {} }
    local comp
    pcall(function() comp = actor.AIAttributesComponent end)
    if not comp then return result end
    result.found = true
    result.class = safe_class_name(comp)
    local map
    pcall(function() map = comp.DamageTypeAffinities end)
    if not map then return result end
    -- UE4SS TMap iteration is via :ForEach(callback) -- pairs() is
    -- NOT bound. Capped via the seen counter ; this runs once per
    -- diag invocation, not per tick.
    local seen = 0
    pcall(function()
        map:ForEach(function(k, v)
            if seen >= 16 then return end
            seen = seen + 1
            -- TMap entries come back wrapped in PropertyAccessors --
            -- both key and value need :get() to reach the real
            -- FGameplayTag / enum byte. Same pattern as
            -- feature_buildings.lua.
            local key = k
            local got_k
            pcall(function() got_k = k:get() end)
            if got_k ~= nil then key = got_k end
            local val = v
            if type(val) ~= "number" then
                local got_v
                pcall(function() got_v = v:get() end)
                if got_v ~= nil then val = got_v end
            end
            local kn = tag_to_string(key)
            local vn
            if type(val) == "number" then
                vn = tostring(val)
            else
                pcall(function() vn = tostring(val) end)
            end
            result.sample[#result.sample + 1] = (kn ~= "" and kn or "?") .. "=" .. (vn or "?")
        end)
    end)
    result.entry_count = seen
    return result
end

local function emit_diag_json(actor, source, tag_results, getter_results, affinities)
    local p = diag_path()
    if not p then return false, "ipc dir unavailable" end
    local function jrec(r)
        local s = "["
        for i, v in ipairs(r.sample) do
            if i > 1 then s = s .. "," end
            s = s .. jstr(v)
        end
        s = s .. "]"
        return "{"
            .. '"name":' .. jstr(r.name)
            .. ',"kind":' .. jstr(r.kind)
            .. ',"count":' .. jnum(r.count)
            .. ',"sample":' .. s
            .. "}"
    end
    local parts = { "{",
        '"actor":', jstr(feature_actor.short_name_of(actor) or "?"), ',',
        '"class":', jstr(safe_class_name(actor)), ',',
        '"source":', jstr(source), ',',
        '"tag_fields":[' }
    for i, r in ipairs(tag_results) do
        if i > 1 then parts[#parts + 1] = "," end
        parts[#parts + 1] = jrec(r)
    end
    parts[#parts + 1] = '],"tag_getters":['
    for i, r in ipairs(getter_results) do
        if i > 1 then parts[#parts + 1] = "," end
        parts[#parts + 1] = jrec(r)
    end
    parts[#parts + 1] = '],"affinities":{'
        .. '"found":' .. jbool(affinities.found)
        .. ',"class":' .. jstr(affinities.class)
        .. ',"entry_count":' .. jnum(affinities.entry_count)
        .. ',"sample":['
    for i, s in ipairs(affinities.sample) do
        if i > 1 then parts[#parts + 1] = "," end
        parts[#parts + 1] = jstr(s)
    end
    parts[#parts + 1] = "]}}"
    local ok, err = mod_paths.write_atomic(p, table.concat(parts))
    if not ok then return false, "write failed: " .. tostring(err) end
    return true, p
end

function M.diag(arg)
    local actor, src = resolve_target(arg)
    if not actor then return false, src end

    local tag_results = {}
    for _, n in ipairs(TAG_FIELD_CANDIDATES) do
        local r = inspect_tag_field(actor, n)
        if r then tag_results[#tag_results + 1] = r end
    end
    local getter_results = {}
    for _, n in ipairs(TAG_GETTER_CANDIDATES) do
        local r = inspect_tag_getter(actor, n)
        if r then getter_results[#getter_results + 1] = r end
    end
    local affinities = inspect_affinities(actor)

    local ok, p = emit_diag_json(actor, src, tag_results, getter_results, affinities)
    if not ok then return false, p end

    -- Compact ack summary so the user can see at-a-glance whether
    -- anything was found without opening the JSON.
    local found_tags = 0
    for _, r in ipairs(tag_results) do
        if r.kind == "container" and r.count > 0 then found_tags = found_tags + 1 end
    end
    for _, r in ipairs(getter_results) do
        if r.kind == "container" and r.count > 0 then found_tags = found_tags + 1 end
    end
    return true, string.format(
        "tag_sources=%d (of %d field+%d getter checked) ; affinities=%s entries=%d ; dump=%s",
        found_tags, #tag_results, #getter_results,
        affinities.found and ("yes:" .. affinities.class) or "no",
        affinities.entry_count, p)
end

-- ---------------------------------------------------------------------------
-- Expression evaluator
-- ---------------------------------------------------------------------------
--
-- Grammar:
--   EXPR    := FIELD ( ";" FIELD )*
--   FIELD   := [ LABEL "=" ] VEXPR
--   VEXPR   := PATH ( "/" PATH )? | BUILDER
--   PATH    := SEG ( "." SEG )*
--   SEG     := name | name "()"     -- "()" calls a no-arg UFunction
--   BUILDER := "$" name [ "(" arg ")" ]
--
-- Builders are special read-only producers that don't fit the dot-walk
-- model (gameplay-tag containers, TMap iteration, etc.). The "$" sigil
-- keeps them syntactically distinct from property paths.
--
-- Single-field, no-label exprs render bare (back-compat with the old
-- single-line "label: val" overlay path -- the caller's stored label
-- gets prepended by refresh_label). Multi-field exprs render as one
-- "Label: value" line per field, joined by \n, and the refresh_label
-- prefix is suppressed.

-- ---------------------------------------------------------------------------
-- $-builders
-- ---------------------------------------------------------------------------

-- (tag_short / tag_to_string moved above the diag verb so it can use them.)

-- Read OwnedGameplayTags from an actor. Strategy (best-quality first):
--   1) actor.LoadedData.GameplayTags (UPROPERTY on UAIDataAsset).
--      This is the static tag set defined in the AI's data asset and
--      is wrapped as a proper FStruct -- iteration yields real
--      FGameplayTag wrappers and tag.TagName:ToString() works.
--   2) actor:BP_GetOwnedGameplayTags() (return-by-value, safe to
--      call). Includes runtime-added tags but elements come back as
--      opaque LocalUnrealParam wrappers, so tag_to_string falls back
--      to GetTagName() UFUNCTION.
--   3) actor.SavedGameplayTags (UPROPERTY, save-game tier). Often
--      empty until the AI is persisted, but cheap to check.
-- Reads the resulting container's GameplayTags TArray with INDEXED
-- access (NOT :ForEach -- the Lua-bound callback marshals an
-- FGameplayTag wrapper per element and accumulates native-frame damage
-- in hot loops).
--
-- IMPORTANT: do NOT guard with `if not arr.ForEach then return end`.
-- UE4SS userdata methods are dispatched via __index, not exposed as
-- table fields, so `arr.ForEach` is nil -- which would silently
-- early-out even when the array is perfectly readable.
local function read_owned_tags(actor)
    local tags = {}
    local seen = {}  -- de-dup across sources
    local function harvest(container)
        if not container then return end
        local arr
        pcall(function() arr = container.GameplayTags end)
        if not arr then return end
        local n
        pcall(function() n = arr:GetArrayNum() end)
        if not n then
            pcall(function() n = #arr end)
        end
        if not n or n == 0 then return end
        if n > 64 then n = 64 end
        for i = 1, n do
            local elem
            pcall(function() elem = arr[i] end)
            if elem ~= nil then
                local s = tag_to_string(elem)
                if s ~= "" and not seen[s] then
                    seen[s] = true
                    tags[#tags + 1] = s
                end
            end
        end
    end
    -- Source 1: data-asset tags.
    local loaded
    pcall(function() loaded = actor.LoadedData end)
    if loaded then
        local c
        pcall(function() c = loaded.GameplayTags end)
        harvest(c)
    end
    -- Source 2: BP getter (runtime-aggregated tags).
    local bpc
    pcall(function() bpc = actor:BP_GetOwnedGameplayTags() end)
    harvest(bpc)
    -- Source 3: SavedGameplayTags property.
    local saved
    pcall(function() saved = actor.SavedGameplayTags end)
    harvest(saved)
    return tags
end

-- Walk every property path that might host an AIAttributesComponent.
-- The header dump shows it's a direct field on ADominionAICharacter
-- ("AIAttributesComponent"). We CLASS-CHECK before touching
-- DamageTypeAffinities -- earlier versions also tried generic names
-- like "AttributesComponent", but on non-AI actors that field can
-- point to a different component layout, and reading
-- DamageTypeAffinities from the wrong type AVs in native code (not
-- catchable by pcall, surfaces as a delayed game crash).
local AI_ATTR_CANDIDATES = { "AIAttributesComponent" }
local function find_ai_attr(actor)
    for _, n in ipairs(AI_ATTR_CANDIDATES) do
        local ok, comp = pcall(function() return actor[n] end)
        if ok and type(comp) == "userdata" and is_valid(comp) then
            local cls = safe_class_name(comp)
            if cls:find("AIAttributes", 1, true) then
                return comp
            end
        end
    end
    return nil
end

-- Pull damage-type affinities filtered by EDamageTypeAffinity name.
-- Returns array of short tag-names matching the requested level.
-- level is one of "Weakness", "Resistance", "Immunity" (case-sensitive
-- per the engine enum).
local function read_affinities(actor, level)
    local out = {}
    local comp = find_ai_attr(actor)
    if not comp then return out end
    local map
    pcall(function() map = comp.DamageTypeAffinities end)
    if not map then return out end
    -- UE4SS TMap iteration is via :ForEach (pairs is NOT bound).
    -- Safe outside hot loops -- this is gated by a 5s builder cache.
    local level_to_int = { Weakness = 0, Resistance = 1, Immunity = 2 }
    local want_int = level_to_int[level]
    local seen = 0
    pcall(function()
        map:ForEach(function(k, v)
            if seen >= 32 then return end
            seen = seen + 1
            -- Unwrap PropertyAccessor on both sides (key and value).
            local key = k
            local got_k
            pcall(function() got_k = k:get() end)
            if got_k ~= nil then key = got_k end
            local val = v
            if type(val) ~= "number" then
                local got_v
                pcall(function() got_v = v:get() end)
                if got_v ~= nil then val = got_v end
            end
            local matches = false
            if type(val) == "number" then
                matches = (val == want_int)
            else
                local s
                pcall(function() s = tostring(val) end)
                if s and s:find(level, 1, true) then matches = true end
            end
            if matches then
                local tag_name = tag_to_string(key)
                if tag_name ~= "" then out[#out + 1] = tag_short(tag_name) end
            end
        end)
    end)
    return out
end

-- Builder dispatch table. Each takes (actor, arg_str_or_nil) and
-- returns (formatted_string, ok). "ok" is false only on hard errors ;
-- empty results return an empty string with ok=true so the field
-- still renders cleanly ("Weakness: -").
local BUILDERS = {}

-- Per-actor builder cache. Tags + damage affinities barely change at
-- runtime, so we re-compute at most once per CACHE_TTL seconds even
-- when the ticker fires every 250ms. This keeps the per-tick load on
-- UE4SS's struct-marshaling minimal -- the historical crashes when
-- iterating these maps every tick were death-by-a-thousand-cuts in
-- native frame state, not single bad calls.
local CACHE_TTL = 5.0
local builder_cache = {}  -- key=actor_key.."|"..bname.."|"..(barg or "") -> { stamp, value }

local function cache_get(key)
    local hit = builder_cache[key]
    if not hit then return nil end
    if (os.clock() - hit.stamp) > CACHE_TTL then return nil end
    return hit.value
end
local function cache_put(key, value)
    builder_cache[key] = { stamp = os.clock(), value = value }
end

BUILDERS.tags = function(actor, arg)
    local all = read_owned_tags(actor)
    if #all == 0 then return "-", true end
    local list = {}
    if arg and arg ~= "" then
        for _, t in ipairs(all) do
            if t:sub(1, #arg) == arg then list[#list + 1] = tag_short(t) end
        end
    else
        for _, t in ipairs(all) do list[#list + 1] = tag_short(t) end
    end
    if #list == 0 then return "-", true end
    -- Cap at 8 entries to keep the overlay readable.
    if #list > 8 then
        local trimmed = { table.unpack(list, 1, 8) }
        trimmed[#trimmed + 1] = string.format("+%d more", #list - 8)
        list = trimmed
    end
    return table.concat(list, ", "), true
end

BUILDERS.tags_full = function(actor, arg)
    local all = read_owned_tags(actor)
    if #all == 0 then return "-", true end
    local list = {}
    if arg and arg ~= "" then
        for _, t in ipairs(all) do
            if t:sub(1, #arg) == arg then list[#list + 1] = t end
        end
    else
        list = all
    end
    if #list == 0 then return "-", true end
    return table.concat(list, ", "), true
end

BUILDERS.affinity = function(actor, arg)
    local level = arg and arg ~= "" and arg or "Weakness"
    local list = read_affinities(actor, level)
    if #list == 0 then return "-", true end
    return table.concat(list, ", "), true
end

-- Convenience aliases so users can write @add @ Weakness=$weakness
-- instead of needing to remember $affinity(Weakness).
BUILDERS.weakness   = function(a) return BUILDERS.affinity(a, "Weakness")   end
BUILDERS.resistance = function(a) return BUILDERS.affinity(a, "Resistance") end
BUILDERS.immunity   = function(a) return BUILDERS.affinity(a, "Immunity")   end
BUILDERS.immune     = BUILDERS.immunity

-- Parse a builder vexpr ("$name" or "$name(arg)"). Returns name + arg
-- on success, nil on shape mismatch.
local function parse_builder(vexpr)
    if vexpr:sub(1, 1) ~= "$" then return nil end
    local body = vexpr:sub(2)
    local lp = body:find("(", 1, true)
    if not lp then return body, nil end
    local rp = body:find(")", lp + 1, true) or (#body + 1)
    return body:sub(1, lp - 1), trim(body:sub(lp + 1, rp - 1))
end

local function parse_expr(expr)
    local fields = {}
    for chunk in string.gmatch(expr or "", "[^;]+") do
        local c = trim(chunk)
        if c ~= "" then
            local eq = c:find("=", 1, true)
            if eq then
                fields[#fields + 1] = { label = trim(c:sub(1, eq - 1)), vexpr = trim(c:sub(eq + 1)) }
            else
                fields[#fields + 1] = { label = nil, vexpr = c }
            end
        end
    end
    return fields
end

-- Returns (formatted_string, ok). On read failure formats the err
-- inline so the overlay still tells the user *why* the read failed.
local function eval_value_expr(actor, vexpr)
    -- Builder dispatch ($name / $name(arg)).
    local bname, barg = parse_builder(vexpr)
    if bname then
        local fn = BUILDERS[bname]
        if not fn then return "<unknown builder $" .. bname .. ">", false end
        local ckey = watch_key(actor) .. "|" .. bname .. "|" .. (barg or "")
        local cached = cache_get(ckey)
        if cached then return cached[1], cached[2] end
        local ok, s_or_err, ok_inner = pcall(fn, actor, barg)
        if not ok then return "<builder err: " .. tostring(s_or_err) .. ">", false end
        local result_ok = ok_inner ~= false
        cache_put(ckey, { s_or_err, result_ok })
        return s_or_err, result_ok
    end
    local slash = vexpr:find("/", 1, true)
    if not slash then
        local v, err = read_path(actor, vexpr)
        if err then return "<" .. err .. ">", false end
        return format_value(v), true
    end
    local left  = trim(vexpr:sub(1, slash - 1))
    local right = trim(vexpr:sub(slash + 1))
    local lv, lerr = read_path(actor, left)
    if lerr then return "<" .. lerr .. ">", false end
    local rv, rerr = read_path(actor, right)
    if rerr then return format_value(lv) .. "/<" .. rerr .. ">", false end
    return format_value(lv) .. "/" .. format_value(rv), true
end

-- Returns (text, ok, is_multi). is_multi tells refresh_label whether
-- to skip its own "label: " prefix (multi-field exprs already have
-- one prefix per line).
local function eval_expr(actor, expr)
    local fields = parse_expr(expr)
    if #fields == 0 then return "<empty expr>", false, false end
    if #fields == 1 and fields[1].label == nil then
        local s, ok = eval_value_expr(actor, fields[1].vexpr)
        return s, ok, false
    end
    local lines = {}
    local all_ok = true
    for _, f in ipairs(fields) do
        local s, ok = eval_value_expr(actor, f.vexpr)
        if not ok then all_ok = false end
        lines[#lines + 1] = (f.label or "?") .. ": " .. s
    end
    return table.concat(lines, "\n"), all_ok, true
end

-- ---------------------------------------------------------------------------
-- Registry + ticker
-- ---------------------------------------------------------------------------

-- key -> { actor, label, expr, color, last_text }
local watches = {}
local watch_count = 0
local ticker_started = false

-- Per-tick dur for AddDebugText. Has to comfortably exceed the tick
-- interval so the label never blanks between refreshes, but short
-- enough that if we crash / drop a watch the label disappears quickly.
local TICK_MS  = 250
local TICK_DUR = 1.0   -- seconds

local YELLOW = { R = 255, G = 255, B = 0, A = 255 }

local function refresh_label(w)
    local hud, _ = feature_debug_hud.resolve_hud_external and feature_debug_hud.resolve_hud_external() or nil
    -- feature_debug_hud doesn't currently export resolve_hud ; fall back
    -- to the same FindFirstOf path used everywhere else in this codebase.
    if not is_valid(hud) and FindFirstOf then
        local ok, h = pcall(function() return FindFirstOf("DebugCameraHUD") end)
        if ok and is_valid(h) then hud = h end
        if not is_valid(hud) then
            local ok2, h2 = pcall(function() return FindFirstOf("HUD") end)
            if ok2 and is_valid(h2) then hud = h2 end
        end
    end
    if not is_valid(hud) then return false, "no HUD" end

    local text, _ok, is_multi = eval_expr(w.actor, w.expr)
    -- Multi-field exprs already include their own "Label: value" per
    -- line ; only the back-compat single-field case wants the legacy
    -- "<w.label>: <text>" prefix.
    local full = (is_multi or w.label == nil or w.label == "")
        and text
        or (w.label .. ": " .. text)

    -- Remove the previous entry for this actor before adding the next ;
    -- otherwise DebugTextList grows by one every tick.
    pcall(function() hud:RemoveDebugText(w.actor, false) end)
    pcall(function()
        hud:AddDebugText(
            full,
            w.actor,
            TICK_DUR,
            { X = 0, Y = 0, Z = 0 },
            { X = 0, Y = 0, Z = 0 },
            w.color or YELLOW,
            false, false, true,
            nil, 1.0, true
        )
    end)
    w.last_text = full
    return true
end

local function tick_all()
    -- Snapshot keys first so we can mutate `watches` (drop invalids)
    -- without confusing the iteration.
    local keys = {}
    for k in pairs(watches) do keys[#keys + 1] = k end
    for _, k in ipairs(keys) do
        local w = watches[k]
        if w then
            if not is_valid(w.actor) then
                watches[k] = nil
                watch_count = watch_count - 1
            else
                pcall(refresh_label, w)
            end
        end
    end
end

local function ensure_ticker()
    if ticker_started then return end
    if not LoopAsync then return end
    ticker_started = true
    LoopAsync(TICK_MS, function()
        if watch_count <= 0 then
            -- No subscribers ; let the loop idle. We cannot truly stop
            -- LoopAsync once started (returning true ends it forever),
            -- so we just early-exit cheaply each tick.
            return false
        end
        pcall(tick_all)
        return false
    end)
end

-- ---------------------------------------------------------------------------
-- Public verbs
-- ---------------------------------------------------------------------------

function M.add(arg)
    local words = {}
    for w in string.gmatch(arg or "", "%S+") do words[#words + 1] = w end
    if #words == 0 then
        return false, "usage: debug.watch.add <name|@> [<expr>]"
    end
    local name = words[1]
    local expr = nil
    if #words >= 2 then
        expr = table.concat(words, " ", 2)
    end

    local actor, src = resolve_target(name)
    if not actor then return false, src end

    -- Auto-discovery if no expr given. Builds a multi-line overlay
    -- (Name + HP + Power + State + Target, whichever resolve) so the
    -- player sees a richer card by default ; the caller can still
    -- pass an explicit expr to override. label only applies to the
    -- back-compat single-field unlabeled case ; multi-field exprs
    -- render their own per-line labels and refresh_label suppresses
    -- this prefix.
    local label = "HP"
    if not expr then
        local hits = discover_health(actor)
        expr = build_default_expr(actor, hits)
        if not expr then
            return false, "no overlay-able fields auto-detected ; run debug.watch.probe " .. name .. " or pass an explicit expr"
        end
    end

    -- Sanity-check the expr now so the user gets immediate feedback
    -- instead of silently-broken overlays.
    local sample, ok = eval_expr(actor, expr)
    if not ok then
        return false, "expr '" .. expr .. "' failed: " .. sample
    end

    local key = watch_key(actor)
    if not watches[key] then watch_count = watch_count + 1 end
    watches[key] = {
        actor    = actor,
        label    = label,
        expr     = expr,
        color    = YELLOW,
        last_text = nil,
    }

    ensure_ticker()
    -- Render once immediately so the user sees the label before the
    -- ticker's first tick.
    pcall(refresh_label, watches[key])

    local short = feature_actor.short_name_of(actor) or "?"
    return true, string.format("watching %s (src=%s) expr='%s' sample=%s",
        short, src, expr, sample)
end

-- One-shot variant of add: render the auto-discovered multi-line
-- overlay once with a long TICK_DUR (8s) and DON'T enter the registry
-- or start the ticker. Useful when you just want a glance at an actor
-- without paying the per-tick refresh cost. Optional explicit expr
-- after the target name overrides auto-discovery (same shape as add).
function M.snap(arg)
    local words = {}
    for w in string.gmatch(arg or "", "%S+") do words[#words + 1] = w end
    if #words == 0 then
        return false, "usage: debug.watch.snap <name|@> [<expr>]"
    end
    local name = words[1]
    local explicit_expr = nil
    if #words >= 2 then
        explicit_expr = table.concat(words, " ", 2)
    end

    local actor, src = resolve_target(name)
    if not actor then return false, src end

    local expr = explicit_expr
    if not expr then
        local hits = discover_health(actor)
        expr = build_default_expr(actor, hits)
        if not expr then
            return false, "no overlay-able fields auto-detected ; try debug.watch.probe " .. name
        end
    end
    local text, _ok = eval_expr(actor, expr)

    local hud
    if FindFirstOf then
        local ok, h = pcall(function() return FindFirstOf("DebugCameraHUD") end)
        if ok and is_valid(h) then hud = h end
        if not is_valid(hud) then
            local ok2, h2 = pcall(function() return FindFirstOf("HUD") end)
            if ok2 and is_valid(h2) then hud = h2 end
        end
    end
    if not is_valid(hud) then return false, "no HUD" end

    pcall(function() hud:RemoveDebugText(actor, false) end)
    pcall(function()
        hud:AddDebugText(text, actor, 8.0,
            { X = 0, Y = 0, Z = 0 }, { X = 0, Y = 0, Z = 0 },
            YELLOW, false, false, true, nil, 1.0, true)
    end)

    local short = feature_actor.short_name_of(actor) or "?"
    -- Count lines via gsub (returns replacement count + 1).
    local _, nl = text:gsub("\n", "\n")
    return true, string.format("snap %s (src=%s) lines=%d expr='%s'",
        short, src, nl + 1, expr)
end

function M.remove(arg)
    local actor, src = resolve_target(arg)
    if not actor then return false, src end
    local key = watch_key(actor)
    if not watches[key] then
        return false, "not watching " .. (feature_actor.short_name_of(actor) or "?")
    end
    -- Best-effort clear of the live label ; the actor may have moved
    -- out of the world, in which case RemoveDebugText is a no-op.
    if FindFirstOf then
        local ok, hud = pcall(function() return FindFirstOf("DebugCameraHUD") end)
        if not ok or not is_valid(hud) then
            ok, hud = pcall(function() return FindFirstOf("HUD") end)
        end
        if ok and is_valid(hud) then
            pcall(function() hud:RemoveDebugText(actor, false) end)
        end
    end
    watches[key] = nil
    watch_count = watch_count - 1
    return true, "removed " .. (feature_actor.short_name_of(actor) or "?")
end

function M.list()
    if watch_count == 0 then return true, "no active watches" end
    local lines = {}
    for _, w in pairs(watches) do
        local short = (is_valid(w.actor) and feature_actor.short_name_of(w.actor)) or "<gone>"
        lines[#lines + 1] = string.format("%s expr='%s' last=%s",
            short, w.expr, w.last_text or "?")
    end
    return true, string.format("%d watch(es): %s", #lines, table.concat(lines, " ; "))
end

function M.clear()
    -- Wipe overlay strings on the HUD too so we don't leave stale
    -- one-second labels lingering for a tick.
    if FindFirstOf then
        local ok, hud = pcall(function() return FindFirstOf("DebugCameraHUD") end)
        if not ok or not is_valid(hud) then
            ok, hud = pcall(function() return FindFirstOf("HUD") end)
        end
        if ok and is_valid(hud) then
            for _, w in pairs(watches) do
                if is_valid(w.actor) then
                    pcall(function() hud:RemoveDebugText(w.actor, false) end)
                end
            end
        end
    end
    local n = watch_count
    watches = {}
    watch_count = 0
    return true, string.format("cleared %d watch(es)", n)
end

function M.describe_actor(actor, explicit_expr)
    if not is_valid(actor) then return nil, false, nil, "invalid actor" end
    local expr = explicit_expr
    if not expr or expr == "" then
        local hits = discover_health(actor)
        expr = build_default_expr(actor, hits)
        if not expr then
            return nil, false, nil, "no overlay-able fields auto-detected"
        end
    end
    local text, ok = eval_expr(actor, expr)
    return text, ok, expr, nil
end

return M
