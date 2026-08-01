-- 飞船（太空平台）：全服公有、每人最多一艘、以主人的名字命名、寿命有限。
--
-- 定位：戴森环是【永久】的加工厂，公共星球是【几小时就重置】的矿场，
-- 飞船夹在中间 —— 它比星球活得久，但终究会没。所以它适合放"这一轮要用的东西"，
-- 不适合当仓库；真正想留下的产出还是得靠关联箱送回环里。
--
-- ══ 为什么必须有这个模块，光"列出 force.platforms"不行 ══
-- 引擎【没有平台创建事件，也不记录创建者和创建时刻】。LuaSpacePlatform 身上能读到
-- index / name / surface / space_location / state / hidden，唯独没有"谁造的"。
-- 所以"归属"这件事只可能由我们自己建立：脚本负责创建，创建的那一刻把主人和时刻记下来。
--
-- ══ 登记表为什么按平台 index 而不是玩家名做主键 ══
-- 因为存在【无主飞船】：玩家仍然可以从火箭井原生造平台，那种船脚本没参与创建、
-- 不知道是谁的。按玩家名做主键的话，这类船在表里根本没有位置可放。
-- 平台 index 才是这件事真正的主键，主人只是它的一个属性（可以为 nil）。
local constants = require('scripts.constants')
local events = require('scripts.events')
local pockets = require('scripts.pockets')

local M = {}

local STARTER_PACK = 'space-platform-starter-pack'

-- 取平台对象。index 指向的平台已经不在了就返回 nil，绝不返回幽灵对象。
local function platform_of(index)
    local platform = game.forces.player.platforms[index]
    if platform and platform.valid then return platform end
    return nil
end

local function records()
    storage.ships = storage.ships or {}
    return storage.ships
end

-- 某人的船。顺手清掉指向已消失平台的记录 —— 登记表的自愈只发生在这一个地方，
-- 其它函数都经由本函数取船，所以不会有第二处需要同步维护的清理逻辑。
function M.of(player)
    if not (player and player.valid) then return nil end
    for index, record in pairs(records()) do
        if record.owner == player.name then
            local platform = platform_of(index)
            if platform then return platform, record end
            records()[index] = nil   -- 在 pairs 里把已存在的键赋 nil 是 Lua 明确允许的
        end
    end
    return nil
end

-- 这艘船的寿命（tick）。到期即销毁。
function M.life_ticks()
    return (storage.ship_life_hours or 50) * constants.hour_to_tick
end

-- 还能活多久（tick）。记录不存在返回 nil，已超期返回负数。
function M.left_ticks(record)
    if not record then return nil end
    return record.created + M.life_ticks() - game.tick
end

-- 给飞船 surface 套上引擎级硬边界，和戴森环同一个思路：能让引擎不生成的区块，
-- 就不要靠脚本涂砖去挡。存档体积是本项目的头号约束。
--
-- 【pcall 包起来，且放在登记之后】：平台 surface 能不能改 map_gen_settings 是未验证的，
-- 而边界失败顶多是存档大一点，绝不该连累"船已经造出来了"这个事实。
-- 这条规矩是修 set_surface_hidden 那个 bug 换来的（见 pockets.hide_surface 的注释）：
-- 未验证的、非关键的调用绝不允许排在关键步骤前面。
local function apply_bounds(platform)
    local surface = platform.surface
    if not (surface and surface.valid) then return end
    local ok, err = pcall(function()
        local mgs = surface.map_gen_settings
        mgs.width = storage.ship_width or 256
        mgs.height = storage.ship_height or 512
        surface.map_gen_settings = mgs
    end)
    if not ok then
        log('[pw] 飞船边界设置失败（不影响飞船本身）：' .. tostring(err))
    end
end

