-- feature_wheel_hook.lua
--
-- Round 62: mouse-wheel hotkey support.
-- Round 65: also route mouse button hotkeys through the same polling path.
--
-- DESIGN ROUND 2 -- the original RegisterHook approach failed because
-- /Script/Engine.PlayerController:InputAxis is a native C++ function,
-- not a UFunction, so UE4SS rejects the hook with "no UFunction with
-- the specified name was found".
--
-- This rewrite uses per-tick polling instead. UE itself surfaces
-- mouse-wheel notches as DISCRETE key events (EKeys::MouseScrollUp /
-- MouseScrollDown), which means PlayerController:WasInputKeyJustPressed
-- returns true on the frame the wheel notched. That UFunction IS
-- exposed (verified in the object dump), and so is IsInputKeyDown
-- which we use for modifier matching.
--
-- Cost: a LoopAsync callback at ~16ms calling two UFunctions per tick
-- (one for up, one for down) plus zero-to-three IsInputKeyDown calls
-- per fire. Well under 0.1% CPU. The loop is gated -- it only runs
-- when at least one wheel binding is registered, so unmodified mods
-- pay nothing.
--
-- Key construction: FKey is a USTRUCT { FName KeyName }, so UE4SS
-- accepts a Lua table { KeyName = FName("MouseScrollUp") } as a
-- direct argument. We build these once at registration time and reuse
-- them across every tick.
--
-- Reload safety: a generation counter keeps stale callbacks from
-- prior reloads no-oping. The poll loop itself is started once and
-- runs forever ; on reload we clear the registry and bump generation,
-- the loop body sees an empty registry and skips dispatch.

local M = {}

-- token -> array of { mod_fkeys = {fkey...}, fn = function }
M._cbs = { up = {}, down = {}, left_mouse = {}, right_mouse = {}, middle_mouse = {} }
M._pressed_latch = { left_mouse = false, right_mouse = false, middle_mouse = false }
M._generation = 0
M._loop_started = false
M._driver = nil
M._deferred_active = false

local POLL_ORDER = { "up", "down", "left_mouse", "right_mouse", "middle_mouse" }
local MOUSE_TOKENS = { left_mouse = true, right_mouse = true, middle_mouse = true }
local POLLED_KEY_NAMES = {
    up = "MouseScrollUp",
    down = "MouseScrollDown",
    left_mouse = "LeftMouseButton",
    right_mouse = "RightMouseButton",
    middle_mouse = "MiddleMouseButton",
}
local TOKEN_ALIASES = {
    WHEEL_UP = "up",
    WHEEL_DOWN = "down",
    LEFT_MOUSE_BUTTON = "left_mouse",
    RIGHT_MOUSE_BUTTON = "right_mouse",
    MIDDLE_MOUSE_BUTTON = "middle_mouse",
}

local function normalize_token(token)
    return TOKEN_ALIASES[token] or token
end

-- FName-based UE key lookup. EKeys::MouseScrollUp / MouseScrollDown
-- are the discrete press events that fire once per wheel notch. The
-- modifier names mirror UE's FKey identifiers (LeftControl etc), NOT
-- the VK-based "LEFT_CONTROL" tokens used by RegisterKeyBindAsync.
local _fkey_cache = {}
local function fkey(name)
    local cached = _fkey_cache[name]
    if cached then return cached end
    if not FName then return nil end
    local ok, fn = pcall(function() return FName(name) end)
    if not ok or not fn then return nil end
    local k = { KeyName = fn }
    _fkey_cache[name] = k
    return k
end

-- Modifier-name translation: the picker stores VK-style names
-- (LEFT_CONTROL etc) so existing keyboard bindings stay compatible.
-- For the wheel path we need UE FKey identifiers instead.
local VK_TO_UE_MOD = {
    LEFT_CONTROL  = "LeftControl",
    RIGHT_CONTROL = "RightControl",
    LEFT_SHIFT    = "LeftShift",
    RIGHT_SHIFT   = "RightShift",
    LEFT_ALT      = "LeftAlt",
    RIGHT_ALT     = "RightAlt",
}

