-- 「经验」内容片段：12 项经验表（图标/进度条/数值）。
--
-- 只导出 M.render(container, player)，不再自己开弹窗，见 claim.lua 顶部注释——
-- 三个子窗口合并成了一个「状态」窗口（scripts/gui/status.lua），这里只管画内容。
-- 没有按钮，所以本模块没有 on_click。
local geometry = require('scripts.geometry')
local exp = require('scripts.exp')
local ring = require('scripts.ring')
local util = require('scripts.util')

local M = {}

-- 下一个能真正拉长戴森环的门槛。0 点时攒到 1 点就会从 0 级变 1 级；
-- 之后才是 10、100、1000 这些十进制门槛（1234 → 10000，10000 → 100000）。
-- 进度条按这个算是【线性】的：1234/10000 就是 12% 进度条，不是 log10 那种压缩显示。
local function next_threshold(amount)
    if amount < 1 then return 1 end
    if amount < 10 then return 10 end
    return 10 ^ (math.floor(math.log(amount, 10)) + 1)
end

function M.render(container, player)
    local header = container.add{type = 'label', caption = {'pw.exp-title'}}
    header.style.font = 'default-bold'

    local table_data = exp.get(player.name)

    -- 新人只看进度条和"1234 / 10000"就够判断该去攒哪一项了；每项对等级的精确贡献
    -- （这一项的十进制位数）是给老玩家优化用的，新人不看这个也不影响上手。
    local veteran = util.is_veteran(player)

    container.add{type = 'label', caption = {'pw.exp-help'}}

    -- 用 table 让引擎自己排列，不手工补空格，中文字宽不等于西文，混排一定会歪。
    -- 老玩家多一列"贡献值"，新人只看图标/进度条/数量三列。
    local grid = container.add{type = 'table', name = 'pw_exp_table', column_count = veteran and 4 or 3}

    -- contribution 必须和 geometry.ring_level 用同一个算法（每项各自取位数再相加），
    -- 否则这里显示的「合计」会跟真正的等级（ring.level_of，走 geometry.ring_level）对不上。
    -- 这两处曾经因为一个是 floor(log10)、一个是「先加后 floor」而自相矛盾过，
    -- 改公式时【两边必须一起改】——它们没有共用同一个函数，只靠这条注释拴着。
    local sum = 0
    for _, short in ipairs(geometry.SCIENCE_PACKS) do
        local amount = table_data[short] or 0
        -- 和 geometry.ring_level 同一个算法：十进制位数 = floor(log10) + 1，攒到 1 点就算 1 级。
        local contribution = amount >= 1 and (math.floor(math.log(amount, 10)) + 1) or 0
        sum = sum + contribution

        local threshold = next_threshold(amount)
        local frac = math.max(0, math.min(1, amount / threshold))

        -- progressbar 的 value 是 0~1 的浮点，不受本次「取整」范围约束（它不是显示文本）。
        grid.add{type = 'sprite', sprite = 'item/' .. geometry.pack_item_name(short)}
        local bar = grid.add{type = 'progressbar', value = frac}
        bar.style.width = 120
        grid.add{type = 'label', caption = {'pw.exp-amount', util.readable(amount), util.readable(threshold)}}
        -- 显示给玩家的数字一律取整（用户明确要求"直接取整"），不再保留两位小数。
        -- contribution 本身在上面就已经是整数了，这个 math.floor 只是保险，不是重复取整的那一次。
        if veteran then
            grid.add{type = 'label', caption = {'pw.exp-contribution', math.floor(contribution)}}
        end
    end

    -- "合计 / 等级 / 环长"是给老玩家复核算法用的汇总数字；等级本身 HUD 上一直都能看到，
    -- 新人不需要在这里再看一遍，也不需要环长这种优化向数值。
    if veteran then
        local level = ring.level_of(player.name)
        container.add{type = 'label', caption = {'pw.exp-sum',
            math.floor(sum), level, ring.half_length_of(player.name) * 2}}
    end
end

return M
