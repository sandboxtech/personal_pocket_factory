-- 管理员配置总览窗口（/pw-config 打开）。
--
-- 为什么是窗口而不是往聊天框里打：31 个配置项打进聊天框会把之前的消息全顶掉，
-- 而且聊天框不能回滚太多、也不能选中复制。配置这种「对照着看、挑一个抄出来改」
-- 的东西天生需要一个能滚动的表格。
--
-- 表格四列：字段名 / 当前值 / 生效范围 / 说明。
-- 【生效范围那一列是这个窗口存在的主要理由】——有些字段改完立刻全服生效，
-- 有些只对之后新建的东西管用。管理员没法从字段名看出区别，改了不生效
-- 又会以为是 bug，然后去翻代码。把这件事写在值旁边，比写在文档里有用得多。
local constants = require('scripts.constants')
local popup = require('scripts.gui.popup')

local M = {}

-- 本窗口比别的宽：要并排放下字段名、值、生效范围、说明四列，
-- 挤在 popup.WIDTH（520）里会让说明那一列频繁换行，反而更难扫。
local WIDTH = 900

-- 生效范围 → 颜色。绿=立刻生效，黄=有条件，灰=不生效。
-- 颜色是给「扫一眼找出哪些能立刻试」用的，文字说明在 tooltip 里。
local APPLIES_COLOR = {
    live = 'green', grow = 'green',
    repaint = 'yellow', reset = 'yellow', new = 'yellow',
    dead = 'gray',
}

-- 把一个 storage 值渲染成【能直接粘回控制台】的 Lua 字面量。
-- 字符串要带引号 —— 少了这层，管理员照着显示的值抄一遍会写出
-- storage.ship_home_planet = nauvis（把星球名当全局变量读，值是 nil）。
local function literal(value)
    if type(value) == 'string' then return "'" .. value .. "'" end
    return tostring(value)
end

-- 物品清单类配置的当前值，渲染成图标 + 数量。
--
-- 只有这一类表享受「显示当前值」的待遇，因为它们是仅有的【短、且管理员改它之前
-- 一定想先看看现在发的是什么】的表配置：其余几张要么长得离谱（world_patch_tiles
-- 有上百个砖名），要么结构一眼能猜到（world_reset_minutes），给个示例就够了。
--
-- 【元素个数必须夹住】：LocalisedString 最多 20 个参数，超了整条字符串会渲染失败
-- （玩家看到的是一行 "Unknown key" 而不是配置表）。管理员把礼包配成 30 项是完全合理的事，
-- 不能让它把这个窗口打崩，所以超出部分折叠成省略号。
local MAX_ITEM_ICONS = 15

-- 值为 {{name=, count=}, ...} 的配置项，都按图标渲染当前值。
local ITEM_LIST_KEYS = {starter_items = true, starter_equipment = true}

local function item_list_caption(key)
    local items = storage[key] or {}
    if #items == 0 then return '{}' end

    local parts = {''}
    for i, it in ipairs(items) do
        if i > MAX_ITEM_ICONS then
            parts[#parts + 1] = string.format('… (+%d)', #items - MAX_ITEM_ICONS)
            break
        end
        -- 物品名写错时富文本会渲染成一个找不到图标的方框，看不出错在哪，
        -- 所以先查原型：不存在就直接把名字原样打出来，管理员一眼能看见错别字。
        local name = tostring(it.name)
        if prototypes.item[name] then
            parts[#parts + 1] = string.format('[item=%s]%s  ', name, tostring(it.count or 1))
        else
            parts[#parts + 1] = string.format('[color=red]%s[/color]×%s  ', name, tostring(it.count or 1))
        end
    end
    return parts
end

local function applies_cell(grid, applies)
    local color = APPLIES_COLOR[applies] or 'gray'
    local label = grid.add{type = 'label',
        caption = {'', '[color=' .. color .. ']', {'pw.cfg-applies-' .. applies}, '[/color]'}}
    label.tooltip = {'pw.cfg-applies-' .. applies .. '-tip'}
    return label
end

-- 【每行必须正好占 4 格】。这是个 column_count = 4 的 table，少填或多填一格，
-- 后面所有行都会整体错位一列。所以"值"这一格哪怕要放两行文字，也必须先塞一个 flow
-- 把它们装进【同一格】里，不能直接 add 两个 label。
local function row(grid, key, value_caption, applies, is_example, example_caption)
    -- 字段名一列直接给出可复制的完整写法，不用管理员自己拼 storage. 前缀
    grid.add{type = 'label', caption = '[color=yellow]storage.' .. key .. '[/color]'}

    local cell = grid.add{type = 'flow', direction = 'vertical'}
    local value = cell.add{type = 'label', caption = value_caption}
    if is_example then
        -- 表结构没有"一个值"可显示，这一格放的是改法示例，用灰色和真实值区分开
        value.style.font_color = {0.7, 0.7, 0.7}
    end
    if example_caption then
        -- 当前值上面已经显示了，这一行是改法示例：灰色、可整行复制粘进控制台。
        local example = cell.add{type = 'label', caption = example_caption}
        example.style.font_color = {0.7, 0.7, 0.7}
        example.style.single_line = false
        example.style.maximal_width = 320
    end

    applies_cell(grid, applies)

    local desc = grid.add{type = 'label', caption = {'pw.cfg-' .. string.gsub(key, '_', '-')}}
    desc.style.single_line = false
    desc.style.maximal_width = 380
end

function M.show(player)
    local inner = popup.open_popup(player, {'pw.cfg-title'})
    inner.style.width = WIDTH

    local head = inner.add{type = 'label', caption = {'pw.cfg-head'}}
    head.style.single_line = false
    head.style.maximal_width = WIDTH

    local scroll = inner.add{type = 'scroll-pane', name = 'pw_cfg_scroll', direction = 'vertical'}
    scroll.style.width = WIDTH - 12
    scroll.style.maximal_height = 600

    for _, group in ipairs(constants.TUNABLE_GROUPS) do
        local scalars, tables_ = {}, {}
        for _, item in ipairs(constants.TUNABLES) do
            if item.group == group then scalars[#scalars + 1] = item end
        end
        for _, item in ipairs(constants.TUNABLE_TABLES) do
            if item.group == group then tables_[#tables_ + 1] = item end
        end
        if #scalars + #tables_ > 0 then
            local title = scroll.add{type = 'label', caption = {'pw.cfg-group-' .. group}}
            title.style.font = 'default-bold'
            title.style.top_padding = 8

            -- 每组一张独立的表。用一张大表也行，但分组标题得跨列合并，
            -- Factorio 的 table 没有跨列，只能靠"一组一张表"来实现分段。
            local grid = scroll.add{type = 'table', column_count = 4}
            grid.style.horizontal_spacing = 12
            grid.style.vertical_spacing = 2

            for _, item in ipairs(scalars) do
                row(grid, item.key, '[color=acid]' .. literal(storage[item.key]) .. '[/color]',
                    item.applies, false)
            end
            for _, item in ipairs(tables_) do
                if ITEM_LIST_KEYS[item.key] then
                    -- 物品清单：当前值（图标）在上、改法示例在下。理由见 item_list_caption。
                    row(grid, item.key, item_list_caption(item.key), item.applies, false, item.example)
                else
                    row(grid, item.key, item.example, item.applies, true)
                end
            end
        end
    end
end

return M
