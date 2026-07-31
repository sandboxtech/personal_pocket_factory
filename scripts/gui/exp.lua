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

-- 下一个能真正加宽等级环的门槛：10 的下一个整次幂。amount < 10 时门槛固定是 10，
-- 否则是比 amount 大的最小 10 次幂（1234 → 10000，10000 → 100000）。
-- 进度条按这个算是【线性】的：1234/10000 就是 12% 进度条，不是 log10 那种压缩显示。
local function next_threshold(amount)
    if amount < 10 then return 10 end
    return 10 ^ (math.floor(math.log(amount, 10)) + 1)
end

function M.render(container, player)
    local header = container.add{type = 'label', caption = {'pw.exp-title'}}
    header.style.font = 'default-bold'

    local table_data = exp.get(player.name)

    -- 新人只看进度条和"1234 / 10000"就够判断该去攒哪一项了；每项对等级的精确贡献
    -- （log10 取整后的那个数）是给老玩家优化用的，新人不看这个也不影响上手。
    local veteran = util.is_veteran(player)

    container.add{type = 'label', caption = {'pw.exp-help'}}

    -- 用 table 让引擎自己排列，不手工补空格，中文字宽不等于西文，混排一定会歪。
    -- 老玩家多一列"贡献值"，新人只看图标/进度条/数量三列。
    local grid = container.add{type = 'table', name = 'pw_exp_table', column_count = veteran and 4 or 3}

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
        if veteran then
            grid.add{type = 'label', caption = {'pw.exp-contribution', math.floor(contribution)}}
        end
    end

    -- "合计 / 等级 / 环宽"是给老玩家复核算法用的汇总数字；等级本身 HUD 上一直都能看到，
    -- 新人不需要在这里再看一遍，也不需要环宽这种优化向数值。
    if veteran then
        local level = ring.level_of(player.name)
        container.add{type = 'label', caption = {'pw.exp-sum',
            math.floor(sum), level, ring.half_width_of(player.name) * 2}}
    end
    container.add{type = 'label', caption = {'pw.exp-next',
        util.readable(math.ceil(min_remaining or 0))}}
end

return M
