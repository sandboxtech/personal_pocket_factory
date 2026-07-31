local exp = require('scripts.exp')
local stamina = require('scripts.stamina')
local util = require('scripts.util')
local popup = require('scripts.gui.popup')
local hud = require('scripts.gui.hud')

local M = {}

function M.show(player)
    local inner = popup.open_popup(player, {'pw.convert-title'})
    local entries, total_gain, points_used = exp.preview(player)

    local any = false
    for _, e in ipairs(entries) do
        if e.take > 0 then
            any = true
            inner.add{type = 'label', caption = {'pw.convert-row',
                '[item=' .. e.item .. ']', e.count, e.quality,
                e.take, util.readable(e.take * e.mult), e.points}}
        end
    end
    if not any then
        inner.add{type = 'label', caption = {'pw.convert-nothing'}}
    end

    inner.add{type = 'label', caption = {'pw.convert-total', util.readable(total_gain), points_used}}
    inner.add{type = 'label', caption = {'pw.convert-have', stamina.balance(player.name)}}

    local button = inner.add{type = 'button', name = 'pw_do_convert', caption = {'pw.convert-do'}}
    if total_gain <= 0 then
        button.enabled = false
        button.tooltip = {'pw.convert-cannot'}
    end
end

-- 返回 true 表示本模块处理了这次点击
function M.on_click(player, name)
    if name ~= 'pw_do_convert' then return false end
    local gain, err = exp.convert(player)
    if gain then
        player.print({'pw.convert-done', util.readable(gain)})
    else
        player.print({err or 'pw.convert-nothing'})
    end
    popup.close_popup(player)
    hud.refresh(player)
    return true
end

return M
