-- 玩法说明弹窗。分三段，按「这条规则现在对你有没有用」决定给谁看。
--
-- ① help-body（所有人）：主循环本身 —— 环 / 死亡与补给 / 十二种经验 / 关联箱 / 公共世界。
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

-- 预警档位，降序。storage 里存的是管理员随手写的数组，顺序不保证，
-- 而说明里「5 / 1」倒过来写成「1 / 5」会让人以为先提醒 1 分钟再提醒 5 分钟。
local function warn_list()
    local src = storage.world_warn_minutes
    if type(src) ~= 'table' then src = {5, 1} end
    local out = {}
    for _, v in ipairs(src) do out[#out + 1] = v end
    table.sort(out, function(a, b) return a > b end)
    return out
end

function M.show(player)
    local inner = popup.open_popup(player, {'pw.help-title'})
    -- 投递口个数是玩家最常问、也是管理员最可能调的数字，所以从 storage 现读传进去，
    -- 不写死在 locale 文本里 —— 改了配置说明会跟着变，不会出现"说明说 1 个、实际能放 12 个"。
    -- 第二个参数是起始装备的补发冷却。放在【所有人都看得到】的这一段，不是塞进老玩家的
    -- 具体数值段：新人恰恰最容易死，也最容易以为"每次复活都白给一套"，
    -- 于是把一套装备当消耗品用掉，然后三小时内赤手空拳。
    local label = inner.add{type = 'label', caption = {'pw.help-body',
        storage.dropoff_limit or 12,
        storage.starter_equipment_hours or 3,
    }}
    label.style.single_line = false
    label.style.maximal_width = popup.WIDTH

    if util.is_veteran(player) then
        -- 自动兑换有【两档速率】（在线快、离线慢），这一版之前说明里只写了一档，
        -- 于是离线玩家会以为自己的收货箱每分钟都在被吃，实际是十分钟一次。
        local extra = inner.add{type = 'label', caption = {'pw.help-body-veteran',
            storage.auto_convert_minutes or 1,
            storage.auto_convert_offline_minutes or 10,
        }}
        extra.style.single_line = false
        extra.style.maximal_width = popup.WIDTH

        local minutes = storage.world_reset_minutes or {}
        local public_hours = storage.ring_public_hours or 30
        local min_hours = storage.ring_min_hours or 3
        local planets = constants.PUBLIC_PLANETS   -- 顺序：nauvis / vulcanus / gleba / fulgora / aquilo
        local detail = inner.add{type = 'label', caption = {'pw.help-body-detail',
            minutes[planets[1]] or 0, minutes[planets[2]] or 0, minutes[planets[3]] or 0,
            minutes[planets[4]] or 0, minutes[planets[5]] or 0,
            storage.tech_loss_k_max or 2,
            public_hours,
            -- 删除阈值不再是独立参数，是公共化阈值乘出来的（见 pockets.delete_threshold）。
            -- 这里跟着乘，而不是再读一个 storage 字段 —— 少一个能和实际规则脱节的地方。
            public_hours * (storage.ring_delete_multiple or 3),
            -- 新人的下限。上面两个是老玩家的上限，中间按累计在线时长线性缩放，
            -- 只报上限会让新人以为自己也有 30 小时可以挥霍，实际只有 3 小时。
            min_hours,
            min_hours * (storage.ring_delete_multiple or 3),
            -- 预警档位是个长度不定的数组，没法一档一个占位符，先拼成一个串再传。
            -- 用 / 分隔而不是顿号：这一栏在 11 种语言里共用同一个拼法。
            table.concat(warn_list(), ' / '),
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
