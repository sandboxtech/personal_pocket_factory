-- 公共世界：太空时代的五个真星球，有限大小，各自独立计时、错峰重置。
--
-- 为什么用真星球而不是 game.create_surface 造裸 surface：
--   真星球的 surface 带着星球原型级的全部机制（Fulgora 闪电、Aquilo 冻结、Vulcanus 巨虫领地、
--   各自的 autoplace 和表面属性基准）。裸 surface 只能靠 set_property 调几个数值，这些一个都拿不到。
--
-- 为什么要显式 create_surface：
--   SA 里星球 surface 是【玩家真的开船降落时】才由引擎创建的。新存档只有 nauvis，
--   其余四个在有人去过之前 game.surfaces['vulcanus'] 就是 nil。
--   force.unlock_space_location() 只解锁星图上的传送点，不创建 surface，这是两件事。
--   game.planets[name].create_surface() 才是把 surface 建出来的那个调用，幂等。
--
-- 为什么错峰：
--   五个星球同时重置的话，全服会在同一刻集体失去一切，节奏是一根锯齿。
--   错开之后，任何时刻都有"刚重置的新鲜世界"和"快到期的成熟世界"，玩家永远有地方去，
--   也永远有理由赶在某个世界到期前把东西搬走。
local constants = require('scripts.constants')

local M = {}

-- 确保五个星球的 surface 都存在。幂等，可以反复调。
function M.ensure_surfaces()
    for _, name in ipairs(constants.PUBLIC_PLANETS) do
        local planet = game.planets[name]
        if planet then
            planet.create_surface()   -- 已存在则什么都不做
        end
    end
end

-- 给公共世界套上有限边界。width/height 是 MapGenSettings 的引擎级硬边界，
-- 边界外是 out-of-map，引擎不生成区块，存档体积从根上受控。
-- 注意：改 map_gen_settings 只影响【之后生成】的区块，所以必须在 clear() 之前设好。
function M.apply_bounds(surface)
    local size = storage.public_size or 2048
    local mgs = surface.map_gen_settings
    mgs.width = size
    mgs.height = size
    surface.map_gen_settings = mgs
end

-- 错峰排期：把五个星球的首次重置时间均匀铺在一个周期里。
-- 第 i 个星球的首次重置在 period × i / N 处，之后每 period 重置一次，永远保持错开。
function M.schedule_all(force_respread)
    storage.world_reset_at = storage.world_reset_at or {}
    local period = (storage.world_reset_minutes or 120) * constants.min_to_tick
    local total = #constants.PUBLIC_PLANETS
    for i, name in ipairs(constants.PUBLIC_PLANETS) do
        if force_respread or not storage.world_reset_at[name] then
            storage.world_reset_at[name] = game.tick + math.floor(period * i / total)
        end
    end
end

-- 距离某世界下次重置还有多少 tick。GUI 倒计时用。负数表示已过期待处理。
function M.time_left(planet_name)
    storage.world_reset_at = storage.world_reset_at or {}
    return (storage.world_reset_at[planet_name] or game.tick) - game.tick
end

-- 把还留在某世界上的玩家撤回各自的口袋世界。重置前调用，避免把人清进虚空。
local function evacuate(surface)
    local pockets = require('scripts.pockets')
    for _, player in pairs(game.connected_players) do
        if player.surface == surface then
            player.print({'pw.world-evacuated', surface.name})
            pockets.enter(player)
        end
    end
end

-- 重置单个公共世界：撤人 → 套边界 → 清空 → 排下一轮。
-- surface.clear(true) 是异步的，引擎会在结算后触发 on_surface_cleared，
-- 地形按新的 map_gen_settings 重新生成。
function M.reset_world(planet_name)
    local surface = game.surfaces[planet_name]
    if not surface or not surface.valid then return false end

    evacuate(surface)
    M.apply_bounds(surface)
    surface.clear(true)

    storage.world_run = storage.world_run or {}
    storage.world_run[planet_name] = (storage.world_run[planet_name] or 0) + 1

    storage.world_reset_at = storage.world_reset_at or {}
    storage.world_reset_at[planet_name] = game.tick + (storage.world_reset_minutes or 120) * constants.min_to_tick

    game.print({'pw.world-reset', planet_name, storage.world_run[planet_name]})
    return true
end

-- 周期任务：检查有没有世界到期。由 tick.lua 每分钟调用。
-- 一次只重置一个，即使多个同时到期也分开做，避免一 tick 内清多个 surface 造成卡顿尖峰。
function M.tick_check()
    storage.world_reset_at = storage.world_reset_at or {}
    for _, name in ipairs(constants.PUBLIC_PLANETS) do
        local at = storage.world_reset_at[name]
        if at and game.tick >= at then
            M.reset_world(name)
            return name
        end
    end
    return nil
end

-- 送玩家去某个公共世界的出生点。
function M.travel(player, planet_name)
    local surface = game.surfaces[planet_name]
    if not surface or not surface.valid then
        player.print({'pw.world-not-ready', planet_name})
        return false
    end
    local origin = player.force.get_spawn_position(surface)
    surface.request_to_generate_chunks(origin, 2)
    surface.force_generate_chunk_requests()
    local pos = surface.find_non_colliding_position('character', origin, 128, 1) or origin
    player.teleport(pos, surface)
    return true
end

return M
