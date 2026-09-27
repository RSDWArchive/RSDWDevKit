-- Transient on-screen toast (Round 51 redesign).
--
-- Old behavior: persistent overlay toggled with Insert that surfaced a
-- "RSDWTools - Player" header. It looked like a debug HUD and didn't do
-- anything useful for the player.
--
-- New behavior: fire-and-forget toast triggered by mod rows. A row of
-- kind "umg" carries (text, duration) ; firing it shows the text on
-- screen for the requested seconds and then auto-hides. Re-firing while
-- a toast is up replaces the text and resets the timer (last-write
-- wins). No input is captured, no key polling, no debounce -- the mod
-- engine + the user's hotkey decide when to fire.

local M = {}

local widget_canvas = nil
local root_border = nil
local toast_text = nil
local oculus_help_canvas = nil
local oculus_help_border = nil
local oculus_help_text = nil
local oculus_help_mode_border = nil
local oculus_help_mode_text = nil
local oculus_rotation_canvas = nil
local oculus_rotation_top_border = nil
local oculus_rotation_top_text = nil
local oculus_rotation_mode_border = nil
local oculus_rotation_mode_text = nil
local editor_gizmo_canvas = nil
local editor_gizmo_handles = {}
local toast_generation = 0           -- bumped on every show ; auto-hide checks it
local oculus_rotation_generation = 0 -- bumped on every modal overlay update
local editor_gizmo_generation = 0    -- bumped on every editor gizmo overlay update
local Visibility_HIDDEN = 2
local Visibility_SELF_HIT_TEST_INVISIBLE = 4

local function is_valid(obj)
    if type(obj) ~= "userdata" then return false end
    local ok_method, method = pcall(function() return obj.IsValid end)
    if not ok_method or not method then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

local function FLinearColor(r, g, b, a)
    return { R = r, G = g, B = b, A = a }
end

local function FSlateColor(r, g, b, a)
    return { SpecifiedColor = FLinearColor(r, g, b, a), ColorUseRule = 0 }
end

local function oculus_overlay_palette(kind)
    -- Keep the Oculus status strip deliberately boring: one stable color,
    -- one text write. The mode-specific controls live in the help panel.
    return {
        top_bg = FLinearColor(0.0, 0.0, 0.0, 0.62),
        mode_bg = FLinearColor(0.0, 0.0, 0.0, 0.62),
        text = FSlateColor(0.92, 0.95, 1.0, 1.0),
    }
end

local function simple_oculus_mode_text(message, palette)
    local line = tostring(message or ""):match("^[^\r\n]+") or ""
    local lower = line:lower()
    if lower:find("grab mode", 1, true) or tostring(palette or ""):lower() == "grab" then
        return "Grab Mode"
    end
    if lower:find("rotation mode", 1, true) or tostring(palette or ""):lower() == "rotation" then
        return "Rotation Mode"
    end
    if lower:find("scale mode", 1, true) or tostring(palette or ""):lower() == "scale" then
        return "Scale Mode"
    end
    return "Oculus Mode"
end

local function apply_oculus_rotation_palette(kind)
    local palette = oculus_overlay_palette(kind)
    if is_valid(oculus_rotation_top_border) then
        oculus_rotation_top_border:SetBrushColor(palette.top_bg)
    end
    if is_valid(oculus_rotation_mode_border) then
        oculus_rotation_mode_border:SetBrushColor(palette.mode_bg)
    end
    if is_valid(oculus_rotation_top_text) then
        oculus_rotation_top_text:SetColorAndOpacity(palette.text)
    end
    if is_valid(oculus_rotation_mode_text) then
        oculus_rotation_mode_text:SetColorAndOpacity(palette.text)
    end
end

local function set_visibility(show)
    if not is_valid(widget_canvas) then return end
    local vis = show and Visibility_SELF_HIT_TEST_INVISIBLE or Visibility_HIDDEN
    widget_canvas:SetVisibility(vis)
    if is_valid(root_border) then
        root_border:SetVisibility(vis)
    end
end

