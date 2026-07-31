-- 周期任务调度 + GUI 点击路由。
--
-- 不用 on_nth_tick，改走 events 总线的 on_tick 加取模门控：
-- 多个模块可以各自订阅、互不覆盖，间隔也能随时调整。
--
-- 各周期任务的取模基数刻意错开成互质的数（3607 / 3613 / 3617 而不是都用 3600），
-- 这样它们几乎不会落在同一 tick 上，避免几件重活撞在一起造成卡顿尖峰。
-- 这个技巧是从 ComfyFactorio 的 clear_vacant_players 里学的，那边注释写着 "nearest prime to 5 minutes"。
local events = require('scripts.events')
local pockets = require('scripts.pockets')
local worlds = require('scripts.worlds')
local gui = require('scripts.gui.init')

local M = {}

events.on(defines.events.on_tick, function()
    local tick = game.tick

    -- 约每分钟：检查有没有公共世界到期该重置了（一次只处理一个）
    if tick % 3607 == 0 then
        worlds.tick_check()
    end

    -- 约每分钟：戴森环离线生命周期（30h 变公共 / 50h 删除）
    if tick % 3613 == 0 then
        pockets.tick_lifecycle()
    end

    -- 约每 10 秒：刷新在线玩家的 HUD（体力和倒计时都在走）
    if tick % 613 == 0 then
        for _, player in pairs(game.connected_players) do
            gui.refresh_hud(player)
        end
    end
end)

events.on(defines.events.on_gui_click, events.safe('gui_click', function(event)
    gui.on_click(event)
end))

return M
