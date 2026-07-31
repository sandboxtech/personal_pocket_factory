-- 左上角 HUD：精简后只剩两行。
-- 第一行：6 个【纯图标、无文字】的传送按钮（戴森环 + 五个公共星球），
--   直接摆在屏幕最上方，不用先点开「传送」窗口就能一键跳转。
-- 第二行：环等级、体力池当前值（不显示上限）、几个功能按钮。
--   原来挤在这里的体力进度条 / 可领取数值 / 领取按钮，全部搬进「领取」子窗口
--   （scripts/gui/claim.lua），这里只留一个入口按钮。
local ring = require('scripts.ring')
local stamina = require('scripts.stamina')
local constants = require('scripts.constants')
local util = require('scripts.util')
local popup = require('scripts.gui.popup')

local M = {}

-- 传送图标行：按钮名复用 travel.lua 已有的路由名（pw_go_ring / pw_go_<星球名>），
-- 图标本身就是点击目标，caption 直接写死成一个不含文字的富文本图标标签，
-- 不经过 locale——两种语言下这颗图标长得一样，没有可翻译的文字。
local function build_travel_icons(flow)
    local go_ring = flow.add{type = 'button', name = 'pw_go_ring', caption = '[space-location=solar-system-edge]'}
    go_ring.tooltip = {'pw.travel-home'}

    for _, name in ipairs(constants.PUBLIC_PLANETS) do
        local surface = game.surfaces[name]
        local go = flow.add{type = 'button', name = 'pw_go_' .. name, caption = '[planet=' .. name .. ']'}
        go.tooltip = {'pw.hud-go-planet-tip', name}
        if not (surface and surface.valid) then
            -- 星球 surface 还没建出来（理论上 on_init 就建好了，这里只是防御）：
            -- 禁用图标，提示原因，和 travel.lua 弹窗里那一排按钮的兜底逻辑保持一致。
            go.enabled = false
            go.tooltip = {'pw.world-not-ready', name}
        end
    end
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

    local travel_bar = root.add{type = 'flow', name = 'pw_hud_travel_bar', direction = 'horizontal'}
    build_travel_icons(travel_bar)

    local row = root.add{type = 'flow', name = 'pw_hud_main_row', direction = 'horizontal'}
    row.style.vertical_align = 'center'

    local name = player.name
    local level = ring.level_of(name)

    row.add{type = 'label', caption = {'pw.hud-level', level}}

    -- 体力池余额：只显示当前值。上限、可领取进度条、领取按钮都在「领取」子窗口里。
    row.add{type = 'label', caption = {'pw.hud-balance', stamina.balance(name)}}

    -- 戴森环宽度：新人不需要这个数字也能玩（怎么变宽在「经验」窗口和玩法说明里都讲了），
    -- 只有老玩家（在线满 storage.detail_hours 小时）才在 HUD 上多看到这一项。
    if util.is_veteran(player) then
        row.add{type = 'label', caption = {'pw.hud-ring-width', ring.half_width_of(name) * 2}}
    end

    row.add{type = 'button', name = 'pw_btn_claim', caption = {'pw.btn-claim'},
             tooltip = {'pw.btn-claim-tip'}}
    row.add{type = 'button', name = 'pw_btn_convert', caption = {'pw.btn-convert'},
             tooltip = {'pw.btn-convert-tip'}}
    row.add{type = 'button', name = 'pw_btn_exp', caption = {'pw.btn-exp'},
             tooltip = {'pw.btn-exp-tip'}}
    row.add{type = 'button', name = 'pw_btn_help', caption = {'pw.btn-help'}}
    -- 「传送」放最后：既是最不常用的一步（图标行已经能一键直达），也和弹窗里
    -- 「传送」标签页/按钮统一放在最右边的约定对上。
    row.add{type = 'button', name = 'pw_btn_travel', caption = {'pw.btn-travel'},
             tooltip = {'pw.btn-travel-tip'}}
end

return M