local function set_oculus_help_visibility(show, show_mode_row)
    if not is_valid(oculus_help_canvas) then return end
    local vis = Visibility_SELF_HIT_TEST_INVISIBLE
    local canvas_vis = show and vis or Visibility_HIDDEN
    oculus_help_canvas:SetVisibility(canvas_vis)
    if is_valid(oculus_help_border) then
        oculus_help_border:SetVisibility(canvas_vis)
    end
    if is_valid(oculus_help_mode_border) then
        oculus_help_mode_border:SetVisibility(show and show_mode_row and vis or Visibility_HIDDEN)
    end
end

local function set_oculus_rotation_visibility(show, show_mode_row)
    if not is_valid(oculus_rotation_canvas) then return end
    local vis = show and Visibility_SELF_HIT_TEST_INVISIBLE or Visibility_HIDDEN
    oculus_rotation_canvas:SetVisibility(vis)
    if is_valid(oculus_rotation_top_border) then
        oculus_rotation_top_border:SetVisibility(vis)
    end
    if is_valid(oculus_rotation_mode_border) then
        oculus_rotation_mode_border:SetVisibility(Visibility_HIDDEN)
    end
end

local function create_widget()
    local UEHelpers
    do
        local ok, mod = pcall(require, "UEHelpers")
        if ok and type(mod) == "table" then UEHelpers = mod end
    end
    if not UEHelpers or not UEHelpers.GetGameInstance then
        print("[RSDWTools.umg] UEHelpers.GetGameInstance unavailable.")
        return false
    end
    local game_instance
    local ok_gi = pcall(function() game_instance = UEHelpers.GetGameInstance() end)
    if not ok_gi or not game_instance then
        print("[RSDWTools.umg] failed to resolve GameInstance.")
        return false
    end

    local user_widget_cls = StaticFindObject and StaticFindObject("/Script/UMG.UserWidget") or nil
    local widget_tree_cls = StaticFindObject and StaticFindObject("/Script/UMG.WidgetTree") or nil
    local canvas_panel_cls = StaticFindObject and StaticFindObject("/Script/UMG.CanvasPanel") or nil
    local border_cls = StaticFindObject and StaticFindObject("/Script/UMG.Border") or nil
    local text_block_cls = StaticFindObject and StaticFindObject("/Script/UMG.TextBlock") or nil
    if not (user_widget_cls and widget_tree_cls and canvas_panel_cls and border_cls and text_block_cls) then
        print("[RSDWTools.umg] required UMG classes not found.")
        return false
    end

    local hud = StaticConstructObject(user_widget_cls, game_instance, FName("RSDWToolsToastHUD"))
    hud.WidgetTree = StaticConstructObject(widget_tree_cls, hud, FName("RSDWToolsToastTree"))

    local canvas = StaticConstructObject(canvas_panel_cls, hud.WidgetTree, FName("RSDWToolsToastCanvas"))
    hud.WidgetTree.RootWidget = canvas

    local border = StaticConstructObject(border_cls, canvas, FName("RSDWToolsToastBorder"))
    border:SetBrushColor(FLinearColor(0.0, 0.0, 0.0, 0.65))
    border:SetPadding({ Left = 14, Top = 8, Right = 14, Bottom = 8 })

    local panel_canvas = StaticConstructObject(canvas_panel_cls, border, FName("RSDWToolsToastPanelCanvas"))
    border:SetContent(panel_canvas)

    -- Anchor the toast to the top-center of the viewport so it reads as
    -- a notification rather than a HUD attachment. Anchors min/max both
    -- (0.5, 0.05), alignment (0.5, 0) keeps it horizontally centered
    -- and pinned 5% down from the top.
    local slot = canvas:AddChildToCanvas(border)
    slot:SetAutoSize(true)
    slot:SetAnchors({ Minimum = { X = 0.5, Y = 0.05 }, Maximum = { X = 0.5, Y = 0.05 } })
    slot:SetAlignment({ X = 0.5, Y = 0.0 })
    slot:SetPosition({ X = 0, Y = 0 })

    local t = StaticConstructObject(text_block_cls, panel_canvas, FName("RSDWToolsToastText"))
    t.Font.Size = 22
    t:SetText(FText(""))
    t:SetColorAndOpacity(FSlateColor(1.0, 1.0, 1.0, 1.0))
    t:SetShadowOffset({ X = 1, Y = 1 })
    t:SetShadowColorAndOpacity(FLinearColor(0.0, 0.0, 0.0, 0.7))
    local ts = panel_canvas:AddChildToCanvas(t)
    ts:SetAutoSize(true)
    ts:SetPosition({ X = 0, Y = 0 })

    canvas.Visibility = Visibility_HIDDEN
    border.Visibility = Visibility_HIDDEN
    panel_canvas.Visibility = Visibility_SELF_HIT_TEST_INVISIBLE

    hud:AddToViewport(95)

    widget_canvas = canvas
    root_border = border
    toast_text = t
    print("[RSDWTools.umg] toast widget created.")
    return true
