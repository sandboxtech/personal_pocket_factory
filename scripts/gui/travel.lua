local constants = require('scripts.constants')
local pockets = require('scripts.pockets')
local worlds = require('scripts.worlds')
local popup = require('scripts.gui.popup')

local M = {}

function M.show(player)
    local inner = popup.open_popup(player, {'pw.travel-title'})

    -- 一、回自己的戴森环
    inner.add{type = 'button', name = 'pw_go_ring', caption = {'pw.travel-home'}}

    -- 二、五个公共世界
    inner.add{type = 'label', caption = {'pw.travel-worlds-head'}}
    inner.add{type = 'label', caption = {'pw.travel-tech-warn',
        string.format('%.1f', worlds.expected_losses())}}

    for _, name in ipairs(constants.PUBLIC_PLANETS) do
        local row = inner.add{type = 'flow', direction = 'horizontal'}
        local surface = game.surfaces[name]
        local left = math.max(0, math.floor(worlds.time_left(name) / constants.min_to_tick))

        -- 按钮放在最前面，方便玩家一眼定位可点击项
        local go = row.add{type = 'button', name = 'pw_go_' .. name, caption = {'pw.travel-go'}}
        row.add{type = 'label', caption = {'pw.travel-world-row', name, left}}
        if not (surface and surface.valid) then
            go.enabled = false
            go.tooltip = {'pw.world-not-ready', name}
        end
    end

    -- 三、所有玩家的戴森环：全部列出（含离线时长），但只有超过 ring_public_hours 的能进
    local rings = pockets.all_rings()
    if #rings > 0 then
        inner.add{type = 'label', caption = {'pw.travel-rings-head',
            storage.ring_public_hours or 30}}
        for _, entry in ipairs(rings) do
            local row = inner.add{type = 'flow', direction = 'horizontal'}
            -- 按钮放在最前面，与上面公共世界那一段保持一致
            local go = row.add{type = 'button', name = 'pw_go_ring_' .. entry.owner_index,
                               caption = {'pw.travel-go'}}
            row.add{type = 'label', caption = {'pw.travel-ring-row',
                entry.owner_name, entry.half_width * 2, entry.idle_hours}}
            if not entry.enterable then
                go.enabled = false
                -- 还差多久才可进入，给玩家一个可规划的数字
                go.tooltip = {'pw.travel-ring-locked',
                    math.max(0, (storage.ring_public_hours or 30) - entry.idle_hours)}
            end
        end
    end
end

function M.on_click(player, name)
    if name == 'pw_go_ring' then
        pockets.enter(player)
        popup.close_popup(player)
        return true
    end

    -- 别人的戴森环。必须在下面的 'pw_go_' 前缀判断【之前】匹配，
    -- 否则会被当成星球名 'ring_7' 传给 worlds.travel。
    local ring_index = string.match(name, '^pw_go_ring_(%d+)$')
    if ring_index then
        local owner = game.players[tonumber(ring_index)]
        local surface = owner and pockets.get(owner)
        if not (surface and surface.valid) then
            player.print({'pw.travel-ring-gone'})
            popup.close_popup(player)
            return true
        end

        -- 再校验一次门槛：按钮可能是在阈值改动前渲染的，也可能主人刚上线。
        -- UI 的 enabled 只是提示，真正的闸门在这里。
        if pockets.idle_hours(owner) < (storage.ring_public_hours or 30) then
            player.print({'pw.travel-ring-locked-msg', owner.name})
            popup.close_popup(player)
            return true
        end

        -- 惰性公共化：有人真的走进来的那一刻才切 link_id，不必等周期扫描。
        -- make_public 幂等，已经是 public 的直接返回 false。
        pockets.make_public(owner)

        local pos = surface.find_non_colliding_position('character', {4, 0}, 64, 1) or {4, 0}
        player.teleport(pos, surface)
        popup.close_popup(player)
        return true
    end

    if string.sub(name, 1, 6) == 'pw_go_' then
        worlds.travel(player, string.sub(name, 7))
        popup.close_popup(player)
        return true
    end

    return false
end

return M
