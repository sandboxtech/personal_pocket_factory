-- 戴森环：每个玩家一个专属 surface，一条宽 32、上下增长的环带（中间 16 格可建、左右各 8 格临空），没有任何资源。
--
-- 定位：戴森环是【加工厂】，公共世界是【矿场】。
-- 环里一颗矿都没有，所有原料必须从公共世界运回来（靠关联箱，见 chests.lua）。
-- 这条约束保证私人世界不会自给自足，玩家必须出门，公开服才不会退化成「同服单人」。
local constants = require('scripts.constants')
local ring = require('scripts.ring')
local chests = require('scripts.chests')
local ships = require('scripts.ships')
-- util 只依赖 constants 和 ring，两者都不反向依赖 pockets，顶层 require 不成环。
local util = require('scripts.util')

local M = {}

local PLAYER_CLEANUP_IDLE_TICKS = 90 * constants.hour_to_tick

function M.surface_name(player)
    return ring.surface_name_for(player)
end

function M.get(player)
    local name = M.surface_name(player)
    return name and game.surfaces[name] or nil
end

-- 这条环该不该出现在遥控视角左侧的平面列表里。
--
-- 判据就是它的公私状态，不是另一套规则：
--   · private —— 藏起来。列表里能选中就意味着能遥控看、能下拆除令、能放蓝图，
--     私人环的"私人"二字必须包含这一层，否则传送门禁形同虚设（同 force 全图已探明）。
--   · public  —— 露出来。公共环的规则本来就是"谁都能进、能拆、能搬空"，
--     藏着它只是让玩家更难找到，并不提供任何保护，纯属添堵。
--
-- 于是这个列表自动变成一份「现在可以去逛的环」清单，和玩法规则始终同步。
-- storage.ring_hide_private = false 可以整服放开（全部露出），代价是私人环也能被遥控拆。
--
-- 隐藏是 per-force 的，没有"只对某个玩家隐藏"的选项。单 force 场景下这不是问题：
-- 环主自己也用 UI 按钮进出，不需要在列表里翻自己那条。
local function ring_should_hide(player_name)
    if storage.ring_hide_private == false then return false end
    storage.ring_state = storage.ring_state or {}
    return storage.ring_state[player_name] ~= 'public'
end

-- 【纯观感，绝不允许它中断建环流程】。参数顺序 surface 在前、hidden 在后
-- （runtime-api.json 的 order 字段为准，曾经写反过）。单独 pcall，且在 ensure() 里排最后。
local function sync_visibility(surface, player_name)
    local hidden = ring_should_hide(player_name)
    local force = game.forces.player
    local ok, err = pcall(function() force.set_surface_hidden(surface, hidden) end)
    if not ok then
        log('[pw] set_surface_hidden 调用失败（不影响戴森环功能）：' .. tostring(err))
        return
    end
    if force.get_surface_hidden(surface) ~= hidden then
        log('[pw] set_surface_hidden 未生效：' .. surface.name)
    end
end

-- 平面列表里显示玩家名。私人环 surface 名也优先就是玩家名；兜底名带 index 时，
-- localised_name 仍然只显示玩家名。
-- 【改 localised_name，不是 name】：name 是全服唯一的键，只有迁移旧环到公共遗迹时才会改。
-- 每次 ensure 都重设，跟上玩家改名。
local function sync_label(surface, player)
    surface.localised_name = player.name
end

-- 戴森环永昼，且太阳能获得 +900% 加成（总功率为标准值的 10 倍）。
-- 环里没有矿，长期电力实际上只有太阳能一条路（燃料和核电都得从公共
-- 星球背回来），而太阳能夜里归零就得先攒蓄电池产能 —— 对一个离线也在计时的场景，
-- 这道门槛卡的正是最不该被卡的新人。代价是蓄电池在环内失去意义，明确接受。
--
-- 用 always_day 而不是 freeze_daytime：后者只是把时钟停住，还会被别处改 daytime 打断。
-- 每次 ensure 都重设，所以老环不用重建也能补上。
local function sync_daylight(surface)
    surface.always_day = storage.ring_always_day ~= false
    surface.solar_power_multiplier = 10
end