end

local function create_oculus_help_widget()
    local UEHelpers
    do
        local ok, mod = pcall(require, "UEHelpers")
        if ok and type(mod) == "table" then UEHelpers = mod end
    end
    if not UEHelpers or not UEHelpers.GetGameInstance then
        print("[RSDWTools.umg] UEHelpers.GetGameInstance unavailable for Oculus help.")
        return false
    end

    local game_instance
    local ok_gi = pcall(function() game_instance = UEHelpers.GetGameInstance() end)
    if not ok_gi or not game_instance then
        print("[RSDWTools.umg] failed to resolve GameInstance for Oculus help.")
        return false
    end

    local user_widget_cls = StaticFindObject and StaticFindObject("/Script/UMG.UserWidget") or nil
    local widget_tree_cls = StaticFindObject and StaticFindObject("/Script/UMG.WidgetTree") or nil
    local canvas_panel_cls = StaticFindObject and StaticFindObject("/Script/UMG.CanvasPanel") or nil
    local border_cls = StaticFindObject and StaticFindObject("/Script/UMG.Border") or nil
    local text_block_cls = StaticFindObject and StaticFindObject("/Script/UMG.TextBlock") or nil
    if not (user_widget_cls and widget_tree_cls and canvas_panel_cls and border_cls and text_block_cls) then
        print("[RSDWTools.umg] Oculus help UMG classes not found.")
        return false
    end

    local hud = StaticConstructObject(user_widget_cls, game_instance, FName("RSDWToolsOculusHelpHUD"))
    hud.WidgetTree = StaticConstructObject(widget_tree_cls, hud, FName("RSDWToolsOculusHelpTree"))

    local canvas = StaticConstructObject(canvas_panel_cls, hud.WidgetTree, FName("RSDWToolsOculusHelpCanvas"))
    hud.WidgetTree.RootWidget = canvas

    local border = StaticConstructObject(border_cls, canvas, FName("RSDWToolsOculusHelpBorder"))
    border:SetBrushColor(FLinearColor(0.0, 0.0, 0.0, 0.62))
    border:SetPadding({ Left = 10, Top = 4, Right = 10, Bottom = 4 })

    local t = StaticConstructObject(text_block_cls, border, FName("RSDWToolsOculusHelpText"))
    t.Font.Size = 15
    t:SetText(FText(""))
    t:SetColorAndOpacity(FSlateColor(0.92, 0.95, 1.0, 1.0))
    t:SetShadowOffset({ X = 1, Y = 1 })
    t:SetShadowColorAndOpacity(FLinearColor(0.0, 0.0, 0.0, 0.75))
    pcall(function() t:SetJustification(1) end)
    border:SetContent(t)

    local slot = canvas:AddChildToCanvas(border)
    pcall(function() slot:SetAutoSize(false) end)
    slot:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 0.0 } })
    slot:SetAlignment({ X = 0.0, Y = 0.0 })
    slot:SetPosition({ X = 0, Y = 0 })
    pcall(function() slot:SetSize({ X = 0, Y = 30 }) end)
    pcall(function() slot:SetOffsets({ Left = 0, Top = 0, Right = 0, Bottom = 30 }) end)

    local mode_border = StaticConstructObject(border_cls, canvas, FName("RSDWToolsOculusHelpModeBorder"))
    mode_border:SetBrushColor(FLinearColor(0.0, 0.0, 0.0, 0.56))
    mode_border:SetPadding({ Left = 12, Top = 8, Right = 12, Bottom = 8 })

    local mode_t = StaticConstructObject(text_block_cls, mode_border, FName("RSDWToolsOculusHelpModeText"))
    mode_t.Font.Size = 15
    mode_t:SetText(FText(""))
    mode_t:SetColorAndOpacity(FSlateColor(0.92, 0.95, 1.0, 1.0))
    mode_t:SetShadowOffset({ X = 1, Y = 1 })
    mode_t:SetShadowColorAndOpacity(FLinearColor(0.0, 0.0, 0.0, 0.75))
    pcall(function() mode_t:SetJustification(2) end)
    mode_border:SetContent(mode_t)

    local mode_slot = canvas:AddChildToCanvas(mode_border)
    pcall(function() mode_slot:SetAutoSize(true) end)
    mode_slot:SetAnchors({ Minimum = { X = 1.0, Y = 0.5 }, Maximum = { X = 1.0, Y = 0.5 } })
    mode_slot:SetAlignment({ X = 1.0, Y = 0.0 })
    mode_slot:SetPosition({ X = -18, Y = 0 })

    canvas.Visibility = Visibility_HIDDEN
    border.Visibility = Visibility_HIDDEN
    mode_border.Visibility = Visibility_HIDDEN
    hud:AddToViewport(96)

    oculus_help_canvas = canvas
    oculus_help_border = border
    oculus_help_text = t
    oculus_help_mode_border = mode_border
    oculus_help_mode_text = mode_t
    print("[RSDWTools.umg] Oculus help widget created.")
    return true
