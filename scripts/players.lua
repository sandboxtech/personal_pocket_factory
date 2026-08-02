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

-- 【唯一被禁的是「绕开 UI 自己建船 / 从原生界面删船」】。生产相关权限一律不禁，包括蓝图库 ——
-- 重置的是公共世界，玩家产线在戴森环里本来就不重置，蓝图加速不了任何东西。
-- 关联箱的防偷因此走实体级的 operable = false，不靠权限组，见 chests.lua。
--
-- 建船必须都从 ships.create 出生，否则脚本不知道船是谁的。而
-- lock_space_platforms() 只是关掉那个按钮，火箭井里还有一条
-- open_new_platform_button_from_rocket_silo，锁按钮挡不住。
--
-- 删船更要紧：飞船全服公有谁都能登，权限系统不能表达"只允许删除自己的平台"。
-- 放行 delete_space_platform 等于谁都能删任何一艘，且不可撤销。
-- 所以只留 overview 的拆船按钮 → ships.scuttle，只拆调用者自己那艘。
-- cancel_delete_space_platform 和 rename 故意不禁：前者禁了只会让删除撤不回，
-- 后者归属记在平台 index 上，改名纯属外观。
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

-- 起始装备（默认：模块装甲 + 个人机器人指令模块 + 6 块太阳能板）。
--
-- 【发的是装好的一整套，不是一堆零件】：装甲直接穿上，模块直接插进装备栏。
-- 玩家刚死完站在空荡荡的环里，最不需要的就是"先自己把装备拼起来"这一步；
-- 而且个人机器人指令模块没有电就是块砖，太阳能板必须和它插在同一件装甲里才有意义，
-- 丢进背包等于把"这套装备能用"这件事变成了玩家要自己发现的知识。
--
-- 装不进去的一律退回背包（装甲栏已经有东西、装备栏放不下、名字写错）：
-- 这个函数在多条路径上被调用，任何一条都不该因为"装备栏满了"而静默吞掉物品。
local function equip_or_insert(player, armor_stack, item)
    local count = math.max(1, math.floor(item.count or 1))
    -- 装备原型和物品原型是两张表：solar-panel-equipment 两边都有，
    -- 但只有 prototypes.equipment 里那条才说明它能插进装备栏。
    if armor_stack and armor_stack.valid_for_read and prototypes.equipment[item.name] then
        local grid = armor_stack.grid
        if grid then
            for _ = 1, count do
                -- put 不给 position 时由引擎自己找空位；放不下返回 nil，
                -- 这时把这一个退回背包，继续试下一个（后面的可能更小、仍放得下）。
                if not grid.put{name = item.name} then
                    player.insert{name = item.name, count = 1}
                end
            end
            return
        end
    end
    player.insert{name = item.name, count = count}
end

-- 发一套起始装备，并记下时间。返回是否真的发了东西。
--
-- 时间戳记在 storage.starter_equipment_at[玩家名]（按名字，和 storage 其余部分一致），
-- 复活时的冷却判定读的就是它。
local function grant_equipment(player)
    local list = storage.starter_equipment or {}
    if #list == 0 then return false end

    -- 先把装甲穿上，再往它的装备栏里插模块 —— 顺序反了的话装备栏还不存在。
    -- 判据是"清单里第一件带 equipment_grid 的装甲"，不写死 modular-armor：
    -- 管理员把默认装甲换成动力装甲时，这段不需要跟着改。
    local armor_inv = player.get_inventory(defines.inventory.character_armor)
    for _, item in ipairs(list) do
        local proto = item.name and prototypes.item[item.name]
        if proto and armor_inv and armor_inv[1] and not armor_inv[1].valid_for_read
                and proto.equipment_grid then
            armor_inv[1].set_stack{name = item.name, count = 1}
        end
    end

    local armor_stack = armor_inv and armor_inv[1] or nil
    for _, item in ipairs(list) do
        if item.name and prototypes.item[item.name] then
            -- 已经穿在身上的那件装甲不要再发一次
            local worn = armor_stack and armor_stack.valid_for_read
                and armor_stack.name == item.name
            if not worn then
                equip_or_insert(player, armor_stack, item)
            end
        end
    end

    storage.starter_equipment_at = storage.starter_equipment_at or {}
    storage.starter_equipment_at[player.name] = game.tick
    return true
end
M.grant_equipment = grant_equipment

-- 距离上次领起始装备过了多久（tick）。从没领过返回一个大到必定过冷却的数。
local function since_equipment(player_name)
    storage.starter_equipment_at = storage.starter_equipment_at or {}
    local at = storage.starter_equipment_at[player_name]
    if not at then return math.huge end
    return game.tick - at
end

-- 复活时的补给：超过冷却就再发一套。
--
-- 【冷却的意义是把"死了重来"和"刷装备"分开】。没有冷却的话，玩家原地自杀就能
-- 无限刷模块装甲和太阳能板，那不是补给是产线。定成 3 小时（storage.starter_equipment_hours）
-- 是因为它比一轮星球重置还长：真正因为一次事故失去全部家当的人等得起，
-- 而想靠死亡刷装备的人会发现这比自己造慢得多。
function M.maybe_grant_equipment(player)
    local hours = storage.starter_equipment_hours or 3
    if since_equipment(player.name) < hours * constants.hour_to_tick then return false end
    if not grant_equipment(player) then return false end
    player.print({'pw.starter-equipment', hours})
    return true
end

events.on(defines.events.on_player_created, function(event)
    local player = game.players[event.player_index]
    if not player then return end

    player.force = game.forces.player   -- 单 force：显式钉死，不给任何人开新 force
    assign_group(player)
    pockets.enter(player)
    grant_starter(player)
    grant_equipment(player)   -- 新玩家一定给，不看冷却（他还没有过"上一次"）
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
    pockets.cancel_player_cleanup(player)
    -- 离线期间环被回收过的话，这里重建。玩家不会掉进一个已经不存在的 surface。
    if not pockets.get(player) then
        pockets.enter(player)
        -- 环被回收 = 建筑全没了，等于从零开始。所以起手物资和起始装备一起重发一份，
        -- 【不看冷却】：这条路径不是玩家能刻意触发的（环只会被管理员删或超时回收），
        -- 用冷却卡它只会让一个刚失去全部家当的人连第一台熔炉都造不出来。
        -- 仍然会记下时间戳，所以他不会转头再死一次又领一套。
        grant_starter(player)
        grant_equipment(player)
        player.print({'pw.ring-rebuilt'})
    else
        -- 环还在，但不代表它是【完整】的：曾经出现过「环建到一半抛错、系统收货箱缺席」
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
    -- 落地之后才发装备：pockets.enter 会 teleport，先发再传送也不会掉东西
    -- （物品在背包里跟着走），但复活提示和装备到手的提示挨在一起更容易看懂。
    M.maybe_grant_equipment(player)
end)

return M