-- 造一艘。成功返回 platform，失败返回 nil 加一个本地化 key。
function M.create(player)
    if not (player and player.valid) then return nil, 'pw.ship-create-failed' end
    if M.of(player) then return nil, 'pw.ship-already-have' end

    -- 起步包自备。这保留了太空玩法本来的门槛 —— 白送一艘船的话，
    -- "上太空"就从一个需要攒产能的目标退化成一个点一下的按钮。
    local need_pack = storage.ship_require_starter_pack ~= false
    if need_pack and player.get_item_count(STARTER_PACK) < 1 then
        return nil, 'pw.ship-no-pack'
    end

    -- 【先造后扣】：造船可能因为各种引擎内部原因返回 nil，先扣包再失败的话
    -- 玩家白丢一个起步包。两条语句之间没有任何让物品数量发生变化的机会，
    -- 所以"先造后扣"不会出现扣不到的情况。
    local platform = game.forces.player.create_space_platform{
        name = player.name,
        planet = storage.ship_home_planet or 'nauvis',
        starter_pack = STARTER_PACK,
    }
    if not platform then return nil, 'pw.ship-create-failed' end

    if need_pack then
        player.remove_item{name = STARTER_PACK, count = 1}
    end

    records()[platform.index] = {owner = player.name, created = game.tick}

    -- 立刻把起步包落地。
    --
    -- 【为什么必须显式调这一下】：新建的平台默认处在 waiting_for_starter_pack 状态，
    -- 等着火箭把起步包送上来，在那之前 LuaSpacePlatform.surface 是 nil
    -- （文档原话："The surface that belongs to this platform (if it has been created yet)"）。
    -- 而本场景是从玩家背包里直接扣掉一个起步包换这艘船的，货已经收了，
    -- 就不该再让玩家去发一次火箭。apply_starter_pack() 正是为这种情况准备的，
    -- 调完 surface 当场就有，玩家点「登船」立刻能上去。
    local ok, err = pcall(function() platform.apply_starter_pack() end)
    if not ok then
        -- 失败也不回滚：船已经登记了，它只是还停在等起步包的状态，玩家仍可以自己发火箭补上。
        -- 直接删船反而会把刚扣掉的那个起步包也一起吞掉。
        log('[pw] apply_starter_pack 失败（飞船仍在，停在等起步包状态）：' .. tostring(err))
    end

    apply_bounds(platform)

    game.print({'pw.ship-created', player.name})
    return platform
end

-- 无主飞船的登记。玩家仍然可以从火箭井原生造平台，那种船脚本没参与创建、
-- 不知道主人是谁，但【寿命规则对它一视同仁】—— 否则"每艘船都是临时的"这条规则
-- 就有了一个人人都能走的后门：原生造的船永不过期。
-- 创建时刻只能取"第一次看见它"的时刻，这对原生造的船就是它诞生的那一刻。
--
-- 走 on_surface_created：引擎没有平台创建事件，但平台的 surface 一定要诞生，
-- 而 LuaSurface.platform 能从 surface 反查到平台对象。这是能拿到的最早时机。
--
-- 这个处理器同时负责【补涂边界】：平台刚创建时 surface 可能还不存在
-- （停在 waiting_for_starter_pack 状态），M.create 里那次 apply_bounds 就落了空。
-- 等 surface 真的出现时本处理器一定会被调到，那时候再套一次边界是最可靠的时机。
-- apply_bounds 幂等（就是覆写 map_gen_settings），重复调没有副作用。
local function on_platform_surface(surface)
    if not (surface and surface.valid) then return end
    local platform = surface.platform
    if not (platform and platform.valid) then return end

    -- 脚本自己造的船在 M.create 里已经登记过；没登记的就是玩家从火箭井原生造的，
    -- 收编成无主飞船，创建时刻取"第一次看见它"的这一刻。
    if not records()[platform.index] then
        records()[platform.index] = {owner = nil, created = game.tick}
    end

    apply_bounds(platform)
end

events.on(defines.events.on_surface_created, function(event)
    on_platform_surface(game.surfaces[event.surface_index])
end)

-- 把还站在某艘船上的人撤回各自的戴森环。销毁前调用，不把人清进虚空。
local function evacuate(platform)
    local surface = platform.surface
    if not (surface and surface.valid) then return end
    for _, p in pairs(game.connected_players) do
        if p.surface == surface then
            p.print({'pw.ship-evacuated'})
            pockets.enter(p)
        end
    end
end

-- 所有在册飞船，供 GUI 列出。顺手清掉指向已消失平台的记录。
-- 每项：{ index, owner（可能是 nil）, platform, left_hours, location（星球名或 nil） }
function M.all()
    local out = {}
    for index, record in pairs(records()) do
        local platform = platform_of(index)
        if platform then
            -- space_location 在飞船停泊时是星球原型，航行途中是 nil。
            -- 只取 name 交给 GUI，GUI 自己决定怎么显示（图标 / "航行中"）。
            local location = platform.space_location
            out[#out + 1] = {
                index = index,
                owner = record.owner,
                platform = platform,
                left_hours = math.floor(math.max(0, M.left_ticks(record)) / constants.hour_to_tick),
                location = location and location.name or nil,
            }
        else
            records()[index] = nil
        end
    end
    return out
end

-- 周期任务：销毁超龄的飞船。先撤人再炸，和戴森环 50 小时删除同一套规矩。
-- 由 scripts/tick.lua 的相位调度器调用（相位 3）。
function M.tick_lifecycle()
    local destroyed = 0
    for index, record in pairs(records()) do
        local platform = platform_of(index)
        if not platform then
            records()[index] = nil
        elseif M.left_ticks(record) <= 0 then
            local label = record.owner or platform.name
            evacuate(platform)
            platform.destroy()
            records()[index] = nil
            destroyed = destroyed + 1
            game.print({'pw.ship-expired', label})
        end
    end
    return destroyed
end

return M
