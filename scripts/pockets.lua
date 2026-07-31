-- 戴森环：每个玩家一个专属 surface，一条高 128 的环带，没有任何资源。
--
-- 定位：戴森环是【加工厂】，公共世界是【矿场】。
-- 环里一颗矿都没有，所有原料必须从公共世界运回来（靠关联箱，见 chests.lua）。
-- 这条约束保证私人世界不会自给自足，玩家必须出门，公开服才不会退化成「同服单人」。
local constants = require('scripts.constants')
local ring = require('scripts.ring')
local chests = require('scripts.chests')

local M = {}

-- surface 名用 player.index 而不是 player.name：玩家名可能含空格或特殊字符，
-- 而 index 在存档内稳定且必定合法。storage 里仍然按玩家名索引，方便改名后继承。
function M.surface_name(player)
    return ring.surface_name_for(player.index)
end

function M.get(player)
    return game.surfaces[M.surface_name(player)]
end

-- 惰性创建。已存在直接返回，不重复建。
function M.ensure(player)
    local existing = M.get(player)
    if existing and existing.valid then return existing end

    -- 种子按玩家 index 派生，保证同一个人每次重开拿到的地形一致，换人则不同。
    local seed = (player.index * 7919 + 104729) % 2147483647
    local surface = game.create_surface(
        M.surface_name(player),
        constants.ring_map_gen(seed, storage.ring_height or 128))

    surface.always_day = true        -- 永昼：这里是工作间，不需要夜战和照明负担
    surface.freeze_daytime = true
    surface.show_clouds = false

    -- 关掉污染。注意是 {} 不是 nil ——
    -- Pollutant 概念是 { pollutant = LuaAirbornePollutantPrototype? }，文档写明 "If nil, pollution is disabled"，
    -- 而 override_pollution_type = nil 的含义是【不覆盖、跟随默认】，是个静默的 no-op。
    -- 因为 Lua 里 {pollutant = nil} 求值就是空表 {}，两种写法长得几乎一样、含义完全相反。
    -- 值得做的理由不只是清掉地图上的红云：污染扩散是 per-surface 每 tick 算的，
    -- 而戴森环是每个玩家一份 surface，人一多就是一堆永远不会有虫子来的污染云在白烧 UPS。
    surface.override_pollution_type = {}

    -- 同步生成出生区，玩家马上就要落地，异步排队会落进还没生成的区块。
    -- 逐区块请求（ring.ensure_chunks），不给大半径——半径是正方形，横向无边界会真的生成出去。
    local half = ring.half_width_of(player.name)
    local ring_height = storage.ring_height or 128
    local y_half = math.floor(ring_height / 2)
    ring.ensure_chunks(surface, -half, half, -y_half, y_half)

    -- 顺序依赖：此刻 storage.ring_state[player.name] 还没赋值（下面才赋），
    -- chests.expected_link_id 里「不是 'public'」分支会直接落到 player.index —— 结果正确，
    -- 但如果把这行挪到 ring_state 赋值之后，也不会错（赋的是 'private'，同样不等于 'public'）。
    -- 只是别把它挪到 ring.ensure_chunks 之前：那时候 surface 还没走完必要的初始化区块生成。
    chests.ensure_array(surface, player)

    storage.ring_applied_half = storage.ring_applied_half or {}
    storage.ring_applied_half[player.name] = half

    storage.ring_state = storage.ring_state or {}
    storage.ring_state[player.name] = 'private'

    if storage.debug then
        for _, p in pairs(game.connected_players) do
            if p.admin then
                p.print('[pw] 已创建戴森环 ' .. surface.name .. ' 半宽 ' .. half)
            end
        end
    end
    return surface
end

-- 把玩家送进自己的戴森环。没有就先建。
function M.enter(player)
    local surface = M.ensure(player)
    if not (surface and surface.valid) then return false end
    -- 出生点在收货箱阵右侧，避开箱阵本身（箱阵占 x∈{-1,0}、y∈{-3..2}）
    local pos = surface.find_non_colliding_position('character', {4, 0}, 32, 1) or {4, 0}
    player.teleport(pos, surface)
    return true
end

return M
