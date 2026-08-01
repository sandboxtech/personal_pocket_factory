-- 玩家生命周期 + 权限组。
--
-- 单 force 设计：所有玩家都留在 game.forces.player，本场景不创建任何额外 force。
-- 理由是 chart（地图勘探数据）是 per force per surface per chunk 存的，
-- 引擎按 RGB565 每像素 2 字节存原始像素（见 LuaForce::get_chunk_chart 的文档），
-- 每多一个 force 就多存一整份地图。人数一多，光 chart 就能把存档撑到几十 MB。
-- 产权隔离本场景靠"每人一个独立 surface"实现，不需要用 force 来隔。
local constants = require('scripts.constants')
local events = require('scripts.events')
local pockets = require('scripts.pockets')
local stamina = require('scripts.stamina')
-- 依赖图确认：gui.init 及其全部传递依赖（popup/hud/convert/travel/exp/help/claim,
-- 以及再往下的 pockets/chests/ring/worlds/exp/util/geometry/constants/stamina）
-- 都不会反过来 require players.lua 或 tick.lua，不构成环，可以在顶层直接 require。
-- 用 gui.init 而不是直接点 gui/hud.lua，是为了走和 tick.lua 一致的公共入口
-- （gui.refresh_hud），不绕开 gui 模块自己的路由层。
local gui = require('scripts.gui.init')

local M = {}

-- 本场景【默认不禁用玩家任何生产相关的权限】，包括蓝图库。
--
-- v1 禁蓝图的理由是「允许蓝图库的话，重置后 Ctrl+V 一秒恢复布局，重置就只剩重跑一遍物流」。
-- 但这条理由在本版已经不成立：重置的是【公共世界】，而玩家的产线在【戴森环】里，
-- 本来就不会被重置。公共世界上只有采集前哨，那本来就该是能快速重铺的东西。
-- 本版真正的持续压力来自科技漏水和弃厂公有化，蓝图一个都加速不了。
--
-- 关联箱的防偷因此不能靠权限组，改用实体级的 operable = false，见 chests.lua。
--
-- ══ 唯一被禁的是「绕开 UI 自己建船 / 删船」这一组动作 ══
--
-- 归属制成立的前提是【每艘船都从 ships.create 出生】，否则脚本不知道船是谁的。
-- ships.enforce_lock() 调的 lock_space_platforms() 只是【关掉那个按钮】
-- （引擎文档原话："disables the space platforms button"），而建船的入口不止一个：
-- input_action 里明明白白有一条 open_new_platform_button_from_rocket_silo ——
-- 火箭井里还有一条路。只锁按钮挡不住它。
--
-- 删船同理，而且更要紧：delete_space_platform 是玩家自己就能触发的动作，
-- 一旦放行，任何人都能删【任何一艘】船（飞船全服公有，谁都能登船，也就都能删）。
-- 这比偷关联箱严重得多且不可撤销。所以删船只走 UI 那条路：
-- scripts/gui/overview.lua 的拆船按钮 → ships.scuttle(player)，只拆调用者自己那艘。
--
-- cancel_delete_space_platform 【故意不禁】：禁掉它只会让某个由别的路径排上的删除
-- 变得撤销不了，纯粹有害无益。
-- rename_space_platform 也不禁：归属记在 storage 的平台 index 上，改名纯属外观。
local ACTION_GROUPS = {
    {
        -- 复用飞船那个开关：它的含义本来就是「UI 是建船的唯一入口」。
        -- 设成 false 就恢复原版行为（同时 ships.enforce_lock 会把按钮解锁回去）。
        flag = 'ship_lock_native_creation',
        actions = {
            'create_space_platform',
            'instantly_create_space_platform',
            'open_new_platform_button_from_rocket_silo',
            'delete_space_platform',
        },
    },
}

local GROUP_NAME = 'pw_default'

