-- 「把世界弄成它应该有的样子」的那一套步骤，全部幂等。
--
-- 为什么要单独成一个模块：这套步骤有三个调用方，而且必须完全一致 ——
--   · on_init                 新开局
--   · on_configuration_changed 脚本变化后加载老存档
--   · /pw-repair              管理员手动触发
-- 抄三份的话，加一步（比如后来加的「锁住原生建船按钮」）就必然漏掉一两处，
-- 而漏掉的那处症状会非常隐晦：新开的服正常，只有升级上来的老存档少了一步。
--
-- 【幂等是硬要求，不是风格偏好】：/pw-repair 允许管理员在任何时刻、连打十次，
-- 这里每一步都必须能重复执行而不累积副作用。目前各步的幂等性来源：
--   · ensure_defaults      只补 == nil 的字段
--   · setup_perm_group     取已有组，没有才建
--   · unlock_space_location 已解锁的再解锁无副作用（引擎行为）
--   · enforce_lock         只是重设一个布尔
--   · ensure_surfaces      已存在的 surface 跳过
--   · apply_bounds         还原到原型状态再叠加固定的一组值，不累积
--   · repair_all           对每条已存在的环调 pockets.ensure，本身就是自愈函数
local constants = require('scripts.constants')
local players = require('scripts.players')
local worlds = require('scripts.worlds')
local ships = require('scripts.ships')
local pockets = require('scripts.pockets')

local M = {}

-- 解锁星图上的全部传送点。
-- 注意 unlock_space_location 和 create_surface 是【两件事】：
-- 前者只让星图上的点变成可见可选，后者才真的把 surface 建出来。
-- 本场景两件都做：surface 由 worlds.ensure_surfaces() 显式建出，传送点由这里解锁。
--
-- 【遍历 prototypes.space_location，而不是只遍历 PUBLIC_PLANETS】：
-- 星图上的地点不止五个公共星球，还有 solar-system-edge 和 shattered-planet。
-- 只解锁五个星球的话，普罗米修斯瓶（唯一来源是破碎星球）永远拿不到，
    -- 而普罗米修斯经验是决定环长的 12 项之一 —— 等于有一项经验被永久锁死，
-- 玩家怎么攒都差这一项。空间位置全解锁才和「12 种瓶子都要集齐」这个核心设定自洽。
function M.unlock_all_space_locations()
    local force = game.forces.player
    for name in pairs(prototypes.space_location) do
        force.unlock_space_location(name)
    end
end

-- 跑一遍全部初始化/修复步骤。返回 {planets = 处理了几颗星球, rings = 校准了几条环}。
--
-- respread = true 时重新把五个世界的重置时刻均匀铺开（只有新开局该这么做）；
-- false 则保留已排期的计划、只给新增的世界补排 —— 老存档上重新铺开会让
-- 所有人正在计算的倒计时集体跳变，那是纯粹的破坏。
function M.run(respread)
    constants.ensure_defaults()
    players.setup_perm_group()
    M.unlock_all_space_locations()
    ships.enforce_lock()        -- 禁用原生建船按钮，UI 是唯一入口

    worlds.ensure_surfaces()    -- 把五个星球的 surface 显式建出来，不等玩家开船降落

    -- 【apply_bounds 现在也是一步修复】，不再只是新开局才做的事：
    -- 它内部先 planet.reset_map_gen_settings() 还原到原型状态，再叠加边界和矿脉倍率，
    -- 于是能洗掉旧版脚本写进存档的矿种污染（旧版把全部矿种写进了每颗星球，
    -- 导致 Nauvis 长出废料）。地图设置只影响【之后生成】的区块，所以清理效果
    -- 要等各星球下一轮重置才看得见 —— 这一点必须对管理员讲清楚，否则他会以为没生效。
    local planets = 0
    for _, name in ipairs(constants.PUBLIC_PLANETS) do
        local surface = game.surfaces[name]
        if surface and surface.valid then
            worlds.apply_bounds(surface)
            planets = planets + 1
        end
    end

    worlds.schedule_all(respread and true or false)

    -- 把已存在的戴森环全部重新 ensure 一遍：补齐半成品环缺失的收货箱阵、
    -- 重设 localised_name（列表里显示玩家名）、按公私状态对齐可见性。
    -- 【只碰已存在的环，绝不新建】——对已被回收的离线玩家调 ensure 会把环凭空造回来。
    local rings = pockets.repair_all()

    return {planets = planets, rings = rings}
end

return M
