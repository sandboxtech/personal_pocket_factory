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
-- 不 require pockets：船销毁时不再手工撤人（引擎会处理站在消失表面上的角色，
-- 玩家走正常复活流程回到自己的环），这条依赖边随那段逻辑一起消失了。
local constants = require('scripts.constants')
local events = require('scripts.events')
-- ring 只依赖 constants 和 geometry，两者都不反向依赖 ships，顶层 require 不成环。
local ring = require('scripts.ring')

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

local ensure_life_started

-- 某人的船。顺手清掉指向已消失平台的记录 —— 登记表的自愈只发生在这一个地方，
-- 其它函数都经由本函数取船，所以不会有第二处需要同步维护的清理逻辑。
function M.of(player)
    if not (player and player.valid) then return nil end
    for index, record in pairs(records()) do
        if record.owner == player.name then
            local platform = platform_of(index)
            if platform then
                ensure_life_started(record, platform)
                return platform, record
            end
            records()[index] = nil   -- 在 pairs 里把已存在的键赋 nil 是 Lua 明确允许的
        end
    end
    return nil
end

-- 船成形了没有。起步包还没用火箭发上来的平台没有 surface，登不上去。
function M.is_ready(platform)
    if not (platform and platform.valid) then return false end
    local surface = platform.surface
    return (surface and surface.valid) and true or false
end

-- 这艘船的寿命（tick）。从平台 surface 真正出现开始算，到期即销毁。
function M.life_ticks()
    return (storage.ship_life_hours or 50) * constants.hour_to_tick
end

-- 旧存档里已经成形的船没有 built 字段，只能沿用旧 created 字段作为寿命起点；
-- 还没成形的船不补 built，等 on_surface_created 捕到真正建设完成的时刻。
function ensure_life_started(record, platform)
    if not record or record.built then return end
    if M.is_ready(platform) then
        record.built = record.created or game.tick
    end
end

-- 还能活多久（tick）。记录不存在返回 nil；尚未成形返回完整寿命；已超期返回负数。
function M.left_ticks(record)
    if not record then return nil end
    local started = record.built
    if not started then return M.life_ticks() end
    return started + M.life_ticks() - game.tick
end

-- 这艘船该有多宽：和主人的戴森环等级挂钩，公式是 per_level × (等级 + bonus)，
-- 配置 (16, 4) 即【宽度 = 16 × (4 + 等级)】。无主飞船按等级 0 算。
--
-- 【为什么船也跟着等级长】：船和环是同一个人的两处资产，只有环会随经验变宽的话，
-- 船就成了一个和成长完全脱钩的固定盒子 —— 后期玩家的船和新人的船一样大，
-- 而他要往船上塞的东西多得多。挂上等级之后，"攒经验"这件事同时喂两条线。
--
-- 高度不跟等级走，仍用固定的 storage.ship_height：太空平台是纵向航行的，
-- 高度对应"航程上的纵深"，横向才是玩家真正铺东西的方向。两个方向都膨胀的话
-- 存档体积是平方级增长，而存档体积是本项目的头号约束。
function M.width_for(owner_name)
    local per_level = storage.ship_width_per_level or 16
    local bonus = storage.ship_width_bonus or 4
    local level = owner_name and ring.level_of(owner_name) or 0
    return per_level * (level + bonus)
end

-- 给飞船 surface 套上引擎级硬边界，和戴森环同一个思路：能让引擎不生成的区块，
-- 就不要靠脚本涂砖去挡。存档体积是本项目的头号约束。
--
-- 【pcall 包起来，且放在登记之后】：平台 surface 能不能改 map_gen_settings 是未验证的，
-- 而边界失败顶多是存档大一点，绝不该连累"船已经造出来了"这个事实。
-- 这条规矩是修 set_surface_hidden 那个 bug 换来的（见 pockets.hide_surface 的注释）：
-- 未验证的、非关键的调用绝不允许排在关键步骤前面。
local function apply_bounds(platform, owner_name)
    local surface = platform.surface
    if not (surface and surface.valid) then return end
    local ok, err = pcall(function()
        local mgs = surface.map_gen_settings
        mgs.width = M.width_for(owner_name)
        mgs.height = storage.ship_height or 512
        surface.map_gen_settings = mgs
    end)
    if not ok then
        log('[pw] 飞船边界设置失败（不影响飞船本身）：' .. tostring(err))
    end