-- 建（或取）本场景的权限组，并按各组自己的开关禁用动作。
--
-- 【生效时机】：本函数在 on_init / on_configuration_changed 时调用，
-- 所以热改那些开关不会立刻改变权限组，要等下次加载。按钮那把锁（ships.enforce_lock）
-- 才是每分钟压一遍的。两者一起构成「按钮看不见 + 动作发不出去」两道。
--
-- defines.input_action[name] 取不到时（版本改名/拼错）返回 nil，直接传给 set_allows_action 会崩，
-- 所以逐个校验、跳过并写 log —— 新版 Factorio 改了动作名的话，日志里会留下线索，
-- 而不是安静地少禁一条。
function M.setup_perm_group()
    local perms = game.permissions
    local group = perms.get_group(GROUP_NAME) or perms.create_group(GROUP_NAME)
    if not group then return nil end

    for _, entry in ipairs(ACTION_GROUPS) do
        -- 开关默认开启：storage 里没有这个字段时按「禁用」处理，
        -- 宁可多禁一条也不要在配置缺失时把归属制的前提悄悄放开。
        local blocked = storage[entry.flag] ~= false
        for _, action_name in ipairs(entry.actions) do
            local action = defines.input_action[action_name]
            if action then
                group.set_allows_action(action, not blocked)
            else
                log('[pw] 权限组跳过无效 input_action 名: ' .. tostring(action_name))
            end
        end
    end
    return group
end

-- 把玩家放进本场景的权限组。管理员想手动调用 /permissions 改组的话，脚本不会覆盖组内动作配置。
local function assign_group(player)
    local group = game.permissions.get_group(GROUP_NAME) or M.setup_perm_group()
    if group then group.add_player(player) end
end

-- 新玩家的起手物资。戴森环里一颗矿都没有，不给起手就真的寸步难行。
--
-- 清单在 storage.starter_items（默认值和改法见 constants.ensure_defaults），
-- 不写死在这里 —— 管理员可以按服务器节奏加减，改完对之后进来的新玩家立刻生效。
--
-- 逐项现查 prototypes.item：名字打错的那一项被跳过，其余照发。
-- 直接 insert 一个不存在的物品名会抛错，而这个函数跑在 on_player_created 里 ——
-- 抛错就意味着新玩家卡在进场流程中间（权限组已设、环已建、体力和 HUD 都还没来），
-- 为一个配置错别字付出这个代价太贵了。
local function grant_starter(player)
    for _, item in ipairs(storage.starter_items or {}) do
        if item.name and prototypes.item[item.name] then
            player.insert{name = item.name, count = item.count or 1}
        end
    end
end

events.on(defines.events.on_player_created, function(event)
    local player = game.players[event.player_index]
    if not player then return end

    player.force = game.forces.player   -- 单 force：显式钉死，不给任何人开新 force
    assign_group(player)
    pockets.enter(player)
    grant_starter(player)
    -- 新玩家的初始体力池。默认倍数是 0，也就是不白送——所有人都从"攒"开始。
    -- 仍然保留这个入口：storage.stamina_initial_multiple 调大就是一份新手礼包，
    -- 派生自可领取上限而不是写死数字，调 cap 时礼包大小自动跟着变。
    local initial = (storage.stamina_pending_cap or 100000) * (storage.stamina_initial_multiple or 0)
    if initial > 0 then stamina.add(player.name, initial) end
    player.print({'pw.welcome'})
    -- 进场立刻建 HUD，不能指望周期刷新任务顺手把它建出来——
    -- 那个任务的间隔现在是 storage.hud_refresh_ticks（默认 3600 tick），
    -- 全指望它的话新玩家要等一分钟才能看到任何 UI。
    gui.refresh_hud(player)
end)

events.on(defines.events.on_player_joined_game, function(event)
    local player = game.players[event.player_index]
    if not player then return end
    assign_group(player)
    -- 离线期间环被回收过的话，这里重建。玩家不会掉进一个已经不存在的 surface。
    if not pockets.get(player) then
        pockets.enter(player)
        player.print({'pw.ring-rebuilt'})
    else
        -- 环还在，但不代表它是【完整】的：曾经出现过「环建到一半抛错、12 个收货箱缺席」
        -- 的存档（见 pockets.hide_surface 的注释）。pockets.ensure 现在是幂等自愈的，
        -- 每次进场跑一遍就能把这类半成品环补齐，代价可以忽略。
        pockets.ensure(player)
        -- 公共期回来的话立刻收回：箱子换回个人 id，访客请出去
        pockets.restore_on_join(player)
    end
    -- 同上：重连/老存档升级后首次进场，同样不能干等周期任务把 HUD 建出来。
    gui.refresh_hud(player)
end)

events.on(defines.events.on_player_respawned, function(event)
    local player = game.players[event.player_index]
    if not player then return end
    -- 死了一律回自己的口袋世界，这里是唯一安全的地方
    pockets.enter(player)
end)

return M
