-- 戴森环计划 scenario 入口。
-- 各子模块在 require 时自行通过 events 总线注册事件，这里只负责按依赖顺序加载 + 初始化。
require('scripts.players')
require('scripts.tick')
require('scripts.chests')
require('scripts.commands')

local constants = require('scripts.constants')
local events = require('scripts.events')
local worlds = require('scripts.worlds')
local players = require('scripts.players')
local ring = require('scripts.ring')

-- 区块生成时涂砖。走 events 总线而不是直接 script.on_event，避免和别处的订阅互相覆盖。
events.on(defines.events.on_chunk_generated, events.safe('chunk', ring.on_chunk_generated))

-- 第一次运行本场景时触发。
script.on_init(function()
    constants.ensure_defaults()
    players.setup_perm_group()

    worlds.ensure_surfaces()   -- 把五个星球的 surface 显式建出来，不再等玩家开船降落
    for _, name in ipairs(constants.PUBLIC_PLANETS) do
        local surface = game.surfaces[name]
        if surface then worlds.apply_bounds(surface) end
    end
    worlds.schedule_all(true)  -- 首次排期：把五个世界的重置时刻均匀铺开
end)

-- 场景脚本变化后加载老存档时触发：补齐新增的默认字段，保证平滑升级。
script.on_configuration_changed(function()
    constants.ensure_defaults()
    players.setup_perm_group()
    worlds.ensure_surfaces()
    worlds.schedule_all(false) -- 已排期的世界保持原计划，只给新增的补排
end)
