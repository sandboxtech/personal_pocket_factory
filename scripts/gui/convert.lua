local exp = require('scripts.exp')
local stamina = require('scripts.stamina')
local util = require('scripts.util')

local M = {}

function M.show(player)
    local gui = require('scripts.gui.init')
    local inner = gui.open_popup(player, {'pw.convert-title'})
    local entries, total, cost = exp.preview(player)

    if #entries == 0 then
        inner.add{type = 'label', caption = {'pw.convert-nothing'}}
    else
        for _, e in ipairs(entries) do
            inner.add{type = 'label', caption = {'pw.convert-row',
                '[item=' .. e.item .. ']', e.count, e.quality, util.readable(e.gain)}}
        end
    end

    inner.add{type = 'label', caption = {'pw.convert-total', util.readable(total), cost}}
    inner.add{type = 'label', caption = {'pw.convert-have', stamina.get(player.name)}}

    local button = inner.add{type = 'button', name = 'pw_do_convert', caption = {'pw.convert-do'}}
    if total <= 0 or stamina.get(player.name) < cost then
        button.enabled = false
        button.tooltip = {'pw.convert-cannot'}
    end
end

-- 返回 true 表示本模块处理了这次点击
function M.on_click(player, name)
    if name ~= 'pw_do_convert' then return false end
    local gui = require('scripts.gui.init')
    local gain, err = exp.convert(player)
    if gain then
        player.print({'pw.convert-done', util.readable(gain)})
    else
        player.print({err or 'pw.convert-nothing'})
    end
    gui.close_popup(player)
    require('scripts.gui.hud').refresh(player)
    return true
end

return M
