-- 公共世界的地貌斑块：每轮重置后，五个星球的地面看起来都不一样。
--
-- 【本模块严格只碰自然环境】——地块(tile)斑块替换，外加装饰物/树木疏密的顺带调整。
-- 【绝对不放箱子/物资箱/永续箱，也绝对不放虫巢/据点/敌方单位】，原因：
--   本场景不能往公共世界里放物资箱：玩家用关联箱一趟就能把它们运回戴森环，
--   而戴森环【不重置】。任何放在公共世界的白给物资，最终都会变成永久收益，
--   这和「星球会重置、环才是长期平台」的核心节奏直接冲突。
--   （敌方据点同理不放——公共世界的核心定位是"有时限的资源场"，不是战斗关卡，
--   加虫巢只会让玩家在世界到期前多一件要处理的麻烦事，和"重置节奏"这个设计目标无关。）
--
-- 做法：noise.lua 的 chunk_sampler + fractal_warped 组合——由 worlds.derive_seed() 给出的
-- 本轮种子，确定性地派生一组"本轮专属"的旋转/拉伸/缩放参数，同一套噪声场套上这组参数，
-- 就在【原生地块名单内】重新分布出一张新斑块图。种子来自 storage.world_run[星球名]，
-- 和 worlds.reset_world() 换种子重开地形用的是同一颗种子——地形和地貌斑块同步换新。
--
-- 只在【公共世界】的区块上跑：戴森环的 on_chunk_generated 处理器（ring.lua）
-- 认 surface 名是不是 'ring_' 前缀，本模块认 surface 名是不是五个公共星球之一，
-- 两者互不相交，各自走 events.on 总线订阅、互不干扰、互不覆盖。
local constants = require('scripts.constants')
local worlds = require('scripts.worlds')
local noise = require('scripts.noise')
local events = require('scripts.events')

local M = {}

-- 公共星球名集合，O(1) 判断，模块加载时算一次（纯常量派生，不读 storage/game）。
local PUBLIC_SET = {}
for _, name in ipairs(constants.PUBLIC_PLANETS) do PUBLIC_SET[name] = true end

-- 该星球本轮的斑块替换用砖名单。表缺项/空表都返回 nil——调用方据此跳过，
-- 不会把 nil 或空数组传进 find_tiles_filtered/chunk_sampler。
local function palette_for(planet_name)
    local t = storage.world_patch_tiles
    local list = t and t[planet_name]
    if type(list) ~= 'table' or #list < 2 then return nil end   -- 少于两种砖，换了也换不出花样
    return list
end

-- 本轮种子：和 worlds.reset_world() 换地形用的是同一条派生规则、同一个轮次号，
-- 保证「地形重开」和「地貌斑块换新」永远同步——不会出现地形已经是新的、斑块还是上一轮的错位。
local function seed_for(planet_name)
    local run = (storage.world_run and storage.world_run[planet_name]) or 0
    return worlds.derive_seed(planet_name, run), run
end

-- 本轮专属的噪声变换(旋转/拉伸/缩放)，按"星球+轮次"缓存——on_chunk_generated 每个区块都会调用，
-- 但同一轮内所有区块必须用同一组参数（否则区块之间斑块朝向对不上，出现接缝）。
-- +12345 只是把变换用的种子和斑块本体噪声用的种子错开，避免两者退化成同一张噪声场的简单复制。
local xform_cache = {}
local function transform_for(planet_name, seed, run)
    local c = xform_cache[planet_name]
    if c and c.run == run then return c.angle, c.stretch, c.zoom end
    local angle, stretch, zoom = noise.seeded_transform(seed + 12345)
    xform_cache[planet_name] = {run = run, angle = angle, stretch = stretch, zoom = zoom}
    return angle, stretch, zoom
end

-- 地块斑块替换：只在【本星球原生砖名单内】的格子上找目标，命中噪声高值区就换成名单里的另一种砖。
-- find_tiles_filtered 的 name 参数直接传整张名单——只会命中名单内的砖，水/熔岩/人造建筑砖
-- 从一开始就不在候选范围内，不存在"不小心把海面换成沙地"这种事。
function M.patch_tiles(surface, planet_name, area, seed, angle, stretch, zoom)
    local palette = palette_for(planet_name)
    if not palette then return end

    local found = surface.find_tiles_filtered{area = area, name = palette}
    if #found == 0 then return end

    local n = #palette
    local sampler = noise.chunk_sampler(noise.octaves.blob, area.left_top, seed, angle, stretch, zoom)

    local tiles = {}
    for _, t in pairs(found) do
        local p = t.position
        local v = sampler(p.x, p.y)                          -- 约 [-1,1]
        local idx = math.floor((v + 1) * 0.5 * n) + 1         -- 映射到 1..n
        if idx < 1 then idx = 1 elseif idx > n then idx = n end
        local target = palette[idx]
        if target ~= t.name then
            tiles[#tiles + 1] = {name = target, position = p}
        end
    end
    -- 批量一次提交；correct_tiles=false 不需要引擎做过渡混合处理(名单里都是同星球原生砖，
    -- 视觉上本来就互相兼容)；remove_colliding_entities=false 绝不因为换地块删掉任何实体。
    if #tiles > 0 then
        surface.set_tiles(tiles, false, false)
    end
end

-- 顺带调整树木疏密：本轮噪声落在"荒芜带"的树，按概率清掉，让这轮某片区域看起来比上轮秃一些。
-- 只做【删除】不做【新增】——新增要过 can_place_entity 碰撞检查、还可能把树种进玩家已经站的地方，
-- 删除已存在的原生树没有这个风险，足够表达"疏密每轮不同"的观感。
-- 只碰 type='tree'：不碰 resource（矿）、不碰 simple-entity(石头)——石头有的可采挖出矿物，
-- 删矿产出的事交给原生地图生成的随机性，本模块不做资源层面的取舍。
function M.thin_trees(surface, area, seed, angle, stretch, zoom)
    local trees = surface.find_entities_filtered{type = 'tree', area = area}
    if #trees == 0 then return end

    local sampler = noise.chunk_sampler(noise.octaves.fine, area.left_top, seed + 500, angle, stretch, zoom)
    for _, tree in pairs(trees) do
        if tree.valid then
            local v = sampler(tree.position.x, tree.position.y)
            if v < -0.3 and math.random() < 0.35 then
                tree.destroy()
            end
        end
    end
end

-- 区块生成时的入口：只在公共世界的区块上跑，其余 surface（戴森环/口袋世界）早退。
function M.on_chunk_generated(event)
    local surface = event.surface
    if not (surface and surface.valid) then return end
    if not PUBLIC_SET[surface.name] then return end

    local seed, run = seed_for(surface.name)
    local angle, stretch, zoom = transform_for(surface.name, seed, run)

    M.patch_tiles(surface, surface.name, event.area, seed, angle, stretch, zoom)
    M.thin_trees(surface, event.area, seed, angle, stretch, zoom)
end

-- 订阅走 events 总线，不用裸 script.on_event——戴森环的 ring.on_chunk_generated
-- 也订阅同一个事件，总线保证两边都能收到、互不覆盖。订阅在模块顶层完成，
-- 保证每次加载(on_init/on_configuration_changed/正常启动)注册都一致，多人不同步。
events.on(defines.events.on_chunk_generated, events.safe('world_terrain', M.on_chunk_generated))

return M