end

local function create_oculus_rotation_widget()
    local UEHelpers
    do
        local ok, mod = pcall(require, "UEHelpers")
        if ok and type(mod) == "table" then UEHelpers = mod end
    end
    if not UEHelpers or not UEHelpers.GetGameInstance then
        print("[RSDWTools.umg] UEHelpers.GetGameInstance unavailable for Oculus rotation.")
        return false
    end

    local game_instance
    local ok_gi = pcall(function() game_instance = UEHelpers.GetGameInstance() end)
    if not ok_gi or not game_instance then
        print("[RSDWTools.umg] failed to resolve GameInstance for Oculus rotation.")
        return false
    end

    local user_widget_cls = StaticFindObject and StaticFindObject("/Script/UMG.UserWidget") or nil
    local widget_tree_cls = StaticFindObject and StaticFindObject("/Script/UMG.WidgetTree") or nil
    local canvas_panel_cls = StaticFindObject and StaticFindObject("/Script/UMG.CanvasPanel") or nil
    local border_cls = StaticFindObject and StaticFindObject("/Script/UMG.Border") or nil
    local text_block_cls = StaticFindObject and StaticFindObject("/Script/UMG.TextBlock") or nil
    if not (user_widget_cls and widget_tree_cls and canvas_panel_cls and border_cls and text_block_cls) then
        print("[RSDWTools.umg] Oculus rotation UMG classes not found.")
        return false
    end

    local hud = StaticConstructObject(user_widget_cls, game_instance, FName("RSDWToolsOculusRotationHUD"))
    hud.WidgetTree = StaticConstructObject(widget_tree_cls, hud, FName("RSDWToolsOculusRotationTree"))

    local canvas = StaticConstructObject(canvas_panel_cls, hud.WidgetTree, FName("RSDWToolsOculusRotationCanvas"))
    hud.WidgetTree.RootWidget = canvas

    local top_border = StaticConstructObject(border_cls, canvas, FName("RSDWToolsOculusRotationTopBorder"))
    top_border:SetBrushColor(FLinearColor(0.04, 0.02, 0.0, 0.70))
    top_border:SetPadding({ Left = 10, Top = 4, Right = 10, Bottom = 4 })

    local top_t = StaticConstructObject(text_block_cls, top_border, FName("RSDWToolsOculusRotationTopText"))
    top_t.Font.Size = 14
    top_t:SetText(FText(""))
    top_t:SetColorAndOpacity(FSlateColor(1.0, 0.88, 0.55, 1.0))
    top_t:SetShadowOffset({ X = 1, Y = 1 })
    top_t:SetShadowColorAndOpacity(FLinearColor(0.0, 0.0, 0.0, 0.80))
    pcall(function() top_t:SetJustification(1) end)
    top_border:SetContent(top_t)

    local top_slot = canvas:AddChildToCanvas(top_border)
    pcall(function() top_slot:SetAutoSize(false) end)
    top_slot:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 1.0, Y = 0.0 } })
    top_slot:SetAlignment({ X = 0.0, Y = 0.0 })
    top_slot:SetPosition({ X = 0, Y = 30 })
    pcall(function() top_slot:SetSize({ X = 0, Y = 30 }) end)
    pcall(function() top_slot:SetOffsets({ Left = 0, Top = 30, Right = 0, Bottom = 30 }) end)

    local mode_border = StaticConstructObject(border_cls, canvas, FName("RSDWToolsOculusRotationModeBorder"))
    mode_border:SetBrushColor(FLinearColor(0.04, 0.02, 0.0, 0.66))
    mode_border:SetPadding({ Left = 12, Top = 8, Right = 12, Bottom = 8 })

    local mode_t = StaticConstructObject(text_block_cls, mode_border, FName("RSDWToolsOculusRotationModeText"))
    mode_t.Font.Size = 15
    mode_t:SetText(FText(""))
    mode_t:SetColorAndOpacity(FSlateColor(1.0, 0.88, 0.55, 1.0))
    mode_t:SetShadowOffset({ X = 1, Y = 1 })
    mode_t:SetShadowColorAndOpacity(FLinearColor(0.0, 0.0, 0.0, 0.80))
    pcall(function() mode_t:SetJustification(2) end)
    mode_border:SetContent(mode_t)

    local mode_slot = canvas:AddChildToCanvas(mode_border)
    pcall(function() mode_slot:SetAutoSize(true) end)
    mode_slot:SetAnchors({ Minimum = { X = 1.0, Y = 0.5 }, Maximum = { X = 1.0, Y = 0.5 } })
    mode_slot:SetAlignment({ X = 1.0, Y = 0.0 })
    mode_slot:SetPosition({ X = -18, Y = 44 })

    canvas.Visibility = Visibility_HIDDEN
    top_border.Visibility = Visibility_HIDDEN
    mode_border.Visibility = Visibility_HIDDEN
    hud:AddToViewport(97)

    oculus_rotation_canvas = canvas
    oculus_rotation_top_border = top_border
    oculus_rotation_top_text = top_t
    oculus_rotation_mode_border = mode_border
    oculus_rotation_mode_text = mode_t
    print("[RSDWTools.umg] Oculus rotation widget created.")
    return true