-- 只负责把 surface 本身建出来。箱阵、涂砖、storage 记账都不在这里，
-- 那些是【每次 ensure 都要跑一遍】的幂等步骤，见 M.ensure。
local function create_surface(player)
    -- 种子按玩家 index 派生，保证同一个人每次重开拿到的地形一致，换人则不同。
    local seed = (player.index * 7919 + 104729) % 2147483647
    local surface = game.create_surface(
        M.surface_name(player),
        constants.ring_map_gen(seed, storage.ring_width or 32))
    ring.record_private_surface(player, surface.name)

    surface.freeze_daytime = true    -- 永昼本身由 sync_daylight 按配置设
    surface.show_clouds = false

    -- 关掉污染。【赋 {} 不是 nil】：Pollutant 是 { pollutant = ... }，文档说
    -- "If nil, pollution is disabled"；而字段本身 = nil 是"不覆盖"，静默 no-op。
    -- 两种写法长得几乎一样、含义完全相反。
    -- pcall 是因为这个字段较新，老版本赋值会抛错，而它只省 UPS、不影响玩法。
    local ok = pcall(function() surface.override_pollution_type = {} end)
    if not ok then
        log('[pw] 本版本 LuaSurface 无 override_pollution_type，戴森环污染未关闭')
    end

    return surface
end

-- 惰性创建 + 自愈。已存在的环不重复建，但下面那几步【每次都跑一遍】。
--
-- 不写成「已存在就直接 return」：那样的话任何一次建环中途出错留下的半成品环就永远修不好。
-- 下面几步全部幂等，重跑的代价可以忽略，换来「进一次环就自动修一次」。
function M.ensure(player)
    local surface = M.get(player)
    if not (surface and surface.valid) then
        surface = create_surface(player)
        if not (surface and surface.valid) then return nil end
    end

    -- 同步生成出生区，玩家马上就要落地，异步排队会落进还没生成的区块。
    -- 逐区块请求（ring.ensure_chunks），不给大半径——半径是正方形，纵向无边界会真的生成出去。
    local half = ring.half_length_of(player.name)
    local ring_width = storage.ring_width or 32
    local x_half = math.floor(ring_width / 2)
    ring.ensure_chunks(surface, -x_half, x_half, -half, half)

    -- 收货箱阵。必须排在 ensure_chunks 之后：箱子要落在已生成、已涂好砖的区块上。
    chests.ensure_array(surface, player)

    -- 记账项用「没有才写」，不能无条件覆盖：ring_applied_half_length 会被 ring.apply_growth
    -- 推到更大的值，ring_state 会被生命周期推到 'public'，这里一律覆盖的话会把它们打回原形。
    storage.ring_applied_half_length = storage.ring_applied_half_length or {}
    storage.ring_applied_half_length[player.name] = storage.ring_applied_half_length[player.name] or half

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
    -- 顺序上必须排在上面 ring_state 兜底之后 —— ring_should_hide 要读它。
    sync_label(surface, player)
    sync_visibility(surface, player.name)
    sync_daylight(surface)

    if storage.debug then
        for _, p in pairs(game.connected_players) do
            if p.admin then
                p.print('[pw] 戴森环就绪 ' .. surface.name .. ' 半长 ' .. half)
            end
        end
    end
    return surface
end

-- 把所有【已存在】的新戴森环过一遍 ensure，补齐半成品环缺失的部分（典型是系统收货箱）。
--
-- 只碰已经存在的环，绝不新建：对已经离线超过删除阈值、环已被回收的玩家调 ensure，
-- 会把那个环凭空造回来，等于绕过离线删除规则。判据就是 M.get(player) 非空。
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

-- 强制撤离时只移动玩家的真实角色实体。遥控视角下 player.surface 是观察位置，
-- player.character 也可能为 nil；body_character 会从 associated characters 找回本体。
function M.enter_body(player)
    local surface = M.ensure(player)
    if not (surface and surface.valid) then return false end
    local character = util.body_character(player)
    if not character then return M.enter(player) end
    local pos = surface.find_non_colliding_position('character', constants.RING_SPAWN, 32, 1)
        or constants.RING_SPAWN
    return character.teleport(pos, surface)
end

-------------------------------------------------------------------------------
-- 离线生命周期：离线满一段时间变公共，再满 3 倍时长后删除。
-- 时长按累计在线时长缩放，下限 3 小时（→ 9 小时删），上限 30 小时（→ 90 小时删）。
--
-- 这把「回收」从一个二元开关变成了有中间态的过程，而中间态本身是玩法 ——
-- 弃厂不是消失，是先变成公共资产：它继续运转、产出汇进全服公共池，任人拆解取用。
--
-- 同时修掉了 v1 一个很粗暴的设定（离线半小时回来工厂就没了）：
-- 现在最少也要离线 3 小时才开始有后果，删除还要再等 3 倍，而且删的只是建筑，进度一点不丢。
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
            M.enter_body(p)
        end
    end
end

local function cleanup_records()
    storage.player_cleanup = storage.player_cleanup or {}
    return storage.player_cleanup
