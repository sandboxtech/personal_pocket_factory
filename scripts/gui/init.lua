-- GUI 路由 + 弹窗骨架。各窗口模块只管往容器里填内容。
-- 全部用引擎自带 style，不引入任何图片资源，scenario 目录就能跑起来。
--
-- 公共辅助（open_popup / close_popup / 两个名字常量）住在叶子模块 popup.lua，
-- 而不是这里：几个窗口子模块（status / travel / help，以及 status 内部组合的
-- claim / convert / exp）也要用这些辅助，如果放在 init.lua 里，子模块就得反过来
-- require init，形成循环依赖，而 Factorio 禁止用"函数体内 require"去绕开循环
-- （只能在模块顶层 require）。抽成叶子模块从依赖图上直接消掉这个环。
local popup = require('scripts.gui.popup')
local hud = require('scripts.gui.hud')
local travel = require('scripts.gui.travel')
local help = require('scripts.gui.help')
local status = require('scripts.gui.status')

local M = {}

-- 转发给老调用点，避免它们直接依赖 popup
M.HUD_NAME = popup.HUD_NAME
M.POPUP_NAME = popup.POPUP_NAME
M.open_popup = popup.open_popup
M.close_popup = popup.close_popup

function M.refresh_hud(player)
    hud.refresh(player)
end

function M.on_click(event)
    local element = event.element
    if not (element and element.valid) then return end
    local player = game.players[event.player_index]
    if not player then return end
    local name = element.name

    if name == 'pw_close' then
        popup.close_popup(player)
    elseif name == 'pw_btn_travel' then
        travel.show(player)
    elseif name == 'pw_btn_status' then
        status.show(player)
    elseif name == 'pw_btn_help' then
        help.show(player)
    elseif travel.on_click(player, name) then
        return
    elseif status.on_click(player, name) then
        return
    end
end

return M
