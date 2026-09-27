-- feature_debug_hud.lua
--
-- Read-only exploration of the live HUD instance (typically
-- ADebugCameraHUD or its Dominion subclass) and its inherited AHUD
-- callable surface. Pure research verbs ; nothing here mutates game
-- state. Once we know the real class + UFunction list we'll layer
-- mutating verbs on top in a follow-up pass.
--
-- Verbs:
--   debug.hud.probe
--       -> writes ipc/debug_hud_probe.json with the live HUD's class,
--          super-chain, and a snapshot of well-known AHUD flags.
--   debug.hud.functions
--       -> writes ipc/debug_hud_functions.json with every UFunction
--          declared at each tier of the live HUD's class chain.
--
-- HUD resolution order (each step pcall'd, first valid wins):
--   1. PlayerController.MyHUD          (canonical)
--   2. PlayerController:GetHUD()       (UFunction accessor, if exposed)
--   3. FindFirstOf("DebugCameraHUD")   (matches engine class name)
--   4. FindFirstOf("HUD")              (last-resort base scan)
--
-- We deliberately do NOT call ForEachProperty here ; reading arbitrary
-- HUD properties hits the same crash classes feature_introspect already
-- guards against. The probe sticks to a fixed list of bool flags + the
-- two FName arrays that AHUD documents as the public debug surface.

local M = {}

local feature_actor = require("feature_actor")
local mod_paths     = require("mod_paths")

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function is_valid(o)
    return feature_actor.is_valid_object(o)
end

local function escape_json(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\"):gsub('"', '\\"')
    s = s:gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
    s = s:gsub("[%z\1-\8\11\12\14-\31]", "")
    return s
end

local function jstr(s) return '"' .. escape_json(s) .. '"' end
local function jbool(b) return b and "true" or "false" end

local function safe_fname(obj, getter)
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

local function obj_class(obj)
    if not obj then return nil end
    local ok, cls = pcall(function() return obj:GetClass() end)
    if not ok or not cls then return nil end
    return cls
end

local function obj_class_name(obj)
    local cls = obj_class(obj); if not cls then return "" end
    return safe_fname(cls, "GetFName")
end

local function obj_full_name(obj)
    if not obj then return "" end
    -- GetFullName has AV'd inside native code on a handful of UObjects
    -- in past introspect runs ; we don't strictly need it for the probe
    -- so we just skip it. Class FName is enough to identify the HUD.
    return ""
end

local function resolve_hud()
    -- Order matters: FindFirstOf is the path the user already
    -- confirmed works (their bShowDebugInfo experiment landed on a
    -- DebugCameraHUD instance). pc.MyHUD is a fallback because not
    -- every PlayerController surfaces that field name and a missing
    -- field can AV through UE4SS reflection on certain wrappers.
    if FindFirstOf then
        local ok, hud = pcall(function() return FindFirstOf("DebugCameraHUD") end)
        if ok and is_valid(hud) then return hud, "FindFirstOf(DebugCameraHUD)" end
        ok, hud = pcall(function() return FindFirstOf("HUD") end)
        if ok and is_valid(hud) then return hud, "FindFirstOf(HUD)" end
    end
    local pc = get_pc()
    if is_valid(pc) then
        local ok, hud = pcall(function() return pc.MyHUD end)
        if ok and is_valid(hud) then return hud, "pc.MyHUD" end
        ok, hud = pcall(function() return pc:GetHUD() end)
        if ok and is_valid(hud) then return hud, "pc:GetHUD()" end
    end
    return nil, "no HUD instance found"
end

-- Walk class -> super -> ... -> UObject. Returns array of UStruct
-- userdata, top-most-derived first.
--
-- Termination strategy mirrors feature_introspect.build_class_chain
-- (and the official UE4SS dump_object.lua): GetSuperStruct() at the
-- top of the chain returns an INVALID userdata (not nil), and ANY
-- further vtable call on it (ForEachFunction, GetFName, ...) AVs the
-- game thread. :IsValid() is the only safe probe -- UE4SS implements
-- it on the wrapper without dispatching into the native object.
local function class_chain(cls)
    local chain = {}
    if not cls then return chain end
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

-- ---------------------------------------------------------------------------
-- HUD resolution
-- ---------------------------------------------------------------------------

local function get_pc()
    -- Reuse the same PC discovery feature_skills uses (pawn:GetController()
    -- + pawn.Controller fallback) so probe behaves identically to the
    -- mutating verbs that will land later.
    local pawn = feature_actor.get_local_pawn()
    if not is_valid(pawn) then return nil, "no local pawn" end
    local ok, pc = pcall(function() return pawn:GetController() end)
    if ok and is_valid(pc) then return pc end
    ok, pc = pcall(function() return pawn.Controller end)
    if ok and is_valid(pc) then return pc end
    return nil, "no player controller"
end

-- ---------------------------------------------------------------------------
-- Property snapshot (fixed allow-list)
-- ---------------------------------------------------------------------------

-- AHUD bool flags worth surfacing. Reading a missing field returns nil ;
-- pcall'd so subclass-removed flags don't break the dump.
local FLAG_NAMES = {
    "bShowHUD",
    "bShowDebugInfo",
    "bShowHitBoxDebugInfo",
    "bShowOverlays",
    "bEnableDebugTextShadow",
    "bLostFocusPaused",
}

local function read_flag(hud, name)
    local ok, v = pcall(function() return hud[name] end)
    if not ok then return nil end
    if v == nil then return nil end
    -- UE bitfield uint8:1 surfaces as a number (0/1) under UE4SS.
    if type(v) == "boolean" then return v end
    if type(v) == "number" then return v ~= 0 end
    return nil
end

-- Stringify a TArray<FName>. We probe length via #arr ; if that fails
-- (some UE4SS builds expose only :Num()) we fall back to that. Each
-- element is read with arr[i] then ToString()'d.
local function read_fname_array(hud, field_name)
    local out = {}
    local ok, arr = pcall(function() return hud[field_name] end)
    if not ok or arr == nil then return out end
    local n = 0
    local ok_len, len = pcall(function() return #arr end)
    if ok_len and type(len) == "number" then
        n = len
    else
        local ok_num, num = pcall(function() return arr:Num() end)
        if ok_num and type(num) == "number" then n = num end
    end
    for i = 1, n do
        local ok_e, e = pcall(function() return arr[i] end)
        if ok_e and e ~= nil then
            local s
            local ok_s, v = pcall(function()
                if type(e) == "userdata" and e.ToString then return e:ToString() end
                return tostring(e)
            end)
            if ok_s then s = v end
            if type(s) == "string" and s ~= "" then
                out[#out + 1] = s
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Verb: debug.hud.probe
-- ---------------------------------------------------------------------------

function M.probe()
    local hud, source = resolve_hud()
    if not is_valid(hud) then
        local body = string.format(
            '{"schema":"rsdwtools.debug_hud.probe.v1","found":false,"reason":%s}',
            jstr(source))
        local d = mod_paths.ipc_dir()
        if d then mod_paths.write_atomic(d .. "\\debug_hud_probe.json", body) end
        return false, "no HUD: " .. tostring(source)
    end

    local cls = obj_class(hud)
    local cls_name = cls and safe_fname(cls, "GetFName") or ""
    local full = obj_full_name(hud)

    -- Super chain as a list of class FNames.
    local chain = class_chain(cls)
    local chain_names = {}
    for i, c in ipairs(chain) do
        chain_names[i] = safe_fname(c, "GetFName")
    end

    local parts = {}
    parts[#parts + 1] = '{"schema":"rsdwtools.debug_hud.probe.v1"'
    parts[#parts + 1] = ',"found":true'
    parts[#parts + 1] = ',"source":' .. jstr(source)
    parts[#parts + 1] = ',"class":' .. jstr(cls_name)
    parts[#parts + 1] = ',"full_name":' .. jstr(full)

    parts[#parts + 1] = ',"class_chain":['
    for i, n in ipairs(chain_names) do
        if i > 1 then parts[#parts + 1] = "," end
        parts[#parts + 1] = jstr(n)
    end
    parts[#parts + 1] = "]"

    parts[#parts + 1] = ',"flags":{'
    local first = true
    for _, name in ipairs(FLAG_NAMES) do
        local v = read_flag(hud, name)
        if v ~= nil then
            if not first then parts[#parts + 1] = "," end
            first = false
            parts[#parts + 1] = jstr(name) .. ":" .. jbool(v)
        end
    end
    parts[#parts + 1] = "}"

    local dd = read_fname_array(hud, "DebugDisplay")
    parts[#parts + 1] = ',"debug_display":['
    for i, n in ipairs(dd) do
        if i > 1 then parts[#parts + 1] = "," end
        parts[#parts + 1] = jstr(n)
    end
    parts[#parts + 1] = "]"

    local td = read_fname_array(hud, "ToggledDebugCategories")
    parts[#parts + 1] = ',"toggled_debug_categories":['
    for i, n in ipairs(td) do
        if i > 1 then parts[#parts + 1] = "," end
        parts[#parts + 1] = jstr(n)
    end
    parts[#parts + 1] = "]"

    parts[#parts + 1] = "}"
    local body = table.concat(parts)

    local d = mod_paths.ipc_dir()
    if not d then return false, "ipc_dir unavailable" end
    local ok, err = mod_paths.write_atomic(d .. "\\debug_hud_probe.json", body)
    if not ok then return false, "write failed: " .. tostring(err) end

    return true, string.format("class=%s chain=%d flags=%d display=%d toggled=%d",
        cls_name, #chain_names, #FLAG_NAMES, #dd, #td)
end

-- ---------------------------------------------------------------------------
-- Verb: debug.hud.functions
-- ---------------------------------------------------------------------------
--
-- Walks the live HUD's class chain and emits every UFunction declared
-- on each tier. We use ForEachFunction (the same direct-call pattern
-- feature_introspect uses) ; probing the method via dot-lookup before
-- calling returns nil on UE4SS userdata and silently produces empty
-- output. Function signatures intentionally stay as bare names ;
-- walking a UFunction's parameter list has crashed the game thread on
-- some BP function objects in the past (see introspect notes).

local function collect_functions(struct)
    local out = {}
    if not struct then return out end
    pcall(function()
        struct:ForEachFunction(function(f)
            local name = safe_fname(f, "GetFName")
            if name and name ~= "" then
                out[#out + 1] = name
            end
        end)
    end)
    table.sort(out)
    return out
end

function M.functions()
    local hud, source = resolve_hud()
    if not is_valid(hud) then
        return false, "no HUD: " .. tostring(source)
    end

    local cls = obj_class(hud)
    local cls_name = cls and safe_fname(cls, "GetFName") or ""
    local full = obj_full_name(hud)
    local chain = class_chain(cls)

    local parts = {}
    parts[#parts + 1] = '{"schema":"rsdwtools.debug_hud.functions.v1"'
    parts[#parts + 1] = ',"source":' .. jstr(source)
    parts[#parts + 1] = ',"class":' .. jstr(cls_name)
    parts[#parts + 1] = ',"full_name":' .. jstr(full)
    parts[#parts + 1] = ',"groups":['

    local total = 0
    for i, c in ipairs(chain) do
        if i > 1 then parts[#parts + 1] = "," end
        local gname = safe_fname(c, "GetFName")
        local fns = collect_functions(c)
        total = total + #fns
        parts[#parts + 1] = '{"class":' .. jstr(gname) .. ',"count":' .. tostring(#fns) .. ',"functions":['
        for j, fn in ipairs(fns) do
            if j > 1 then parts[#parts + 1] = "," end
            parts[#parts + 1] = jstr(fn)
        end
        parts[#parts + 1] = "]}"
    end

    parts[#parts + 1] = "]}"
    local body = table.concat(parts)

    local d = mod_paths.ipc_dir()
    if not d then return false, "ipc_dir unavailable" end
    local ok, err = mod_paths.write_atomic(d .. "\\debug_hud_functions.json", body)
    if not ok then return false, "write failed: " .. tostring(err) end

    return true, string.format("class=%s tiers=%d functions=%d",
        cls_name, #chain, total)
end

-- ---------------------------------------------------------------------------
-- Verb: debug.hud.draw.probe [seconds]
-- ---------------------------------------------------------------------------
--
-- One-shot research probe. Hooks /Script/Engine.HUD:ReceiveDrawHUD for
-- N seconds (default 3) and records:
--   * how many times the hook fired
--   * whether hud.Canvas was valid inside the hook
--   * canvas SizeX/SizeY on first fire
--   * per-primitive draw attempt result (DrawText / DrawRect / DrawLine)
--   * Project() result for the local pawn's world location
--
-- Why a hook? AHUD::DrawText et al only work when called from inside
-- the postrender window. Outside that window hud.Canvas is null and
-- the calls either no-op or crash. ReceiveDrawHUD is the documented
-- BlueprintImplementableEvent that fires inside that window ; if the
-- live BP_HUD_MainHUD_C overrides it, our hook will catch every fire
-- and we can run draw code with a valid canvas.
--
-- If fired_count stays 0 the BP doesn't implement ReceiveDrawHUD and
-- we'll need Plan B (hook DrawHUD instead) or Plan C (AddDebugText
-- only).
--
-- Output: ipc/debug_hud_draw_probe.json. The verb returns immediately
-- after registering ; results are flushed to disk by a LoopAsync timer
-- when the deadline expires. The router ack just confirms registration.

-- Module-level handle so a second probe call replaces the first
-- cleanly. Single-slot ; multiple concurrent probes are not supported.
M._draw_probe = nil

local function color_red()    return { R = 1.0, G = 0.0, B = 0.0, A = 1.0 } end
local function color_green()  return { R = 0.0, G = 1.0, B = 0.0, A = 1.0 } end
local function color_blue()   return { R = 0.0, G = 0.4, B = 1.0, A = 1.0 } end

-- Pcall a single draw call, recording {ok, err} for the JSON dump. We
-- only attempt each primitive ONCE (on first hook fire) to keep cost
-- bounded ; if a primitive crashes the game thread we want it to crash
-- on the first frame so the user sees the failure mode immediately.
local function attempt_draw(state, hud, key, fn)
    if state.attempts[key] then return end
    state.attempts[key] = { ok = false, err = "" }
    local ok, err = pcall(fn, hud)
    state.attempts[key].ok  = ok and true or false
    state.attempts[key].err = ok and "" or tostring(err or "")
end

local function flush_probe_json(state)
    local parts = {}
    parts[#parts + 1] = '{"schema":"rsdwtools.debug_hud.draw_probe.v1"'
    parts[#parts + 1] = ',"hook_path":' .. jstr(state.hook_path)
    parts[#parts + 1] = ',"hook_registered":' .. jbool(state.registered)
    parts[#parts + 1] = ',"register_error":' .. jstr(state.register_error or "")
    parts[#parts + 1] = ',"duration_seconds":' .. tostring(state.seconds)
    parts[#parts + 1] = ',"fired_count":' .. tostring(state.fired_count)
    parts[#parts + 1] = ',"canvas_valid_count":' .. tostring(state.canvas_valid_count)
    parts[#parts + 1] = ',"first_canvas_size_x":' .. tostring(state.canvas_size_x or 0)
    parts[#parts + 1] = ',"first_canvas_size_y":' .. tostring(state.canvas_size_y or 0)

    parts[#parts + 1] = ',"attempts":{'
    local first = true
    for k, v in pairs(state.attempts) do
        if not first then parts[#parts + 1] = "," end
        first = false
        parts[#parts + 1] = jstr(k) .. ':{"ok":' .. jbool(v.ok) .. ',"err":' .. jstr(v.err) .. '}'
    end
    parts[#parts + 1] = "}"

    parts[#parts + 1] = ',"project":{"ok":' .. jbool(state.project_ok or false)
    parts[#parts + 1] = ',"x":' .. tostring(state.project_x or 0)
    parts[#parts + 1] = ',"y":' .. tostring(state.project_y or 0)
    parts[#parts + 1] = ',"z":' .. tostring(state.project_z or 0)
    parts[#parts + 1] = ',"err":' .. jstr(state.project_err or "") .. "}"

    parts[#parts + 1] = "}"
    local body = table.concat(parts)
    local d = mod_paths.ipc_dir()
    if not d then return end
    pcall(function() mod_paths.write_atomic(d .. "\\debug_hud_draw_probe.json", body) end)
end

local function unregister_probe(state)
    if not state then return end
    if state.unregistered then return end
    state.unregistered = true
    if UnregisterHook and state.hook_path and (state.pre_id or state.post_id) then
        pcall(function() UnregisterHook(state.hook_path, state.pre_id or 0, state.post_id or 0) end)
    end
end

function M.draw_probe(arg)
    -- Replace any prior in-flight probe ; flush its partial state first
    -- so we don't lose it.
    if M._draw_probe and not M._draw_probe.unregistered then
        unregister_probe(M._draw_probe)
        flush_probe_json(M._draw_probe)
    end

    local seconds = tonumber((arg or ""):match("(%d+%.?%d*)")) or 3
    if seconds < 1 then seconds = 1 end
    if seconds > 30 then seconds = 30 end

    local hud, src = resolve_hud()
    if not is_valid(hud) then
        return false, "no HUD: " .. tostring(src)
    end

    -- Cache the local pawn location once (for the Project() test). If
    -- it fails here we still run the hook ; the project block just
    -- won't have meaningful numbers.
    local pawn_loc = nil
    pcall(function()
        local pawn = feature_actor.get_local_pawn()
        if is_valid(pawn) and pawn.K2_GetActorLocation then
            pawn_loc = pawn:K2_GetActorLocation()
        end
    end)

    local state = {
        hook_path           = "/Script/Engine.HUD:ReceiveDrawHUD",
        registered          = false,
        register_error      = "",
        seconds             = seconds,
        fired_count         = 0,
        canvas_valid_count  = 0,
        canvas_size_x       = nil,
        canvas_size_y       = nil,
        attempts            = {},
        project_ok          = false,
        project_x           = 0,
        project_y           = 0,
        project_z           = 0,
        project_err         = "",
        pre_id              = nil,
        post_id             = nil,
        unregistered        = false,
        hud_source          = src,
        hud_class           = obj_class_name(hud),
    }
    M._draw_probe = state

    if not RegisterHook then
        state.register_error = "RegisterHook global missing"
        flush_probe_json(state)
        return false, "RegisterHook unavailable"
    end

    -- Hook callback. UE4SS modern signature: function(Context, ...) where
    -- the additional args are the BP function params. We don't actually
    -- need those ; we use the captured `hud` userdata for draw calls
    -- because Canvas state is per-HUD and valid throughout postrender.
    local function on_receive_draw_hud(_context, _sx, _sy)
        if state.unregistered then return end
        state.fired_count = state.fired_count + 1

        -- Canvas validity check.
        local canvas_ok = false
        local canvas_obj = nil
        pcall(function()
            canvas_obj = hud.Canvas
            if is_valid(canvas_obj) then canvas_ok = true end
        end)
        if canvas_ok then
            state.canvas_valid_count = state.canvas_valid_count + 1
            if not state.canvas_size_x then
                pcall(function()
                    state.canvas_size_x = canvas_obj.SizeX or canvas_obj.ClipX or 0
                    state.canvas_size_y = canvas_obj.SizeY or canvas_obj.ClipY or 0
                end)
            end
        end

        -- Run draw attempts only on the first fire ; once a primitive
        -- has been categorized ok/err we don't need to redo it. Keeps
        -- per-frame cost bounded.
        attempt_draw(state, hud, "DrawText", function(h)
            h:DrawText("RSDW probe", color_red(), 100.0, 100.0, nil, 1.0, false)
        end)
        attempt_draw(state, hud, "DrawRect", function(h)
            h:DrawRect(color_green(), 90.0, 90.0, 200.0, 30.0)
        end)
        attempt_draw(state, hud, "DrawLine", function(h)
            h:DrawLine(0.0, 0.0, 500.0, 500.0, color_blue(), 2.0)
        end)

        -- Project() test ; only attempt once and only if we cached a
        -- pawn location at register time.
        if not state.project_attempted and pawn_loc then
            state.project_attempted = true
            local ok, v = pcall(function()
                return hud:Project(pawn_loc, false)
            end)
            if ok and v then
                state.project_ok = true
                pcall(function()
                    state.project_x = v.X or 0
                    state.project_y = v.Y or 0
                    state.project_z = v.Z or 0
                end)
            else
                state.project_err = tostring(v or "no result")
            end
        end
    end

    local ok_reg, pre_id, post_id = pcall(function()
        return RegisterHook(state.hook_path, on_receive_draw_hud)
    end)
    if not ok_reg then
        state.register_error = tostring(pre_id or "register failed")
        flush_probe_json(state)
        return false, "register failed: " .. state.register_error
    end
    state.registered = true
    state.pre_id  = pre_id
    state.post_id = post_id

    -- Schedule the unregister + flush. LoopAsync runs callbacks on the
    -- game thread, so unregistering inside it is safe.
    local deadline_ms = math.floor(seconds * 1000)
    if LoopAsync then
        local elapsed = 0
        local tick_ms = 200
        LoopAsync(tick_ms, function()
            if state.unregistered then return true end
            elapsed = elapsed + tick_ms
            if elapsed >= deadline_ms then
                unregister_probe(state)
                flush_probe_json(state)
                return true   -- stop loop
            end
            return false
        end)
    else
        -- No LoopAsync: best-effort, flush now (won't capture any frames).
        unregister_probe(state)
        flush_probe_json(state)
    end

    return true, string.format("hooked %s seconds=%d hud=%s",
        state.hook_path, seconds, state.hud_class)
end

-- ===========================================================================
-- Mutating verbs (Path 1: AddDebugText overlays + Path 2: ShowDebug family)
-- ===========================================================================
--
-- These all run on the live HUD instance returned by resolve_hud(). The
-- HUD is re-resolved on every verb call ; HUD references can churn on
-- level/PIE transitions and a captured reference would silently start
-- targeting a stale object.
--
-- Notes on UE4SS arg passing:
--   * FName parameters: pass a Lua string ; UE4SS auto-converts.
--   * FVector / FColor / FLinearColor: pass a Lua table with the
--     matching field names (X/Y/Z, R/G/B/A). Floats default to 0,
--     bools default to false ; we still pass them explicitly so the
--     UFunction signature lookup matches exactly.
--   * uint8:1 bitfields (bShowHUD etc): assign 0 or 1 to the field.
--     Lua booleans don't auto-convert through UE4SS for bitfields.

local function trim(s) return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", "")) end

local function split_words(s)
    local out = {}
    for tok in tostring(s or ""):gmatch("%S+") do out[#out + 1] = tok end
    return out
end

-- Parse "r,g,b" or "r,g,b,a" into FColor table (0..255 ints). Returns
-- nil if the input doesn't look like a color spec ; caller falls back
-- to a default.
local function parse_color(s)
    if not s or s == "" then return nil end
    local r, g, b, a = s:match("^(%d+),(%d+),(%d+),(%d+)$")
    if not r then r, g, b = s:match("^(%d+),(%d+),(%d+)$") end
    if not r then return nil end
    local function clamp(v) v = tonumber(v) or 0; if v < 0 then v = 0 end; if v > 255 then v = 255 end; return math.floor(v) end
    return { R = clamp(r), G = clamp(g), B = clamp(b), A = a and clamp(a) or 255 }
end

local function default_color() return { R = 255, G = 255, B = 0, A = 255 } end
local function zero_vector()   return { X = 0.0, Y = 0.0, Z = 0.0 } end

-- Coerce on/off/1/0/true/false to boolean. Returns nil on garbage.
local function parse_onoff(s)
    if s == nil then return nil end
    local m = tostring(s):lower()
    if m == "on" or m == "1" or m == "true"  then return true  end
    if m == "off"or m == "0" or m == "false" then return false end
    return nil
end

-- ---------------------------------------------------------------------------
-- Path 2: ShowDebug family
-- ---------------------------------------------------------------------------

-- debug.hud.flag <name> <on|off>
--
-- Writes the named uint8:1 bitfield on the HUD. We restrict to a small
-- allow-list so a typo can't write to an arbitrary HUD property.
local FLAG_WRITE_ALLOW = {
    bShowHUD              = true,
    bShowDebugInfo        = true,
    bShowHitBoxDebugInfo  = true,
    bShowOverlays         = true,
    bEnableDebugTextShadow = true,
}

function M.flag(arg)
    local words = split_words(arg)
    local name, mode = words[1], words[2]
    if not name or not mode then
        return false, "usage: debug.hud.flag <name> <on|off>"
    end
    if not FLAG_WRITE_ALLOW[name] then
        return false, "unknown flag (allowed: bShowHUD, bShowDebugInfo, bShowHitBoxDebugInfo, bShowOverlays, bEnableDebugTextShadow)"
    end
    local v = parse_onoff(mode)
    if v == nil then return false, "mode must be on|off" end

    local hud, src = resolve_hud()
    if not is_valid(hud) then return false, "no HUD: " .. tostring(src) end

    local ok, err = pcall(function() hud[name] = v and 1 or 0 end)
    if not ok then return false, "write failed: " .. tostring(err) end
    return true, string.format("%s=%s", name, v and "on" or "off")
end

-- debug.hud.show.reset
--
-- Convenience wrapper for ShowDebug("Reset") which clears DebugDisplay
-- AND drops bShowDebugInfo back to false. Use this to recover from a
-- bad category set without restarting the game.
function M.show_reset()
    local hud, src = resolve_hud()
    if not is_valid(hud) then return false, "no HUD: " .. tostring(src) end
    local ok_fn, fname = pcall(function() return FName("Reset") end)
    if not ok_fn or fname == nil then return false, "FName ctor failed for Reset" end
    local ok, err = pcall(function() hud:ShowDebug(fname) end)
    if not ok then return false, "ShowDebug(Reset) failed: " .. tostring(err) end
    local dd = read_fname_array(hud, "DebugDisplay")
    local on = read_flag(hud, "bShowDebugInfo")
    return true, string.format("reset ; bShowDebugInfo=%s display=[%s]",
        tostring(on), table.concat(dd, ","))
end

-- debug.hud.show <category>
--
-- Calls AHUD::ShowDebug(FName). UE's design is toggle-only: calling
-- with the same name twice turns it back off. Passing "Reset" clears
-- DebugDisplay and disables bShowDebugInfo.
function M.show(arg)
    local body = trim(arg)
    if body == "" then
        return false, "usage: debug.hud.show <category>  (Game|AI|Animation|Physics|Net|Camera|Weapon|Collision|Bones|Reset|...)"
    end
    local words = split_words(body)
    local cat = words[1]

    local hud, src = resolve_hud()
    if not is_valid(hud) then return false, "no HUD: " .. tostring(src) end

    -- Earlier crash was the FName marshaling bug, not category dispatch.
    -- Now that we wrap with FName() the toggle path is safe -- the
    -- engine itself simply skips DisplayDebug for categories whose
    -- target deref would null. Leaving the obsolete pre-toggle guard
    -- in place was just blocking valid calls. The flag-write side
    -- still guards bShowDebugInfo because that's the actual frame-dispatcher.

    -- UE4SS marshals UFunction params strictly ; passing a raw Lua
    -- string where the signature wants FName will write garbage into
    -- the param frame and AV the native impl before it runs (verified:
    -- even ShowDebug("Reset") crashed). Always wrap with FName().
    local ok_fn, fname = pcall(function() return FName(cat) end)
    if not ok_fn or fname == nil then return false, "FName ctor failed for " .. tostring(cat) end

    local ok, err = pcall(function() hud:ShowDebug(fname) end)
    if not ok then return false, "ShowDebug failed: " .. tostring(err) end

    -- Read-back so the ack reflects the new state. Empty array == off.
    local active = read_fname_array(hud, "DebugDisplay")
    return true, string.format("toggled %s ; active=[%s]", cat, table.concat(active, ","))
end

-- debug.hud.show.sub <subcategory>
function M.show_sub(arg)
    local sub = trim(arg)
    if sub == "" then
        return false, "usage: debug.hud.show.sub <subcategory>"
    end
    local hud, src = resolve_hud()
    if not is_valid(hud) then return false, "no HUD: " .. tostring(src) end

    local ok_fn, fname = pcall(function() return FName(sub) end)
    if not ok_fn or fname == nil then return false, "FName ctor failed for " .. tostring(sub) end
    local ok, err = pcall(function() hud:ShowDebugToggleSubCategory(fname) end)
    if not ok then return false, "ShowDebugToggleSubCategory failed: " .. tostring(err) end
    return true, "toggled sub=" .. sub
end

-- debug.hud.show.list
--
-- Read-only ; returns the current DebugDisplay + ToggledDebugCategories
-- + bShowDebugInfo state in the ack body so the user can see it
-- without polling the JSON.
function M.show_list()
    local hud, src = resolve_hud()
    if not is_valid(hud) then return false, "no HUD: " .. tostring(src) end
    local dd = read_fname_array(hud, "DebugDisplay")
    local td = read_fname_array(hud, "ToggledDebugCategories")
    local on = read_flag(hud, "bShowDebugInfo")
    return true, string.format("bShowDebugInfo=%s display=[%s] sub=[%s]",
        tostring(on), table.concat(dd, ","), table.concat(td, ","))
end

-- debug.hud.show.cats
--
-- Returns the canonical UE5 category list as a hint. There's no UFunction
-- exposing AHUD::DebugDisplayNames so this is a static reference list ;
-- toggle each one in turn to discover what your build actually wires up.
local CANONICAL_CATEGORIES = {
    "Reset", "Game", "AI", "Animation", "Bones", "Camera",
    "Collision", "ForceFeedback", "Input", "Net", "Physics",
    "Slate", "Weapon", "Reverb", "Audio", "Particles", "Niagara",
}
function M.show_cats()
    return true, "categories: " .. table.concat(CANONICAL_CATEGORIES, ",")
end

function M.target_next()
    local hud, src = resolve_hud()
    if not is_valid(hud) then return false, "no HUD: " .. tostring(src) end
    local ok, err = pcall(function() hud:NextDebugTarget() end)
    if not ok then return false, "NextDebugTarget failed: " .. tostring(err) end
    return true, "next"
end

function M.target_prev()
    local hud, src = resolve_hud()
    if not is_valid(hud) then return false, "no HUD: " .. tostring(src) end
    local ok, err = pcall(function() hud:PreviousDebugTarget() end)
    if not ok then return false, "PreviousDebugTarget failed: " .. tostring(err) end
    return true, "prev"
end

-- ---------------------------------------------------------------------------
-- Path 1: AddDebugText overlays (persistent text-on-actors)
-- ---------------------------------------------------------------------------

-- debug.draw.label <actor-name> <text...> [#dur=<sec>] [#color=r,g,b[,a]]
--
-- Body grammar: first whitespace-delimited token is the actor short
-- name, the rest is the label text up to optional `#dur=` / `#color=`
-- markers. We use `#` because it's not a Lua-pattern metachar we'd
-- accidentally match on, and because labels frequently contain
-- punctuation we don't want to reserve.
--
-- Examples:
--   debug.draw.label Goblin "HP: 12/30"
--   debug.draw.label Tree health #dur=20 #color=0,255,0
local function parse_label_args(arg)
    -- Pull #dur / #color first, strip from string, then split.
    local dur, color
    local stripped = arg
    stripped = stripped:gsub("%s*#dur=([%d%.]+)", function(v) dur = tonumber(v); return "" end)
    stripped = stripped:gsub("%s*#color=([%d,]+)", function(v) color = parse_color(v); return "" end)
    stripped = trim(stripped)

    local sp = stripped:find("%s")
    if not sp then
        return stripped, nil, dur, color
    end
    local name = stripped:sub(1, sp - 1)
    local text = trim(stripped:sub(sp + 1))
    return name, text, dur, color
end

function M.draw_label(arg)
    local name, text, dur, color = parse_label_args(arg or "")
    if not name or name == "" or not text or text == "" then
        return false, "usage: debug.draw.label <actor-name> <text> [#dur=<sec>] [#color=r,g,b[,a]]"
    end
    dur   = dur or 30.0
    color = color or default_color()

    local actor = feature_actor.resolve_actor_by_name(name)
    if not is_valid(actor) then return false, "actor not found: " .. name end

    local hud, src = resolve_hud()
    if not is_valid(hud) then return false, "no HUD: " .. tostring(src) end

    -- AHUD::AddDebugText signature (12 params). We pass nil for InFont
    -- so the HUD's default font is used. bKeepAttachedToActor=true so
    -- the text follows the actor through its remaining lifetime.
    local ok, err = pcall(function()
        hud:AddDebugText(
            text,                       -- FString DebugText
            actor,                      -- AActor* SrcActor
            dur,                        -- float Duration (0 == infinite per UE convention; we use a real value)
            zero_vector(),              -- FVector Offset
            zero_vector(),              -- FVector DesiredOffset
            color,                      -- FColor TextColor
            false,                      -- bSkipOverwriteCheck
            false,                      -- bAbsoluteLocation
            true,                       -- bKeepAttachedToActor
            nil,                        -- UFont* InFont (nil == HUD default)
            1.0,                        -- float FontScale
            true                        -- bDrawShadow
        )
    end)
    if not ok then return false, "AddDebugText failed: " .. tostring(err) end

    return true, string.format("labeled %s dur=%g color=%d,%d,%d",
        name, dur, color.R, color.G, color.B)
end

-- debug.draw.label.clear [actor-name]
--   No arg -> RemoveAllDebugStrings (wipes everything)
--   With arg -> RemoveDebugText(actor, false) wipes that actor's
--               labels only (the bool keeps no-duration entries when
--               true ; we pass false for full clear).
function M.draw_label_clear(arg)
    local hud, src = resolve_hud()
    if not is_valid(hud) then return false, "no HUD: " .. tostring(src) end

    local name = trim(arg or "")
    if name == "" then
        local ok, err = pcall(function() hud:RemoveAllDebugStrings() end)
        if not ok then return false, "RemoveAllDebugStrings failed: " .. tostring(err) end
        return true, "cleared all"
    end

    local actor = feature_actor.resolve_actor_by_name(name)
    if not is_valid(actor) then return false, "actor not found: " .. name end
    local ok, err = pcall(function() hud:RemoveDebugText(actor, false) end)
    if not ok then return false, "RemoveDebugText failed: " .. tostring(err) end
    return true, "cleared " .. name
end

return M
