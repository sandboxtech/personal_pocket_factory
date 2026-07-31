-- 左上角 HUD + 各功能弹窗。
--
-- 全部用引擎自带的 style，不引入任何图片资源，scenario 目录就能跑起来。
-- HUD 每 10 秒由 tick.lua 刷新一次（体力在涨、世界倒计时在走）。
local constants = require('scripts.constants')
local util = require('scripts.util')
local stamina = require('scripts.stamina')
local exp = require('scripts.exp')
local pockets = require('scripts.pockets')
local worlds = require('scripts.worlds')

local M = {}

local HUD_NAME = 'pw_hud'
local POPUP_NAME = 'pw_popup'

-- 关掉可能已存在的弹窗，保证同时只有一个，不会叠罗汉
local function close_popup(player)
    local existing = player.gui.screen[POPUP_NAME]
    if existing then existing.destroy() end
end

-- 建一个居中的空弹窗框架，返回内容容器供调用方填充
local function open_popup(player, title)
    close_popup(player)
    local frame = player.gui.screen.add{type = 'frame', name = POPUP_NAME, caption = title, direction = 'vertical'}
    frame.auto_center = true
    local inner = frame.add{type = 'flow', name = 'inner', direction = 'vertical'}
    frame.add{type = 'button', name = 'pw_close', caption = {'pw.close'}}
    return inner
end

-------------------------------------------------------------------------------
-- HUD
-------------------------------------------------------------------------------

function M.refresh_hud(player)
    local root = player.gui.top[HUD_NAME]
    if not root then
        root = player.gui.top.add{type = 'frame', name = HUD_NAME, direction = 'horizontal'}
    end
    root.clear()

    local player_exp = exp.get(player.name)
    local level = util.level_of(player_exp)
    local to_next = util.exp_to_next(player_exp)

    root.add{type = 'label', caption = {'pw.hud-level', level, util.readable(player_exp), util.readable(to_next)}}
    root.add{type = 'label', caption = {'pw.hud-stamina', stamina.get(player.name), storage.stamina_cap or 1440}}

    root.add{type = 'button', name = 'pw_btn_convert', caption = {'pw.btn-convert'},
             tooltip = {'pw.btn-convert-tip'}}
    root.add{type = 'button', name = 'pw_btn_pocket', caption = {'pw.btn-pocket'},
             tooltip = {'pw.btn-pocket-tip'}}
    root.add{type = 'button', name = 'pw_btn_worlds', caption = {'pw.btn-worlds'},
             tooltip = {'pw.btn-worlds-tip'}}
    root.add{type = 'button', name = 'pw_btn_help', caption = {'pw.btn-help'}}
end

-------------------------------------------------------------------------------
-- 兑换窗口
-------------------------------------------------------------------------------

local function show_convert(player)
    local inner = open_popup(player, {'pw.convert-title'})
    local gain, cost, total = exp.preview(player)

    inner.add{type = 'label', caption = {'pw.convert-value', string.format('%.1f', total)}}
    inner.add{type = 'label', caption = {'pw.convert-gain', util.readable(gain), cost}}
    inner.add{type = 'label', caption = {'pw.convert-have', stamina.get(player.name)}}

    local button = inner.add{type = 'button', name = 'pw_do_convert', caption = {'pw.convert-do'}}
    if gain <= 0 then
        button.enabled = false
        button.tooltip = {'pw.convert-cannot'}
    end
end

-------------------------------------------------------------------------------
-- 世界列表：显示每个公共世界的重置倒计时，点击前往
-------------------------------------------------------------------------------

local function show_worlds(player)
    local inner = open_popup(player, {'pw.worlds-title'})
    inner.add{type = 'label', caption = {'pw.worlds-help'}}

    for _, name in ipairs(constants.PUBLIC_PLANETS) do
        local row = inner.add{type = 'flow', direction = 'horizontal'}
        local surface = game.surfaces[name]
        local left_minutes = math.max(0, math.floor(worlds.time_left(name) / constants.min_to_tick))
        local run = (storage.world_run or {})[name] or 0

        row.add{type = 'label', caption = {'pw.worlds-entry', name, left_minutes, run}}
        local go = row.add{type = 'button', name = 'pw_go_' .. name, caption = {'pw.worlds-go'}}
        if not (surface and surface.valid) then
            go.enabled = false
            go.tooltip = {'pw.world-not-ready', name}
        end
    end
end

-------------------------------------------------------------------------------
-- 玩法说明
-------------------------------------------------------------------------------

local function show_help(player)
    local inner = open_popup(player, {'pw.help-title'})
    local label = inner.add{type = 'label', caption = {'pw.help-body'}}
    label.style.single_line = false
    label.style.maximal_width = 520
end

-------------------------------------------------------------------------------
-- 点击路由
-------------------------------------------------------------------------------

function M.on_click(event)
    local element = event.element
    if not (element and element.valid) then return end
    local player = game.players[event.player_index]
    if not player then return end
    local name = element.name

    if name == 'pw_close' then
        close_popup(player)

    elseif name == 'pw_btn_convert' then
        show_convert(player)

    elseif name == 'pw_do_convert' then
        local gain, err = exp.convert(player)
        if gain then
            player.print({'pw.convert-done', util.readable(gain)})
        else
            player.print({err or 'pw.convert-nothing'})
        end
        close_popup(player)
        M.refresh_hud(player)

    elseif name == 'pw_btn_pocket' then
        pockets.enter(player)
        close_popup(player)

    elseif name == 'pw_btn_worlds' then
        show_worlds(player)

    elseif name == 'pw_btn_help' then
        show_help(player)

    elseif string.sub(name, 1, 6) == 'pw_go_' then
        local planet = string.sub(name, 7)
        worlds.travel(player, planet)
        close_popup(player)
    end
end

return M