local UE_MOD_NAMES = { "LeftControl", "RightControl", "LeftShift", "RightShift", "LeftAlt", "RightAlt" }

local function modifier_fkey_for_token(vk_name)
    local ue_name = VK_TO_UE_MOD[vk_name]
    if not ue_name then return nil end
    return fkey(ue_name)
end

-- Get the local PlayerController. Delegated to feature_net for the
-- canonical multiplayer-correct resolver (IsLocalController()-based).
local feature_net = require("feature_net")
local function get_pc()
    local ok, pc = pcall(function() return feature_net.local_controller() end)
    if ok then return pc end
    print("[RSDWTools.wheel] local controller lookup failed: " .. tostring(pc))
    return nil
end

local function modifier_down(pc, ue_name)
    if not pc or not pc.IsInputKeyDown then return false end
    local fk = fkey(ue_name)
    if not fk then return false end
    local ok, held = pcall(function() return pc:IsInputKeyDown(fk) end)
    return ok and held == true
end

local function modifiers_exact(pc, entry)
    local mod_fkeys = entry.mod_fkeys or {}
    local mod_set = entry.mod_set or {}
    if not pc or not pc.IsInputKeyDown then return false end
    for _, fk in ipairs(mod_fkeys) do
        local ok, held = pcall(function() return pc:IsInputKeyDown(fk) end)
        if not ok or not held then return false end
    end
    for _, ue_name in ipairs(UE_MOD_NAMES) do
        if not mod_set[ue_name] and modifier_down(pc, ue_name) then return false end
    end
    return true
end

local function entry_enabled(entry)
    if entry.gen ~= M._generation then return false end
    if entry.deferred == true and M._deferred_active ~= true then return false end
    if entry.can_poll and not entry.can_poll() then return false end
    return true
end

local function dispatch(pc, list)
    for _, entry in ipairs(list) do
        if entry_enabled(entry) and modifiers_exact(pc, entry) then
            local ok, err = pcall(entry.fn)
            if not ok then
                print("[RSDWTools.wheel] callback error: " .. tostring(err))
            end
        end
    end
end

local _poll_key_cache = {}

local function poll_key(token)
    local cached = _poll_key_cache[token]
    if cached then return cached end
    local key_name = POLLED_KEY_NAMES[token]
    if not key_name then return nil end
    local fk = fkey(key_name)
    _poll_key_cache[token] = fk
    return fk
end

local function has_enabled_entry(list)
    for _, entry in ipairs(list) do
        if entry_enabled(entry) then return true end
    end
    return false
end

local function has_bindings()
    for _, token in ipairs(POLL_ORDER) do
        if has_enabled_entry(M._cbs[token]) then return true end
    end
    return false
end

local function update_press_latch(pc, token, key)
    if not MOUSE_TOKENS[token] then return end
    if not pc or not pc.IsInputKeyDown then return end
    local ok, down = pcall(function() return pc:IsInputKeyDown(key) end)
    if ok and down ~= true then
        M._pressed_latch[token] = false
    end
end

local function should_dispatch_press(token)
    if not MOUSE_TOKENS[token] then return true end
    if M._pressed_latch[token] then return false end
    M._pressed_latch[token] = true
    return true
end

local function tick()
    if not has_bindings() then
        return -- registry empty ; cheapest possible path
    end
    local pc = get_pc()
    if not pc or not pc.WasInputKeyJustPressed then return end
    for _, token in ipairs(POLL_ORDER) do
        local list = M._cbs[token]
        if has_enabled_entry(list) then
            local key = poll_key(token)
            if key then
                update_press_latch(pc, token, key)
                local ok, pressed = pcall(function() return pc:WasInputKeyJustPressed(key) end)
                if ok and pressed and should_dispatch_press(token) then dispatch(pc, list) end
            end
        end
    end
end

local POLL_MS = 4   -- ~250Hz. WasInputKeyJustPressed is true for
                    -- exactly one game frame, so a 16ms async poll
                    -- can sample BETWEEN game frames and miss
                    -- notches entirely. 4ms gives 4-8 sample
                    -- opportunities per game frame at typical
                    -- 60-144fps so every notch is caught. Cost is
                    -- still trivial: ~2 UFunction calls per tick on
                    -- a non-render thread.

