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

    -- 关掉污染。
    --
    -- 注意赋的是 {} 不是 nil ——
    -- Pollutant 概念是 { pollutant = LuaAirbornePollutantPrototype? }，
    -- 文档写明 "If nil, pollution is disabled"，
    -- 而 override_pollution_type = nil 的含义是【不覆盖、跟随默认】，是个静默的 no-op。
    -- 因为 Lua 里 {pollutant = nil} 求值就是空表 {}，两种写法长得几乎一样、含义完全相反。
    --
    -- 但这个字段是较新版本才有的，老版本上赋值会直接抛错。
    -- 所以用 pcall 包起来，失败就退回「不关污染」并写 log —— 污染对本场景没有玩法影响
    -- （环里 no_enemies_mode = true，没有虫子可招），关掉只是省 UPS，不值得为它崩服。
    local ok = pcall(function() surface.override_pollution_type = {} end)
    if not ok then
        log('[pw] 本版本 LuaSurface 无 override_pollution_type，戴森环污染未关闭')
    end

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

-------------------------------------------------------------------------------
-- 离线生命周期：30 小时变公共，50 小时删除
--
-- 这把「回收」从一个二元开关变成了有中间态的过程，而中间态本身是玩法 ——
-- 弃厂不是消失，是先变成公共资产：它继续运转、产出汇进全服公共池，任人拆解取用。
--
-- 同时修掉了 v1 一个很粗暴的设定（离线半小时回来工厂就没了）：
-- 现在 30 小时才开始有后果，50 小时才真的删，而且删的只是建筑，进度一点不丢。
-------------------------------------------------------------------------------

-- 把还留在某 surface 上的玩家撤回各自的戴森环。
local function evacuate(surface, except_name)
    for _, p in pairs(game.connected_players) do
        if p.surface == surface and p.name ~= except_name then
            p.print({'pw.ring-evacuated'})
            M.enter(p)
        end
    end
end

-- 删除某人的戴森环。经验一点不动，下次上线重新长出来。
function M.delete_ring(player)
    if not (player and player.valid) then return false, 'pw.cmd-no-player' end
    if player.connected then return false, 'pw.cmd-player-online' end

    local surface = M.get(player)
    if not (surface and surface.valid) then return false, 'pw.cmd-no-ring' end

    evacuate(surface, nil)
    game.delete_surface(surface)

    storage.ring_state = storage.ring_state or {}
    storage.ring_state[player.name] = nil
    storage.ring_applied_half = storage.ring_applied_half or {}
    storage.ring_applied_half[player.name] = nil
    return true
end

-- 玩家上线：若他的环在公共期，立刻收回。
function M.restore_on_join(player)
    storage.ring_state = storage.ring_state or {}
    if storage.ring_state[player.name] ~= 'public' then return end

    storage.ring_state[player.name] = 'private'
    chests.set_array_link(player, player.index)

    local surface = M.get(player)
    if surface and surface.valid then
        evacuate(surface, player.name)   -- 把还在里面逛的访客请出去
    end
    player.print({'pw.ring-reclaimed'})
end

-- 离线多久了（小时）。在线玩家返回 0。
function M.idle_hours(player)
    if player.connected then return 0 end
    return (game.tick - (player.last_online or 0)) / constants.hour_to_tick
end

-- 这个玩家的公共化阈值（tick）。新人按累计在线时长缩放，投满 ring_public_hours
-- 之后才拿到老玩家那个固定上限——「你投入了多久，就受多久保护」。
-- player.online_time 是这个存档里该玩家全部会话累计的在线 tick 数（见 util.is_veteran
-- 旁的说明，已核实存在），新建角色是 0，靠 ring_min_hours 兜住下限，不会一离线就立刻公共化。
function M.public_threshold(player)
    local cap_hours = storage.ring_public_hours or 30
    local min_hours = storage.ring_min_hours or 1
    local played_hours = (player.online_time or 0) / constants.hour_to_tick
    local hours = math.max(min_hours, math.min(cap_hours, played_hours))
    return hours * constants.hour_to_tick
end

-- 这个玩家的删除阈值（tick）。同 public_threshold，倍数是 2
-- （删除阈值 = min(ring_delete_hours, 2 × 累计在线小时数)）。
function M.delete_threshold(player)
    local cap_hours = storage.ring_delete_hours or 50
    local min_hours = storage.ring_min_hours or 1
    local played_hours = (player.online_time or 0) / constants.hour_to_tick
    local hours = math.max(min_hours, math.min(cap_hours, played_hours * 2))
    return hours * constants.hour_to_tick
end

-- private → public 跃迁。周期扫描和「访客点进来」两条路都走这里，保证行为一致。
-- 已经是 public 的直接返回 false，幂等。
function M.make_public(player)
    storage.ring_state = storage.ring_state or {}
    if storage.ring_state[player.name] == 'public' then return false end
    if not M.get(player) then return false end

    storage.ring_state[player.name] = 'public'
    chests.set_array_link(player, constants.PUBLIC_LINK_ID)
    game.print({'pw.ring-public', player.name})
    return true
end

-- 周期任务：扫描离线玩家，做 private → public 和 public → 删除 两个跃迁。
--
-- 【关键】阈值每次现读、现算 idle，绝不缓存成「到期 tick」。
-- 存了到期 tick 的话，改配置就只对新数据生效，服务器会处于两套规则并存的状态。
function M.tick_lifecycle()
    storage.ring_state = storage.ring_state or {}

    for _, player in pairs(game.players) do
        if not player.connected then
            local idle = game.tick - (player.last_online or 0)
            local state = storage.ring_state[player.name]
            -- 阈值按这个玩家的累计在线时长现算（见 public_threshold/delete_threshold 的说明），
            -- 不缓存，改配置或玩家继续攒在线时长都能立刻反映到判定上。
            local public_at = M.public_threshold(player)
            local delete_at = M.delete_threshold(player)

            if idle >= delete_at then
                if M.get(player) then
                    M.delete_ring(player)
                    game.print({'pw.ring-deleted', player.name})
                end
            elseif idle >= public_at and state == 'private' then
                M.make_public(player)
            end
        end
    end
end

-- 所有存在的戴森环，供传送窗口列出。
--
-- 列【全部】而不是只列公共的：玩家看得到别人的环有多大、离线多久、还有多久能进，
-- 这比一个空列表有信息量得多，也让「等某人超时」变成一件可以规划的事。
-- 但 enterable 只对已超过【这个主人自己的】公共化阈值为 true —— 看得到不等于进得去。
-- 阈值因人而异（新人按在线时长缩放，见 public_threshold），所以逐个玩家现算，
-- 不能像老版本那样拿 storage.ring_public_hours 当全服统一门槛用。
-- 顺带把这个阈值（小时）也带出来，供 GUI 算「还差多久」，不能再假设全服一个数。
function M.all_rings()
    storage.ring_state = storage.ring_state or {}
    local out = {}
    for _, player in pairs(game.players) do
        if M.get(player) then
            local idle = M.idle_hours(player)
            local public_hours = M.public_threshold(player) / constants.hour_to_tick
            out[#out + 1] = {
                owner_name = player.name,
                owner_index = player.index,
                idle_hours = math.floor(idle),
                half_width = ring.half_width_of(player.name),
                state = storage.ring_state[player.name] or 'private',
                public_hours = public_hours,
                enterable = idle >= public_hours,
            }
        end
    end
    return out
end

return M
