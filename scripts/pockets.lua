-- 口袋世界：每个玩家一个专属 surface，没有任何资源。
--
-- 定位：口袋世界是【加工厂】，公共世界是【矿场】。
-- 口袋里一颗矿都没有，所有原料必须从公共世界背回来。这条约束是整个玩法的支点：
--   · 它保证私人世界不会自给自足，玩家必须出门，公开服才不会退化成"同服单人"；
--   · 它让口袋世界的价值是"安全和产权"而不是"资源"，产线搭在这里没人能拆。
--
-- 生命周期：上线惰性创建，离线超时回收（delete_surface）。
-- 这样存档里永远只装着活跃玩家的口袋，不会随注册人数单调增长。
local constants = require('scripts.constants')

local M = {}

-- surface 名用 player.index 而不是 player.name：玩家名可能含空格或特殊字符，
-- 而 index 在存档内稳定且必定合法。storage 里仍然按玩家名索引，方便改名后继承。
function M.surface_name(player)
    return constants.POCKET_PREFIX .. tostring(player.index)
end

-- 取玩家的口袋 surface，不存在返回 nil。
function M.get(player)
    return game.surfaces[M.surface_name(player)]
end

-- 惰性创建。已存在直接返回，不重复建。
function M.ensure(player)
    local existing = M.get(player)
    if existing and existing.valid then return existing end

    local size = storage.pocket_size or 256
    -- 种子按玩家 index 派生，保证同一个人每次重开拿到的地形一致，换人则不同。
    local seed = (player.index * 7919 + 104729) % 2147483647
    local surface = game.create_surface(M.surface_name(player), constants.pocket_map_gen(size, seed))

    surface.always_day = true          -- 口袋世界永昼：这里是工作间，不需要夜战和照明负担
    surface.freeze_daytime = true
    surface.show_clouds = false

    -- 同步生成出生区，玩家马上就要落地，异步排队会落进还没生成的区块
    surface.request_to_generate_chunks({0, 0}, 2)
    surface.force_generate_chunk_requests()

    storage.pocket_run = storage.pocket_run or {}
    storage.pocket_run[player.name] = game.tick

    if storage.debug then
        for _, p in pairs(game.connected_players) do
            if p.admin then p.print('[pw] 已创建口袋世界 ' .. surface.name .. ' 边长 ' .. size) end
        end
    end
    return surface
end

-- 把玩家送进自己的口袋世界。没有就先建。
function M.enter(player)
    local surface = M.ensure(player)
    if not surface or not surface.valid then return false end
    local pos = surface.find_non_colliding_position('character', {0, 0}, 64, 1) or {0, 0}
    player.teleport(pos, surface)
    return true
end

-- 回收某玩家的口袋世界。玩家还在里面的话先不动，避免把人删进虚空。
function M.reclaim(player)
    local surface = M.get(player)
    if not surface or not surface.valid then return false end
    for _, p in pairs(game.connected_players) do
        if p.surface == surface then return false end
    end
    game.delete_surface(surface)
    storage.pocket_run = storage.pocket_run or {}
    storage.pocket_run[player.name] = nil
    return true
end

-- 周期任务：回收离线超时玩家的口袋世界。由 tick.lua 每分钟调用一次。
-- 这是存档体积的主要闸门，离线的人不该继续占着一整个 surface。
function M.reclaim_offline()
    local keep = (storage.pocket_keep_offline_minutes or 30) * constants.min_to_tick
    local reclaimed = 0
    for _, player in pairs(game.players) do
        if not player.connected then
            local idle = game.tick - (player.last_online or 0)
            if idle > keep and M.reclaim(player) then
                reclaimed = reclaimed + 1
            end
        end
    end
    return reclaimed
end

return M