end

local function editor_gizmo_color(axis, active)
    local alpha = active and 0.94 or 0.78
    if axis == "x" then return FLinearColor(0.95, 0.10, 0.10, alpha) end
    if axis == "y" then return FLinearColor(0.10, 0.86, 0.18, alpha) end
    if axis == "z" then return FLinearColor(0.18, 0.36, 1.0, alpha) end
    return FLinearColor(1.0, 0.86, 0.18, alpha)
end

local function create_editor_gizmo_widget()
    local UEHelpers
    do
        local ok, mod = pcall(require, "UEHelpers")
        if ok and type(mod) == "table" then UEHelpers = mod end
    end
    if not UEHelpers or not UEHelpers.GetGameInstance then
        print("[RSDWTools.umg] UEHelpers.GetGameInstance unavailable for editor gizmo.")
        return false
    end

    local game_instance
    local ok_gi = pcall(function() game_instance = UEHelpers.GetGameInstance() end)
    if not ok_gi or not game_instance then
        print("[RSDWTools.umg] failed to resolve GameInstance for editor gizmo.")
        return false
    end

    local user_widget_cls = StaticFindObject and StaticFindObject("/Script/UMG.UserWidget") or nil
    local widget_tree_cls = StaticFindObject and StaticFindObject("/Script/UMG.WidgetTree") or nil
    local canvas_panel_cls = StaticFindObject and StaticFindObject("/Script/UMG.CanvasPanel") or nil
    local border_cls = StaticFindObject and StaticFindObject("/Script/UMG.Border") or nil
    local text_block_cls = StaticFindObject and StaticFindObject("/Script/UMG.TextBlock") or nil
    if not (user_widget_cls and widget_tree_cls and canvas_panel_cls and border_cls and text_block_cls) then
        print("[RSDWTools.umg] editor gizmo UMG classes not found.")
        return false
    end

    local hud = StaticConstructObject(user_widget_cls, game_instance, FName("RSDWToolsEditorGizmoHUD"))
    hud.WidgetTree = StaticConstructObject(widget_tree_cls, hud, FName("RSDWToolsEditorGizmoTree"))

    local canvas = StaticConstructObject(canvas_panel_cls, hud.WidgetTree, FName("RSDWToolsEditorGizmoCanvas"))
    hud.WidgetTree.RootWidget = canvas

    editor_gizmo_handles = {}
    for _, axis in ipairs({ "free", "x", "y", "z" }) do
        local border = StaticConstructObject(border_cls, canvas, FName("RSDWToolsEditorGizmo" .. axis .. "Border"))
        border:SetBrushColor(editor_gizmo_color(axis, false))
        border:SetPadding({ Left = 8, Top = 5, Right = 8, Bottom = 5 })

        local text = StaticConstructObject(text_block_cls, border, FName("RSDWToolsEditorGizmo" .. axis .. "Text"))
        text.Font.Size = axis == "free" and 17 or 19
        text:SetText(FText(axis == "free" and "G" or axis:upper()))
        text:SetColorAndOpacity(FSlateColor(1.0, 1.0, 1.0, 1.0))
        text:SetShadowOffset({ X = 1, Y = 1 })
        text:SetShadowColorAndOpacity(FLinearColor(0.0, 0.0, 0.0, 0.85))
        pcall(function() text:SetJustification(1) end)
        border:SetContent(text)

        local slot = canvas:AddChildToCanvas(border)
        pcall(function() slot:SetAutoSize(true) end)
        slot:SetAnchors({ Minimum = { X = 0.0, Y = 0.0 }, Maximum = { X = 0.0, Y = 0.0 } })
        slot:SetAlignment({ X = 0.5, Y = 0.5 })
        slot:SetPosition({ X = -1000, Y = -1000 })

        border.Visibility = Visibility_HIDDEN
        editor_gizmo_handles[axis] = { border = border, text = text, slot = slot }
    end

    canvas.Visibility = Visibility_HIDDEN
    hud:AddToViewport(99)

    editor_gizmo_canvas = canvas
    print("[RSDWTools.umg] editor gizmo widget created.")
    return true
