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

-- 把戴森环从遥控视角的平面列表里藏起来。
--
-- 【纯观感功能，绝不允许它中断建环流程】——这不是防御性编程的客套话，是修 bug 修出来的规矩：
-- 这行曾经写成 set_surface_hidden(true, surface)（参数顺序反了），抛出
-- InvalidSurfaceIdentification，而它当时【排在 chests.ensure_array 前面】，
-- 于是被事件总线的 pcall 吞掉之后，12 个收货箱压根没被创建 ——
-- 玩家看到的现象是「地板在、箱子没了」，从表象上完全联想不到「隐藏 surface」这个功能。
-- 所以现在：① 参数顺序以 runtime-api.json 为准（surface 在前、hidden 在后，已核对）；
-- ② 单独 pcall，失败只写 log；③ 调用点挪到 ensure() 的最后，前面的关键步骤全做完再说。
--
-- 单 force 场景下这个隐藏对整个 force 生效（没有「只对某个玩家隐藏」的选项），
-- 但这恰好可行：所有人（包括环主自己）都靠 UI 按钮传送进出，没人需要在列表里翻它。
local function hide_surface(surface)
    local force = game.forces.player
    local ok, err = pcall(function() force.set_surface_hidden(surface, true) end)
    if not ok then
        log('[pw] set_surface_hidden 调用失败（不影响戴森环功能）：' .. tostring(err))
        return
    end
    if not force.get_surface_hidden(surface) then
        log('[pw] set_surface_hidden 未生效：' .. surface.name .. ' 仍会出现在遥控视角列表里')
    end
end

-- 只负责把 surface 本身建出来。箱阵、涂砖、storage 记账都不在这里，
-- 那些是【每次 ensure 都要跑一遍】的幂等步骤，见 M.ensure。
local function create_surface(player)
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

    return surface
end

-- 惰性创建 + 自愈。已存在的环不重复建，但下面那几步【每次都跑一遍】。
--
-- 为什么不是「已存在就直接 return」：那样写的话，任何一次建环中途出错留下的半成品环
-- 就永远修不好了 —— 上面 set_surface_hidden 参数写反那次正是如此，环建出来了、
-- 地板也有（涂砖走的是 on_chunk_generated 这条独立路径），唯独 12 个收货箱缺席，
-- 而且此后每次进环都从第一行直接返回，永远不会补建。
-- 现在这几步全部幂等（ensure_chunks 对已生成区块是 no-op，ensure_array 逐位置跳过已存在的箱子），
-- 每次调用重跑一遍的代价可以忽略，换来的是「进一次环就自动修一次」。
function M.ensure(player)
    local surface = M.get(player)
    if not (surface and surface.valid) then
        surface = create_surface(player)
        if not (surface and surface.valid) then return nil end
    end

    -- 同步生成出生区，玩家马上就要落地，异步排队会落进还没生成的区块。
    -- 逐区块请求（ring.ensure_chunks），不给大半径——半径是正方形，横向无边界会真的生成出去。
    local half = ring.half_width_of(player.name)
    local ring_height = storage.ring_height or 128
    local y_half = math.floor(ring_height / 2)
    ring.ensure_chunks(surface, -half, half, -y_half, y_half)

    -- 收货箱阵。必须排在 ensure_chunks 之后：箱子要落在已生成、已涂好砖的区块上。
    chests.ensure_array(surface, player)

    -- 记账项用「没有才写」，不能无条件覆盖：ring_applied_half 会被 ring.apply_growth
    -- 推到更大的值，ring_state 会被生命周期推到 'public'，这里一律覆盖的话会把它们打回原形。
    storage.ring_applied_half = storage.ring_applied_half or {}
    storage.ring_applied_half[player.name] = storage.ring_applied_half[player.name] or half

    storage.ring_state = storage.ring_state or {}
    storage.ring_state[player.name] = storage.ring_state[player.name] or 'private'

    -- 复活点钉在环上。
    --
    -- 【这是本场景处理"表面被删时玩家在里面"的唯一手段】。脚本不在删除前搬人——
    -- 引擎自己会处理站在消失表面上的角色（角色死亡），玩家随后走正常复活流程，
    -- 所以真正要管好的是复活落在哪儿，而不是删除那一刻的玩家状态。
    -- 兜底还有一层：scripts/players.lua 的 on_player_respawned 一律调 M.enter，
    -- 环没了就当场重建。两层的关系是"引擎的默认落点尽量别离谱"+"脚本最终说了算"。
    --
    -- set_spawn_position 是 per-force-per-surface 的，单 force 场景下即
    -- 「这个 surface 上的出生点」，各条环互不干扰。坐标和 M.enter 的落点保持一致。
    game.forces.player.set_spawn_position(constants.RING_SPAWN, surface)

    -- 放在最后：纯观感，前面的关键步骤全部做完才轮到它，它出问题也不会牵连任何人。
    hide_surface(surface)

    if storage.debug then
        for _, p in pairs(game.connected_players) do
            if p.admin then
                p.print('[pw] 戴森环就绪 ' .. surface.name .. ' 半宽 ' .. half)
            end
        end
    end
    return surface
