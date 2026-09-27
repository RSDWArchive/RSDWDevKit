-- feature_ui.lua: HUD widget enumeration + per-widget visibility toggling.
--
-- Strategy: APlayerHUD on Dragonwilds exposes a TArray<UUserWidget*>
-- HUDWidgetRefs that the BuildHUD() Blueprint populates with every UMG
-- widget instance the gameplay HUD spawns. We iterate that array (and
-- skip invalid entries) instead of FindAllOf("UserWidget"), which used
-- to crash because FindAllOf returns CDOs and partial trees that aren't
-- safe to call SetVisibility on.
--
-- Wire protocol (see command_line_router.lua):
--   ui.widgets.scan          -> writes ipc/widgets.json with [{id,label,...}]
--                               and acks "ok ui.widgets.scan <count>"
--   ui.widgets.set <id> <on|off>
--                            -> SetVisibility(0=Visible | 1=Collapsed) on
--                               the cached ref; "on" restores the original
--                               visibility we captured at scan time.
--   ui.widgets.hudroot <on|off>
--                            -> Directly sets WBP_HUD_RootWidget_C without
--                               requiring a prior ui.widgets.scan.
--
-- Caching note: widget_state is keyed by integer id (1-based, matching the
-- order of HUDWidgetRefs at scan time). Every scan rebuilds the table, so
-- a refresh after a level transition cleans up stale entries on its own.

local M = {}

local feature_actor = require("feature_actor")

local ESlateVisibility_Visible              = 0
local ESlateVisibility_Collapsed            = 1
local ESlateVisibility_Hidden               = 2
local ESlateVisibility_HitTestInvisible     = 3
local ESlateVisibility_SelfHitTestInvisible = 4

local visibility_label = {
    [-1] = "?",
    [0]  = "Visible",
    [1]  = "Collapsed",
    [2]  = "Hidden",
    [3]  = "HitTestInvisible",
    [4]  = "SelfHitTestInvisible",
}

-- Per-id state: { ref = UUserWidget*, original_vis = int }.
local widget_state = {}
-- Round 62: module-level cache of every CommonUI container we've seen
-- across scans. Push falls back to these when the activatable row's
-- entry has no cached container (its outer chain didn't include one
-- ; some Dragonwilds menus are owned by World/GameInstance instead
-- of being parented to a stack widget). Stored as
--   { container = UObject, name = "DomActivatableWidgetStack",
--     hosted_classes = { ["UClass*"] = true } }
local containers_known = {}

-- Round 63: EMainSubMenuType from Dominion_enums.hpp (line ~1797).
-- UMainMenuBase::NavigateToScreen(EMainSubMenuType) is the canonical
-- way Dragonwilds opens its menus ; pushing a sub-widget directly
-- onto a stack via BP_AddWidget produces a non-interactive ghost
-- because the sub-widget never gets registered with MainMenuBase
-- (no input mode swap, no pause, no focus, no CurrentScreenWidget).
-- Name -> enum value, lower-cased keys for case-insensitive lookup.
local main_sub_menu_type = {
    notset = 0, credits = 1, landing = 2, splash = 3, settings = 4,
    server = 5, developer = 6, charcreate = 7, charselect = 8,
    charselectforinvite = 9, worlds = 10, createworld = 11, pause = 12,
    skillsmain = 13, skillsperks = 14, spellbook = 15, topnavmenu = 16,
    topnavsystemsmenu = 17, journalmenu = 18, journaldetail = 19,
    consentform = 20, calibration = 21, accessibility = 22, tospp = 23,
    termsofservice = 24, privacypolicy = 25, seizurewarning = 26,
    copyright = 27, eoslanding = 28, eoslogin = 29, attemptinglogin = 30,
    selectworldtype = 31, selectworldgamemode = 32, trailer = 33,
    roadmap = 34, selectdedicatedserverhostingtype = 35, playerlist = 36,
    ["end"] = 37,
}

-- Reverse lookup, value -> canonical (CamelCase) display name. Used
-- when emitting available_menu_screens in widgets.json so the WPF
-- combo can show the proper name instead of the lowercase key.
local main_sub_menu_type_name = {
    [0] = "NotSet", [1] = "Credits", [2] = "Landing", [3] = "Splash",
    [4] = "Settings", [5] = "Server", [6] = "Developer", [7] = "CharCreate",
    [8] = "CharSelect", [9] = "CharSelectForInvite", [10] = "Worlds",
    [11] = "CreateWorld", [12] = "Pause", [13] = "SkillsMain",
    [14] = "SkillsPerks", [15] = "SpellBook", [16] = "TopNavMenu",
    [17] = "TopNavSystemsMenu", [18] = "JournalMenu", [19] = "JournalDetail",
    [20] = "ConsentForm", [21] = "Calibration", [22] = "Accessibility",
    [23] = "TOSPP", [24] = "TermsOfService", [25] = "PrivacyPolicy",
    [26] = "SeizureWarning", [27] = "Copyright", [28] = "EOSLanding",
    [29] = "EOSLogin", [30] = "AttemptingLogin", [31] = "SelectWorldType",
    [32] = "SelectWorldGameMode", [33] = "Trailer", [34] = "Roadmap",
    [35] = "SelectDedicatedServerHostingType", [36] = "PlayerList",
    [37] = "End",
}

-- Cached MainMenuBase root + screen-class lookup, refreshed on scan.
local menu_root_cached = nil
local screen_class_to_value = {} -- [UClass*] = integer enum value
-- Round 65: per-screen-value -> MainMenuBase root that actually
-- advertises that screen. Multiple MainMenuBase instances live in
-- memory simultaneously (FrontEndMenu + the gameplay one spawned
-- via PlayerController.MainMenuRootWidgetClass) ; their
-- ScreenWidgetMaps are disjoint. NavigateToScreen on the wrong
-- root logs "Screen[N] is not in the widget map" and silently
-- no-ops. Keep one entry per screen value pointing at a root that
-- has it.
local screen_value_to_root = {} -- [int value] = MainMenuBase UObject

local function is_valid(o)
    if not o then return false end
    if type(o) ~= "userdata" then return false end
    local ok, valid = pcall(function() return o:IsValid() end)
    return ok and valid == true
