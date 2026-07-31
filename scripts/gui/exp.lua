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

    local sum = 0
    for _, short in ipairs(geometry.SCIENCE_PACKS) do
        local amount = table_data[short] or 0
        local contribution = amount > 1 and math.log(amount, 10) or 0
        sum = sum + contribution

        local threshold = next_threshold(amount)
        local frac = math.max(0, math.min(1, amount / threshold))

        grid.add{type = 'sprite', sprite = 'item/' .. geometry.pack_item_name(short)}
        local bar = grid.add{type = 'progressbar', value = frac}
        bar.style.width = 120
        grid.add{type = 'label', caption = {'pw.exp-amount', util.readable(amount), util.readable(threshold)}}
        grid.add{type = 'label', caption = {'pw.exp-contribution', string.format('%.2f', contribution)}}
    end

    local level = ring.level_of(player.name)
    inner.add{type = 'label', caption = {'pw.exp-sum',
        string.format('%.2f', sum), level, ring.half_width_of(player.name) * 2}}
    inner.add{type = 'label', caption = {'pw.exp-next',
        string.format('%.2f', level + 1 - sum)}}
end

return M
