-- GUI 路由 + 弹窗骨架。各窗口模块只管往容器里填内容。
-- 全部用引擎自带 style，不引入任何图片资源，scenario 目录就能跑起来。
local M = {}

M.HUD_NAME = 'pw_hud'
M.POPUP_NAME = 'pw_popup'

-- 关掉可能已存在的弹窗，保证同时只有一个，不会叠罗汉
function M.close_popup(player)
    local existing = player.gui.screen[M.POPUP_NAME]
    if existing then existing.destroy() end
end

-- 建一个居中的空弹窗框架，返回内容容器供调用方填充
function M.open_popup(player, title)
    M.close_popup(player)
    local frame = player.gui.screen.add{
        type = 'frame', name = M.POPUP_NAME, caption = title, direction = 'vertical'}
    frame.auto_center = true
    local inner = frame.add{type = 'flow', name = 'inner', direction = 'vertical'}
    frame.add{type = 'button', name = 'pw_close', caption = {'pw.close'}}
    return inner
end

-- 子模块要用 open_popup，所以必须在 M 定义之后 require（循环依赖）
local hud = require('scripts.gui.hud')
local convert = require('scripts.gui.convert')
local travel = require('scripts.gui.travel')
local exp_window = require('scripts.gui.exp')
local help = require('scripts.gui.help')

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
        M.close_popup(player)
    elseif name == 'pw_btn_convert' then
        convert.show(player)
    elseif name == 'pw_btn_travel' then
        travel.show(player)
    elseif name == 'pw_btn_exp' then
        exp_window.show(player)
    elseif name == 'pw_btn_help' then
        help.show(player)
    elseif convert.on_click(player, name) then
        return
    elseif travel.on_click(player, name) then
        return
    end
end

return M
