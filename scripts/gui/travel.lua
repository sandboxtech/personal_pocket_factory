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
            -- 禁用原因里带上星球图标 + 本地化星球名（util.planet_label），
            -- 不甩一个裸 surface 名当纯文本。
            go.tooltip = {'pw.world-not-ready', util.planet_label(name)}
        end
    end

    -- 三、别人的戴森环、以及各人名下的飞船，全部搬去了「全服总览」页
    --     （scripts/gui/overview.lua）。它们回答的是同一个问题——服务器上现在有谁、
    --     各自什么状态、我能去哪——拆在两个窗口里只会让玩家两处都翻一遍。
    --     本窗口现在专职做一件事：把【我自己】送到某个地方去。
end

function M.on_click(player, name)
    if name == 'pw_go_ring' then
        pockets.enter(player)
        popup.close_popup(player)
        return true
    end

    -- 「进别人的戴森环」搬去了 overview.lua（按钮名前缀改成 pw_ov_ring_）。
    -- 顺带消掉了这里一个隐患：原来那个 pw_go_ring_<index> 必须抢在下面的
    -- 'pw_go_' 前缀判断之前匹配，否则 'ring_7' 会被当成星球名传给 worlds.travel。
    -- 换成互不重叠的前缀之后，两条路由谁先谁后都不影响正确性。

    if string.sub(name, 1, 6) == 'pw_go_' then
        worlds.travel(player, string.sub(name, 7))
        popup.close_popup(player)
        return true
    end

    return false
end

return M
