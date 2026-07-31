-- 「领取」子窗口：体力池详情 + 可领取进度条 + 领取按钮。
-- 从 HUD 精简出来的内容都搬到这里——HUD 只剩体力池当前值，细节点开本窗口看。
--
-- 顶层只 require popup（叶子模块），不 require gui.init：
-- init.lua 要反过来 require 本模块（走 M.show 打开窗口），
-- Factorio 又不允许在函数体内 require 来绕开循环，只能从依赖图上避免这条边。
-- hud.lua 同理是叶子方向的依赖（本模块 → hud，不会反过来），领取后要刷新 HUD 上的体力数字，
-- 这条依赖和 convert.lua 已有的做法一致（兑换后也会 require hud 来刷新余额）。
local stamina = require('scripts.stamina')
local util = require('scripts.util')
local popup = require('scripts.gui.popup')
local hud = require('scripts.gui.hud')

local M = {}

function M.show(player)
    local inner = popup.open_popup(player, {'pw.claim-title'})
    local name = player.name
    -- 上限数值是"知道了能优化"的那种信息（比如快满了就该赶紧点领取/兑换），
    -- 不知道也完全不影响正常领取，所以只给老玩家看；新人只看进度条和当前数值。
    local veteran = util.is_veteran(player)

    -- 体力池：老玩家看"当前/上限"，新人只看当前值
    if veteran then
        inner.add{type = 'label', caption = {'pw.claim-balance',
            stamina.balance(name), stamina.balance_cap_points()}}
    else
        inner.add{type = 'label', caption = {'pw.claim-balance-plain', stamina.balance(name)}}
    end

    -- 可领取池：进度条人人都看得到，"可领 X"的上限 Y 只给老玩家看
    local pending_flow = inner.add{type = 'flow', name = 'pw_pending_flow', direction = 'horizontal'}
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
    local claim_btn = inner.add{type = 'button', name = 'pw_claim_stamina', caption = {'pw.claim-do'}}
    if claimable < 1 then
        claim_btn.enabled = false
        claim_btn.tooltip = {'pw.stamina-none-yet'}
    else
        claim_btn.tooltip = {'pw.claim-do-tip'}
    end
end

-- 返回 true 表示本模块处理了这次点击
function M.on_click(player, name)
    if name ~= 'pw_claim_stamina' then return false end
    local n = stamina.claim(player.name)
    if n > 0 then
        player.print({'pw.stamina-claimed', n})
    else
        player.print({'pw.stamina-none-yet'})
    end
    -- 不关窗口：领取后数字立刻变化，方便玩家看到结果；同时把 HUD 上的体力当前值一起刷新。
    M.show(player)
    hud.refresh(player)
    return true
end

return M
