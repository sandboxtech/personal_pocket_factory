-- 玩法说明弹窗。分三段，按「这条规则现在对你有没有用」决定给谁看。
--
-- ① help-body（所有人）：主循环本身 —— 环 / 十二种经验 / 关联箱 / 自动兑换 / 公共世界。
--    新人照着这段就能开始玩。
-- ② help-body-veteran（老玩家）：科技漏水 / 体力 / 长期不上线。
--    这三件事都是「知道了能规划、不知道也照样上手」的规则：新人先把
--    采集→送货→攒经验这条主循环跑顺，比提前担心科技会掉、环会被公有化更重要。
-- ③ help-body-detail（老玩家）：上面那些规则的具体数字。
--
-- 老玩家的判据是 util.is_veteran（累计在线满 storage.detail_hours 小时，默认 6，可热改）。
--
-- ③ 里的数字全部现读 storage（带 nil 兜底），不写死在 locale 文本里——
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
        local extra = inner.add{type = 'label', caption = {'pw.help-body-veteran'}}
        extra.style.single_line = false
        extra.style.maximal_width = popup.WIDTH

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

    -- 交流群和项目地址【对所有人可见，且永远排在最后】。
    -- 不进分级披露：新人恰恰是最需要有个地方问问题的那一批，
    -- 把联系方式藏在"在线满 6 小时"后面完全说不通。
    inner.add{type = 'line', direction = 'horizontal'}
    local footer = inner.add{type = 'label', caption = {'pw.help-footer'}}
    footer.style.single_line = false
    footer.style.maximal_width = popup.WIDTH
end

return M