end

local function set_editor_gizmo_hidden()
    if is_valid(editor_gizmo_canvas) then
        editor_gizmo_canvas:SetVisibility(Visibility_HIDDEN)
    end
    for _, entry in pairs(editor_gizmo_handles or {}) do
        if is_valid(entry.border) then entry.border:SetVisibility(Visibility_HIDDEN) end
    end
end

local function update_editor_gizmo_overlay(points)
    if type(points) ~= "table" or #points == 0 then
        set_editor_gizmo_hidden()
        return
    end
    if not is_valid(editor_gizmo_canvas) then
        if not create_editor_gizmo_widget() then return end
    end
    if not is_valid(editor_gizmo_canvas) then return end

    editor_gizmo_canvas:SetVisibility(Visibility_SELF_HIT_TEST_INVISIBLE)
    for _, entry in pairs(editor_gizmo_handles or {}) do
        if is_valid(entry.border) then entry.border:SetVisibility(Visibility_HIDDEN) end
    end

    for _, point in ipairs(points) do
        local axis = tostring(point.axis or "free"):lower()
        local entry = editor_gizmo_handles[axis]
        if entry then
            if is_valid(entry.border) then
                entry.border:SetBrushColor(editor_gizmo_color(axis, point.active == true))
                entry.border:SetVisibility(Visibility_SELF_HIT_TEST_INVISIBLE)
            end
            if is_valid(entry.text) then
                entry.text:SetText(FText(tostring(point.label or (axis == "free" and "G" or axis:upper()))))
            end
            if entry.slot then
                pcall(function() entry.slot:SetPosition({ X = tonumber(point.x) or 0, Y = tonumber(point.y) or 0 }) end)
            end
        end
    end
end

-- Fire a toast on screen.
--   message  : string text to show
--   duration : seconds before auto-hide ; defaults to 3 if nil/<=0
local function show_toast(message, duration)
    if not message or message == "" then return end
    duration = tonumber(duration) or 3
    if duration <= 0 then duration = 3 end

    if not is_valid(toast_text) then
        if not create_widget() then return end
    end
    if is_valid(toast_text) then
        toast_text:SetText(FText(tostring(message)))
    end
    set_visibility(true)

    toast_generation = toast_generation + 1
    local my_gen = toast_generation
    if LoopAsync then
        local delay_ms = math.floor(duration * 1000)
        LoopAsync(delay_ms, function()
            -- Only hide if a newer toast hasn't superseded us.
            if my_gen ~= toast_generation then return true end
            ExecuteInGameThread(function()
                if my_gen == toast_generation then
                    set_visibility(false)
                end
            end)
            return true -- one-shot ; LoopAsync exits when callback returns true
        end)
    end