end

local function get_pawn()
    local p = feature_actor.get_local_pawn()
    if not p or not feature_actor.is_valid_object(p) then return nil end
    return p
end

local function get_player_hud(pawn)
    local pc
    pcall(function() pc = pawn:GetController() end)
    if not is_valid(pc) then return nil end
    local hud
    pcall(function() hud = pc.MyHUD end)
    if not is_valid(hud) then return nil end
    return hud
end

-- The build/version watermark in the top-left corner ("live-CL-... Charismatic-Dolphin")
-- is NOT a HUD widget — it lives on UDominionGameInstance.WatermarkWidget
-- (UWatermarkWidget extends UUserWidget). We surface it as an extra row
-- in the scan so the dropdown can collapse it like any other widget.
local function get_extra_widgets()
    local out = {}
    local gi
    if FindFirstOf then
        pcall(function() gi = FindFirstOf("DominionGameInstance") end)
    end
    if is_valid(gi) then
        local wm
        pcall(function() wm = gi.WatermarkWidget end)
        if is_valid(wm) then
            out[#out + 1] = wm
        end
    end
    return out
end

local function fname_to_string(n)
    if not n then return "" end
    if type(n) == "string" then return n end
    local ok, s = pcall(function() return n:ToString() end)
    if ok and s then return tostring(s) end
    return tostring(n)
end

local function widget_class_name(w)
    -- GetClass()/GetFName()/ToString() chains three vtable calls; on a stale
    -- TWeakObjectPtr that's a guaranteed AV. Try the cheapest path first:
    -- GetFullName already encodes the class name as the leading token (e.g.
    -- "WBP_HUD_Vitals_C /Game/.../WBP_HUD_Vitals.WBP_HUD_Vitals_C_2147481922").
    local fn
    if pcall(function() fn = w:GetFullName() end) and type(fn) == "string" and #fn > 0 then
        local first = fn:match("^(%S+)")
        if first and #first > 0 then return first end
    end
    -- Fallback: Class chain.
    local cls
    pcall(function() cls = w:GetClass() end)
    if not cls then return "<unknown>" end
    local name
    pcall(function() name = cls:GetFName() end)
    return fname_to_string(name)
end

-- Cosmetic: WBP_HUD_Vitals_HealthBar_C -> "HUD Vitals Health Bar".
local function friendly_label(class_name)
    local s = tostring(class_name or "")
    s = s:gsub("_C$", "")
    s = s:gsub("^WBP_", "")
    s = s:gsub("^BP_", "")
    s = s:gsub("_", " ")
    -- Insert space between camelCase humps.
    s = s:gsub("(%l)(%u)", "%1 %2")
    s = s:gsub("(%u)(%u%l)", "%1 %2")
    return s
end

local function read_visibility(w)
    -- Read the reflected `Visibility` property directly (UE4SS resolves
    -- this via property offsets, not vtable). Calling :GetVisibility()
    -- as a UFUNCTION goes through ProcessEvent and crashes the engine
    -- on certain HUD widgets (e.g. ones whose root slate hasn't been
    -- constructed yet).
    local v
    local ok = pcall(function() v = w.Visibility end)
    if not ok or v == nil then return -1 end
    if type(v) == "number" then return v end
    if type(v) == "userdata" then
        local n
        pcall(function() n = v:GetIntValue() end)
        if type(n) == "number" then return n end
    end
    return -1
end

-- Round 62: walk the widget's outer chain looking for a CommonUI
-- container (UCommonActivatableWidgetStack / Queue / base). Returns
-- the container UObject and its class name string, or nil. Defined
-- here at top-level (not inside scan_widgets) so push_with_id can
-- also fall back to it when the cached entry has a dead container.
local function find_container_outer(w)
    local cur = w
    for _ = 1, 10 do
        local outer
        pcall(function() outer = cur:GetOuter() end)
        if not outer then return nil end
        local ok_v, valid = pcall(function() return outer:IsValid() end)
        if not (ok_v and valid) then return nil end
        local cls
        pcall(function() cls = outer:GetClass() end)
        if cls then
            local cname = ""
            pcall(function() cname = cls:GetFName():ToString() end)
            if cname:find("ActivatableWidget", 1, true)
               and (cname:find("Stack") or cname:find("Queue") or cname:find("Container"))
            then
                return outer, cname
            end
        end
        cur = outer
    end
    return nil
end

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

local function get_widgets_json_path()
    local base = get_win64_base()
    if not base then return nil end
    local sep = "\\"
    return base .. sep .. "ue4ss" .. sep .. "Mods" .. sep .. "RSDWTools"
        .. sep .. "ipc" .. sep .. "widgets.json"
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

-- ui.widgets.scan [scope] -> writes ipc/widgets.json, returns count.
-- Scopes (Round 59):
--   "hud"         HUDWidgetRefs + extras only (small, stable list)
--   "viewport"    FindAllOf("UserWidget") sweep (AddToViewport widgets)
--   "activatable" CommonUI activatable widgets (pause menu, map, dialogs)
--   "all"         everything above (default ; matches old behaviour)
-- The shipped widgets.json always represents the most recent scan ; the
-- WPF UI can call any of the four scoped scans independently so the
-- list stays small and the user can mentally separate "HUD vs menu".
function M.scan_widgets(scope)
    scope = tostring(scope or "all"):lower()
    local want_hud         = (scope == "hud")         or (scope == "all")
    local want_viewport    = (scope == "viewport")    or (scope == "all")
    local want_activatable = (scope == "activatable") or (scope == "all")

    -- HUD lookup is only required for the HUDWidgetRefs path. Activatable
    -- and viewport scans work even with no pawn (e.g. on the main menu).
    local hud
    if want_hud then
        local pawn = get_pawn(); if not pawn then return false, "no local pawn" end
        hud = get_player_hud(pawn); if not hud then return false, "no HUD" end
    end

    -- Reset cache on every scan: invalidates ids from prior level/HUD load.
    widget_state = {}
    containers_known = {}
    menu_root_cached = nil
    screen_class_to_value = {}
    screen_value_to_root = {}

    local refs
    if hud then pcall(function() refs = hud.HUDWidgetRefs end) end

    local entries = {}
    local next_id = 0
    -- Round 57: dedupe by FullName so the same widget pointer surfaced
    -- via multiple sources (HUDWidgetRefs + FindAllOf viewport sweep)
    -- only renders one row in the UI.
    local seen_full_names = {}

    -- Local helper: process one widget pointer into an entry + cache row.
    local function process(w, src_label)
        if not is_valid(w) then return end
        -- Skip class default objects ; calling SetVisibility on a CDO
        -- crashes the engine and they aren't visible widgets anyway.
        local fn
        pcall(function() fn = w:GetFullName() end)
        if type(fn) ~= "string" or #fn == 0 then return end
        if fn:find("Default__", 1, true) then return end
        if seen_full_names[fn] then return end
        next_id = next_id + 1
        -- Round 62: store id (not just true) so the post-pass that walks
        -- container WidgetLists can map a contained widget's FullName
        -- back to its row and backfill the cached container ref.
        seen_full_names[fn] = next_id
        local cls    = widget_class_name(w)
        local label  = friendly_label(cls)
        -- GetFullName format: "<ClassName> <PathName>". Split out the
        -- path so the WPF UI can show an instance discriminator next
        -- to the (often duplicated) class label. Round 58: many
        -- CommonActivatableWidget subclasses pool multiple instances
        -- with the same class label ; without the path the rows look
        -- like duplicates that the user can't tell apart.
        local pathstr = ""
        local sp = fn:find(" ", 1, true)
        if sp then pathstr = fn:sub(sp + 1) end
        local vis    = read_visibility(w)
        local visible = (vis == 0 or vis == 3 or vis == 4)
        widget_state[next_id] = { ref = w, original_vis = vis }
        -- Round 62: for activatable rows, capture class + container at
        -- scan time. The widget instance can be GC'd or returned to a
        -- pool the moment the menu closes ; without these cached refs
        -- a Push call on a stale id has nothing to work with.
        if src_label:sub(1, 7) == "active:" or src_label:sub(1, 7) == "pooled:" then
            local cls_obj
            pcall(function() cls_obj = w:GetClass() end)
            widget_state[next_id].class = cls_obj
            local container, container_name = find_container_outer(w)
            widget_state[next_id].container = container
            widget_state[next_id].container_name = container_name
        end
        entries[#entries + 1] = string.format(
            '{"id":%d,"label":"%s","class":"%s","path":"%s","visible":%s,"vis_code":%d,"vis_name":"%s","source":"%s"}',
            next_id,
            escape_json(label),
            escape_json(cls),
            escape_json(pathstr),
            visible and "true" or "false",
            vis,
            escape_json(visibility_label[vis] or "?"),
            escape_json(src_label)
        )
        print(string.format("[RSDWTools] ui.widgets.scan: %s id=%d cls=%s vis=%d",
            src_label, next_id, cls, vis))
    end

    if want_hud and refs then
        local n = 0
        pcall(function() n = #refs end)
        print(string.format("[RSDWTools] ui.widgets.scan: HUDWidgetRefs n=%d", n))
        for i = 1, n do
            -- Per-step trace: if the engine AVs on a specific entry, the
            -- log will end with the last "i=K" line so we know which one.
            print(string.format("[RSDWTools] ui.widgets.scan: i=%d fetch", i))
            local w
            local fok = pcall(function() w = refs[i] end)
            if not fok then
                print(string.format("[RSDWTools] ui.widgets.scan: i=%d fetch FAILED", i))
            else
                process(w, "hud[" .. i .. "]")
            end
        end
    end

    -- Extras: widgets that aren't on APlayerHUD (e.g. the GameInstance
    -- watermark in the top-left corner).
    if want_hud then
        for _, w in ipairs(get_extra_widgets()) do
            process(w, "extra")
        end
    end

    -- Round 57: viewport sweep. Catches every UUserWidget that was
    -- AddToViewport'd outside the BuildHUD pipeline, plus any
    -- CommonUI activatable widget pushed onto a widget stack (pause
    -- menu, map, inventory, vendor screens). FindAllOf returns CDOs
    -- and pre-constructed pool entries too; we filter those via the
    -- "Default__" FullName prefix and the IsConstructed UFUNCTION,
    -- and the dedupe by FullName above keeps already-processed HUD
    -- refs from showing up twice.
    --
    -- Why not require IsInViewport(): CommonUI activatable widgets
    -- live on a UCommonActivatableWidgetStack inside a viewport
    -- container; the children themselves return false for
    -- IsInViewport even while fully painted on screen. Switching to
    -- IsConstructed lets the user toggle the pause menu/map widget
    -- the same way they toggle a HUD vital. Cost: a few extra
    -- "warmed but not visible" widgets show up in the list with a
    -- vis_code of 1 (Collapsed) ; toggling them on a non-visible
    -- widget is a silent no-op.
    if FindAllOf and want_viewport then
        local all
        pcall(function() all = FindAllOf("UserWidget") end)
        if type(all) == "table" then
            local n = #all
            print(string.format("[RSDWTools] ui.widgets.scan: FindAllOf UserWidget n=%d", n))
            local kept, dropped = 0, 0
            local last_has_iv, last_has_ic = false, false
            for i = 1, n do
                local w = all[i]
                if is_valid(w) then
                    -- Accept the widget if EITHER signal is true.
                    -- IsConstructed catches CommonUI activatable
                    -- widgets sitting on a stack ; IsInViewport
                    -- catches anything AddToViewport'd directly.
                    -- On builds where one of these UFUNCTIONs is
                    -- not reachable via reflection the pcall fails
                    -- silently and we fall back to the other.
                    local in_viewport, has_iv = false, false
                    pcall(function()
                        in_viewport = w:IsInViewport() == true
                        has_iv = true
                    end)
                    local constructed, has_ic = false, false
                    pcall(function()
                        constructed = w:IsConstructed() == true
                        has_ic = true
                    end)
                    last_has_iv, last_has_ic = has_iv, has_ic
                    if in_viewport or constructed then
                        local src
                        if in_viewport then src = "viewport"
                        elseif constructed then src = "constructed"
                        else src = "userwidget" end
                        process(w, src)
                        kept = kept + 1
                    else
                        dropped = dropped + 1
                    end
                end
            end
            print(string.format(
                "[RSDWTools] ui.widgets.scan: FindAllOf kept=%d dropped=%d (has_iv last=%s has_ic last=%s)",
                kept, dropped, tostring(last_has_iv), tostring(last_has_ic)))
        end
    end

    if FindAllOf and want_activatable then
        -- Round 58/59: dedicated CommonUI activatable sweep. Pause
        -- menu, map widget, vendor screens, dialog stacks etc. all
        -- derive from UCommonActivatableWidget (Dragonwilds wraps it
        -- as UDomUserWidget). FindAllOf("UserWidget") often misses
        -- these on certain UE4SS builds because the reflection lookup
        -- keys on exact class name rather than ancestry, and even
        -- when it does return them, IsInViewport()/IsConstructed()
        -- can both read false because activatable widgets are
        -- slate-painted via the activation system rather than the
        -- viewport widget tree.
        --
        -- Strategy: take everything FindAllOf returns for each
        -- candidate class, skip CDOs by FullName ("Default__"),
        -- include unconditionally. Dedupe by FullName above stops
        -- duplicates. Tag with IsActivated() so the user can spot
        -- which ones are live ; flipping vis on a non-activated
        -- widget is a silent no-op.
        --
        -- Round 59: also enumerate the Dragonwilds-specific named
        -- subclasses directly because some UE4SS builds key
        -- FindAllOf on exact class name rather than ancestry, so
        -- asking for the parent ("CommonActivatableWidget") returns
        -- nothing while asking for "PauseMenuScreen" returns hits.
        local activatable_classes = {
            "CommonActivatableWidget",
            "DomUserWidget",
            "DomActivatableWidgetStack",
            "HUDRootWidget",
            "MainMenuBase",
            "PauseMenuScreen",
            "MapWidget",
            "QuestListWidget",
            "GenericDialogBase",
        }
        for _, cls in ipairs(activatable_classes) do
            local all
            pcall(function() all = FindAllOf(cls) end)
            if type(all) == "table" then
                local n = #all
                local kept, skipped = 0, 0
                for i = 1, n do
                    local w = all[i]
                    if is_valid(w) then
                        local fn
                        pcall(function() fn = w:GetFullName() end)
                        if type(fn) == "string" and not fn:find("Default__", 1, true) then
                            local activated = false
                            pcall(function() activated = w:IsActivated() == true end)
                            local src = activated and ("active:" .. cls) or ("pooled:" .. cls)
                            local before = #entries
                            process(w, src)
                            if #entries > before then
                                kept = kept + 1
                            else
                                skipped = skipped + 1 -- already seen via dedupe
                            end
                        end
                    end
                end
                print(string.format(
                    "[RSDWTools] ui.widgets.scan: FindAllOf %s n=%d kept=%d dedup_skipped=%d",
                    cls, n, kept, skipped))
            else
                print(string.format(
                    "[RSDWTools] ui.widgets.scan: FindAllOf %s returned no table", cls))
            end
        end
    end

    -- Round 62: container post-pass. Enumerate every CommonUI
    -- container class, walk each one's WidgetList, and backfill
    -- entry.container for any contained widget whose row didn't pick
    -- up a container via outer-chain walk. Also stash every container
    -- in containers_known so push_with_id can fall back to a
    -- by-class search when an entry has no cached container at all.
    if FindAllOf and want_activatable then
        local container_classes = {
            "DomActivatableWidgetStack",
            "CommonActivatableWidgetStack",
            "CommonActivatableWidgetQueue",
            "CommonActivatableWidgetContainerBase",
        }
        local total_containers = 0
        local backfilled = 0
        for _, ccls in ipairs(container_classes) do
            local all
            pcall(function() all = FindAllOf(ccls) end)
            if type(all) == "table" then
                for i = 1, #all do
                    local cont = all[i]
                    if is_valid(cont) then
                        local cfn
                        pcall(function() cfn = cont:GetFullName() end)
                        if type(cfn) == "string" and not cfn:find("Default__", 1, true) then
                            -- Track the container with the set of widget
                            -- classes currently in its WidgetList. Push
                            -- uses this to pick a container known to
                            -- accept the row's class.
                            local hosted = {}
                            local list
                            pcall(function() list = cont.WidgetList end)
                            if list then
                                local n_list = 0
                                pcall(function() n_list = #list end)
                                for j = 1, n_list do
                                    local child
                                    pcall(function() child = list[j] end)
                                    if is_valid(child) then
                                        local ccls_obj
                                        pcall(function() ccls_obj = child:GetClass() end)
                                        if ccls_obj then hosted[ccls_obj] = true end
                                        local child_fn
                                        pcall(function() child_fn = child:GetFullName() end)
                                        local found_id = type(child_fn) == "string"
                                            and seen_full_names[child_fn] or nil
                                        if type(found_id) == "number" then
                                            local e = widget_state[found_id]
                                            if e and not is_valid(e.container) then
                                                e.container = cont
                                                e.container_name = ccls
                                                backfilled = backfilled + 1
                                            end
                                        end
                                    end
                                end
                            end
                            containers_known[#containers_known + 1] = {
                                container = cont,
                                name = ccls,
                                hosted_classes = hosted,
                            }
                            total_containers = total_containers + 1
                        end
                    end
                end
            end
        end
        print(string.format(
            "[RSDWTools] ui.widgets.scan: containers=%d backfilled_entries=%d",
            total_containers, backfilled))
    end

    -- Round 63: MainMenuBase / ScreenWidgetMap discovery. Find a live
    -- MainMenuBase instance, iterate its TMap<EMainSubMenuType,
    -- TSubclassOf<UMainMenuSubWidgetBase>> to learn which sub-widget
    -- class corresponds to which screen enum value. Then walk
    -- widget_state and stamp menu_root + menu_screen_value on every
    -- entry whose class is one of those sub-widget classes. Push will
    -- prefer NavigateToScreen for these rows because BP_AddWidget on
    -- a sub-widget produces a non-interactive ghost.
    if FindAllOf and want_activatable then
        local roots
        pcall(function() roots = FindAllOf("MainMenuBase") end)
        if type(roots) == "table" then
            -- Round 65: walk EVERY live MainMenuBase, not just the
            -- first non-CDO. The frontend (UMainMenuBase from
            -- FrontEndMenuClass) and the gameplay one (spawned via
            -- PlayerController.MainMenuRootWidgetClass) both live in
            -- memory simultaneously and their ScreenWidgetMaps are
            -- disjoint -- the frontend has Landing/CharSelect/etc, the
            -- gameplay one has Pause/JournalMenu/SkillsMain/etc. Pick
            -- one root per screen value and remember a fallback
            -- "any non-CDO MainMenuBase" for free-form invocation.
            for i = 1, #roots do
                local root = roots[i]
                if is_valid(root) then
                    local rfn
                    pcall(function() rfn = root:GetFullName() end)
                    if type(rfn) == "string" and not rfn:find("Default__", 1, true) then
                        if not is_valid(menu_root_cached) then
                            menu_root_cached = root
                        end
                        local map
                        pcall(function() map = root.ScreenWidgetMap end)
                        if map then
                            local ok_each = pcall(function()
                                map:ForEach(function(k, v)
                                    -- k is EMainSubMenuType (userdata or
                                    -- number), v is a TSubclassOf wrapper
                                    -- around a UClass*.
                                    local key_n
                                    if type(k) == "number" then key_n = k
                                    elseif type(k) == "userdata" then
                                        pcall(function() key_n = k:GetIntValue() end)
                                        if not key_n then pcall(function() key_n = k:get() end) end
                                    end
                                    -- TSubclassOf in UE4SS Lua usually
                                    -- presents directly as the UClass.
                                    local cls_obj = v
                                    if type(v) == "userdata" then
                                        local g
                                        pcall(function() g = v:Get() end)
                                        if g then cls_obj = g end
                                    end
                                    if type(key_n) == "number" and cls_obj then
                                        screen_class_to_value[cls_obj] = key_n
                                        -- First root that maps this
                                        -- screen wins ; subsequent roots
                                        -- (if they also have it) get
                                        -- ignored. Either is correct.
                                        if not screen_value_to_root[key_n] then
                                            screen_value_to_root[key_n] = root
                                        end
                                    end
                                end)
                            end)
                            if not ok_each then
                                print("[RSDWTools] ui.widgets.scan: ScreenWidgetMap ForEach unsupported on this UE4SS build")
                            end
                        end
                    end
                end
            end
        end
        local n_screens = 0
        for _ in pairs(screen_class_to_value) do n_screens = n_screens + 1 end
        local n_roots = 0
        do
            local seen_root = {}
            for _, r in pairs(screen_value_to_root) do
                if not seen_root[r] then seen_root[r] = true; n_roots = n_roots + 1 end
            end
        end
        print(string.format(
            "[RSDWTools] ui.widgets.scan: menu_roots=%d screen_classes_mapped=%d",
            n_roots, n_screens))

        -- Stamp every widget_state entry whose UClass matches.
        if n_screens > 0 then
            local stamped = 0
            for _, entry in pairs(widget_state) do
                local cls = entry.class
                if not cls and is_valid(entry.ref) then
                    pcall(function() cls = entry.ref:GetClass() end)
                end
                local v = cls and screen_class_to_value[cls] or nil
                if v then
                    entry.menu_root = screen_value_to_root[v] or menu_root_cached
                    entry.menu_screen_value = v
                    stamped = stamped + 1
                end
            end
            print(string.format(
                "[RSDWTools] ui.widgets.scan: menu_screen entries stamped=%d", stamped))
        end
    end

    -- Round 64: emit the screens we discovered via ScreenWidgetMap so
    -- the WPF Navigate combo only lists items the running build has
    -- actually wired up. Sorted by enum value for stable display.
    local screen_values = {}
    for v, _ in pairs(screen_class_to_value) do
        -- screen_class_to_value is keyed by UClass*, but its values
        -- are the enum ints we want to surface.
    end
    -- Re-iterate against the inverse since we want enum ints, not classes.
    local seen_v = {}
    for _, v in pairs(screen_class_to_value) do
        if not seen_v[v] then
            seen_v[v] = true
            screen_values[#screen_values + 1] = v
        end
    end
    table.sort(screen_values)
    local screens_json = {}
    for _, v in ipairs(screen_values) do
        local n = main_sub_menu_type_name[v] or tostring(v)
        screens_json[#screens_json + 1] = string.format(
            '{"name":"%s","value":%d}', escape_json(n), v)
    end

    local body = '{"generated_unix":' .. tostring(os.time())
        .. ',"count":' .. tostring(#entries)
        .. ',"available_menu_screens":[' .. table.concat(screens_json, ",") .. "]"
        .. ',"widgets":[' .. table.concat(entries, ",") .. "]}"
    local path = get_widgets_json_path()
    local wok, werr = write_atomic(path, body)
    if not wok then return false, werr end
    return true, tostring(#entries)
end

-- ui.widgets.set <id> <on|off>
-- Round 50: same auto-rescan-once fallback as set_widget_vis below.
local function set_with_id(id, show)
    local entry = widget_state[id]
    if not entry or not is_valid(entry.ref) then
        return nil, entry and "stale" or "missing"
    end
    local target_vis
    if show then
        target_vis = (entry.original_vis and entry.original_vis >= 0)
            and entry.original_vis or ESlateVisibility_Visible
    else
        target_vis = ESlateVisibility_Collapsed
    end
    local ok, err = pcall(function() entry.ref:SetVisibility(target_vis) end)
    if not ok then return false, "SetVisibility failed: " .. tostring(err) end
    return true, string.format("id=%d -> %s", id, visibility_label[target_vis] or tostring(target_vis))
end

function M.set_widget(args_str)
    if not args_str or args_str == "" then
        return false, "usage: ui.widgets.set <id> <on|off>"
    end
    local id_str, mode = args_str:match("^(%S+)%s+(%S+)%s*$")
    if not (id_str and mode) then
        return false, "usage: ui.widgets.set <id> <on|off>"
    end
    local id = tonumber(id_str)
    if not id then return false, "id must be an integer" end

    local m = mode:lower()
    local show
    if m == "on" or m == "1" or m == "true" or m == "show" then show = true
    elseif m == "off" or m == "0" or m == "false" or m == "hide" then show = false
    else return false, "mode must be on|off" end

    local ok, msg = set_with_id(id, show)
    if ok ~= nil then return ok, msg end
    print(string.format("[RSDWTools] ui.widgets.set: id=%d %s ; auto-rescan + retry.",
        id, msg or "missing"))
    pcall(function() M.scan_widgets() end)
    local ok2, msg2 = set_with_id(id, show)
    if ok2 ~= nil then return ok2, msg2 end
    return false, "unknown id (rescan?): " .. tostring(id)
end

-- ui.widgets.setvis <id> <0..4>
-- Direct ESlateVisibility setter so the WPF dropdown can pick any of the
-- five engine modes (Visible / Collapsed / Hidden / HitTestInvisible /
-- SelfHitTestInvisible) instead of being limited to on/off.
--
-- Round 50: hotkey'd / favorited setvis verbs may fire in a session
-- that hasn't run a manual scan yet, or after a level reload that
-- emptied widget_state. Instead of failing with "unknown id", we try
-- one auto-rescan and retry the lookup. Same fix is applied below to
-- M.set_widget so the on/off path benefits too.
local function setvis_with_id(id, code)
    local entry = widget_state[id]
    if not entry or not is_valid(entry.ref) then
        return nil, entry and "stale" or "missing"
    end
    local ok, err = pcall(function() entry.ref:SetVisibility(code) end)
    if not ok then return false, "SetVisibility failed: " .. tostring(err) end
    return true, string.format("id=%d -> %s", id, visibility_label[code] or tostring(code))
end

function M.set_widget_vis(args_str)
    if not args_str or args_str == "" then
        return false, "usage: ui.widgets.setvis <id> <0..4>"
    end
    local id_str, code_str = args_str:match("^(%S+)%s+(%S+)%s*$")
    if not (id_str and code_str) then
        return false, "usage: ui.widgets.setvis <id> <0..4>"
    end
    local id   = tonumber(id_str)
    local code = tonumber(code_str)
    if not id   then return false, "id must be an integer" end
    if not code then return false, "vis code must be 0..4" end
    if code < 0 or code > 4 or code ~= math.floor(code) then
        return false, "vis code must be an integer 0..4"
    end

    local ok, msg = setvis_with_id(id, code)
    if ok ~= nil then return ok, msg end
    -- Auto-rescan once. Quiet failure here ; we fall through to the
    -- explicit "unknown id (rescan?)" message if the rescan can't
    -- recover the entry (e.g. HUD is gone, or this id genuinely is
    -- out of range for the current scan).
    print(string.format("[RSDWTools] ui.widgets.setvis: id=%d %s ; auto-rescan + retry.",
        id, msg or "missing"))
    pcall(function() M.scan_widgets() end)
    local ok2, msg2 = setvis_with_id(id, code)
    if ok2 ~= nil then return ok2, msg2 end
    return false, "unknown id (rescan?): " .. tostring(id)
end

local function add_hud_root_candidate(out, seen, w)
    if not is_valid(w) then return end
    local fn
    pcall(function() fn = w:GetFullName() end)
    if type(fn) ~= "string" or #fn == 0 then return end
    if fn:find("Default__", 1, true) then return end
    if seen[fn] then return end
    local cls = widget_class_name(w)
    if cls ~= "WBP_HUD_RootWidget_C" then return end
    seen[fn] = true
    out[#out + 1] = w
end

local function collect_hud_root_widgets()
    local out = {}
    local seen = {}

    local pawn = get_pawn()
    local hud = pawn and get_player_hud(pawn) or nil
    local refs
    if hud then pcall(function() refs = hud.HUDWidgetRefs end) end
    if refs then
        local n = 0
        pcall(function() n = #refs end)
        for i = 1, n do
            local w
            if pcall(function() w = refs[i] end) then
                add_hud_root_candidate(out, seen, w)
            end
        end
    end

    if FindAllOf then
        local classes = { "WBP_HUD_RootWidget_C", "HUDRootWidget", "UserWidget" }
        for _, class_name in ipairs(classes) do
            local all
            pcall(function() all = FindAllOf(class_name) end)
            if type(all) == "table" then
                for i = 1, #all do
                    add_hud_root_candidate(out, seen, all[i])
                end
            end
        end
    end

    return out
end

function M.set_hud_root(args_str)
    local mode = tostring(args_str or ""):match("^%s*(%S+)%s*$")
    if not mode then
        return false, "usage: ui.widgets.hudroot <on|off>"
    end
    mode = mode:lower()
    local code
    if mode == "off" or mode == "hide" or mode == "hidden" or mode == "0" or mode == "false" then
        code = ESlateVisibility_Hidden
    elseif mode == "on" or mode == "show" or mode == "visible" or mode == "1" or mode == "true" then
        code = ESlateVisibility_SelfHitTestInvisible
    else
        return false, "mode must be on|off"
    end

    local widgets = collect_hud_root_widgets()
    if #widgets == 0 then
        return false, "no live WBP_HUD_RootWidget_C widgets found"
    end

    local changed, failed = 0, 0
    for _, widget in ipairs(widgets) do
        local ok = pcall(function() widget:SetVisibility(code) end)
        if ok then changed = changed + 1 else failed = failed + 1 end
    end

    return failed == 0,
        string.format("%s=%d fail=%d -> %s", mode, changed, failed,
            visibility_label[code] or tostring(code))
end

-- ui.widgets.resetall -> restore each cached widget to the visibility we
-- captured at scan time. Useful after Hide All to undo the operation.
function M.reset_all()
    local count, fails = 0, 0
    for id, entry in pairs(widget_state) do
        if is_valid(entry.ref) then
            local target = (entry.original_vis and entry.original_vis >= 0)
                and entry.original_vis or ESlateVisibility_Visible
            local ok = pcall(function() entry.ref:SetVisibility(target) end)
            if ok then count = count + 1 else fails = fails + 1 end
        else
            fails = fails + 1
        end
    end
    return true, string.format("reset=%d fail=%d", count, fails)
end

-- ui.widgets.hideall -> set every cached widget to Collapsed.
function M.hide_all()
    local count, fails = 0, 0
    for id, entry in pairs(widget_state) do
        if is_valid(entry.ref) then
            local ok = pcall(function() entry.ref:SetVisibility(ESlateVisibility_Collapsed) end)
            if ok then count = count + 1 else fails = fails + 1 end
        else
            fails = fails + 1
        end
    end
    return true, string.format("hidden=%d fail=%d", count, fails)
end

-- Round 60: ui.widgets.activate <id> <on|off>
-- Calls UCommonActivatableWidget::ActivateWidget / DeactivateWidget on
-- the cached ref. Unlike SetVisibility this drives the full CommonUI
-- activation pipeline (input mapping context, focus, modality, the
-- bSetVisibilityOnActivated/Deactivated bindings) ; this is what the
-- game does internally to "open" a pause menu or dialog.
--
-- Limitations:
--   * Only works on widgets that derive from UCommonActivatableWidget.
--     Non-activatable rows will fail with the engine's "missing
--     UFUNCTION" error (we propagate the pcall error string).
--   * Activating a pooled-but-not-on-a-stack widget paints it without
--     setting up input ; the next stack tick may yank focus back.
--     For a clean "open the pause menu", the right call is
--     PushWidget on the owning UCommonActivatableWidgetContainerBase ;
--     that needs us to know which stack hosts which menu, which the
--     UI tab's catalog doesn't yet expose. Toggling an already-pushed
--     menu (deactivate to close, re-activate to re-open) is the
--     reliable path today.
local function activate_with_id(id, on)
    local entry = widget_state[id]
    if not entry then return nil, "missing" end
    -- Round 62: the cached ref is often dead by the time the user
    -- clicks Activate (CommonUI returns the instance to a pool /
    -- GCs it on close). is_valid catches *some* of that, but UE4SS
    -- IsValid can return true for a freed pointer ; wrap the call
    -- in pcall and translate "nullptr" into a Push hint.
    if not is_valid(entry.ref) then
        return false, "stale ref ; click Push to re-open from cached class"
    end
    local fn_name = on and "ActivateWidget" or "DeactivateWidget"
    local ok, err = pcall(function() entry.ref[fn_name](entry.ref) end)
    if not ok then
        if tostring(err):find("nullptr", 1, true) and on then
            return false, "stale ref ; click Push to re-open from cached class"
        end
        return false, fn_name .. " failed: " .. tostring(err)
    end
    -- Read-back the activation flag so the UI layer can confirm.
    local active
    pcall(function() active = entry.ref:IsActivated() end)
    return true, string.format("id=%d %s active=%s", id, fn_name, tostring(active))
end

function M.activate_widget(args_str)
    if not args_str or args_str == "" then
        return false, "usage: ui.widgets.activate <id> <on|off>"
    end
    local id_str, mode = args_str:match("^(%S+)%s+(%S+)%s*$")
    if not (id_str and mode) then
        return false, "usage: ui.widgets.activate <id> <on|off>"
    end
    local id = tonumber(id_str)
    if not id then return false, "id must be an integer" end

    local m = mode:lower()
    local on
    if m == "on" or m == "1" or m == "true" or m == "show" or m == "activate" then on = true
    elseif m == "off" or m == "0" or m == "false" or m == "hide" or m == "deactivate" then on = false
    else return false, "mode must be on|off" end

    local ok, msg = activate_with_id(id, on)
    if ok ~= nil then return ok, msg end
    print(string.format("[RSDWTools] ui.widgets.activate: id=%d %s ; auto-rescan + retry.",
        id, msg or "missing"))
    pcall(function() M.scan_widgets() end)
    local ok2, msg2 = activate_with_id(id, on)
    if ok2 ~= nil then return ok2, msg2 end
    return false, "unknown id (rescan?): " .. tostring(id)
end

-- Round 61: ui.widgets.push <id>
-- Push the widget's class onto its CommonUI container. This is the
-- path the game uses internally when an input action like
-- "OpenPauseMenu" fires ; BP_AddWidget runs the full activation
-- pipeline (input mapping, focus, modality, visibility bindings) and
-- the new instance actually paints on screen.
--
-- Round 62: prefer the class + container cached at scan time. The
-- live widget pointer is often dead by the time the user clicks Push
-- (CommonUI returns the instance to a pool / GCs it on close), but
-- the container itself outlives any single push and the class object
-- is global. So even when entry.ref is nullptr we can still re-open.
local function push_with_id(id)
    local entry = widget_state[id]
    if not entry then return nil, "missing" end

    -- Round 63: prefer MainMenuBase::NavigateToScreen for sub-widget
    -- rows. BP_AddWidget on a UMainMenuSubWidgetBase produces a
    -- non-interactive ghost ; the canonical path goes through
    -- MainMenuBase which handles input mode, focus, pause, and
    -- registering CurrentScreenWidget.
    if entry.menu_screen_value and is_valid(entry.menu_root) then
        local ok, err = pcall(function()
            entry.menu_root:NavigateToScreen(entry.menu_screen_value)
        end)
        if ok then
            return true, string.format("id=%d NavigateToScreen(%d) on MainMenuBase",
                id, entry.menu_screen_value)
        end
        -- Fall through to BP_AddWidget if the navigate call failed
        -- ; better to try than fail outright.
        print(string.format(
            "[RSDWTools] ui.widgets.push: NavigateToScreen failed (%s) ; falling back to BP_AddWidget",
            tostring(err)))
    end

    -- Resolve container ; prefer cached, fall back to walking outer
    -- chain on the live ref if we still have one, then fall back to
    -- the module-level containers_known list (Round 62: many
    -- Dragonwilds menus aren't parented to a stack via Outer ; the
    -- post-pass has to discover containers separately).
    local container = entry.container
    local container_name = entry.container_name
    if not is_valid(container) and is_valid(entry.ref) then
        container, container_name = find_container_outer(entry.ref)
    end
    if not is_valid(container) then
        -- Resolve class first so we can match by hosted class.
        local widget_class = entry.class
        if not is_valid(widget_class) and is_valid(entry.ref) then
            pcall(function() widget_class = entry.ref:GetClass() end)
        end
        if is_valid(widget_class) then
            for _, info in ipairs(containers_known) do
                if is_valid(info.container) and info.hosted_classes[widget_class] then
                    container = info.container
                    container_name = info.name .. " (matched by hosted class)"
                    break
                end
            end
        end
        -- Last-resort: if exactly one container exists, just use it.
        -- Better than refusing the push outright.
        if not is_valid(container) and #containers_known == 1
           and is_valid(containers_known[1].container) then
            container = containers_known[1].container
            container_name = containers_known[1].name .. " (only known container)"
        end
    end
    if not is_valid(container) then
        return false, "no container resolvable ; rescan with the menu open so we can capture its parent stack"
    end

    -- Resolve class ; prefer cached.
    local widget_class = entry.class
    if not is_valid(widget_class) and is_valid(entry.ref) then
        pcall(function() widget_class = entry.ref:GetClass() end)
    end
    if not is_valid(widget_class) then
        return false, "no widget class cached and no live ref to read it from ; rescan with the menu open"
    end

    local pushed
    local ok, err = pcall(function() pushed = container:BP_AddWidget(widget_class) end)
    if not ok then
        return false, "BP_AddWidget failed on " .. tostring(container_name) .. ": " .. tostring(err)
    end
    return true, string.format("id=%d pushed onto %s (rescan to see new id)", id, tostring(container_name))
end

function M.push_widget(args_str)
    if not args_str or args_str == "" then
        return false, "usage: ui.widgets.push <id>"
    end
    local id_str = args_str:match("^(%S+)%s*$")
    if not id_str then return false, "usage: ui.widgets.push <id>" end
    local id = tonumber(id_str)
    if not id then return false, "id must be an integer" end

    local ok, msg = push_with_id(id)
    if ok ~= nil then return ok, msg end
    print(string.format("[RSDWTools] ui.widgets.push: id=%d %s ; auto-rescan + retry.",
        id, msg or "missing"))
    pcall(function() M.scan_widgets() end)
    local ok2, msg2 = push_with_id(id)
    if ok2 ~= nil then return ok2, msg2 end
    return false, "unknown id (rescan?): " .. tostring(id)
end

-- Round 63: ui.menus.navigate <name|number>
-- Direct entry point that doesn't require a prior scan / cached id.
-- Resolves a screen name (case-insensitive, e.g. "Pause", "JournalMenu",
-- "SkillsMain", "SpellBook") or numeric value to EMainSubMenuType, finds
-- the live MainMenuBase, and calls NavigateToScreen. This is the same
-- code path the game itself uses on Esc/keybind, so input mode, focus,
-- pause, and CurrentScreenWidget all get wired up correctly.
--
-- Round 65: multiple MainMenuBase instances coexist (FrontEndMenu and
-- the gameplay one spawned from PlayerController.MainMenuRootWidgetClass)
-- and their ScreenWidgetMaps are disjoint. Pick the root whose map
-- actually contains the requested screen value ; otherwise NavigateToScreen
-- silently no-ops with "Screen[N] is not in the widget map" in the log.
local function discover_main_menu_roots()
    -- Refreshes screen_value_to_root by walking every MainMenuBase
    -- found via FindAllOf and reading each ScreenWidgetMap. Used as
    -- a lazy fallback when menus_navigate is called without a prior
    -- ui.widgets.scan having run.
    local roots
    pcall(function() roots = FindAllOf("MainMenuBase") end)
    if type(roots) ~= "table" then return end
    for i = 1, #roots do
        local root = roots[i]
        if is_valid(root) then
            local rfn
            pcall(function() rfn = root:GetFullName() end)
            if type(rfn) == "string" and not rfn:find("Default__", 1, true) then
                if not is_valid(menu_root_cached) then menu_root_cached = root end
                local map
                pcall(function() map = root.ScreenWidgetMap end)
                if map then
                    pcall(function()
                        map:ForEach(function(k, v)
                            local key_n
                            if type(k) == "number" then key_n = k
                            elseif type(k) == "userdata" then
                                pcall(function() key_n = k:GetIntValue() end)
                                if not key_n then pcall(function() key_n = k:get() end) end
                            end
                            if type(key_n) == "number" then
                                if not screen_value_to_root[key_n] then
                                    screen_value_to_root[key_n] = root
                                end
                            end
                        end)
                    end)
                end
            end
        end
    end
end

function M.menus_navigate(args_str)
    if not args_str or args_str == "" then
        return false, "usage: ui.menus.navigate <name|number> (e.g. Pause, JournalMenu, 12)"
    end
    local arg = args_str:match("^(%S+)%s*$")
    if not arg then return false, "usage: ui.menus.navigate <name|number>" end
    local value = tonumber(arg)
    if not value then
        value = main_sub_menu_type[arg:lower()]
    end
    if type(value) ~= "number" then
        return false, "unknown screen name: " .. tostring(arg)
    end

    -- Pick the root whose ScreenWidgetMap actually contains this
    -- value. If we don't know yet, run an on-demand discovery pass.
    local root = screen_value_to_root[value]
    if not is_valid(root) then
        discover_main_menu_roots()
        root = screen_value_to_root[value]
    end
    -- Last-resort fallback: any non-CDO MainMenuBase. May log
    -- "Screen[N] is not in the widget map" and no-op, but better
    -- to attempt than reject ; when the gameplay MainMenuBase
    -- gets constructed mid-session a retry will pick it up.
    if not is_valid(root) then root = menu_root_cached end
    if not is_valid(root) then
        return false, "no live MainMenuBase advertises screen " .. tostring(value)
            .. " ; open the in-game pause menu once so its MainMenuBase spawns, then retry"
    end

    local ok, err = pcall(function() root:NavigateToScreen(value) end)
    if not ok then
        return false, "NavigateToScreen failed: " .. tostring(err)
    end
    return true, string.format("NavigateToScreen(%d) sent", value)
end

return M
