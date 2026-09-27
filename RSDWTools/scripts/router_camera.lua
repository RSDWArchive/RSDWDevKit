local support = require("router_support")
local lazy_feature = support.lazy_feature

local feature_camera = lazy_feature("feature_camera")
local feature_grab = lazy_feature("feature_grab")
local feature_oculus = lazy_feature("feature_oculus")
local feature_oculus_config = lazy_feature("feature_oculus_config")
local feature_oculus_clone = lazy_feature("feature_oculus_clone")
local feature_oculus_duplicate = lazy_feature("feature_oculus_duplicate")
local feature_oculus_input_guard = lazy_feature("feature_oculus_input_guard")
local feature_oculus_proxy = lazy_feature("feature_oculus_proxy")
local feature_oculus_transform = lazy_feature("feature_oculus_transform")
local feature_wheel_hook = lazy_feature("feature_wheel_hook")

local M = {}

local function safe_cancel_grab()
    if feature_oculus_proxy.is_active and feature_oculus_proxy.is_active() then
        return feature_oculus_proxy.place_cancel()
    end
    if feature_grab.safe_cancel then
        return feature_grab.safe_cancel()
    end
    if feature_grab.is_active and feature_grab.is_active() then
        return feature_grab.cancel()
    end
    return true, "not grabbing"
end

local function set_oculus_input_poll(active)
    local ok, detail = pcall(function()
        if feature_wheel_hook.set_oculus_active then
            return feature_wheel_hook.set_oculus_active(active == true)
        end
        return true, "wheel hook has no deferred Oculus gate"
    end)
    if not ok then
        print("[RSDWTools] Oculus input poll gate failed: " .. tostring(detail))
    end
end

local function release_oculus_input_guard(reason)
    pcall(function()
        if feature_oculus_input_guard.release_all then
            feature_oculus_input_guard.release_all(reason or "oculus.exit")
        end
    end)
end