end

-- ══ 禁用原生建船，只留 UI 这一条路 ══
--
-- lock_space_platforms() 是【纯 UI 闸门】。引擎文档写得很克制：
--   lock_space_platforms  "Locks the space platforms, which disables the space platforms button"
--   is_space_platforms_unlocked  "This basically just controls the availability of the
--                                 space platforms button"
-- 它不拦 create_space_platform 这个脚本调用，所以「玩家自己建不了、脚本能建」正好成立。
-- 这是本场景需要归属制的前提：船必须都从 M.create 出生，才谈得上"这是谁的船"。
--
-- 【为什么要反复锁，不能只在 on_init 锁一次】：
-- 按钮的解锁是引擎内部行为。space-platform 科技是个 trigger 科技
-- （research_trigger = {type = "create-space-platform"}），效果只解锁几个配方，
-- 并不负责解锁那个按钮 —— 也就是说我没法从原型里枚举出全部会重新解锁它的路径。
-- 之前关联箱防偷那轮的教训是【枚举触发点必然漏】，所以这里不枚举：
-- 本函数幂等，由 on_research_finished 和每分钟的调度器各调一次，
-- 无论谁把它解开，最迟一分钟内会被重新锁上。
function M.enforce_lock()
    local force = game.forces.player
    if storage.ship_lock_native_creation == false then
        if not force.is_space_platforms_unlocked() then force.unlock_space_platforms() end
        return
    end
    if force.is_space_platforms_unlocked() then
        force.lock_space_platforms()
    end
end

events.on(defines.events.on_research_finished, function()
    M.enforce_lock()
end)

-- 造一艘。成功返回 platform，失败返回 nil 加一个本地化 key。
--
-- 【起步包仍然要用火箭发上去】：本函数只负责把平台登记出来，它诞生时处在
-- waiting_for_starter_pack 状态，surface 还不存在
-- （文档原话："The surface that belongs to this platform (if it has been created yet)"）。
-- 玩家得照常造火箭、把 space-platform-starter-pack 发上天，平台才真正成形。
-- 换句话说 UI 按钮换掉的只是"谁来按下创建"这一步，太空玩法本来的门槛一点没降 ——
-- 这正是"启动包还是要发射"的意思。surface 出现时 on_surface_created 会接手套边界。
function M.create(player)
    if not (player and player.valid) then return nil, 'pw.ship-create-failed' end
    if M.of(player) then return nil, 'pw.ship-already-have' end

    local platform = game.forces.player.create_space_platform{
        name = player.name,
        planet = storage.ship_home_planet or 'nauvis',
        starter_pack = STARTER_PACK,
    }
    if not platform then
        -- 把当时的闸门状态一并记下来：如果哪天引擎改成"锁了就连脚本也不让建"，
        -- 这条 log 是唯一能立刻指出真凶的线索，否则只会看到一个没有理由的失败。
        log('[pw] create_space_platform 返回 nil；space_platforms_unlocked = '
            .. tostring(game.forces.player.is_space_platforms_unlocked()))
        return nil, 'pw.ship-create-failed'
    end

    records()[platform.index] = {owner = player.name, created = game.tick}
    apply_bounds(platform, player.name)   -- 此刻多半还没有 surface，真正生效的是 on_surface_created 里那次

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

    local rs = records()
    local record = rs[platform.index]

    -- 脚本自己造的船在 M.create 里已经登记过；没登记的就是玩家从火箭井原生造的，
    -- 收编成无主飞船，创建时刻取"第一次看见它"的这一刻。
    if not record then
        record = {owner = nil, created = game.tick}
        rs[platform.index] = record
    end

    -- surface 出现才代表起步包已经发上来、船真正成形，寿命从这里开始扣。
    record.built = record.built or game.tick

    apply_bounds(platform, record.owner)
