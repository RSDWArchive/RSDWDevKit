-- Explicit, read-only compatibility probes. Nothing runs at module load/startup.
local M = {}
function M.run(which)
    if which == "status" then
        local ok, manifest = pcall(require, "compatibility_manifest")
        if not ok then return false, "missing generated compatibility manifest" end
        return true, string.format("candidate=%s target_cl=%s reference_cl=%s ue4ss=%s live_verified=false; probes: compat.buildings, compat.ai, compat.items",
            manifest.candidate, manifest.target_cl, manifest.reference_cl, manifest.ue4ss)
    elseif which == "buildings" then
        return require("feature_build_access").status()
    elseif which == "ai" then
        return require("feature_actor_facade").status()
    elseif which == "items" then
        -- Uses the existing reticle snapshot/report path; no stabilization writes.
        return require("feature_inventory").runtime_snapshot("")
    end
    return false, "usage: compat.<status|buildings|ai|items>"
end
return M