function M.try_handle(line, handle_line)
    local route_line = handle_line or function()
        return false, "router callback missing"
    end
    -- ---- camera.debug.* + camera.grab.* + camera.lookat (top-level ; longest-prefix order) ----
    -- Must live OUTSIDE the actor.* block above ; the dispatcher gates that
    -- whole block on `line:sub(1,6) == "actor."`, so any camera.* line
    -- typed there would silently fall through. Keep these grouped here so
    -- the next refactor doesn't re-nest them by accident.
    --   camera.debug.status         report stock DebugCamera controller state
    --   camera.debug.enable         enable Unreal's stock DebugCamera
    --   camera.debug.disable        disable Unreal's stock DebugCamera
    --   camera.debug.toggle         toggle Unreal's stock DebugCamera
    --   camera.debug.force_restore  explicit fallback if stock disable fails
    --   camera.debug.speed <scale>  scale DebugCamera pawn movement speed
    --   camera.debug.display        toggle DebugCamera overlay
    --   camera.debug.selected       report DebugCamera selected actor
    --   camera.streaming.status     report DebugCamera + World Partition streaming state
    --   camera.streaming.scale <n> [range]  scale camera source shapes / WP grid range
    --   camera.streaming.reset      restore runtime streaming experiment snapshot
    --   camera.lod.status [radius] [limit]  count render components near camera
    --   camera.lod.force <radius> [lod] [limit]  disabled after Shipping crash reports
    --   camera.lod.reset            restore camera-local LOD experiment snapshot
    --   camera.rig.*                first DebugCamera-backed pose/path verbs
    --   camera.rig.roll.add/set/reset/step/status  hotkeyable roll controls
    --   camera.grab.release         drop in place
    --   camera.grab.cancel          drop and restore start transform
    --   camera.grab.status          report state
    --   camera.grab.mode <m>        m in {move,rot,z,scale}
    --   camera.grab.delta <signed>  one wheel-tick in the active mode
    --   camera.grab.safety <on|off|toggle|status> toggle unsafe target blocks
    --   camera.grab.rotate <signed> dedicated yaw nudge (mode-independent)
    --   camera.grab.start [name]    latch named (or look-at) actor
    --   camera.grab.item            latch/release runtime world item nearest reticle
    --   camera.lookat               probe what the camera trace hits
    --   camera.lookat.item          inspect runtime world item nearest reticle
    --   camera.oculus.clone         spawn same class as look-at actor and copy transform
    --   camera.oculus.preview       arm build preview from look-at building piece
    --   camera.oculus.duplicate     legacy alias for camera.oculus.preview
    --   camera.oculus.proxy.*       detached SM/SK proxy probe for safer actor manipulation
    --   camera.oculus.transform.inspect   inspect/capture actor under reticle
    --   camera.oculus.transform.capture   enable/disable passive transform capture
    --   camera.oculus.transform.reload ... re-read selected live actor transform
    --   camera.oculus.transform.apply ... apply edited transform to capture
    --   camera.destroy.lookat       destroy actor under the active camera reticle
    if line == "camera.debug.status" then
        local ok, detail = feature_camera.status()
        if ok then return true, true, "ok camera.debug.status " .. tostring(detail) end
        return true, false, "camera.debug.status failed: " .. tostring(detail)
    end
    if line == "camera.streaming.status" then
        local ok, detail = feature_camera.streaming_status()
        if ok then return true, true, "ok camera.streaming.status " .. tostring(detail) end
        return true, false, "camera.streaming.status failed: " .. tostring(detail)
    end
    if line == "camera.streaming.scale" or line:sub(1, 23) == "camera.streaming.scale " then
        local arg = line:sub(24):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.streaming_scale(arg)
        if ok then return true, true, "ok camera.streaming.scale " .. tostring(detail) end
        return true, false, "camera.streaming.scale failed: " .. tostring(detail)
    end
    if line == "camera.streaming.reset" then
        local ok, detail = feature_camera.streaming_reset()
        if ok then return true, true, "ok camera.streaming.reset " .. tostring(detail) end
        return true, false, "camera.streaming.reset failed: " .. tostring(detail)
    end
    if line == "camera.lod.status" or line:sub(1, 18) == "camera.lod.status " then
        local arg = line:sub(19):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.lod_status(arg)
        if ok then return true, true, "ok camera.lod.status " .. tostring(detail) end
        return true, false, "camera.lod.status failed: " .. tostring(detail)
    end
    if line == "camera.lod.force" or line:sub(1, 17) == "camera.lod.force " then
        local arg = line:sub(18):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.lod_force(arg)
        if ok then return true, true, "ok camera.lod.force " .. tostring(detail) end
        return true, false, "camera.lod.force failed: " .. tostring(detail)
    end
    if line == "camera.lod.reset" then
        local ok, detail = feature_camera.lod_reset()
        if ok then return true, true, "ok camera.lod.reset " .. tostring(detail) end
        return true, false, "camera.lod.reset failed: " .. tostring(detail)
    end
    if line == "camera.rig.status" then
        local ok, detail = feature_camera.rig_status()
        if ok then return true, true, "ok camera.rig.status " .. tostring(detail) end
        return true, false, "camera.rig.status failed: " .. tostring(detail)
    end
    if line == "camera.rig.start" or line:sub(1, 17) == "camera.rig.start " then
        local arg = line:sub(18):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_start(arg)
        if ok then return true, true, "ok camera.rig.start " .. tostring(detail) end
        return true, false, "camera.rig.start failed: " .. tostring(detail)
    end
    if line == "camera.rig.stop" then
        local ok, detail = feature_camera.rig_stop()
        if ok then return true, true, "ok camera.rig.stop " .. tostring(detail) end
        return true, false, "camera.rig.stop failed: " .. tostring(detail)
    end
    if line == "camera.rig.list" then
        local ok, detail = feature_camera.rig_list()
        if ok then return true, true, "ok camera.rig.list " .. tostring(detail) end
        return true, false, "camera.rig.list failed: " .. tostring(detail)
    end
    if line == "camera.rig.clear" then
        local ok, detail = feature_camera.rig_clear()
        if ok then return true, true, "ok camera.rig.clear " .. tostring(detail) end
        return true, false, "camera.rig.clear failed: " .. tostring(detail)
    end
    if line:sub(1, 19) == "camera.rig.pose.set" then
        local arg = line:sub(20):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_pose_set(arg)
        if ok then return true, true, "ok camera.rig.pose.set " .. tostring(detail) end
        return true, false, "camera.rig.pose.set failed: " .. tostring(detail)
    end
    if line == "camera.rig.poses.file" or line:sub(1, 22) == "camera.rig.poses.file " then
        local arg = line:sub(23):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_poses_file(arg)
        if ok then return true, true, "ok camera.rig.poses.file " .. tostring(detail) end
        return true, false, "camera.rig.poses.file failed: " .. tostring(detail)
    end
    if line:sub(1, 17) == "camera.rig.delete" then
        local arg = line:sub(18):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_delete(arg)
        if ok then return true, true, "ok camera.rig.delete " .. tostring(detail) end
        return true, false, "camera.rig.delete failed: " .. tostring(detail)
    end
    if line:sub(1, 18) == "camera.rig.capture" then
        local arg = line:sub(19):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_capture(arg)
        if ok then return true, true, "ok camera.rig.capture " .. tostring(detail) end
        return true, false, "camera.rig.capture failed: " .. tostring(detail)
    end
    if line == "camera.rig.goto.file" or line:sub(1, 21) == "camera.rig.goto.file " then
        local arg = line:sub(22):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_goto_file(arg)
        if ok then return true, true, "ok camera.rig.goto.file " .. tostring(detail) end
        return true, false, "camera.rig.goto.file failed: " .. tostring(detail)
    end
    if line:sub(1, 15) == "camera.rig.goto" then
        local arg = line:sub(16):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_goto(arg)
        if ok then return true, true, "ok camera.rig.goto " .. tostring(detail) end
        return true, false, "camera.rig.goto failed: " .. tostring(detail)
    end
    if line == "camera.rig.play.stop" then
        local ok, detail = feature_camera.rig_play_stop()
        if ok then return true, true, "ok camera.rig.play.stop " .. tostring(detail) end
        return true, false, "camera.rig.play.stop failed: " .. tostring(detail)
    end
    if line == "camera.rig.play.file" or line:sub(1, 21) == "camera.rig.play.file " then
        local arg = line:sub(22):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_play_file(arg)
        if ok then return true, true, "ok camera.rig.play.file " .. tostring(detail) end
        return true, false, "camera.rig.play.file failed: " .. tostring(detail)
    end
    if line == "camera.rig.play.chain" or line:sub(1, 22) == "camera.rig.play.chain " then
        local arg = line:sub(23):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_play_chain(arg)
        if ok then return true, true, "ok camera.rig.play.chain " .. tostring(detail) end
        return true, false, "camera.rig.play.chain failed: " .. tostring(detail)
    end
    if line:sub(1, 15) == "camera.rig.play" then
        local arg = line:sub(16):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_play(arg)
        if ok then return true, true, "ok camera.rig.play " .. tostring(detail) end
        return true, false, "camera.rig.play failed: " .. tostring(detail)
    end
    if line:sub(1, 14) == "camera.rig.fov" then
        local arg = line:sub(15):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_fov(arg)
        if ok then return true, true, "ok camera.rig.fov " .. tostring(detail) end
        return true, false, "camera.rig.fov failed: " .. tostring(detail)
    end
    if line == "camera.rig.roll.status" then
        local ok, detail = feature_camera.rig_roll_status()
        if ok then return true, true, "ok camera.rig.roll.status " .. tostring(detail) end
        return true, false, "camera.rig.roll.status failed: " .. tostring(detail)
    end
    if line == "camera.rig.roll.reset" then
        local ok, detail = feature_camera.rig_roll_reset()
        if ok then return true, true, "ok camera.rig.roll.reset " .. tostring(detail) end
        return true, false, "camera.rig.roll.reset failed: " .. tostring(detail)
    end
    if line == "camera.rig.roll.step" or line:sub(1, 21) == "camera.rig.roll.step " then
        local arg = line:sub(22):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_roll_step(arg)
        if ok then return true, true, "ok camera.rig.roll.step " .. tostring(detail) end
        return true, false, "camera.rig.roll.step failed: " .. tostring(detail)
    end
    if line == "camera.rig.roll.add" or line:sub(1, 20) == "camera.rig.roll.add " then
        local arg = line:sub(21):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_roll_add(arg)
        if ok then return true, true, "ok camera.rig.roll.add " .. tostring(detail) end
        return true, false, "camera.rig.roll.add failed: " .. tostring(detail)
    end
    if line == "camera.rig.roll.set" or line:sub(1, 20) == "camera.rig.roll.set " then
        local arg = line:sub(21):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_roll_set(arg)
        if ok then return true, true, "ok camera.rig.roll.set " .. tostring(detail) end
        return true, false, "camera.rig.roll.set failed: " .. tostring(detail)
    end
    if line == "camera.fps" or line:sub(1, 11) == "camera.fps " then
        local arg = line:sub(12):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.fps(arg)
        if ok then return true, true, "ok camera.fps " .. tostring(detail) end
        return true, false, "camera.fps failed: " .. tostring(detail)
    end
    if line == "camera.vsync" or line:sub(1, 13) == "camera.vsync " then
        local arg = line:sub(14):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.vsync(arg)
        if ok then return true, true, "ok camera.vsync " .. tostring(detail) end
        return true, false, "camera.vsync failed: " .. tostring(detail)
    end
    if line == "camera.rig.lookat" or line:sub(1, 18) == "camera.rig.lookat " then
        local arg = line:sub(19):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_camera.rig_lookat(arg)
        if ok then return true, true, "ok camera.rig.lookat " .. tostring(detail) end
        return true, false, "camera.rig.lookat failed: " .. tostring(detail)
    end
    if line == "camera.debug.enable" then
        local ok, detail = feature_camera.enable()
        if ok then return true, true, "ok camera.debug.enable " .. tostring(detail) end
        return true, false, "camera.debug.enable failed: " .. tostring(detail)
    end
    if line == "camera.debug.disable" then
        local ok, detail = feature_camera.disable()
        if ok then return true, true, "ok camera.debug.disable " .. tostring(detail) end
        return true, false, "camera.debug.disable failed: " .. tostring(detail)
    end
    if line == "camera.debug.toggle" then
        local ok, detail = feature_camera.toggle()
        if ok then return true, true, "ok camera.debug.toggle " .. tostring(detail) end
        return true, false, "camera.debug.toggle failed: " .. tostring(detail)
    end
    if line == "camera.debug.force_restore" then
        local ok, detail = feature_camera.force_restore()
        if ok then return true, true, "ok camera.debug.force_restore " .. tostring(detail) end
        return true, false, "camera.debug.force_restore failed: " .. tostring(detail)
    end
    if line == "camera.debug.display" then
        local ok, detail = feature_camera.display()
        if ok then return true, true, "ok camera.debug.display " .. tostring(detail) end
        return true, false, "camera.debug.display failed: " .. tostring(detail)
    end
    if line == "camera.debug.selected" then
        local ok, detail = feature_camera.selected()
        if ok then return true, true, "ok camera.debug.selected " .. tostring(detail) end
        return true, false, "camera.debug.selected failed: " .. tostring(detail)
    end
    if line == "camera.debug.speed" or line:sub(1, 19) == "camera.debug.speed " then
        local arg = line:sub(20):match("^%s*(.-)%s*$") or ""
        if arg == "" then return true, false, "usage: camera.debug.speed <scale>" end
        local ok, detail = feature_camera.speed(arg)
        if ok then return true, true, "ok camera.debug.speed " .. tostring(detail) end
        return true, false, "camera.debug.speed failed: " .. tostring(detail)
    end
    if line == "camera.oculus.status" then
        local ok, detail = feature_oculus.status()
        if ok then return true, true, "ok camera.oculus.status " .. tostring(detail) end
        return true, false, "camera.oculus.status failed: " .. tostring(detail)
    end
    if line == "camera.oculus.start" then
        local ok, detail = feature_oculus.start()
        if ok then
            local active_ok, active_detail = feature_oculus.require_state("active")
            if not active_ok then
                return true, false, "camera.oculus.start init blocked: " .. tostring(active_detail)
            end
            set_oculus_input_poll(true)
            local init_ok, init_detail = feature_oculus_config.run_init(function(cmd)
                return route_line(cmd)
            end)
            if init_ok then
                local repair_ok, repair_detail = feature_oculus.repair_camera_after_modal("oculus.start")
                local repair_detail_text = repair_ok and tostring(repair_detail) or "camera repair skipped"
                local help_ok, help_detail = feature_oculus_config.show_hotkey_help(function(cmd)
                    return route_line(cmd)
                end)
                if help_ok then return true, true, "ok camera.oculus.start " .. tostring(detail) .. "; " .. tostring(init_detail) .. "; " .. tostring(repair_detail_text) .. "; " .. tostring(help_detail) end
                return true, false, "camera.oculus.start help failed: " .. tostring(help_detail)
            end
            return true, false, "camera.oculus.start init failed: " .. tostring(init_detail)
        end
        return true, false, "camera.oculus.start failed: " .. tostring(detail)
    end
    if line == "camera.oculus.help" or line:sub(1, 19) == "camera.oculus.help " then
        local arg = line:sub(20):match("^%s*(.-)%s*$") or ""
        local ok, detail
        if arg == "" then
            ok, detail = feature_oculus_config.set_hotkey_help_visibility("on")
        else
            ok, detail = feature_oculus_config.set_hotkey_help_visibility(arg)
        end
        if ok then return true, true, "ok camera.oculus.help " .. tostring(detail) end
        return true, false, "camera.oculus.help failed: " .. tostring(detail)
    end
    if line == "camera.oculus.umg" or line:sub(1, 18) == "camera.oculus.umg " then
        local arg = line:sub(19):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_config.set_hotkey_help_visibility(arg)
        if ok then return true, true, "ok camera.oculus.umg " .. tostring(detail) end
        return true, false, "camera.oculus.umg failed: " .. tostring(detail)
    end
    if line == "camera.oculus.init" then
        local active_ok, active_detail = feature_oculus.require_state("active")
        if not active_ok then return true, false, "camera.oculus.init failed: " .. tostring(active_detail) end
        set_oculus_input_poll(true)
        local init_ok, init_detail = feature_oculus_config.run_init(function(cmd)
            return route_line(cmd)
        end)
        if init_ok then
            local repair_ok, repair_detail = feature_oculus.repair_camera_after_modal("oculus.init")
            local repair_detail_text = repair_ok and tostring(repair_detail) or "camera repair skipped"
            local help_ok, help_detail = feature_oculus_config.show_hotkey_help(function(cmd)
                return route_line(cmd)
            end)
            if help_ok then return true, true, "ok camera.oculus.init " .. tostring(init_detail) .. "; " .. tostring(repair_detail_text) .. "; " .. tostring(help_detail) end
            return true, false, "camera.oculus.init help failed: " .. tostring(help_detail)
        end
        return true, false, "camera.oculus.init failed: " .. tostring(init_detail)
    end
    if line == "camera.oculus.stop" then
        set_oculus_input_poll(false)
        release_oculus_input_guard("oculus.stop")
        safe_cancel_grab()
        local freeze_ok, freeze_detail = feature_oculus.freeze_stop("oculus.stop")
        local ok, detail = feature_oculus.stop()
        if ok then
            local exit_ok, exit_detail = feature_oculus_config.run_exit(function(cmd)
                return route_line(cmd)
            end)
            feature_oculus_config.hide_hotkey_help()
            if exit_ok and freeze_ok then return true, true, "ok camera.oculus.stop " .. tostring(detail) .. "; " .. tostring(freeze_detail) .. "; " .. tostring(exit_detail) end
            if not freeze_ok then return true, false, "camera.oculus.stop freeze restore failed: " .. tostring(freeze_detail) end
            return true, false, "camera.oculus.stop exit failed: " .. tostring(exit_detail)
        end
        return true, false, "camera.oculus.stop failed: " .. tostring(detail)
    end
    if line == "camera.oculus.exit" then
        set_oculus_input_poll(false)
        release_oculus_input_guard("oculus.exit")
        safe_cancel_grab()
        local freeze_ok, freeze_detail = feature_oculus.freeze_stop("oculus.exit")
        local ok, detail = feature_oculus_config.run_exit(function(cmd)
            return route_line(cmd)
        end, true)
        feature_oculus_config.hide_hotkey_help()
        if ok and freeze_ok then return true, true, "ok camera.oculus.exit " .. tostring(freeze_detail) .. "; " .. tostring(detail) end
        if not freeze_ok then return true, false, "camera.oculus.exit freeze restore failed: " .. tostring(freeze_detail) end
        return true, false, "camera.oculus.exit failed: " .. tostring(detail)
    end
    if line == "camera.oculus.toggle" then
        local was_active = feature_oculus.require_state("active")
        if was_active then
            set_oculus_input_poll(false)
            release_oculus_input_guard("oculus.toggle.off")
            safe_cancel_grab()
            feature_oculus.freeze_stop("oculus.toggle.off")
        end
        local ok, detail = feature_oculus.toggle()
        if ok then
            local active_ok = feature_oculus.require_state("active")
            if active_ok then
                set_oculus_input_poll(true)
                local init_ok, init_detail = feature_oculus_config.run_init(function(cmd)
                    return route_line(cmd)
                end)
                if not init_ok then return true, false, "camera.oculus.toggle init failed: " .. tostring(init_detail) end
                local repair_ok, repair_detail = feature_oculus.repair_camera_after_modal("oculus.toggle")
                local repair_detail_text = repair_ok and tostring(repair_detail) or "camera repair skipped"
                feature_oculus_config.show_hotkey_help(function(cmd)
                    return route_line(cmd)
                end)
                detail = tostring(detail) .. "; " .. tostring(init_detail) .. "; " .. tostring(repair_detail_text)
            else
                set_oculus_input_poll(false)
                local exit_ok, exit_detail = feature_oculus_config.run_exit(function(cmd)
                    return route_line(cmd)
                end)
                feature_oculus_config.hide_hotkey_help()
                if not exit_ok then return true, false, "camera.oculus.toggle exit failed: " .. tostring(exit_detail) end
                detail = tostring(detail) .. "; " .. tostring(exit_detail)
            end
            return true, true, "ok camera.oculus.toggle " .. tostring(detail)
        end
        return true, false, "camera.oculus.toggle failed: " .. tostring(detail)
    end
    if line == "camera.oculus.require" or line:sub(1, 22) == "camera.oculus.require " then
        local arg = line:sub(23):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus.require_state(arg)
        if ok then return true, true, "ok camera.oculus.require " .. tostring(detail) end
        return true, false, "camera.oculus.require failed: " .. tostring(detail)
    end
    if line == "camera.oculus.speed" or line:sub(1, 20) == "camera.oculus.speed " then
        local arg = line:sub(21):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus.speed(arg)
        if ok then return true, true, "ok camera.oculus.speed " .. tostring(detail) end
        return true, false, "camera.oculus.speed failed: " .. tostring(detail)
    end
    if line == "camera.oculus.speed.reapply" then
        local ok, detail = feature_oculus.reapply_speed("")
        if ok then return true, true, "ok camera.oculus.speed.reapply " .. tostring(detail) end
        return true, false, "camera.oculus.speed.reapply failed: " .. tostring(detail)
    end
    if line == "camera.oculus.freeze.settings" or line:sub(1, 30) == "camera.oculus.freeze.settings " then
        local arg = line:sub(31):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus.freeze_settings(arg)
        if ok then return true, true, "ok camera.oculus.freeze.settings " .. tostring(detail) end
        return true, false, "camera.oculus.freeze.settings failed: " .. tostring(detail)
    end
    if line == "camera.oculus.freeze.start" or line:sub(1, 27) == "camera.oculus.freeze.start " then
        local arg = line:sub(28):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus.freeze_start(arg)
        if ok then return true, true, "ok camera.oculus.freeze.start " .. tostring(detail) end
        return true, false, "camera.oculus.freeze.start failed: " .. tostring(detail)
    end
    if line == "camera.oculus.freeze.stop" or line:sub(1, 26) == "camera.oculus.freeze.stop " then
        local arg = line:sub(27):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus.freeze_stop(arg)
        if ok then return true, true, "ok camera.oculus.freeze.stop " .. tostring(detail) end
        return true, false, "camera.oculus.freeze.stop failed: " .. tostring(detail)
    end
    if line == "camera.oculus.freeze.status" then
        local ok, detail = feature_oculus.freeze_status()
        if ok then return true, true, "ok camera.oculus.freeze.status " .. tostring(detail) end
        return true, false, "camera.oculus.freeze.status failed: " .. tostring(detail)
    end
    if line == "camera.oculus.freeze.speed" or line:sub(1, 27) == "camera.oculus.freeze.speed " then
        local arg = line:sub(28):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus.freeze_speed(arg)
        if ok then return true, true, "ok camera.oculus.freeze.speed " .. tostring(detail) end
        return true, false, "camera.oculus.freeze.speed failed: " .. tostring(detail)
    end
    if line == "camera.oculus.pause" or line:sub(1, 20) == "camera.oculus.pause " then
        local arg = line:sub(21):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus.pause(arg)
        if ok then return true, true, "ok camera.oculus.pause " .. tostring(detail) end
        return true, false, "camera.oculus.pause failed: " .. tostring(detail)
    end
    if line == "camera.oculus.pause.status" then
        local ok, detail = feature_oculus.pause_status()
        if ok then return true, true, "ok camera.oculus.pause.status " .. tostring(detail) end
        return true, false, "camera.oculus.pause.status failed: " .. tostring(detail)
    end
    if line == "camera.oculus.distance" or line:sub(1, 23) == "camera.oculus.distance " then
        local arg = line:sub(24):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus.distance(arg)
        if ok then return true, true, "ok camera.oculus.distance " .. tostring(detail) end
        return true, false, "camera.oculus.distance failed: " .. tostring(detail)
    end
    if line == "camera.oculus.vignette" or line:sub(1, 23) == "camera.oculus.vignette " then
        local arg = line:sub(24):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus.vignette(arg)
        if ok then return true, true, "ok camera.oculus.vignette " .. tostring(detail) end
        return true, false, "camera.oculus.vignette failed: " .. tostring(detail)
    end
    if line == "camera.oculus.watermark" or line:sub(1, 24) == "camera.oculus.watermark " then
        local arg = line:sub(25):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus.watermark(arg)
        if ok then return true, true, "ok camera.oculus.watermark " .. tostring(detail) end
        return true, false, "camera.oculus.watermark failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.inspect" then
        local ok, detail = feature_oculus_proxy.preview_inspect()
        if ok then return true, true, "ok camera.oculus.preview.inspect " .. tostring(detail) end
        return true, false, "camera.oculus.preview.inspect failed: " .. tostring(detail)
    end
    local preview_host_audit_prefix = "camera.oculus.preview.host.audit"
    if line == preview_host_audit_prefix or line:sub(1, #preview_host_audit_prefix + 1) == preview_host_audit_prefix .. " " then
        local arg = line:sub(#preview_host_audit_prefix + 2):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_proxy.preview_host_audit(arg)
        if ok then return true, true, "ok camera.oculus.preview.host.audit " .. tostring(detail) end
        return true, false, "camera.oculus.preview.host.audit failed: " .. tostring(detail)
    end
    local preview_move_capture_prefix = "camera.oculus.preview.move.capture"
    if line == preview_move_capture_prefix or line:sub(1, #preview_move_capture_prefix + 1) == preview_move_capture_prefix .. " " then
        local arg = line:sub(#preview_move_capture_prefix + 2):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_proxy.preview_move_capture(arg)
        if ok then return true, true, "ok camera.oculus.preview.move.capture " .. tostring(detail) end
        return true, false, "camera.oculus.preview.move.capture failed: " .. tostring(detail)
    end
    local preview_move_start_prefix = "camera.oculus.preview.move.start"
    if line == preview_move_start_prefix or line:sub(1, #preview_move_start_prefix + 1) == preview_move_start_prefix .. " " then
        local arg = line:sub(#preview_move_start_prefix + 2):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_proxy.preview_move_start(arg)
        if ok then return true, true, "ok camera.oculus.preview.move.start " .. tostring(detail) end
        return true, false, "camera.oculus.preview.move.start failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.move.status" then
        local ok, detail = feature_oculus_proxy.preview_move_status()
        if ok then return true, true, "ok camera.oculus.preview.move.status " .. tostring(detail) end
        return true, false, "camera.oculus.preview.move.status failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.move.confirm" then
        local ok, detail = feature_oculus_proxy.preview_move_confirm()
        if ok then return true, true, "ok camera.oculus.preview.move.confirm " .. tostring(detail) end
        return true, false, "camera.oculus.preview.move.confirm failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.move.cancel" then
        local ok, detail = feature_oculus_proxy.preview_move_cancel()
        if ok then return true, true, "ok camera.oculus.preview.move.cancel " .. tostring(detail) end
        return true, false, "camera.oculus.preview.move.cancel failed: " .. tostring(detail)
    end
    local preview_swap_start_prefix = "camera.oculus.preview.swap.start"
    if line == preview_swap_start_prefix or line:sub(1, #preview_swap_start_prefix + 1) == preview_swap_start_prefix .. " " then
        local arg = line:sub(#preview_swap_start_prefix + 2):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_proxy.preview_swap_start(arg)
        if ok then return true, true, "ok camera.oculus.preview.swap.start " .. tostring(detail) end
        return true, false, "camera.oculus.preview.swap.start failed: " .. tostring(detail)
    end
    local preview_component_start_prefix = "camera.oculus.preview.component.start"
    if line == preview_component_start_prefix or line:sub(1, #preview_component_start_prefix + 1) == preview_component_start_prefix .. " " then
        local arg = line:sub(#preview_component_start_prefix + 2):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_proxy.preview_component_start(arg)
        if ok then return true, true, "ok camera.oculus.preview.component.start " .. tostring(detail) end
        return true, false, "camera.oculus.preview.component.start failed: " .. tostring(detail)
    end
    local preview_component_capture_prefix = "camera.oculus.preview.component.capture"
    if line == preview_component_capture_prefix or line:sub(1, #preview_component_capture_prefix + 1) == preview_component_capture_prefix .. " " then
        local arg = line:sub(#preview_component_capture_prefix + 2):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_proxy.preview_component_capture(arg)
        if ok then return true, true, "ok camera.oculus.preview.component.capture " .. tostring(detail) end
        return true, false, "camera.oculus.preview.component.capture failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.component.arm" then
        local ok, detail = feature_oculus_proxy.preview_component_arm()
        if ok then return true, true, "ok camera.oculus.preview.component.arm " .. tostring(detail) end
        return true, false, "camera.oculus.preview.component.arm failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.component.resolve" then
        local ok, detail = feature_oculus_proxy.preview_component_resolve()
        if ok then return true, true, "ok camera.oculus.preview.component.resolve " .. tostring(detail) end
        return true, false, "camera.oculus.preview.component.resolve failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.component.exit" then
        local ok, detail = feature_oculus_proxy.preview_component_exit()
        if ok then return true, true, "ok camera.oculus.preview.component.exit " .. tostring(detail) end
        return true, false, "camera.oculus.preview.component.exit failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.component.enter" then
        local ok, detail = feature_oculus_proxy.preview_component_enter()
        if ok then return true, true, "ok camera.oculus.preview.component.enter " .. tostring(detail) end
        return true, false, "camera.oculus.preview.component.enter failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.component.select" then
        local ok, detail = feature_oculus_proxy.preview_component_select()
        if ok then return true, true, "ok camera.oculus.preview.component.select " .. tostring(detail) end
        return true, false, "camera.oculus.preview.component.select failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.component.preview" then
        local ok, detail = feature_oculus_proxy.preview_component_preview()
        if ok then return true, true, "ok camera.oculus.preview.component.preview " .. tostring(detail) end
        return true, false, "camera.oculus.preview.component.preview failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.component.create" then
        local ok, detail = feature_oculus_proxy.preview_component_create()
        if ok then return true, true, "ok camera.oculus.preview.component.create " .. tostring(detail) end
        return true, false, "camera.oculus.preview.component.create failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.component.mesh" then
        local ok, detail = feature_oculus_proxy.preview_component_mesh()
        if ok then return true, true, "ok camera.oculus.preview.component.mesh " .. tostring(detail) end
        return true, false, "camera.oculus.preview.component.mesh failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.component.attach" then
        local ok, detail = feature_oculus_proxy.preview_component_attach()
        if ok then return true, true, "ok camera.oculus.preview.component.attach " .. tostring(detail) end
        return true, false, "camera.oculus.preview.component.attach failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.component.register" then
        local ok, detail = feature_oculus_proxy.preview_component_register()
        if ok then return true, true, "ok camera.oculus.preview.component.register " .. tostring(detail) end
        return true, false, "camera.oculus.preview.component.register failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.component.hidehost" then
        local ok, detail = feature_oculus_proxy.preview_component_hidehost()
        if ok then return true, true, "ok camera.oculus.preview.component.hidehost " .. tostring(detail) end
        return true, false, "camera.oculus.preview.component.hidehost failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.component.finish" then
        local ok, detail = feature_oculus_proxy.preview_component_finish()
        if ok then return true, true, "ok camera.oculus.preview.component.finish " .. tostring(detail) end
        return true, false, "camera.oculus.preview.component.finish failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.component.apply" then
        local ok, detail = feature_oculus_proxy.preview_component_apply()
        if ok then return true, true, "ok camera.oculus.preview.component.apply " .. tostring(detail) end
        return true, false, "camera.oculus.preview.component.apply failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.component.status" then
        local ok, detail = feature_oculus_proxy.preview_component_status()
        if ok then return true, true, "ok camera.oculus.preview.component.status " .. tostring(detail) end
        return true, false, "camera.oculus.preview.component.status failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.component.confirm" then
        local ok, detail = feature_oculus_proxy.preview_component_confirm()
        if ok then return true, true, "ok camera.oculus.preview.component.confirm " .. tostring(detail) end
        return true, false, "camera.oculus.preview.component.confirm failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.component.cancel" then
        local ok, detail = feature_oculus_proxy.preview_component_cancel()
        if ok then return true, true, "ok camera.oculus.preview.component.cancel " .. tostring(detail) end
        return true, false, "camera.oculus.preview.component.cancel failed: " .. tostring(detail)
    end
    local preview_swap_capture_prefix = "camera.oculus.preview.swap.capture"
    if line == preview_swap_capture_prefix or line:sub(1, #preview_swap_capture_prefix + 1) == preview_swap_capture_prefix .. " " then
        local arg = line:sub(#preview_swap_capture_prefix + 2):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_proxy.preview_swap_capture(arg)
        if ok then return true, true, "ok camera.oculus.preview.swap.capture " .. tostring(detail) end
        return true, false, "camera.oculus.preview.swap.capture failed: " .. tostring(detail)
    end
    local preview_swap_host_prefix = "camera.oculus.preview.swap.host"
    if line == preview_swap_host_prefix or line:sub(1, #preview_swap_host_prefix + 1) == preview_swap_host_prefix .. " " then
        local arg = line:sub(#preview_swap_host_prefix + 2):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_proxy.preview_swap_host(arg)
        if ok then return true, true, "ok camera.oculus.preview.swap.host " .. tostring(detail) end
        return true, false, "camera.oculus.preview.swap.host failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.swap.arm" then
        local ok, detail = feature_oculus_proxy.preview_swap_arm()
        if ok then return true, true, "ok camera.oculus.preview.swap.arm " .. tostring(detail) end
        return true, false, "camera.oculus.preview.swap.arm failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.swap.apply" then
        local ok, detail = feature_oculus_proxy.preview_swap_apply()
        if ok then return true, true, "ok camera.oculus.preview.swap.apply " .. tostring(detail) end
        return true, false, "camera.oculus.preview.swap.apply failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.swap.status" then
        local ok, detail = feature_oculus_proxy.preview_swap_status()
        if ok then return true, true, "ok camera.oculus.preview.swap.status " .. tostring(detail) end
        return true, false, "camera.oculus.preview.swap.status failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.swap.debug" then
        local ok, detail = feature_oculus_proxy.preview_swap_debug()
        if ok then return true, true, "ok camera.oculus.preview.swap.debug " .. tostring(detail) end
        return true, false, "camera.oculus.preview.swap.debug failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.swap.xform" then
        local ok, detail = feature_oculus_proxy.preview_swap_xform()
        if ok then return true, true, "ok camera.oculus.preview.swap.xform " .. tostring(detail) end
        return true, false, "camera.oculus.preview.swap.xform failed: " .. tostring(detail)
    end
    local preview_swap_skelroute_prefix = "camera.oculus.preview.swap.skelroute"
    if line == preview_swap_skelroute_prefix or line:sub(1, #preview_swap_skelroute_prefix + 1) == preview_swap_skelroute_prefix .. " " then
        local arg = line:sub(#preview_swap_skelroute_prefix + 2):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_proxy.preview_swap_skelroute(arg)
        if ok then return true, true, "ok camera.oculus.preview.swap.skelroute " .. tostring(detail) end
        return true, false, "camera.oculus.preview.swap.skelroute failed: " .. tostring(detail)
    end
    local preview_swap_anim_prefix = "camera.oculus.preview.swap.anim"
    if line == preview_swap_anim_prefix or line:sub(1, #preview_swap_anim_prefix + 1) == preview_swap_anim_prefix .. " " then
        local arg = line:sub(#preview_swap_anim_prefix + 2):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_proxy.preview_swap_anim(arg)
        if ok then return true, true, "ok camera.oculus.preview.swap.anim " .. tostring(detail) end
        return true, false, "camera.oculus.preview.swap.anim failed: " .. tostring(detail)
    end
    local preview_swap_cleanup_prefix = "camera.oculus.preview.swap.cleanup"
    if line == preview_swap_cleanup_prefix or line:sub(1, #preview_swap_cleanup_prefix + 1) == preview_swap_cleanup_prefix .. " " then
        local arg = line:sub(#preview_swap_cleanup_prefix + 2):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_proxy.preview_swap_cleanup(arg)
        if ok then return true, true, "ok camera.oculus.preview.swap.cleanup " .. tostring(detail) end
        return true, false, "camera.oculus.preview.swap.cleanup failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.swap.confirm" then
        local ok, detail = feature_oculus_proxy.preview_swap_confirm()
        if ok then return true, true, "ok camera.oculus.preview.swap.confirm " .. tostring(detail) end
        return true, false, "camera.oculus.preview.swap.confirm failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview.swap.cancel" then
        local ok, detail = feature_oculus_proxy.preview_swap_cancel()
        if ok then return true, true, "ok camera.oculus.preview.swap.cancel " .. tostring(detail) end
        return true, false, "camera.oculus.preview.swap.cancel failed: " .. tostring(detail)
    end
    local proxy_attachgrab_start_prefix = "camera.oculus.proxy.attachgrab.start"
    if line == proxy_attachgrab_start_prefix or line:sub(1, #proxy_attachgrab_start_prefix + 1) == proxy_attachgrab_start_prefix .. " " then
        local arg = line:sub(#proxy_attachgrab_start_prefix + 2):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_proxy.attachgrab_start(arg)
        if ok then return true, true, "ok camera.oculus.proxy.attachgrab.start " .. tostring(detail) end
        return true, false, "camera.oculus.proxy.attachgrab.start failed: " .. tostring(detail)
    end
    if line == "camera.oculus.proxy.attachgrab.confirm" then
        local ok, detail = feature_oculus_proxy.attachgrab_confirm()
        if ok then return true, true, "ok camera.oculus.proxy.attachgrab.confirm " .. tostring(detail) end
        return true, false, "camera.oculus.proxy.attachgrab.confirm failed: " .. tostring(detail)
    end
    if line == "camera.oculus.proxy.attachgrab.cancel" then
        local ok, detail = feature_oculus_proxy.attachgrab_cancel()
        if ok then return true, true, "ok camera.oculus.proxy.attachgrab.cancel " .. tostring(detail) end
        return true, false, "camera.oculus.proxy.attachgrab.cancel failed: " .. tostring(detail)
    end
    if line == "camera.oculus.proxy.attachgrab.status" then
        local ok, detail = feature_oculus_proxy.attachgrab_status()
        if ok then return true, true, "ok camera.oculus.proxy.attachgrab.status " .. tostring(detail) end
        return true, false, "camera.oculus.proxy.attachgrab.status failed: " .. tostring(detail)
    end
    if line == "camera.oculus.proxy.target.inspect" then
        local ok, detail = feature_oculus_proxy.target_mesh_inspect()
        if ok then return true, true, "ok camera.oculus.proxy.target.inspect " .. tostring(detail) end
        return true, false, "camera.oculus.proxy.target.inspect failed: " .. tostring(detail)
    end
    if line == "camera.oculus.proxy.inspect" then
        local ok, detail = feature_oculus_proxy.proxy_inspect()
        if ok then return true, true, "ok camera.oculus.proxy.inspect " .. tostring(detail) end
        return true, false, "camera.oculus.proxy.inspect failed: " .. tostring(detail)
    end
    if line == "camera.oculus.proxy.staticmesh.probe" then
        local ok, detail = feature_oculus_proxy.proxy_static_mesh_probe()
        if ok then return true, true, "ok camera.oculus.proxy.staticmesh.probe " .. tostring(detail) end
        return true, false, "camera.oculus.proxy.staticmesh.probe failed: " .. tostring(detail)
    end
    local proxy_place_start_prefix = "camera.oculus.proxy.place.start"
    if line == proxy_place_start_prefix or line:sub(1, #proxy_place_start_prefix + 1) == proxy_place_start_prefix .. " " then
        local arg = line:sub(#proxy_place_start_prefix + 2):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_proxy.place_start(arg)
        if ok then return true, true, "ok camera.oculus.proxy.place.start " .. tostring(detail) end
        return true, false, "camera.oculus.proxy.place.start failed: " .. tostring(detail)
    end
    if line == "camera.oculus.proxy.place.confirm" then
        local ok, detail = feature_oculus_proxy.place_confirm()
        if ok then return true, true, "ok camera.oculus.proxy.place.confirm " .. tostring(detail) end
        return true, false, "camera.oculus.proxy.place.confirm failed: " .. tostring(detail)
    end
    if line == "camera.oculus.proxy.place.cancel" then
        local ok, detail = feature_oculus_proxy.place_cancel()
        if ok then return true, true, "ok camera.oculus.proxy.place.cancel " .. tostring(detail) end
        return true, false, "camera.oculus.proxy.place.cancel failed: " .. tostring(detail)
    end
    if line == "camera.oculus.proxy.place.status" then
        local ok, detail = feature_oculus_proxy.place_status()
        if ok then return true, true, "ok camera.oculus.proxy.place.status " .. tostring(detail) end
        return true, false, "camera.oculus.proxy.place.status failed: " .. tostring(detail)
    end
    if line == "camera.oculus.proxy.sync.preview" then
        local ok, detail = feature_oculus_proxy.sync_preview()
        if ok then return true, true, "ok camera.oculus.proxy.sync.preview " .. tostring(detail) end
        return true, false, "camera.oculus.proxy.sync.preview failed: " .. tostring(detail)
    end
    local proxy_attach_preview_prefix = "camera.oculus.proxy.attach.preview"
    if line == proxy_attach_preview_prefix or line:sub(1, #proxy_attach_preview_prefix + 1) == proxy_attach_preview_prefix .. " " then
        local arg = line:sub(#proxy_attach_preview_prefix + 2):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_proxy.attach_preview(arg)
        if ok then return true, true, "ok camera.oculus.proxy.attach.preview " .. tostring(detail) end
        return true, false, "camera.oculus.proxy.attach.preview failed: " .. tostring(detail)
    end
    if line == "camera.oculus.proxy.spawn" or line == "camera.oculus.proxy.preview" then
        local ok, detail = feature_oculus_proxy.spawn()
        if ok then return true, true, "ok camera.oculus.proxy.spawn " .. tostring(detail) end
        return true, false, "camera.oculus.proxy.spawn failed: " .. tostring(detail)
    end
    if line == "camera.oculus.proxy.clear" then
        local ok, detail = feature_oculus_proxy.clear()
        if ok then return true, true, "ok camera.oculus.proxy.clear " .. tostring(detail) end
        return true, false, "camera.oculus.proxy.clear failed: " .. tostring(detail)
    end
    if line == "camera.oculus.proxy.status" then
        local ok, detail = feature_oculus_proxy.status()
        if ok then return true, true, "ok camera.oculus.proxy.status " .. tostring(detail) end
        return true, false, "camera.oculus.proxy.status failed: " .. tostring(detail)
    end
    if line:sub(1, 19) == "camera.grab.release" then
        if feature_oculus_proxy.is_active and feature_oculus_proxy.is_active() then
            local ok, detail = feature_oculus_proxy.place_confirm()
            if ok then return true, true, "ok camera.grab.release " .. tostring(detail) end
            return true, false, "camera.grab.release failed: " .. tostring(detail)
        end
        local ok, detail = feature_grab.release()
        if ok then return true, true, "ok camera.grab.release " .. tostring(detail) end
        return true, false, "camera.grab.release failed: " .. tostring(detail)
    end
    if line == "camera.grab.safe_cancel" then
        local ok, detail = safe_cancel_grab()
        if ok then return true, true, "ok camera.grab.safe_cancel " .. tostring(detail) end
        return true, false, "camera.grab.safe_cancel failed: " .. tostring(detail)
    end
    if line:sub(1, 18) == "camera.grab.cancel" then
        if feature_oculus_proxy.is_active and feature_oculus_proxy.is_active() then
            local ok, detail = feature_oculus_proxy.place_cancel()
            if ok then return true, true, "ok camera.grab.cancel " .. tostring(detail) end
            return true, false, "camera.grab.cancel failed: " .. tostring(detail)
        end
        local ok, detail = feature_grab.cancel()
        if ok then return true, true, "ok camera.grab.cancel " .. tostring(detail) end
        return true, false, "camera.grab.cancel failed: " .. tostring(detail)
    end
    if line:sub(1, 18) == "camera.grab.status" then
        if feature_oculus_proxy.is_active and feature_oculus_proxy.is_active() then
            local ok, detail = feature_oculus_proxy.place_status()
            if ok then return true, true, "ok camera.grab.status " .. tostring(detail) end
            return true, false, "camera.grab.status failed: " .. tostring(detail)
        end
        local ok, detail = feature_grab.status()
        if ok then return true, true, "ok camera.grab.status " .. tostring(detail) end
        return true, false, "camera.grab.status failed: " .. tostring(detail)
    end
    local grab_probe_prefix = "camera.grab.probe"
    if line == grab_probe_prefix or line:sub(1, #grab_probe_prefix + 1) == grab_probe_prefix .. " " then
        local arg = line:sub(#grab_probe_prefix + 2):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_grab.probe(arg ~= "" and arg or nil)
        if ok then return true, true, "ok camera.grab.probe " .. tostring(detail) end
        return true, false, "camera.grab.probe failed: " .. tostring(detail)
    end
    if line == "camera.grab.steps" or line:sub(1, 18) == "camera.grab.steps " then
        local arg = line:sub(19):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_grab.steps(arg)
        if ok then return true, true, "ok camera.grab.steps " .. tostring(detail) end
        return true, false, "camera.grab.steps failed: " .. tostring(detail)
    end
    if line == "camera.grab.safety" or line:sub(1, 19) == "camera.grab.safety " then
        local arg = line:sub(20):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_grab.safety(arg)
        if ok then return true, true, "ok camera.grab.safety " .. tostring(detail) end
        return true, false, "camera.grab.safety failed: " .. tostring(detail)
    end
    if line:sub(1, 17) == "camera.grab.delta" then
        local arg = line:sub(18):match("^%s*(.-)%s*$") or ""
        if arg == "" then return true, false, "usage: camera.grab.delta <signed-number>" end
        local ok, detail = feature_grab.delta(arg)
        if ok then return true, true, "ok camera.grab.delta " .. tostring(detail) end
        return true, false, "camera.grab.delta failed: " .. tostring(detail)
    end
    if line:sub(1, 18) == "camera.grab.rotate" then
        local arg = line:sub(19):match("^%s*(.-)%s*$") or ""
        if arg == "" then return true, false, "usage: camera.grab.rotate <signed-number>" end
        local ok, detail = feature_grab.rotate(arg)
        if ok then return true, true, "ok camera.grab.rotate " .. tostring(detail) end
        return true, false, "camera.grab.rotate failed: " .. tostring(detail)
    end
    if line:sub(1, 17) == "camera.grab.scale" then
        local arg = line:sub(18):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_grab.scale_delta(arg ~= "" and arg or "1")
        if ok then return true, true, "ok camera.grab.scale " .. tostring(detail) end
        return true, false, "camera.grab.scale failed: " .. tostring(detail)
    end
    if line:sub(1, 16) == "camera.grab.lift" then
        local arg = line:sub(17):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_grab.lift(arg ~= "" and arg or "1")
        if ok then return true, true, "ok camera.grab.lift " .. tostring(detail) end
        return true, false, "camera.grab.lift failed: " .. tostring(detail)
    end
    local grab_toggle_safe_prefix = "camera.grab.toggle_safe"
    if line == grab_toggle_safe_prefix or line:sub(1, #grab_toggle_safe_prefix + 1) == grab_toggle_safe_prefix .. " " then
        local arg = line:sub(#grab_toggle_safe_prefix + 2):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_grab.toggle_safe(arg ~= "" and arg or nil)
        if ok then return true, true, "ok camera.grab.toggle_safe " .. tostring(detail) end
        return true, false, "camera.grab.toggle_safe failed: " .. tostring(detail)
    end
    if line:sub(1, 18) == "camera.grab.toggle" then
        local arg = line:sub(19):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_grab.toggle(arg ~= "" and arg or nil)
        if ok then return true, true, "ok camera.grab.toggle " .. tostring(detail) end
        return true, false, "camera.grab.toggle failed: " .. tostring(detail)
    end
    if line == "camera.grab.lastspawned" then
        local ok, detail = feature_grab.start_lastspawned()
        if ok then return true, true, "ok camera.grab.lastspawned " .. tostring(detail) end
        return true, false, "camera.grab.lastspawned failed: " .. tostring(detail)
    end
    if line == "camera.grab.item" then
        local ok, detail = feature_grab.toggle_item()
        if ok then return true, true, "ok camera.grab.item " .. tostring(detail) end
        return true, false, "camera.grab.item failed: " .. tostring(detail)
    end
    local grab_start_safe_prefix = "camera.grab.start_safe"
    if line == grab_start_safe_prefix or line:sub(1, #grab_start_safe_prefix + 1) == grab_start_safe_prefix .. " " then
        local arg = line:sub(#grab_start_safe_prefix + 2):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_grab.start_safe(arg ~= "" and arg or nil)
        if ok then return true, true, "ok camera.grab.start_safe " .. tostring(detail) end
        return true, false, "camera.grab.start_safe failed: " .. tostring(detail)
    end
    if line:sub(1, 17) == "camera.grab.start" then
        local arg = line:sub(18):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_grab.start(arg ~= "" and arg or nil)
        if ok then return true, true, "ok camera.grab.start " .. tostring(detail) end
        return true, false, "camera.grab.start failed: " .. tostring(detail)
    end
    if line:sub(1, 16) == "camera.grab.mode" then
        local arg = line:sub(17):match("^%s*(.-)%s*$") or ""
        if arg == "" then return true, false, "usage: camera.grab.mode <move|rot|z|scale>" end
        local ok, detail = feature_grab.mode(arg)
        if ok then return true, true, "ok camera.grab.mode " .. tostring(detail) end
        return true, false, "camera.grab.mode failed: " .. tostring(detail)
    end
    if line == "camera.lookat.item" then
        local ok, detail = feature_grab.lookat_item()
        if ok then return true, true, "ok camera.lookat.item " .. tostring(detail) end
        return true, false, "camera.lookat.item failed: " .. tostring(detail)
    end
    if line:sub(1, 13) == "camera.lookat" then
        local ok, detail = feature_grab.lookat()
        if ok then return true, true, "ok camera.lookat " .. tostring(detail) end
        return true, false, "camera.lookat failed: " .. tostring(detail)
    end
    if line == "camera.oculus.transform.inspect" then
        local ok, detail = feature_grab.lookat()
        if ok then return true, true, "ok camera.oculus.transform.inspect " .. tostring(detail) end
        return true, false, "camera.oculus.transform.inspect failed: " .. tostring(detail)
    end
    if line == "camera.oculus.transform.capture" or line:sub(1, 32) == "camera.oculus.transform.capture " then
        local arg = line:sub(33):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_transform.capture(arg)
        if ok then return true, true, "ok camera.oculus.transform.capture " .. tostring(detail) end
        return true, false, "camera.oculus.transform.capture failed: " .. tostring(detail)
    end
    if line == "camera.oculus.clone" then
        local ok, detail = feature_oculus_clone.clone()
        if ok then return true, true, "ok camera.oculus.clone " .. tostring(detail) end
        return true, false, "camera.oculus.clone failed: " .. tostring(detail)
    end
    if line == "camera.oculus.preview" then
        local ok, detail = feature_oculus_duplicate.preview()
        if ok then return true, true, "ok camera.oculus.preview " .. tostring(detail) end
        return true, false, "camera.oculus.preview failed: " .. tostring(detail)
    end
    if line == "camera.oculus.duplicate" then
        local ok, detail = feature_oculus_duplicate.duplicate()
        if ok then return true, true, "ok camera.oculus.duplicate " .. tostring(detail) end
        return true, false, "camera.oculus.duplicate failed: " .. tostring(detail)
    end
    if line == "camera.oculus.transform.reload" or line:sub(1, 31) == "camera.oculus.transform.reload " then
        local arg = line:sub(32):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_transform.reload(arg)
        if ok then return true, true, "ok camera.oculus.transform.reload " .. tostring(detail) end
        return true, false, "camera.oculus.transform.reload failed: " .. tostring(detail)
    end
    if line == "camera.oculus.transform.apply" or line:sub(1, 30) == "camera.oculus.transform.apply " then
        local arg = line:sub(31):match("^%s*(.-)%s*$") or ""
        local ok, detail = feature_oculus_transform.apply(arg)
        if ok then return true, true, "ok camera.oculus.transform.apply " .. tostring(detail) end
        return true, false, "camera.oculus.transform.apply failed: " .. tostring(detail)
    end
    if line == "camera.destroy.lookat" then
        local ok, detail = feature_grab.destroy_lookat()
        if ok then return true, true, "ok camera.destroy.lookat " .. tostring(detail) end
        return true, false, "camera.destroy.lookat failed: " .. tostring(detail)
    end


    return false, nil, nil
end

return M
