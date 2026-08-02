-- 左上角常驻 HUD。两行，视觉上分成三块：
--
--   ┌──────────────────────────────────────────┐
--   │ ┌ 凹陷槽 ─────────────────┐              │   ← 传送图标条
--   │ │ [环][N][V][G][F][A]     │              │
--   │ └─────────────────────────┘              │
--   │ Lv.4  [电]1234  宽128 │ [状态][全服][传送][?] │   ← 数据 | 分隔线 | 按钮
--   └──────────────────────────────────────────┘
--
-- 三条布局上的讲究，都不是纯装饰：
--
-- ① 传送图标条套一层 inside_deep_frame（凹陷槽）。六颗图标按钮如果直接摆在
--    外层 frame 上，会和下面那行的功能按钮糊成"一堆按钮"，玩家分不清哪些是
--    "去某地"、哪些是"开某个窗口"。凹进去一层，它就读作一个独立的工具条。
--
-- ② 数据和按钮之间插一条竖线。左边是【状态】（只读，看一眼就走），
--    右边是【操作】（点了会发生事情）。这两类东西并排放而不加分隔的话，
--    "Lv.4" 和一颗按钮在余光里长得一样。
--
-- ③ 按钮一律用 tool_button（32×32 图标按钮），不用带文字的默认按钮。
--    四个文字按钮横排会把 HUD 撑得很宽，而 HUD 是常驻的，占宽度就是永久成本。
--    代价是要靠 tooltip 说明用途，所以每颗都必须有 tooltip（下面 action 里强制传）。
local ring = require('scripts.ring')
local stamina = require('scripts.stamina')
local constants = require('scripts.constants')
local util = require('scripts.util')
local popup = require('scripts.gui.popup')
local worlds = require('scripts.worlds')

local M = {}

-- 传送图标行：按钮名复用 travel.lua 已有的路由名（pw_go_ring / pw_go_<星球名>），
-- 图标本身就是点击目标，caption 直接写死成一个不含文字的富文本标签，
-- 不经过 locale——两种语言下这颗图标长得一样，没有可翻译的文字。
--
-- tooltip 不一样：图标行本身没有文字，玩家得靠 tooltip 才知道点下去去哪儿，
-- 所以 tooltip 里嵌 util.planet_label（[planet=xxx] 图标 + 引擎自带的本地化星球名），
-- 而不是甩一个裸的 surface 名（比如 "nauvis"）当纯文本。
local function build_travel_bar(parent)
    -- 凹陷槽：让这六颗"去某地"的按钮和下面"开某个窗口"的按钮在视觉上分开。
    local slot = parent.add{type = 'frame', name = 'pw_hud_travel_slot', style = 'inside_deep_frame'}
    local bar = slot.add{type = 'flow', name = 'pw_hud_travel_bar', direction = 'horizontal'}
    bar.style.horizontal_spacing = 0    -- 图标按钮紧挨着，读作一整条工具条

    local go_ring = bar.add{type = 'button', name = 'pw_go_ring', style = 'tool_button',
                            caption = '[space-location=solar-system-edge]'}
    go_ring.tooltip = {'pw.travel-home'}

    for _, name in ipairs(constants.PUBLIC_PLANETS) do
        local surface = game.surfaces[name]
        local go = bar.add{type = 'button', name = 'pw_go_' .. name, style = 'tool_button',
                           caption = '[planet=' .. name .. ']'}
        go.tooltip = {'pw.hud-go-planet-tip', util.planet_label(name)}
        if not (surface and surface.valid) then
            -- 星球 surface 还没建出来（理论上 on_init 就建好了，这里只是防御）：
            -- 禁用图标，提示原因，和 travel.lua 弹窗里那一排按钮的兜底逻辑保持一致。
            go.enabled = false
            go.tooltip = {'pw.world-not-ready', util.planet_label(name)}
        elseif not worlds.is_travel_open(name) then
            go.enabled = false
            go.tooltip = {'pw.world-closed', util.planet_label(name)}
        end
    end
end

