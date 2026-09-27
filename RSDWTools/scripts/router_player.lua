local support = require("router_support")
local lazy_feature = support.lazy_feature

local feature_teleport = lazy_feature("feature_teleport")
local feature_player = lazy_feature("feature_player")
local feature_player_attack = lazy_feature("feature_player_attack")
local feature_player_anim = lazy_feature("feature_player_anim")
local feature_player_spells = lazy_feature("feature_player_spells")
local feature_field = lazy_feature("feature_field")
local feature_ge = lazy_feature("feature_ge")
local feature_transmog = lazy_feature("feature_transmog")

local M = {}

function M.try_handle(line)
    if line == "player.loc" or line:sub(1, 11) == "player.loc " then
        local ok, result = feature_teleport.report_current_location()
        if ok then
            -- Plain coordinate ack so the WPF side can parse it with one split.
            return true, true, tostring(result)
        end
        return true, false, "player.loc failed: " .. tostring(result)
    end

    -- Round 29 catalog pipeline:
    --   dump.types -> UE4SS GenerateLuaTypes() emits EmmyLua type stubs to
    --                 <ue4ss>/Mods/shared/types/.
    if line == "dump.types" then
        if type(GenerateLuaTypes) ~= "function" then
            return true, false, "dump.types failed: GenerateLuaTypes global not registered (UE4SS too old?)"
        end
        local ok, err = pcall(GenerateLuaTypes)
        if not ok then
            return true, false, "dump.types failed: " .. tostring(err)
        end
        return true, true, "ok dump.types -- types regenerated under ue4ss/Mods/shared/types/"
    end

    -- player.* cheat / read verbs. Grouped under one prefix check so every
    -- new one lives right here (not scattered around the file) and so we
    -- don't have to touch main dispatch each time a verb is added. Each
    -- verb pulls its single argument off the line via a fixed offset that
    -- matches its string length; the offset constant lives next to the
    -- call site so refactoring a verb name only changes two adjacent
    -- numbers in one block.
    if line:sub(1, 7) == "player." then
        local function arg_after(verb)
            local rest = line:sub(#verb + 1)
            return (tostring(rest or ""):gsub("^%s+", ""):gsub("%s+$", ""))
        end
        local function matches_player(verb)
            return line == verb or line:sub(1, #verb + 1) == verb .. " "
        end

        -- Animation / action playback
        if matches_player("player.anim.play") then
            local ok, detail = feature_player_anim.play_animation(arg_after("player.anim.play"))
            if ok then return true, true, "ok player.anim.play " .. tostring(detail) end
            return true, false, "player.anim.play failed: " .. tostring(detail)
        end
        if matches_player("player.anim.montage") then
            local ok, detail = feature_player_anim.play_montage(arg_after("player.anim.montage"))
            if ok then return true, true, "ok player.anim.montage " .. tostring(detail) end
            return true, false, "player.anim.montage failed: " .. tostring(detail)
        end
        if matches_player("player.anim.stop") then
            local ok, detail = feature_player_anim.stop_montage(arg_after("player.anim.stop"))
            if ok then return true, true, "ok player.anim.stop " .. tostring(detail) end
            return true, false, "player.anim.stop failed: " .. tostring(detail)
        end
        if matches_player("player.attack.state") then
            local ok, detail = feature_player_attack.attack_state(arg_after("player.attack.state"))
            if ok then return true, true, "ok player.attack.state " .. tostring(detail) end
            return true, false, "player.attack.state failed: " .. tostring(detail)
        end
        if matches_player("player.attack.data") then
            local ok, detail = feature_player_attack.attack_data(arg_after("player.attack.data"))
            if ok then return true, true, "ok player.attack.data " .. tostring(detail) end
            return true, false, "player.attack.data failed: " .. tostring(detail)
        end
        if matches_player("player.attack.trace") then
            local ok, detail = feature_player_attack.attack_trace(arg_after("player.attack.trace"))
            if ok then return true, true, "ok player.attack.trace " .. tostring(detail) end
            return true, false, "player.attack.trace failed: " .. tostring(detail)
        end
        if matches_player("player.attack.perform") then
            local ok, detail = feature_player_attack.attack_perform(arg_after("player.attack.perform"))
            if ok then return true, true, "ok player.attack.perform " .. tostring(detail) end
            return true, false, "player.attack.perform failed: " .. tostring(detail)
        end
        if matches_player("player.attack") then
            local ok, detail = feature_player_attack.play_attack(arg_after("player.attack"))
            if ok then return true, true, "ok player.attack " .. tostring(detail) end
            return true, false, "player.attack failed: " .. tostring(detail)
        end
        if matches_player("player.emote") then
            local ok, detail = feature_player_anim.play_emote(arg_after("player.emote"))
            if ok then return true, true, "ok player.emote " .. tostring(detail) end
            return true, false, "player.emote failed: " .. tostring(detail)
        end

        -- Movement
        if line:sub(1, 11) == "player.time" then
            local ok, detail = feature_player.set_time_dilation(arg_after("player.time"))
            if ok then return true, true, "ok player.time " .. tostring(detail) end
            return true, false, "player.time failed: " .. tostring(detail)
        end
        if line:sub(1, 17) == "player.jump.count" then
            local ok, detail = feature_player.set_jump_count(arg_after("player.jump.count"))
            if ok then return true, true, "ok player.jump.count " .. tostring(detail) end
            return true, false, "player.jump.count failed: " .. tostring(detail)
        end
        if line:sub(1, 16) == "player.jump.hold" then
            local ok, detail = feature_player.set_jump_hold(arg_after("player.jump.hold"))
            if ok then return true, true, "ok player.jump.hold " .. tostring(detail) end
            return true, false, "player.jump.hold failed: " .. tostring(detail)
        end

        -- Combat
        if line:sub(1, 16) == "player.buildings" then
            local ok, detail = feature_player.set_can_damage_buildings(arg_after("player.buildings"))
            if ok then return true, true, "ok player.buildings " .. tostring(detail) end
            return true, false, "player.buildings failed: " .. tostring(detail)
        end
        if line:sub(1, 16) == "player.invisible" then
            local ok, detail = feature_player.set_invisible(arg_after("player.invisible"))
            if ok then return true, true, "ok player.invisible " .. tostring(detail) end
            return true, false, "player.invisible failed: " .. tostring(detail)
        end
        if line:sub(1, 15) == "player.soulrift" then
            local ok, detail = feature_player.set_soul_rift_immunity(arg_after("player.soulrift"))
            if ok then return true, true, "ok player.soulrift " .. tostring(detail) end
            return true, false, "player.soulrift failed: " .. tostring(detail)
        end

        -- Vitals (component-backed cheats)
        if line:sub(1, 17) == "player.invincible" then
            local ok, detail = feature_player.set_invincible(arg_after("player.invincible"))
            if ok then return true, true, "ok player.invincible " .. tostring(detail) end
            return true, false, "player.invincible failed: " .. tostring(detail)
        end
        if line:sub(1, 15) == "player.immortal" then
            local ok, detail = feature_player.set_immortal(arg_after("player.immortal"))
            if ok then return true, true, "ok player.immortal " .. tostring(detail) end
            return true, false, "player.immortal failed: " .. tostring(detail)
        end
        -- health.heal / health.damage MUST be checked before player.health
        -- (the shorter prefix would otherwise eat the compound verbs and
        -- send their numeric tail as the new "current health").
        -- NOTE: player.health.max and player.revive removed 2026-04-17 --
        -- see NOTES/cheats-to-revisit.md sections 4 and 5.
        if line == "player.health.heal" or line:sub(1, 19) == "player.health.heal " then
            local ok, detail = feature_player.heal_full()
            if ok then return true, true, "ok player.health.heal " .. tostring(detail) end
            return true, false, "player.health.heal failed: " .. tostring(detail)
        end
        if line:sub(1, 20) == "player.health.damage" then
            local ok, detail = feature_player.damage_self(arg_after("player.health.damage"))
            if ok then return true, true, "ok player.health.damage " .. tostring(detail) end
            return true, false, "player.health.damage failed: " .. tostring(detail)
        end
        if line:sub(1, 13) == "player.health" then
            local ok, detail = feature_player.set_health(arg_after("player.health"))
            if ok then return true, true, "ok player.health " .. tostring(detail) end
            return true, false, "player.health failed: " .. tostring(detail)
        end

        -- Movement (component-backed)
        if line:sub(1, 18) == "player.fall_immune" then
            local ok, detail = feature_player.set_fall_immune(arg_after("player.fall_immune"))
            if ok then return true, true, "ok player.fall_immune " .. tostring(detail) end
            return true, false, "player.fall_immune failed: " .. tostring(detail)
        end
        if line:sub(1, 16) == "player.walkspeed" then
            local ok, detail = feature_player.set_walkspeed(arg_after("player.walkspeed"))
            if ok then return true, true, "ok player.walkspeed " .. tostring(detail) end
            return true, false, "player.walkspeed failed: " .. tostring(detail)
        end
        if line:sub(1, 14) == "player.jumpvel" then
            local ok, detail = feature_player.set_jumpvel(arg_after("player.jumpvel"))
            if ok then return true, true, "ok player.jumpvel " .. tostring(detail) end
            return true, false, "player.jumpvel failed: " .. tostring(detail)
        end
        if line:sub(1, 14) == "player.gravity" then
            local ok, detail = feature_player.set_gravity(arg_after("player.gravity"))
            if ok then return true, true, "ok player.gravity " .. tostring(detail) end
            return true, false, "player.gravity failed: " .. tostring(detail)
        end
        if line:sub(1, 17) == "player.aircontrol" then
            local ok, detail = feature_player.set_air_control(arg_after("player.aircontrol"))
            if ok then return true, true, "ok player.aircontrol " .. tostring(detail) end
            return true, false, "player.aircontrol failed: " .. tostring(detail)
        end
        if line:sub(1, 16) == "player.speedmult" then
            local ok, detail = feature_player.set_speed_mult(arg_after("player.speedmult"))
            if ok then return true, true, "ok player.speedmult " .. tostring(detail) end
            return true, false, "player.speedmult failed: " .. tostring(detail)
        end
        if line:sub(1, 15) == "player.movemode" then
            local ok, detail = feature_player.set_movement_mode(arg_after("player.movemode"))
            if ok then return true, true, "ok player.movemode " .. tostring(detail) end
            return true, false, "player.movemode failed: " .. tostring(detail)
        end
        if line:sub(1, 13) == "player.noclip" then
            local ok, detail = feature_player.set_noclip(arg_after("player.noclip"))
            if ok then return true, true, "ok player.noclip " .. tostring(detail) end
            return true, false, "player.noclip failed: " .. tostring(detail)
        end
        if line:sub(1, 15) == "player.flyspeed" then
            local ok, detail = feature_player.set_flyspeed(arg_after("player.flyspeed"))
            if ok then return true, true, "ok player.flyspeed " .. tostring(detail) end
            return true, false, "player.flyspeed failed: " .. tostring(detail)
        end
        -- player.swimspeed removed in round 5 -- see cheats-to-revisit.md ??6.
        if line:sub(1, 19) == "player.acceleration" then
            local ok, detail = feature_player.set_acceleration(arg_after("player.acceleration"))
            if ok then return true, true, "ok player.acceleration " .. tostring(detail) end
            return true, false, "player.acceleration failed: " .. tostring(detail)
        end

        -- Survival stats. The .refill / .clear compound verbs MUST be
        -- checked before their short form so the shorter prefix doesn't
        -- swallow them (same pattern as health.heal vs health).
        if line == "player.hydration.refill" or line:sub(1, 24) == "player.hydration.refill " then
            local ok, detail = feature_player.refill_hydration()
            if ok then return true, true, "ok player.hydration.refill " .. tostring(detail) end
            return true, false, "player.hydration.refill failed: " .. tostring(detail)
        end
        -- Round 15: DecayBuffer per stat (must come before the generic
        -- player.hydration prefix or it'll swallow this).
        if line:sub(1, 28) == "player.hydration.decaybuffer" then
            local ok, detail = feature_player.set_hydration_decaybuffer(arg_after("player.hydration.decaybuffer"))
            if ok then return true, true, "ok player.hydration.decaybuffer " .. tostring(detail) end
            return true, false, "player.hydration.decaybuffer failed: " .. tostring(detail)
        end
        if line:sub(1, 16) == "player.hydration" then
            local ok, detail = feature_player.set_hydration(arg_after("player.hydration"))
            if ok then return true, true, "ok player.hydration " .. tostring(detail) end
            return true, false, "player.hydration failed: " .. tostring(detail)
        end
        if line == "player.sustenance.refill" or line:sub(1, 25) == "player.sustenance.refill " then
            local ok, detail = feature_player.refill_sustenance()
            if ok then return true, true, "ok player.sustenance.refill " .. tostring(detail) end
            return true, false, "player.sustenance.refill failed: " .. tostring(detail)
        end
        if line:sub(1, 29) == "player.sustenance.decaybuffer" then
            local ok, detail = feature_player.set_sustenance_decaybuffer(arg_after("player.sustenance.decaybuffer"))
            if ok then return true, true, "ok player.sustenance.decaybuffer " .. tostring(detail) end
            return true, false, "player.sustenance.decaybuffer failed: " .. tostring(detail)
        end
        if line:sub(1, 17) == "player.sustenance" then
            local ok, detail = feature_player.set_sustenance(arg_after("player.sustenance"))
            if ok then return true, true, "ok player.sustenance " .. tostring(detail) end
            return true, false, "player.sustenance failed: " .. tostring(detail)
        end
        if line == "player.endurance.refill" or line:sub(1, 24) == "player.endurance.refill " then
            local ok, detail = feature_player.refill_endurance()
            if ok then return true, true, "ok player.endurance.refill " .. tostring(detail) end
            return true, false, "player.endurance.refill failed: " .. tostring(detail)
        end
        if line:sub(1, 28) == "player.endurance.decaybuffer" then
            local ok, detail = feature_player.set_endurance_decaybuffer(arg_after("player.endurance.decaybuffer"))
            if ok then return true, true, "ok player.endurance.decaybuffer " .. tostring(detail) end
            return true, false, "player.endurance.decaybuffer failed: " .. tostring(detail)
        end
        if line:sub(1, 16) == "player.endurance" then
            local ok, detail = feature_player.set_endurance(arg_after("player.endurance"))
            if ok then return true, true, "ok player.endurance " .. tostring(detail) end
            return true, false, "player.endurance failed: " .. tostring(detail)
        end
        if line == "player.toxicity.clear" or line:sub(1, 22) == "player.toxicity.clear " then
            local ok, detail = feature_player.clear_toxicity()
            if ok then return true, true, "ok player.toxicity.clear " .. tostring(detail) end
            return true, false, "player.toxicity.clear failed: " .. tostring(detail)
        end
        if line:sub(1, 15) == "player.toxicity" then
            local ok, detail = feature_player.set_toxicity(arg_after("player.toxicity"))
            if ok then return true, true, "ok player.toxicity " .. tostring(detail) end
            return true, false, "player.toxicity failed: " .. tostring(detail)
        end

        -- Stealth / Stamina / Sleep (one-shot or toggle verbs, no numeric arg).
        if line:sub(1, 14) == "player.stealth" then
            local ok, detail = feature_player.set_stealth(arg_after("player.stealth"))
            if ok then return true, true, "ok player.stealth " .. tostring(detail) end
            return true, false, "player.stealth failed: " .. tostring(detail)
        end
        if line == "player.stamina.refill" or line:sub(1, 22) == "player.stamina.refill " then
            local ok, detail = feature_player.refill_stamina()
            if ok then return true, true, "ok player.stamina.refill " .. tostring(detail) end
            return true, false, "player.stamina.refill failed: " .. tostring(detail)
        end
        if line == "player.wakeup" or line:sub(1, 14) == "player.wakeup " then
            local ok, detail = feature_player.wake_up()
            if ok then return true, true, "ok player.wakeup " .. tostring(detail) end
            return true, false, "player.wakeup failed: " .. tostring(detail)
        end

        -- Round 5: Items / Interaction / Camera / Stealth / Evade.
        --
        -- Compound-verb ordering rule still applies: longer prefix first.
        -- The only compound-risk ones here are the .* family for camera
        -- (player.fov has no sub-verbs so the bare prefix check is fine).
        if line:sub(1, 21) == "player.durabilityloss" then
            local ok, detail = feature_player.set_no_durability_loss(arg_after("player.durabilityloss"))
            if ok then return true, true, "ok player.durabilityloss " .. tostring(detail) end
            return true, false, "player.durabilityloss failed: " .. tostring(detail)
        end
        if line:sub(1, 13) == "player.magnet" then
            local ok, detail = feature_player.set_magnet_range(arg_after("player.magnet"))
            if ok then return true, true, "ok player.magnet " .. tostring(detail) end
            return true, false, "player.magnet failed: " .. tostring(detail)
        end
        if line:sub(1, 10) == "player.fov" then
            local ok, detail = feature_player.set_fov(arg_after("player.fov"))
            if ok then return true, true, "ok player.fov " .. tostring(detail) end
            return true, false, "player.fov failed: " .. tostring(detail)
        end
        -- Phase 2: Camera + UI tabs. Generic component field setter
        -- handles any UCameraComponent / USpringArmComponent / PC / HUD
        -- field by alias. The Lua resolver also accepts PC, HUD, and
        -- CameraManager as special root tokens.
        --   player.comp.set <Alias> <Field> <value>      (16)
        --   player.comp.get <Alias> <Field>              (16)
        if line:sub(1, 16) == "player.comp.set " then
            local ok, detail = feature_player.comp_set(line:sub(17))
            if ok then return true, true, "ok player.comp.set " .. tostring(detail) end
            return true, false, "player.comp.set failed: " .. tostring(detail)
        end
        if line:sub(1, 16) == "player.comp.get " then
            local ok, detail = feature_player.comp_get(line:sub(17))
            if ok then return true, true, tostring(detail) end
            return true, false, "player.comp.get failed: " .. tostring(detail)
        end
        -- Round 26 round A: generic uniform-schema write verbs. Methodology
        -- doc `docs/MODS_CATALOG_METHODOLOGY.md` section 5. Eight verbs cover
        -- every Mods-tab category by walking dot-paths against either the
        -- local pawn (`pawn`) or a world subsystem/actor (`world`).
        --   player.field.set         <root> <path> <value>           (17)
        --   player.field.set_index   <root> <ctnrPath> <idx> <value> (23)
        --   player.field.set_key     <root> <ctnrPath> <key> <value> (21)
        --   player.field.set_object  <root> <path> <ClassName>       (24)  -- round 27
        --   player.field.add         <root> <ctnrPath> <value>       (17)  -- round 27
        --   player.field.remove      <root> <ctnrPath> <idxOrValue>  (20)  -- round 27
        --   player.field.clear       <root> <ctnrPath>               (19)  -- round 27
        --   player.field.call        <root> <path> [args...]         (18)
        -- Each branch checks an exact-length prefix string, so prefix
        -- shadowing is handled per-branch (no longest-first requirement).
        if line:sub(1, 24) == "player.field.set_object " then
            local ok, detail = feature_field.set_object(line:sub(25))
            if ok then return true, true, "ok player.field.set_object " .. tostring(detail) end
            return true, false, "player.field.set_object failed: " .. tostring(detail)
        end
        if line:sub(1, 23) == "player.field.set_asset " then
            local ok, detail = feature_field.set_asset(line:sub(24))
            if ok then return true, true, "ok player.field.set_asset " .. tostring(detail) end
            return true, false, "player.field.set_asset failed: " .. tostring(detail)
        end
        if line:sub(1, 23) == "player.field.set_index " then
            local ok, detail = feature_field.set_index(line:sub(24))
            if ok then return true, true, "ok player.field.set_index " .. tostring(detail) end
            return true, false, "player.field.set_index failed: " .. tostring(detail)
        end
        if line:sub(1, 21) == "player.field.set_key " then
            local ok, detail = feature_field.set_key(line:sub(22))
            if ok then return true, true, "ok player.field.set_key " .. tostring(detail) end
            return true, false, "player.field.set_key failed: " .. tostring(detail)
        end
        if line:sub(1, 20) == "player.field.remove " then
            local ok, detail = feature_field.remove(line:sub(21))
            if ok then return true, true, "ok player.field.remove " .. tostring(detail) end
            return true, false, "player.field.remove failed: " .. tostring(detail)
        end
        if line:sub(1, 19) == "player.field.clear " then
            local ok, detail = feature_field.clear(line:sub(20))
            if ok then return true, true, "ok player.field.clear " .. tostring(detail) end
            return true, false, "player.field.clear failed: " .. tostring(detail)
        end
        if line:sub(1, 18) == "player.field.call " then
            local ok, detail = feature_field.call(line:sub(19))
            if ok then return true, true, "ok player.field.call " .. tostring(detail) end
            return true, false, "player.field.call failed: " .. tostring(detail)
        end
        if line:sub(1, 17) == "player.field.set " then
            local ok, detail = feature_field.set(line:sub(18))
            if ok then return true, true, "ok player.field.set " .. tostring(detail) end
            return true, false, "player.field.set failed: " .. tostring(detail)
        end
        if line:sub(1, 17) == "player.field.add " then
            local ok, detail = feature_field.add(line:sub(18))
            if ok then return true, true, "ok player.field.add " .. tostring(detail) end
            return true, false, "player.field.add failed: " .. tostring(detail)
        end
        if line:sub(1, 13) == "player.silent" then
            local ok, detail = feature_player.set_silent(arg_after("player.silent"))
            if ok then return true, true, "ok player.silent " .. tostring(detail) end
            return true, false, "player.silent failed: " .. tostring(detail)
        end
        if line:sub(1, 12) == "player.surge" then
            local ok, detail = feature_player.set_surge(arg_after("player.surge"))
            if ok then return true, true, "ok player.surge " .. tostring(detail) end
            return true, false, "player.surge failed: " .. tostring(detail)
        end

        -- Round 6: Combat (parry / block) + Targeting (lock-on range).
        -- Note: "player.parrywindow" must be checked before any shorter
        -- "player.p*" prefix would be added in future, and "player.blockangle"
        -- likewise. The current ordering is safe; keep in mind if expanding.
        if line:sub(1, 18) == "player.parrywindow" then
            local ok, detail = feature_player.set_parry_window(arg_after("player.parrywindow"))
            if ok then return true, true, "ok player.parrywindow " .. tostring(detail) end
            return true, false, "player.parrywindow failed: " .. tostring(detail)
        end
        if line:sub(1, 17) == "player.blockangle" then
            local ok, detail = feature_player.set_block_angle(arg_after("player.blockangle"))
            if ok then return true, true, "ok player.blockangle " .. tostring(detail) end
            return true, false, "player.blockangle failed: " .. tostring(detail)
        end
        if line:sub(1, 13) == "player.lockon" then
            local ok, detail = feature_player.set_lockon_scale(arg_after("player.lockon"))
            if ok then return true, true, "ok player.lockon " .. tostring(detail) end
            return true, false, "player.lockon failed: " .. tostring(detail)
        end

        -- Round 7: Vitals / Survival sliders + Combat / Ranged / Magic toggles.
        -- Ordering: "player.respawninvul" must precede any future "player.respawn"
        -- prefix match; "player.wellrested" is unique already; the toggles are
        -- all unique prefixes.
        if line:sub(1, 19) == "player.respawninvul" then
            local ok, detail = feature_player.set_respawn_invul(arg_after("player.respawninvul"))
            if ok then return true, true, "ok player.respawninvul " .. tostring(detail) end
            return true, false, "player.respawninvul failed: " .. tostring(detail)
        end
        if line:sub(1, 17) == "player.wellrested" then
            local ok, detail = feature_player.set_well_rested(arg_after("player.wellrested"))
            if ok then return true, true, "ok player.wellrested " .. tostring(detail) end
            return true, false, "player.wellrested failed: " .. tostring(detail)
        end
        if line:sub(1, 12) == "player.poise" then
            local ok, detail = feature_player.set_poise(arg_after("player.poise"))
            if ok then return true, true, "ok player.poise " .. tostring(detail) end
            return true, false, "player.poise failed: " .. tostring(detail)
        end
        if line:sub(1, 17) == "player.perfectaim" then
            local ok, detail = feature_player.set_perfect_aim(arg_after("player.perfectaim"))
            if ok then return true, true, "ok player.perfectaim " .. tostring(detail) end
            return true, false, "player.perfectaim failed: " .. tostring(detail)
        end

        -- Round 9: Gameplay-Effect apply/remove/toggle/has. One verb family
        -- covers every attribute-driven cheat (Max Health, resistances,
        -- stamina regen, damage multipliers, XP boosters, etc.) because the
        -- game's attribute system ONLY accepts mutations through the GE
        -- apply path -- see NOTES/cheats-to-revisit.md ??11 and the round
        -- 8.5 probe dump (ipc/probes/gameplay_effects/).
        --
        -- Ordering: the longest prefix must be matched first. The verb
        -- lengths are:
        --   player.ge.apply  = 15
        --   player.ge.remove = 16
        --   player.ge.toggle = 16
        --   player.ge.list   = 14
        --   player.ge.has    = 13   (this is a strict prefix of "has...")
        -- Round 56 added the CDO field editor:
        --   player.ge.cdo.dump  = 19
        --   player.ge.cdo.set   = 18
        --   player.ge.cdo.get   = 18
        --   player.ge.cdo.reset = 20
        -- Since all five share "player.ge." as a prefix, we check the
        -- specific tails via exact-length substring comparisons.

        -- Round 56: CDO editor verbs first (they all share the longer
        -- "player.ge.cdo." prefix and would otherwise be eaten by the
        -- shorter ge.apply / ge.remove checks below if any of them ever
        -- get a tail that lands on the same length).
        if line:sub(1, 20) == "player.ge.cdo.reset " or line == "player.ge.cdo.reset" then
            local arg = arg_after("player.ge.cdo.reset")
            if arg == "" then return true, false, "usage: player.ge.cdo.reset <ClassName>" end
            local ok, detail = feature_ge.cdo_reset(arg)
            if ok then return true, true, "ok player.ge.cdo.reset " .. tostring(detail) end
            return true, false, "player.ge.cdo.reset failed: " .. tostring(detail)
        end
        -- Round 56.1: chunked-dump fetch verb. Must be checked BEFORE
        -- the bare "player.ge.cdo.dump " prefix below since it shares
        -- the same first 19 characters.
        if line:sub(1, 25) == "player.ge.cdo.dump.chunk " then
            local rest = arg_after("player.ge.cdo.dump.chunk")
            local class_name, index = rest:match("^(%S+)%s+(%S+)$")
            if not class_name then
                return true, false, "usage: player.ge.cdo.dump.chunk <ClassName> <Index>"
            end
            local ok, detail = feature_ge.cdo_dump_chunk(class_name, index)
            -- Raw chunk body, no verb echo: keeps every byte of the
            -- 1024-byte mailbox available for JSON payload.
            if ok then return true, true, tostring(detail) end
            return true, false, "player.ge.cdo.dump.chunk failed: " .. tostring(detail)
        end
        if line:sub(1, 19) == "player.ge.cdo.dump " or line == "player.ge.cdo.dump" then
            local arg = arg_after("player.ge.cdo.dump")
            if arg == "" then return true, false, "usage: player.ge.cdo.dump <ClassName>" end
            local ok, detail = feature_ge.cdo_dump(arg)
            if ok then return true, true, "ok player.ge.cdo.dump " .. tostring(detail) end
            return true, false, "player.ge.cdo.dump failed: " .. tostring(detail)
        end
        if line:sub(1, 18) == "player.ge.cdo.set " then
            local rest = arg_after("player.ge.cdo.set")
            -- ClassName Field Value ; value may contain spaces, so split
            -- on the first two whitespace runs only.
            local class_name, path, value = rest:match("^(%S+)%s+(%S+)%s+(.+)$")
            if not class_name then
                return true, false, "usage: player.ge.cdo.set <ClassName> <FieldPath> <Value>"
            end
            local ok, detail = feature_ge.cdo_set(class_name, path, value)
            if ok then return true, true, "ok player.ge.cdo.set " .. tostring(detail) end
            return true, false, "player.ge.cdo.set failed: " .. tostring(detail)
        end
        if line:sub(1, 18) == "player.ge.cdo.get " then
            local rest = arg_after("player.ge.cdo.get")
            local class_name, path = rest:match("^(%S+)%s+(%S+)$")
            if not class_name then
                return true, false, "usage: player.ge.cdo.get <ClassName> <FieldPath>"
            end
            local ok, detail = feature_ge.cdo_get(class_name, path)
            if ok then return true, true, tostring(detail) end
            return true, false, "player.ge.cdo.get failed: " .. tostring(detail)
        end

        if line:sub(1, 16) == "player.ge.remove" then
            local arg = arg_after("player.ge.remove")
            if arg == "" then return true, false, "usage: player.ge.remove <ClassName>" end
            local ok, detail = feature_ge.remove_ge(arg)
            if ok then return true, true, "ok player.ge.remove " .. tostring(detail) end
            return true, false, "player.ge.remove failed: " .. tostring(detail)
        end
        if line:sub(1, 16) == "player.ge.toggle" then
            local rest = arg_after("player.ge.toggle")
            local class_name, value = rest:match("^(%S+)%s+(%S+)$")
            if not class_name then return true, false, "usage: player.ge.toggle <ClassName> <on|off>" end
            local ok, detail = feature_ge.toggle_ge(class_name, value)
            if ok then return true, true, "ok player.ge.toggle " .. tostring(detail) end
            return true, false, "player.ge.toggle failed: " .. tostring(detail)
        end
        if line:sub(1, 15) == "player.ge.apply" then
            local arg = arg_after("player.ge.apply")
            if arg == "" then return true, false, "usage: player.ge.apply <ClassName>" end
            local ok, detail = feature_ge.apply_ge(arg)
            if ok then return true, true, "ok player.ge.apply " .. tostring(detail) end
            return true, false, "player.ge.apply failed: " .. tostring(detail)
        end
        if line:sub(1, 14) == "player.ge.list" then
            local ok, detail = feature_ge.list_applied()
            if ok then return true, true, "ok player.ge.list " .. tostring(detail) end
            return true, false, "player.ge.list failed: " .. tostring(detail)
        end
        if line:sub(1, 13) == "player.ge.has" then
            local arg = arg_after("player.ge.has")
            if arg == "" then return true, false, "usage: player.ge.has <ClassName>" end
            local ok, detail = feature_ge.has_ge(arg)
            if ok then return true, true, tostring(detail) end
            return true, false, "player.ge.has failed: " .. tostring(detail)
        end

        -- Round 22: direct GAS attribute writes (player.attr.set/get).
        -- Bypasses the GE pipeline (which ??12 proved unreliable) and the
        -- per-component scalar fields (which ??5/??13/??17/??18/??23 all proved
        -- ineffective). Writes the live AttributeValues[i] / SharedAttribute
        -- Values[i] slot the game's combat/stamina/regen code reads on the
        -- next tick. See feature_attr.lua for the full rationale.
        --
        -- player.attr.set = 15
        -- player.attr.get = 15
        -- Both are unique with no shared prefixes against existing verbs.
        if line:sub(1, 15) == "player.attr.set" then
            local rest = arg_after("player.attr.set")
            local class_name, value = rest:match("^(%S+)%s+(%S+)$")
            if not class_name then return true, false, "usage: player.attr.set <ClassName> <value>" end
            local feature_attr = require("feature_attr")
            local ok, detail = feature_attr.set_attribute(class_name, value)
            if ok then return true, true, "ok player.attr.set " .. tostring(detail) end
            return true, false, "player.attr.set failed: " .. tostring(detail)
        end
        if line:sub(1, 15) == "player.attr.get" then
            local arg = arg_after("player.attr.get")
            if arg == "" then return true, false, "usage: player.attr.get <ClassName>" end
            local feature_attr = require("feature_attr")
            local ok, detail = feature_attr.get_attribute(arg)
            if ok then return true, true, tostring(detail) end
            return true, false, "player.attr.get failed: " .. tostring(detail)
        end

        -- Teleport tweaks
        if line:sub(1, 15) == "player.tp.delay" then
            local ok, detail = feature_player.set_tp_loading_delay(arg_after("player.tp.delay"))
            if ok then return true, true, "ok player.tp.delay " .. tostring(detail) end
            return true, false, "player.tp.delay failed: " .. tostring(detail)
        end
        if line:sub(1, 13) == "player.tp.vfx" then
            local ok, detail = feature_player.set_tp_vfx_delay(arg_after("player.tp.vfx"))
            if ok then return true, true, "ok player.tp.vfx " .. tostring(detail) end
            return true, false, "player.tp.vfx failed: " .. tostring(detail)
        end
        if line:sub(1, 17) == "player.tp.timeout" then
            local ok, detail = feature_player.set_tp_timeout(arg_after("player.tp.timeout"))
            if ok then return true, true, "ok player.tp.timeout " .. tostring(detail) end
            return true, false, "player.tp.timeout failed: " .. tostring(detail)
        end

        -- Round 11: new-capability cheats. Ordering rules applied (compound
        -- / longer verbs first, matching the rest of this file):
        --   player.mounts.unlockall       = 23   (not a prefix of anything)
        --   player.mount.invincible       = 23   (not a prefix of anything)
        --   player.spell.cancel           = 19
        --   player.revivedelay            = 18
        --   player.arrowrange             = 17
        --   player.aimpitch               = 15
        -- critchance + foliagerange dispatch removed in 11.5 (see header doc).
        -- player.unlock.corruptionshot + player.spells.* removed in round 12
        -- rollback (see NOTES/cheats-to-revisit.md ??16).
        -- None of these share prefixes with each other or with existing
        -- player.* verbs (verified by grep against the full verb list).
        if line:sub(1, 23) == "player.mounts.unlockall" then
            local ok, detail = feature_player.unlock_all_mounts(arg_after("player.mounts.unlockall"))
            if ok then return true, true, "ok player.mounts.unlockall " .. tostring(detail) end
            return true, false, "player.mounts.unlockall failed: " .. tostring(detail)
        end
        if line:sub(1, 23) == "player.mount.invincible" then
            local ok, detail = feature_player.set_mount_invincible(arg_after("player.mount.invincible"))
            if ok then return true, true, "ok player.mount.invincible " .. tostring(detail) end
            return true, false, "player.mount.invincible failed: " .. tostring(detail)
        end
        if line == "player.spell.cancel" or line:sub(1, 20) == "player.spell.cancel " then
            local ok, detail = feature_player_spells.cancel_spell()
            if ok then return true, true, "ok player.spell.cancel " .. tostring(detail) end
            return true, false, "player.spell.cancel failed: " .. tostring(detail)
        end
        -- Round 13 spell cheats. player.spells. (14) vs player.spell. (13) -- no
        -- overlap. Within player.spells.* the prefix lengths are:
        --   player.spells.continuouscast   (28)
        --   player.spells.zerocooldown     (26)
        --   player.spells.unlock           (20)
        -- None is a prefix of another so dispatch order is purely cosmetic;
        -- we keep them sorted longest-first per the project's house style.
        if line:sub(1, 28) == "player.spells.continuouscast" then
            local ok, detail = feature_player_spells.set_spells_continuouscast(arg_after("player.spells.continuouscast"))
            if ok then return true, true, "ok player.spells.continuouscast " .. tostring(detail) end
            return true, false, "player.spells.continuouscast failed: " .. tostring(detail)
        end
        if line:sub(1, 26) == "player.spells.zerocooldown" then
            local ok, detail = feature_player_spells.set_spells_zerocooldown(arg_after("player.spells.zerocooldown"))
            if ok then return true, true, "ok player.spells.zerocooldown " .. tostring(detail) end
            return true, false, "player.spells.zerocooldown failed: " .. tostring(detail)
        end
        if line:sub(1, 20) == "player.spells.unlock" then
            local ok, detail = feature_player_spells.set_spells_unlock(arg_after("player.spells.unlock"))
            if ok then return true, true, "ok player.spells.unlock " .. tostring(detail) end
            return true, false, "player.spells.unlock failed: " .. tostring(detail)
        end
        if line:sub(1, 18) == "player.revivedelay" then
            local ok, detail = feature_player.set_revive_delay(arg_after("player.revivedelay"))
            if ok then return true, true, "ok player.revivedelay " .. tostring(detail) end
            return true, false, "player.revivedelay failed: " .. tostring(detail)
        end
        if line:sub(1, 17) == "player.arrowrange" then
            local ok, detail = feature_player.set_arrow_range(arg_after("player.arrowrange"))
            if ok then return true, true, "ok player.arrowrange " .. tostring(detail) end
            return true, false, "player.arrowrange failed: " .. tostring(detail)
        end
        if line:sub(1, 15) == "player.aimpitch" then
            local ok, detail = feature_player.set_aim_pitch_unlock(arg_after("player.aimpitch"))
            if ok then return true, true, "ok player.aimpitch " .. tostring(detail) end
            return true, false, "player.aimpitch failed: " .. tostring(detail)
        end

        -- player.transmog.* : visual-only wearable overrides for testing the
        -- equipment appearance path. These verbs intentionally do not mutate
        -- Current*Wearable or inventory state; they only push or hide visuals
        -- on the live outfit mesh.
        if line == "player.transmog.status" or line:sub(1, #"player.transmog.status ") == "player.transmog.status " then
            local ok, detail = feature_transmog.status(arg_after("player.transmog.status"))
            if ok then return true, true, "ok player.transmog.status " .. tostring(detail) end
            return true, false, "player.transmog.status failed: " .. tostring(detail)
        end
        if line == "player.transmog.list" or line:sub(1, #"player.transmog.list ") == "player.transmog.list " then
            local ok, detail = feature_transmog.list(arg_after("player.transmog.list"))
            if ok then return true, true, "ok player.transmog.list " .. tostring(detail) end
            return true, false, "player.transmog.list failed: " .. tostring(detail)
        end
        if line == "player.transmog.capture" or line:sub(1, #"player.transmog.capture ") == "player.transmog.capture " then
            local ok, detail = feature_transmog.capture(arg_after("player.transmog.capture"))
            if ok then return true, true, "ok player.transmog.capture " .. tostring(detail) end
            return true, false, "player.transmog.capture failed: " .. tostring(detail)
        end
        if line:sub(1, #"player.transmog.apply ") == "player.transmog.apply " then
            local ok, detail = feature_transmog.apply(arg_after("player.transmog.apply"))
            if ok then return true, true, "ok player.transmog.apply " .. tostring(detail) end
            return true, false, "player.transmog.apply failed: " .. tostring(detail)
        end
        if line == "player.transmog.outfit" or line:sub(1, #"player.transmog.outfit ") == "player.transmog.outfit " then
            local ok, detail = feature_transmog.outfit(arg_after("player.transmog.outfit"))
            if ok then return true, true, "ok player.transmog.outfit " .. tostring(detail) end
            return true, false, "player.transmog.outfit failed: " .. tostring(detail)
        end
        if line == "player.transmog.hide" or line:sub(1, #"player.transmog.hide ") == "player.transmog.hide " then
            local ok, detail = feature_transmog.hide(arg_after("player.transmog.hide"))
            if ok then return true, true, "ok player.transmog.hide " .. tostring(detail) end
            return true, false, "player.transmog.hide failed: " .. tostring(detail)
        end
        if line == "player.transmog.clear" or line:sub(1, #"player.transmog.clear ") == "player.transmog.clear " then
            local ok, detail = feature_transmog.clear(arg_after("player.transmog.clear"))
            if ok then return true, true, "ok player.transmog.clear " .. tostring(detail) end
            return true, false, "player.transmog.clear failed: " .. tostring(detail)
        end
        if line == "player.transmog.reapply" or line:sub(1, #"player.transmog.reapply ") == "player.transmog.reapply " then
            local ok, detail = feature_transmog.reapply(arg_after("player.transmog.reapply"))
            if ok then return true, true, "ok player.transmog.reapply " .. tostring(detail) end
            return true, false, "player.transmog.reapply failed: " .. tostring(detail)
        end
        if line == "player.transmog.debug" or line:sub(1, #"player.transmog.debug ") == "player.transmog.debug " then
            local ok, detail = feature_transmog.debug(arg_after("player.transmog.debug"))
            if ok then return true, true, "ok player.transmog.debug " .. tostring(detail) end
            return true, false, "player.transmog.debug failed: " .. tostring(detail)
        end

        -- Reader: "player.get <key>" returns the raw field value so the WPF
        -- can prime its sliders on first open. Ack body is just the value.
        if line:sub(1, 10) == "player.get" then
            local key = arg_after("player.get")
            if key == "" then return true, false, "usage: player.get <key>" end
            local getters = {
                ["time"]         = feature_player.get_time_dilation,
                ["jump.count"]   = feature_player.get_jump_count,
                ["jump.hold"]    = feature_player.get_jump_hold,
                ["buildings"]    = feature_player.get_can_damage_buildings,
                ["tp.delay"]     = feature_player.get_tp_loading_delay,
                ["tp.vfx"]       = feature_player.get_tp_vfx_delay,
                ["tp.timeout"]   = feature_player.get_tp_timeout,
                ["health"]       = feature_player.get_health,
                ["maxhealth"]    = feature_player.get_max_health,
                ["walkspeed"]    = feature_player.get_walkspeed,
                ["jumpvel"]      = feature_player.get_jumpvel,
                ["gravity"]      = feature_player.get_gravity,
                ["aircontrol"]   = feature_player.get_air_control,
                ["speedmult"]    = feature_player.get_speed_mult,
                ["flyspeed"]     = feature_player.get_flyspeed,
                ["acceleration"] = feature_player.get_acceleration,
                ["hydration"]    = feature_player.get_hydration,
                ["sustenance"]   = feature_player.get_sustenance,
                ["endurance"]    = feature_player.get_endurance,
                ["toxicity"]     = feature_player.get_toxicity,
                ["stamina"]      = feature_player.get_stamina,
                ["maxstamina"]   = feature_player.get_max_stamina,
                ["stealth"]      = feature_player.get_stealth,
                -- Round 5 (potion.slots removed in round 7).
                ["durabilityloss"] = feature_player.get_no_durability_loss,
                ["magnet"]       = feature_player.get_magnet_range,
                ["fov"]          = feature_player.get_fov,
                ["silent"]       = feature_player.get_silent,
                ["surge"]        = feature_player.get_surge,
                -- Round 6
                ["parrywindow"]  = feature_player.get_parry_window,
                ["blockangle"]   = feature_player.get_block_angle,
                ["lockon"]       = feature_player.get_lockon_scale,
                -- Round 7
                ["respawninvul"] = feature_player.get_respawn_invul,
                ["wellrested"]   = feature_player.get_well_rested,
                ["poise"]        = feature_player.get_poise,
                ["perfectaim"]   = feature_player.get_perfect_aim,
                -- Round 11 (critchance + foliagerange removed in 11.5)
                ["mounts.unlocked"]      = feature_player.get_mounts_unlocked,
                ["mount.invincible"]     = feature_player.get_mount_invincible,
                ["aimpitch"]             = feature_player.get_aim_pitch_unlock,
                ["arrowrange"]           = feature_player.get_arrow_range,
                ["revivedelay"]          = feature_player.get_revive_delay,
            }
            local fn = getters[key]
            if not fn then return true, false, "unknown key: " .. key end
            local ok, detail = fn()
            if ok then return true, true, tostring(detail) end
            return true, false, "player.get failed: " .. tostring(detail)
        end

        return true, false, "unknown player.* verb"
    end

    return false, nil, nil
end

return M
