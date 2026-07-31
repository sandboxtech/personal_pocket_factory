local geometry = require('scripts.geometry')
local ring = require('scripts.ring')
local stamina = require('scripts.stamina')

local M = {}

function M.refresh(player)
    local gui = require('scripts.gui.init')
    local root = player.gui.top[gui.HUD_NAME]
    if not root then
        root = player.gui.top.add{type = 'frame', name = gui.HUD_NAME, direction = 'horizontal'}
    end
    root.clear()

    local level = ring.level_of(player.name)
    local width = ring.half_width_of(player.name) * 2

    root.add{type = 'label', caption = {'pw.hud-ring', level, width}}
    root.add{type = 'label', caption = {'pw.hud-stamina',
        stamina.get(player.name), storage.stamina_cap or 1440}}

    root.add{type = 'button', name = 'pw_btn_convert', caption = {'pw.btn-convert'},
             tooltip = {'pw.btn-convert-tip'}}
    root.add{type = 'button', name = 'pw_btn_travel', caption = {'pw.btn-travel'},
             tooltip = {'pw.btn-travel-tip'}}
    root.add{type = 'button', name = 'pw_btn_exp', caption = {'pw.btn-exp'},
             tooltip = {'pw.btn-exp-tip'}}
    root.add{type = 'button', name = 'pw_btn_help', caption = {'pw.btn-help'}}
end

return M
