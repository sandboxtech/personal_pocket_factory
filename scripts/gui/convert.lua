-- 「兑换」内容片段：背包里的科技瓶预览 + 立即兑换按钮。
--
-- 只导出 M.render(container, player)，不再自己开弹窗，见 claim.lua 顶部注释——
-- 三个子窗口合并成了一个「状态」窗口（scripts/gui/status.lua），这里只管画内容。
local exp = require('scripts.exp')
local stamina = require('scripts.stamina')
local util = require('scripts.util')
local hud = require('scripts.gui.hud')

local M = {}

function M.render(container, player)
    local header = container.add{type = 'label', caption = {'pw.convert-title'}}
    header.style.font = 'default-bold'

    local entries, total_gain, points_used = exp.preview(player)

    local any = false
    for _, e in ipairs(entries) do
        if e.take > 0 then
            any = true
            container.add{type = 'label', caption = {'pw.convert-row',
                '[item=' .. e.item .. ']', e.count, e.quality,
                e.take, util.readable(e.take * e.mult), e.points}}
        end
    end
    if not any then
        container.add{type = 'label', caption = {'pw.convert-nothing'}}
    end

    container.add{type = 'label', caption = {'pw.convert-total', util.readable(total_gain), points_used}}
    container.add{type = 'label', caption = {'pw.convert-have', stamina.balance(player.name)}}

    local button = container.add{type = 'button', name = 'pw_do_convert', caption = {'pw.convert-do'}}
    if total_gain <= 0 then
        button.enabled = false
        button.tooltip = {'pw.convert-cannot'}
    end
end

-- 返回 true 表示本模块处理了这次点击。不在这里关窗口/重开窗口——
-- 兑换会同时改变体力、经验两段的数字，重开整个合并窗口的职责交给 status.lua。
function M.on_click(player, name)
    if name ~= 'pw_do_convert' then return false end
    local gain, err = exp.convert(player)
    if gain then
        player.print({'pw.convert-done', util.readable(gain)})
    else
        player.print({err or 'pw.convert-nothing'})
    end
    hud.refresh(player)
    return true
end

return M
