local constants = require('scripts.constants')
local pockets = require('scripts.pockets')
local worlds = require('scripts.worlds')
local util = require('scripts.util')
local popup = require('scripts.gui.popup')

local M = {}

function M.show(player)
    local inner = popup.open_popup(player, {'pw.travel-title'})

    -- 一、回自己的戴森环
    inner.add{type = 'button', name = 'pw_go_ring', caption = {'pw.travel-home'}}

    -- 二、五个公共世界
    inner.add{type = 'label', caption = {'pw.travel-worlds-head'}}

    -- 科技流失倒计时是"知道了能规划"的信息（赶在漏水前把要紧科技用上），
    -- 新人先把"去哪个星球、多久重置"这两件事搞清楚就够了，这条只给老玩家看。
    --
    -- 显示的是「距离下次科技流失还有多久」，不是丢失数量的期望值——
    -- 后者（worlds.expected_losses）还留着给别处用，但对玩家来说「还剩多久」
    -- 才是能直接规划行动的信息。调度器（Task 12）上线前 tech_loss_time_left
    -- 恒返回 nil，这里退化显示「尚未排期」，不瞎编一个数字。
    if util.is_veteran(player) then
        local tech_left = worlds.tech_loss_time_left()
        if tech_left then
            local minutes = math.max(0, math.floor(tech_left / constants.min_to_tick))
            inner.add{type = 'label', caption = {'pw.travel-tech-timer', minutes}}
        else
            inner.add{type = 'label', caption = {'pw.travel-tech-unscheduled'}}
        end
    end

    for _, name in ipairs(constants.PUBLIC_PLANETS) do
        local row = inner.add{type = 'flow', direction = 'horizontal'}
        local surface = game.surfaces[name]
        local left = math.max(0, math.floor(worlds.time_left(name) / constants.min_to_tick))

        -- 星球图标放进按钮文字里（"前往[planet=xxx]"），每个星球图标不同，
        -- 所以 pw.travel-go-planet 做成带参数的 key，不能像 pw.travel-go 那样写死。
        -- 行文本只剩倒计时，不再重复星球名。
        local go = row.add{type = 'button', name = 'pw_go_' .. name, caption = {'pw.travel-go-planet', name}}
        row.add{type = 'label', caption = {'pw.travel-world-row', left}}
        if not (surface and surface.valid) then
            go.enabled = false
            go.tooltip = {'pw.world-not-ready', name}
        end
    end

    -- 三、所有玩家的戴森环：全部列出（含离线时长），但只有超过【各自的】公共化阈值的能进
    --
    -- 整段只给老玩家看：新人还没攒够经验，去别人环里逛也拿不走什么，
    -- 先把"怎么攒经验、怎么用关联箱"这些基本操作弄明白更重要。
    --
    -- 阈值现在因人而异（新人按在线时长缩放，见 pockets.public_threshold），
    -- 不再有一个全服统一的数字可以放进表头，所以表头文案改成不带具体小时数；
    -- 每一行的「还差多久」用 entry.public_hours（这个主人自己的阈值）现算。
    if util.is_veteran(player) then
        local rings = pockets.all_rings()
        if #rings > 0 then
            inner.add{type = 'label', caption = {'pw.travel-rings-head'}}
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
                        math.max(0, math.floor(entry.public_hours - entry.idle_hours))}
                end
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
        -- 阈值用这个主人自己的 public_threshold（按他的在线时长缩放），不能再假设全服统一。
        if pockets.idle_hours(owner) < (pockets.public_threshold(owner) / constants.hour_to_tick) then
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