end

events.on(defines.events.on_surface_created, function(event)
    on_platform_surface(game.surfaces[event.surface_index])
end)

-- 玩家主动拆掉【自己的】船。返回 true 表示拆了。
--
-- 【只能拆自己的，而且没有管理员批量版本】。飞船是全服公有的（谁都能登船、谁都能用），
-- 但"拆"这件事只有船主能做 —— 一个人能拆别人的船，等于一个人能把别人囤在船上的东西
-- 连船一起清空，那比偷关联箱严重得多，而且不可撤销。
-- 所以这个函数【只接受一个 player 参数，拆的永远是他名下那艘】，
-- 不提供"按 index 拆"的入口，从签名上就不给越权留位置。
--
-- 为什么需要主动拆：每人同时只能有一艘，想换个环绕星球、或者上一艘卡在
-- 等起步包的状态回不来了，需要有一个明确的放弃入口。
function M.scuttle(player)
    local platform, record = M.of(player)
    if not platform then return false end
    local index = platform.index
    platform.destroy()
    records()[index] = nil
    game.print({'pw.ship-scuttled', player.name})
    return true
end

-- 删除某玩家名下的船。给戴森环回收流程用，按登记表的 key（平台 index）删，
-- 不按平台 name 删：船可以被玩家改名，name 不是可靠身份。
function M.destroy_owned(player)
    if not (player and player.valid) then return false end

    for index, record in pairs(records()) do
        if record.owner == player.name then
            local platform = platform_of(index)
            if platform then platform.destroy() end
            records()[index] = nil
            return platform and true or false
        end
    end
    return false
end

-- 所有在册飞船，供 GUI 列出。顺手清掉指向已消失平台的记录。
-- 每项：{ index, owner（可能是 nil）, platform, left_hours, location（星球名或 nil） }
function M.all()
    local out = {}
    for index, record in pairs(records()) do
        local platform = platform_of(index)
        if platform then
            ensure_life_started(record, platform)
            -- space_location 在飞船停泊时是星球原型，航行途中是 nil。
            -- 只取 name 交给 GUI，GUI 自己决定怎么显示（图标 / "航行中"）。
            local location = platform.space_location
            out[#out + 1] = {
                index = index,
                owner = record.owner,
                platform = platform,
                left_hours = math.floor(math.max(0, M.left_ticks(record)) / constants.hour_to_tick),
                location = location and location.name or nil,
                -- 起步包还没发射上来的平台没有 surface，登不上去。
                -- 判据直接用「surface 在不在」而不是比对 state 枚举：
                -- 能不能登船取决于有没有地方站，这就是那个条件本身。
                ready = M.is_ready(platform),
            }
        else
            records()[index] = nil
        end
    end
    return out
end

-- 周期任务：销毁超龄的飞船。由 scripts/tick.lua 的相位调度器调用（相位 3）。
--
-- 【不撤人】。和戴森环删除同一套规矩：船没了，还在船上的人跟着没，
-- 然后走正常复活流程回到自己的戴森环（on_player_respawned → pockets.enter）。
-- 引擎自己会处理表面消失时站在上面的角色，脚本不需要抢在前面搬人 ——
-- 要管好的是复活点，不是销毁那一刻的玩家状态。
-- 船本来就是有寿命的临时资产，跟船一起沉掉也符合它的定位。
function M.tick_lifecycle()
    local destroyed = 0
    for index, record in pairs(records()) do
        local platform = platform_of(index)
        if not platform then
            records()[index] = nil
        else
            ensure_life_started(record, platform)
        end
        if platform and record.built and M.left_ticks(record) <= 0 then
            local label = record.owner or platform.name
            platform.destroy()
            records()[index] = nil
            destroyed = destroyed + 1
            game.print({'pw.ship-expired', label})
        end
    end
    return destroyed
end

return M
