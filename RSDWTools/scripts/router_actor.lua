local support = require("router_support")
local lazy_feature = support.lazy_feature

local feature_actor = lazy_feature("feature_actor")
local feature_introspect = lazy_feature("feature_introspect")

local M = {}

-- Splits the remainder of an actor.* command into { name, optional_tail }.
-- Scan emits names via GetName() which has no spaces, so we can safely split
-- on whitespace: the first token is the actor name; anything after (if
-- present) is the optional parameter (on|off|<scale_value>).
local function split_actor_body(line, verb_len)
    local rest = line:sub(verb_len + 1)
    rest = (tostring(rest or ""):gsub("^%s+", ""):gsub("%s+$", ""))
    if rest == "" then
        return nil, nil
    end
    local name, tail = rest:match("^(%S+)%s+(.+)$")
    if name then
        return name, tail
    end
    return rest, nil
end

function M.try_handle(line)
    -- actor.* verbs. Must check BEFORE the generic "tele"/"scan" prefix checks so
    -- "actor.scale" doesn't get swallowed by a future shorter prefix, and because
    -- these compound verbs are routed together.
    if line:sub(1, 6) == "actor." then
        -- actor.goto <name>
        if line:sub(1, 10) == "actor.goto" then
            local name = select(1, split_actor_body(line, 10))
            if not name then
                return true, false, "usage: actor.goto <name>"
            end
            local ok, detail = feature_actor.goto_actor(name)
            if ok then return true, true, "ok actor.goto " .. tostring(detail or name) end
            return true, false, "actor.goto failed: " .. tostring(detail)
        end

        -- actor.bring <name>
        if line:sub(1, 11) == "actor.bring" then
            local name = select(1, split_actor_body(line, 11))
            if not name then
                return true, false, "usage: actor.bring <name>"
            end
            local ok, detail = feature_actor.bring_actor(name)
            if ok then return true, true, "ok actor.bring " .. tostring(detail or name) end
            return true, false, "actor.bring failed: " .. tostring(detail)
        end

        -- actor.del <name>
        if line:sub(1, 9) == "actor.del" then
            local name = select(1, split_actor_body(line, 9))
            if not name then
                return true, false, "usage: actor.del <name>"
            end
            local ok, detail = feature_actor.delete_actor(name)
            if ok then return true, true, "ok actor.del " .. tostring(detail or name) end
            return true, false, "actor.del failed: " .. tostring(detail)
        end

        -- actor.vis <name> [on|off]
        if line:sub(1, 9) == "actor.vis" then
            local name, tail = split_actor_body(line, 9)
            if not name then
                return true, false, "usage: actor.vis <name> [on|off]"
            end
            local ok, detail = feature_actor.set_visibility(name, tail)
            if ok then return true, true, "ok actor.vis " .. name .. " " .. tostring(detail) end
            return true, false, "actor.vis failed: " .. tostring(detail)
        end

        -- actor.col <name> [on|off]
        if line:sub(1, 9) == "actor.col" then
            local name, tail = split_actor_body(line, 9)
            if not name then
                return true, false, "usage: actor.col <name> [on|off]"
            end
            local ok, detail = feature_actor.set_collision(name, tail)
            if ok then return true, true, "ok actor.col " .. name .. " " .. tostring(detail) end
            return true, false, "actor.col failed: " .. tostring(detail)
        end

        -- actor.spectate.reset -- MUST be checked BEFORE actor.spectate (the
        -- shorter prefix would otherwise swallow the longer match and try to
        -- treat "reset" as an actor name).
        if line == "actor.spectate.reset" or line:sub(1, 21) == "actor.spectate.reset " then
            local ok, detail = feature_actor.spectate_reset()
            if ok then return true, true, "ok actor.spectate.reset " .. tostring(detail) end
            return true, false, "actor.spectate.reset failed: " .. tostring(detail)
        end

        -- actor.spectate <name> -- point the camera at a named actor via
        -- SetViewTargetWithBlend. Pawn input still drives the real character
        -- in the background; this is pure view decoupling.
        if line:sub(1, 14) == "actor.spectate" then
            local name = select(1, split_actor_body(line, 14))
            if not name then
                return true, false, "usage: actor.spectate <name>"
            end
            local ok, detail = feature_actor.spectate_actor(name)
            if ok then return true, true, "ok actor.spectate " .. tostring(detail or name) end
            return true, false, "actor.spectate failed: " .. tostring(detail)
        end

        -- actor.info.field <name> <segments>   (must come before actor.info ;
        -- longest-prefix match.) <segments> is dot-separated property names.
        if line:sub(1, 16) == "actor.info.field" then
            local body = line:sub(17)
            -- split body into "<name> <path>"
            body = body:match("^%s*(.-)%s*$") or ""
            local name, path = body:match("^(%S+)%s+(.+)$")
            if not name then
                name = body
                path = ""
            end
            if not name or name == "" then
                return true, false, "usage: actor.info.field <name> <seg>[.<seg>...]"
            end
            local ok, detail = feature_introspect.dump_actor_field(name, path)
            if ok then return true, true, "ok actor.info.field " .. tostring(detail) end
            return true, false, "actor.info.field failed: " .. tostring(detail)
        end

        -- actor.info <name>
        if line:sub(1, 10) == "actor.info" then
            local name = select(1, split_actor_body(line, 10))
            if not name or name == "" then
                return true, false, "usage: actor.info <name>"
            end
            local ok, detail = feature_introspect.dump_actor(name)
            if ok then return true, true, "ok actor.info " .. tostring(detail) end
            return true, false, "actor.info failed: " .. tostring(detail)
        end

        -- actor.scale <name> [value]
        if line:sub(1, 11) == "actor.scale" then
            local name, tail = split_actor_body(line, 11)
            if not name then
                return true, false, "usage: actor.scale <name> [value]"
            end
            if tail == nil or tail == "" then
                local ok, detail = feature_actor.get_scale_uniform(name)
                if ok then return true, true, tostring(detail) end
                return true, false, "actor.scale failed: " .. tostring(detail)
            end
            local ok, detail = feature_actor.set_scale_uniform(name, tail)
            if ok then return true, true, "ok actor.scale " .. name .. " " .. tostring(detail) end
            return true, false, "actor.scale failed: " .. tostring(detail)
        end

        return true, false, "unknown actor.* verb"
    end

    return false, nil, nil
end

return M