-- 玩法说明弹窗。
--
-- 新人和老玩家看到的内容不一样：help-body 只讲"怎么玩"，不含任何数值；
-- 老玩家（util.is_veteran，累计在线满 storage.detail_hours 小时）在下面多看一段
-- help-body-detail，把重置周期、科技撤销概率、戴森环生命周期阈值这些
-- "知道了能优化、不知道也不影响上手"的具体数字摆出来。
--
-- 这些数字全部现读 storage（带 nil 兜底），不写死在 locale 文本里——
-- 管理员改配置后这段说明立刻跟着变，不会跟实际配置脱节。
local constants = require('scripts.constants')
local util = require('scripts.util')
local popup = require('scripts.gui.popup')

local M = {}

function M.show(player)
    local inner = popup.open_popup(player, {'pw.help-title'})
    local label = inner.add{type = 'label', caption = {'pw.help-body'}}
    label.style.single_line = false
    label.style.maximal_width = popup.WIDTH

    if util.is_veteran(player) then
        local minutes = storage.world_reset_minutes or {}
        local planets = constants.PUBLIC_PLANETS   -- 顺序：nauvis / vulcanus / gleba / fulgora / aquilo
        local detail = inner.add{type = 'label', caption = {'pw.help-body-detail',
            minutes[planets[1]] or 0, minutes[planets[2]] or 0, minutes[planets[3]] or 0,
            minutes[planets[4]] or 0, minutes[planets[5]] or 0,
            storage.tech_loss_k or 1,
            storage.ring_public_hours or 30,
            storage.ring_delete_hours or 50,
        }}
        detail.style.single_line = false
        detail.style.maximal_width = popup.WIDTH
    end
end

return M
