-- 左上角 HUD：环等级/宽度、体力（可领取池进度条 + 领取按钮 + 体力池余额）、功能按钮。
local ring = require('scripts.ring')
local stamina = require('scripts.stamina')
local popup = require('scripts.gui.popup')

local M = {}

function M.refresh(player)
    local root = player.gui.top[popup.HUD_NAME]
    if not root then
        root = player.gui.top.add{type = 'frame', name = popup.HUD_NAME, direction = 'horizontal'}
    end
    root.clear()

    local name = player.name
    local level = ring.level_of(name)
    local width = ring.half_width_of(name) * 2

    root.add{type = 'label', caption = {'pw.hud-ring', level, width}}

    -- 体力池余额：兑换经验时从这里扣点数
    root.add{type = 'label', caption = {'pw.hud-balance', stamina.balance(name), stamina.balance_cap_points()}}

    -- 可领取池：进度条 + "可领 X/Y" 文本，凑不够 1 点时领取按钮置灰
    local pending_flow = root.add{type = 'flow', name = 'pw_pending_flow', direction = 'horizontal'}
    pending_flow.style.vertical_align = 'center'
    local bar = pending_flow.add{type = 'progressbar', name = 'pw_pending_bar',
        value = stamina.pending_fraction(name)}
    bar.style.width = 100
    local claimable = stamina.claimable(name)
    pending_flow.add{type = 'label', caption = {'pw.hud-pending', claimable, stamina.pending_cap_points()}}

    local claim_btn = root.add{type = 'button', name = 'pw_claim_stamina', caption = {'pw.btn-claim-stamina'}}
    if claimable < 1 then
        claim_btn.enabled = false
        claim_btn.tooltip = {'pw.stamina-none-yet'}
    else
        claim_btn.tooltip = {'pw.btn-claim-stamina-tip'}
    end

    root.add{type = 'button', name = 'pw_btn_convert', caption = {'pw.btn-convert'},
             tooltip = {'pw.btn-convert-tip'}}
    root.add{type = 'button', name = 'pw_btn_travel', caption = {'pw.btn-travel'},
             tooltip = {'pw.btn-travel-tip'}}
    root.add{type = 'button', name = 'pw_btn_exp', caption = {'pw.btn-exp'},
             tooltip = {'pw.btn-exp-tip'}}
    root.add{type = 'button', name = 'pw_btn_help', caption = {'pw.btn-help'}}
end

return M
