local M = {}

function M.show(player)
    local gui = require('scripts.gui.init')
    local inner = gui.open_popup(player, {'pw.help-title'})
    local label = inner.add{type = 'label', caption = {'pw.help-body'}}
    label.style.single_line = false
    label.style.maximal_width = 560
end

return M
