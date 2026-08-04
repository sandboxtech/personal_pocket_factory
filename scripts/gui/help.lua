-- 玩法说明分成简化页和详细页。默认页只讲主循环；详细页展示全部规则和具体数值。
-- 具体数字全部现读 storage（带 nil 兜底），不写死在 locale 文本里——
-- 管理员改配置后这段说明立刻跟着变，不会跟实际配置脱节。
local constants = require('scripts.constants')
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
    local summary = inner.add{type = 'label', caption = {'pw.help-body-summary'}}
    summary.style.single_line = false
    summary.style.maximal_width = popup.WIDTH
    inner.add{type = 'button', name = 'pw_help_detail', caption = {'pw.help-detail-button'}}

    inner.add{type = 'line', direction = 'horizontal'}
    local footer = inner.add{type = 'label', caption = {'pw.help-footer'}}
    footer.style.single_line = false
    footer.style.maximal_width = popup.WIDTH
end

function M.show_detail(player)
    local inner = popup.open_popup(player, {'pw.help-detail-title'})
    local content = inner.add{type = 'scroll-pane', direction = 'vertical'}
    content.style.width = popup.WIDTH - 12
    content.style.maximal_height = 650
    -- 投递口个数是玩家最常问、也是管理员最可能调的数字，所以从 storage 现读传进去，
    -- 不写死在 locale 文本里 —— 改了配置说明会跟着变，不会出现"说明说 1 个、实际能放 8 个"。
    -- 第二个参数是起始装备的补发冷却。放在【所有人都看得到】的这一段，不是塞进老玩家的
    -- 具体数值段：新人恰恰最容易死，也最容易以为"每次复活都白给一套"，
    -- 于是把一套装备当消耗品用掉，然后三小时内赤手空拳。
    local label = content.add{type = 'label', caption = {'pw.help-body',
        storage.dropoff_limit or 8,
        storage.starter_equipment_hours or 3,
    }}
    label.style.single_line = false
    label.style.maximal_width = popup.WIDTH

    -- 自动兑换只处理在线玩家。
    local extra = content.add{type = 'label', caption = {'pw.help-body-veteran',
        storage.auto_convert_minutes or 1,
    }}
    extra.style.single_line = false
    extra.style.maximal_width = popup.WIDTH

    local minutes = storage.world_reset_minutes or {}
    local public_hours = storage.ring_public_hours or 30
    local min_hours = storage.ring_min_hours or 3
    local planets = constants.PUBLIC_PLANETS
    local detail = content.add{type = 'label', caption = {'pw.help-body-detail',
        minutes[planets[1]] or 0, minutes[planets[2]] or 0, minutes[planets[3]] or 0,
        minutes[planets[4]] or 0, minutes[planets[5]] or 0,
        storage.tech_loss_k_max or 0.5,
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

    inner.add{type = 'button', name = 'pw_help_simple', caption = {'pw.help-simple-button'}}

    -- 交流群和项目地址【对所有人可见，且永远排在最后】。
    -- 不进分级披露：新人恰恰是最需要有个地方问问题的那一批，
    -- 把联系方式藏在"在线满 6 小时"后面完全说不通。
    inner.add{type = 'line', direction = 'horizontal'}
    local footer = inner.add{type = 'label', caption = {'pw.help-footer'}}
    footer.style.single_line = false
    footer.style.maximal_width = popup.WIDTH
end

return M
