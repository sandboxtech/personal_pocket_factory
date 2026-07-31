local geometry = require('scripts.geometry')
local exp = require('scripts.exp')
local ring = require('scripts.ring')
local util = require('scripts.util')

local M = {}

function M.show(player)
    local gui = require('scripts.gui.init')
    local inner = gui.open_popup(player, {'pw.exp-title'})
    local table_data = exp.get(player.name)

    inner.add{type = 'label', caption = {'pw.exp-help'}}

    local sum = 0
    for _, short in ipairs(geometry.SCIENCE_PACKS) do
        local amount = table_data[short] or 0
        local contribution = amount > 1 and math.log(amount, 10) or 0
        sum = sum + contribution
        inner.add{type = 'label', caption = {'pw.exp-row',
            '[item=' .. geometry.pack_item_name(short) .. ']',
            util.readable(amount),
            string.format('%.2f', contribution)}}
    end

    local level = ring.level_of(player.name)
    inner.add{type = 'label', caption = {'pw.exp-sum',
        string.format('%.2f', sum), level, ring.half_width_of(player.name) * 2}}
    inner.add{type = 'label', caption = {'pw.exp-next',
        string.format('%.2f', level + 1 - sum)}}
end

return M
