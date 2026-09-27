-- Oculus Vanilla+ preview helper.
--
-- Repair-mode reticle action:
--   * building pieces arm the normal build preview copy path
--   * actors/items are intentionally ignored; editor-style cloning lives outside Oculus

local M = {}

local feature_build_preview = require("feature_build_preview")

function M.preview()
    local ok, detail = feature_build_preview.lookat()
    if ok then return true, tostring(detail) end
    return false, tostring(detail)
end

-- Backward-compatible alias for old configs/manual commands.
function M.duplicate()
    return M.preview()
end

return M