-- 功能按钮。tooltip 是【必填参数】而不是可选项：这些按钮只有图标没有文字，
-- 漏了 tooltip 的那一颗，玩家就完全不知道它是干什么的。
local function action(parent, name, icon, tooltip)
    local button = parent.add{type = 'button', name = name, style = 'tool_button', caption = icon}
    button.tooltip = tooltip
    return button
end

-- 同时承担"不存在就创建"和"刷新内容"两件事：不存在就 add 一个，然后统一 clear()
-- 重建里面的内容，所以【任何时候调用这个函数都是安全的】——不用管 HUD 到底建没建过。
--
-- 但反过来不能把"创建"这件事全权交给周期任务（scripts/tick.lua 里的定时刷新）：
-- 玩家一进场就该看到 HUD，若只靠周期任务顺手建出来，UI 出现的时间就被刷新间隔
-- （storage.hud_refresh_ticks）绑架了——间隔一降低到分钟级，新玩家就要真等那么久
-- 才看到任何界面。所以 scripts/players.lua 在 on_player_created / on_player_joined_game
-- 里都会主动调一次 gui.refresh_hud(player)，创建职责不能只挂在刷新循环上。
function M.refresh(player)
    local root = player.gui.top[popup.HUD_NAME]
    if not root then
        root = player.gui.top.add{type = 'frame', name = popup.HUD_NAME, direction = 'vertical'}
    end
    root.clear()
    root.style.padding = 4

    -- 两行装进一个竖向 flow，行间距设在【flow】上而不是外层 frame 上。
    -- vertical_spacing / horizontal_spacing 是 Table/Flow/VerticalFlow 样式独有的属性，
    -- 赋给 frame 会直接抛 "Expected Table or Flow Or VerticalFlow but was Frame"。
    -- 这类错误 luac 和静态检查都看不见：属性名拼写正确、类型也对，
    -- 只是这个属性不存在于这一类样式上，非得渲染到那一行才炸。
    local content = root.add{type = 'flow', name = 'pw_hud_content', direction = 'vertical'}
    content.style.vertical_spacing = 4

    build_travel_bar(content)

    local row = content.add{type = 'flow', name = 'pw_hud_main_row', direction = 'horizontal'}
    row.style.vertical_align = 'center'
    row.style.horizontal_spacing = 8

    local name = player.name

    -- 等级和体力用加粗样式：这两个数字是玩家最常瞥一眼的东西，
    -- 混在普通标签里会被旁边的按钮抢掉注意力。
    local level = row.add{type = 'label', caption = {'pw.hud-level', ring.level_of(name)}}
    level.style.font = 'default-bold'

    -- 体力池余额：只显示当前值。上限、可领取进度条、领取按钮都在「状态」窗口里。
    local balance = row.add{type = 'label', caption = {'pw.hud-balance', stamina.balance(name)}}
    balance.style.font = 'default-bold'

    -- 戴森环长度：新人不需要这个数字也能玩（怎么变长在「经验」窗口和玩法说明里都讲了），
    -- 只有老玩家（在线满 storage.detail_hours 小时）才在 HUD 上多看到这一项。
    if util.is_veteran(player) then
        row.add{type = 'label', caption = {'pw.hud-ring-length', ring.half_length_of(name) * 2}}
    end

    -- 竖线分隔【只读数据】和【会发生事情的按钮】，见文件头 ② 。
    row.add{type = 'line', direction = 'vertical'}

    -- 原来的「领取／兑换／经验」三个按钮早已合并成一个：三块内容本来就要互相参照着看
    -- （体力够不够兑换、兑换完经验涨没涨），分开点三次纯属多余的操作成本。
    action(row, 'pw_btn_status', '[img=virtual-signal/signal-battery-mid-level]', {'pw.btn-status-tip'})
    action(row, 'pw_btn_overview', '[img=virtual-signal/signal-info]', {'pw.btn-overview-tip'})
    -- 「传送」放按钮组最后：图标行已经能一键直达，弹窗里那份是带倒计时的完整版，
    -- 属于"想规划一下再走"时才点的东西。
    action(row, 'pw_btn_travel', '[img=space-location/solar-system-edge]', {'pw.btn-travel-tip'})
    action(row, 'pw_btn_help', '[img=utility/questionmark]', {'pw.btn-help-tip'})
end

return M