end

function M.toast(message, duration)
    if not ExecuteInGameThread then
        print("[RSDWTools.umg] ExecuteInGameThread unavailable.")
        return
    end
    ExecuteInGameThread(function()
        show_toast(message, duration)
    end)
end

function M.oculus_help(message, mode_message)
    if not ExecuteInGameThread then
        print("[RSDWTools.umg] ExecuteInGameThread unavailable.")
        return
    end
    ExecuteInGameThread(function()
        local primary = tostring(message or "")
        local secondary = tostring(mode_message or "")
        if primary == "" and secondary == "" then
            set_oculus_help_visibility(false, false)
            return
        end
        if not is_valid(oculus_help_text) then
            if not create_oculus_help_widget() then return end
        end
        if is_valid(oculus_help_text) then
            oculus_help_text:SetText(FText(primary))
        end
        if is_valid(oculus_help_mode_text) then
            oculus_help_mode_text:SetText(FText(secondary))
        end
        set_oculus_help_visibility(primary ~= "", secondary ~= "")
    end)
end

function M.oculus_help_hide()
    M.oculus_help("")
end

function M.oculus_rotation_overlay(show, top_message, mode_message, palette)
    if not ExecuteInGameThread then
        print("[RSDWTools.umg] ExecuteInGameThread unavailable.")
        return
    end
    oculus_rotation_generation = oculus_rotation_generation + 1
    local my_gen = oculus_rotation_generation
    ExecuteInGameThread(function()
        if my_gen ~= oculus_rotation_generation then return end
        local force_hide = show ~= true and (palette == "hide" or top_message == "__hide")
        if force_hide then
            set_oculus_rotation_visibility(false, false)
            return
        end
        if show ~= true then
            top_message = "Oculus Mode"
            mode_message = ""
            palette = "oculus"
        end
        if not is_valid(oculus_rotation_top_text) then
            if not create_oculus_rotation_widget() then return end
        end
        apply_oculus_rotation_palette(palette)
        local top_text = simple_oculus_mode_text(top_message, palette)
        if is_valid(oculus_rotation_top_text) then
            oculus_rotation_top_text:SetText(FText(top_text))
        end
        if is_valid(oculus_rotation_mode_text) then
            oculus_rotation_mode_text:SetText(FText(""))
        end
        set_oculus_rotation_visibility(true, false)
    end)
end

function M.editor_gizmo_overlay(points)
    if not ExecuteInGameThread then
        print("[RSDWTools.umg] ExecuteInGameThread unavailable for editor gizmo.")
        return
    end
    editor_gizmo_generation = editor_gizmo_generation + 1
    local my_gen = editor_gizmo_generation
    ExecuteInGameThread(function()
        if my_gen ~= editor_gizmo_generation then return end
        update_editor_gizmo_overlay(points)
    end)
end

function M.editor_gizmo_hide()
    if not ExecuteInGameThread then return end
    editor_gizmo_generation = editor_gizmo_generation + 1
    local my_gen = editor_gizmo_generation
    ExecuteInGameThread(function()
        if my_gen ~= editor_gizmo_generation then return end
        set_editor_gizmo_hidden()
    end)
end

-- Backwards-compat shim used by older console handlers ; routes through
-- the toast with the default duration.
function M.set_text(message)
    M.toast(message, 3)
end

function M.on_player_ready()
    -- Lazy-create on first toast ; nothing to do here.
end

function M.register_console()
    if not RegisterConsoleCommandHandler then return end
    RegisterConsoleCommandHandler("rsdwt_umg_text", function(_, parts)
        local txt
        if type(parts) == "table" then
            local chunks = {}
            for i = 2, #parts do chunks[#chunks + 1] = tostring(parts[i]) end
            txt = table.concat(chunks, " ")
        end
        M.toast(txt or "test", 3)
        return true
    end)
end

return M
