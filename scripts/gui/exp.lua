local geometry = require('scripts.geometry')
local exp = require('scripts.exp')
local ring = require('scripts.ring')
local util = require('scripts.util')
local popup = require('scripts.gui.popup')

local M = {}

-- 下一个能真正加宽等级环的门槛：10 的下一个整次幂。amount < 10 时门槛固定是 10，
-- 否则是比 amount 大的最小 10 次幂（1234 → 10000，10000 → 100000）。
-- 进度条按这个算是【线性】的：1234/10000 就是 12% 进度条，不是 log10 那种压缩显示。
local function next_threshold(amount)
    if amount < 10 then return 10 end
    return 10 ^ (math.floor(math.log(amount, 10)) + 1)
end

function M.show(player)
    local inner = popup.open_popup(player, {'pw.exp-title'})
    local table_data = exp.get(player.name)

    inner.add{type = 'label', caption = {'pw.exp-help'}}

    -- 用 table 让引擎自己排列四列，不手工补空格——中文字宽不等于西文，混排一定会歪。
    local grid = inner.add{type = 'table', name = 'pw_exp_table', column_count = 4}

    -- contribution 必须和 geometry.ring_level 用同一个算法（每项各自 floor 再相加），
    -- 否则这里显示的「合计」会跟真正的等级（ring.level_of，走 geometry.ring_level）对不上——
    -- 旧代码在这里是「先加 log10 原始值、最后统一 floor 一次」，那是改公式之前的算法，
    -- 两种瓶子各 99 点时旧代码会算出合计 3，但真实等级已经是 2，界面会自相矛盾。
    local sum = 0
    -- 还差多远才能再长一级：不能再用「全局的分数差」，因为新公式下 sum 恒等于 level（都是整数），
    -- level + 1 - sum 恒为 1，那条提示会失去意义。改成【找 12 项里离自己下一个数量级门槛最近的那项】，
    -- 距离用真实数量（不是 log10 值）表示，跟每项进度条「1234 / 10000」的线性单位保持一致——
    -- 玩家只要把那一项攒够这个数，等级就会真的涨。
    local min_remaining = nil
    for _, short in ipairs(geometry.SCIENCE_PACKS) do
        local amount = table_data[short] or 0
        local contribution = amount >= 1 and math.floor(math.log(amount, 10)) or 0
        sum = sum + contribution

        local threshold = next_threshold(amount)
        local frac = math.max(0, math.min(1, amount / threshold))
        local remaining = threshold - amount
        if not min_remaining or remaining < min_remaining then
            min_remaining = remaining
        end

        -- progressbar 的 value 是 0~1 的浮点，不受本次「取整」范围约束（它不是显示文本）。
        grid.add{type = 'sprite', sprite = 'item/' .. geometry.pack_item_name(short)}
        local bar = grid.add{type = 'progressbar', value = frac}
        bar.style.width = 120
        grid.add{type = 'label', caption = {'pw.exp-amount', util.readable(amount), util.readable(threshold)}}
        -- 显示给玩家的数字一律取整（用户明确要求"直接取整"），不再保留两位小数。
        -- contribution 本身在上面就已经是整数了，这个 math.floor 只是保险，不是重复取整的那一次。
        grid.add{type = 'label', caption = {'pw.exp-contribution', math.floor(contribution)}}
    end

    local level = ring.level_of(player.name)
    inner.add{type = 'label', caption = {'pw.exp-sum',
        math.floor(sum), level, ring.half_width_of(player.name) * 2}}
    inner.add{type = 'label', caption = {'pw.exp-next',
        util.readable(math.ceil(min_remaining or 0))}}
end

return M
