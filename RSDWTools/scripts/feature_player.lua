-- Player "cheats" feature: value writes and RPC calls on the local pawn.
--
-- Every verb here targets the local player character (the pawn returned by
-- feature_actor.get_local_pawn()). Field-name choices were validated against
-- a fresh introspection dump (Dumps/ipc/player/actor_info.json) so we know:
--
--   * the field/method *exists* on the pawn or its class chain, and
--   * its type matches what the UI sends (float / int32 / boolean).
--
-- Design contract:
--   * Every public function is called from the game thread. main.lua wraps
--     command_line_router.handle_line() in ExecuteInGameThread already, so
--     we do NOT wrap again here (wrapping would make the call async and we'd
--     lose the return value, which is how feature_actor.goto_actor originally
--     regressed with "actor.goto failed: nil").
--   * Every native touch is pcall-guarded. We cannot trap a native AV this
--     way (Lua pcall can't unwind the C stack) but we CAN trap Lua-level
--     binding errors (wrong arg type, missing getter, etc).
--   * Return shape is always (ok, detail_or_error):
--       ok=true  -> detail is a short human string for the ack ("ok <verb> <value>")
--       ok=false -> detail is an error string
--
-- The router layer wraps our return into the final ack string the WPF side
-- reads. So "ok, '1.5'" becomes "ack: ok player.time 1.5" on the wire.

local M = {}

-- ---------- Player stats/component wrappers ----------

function M.set_time_dilation(value_str)
    return require("feature_player_stats").set_time_dilation(value_str)
end

function M.set_jump_count(value_str)
    return require("feature_player_stats").set_jump_count(value_str)
end

function M.set_jump_hold(value_str)
    return require("feature_player_stats").set_jump_hold(value_str)
end

function M.set_can_damage_buildings(value_str)
    return require("feature_player_stats").set_can_damage_buildings(value_str)
end

function M.set_invisible(value_str)
    return require("feature_player_stats").set_invisible(value_str)
end

function M.set_soul_rift_immunity(value_str)
    return require("feature_player_stats").set_soul_rift_immunity(value_str)
end

function M.set_invincible(value_str)
    return require("feature_player_stats").set_invincible(value_str)
end

function M.set_immortal(value_str)
    return require("feature_player_stats").set_immortal(value_str)
end

function M.set_health(value_str)
    return require("feature_player_stats").set_health(value_str)
end

function M.heal_full()
    return require("feature_player_stats").heal_full()
end

function M.damage_self(value_str)
    return require("feature_player_stats").damage_self(value_str)
end

function M.set_fall_immune(value_str)
    return require("feature_player_stats").set_fall_immune(value_str)
end

function M.set_walkspeed(value_str)
    return require("feature_player_stats").set_walkspeed(value_str)
end

function M.set_jumpvel(value_str)
    return require("feature_player_stats").set_jumpvel(value_str)
end

function M.set_gravity(value_str)
    return require("feature_player_stats").set_gravity(value_str)
end

function M.set_air_control(value_str)
    return require("feature_player_stats").set_air_control(value_str)
end

function M.set_speed_mult(value_str)
    return require("feature_player_stats").set_speed_mult(value_str)
end

function M.set_movement_mode(value_str)
    return require("feature_player_stats").set_movement_mode(value_str)
end

function M.set_noclip(value_str)
    return require("feature_player_stats").set_noclip(value_str)
end

function M.set_flyspeed(value_str)
    return require("feature_player_stats").set_flyspeed(value_str)
end

function M.set_acceleration(value_str)
    return require("feature_player_stats").set_acceleration(value_str)
end

function M.get_health()
    return require("feature_player_stats").get_health()
end

function M.get_max_health()
    return require("feature_player_stats").get_max_health()
end

function M.get_walkspeed()
    return require("feature_player_stats").get_walkspeed()
end

function M.get_jumpvel()
    return require("feature_player_stats").get_jumpvel()
end

function M.get_gravity()
    return require("feature_player_stats").get_gravity()
end

function M.get_air_control()
    return require("feature_player_stats").get_air_control()
end

function M.get_speed_mult()
    return require("feature_player_stats").get_speed_mult()
end

function M.get_flyspeed()
    return require("feature_player_stats").get_flyspeed()
end

function M.get_acceleration()
    return require("feature_player_stats").get_acceleration()
end

function M.set_hydration(v)
    return require("feature_player_stats").set_hydration(v)
end

function M.set_sustenance(v)
    return require("feature_player_stats").set_sustenance(v)
end

function M.set_endurance(v)
    return require("feature_player_stats").set_endurance(v)
end

function M.set_toxicity(v)
    return require("feature_player_stats").set_toxicity(v)
end

function M.set_hydration_decaybuffer(v)
    return require("feature_player_stats").set_hydration_decaybuffer(v)
end

function M.set_sustenance_decaybuffer(v)
    return require("feature_player_stats").set_sustenance_decaybuffer(v)
end

function M.set_endurance_decaybuffer(v)
    return require("feature_player_stats").set_endurance_decaybuffer(v)
end

function M.refill_hydration()
    return require("feature_player_stats").refill_hydration()
end

function M.refill_sustenance()
    return require("feature_player_stats").refill_sustenance()
end

function M.refill_endurance()
    return require("feature_player_stats").refill_endurance()
end

function M.clear_toxicity()
    return require("feature_player_stats").clear_toxicity()
end

function M.set_stealth(value_str)
    return require("feature_player_stats").set_stealth(value_str)
end

function M.refill_stamina()
    return require("feature_player_stats").refill_stamina()
end

function M.wake_up()
    return require("feature_player_stats").wake_up()
end

function M.get_hydration()
    return require("feature_player_stats").get_hydration()
end

function M.get_sustenance()
    return require("feature_player_stats").get_sustenance()
end

function M.get_endurance()
    return require("feature_player_stats").get_endurance()
end

function M.get_toxicity()
    return require("feature_player_stats").get_toxicity()
end

function M.get_stamina()
    return require("feature_player_stats").get_stamina()
end

function M.get_max_stamina()
    return require("feature_player_stats").get_max_stamina()
end

function M.get_stealth()
    return require("feature_player_stats").get_stealth()
end

function M.set_tp_loading_delay(value_str)
    return require("feature_player_stats").set_tp_loading_delay(value_str)
end

function M.set_tp_vfx_delay(value_str)
    return require("feature_player_stats").set_tp_vfx_delay(value_str)
end

function M.set_tp_timeout(value_str)
    return require("feature_player_stats").set_tp_timeout(value_str)
end

function M.get_time_dilation()
    return require("feature_player_stats").get_time_dilation()
end

function M.get_jump_count()
    return require("feature_player_stats").get_jump_count()
end

function M.get_jump_hold()
    return require("feature_player_stats").get_jump_hold()
end

function M.get_can_damage_buildings()
    return require("feature_player_stats").get_can_damage_buildings()
end

function M.get_tp_loading_delay()
    return require("feature_player_stats").get_tp_loading_delay()
end

function M.get_tp_vfx_delay()
    return require("feature_player_stats").get_tp_vfx_delay()
end

function M.get_tp_timeout()
    return require("feature_player_stats").get_tp_timeout()
end

function M.set_no_durability_loss(value_str)
    return require("feature_player_stats").set_no_durability_loss(value_str)
end

function M.get_no_durability_loss()
    return require("feature_player_stats").get_no_durability_loss()
end

function M.set_magnet_range(value_str)
    return require("feature_player_stats").set_magnet_range(value_str)
end

function M.get_magnet_range()
    return require("feature_player_stats").get_magnet_range()
end

function M.set_fov(value_str)
    return require("feature_player_stats").set_fov(value_str)
end

function M.get_fov()
    return require("feature_player_stats").get_fov()
end

function M.set_silent(value_str)
    return require("feature_player_stats").set_silent(value_str)
end

function M.get_silent()
    return require("feature_player_stats").get_silent()
end

function M.set_surge(value_str)
    return require("feature_player_stats").set_surge(value_str)
end

function M.get_surge()
    return require("feature_player_stats").get_surge()
end

function M.set_parry_window(value_str)
    return require("feature_player_stats").set_parry_window(value_str)
end

function M.get_parry_window()
    return require("feature_player_stats").get_parry_window()
end

function M.set_block_angle(value_str)
    return require("feature_player_stats").set_block_angle(value_str)
end

function M.get_block_angle()
    return require("feature_player_stats").get_block_angle()
end

function M.set_lockon_scale(value_str)
    return require("feature_player_stats").set_lockon_scale(value_str)
end

function M.get_lockon_scale()
    return require("feature_player_stats").get_lockon_scale()
end

function M.set_respawn_invul(value_str)
    return require("feature_player_stats").set_respawn_invul(value_str)
end

function M.get_respawn_invul()
    return require("feature_player_stats").get_respawn_invul()
end

function M.set_well_rested(value_str)
    return require("feature_player_stats").set_well_rested(value_str)
end

function M.get_well_rested()
    return require("feature_player_stats").get_well_rested()
end

function M.set_poise(value_str)
    return require("feature_player_stats").set_poise(value_str)
end

function M.get_poise()
    return require("feature_player_stats").get_poise()
end

function M.set_perfect_aim(value_str)
    return require("feature_player_stats").set_perfect_aim(value_str)
end

function M.get_perfect_aim()
    return require("feature_player_stats").get_perfect_aim()
end

function M.unlock_all_mounts(value_str)
    return require("feature_player_stats").unlock_all_mounts(value_str)
end

function M.get_mounts_unlocked()
    return require("feature_player_stats").get_mounts_unlocked()
end

function M.set_mount_invincible(value_str)
    return require("feature_player_stats").set_mount_invincible(value_str)
end

function M.get_mount_invincible()
    return require("feature_player_stats").get_mount_invincible()
end

function M.set_aim_pitch_unlock(value_str)
    return require("feature_player_stats").set_aim_pitch_unlock(value_str)
end

function M.get_aim_pitch_unlock()
    return require("feature_player_stats").get_aim_pitch_unlock()
end

function M.set_arrow_range(value_str)
    return require("feature_player_stats").set_arrow_range(value_str)
end

function M.get_arrow_range()
    return require("feature_player_stats").get_arrow_range()
end

function M.set_revive_delay(value_str)
    return require("feature_player_stats").set_revive_delay(value_str)
end

function M.get_revive_delay()
    return require("feature_player_stats").get_revive_delay()
end

function M.cancel_spell()
    return require("feature_player_stats").cancel_spell()
end

function M.set_spells_unlock(value_str)
    return require("feature_player_stats").set_spells_unlock(value_str)
end

function M.set_spells_zerocooldown(value_str)
    return require("feature_player_stats").set_spells_zerocooldown(value_str)
end

function M.set_spells_continuouscast(value_str)
    return require("feature_player_stats").set_spells_continuouscast(value_str)
end

function M.comp_set(args_str)
    return require("feature_player_stats").comp_set(args_str)
end

function M.comp_get(args_str)
    return require("feature_player_stats").comp_get(args_str)
end
-- ---------- World spawn/class wrappers ----------

function M.summon(value_str)
    return require("feature_player_spawn").summon(value_str)
end

function M.load_class(value_str)
    return require("feature_player_spawn").load_class(value_str)
end

function M.spawn(value_str)
    return require("feature_player_spawn").spawn(value_str)
end

function M.spawn_transform(value_str)
    return require("feature_player_spawn").spawn_transform(value_str)
end

function M.spawn_safe(value_str)
    return require("feature_player_spawn").spawn_safe(value_str)
end

function M.spawn_item(value_str)
    return require("feature_player_spawn").spawn_item(value_str)
end

-- =============================================================================
-- player animation verbs
-- =============================================================================

function M.play_montage(value_str)
    return require("feature_player_anim").play_montage(value_str)
end

function M.stop_montage(value_str)
    return require("feature_player_anim").stop_montage(value_str)
end

function M.play_emote(value_str)
    return require("feature_player_anim").play_emote(value_str)
end

function M.attack_state(_value_str)
    return require("feature_player_attack").attack_state(_value_str)
end

function M.attack_data(value_str)
    return require("feature_player_attack").attack_data(value_str)
end

function M.attack_trace(value_str)
    return require("feature_player_attack").attack_trace(value_str)
end

function M.attack_perform(value_str)
    return require("feature_player_attack").attack_perform(value_str)
end

function M.play_attack(value_str)
    return require("feature_player_attack").play_attack(value_str)
end

function M.play_animation(value_str)
    return require("feature_player_anim").play_animation(value_str)
end

return M

