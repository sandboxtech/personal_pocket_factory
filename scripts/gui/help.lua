local popup = require('scripts.gui.popup')

local M = {}

function M.show(player)
    local inner = popup.open_popup(player, {'pw.help-title'})
    local label = inner.add{type = 'label', caption = {'pw.help-body'}}
    label.style.single_line = false
    label.style.maximal_width = 560
end

return M