local function ensure_loop()
    if M._loop_started then return end
    if EngineTickAvailable == true and type(LoopInGameThreadAfterFrames) == "function" then
        local ok, handle_or_err = pcall(function()
            return LoopInGameThreadAfterFrames(1, function()
                local ok_tick, err = pcall(tick)
                if not ok_tick then
                    print("[RSDWTools.wheel] engine tick failed: " .. tostring(err))
                end
            end)
        end)
        if ok and handle_or_err then
            M._loop_started = true
            M._driver = "engine_tick"
            print("[RSDWTools.wheel] poll loop started on engine tick.")
            return
        end
        print("[RSDWTools.wheel] engine tick unavailable: " .. tostring(handle_or_err))
    end
    if not LoopAsync then
        print("[RSDWTools.wheel] LoopAsync unavailable -- wheel bindings disabled.")
        return
    end
    M._loop_started = true
    M._driver = "loop_async"
    LoopAsync(POLL_MS, function()
        tick()
        return false  -- never exit
    end)
    print(string.format("[RSDWTools.wheel] wheel poll loop ~%dms started.", POLL_MS))
end

-- Public API -------------------------------------------------------------

function M.bump_generation()
    M._generation = M._generation + 1
    for _, token in ipairs(POLL_ORDER) do M._cbs[token] = {} end
    for token, _ in pairs(MOUSE_TOKENS) do M._pressed_latch[token] = false end
end

function M.set_oculus_active(active)
    M._deferred_active = active == true
    for token, _ in pairs(MOUSE_TOKENS) do M._pressed_latch[token] = false end
    if M._deferred_active and has_bindings() then ensure_loop() end
    return true, "oculus_poll=" .. tostring(M._deferred_active)
end

-- direction:    "up", "down", WHEEL_*, or *_MOUSE_BUTTON
-- mod_tokens:   array of VK-style modifier names ("LEFT_CONTROL" etc)
-- callback:     zero-arg function fired on each matching wheel notch
-- can_poll:     optional zero-arg predicate checked before polling the key
local function register_internal(direction, mod_tokens, callback, can_poll, deferred)
    direction = normalize_token(direction)
    if not POLLED_KEY_NAMES[direction] then return end
    if type(callback) ~= "function" then return end
    -- Translate VK-style modifier tokens to UE FKey structs once at
    -- register time. Unknown tokens are silently skipped (defensive ;
    -- the picker only emits the six we recognize).
    local mod_fkeys = {}
    local mod_set = {}
    if type(mod_tokens) == "table" then
        for _, name in ipairs(mod_tokens) do
            local fk = modifier_fkey_for_token(name)
            local ue_name = VK_TO_UE_MOD[name]
            if fk and ue_name and not mod_set[ue_name] then
                mod_fkeys[#mod_fkeys + 1] = fk
                mod_set[ue_name] = true
            end
        end
    end
    table.insert(M._cbs[direction], {
        mod_fkeys = mod_fkeys,
        mod_set   = mod_set,
        fn        = callback,
        can_poll  = type(can_poll) == "function" and can_poll or nil,
        gen       = M._generation,
        deferred  = deferred == true,
    })
    if deferred == true then
        if M._deferred_active then ensure_loop() end
    else
        ensure_loop()
    end
end

function M.register(direction, mod_tokens, callback, can_poll)
    register_internal(direction, mod_tokens, callback, can_poll, false)
end

function M.register_deferred(direction, mod_tokens, callback, can_poll)
    register_internal(direction, mod_tokens, callback, can_poll, true)
end

function M.binding_count()
    local count = 0
    for _, token in ipairs(POLL_ORDER) do count = count + #M._cbs[token] end
    return count
end

function M.status()
    return true, string.format("driver=%s bindings=%d generation=%d oculus_poll=%s",
        tostring(M._driver or "none"),
        M.binding_count(),
        tonumber(M._generation) or 0,
        tostring(M._deferred_active == true))
end

return M