end

-- 环被删除时，离线玩家进入待清理表；上线会取消。
-- 到期后移除离线 LuaPlayer 记录，让引擎自己清掉角色、背包和个人蓝图库。
-- 注意：玩家进度在本场景自己的 storage 里按玩家名保存，不跟着删。
function M.queue_player_cleanup(player)
    if not (player and player.valid) then return false end
    local rs = cleanup_records()
    if player.connected then
        rs[player.index] = nil
        rs[player.name] = nil -- 兼容旧存档里按名字排队的记录。
        return false
    end

    rs[player.index] = {
        index = player.index,
        queued = game.tick,
        name = player.name,
        due = (player.last_online or game.tick) + PLAYER_CLEANUP_IDLE_TICKS,
    }
    return true
end

function M.cancel_player_cleanup(player)
    if not (player and player.valid) then return false end
    local rs = cleanup_records()
    if not (rs[player.index] or rs[player.name]) then return false end
    rs[player.index] = nil
    rs[player.name] = nil
    return true
end

local function remove_offline_player(player)
    local ok, err = pcall(function()
        game.remove_offline_players({player.index})
    end)
    if not ok then
        log('[pw] 移除离线玩家失败 ' .. player.name .. '：' .. tostring(err))
        return false
    end
    return true
end

function M.tick_player_cleanup()
    local cleaned = 0
    for key, record in pairs(cleanup_records()) do
        local player = (record.index and game.players[record.index])
            or (record.name and game.players[record.name])
            or (type(key) == 'string' and game.players[key])
        if not (player and player.valid) then
            cleanup_records()[key] = nil
        elseif player.connected then
            cleanup_records()[key] = nil
        else
            local idle = game.tick - (player.last_online or game.tick)
            local due = record.due or ((player.last_online or game.tick) + PLAYER_CLEANUP_IDLE_TICKS)
            if idle >= PLAYER_CLEANUP_IDLE_TICKS and game.tick >= due then
                chests.clear_player_dropoffs(player.index)
                if remove_offline_player(player) then
                    cleanup_records()[key] = nil
                    cleaned = cleaned + 1
                end
            end
        end
    end
    return cleaned
end

local function tick_public_rings()
    storage.public_rings = storage.public_rings or {}
    local removed = 0
    for name, record in pairs(storage.public_rings) do
        local surface = game.surfaces[name]
        if not (surface and surface.valid) then
            storage.public_rings[name] = nil
        elseif game.tick >= (record.expires or game.tick) then
            evacuate(surface, nil)
            game.delete_surface(surface)
            storage.public_rings[name] = nil
            game.print({'pw.public-ring-expired', record.original_owner or tostring(record.id or '')})
            removed = removed + 1
        end
    end
    return removed
end

-- 删除某人的戴森环，同时删除他名下的飞船。经验一点不动，下次进环重新长出来。
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
    ships.destroy_owned(player)
    M.queue_player_cleanup(player)

    storage.ring_state = storage.ring_state or {}
    storage.ring_state[player.name] = nil
    storage.ring_applied_half = storage.ring_applied_half or {}
    storage.ring_applied_half[player.name] = nil
    storage.ring_applied_half_length = storage.ring_applied_half_length or {}
    storage.ring_applied_half_length[player.name] = nil
    ring.forget_private_surface(player)
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
    storage.ring_applied_half_length = storage.ring_applied_half_length or {}

    local deleted = 0
    for _, player in pairs(game.players) do
        local surface = M.get(player)
        if surface and surface.valid then
            game.delete_surface(surface)
            ships.destroy_owned(player)
            M.queue_player_cleanup(player)
            storage.ring_state[player.name] = nil
            storage.ring_applied_half[player.name] = nil
            storage.ring_applied_half_length[player.name] = nil
            ring.forget_private_surface(player)
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
        -- 收回私有的同时从公开列表里撤下来。只把人请出去而留着列表入口，
        -- 等于访客关掉传送窗口换成遥控视角，照样能在里面下拆除令。
        sync_visibility(surface, player.name)
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
-- 时长走 util.played_hours 而不是直接读 player.online_time：那是一份只增不减的快照，
-- 挡住 game.reset_time_played()（每轮 Nauvis 重置会调）可能带来的归零，理由见那边的注释。
-- 新建角色是 0，靠 ring_min_hours 兜住下限，不会一离线就立刻公共化。
function M.public_threshold(player)
    local cap_hours = storage.ring_public_hours or 30
    local min_hours = storage.ring_min_hours or 3
    local played_hours = util.played_hours(player)
    local hours = math.max(min_hours, math.min(cap_hours, played_hours))
    return hours * constants.hour_to_tick
