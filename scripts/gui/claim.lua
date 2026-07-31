-- 「领取」内容片段：体力池详情 + 可领取进度条 + 领取按钮。
--
-- 只导出 M.render(container, player)，不再自己开弹窗——三个子窗口（领取/兑换/经验）
-- 合并成了一个「状态」窗口（scripts/gui/status.lua），窗口本身只开一次，
-- claim/convert/exp 依次把内容画进同一个容器。单一职责没变，只是不再各开各的窗口。
--
-- 顶层不 require popup、不 require gui.init、也不 require gui.status：
-- status.lua 要反过来 require 本模块（调 M.render 组装内容），Factorio 又不允许在
-- 函数体内 require 来绕开循环依赖，只能从依赖图上避免这条边。
-- hud.lua 是叶子方向的依赖（本模块 → hud，不会反过来），领取后要刷新 HUD 上的体力数字。
local stamina = require('scripts.stamina')
local util = require('scripts.util')
local hud = require('scripts.gui.hud')

local M = {}

function M.render(container, player)
    local header = container.add{type = 'label', caption = {'pw.claim-title'}}
    header.style.font = 'default-bold'

    local name = player.name
    -- 上限数值是"知道了能优化"的那种信息（比如快满了就该赶紧点领取/兑换），
    -- 不知道也完全不影响正常领取，所以只给老玩家看；新人只看进度条和当前数值。
    local veteran = util.is_veteran(player)

    -- 体力池：老玩家看"当前/上限"，新人只看当前值
    if veteran then
        container.add{type = 'label', caption = {'pw.claim-balance',
            stamina.balance(name), stamina.balance_cap_points()}}
    else
        container.add{type = 'label', caption = {'pw.claim-balance-plain', stamina.balance(name)}}
    end

    -- 可领取池：进度条人人都看得到，"可领 X"的上限 Y 只给老玩家看
    local pending_flow = container.add{type = 'flow', name = 'pw_pending_flow', direction = 'horizontal'}
    pending_flow.style.vertical_align = 'center'
    local bar = pending_flow.add{type = 'progressbar', name = 'pw_pending_bar',
        value = stamina.pending_fraction(name)}
    bar.style.width = 160
    local claimable = stamina.claimable(name)
    if veteran then
        pending_flow.add{type = 'label', caption = {'pw.claim-pending', claimable, stamina.pending_cap_points()}}
    else
        pending_flow.add{type = 'label', caption = {'pw.claim-pending-plain', claimable}}
    end

    -- 领取按钮：可领不足 1 点时置灰，tooltip 说明原因
    local claim_btn = container.add{type = 'button', name = 'pw_claim_stamina', caption = {'pw.claim-do'}}
    if claimable < 1 then
        claim_btn.enabled = false
        claim_btn.tooltip = {'pw.stamina-none-yet'}
    else
        claim_btn.tooltip = {'pw.claim-do-tip'}
    end
end

-- 返回 true 表示本模块处理了这次点击。刷新整个合并窗口的职责交给 status.lua——
-- 领取会改变体力数字，但这个片段自己不知道窗口现在长什么样，重开整个窗口才对。
function M.on_click(player, name)
    if name ~= 'pw_claim_stamina' then return false end
    local n = stamina.claim(player.name)
    if n > 0 then
        player.print({'pw.stamina-claimed', n})
    else
        player.print({'pw.stamina-none-yet'})
    end
    hud.refresh(player)
    return true
end

return M