end

-- 把所有【已存在】的戴森环过一遍 ensure，补齐半成品环缺失的部分（典型是 12 个收货箱）。
--
-- 只碰已经存在的环，绝不新建：对已经离线超过删除阈值、环已被回收的玩家调 ensure，
-- 会把那个环凭空造回来，等于绕过 50 小时删除规则。判据就是 M.get(player) 非空。
--
-- 由 on_configuration_changed（老存档升级）和 /ring-repair 指令调用。
function M.repair_all()
    local count = 0
    for _, player in pairs(game.players) do
        if M.get(player) then
            M.ensure(player)
            count = count + 1
        end
    end
    return count
end

-- 把玩家送进自己的戴森环。没有就先建。
function M.enter(player)
    local surface = M.ensure(player)
    if not (surface and surface.valid) then return false end
    -- 落点在收货箱阵右侧、避开箱阵本身。坐标和箱阵坐标一起定义在 constants 里，
    -- 那边有为什么必须放在一起看的说明。
    local pos = surface.find_non_colliding_position('character', constants.RING_SPAWN, 32, 1)
        or constants.RING_SPAWN
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

-- 把还留在某 surface 上的访客请回各自的戴森环。
--
-- 【这不是"删表面前的清场"，删表面不需要清场】——引擎会处理站在被删表面上的角色
-- （角色死亡，玩家走正常的复活流程，而复活流程本场景已经接管：on_player_respawned
-- 一律送回他自己的环，见 scripts/players.lua）。
-- 本函数唯一的用途是【主人回来了，把客人请出去】这条玩法规则，和删除毫无关系。
local function evacuate(surface, except_name)
    for _, p in pairs(game.connected_players) do
        if p.surface == surface and p.name ~= except_name then
            p.print({'pw.ring-evacuated'})
            M.enter(p)
        end
    end
end

-- 删除某人的戴森环。经验一点不动，下次进环重新长出来。
--
-- 【不检查主人在不在线，也不清场】。老版本两样都做，理由是"删表面必然要处理人在里面
-- 怎么办"——但那个前提本身是错的：引擎自己会处理，站在被删表面上的角色会死亡，
-- 玩家走正常复活流程，而本场景已经接管了复活（on_player_respawned → pockets.enter），
-- 一律落在他自己的环里。真正要管好的是【复活点】，不是删除那一刻的玩家状态。
-- 少了这两层，指令的行为也从"有时候拒绝执行"变成了"永远照做"，更好预期。
function M.delete_ring(player)
    if not (player and player.valid) then return false, 'pw.cmd-no-player' end

    local surface = M.get(player)
    if not (surface and surface.valid) then return false, 'pw.cmd-no-ring' end

    game.delete_surface(surface)

    storage.ring_state = storage.ring_state or {}
    storage.ring_state[player.name] = nil
    storage.ring_applied_half = storage.ring_applied_half or {}
    storage.ring_applied_half[player.name] = nil
    return true
end

-- 删除【所有】戴森环。经验一点不动，没的只有建筑和关联库存。返回删掉的条数。
--
-- 【不搬人、不检查在线】。站在环里的玩家会随表面删除而死亡，然后走正常复活流程，
-- 而复活流程本场景已经接管（on_player_respawned → M.enter），一律落回他自己的环。
-- 早先这里手工把所有人挪到公共世界、并在公共世界不可用时整个中止，
-- 那套逻辑解决的是一个引擎本来就不会出的问题，代价是多了一条"什么都没删"的分支
-- 和一个只在那条分支上用得到的错误码。
--
-- 死亡会掉背包，这对一条"重置全服"的指令是可接受的（也符合它的语义）；
-- 指令本身有预览 + confirm 两道闸，见 scripts/commands.lua。
function M.delete_all_rings()
    storage.ring_state = storage.ring_state or {}
    storage.ring_applied_half = storage.ring_applied_half or {}

    local deleted = 0
    for _, player in pairs(game.players) do
        local surface = M.get(player)
        if surface and surface.valid then
            game.delete_surface(surface)
            storage.ring_state[player.name] = nil
            storage.ring_applied_half[player.name] = nil
            deleted = deleted + 1
        end
    end
    return deleted
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
                -- 等级和半宽一起给出来：半宽本来就是等级算的，让调用方自己再算一遍
                -- 等于把"环宽怎么来的"这条规则复制到 GUI 里，改规则时会漏改一处。
                level = ring.level_of(player.name),
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