end

-- 这个玩家的删除阈值（tick）。直接是公共化阈值的固定倍数，不再单独算一遍。
--
-- 为什么改成「乘公共化阈值」而不是「自己有一套上限和缩放」：
-- 两条阈值各算各的时，新人的删除线可能反而比公共线更早到（缩放系数不同），
-- 于是环还没经历过公共期就直接没了 —— 中间态是本场景的核心玩法，
-- 不该因为参数取值不当而被跳过。乘出来的版本在数学上永远保证
-- 删除线 = 倍数 × 公共线 > 公共线，任何参数组合都不可能倒挂。
-- 默认 3 倍：下限 3 小时 → 9 小时删除，上限 30 小时 → 90 小时删除。
function M.delete_threshold(player)
    return M.public_threshold(player) * (storage.ring_delete_multiple or 3)
end

-- private → public 跃迁。周期扫描和「访客点进来」两条路都走这里，保证行为一致。
-- 已经是 public 的直接返回 false，幂等。
function M.make_public(player)
    storage.ring_state = storage.ring_state or {}
    if storage.ring_state[player.name] == 'public' then return false end
    if not M.get(player) then return false end

    storage.ring_state[player.name] = 'public'
    chests.set_array_link(player, constants.PUBLIC_LINK_ID)
    -- 状态一变，遥控视角列表里立刻多出这条环（顶着主人的名字）。
    -- 必须在写完 ring_state 之后调，ring_should_hide 读的就是那个字段。
    local surface = M.get(player)
    if surface and surface.valid then sync_visibility(surface, player.name) end
    game.print({'pw.ring-public', player.name})
    return true
end

-- 周期任务：扫描离线玩家，做 private → public 和 public → 删除 两个跃迁。
--
-- 【关键】阈值每次现读、现算 idle，绝不缓存成「到期 tick」。
-- 存了到期 tick 的话，改配置就只对新数据生效，服务器会处于两套规则并存的状态。
function M.tick_lifecycle()
    storage.ring_state = storage.ring_state or {}
    M.tick_player_cleanup()
    tick_public_rings()

    for _, player in pairs(game.players) do
        -- 顺手把显示层重新对一遍。状态跃迁那几处已经各自同步过了，这里是兜底：
        -- 管理员热改 ring_hide_private、或者手工改过某人的 ring_state 之后，
        -- 不重进环也能在下一轮扫描时自动对齐，不会留下"状态是公共、列表里却没有"的错位。
        local surface = M.get(player)
        if surface and surface.valid then
            sync_visibility(surface, player.name)
            -- 永昼和太阳能倍率一并兜底：已经存在的环没走过 ensure，靠这里补上，
            -- 不需要环主重新进环、也不需要重建环。
            sync_daylight(surface)
        end

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
                -- 等级和半长一起给出来：半长本来就是等级算的，让调用方自己再算一遍
                -- 等于把"环长怎么来的"这条规则复制到 GUI 里，改规则时会漏改一处。
                level = ring.level_of(player.name),
                half_length = ring.half_length_of(player.name),
                state = storage.ring_state[player.name] or 'private',
                public_hours = public_hours,
                enterable = idle >= public_hours,
            }
        end
    end
    return out
end

function M.public_rings()
    storage.public_rings = storage.public_rings or {}
    local out = {}
    for name, record in pairs(storage.public_rings) do
        local surface = game.surfaces[name]
        if surface and surface.valid then
            out[#out + 1] = {
                id = record.id or ring.public_ring_id_of_name(name) or 0,
                name = name,
                original_owner = record.original_owner,
                left_hours = math.max(0, math.floor(((record.expires or game.tick) - game.tick) / constants.hour_to_tick)),
            }
        else
            storage.public_rings[name] = nil
        end
    end
    table.sort(out, function(a, b)
        if a.left_hours ~= b.left_hours then return a.left_hours < b.left_hours end
        return a.name < b.name
    end)
    return out
end

function M.enter_public_ring(player, id)
    storage.public_rings = storage.public_rings or {}
    for name, record in pairs(storage.public_rings) do
        if (record.id or ring.public_ring_id_of_name(name)) == id then
            local surface = game.surfaces[name]
            if not (surface and surface.valid) then
                storage.public_rings[name] = nil
                return false
            end
            local pos = surface.find_non_colliding_position('character', constants.RING_SPAWN, 64, 1)
                or constants.RING_SPAWN
            player.teleport(pos, surface)
            return true
        end
    end
    return false
end

return M
