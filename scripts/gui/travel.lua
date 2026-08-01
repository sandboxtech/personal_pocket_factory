local constants = require('scripts.constants')
local pockets = require('scripts.pockets')
local worlds = require('scripts.worlds')
-- exp 只依赖 constants/geometry/ring/stamina/util，都不反向依赖 gui，顶层 require 不成环。
local exp = require('scripts.exp')
local util = require('scripts.util')
local popup = require('scripts.gui.popup')

local M = {}

function M.show(player)
    local inner = popup.open_popup(player, {'pw.travel-title'})

    -- 一、回自己的戴森环
    inner.add{type = 'button', name = 'pw_go_ring', caption = {'pw.travel-home'}}

    -- 二、五个公共世界
    inner.add{type = 'label', caption = {'pw.travel-worlds-head'}}

    -- 科技漏水倒计时：【所有人都看得到】。
    -- 它一度被归进"老玩家才看的细节"，但那个分类是错的——星球重置倒计时给所有人看，
    -- 科技漏水是同一类东西：全服性的、有明确时刻的、看了能改变当下行动的事件
    -- （赶在漏水前把要紧科技用掉）。新人不知道这件事会发生，才是真的会被打懵。
    --
    -- 显示「还剩多久」而不是丢失数量的期望值（worlds.expected_losses 留着给别处用）：
    -- 前者能直接换算成行动，后者只是个统计量。
    -- 调度器还没排过第一轮时 tech_loss_time_left 返回 nil，退化显示「尚未排期」，
    -- 不瞎编一个数字。
    local tech_left = worlds.tech_loss_time_left()
    if tech_left then
        local minutes = math.max(0, math.floor(tech_left / constants.min_to_tick))
        inner.add{type = 'label', caption = {'pw.travel-tech-timer', minutes}}
    else
        inner.add{type = 'label', caption = {'pw.travel-tech-unscheduled'}}
    end

    -- 自动兑换倒计时。和科技漏水一样【所有人都看得到】：
    -- 它决定"我现在要不要赶紧把收货箱里的瓶子用机械臂拉进实验室"，
    -- 是一条看了就能改变当下动作的信息，不是给老玩家看的优化细节。
    local convert_left = exp.auto_convert_time_left()
    if convert_left then
        local minutes = math.max(0, math.floor(convert_left / constants.min_to_tick))
        inner.add{type = 'label', caption = {'pw.travel-convert-timer', minutes}}
    else
        inner.add{type = 'label', caption = {'pw.travel-convert-unscheduled'}}
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
