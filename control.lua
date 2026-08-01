-- 戴森环计划 scenario 入口。
-- 各子模块在 require 时自行通过 events 总线注册事件，这里只负责按依赖顺序加载 + 初始化。
require('scripts.players')
require('scripts.tick')
require('scripts.chests')
require('scripts.commands')
require('scripts.ships')          -- 飞船子系统：模块内部已在顶层订阅 on_surface_created
require('scripts.world_terrain')   -- 公共世界地貌斑块：模块内部已在顶层订阅 on_chunk_generated

local constants = require('scripts.constants')
local events = require('scripts.events')
local worlds = require('scripts.worlds')
local players = require('scripts.players')
local ring = require('scripts.ring')
local pockets = require('scripts.pockets')

-- 区块生成时涂砖。走 events 总线而不是直接 script.on_event，避免和别处的订阅互相覆盖。
events.on(defines.events.on_chunk_generated, events.safe('chunk', ring.on_chunk_generated))

-- 解锁星图上的全部传送点。
-- 注意 unlock_space_location 和 create_surface 是【两件事】：
-- 前者只让星图上的点变成可见可选，后者才真的把 surface 建出来。
-- 本场景两件都做：surface 由 worlds.ensure_surfaces() 显式建出，传送点由这里解锁。
-- 幂等：已解锁的地点再解锁一次没有副作用。
--
-- 【遍历 prototypes.space_location，而不是只遍历 PUBLIC_PLANETS】：
-- 星图上的地点不止五个公共星球，还有 solar-system-edge 和 shattered-planet。
-- 只解锁五个星球的话，普罗米修斯瓶（唯一来源是破碎星球）永远拿不到，
-- 而普罗米修斯经验是决定环宽的 12 项之一 —— 等于有一项经验被永久锁死，
-- 玩家怎么攒都差这一项。空间位置全解锁才和「12 种瓶子都要集齐」这个核心设定自洽。
local function unlock_all_space_locations()
    local force = game.forces.player
    for name in pairs(prototypes.space_location) do
        force.unlock_space_location(name)
    end
end

-- 第一次运行本场景时触发。
script.on_init(function()
    constants.ensure_defaults()
    players.setup_perm_group()
    unlock_all_space_locations()

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
    unlock_all_space_locations()
    worlds.ensure_surfaces()
    worlds.schedule_all(false) -- 已排期的世界保持原计划，只给新增的补排
    -- 把已存在的戴森环全部重新 ensure 一遍，补齐半成品环缺失的收货箱阵。
    -- 老存档升级正是这类修复该发生的时机：玩家不用重连，加载完就已经是修好的。
    pockets.repair_all()
end)
