-- 全局常量 + storage 默认值的【唯一出生地】。
-- ensure_defaults() 在 on_init / on_configuration_changed / 每次世界重置时都会调用，幂等、不覆盖已调过的值。
-- 各模块使用点仍保留 nil 兜底：ensure_defaults 是幂等的（storage.x = storage.x or 默认值），
-- 所以【本次新加的字段在开发中途重载的存档里可能还没有值】，直接索引会崩。
-- 这不是为了兼容历史版本存档——本项目不承诺跨版本存档兼容，赛季直接开新档。
local geometry = require('scripts.geometry')

local M = {}

M.sec_to_tick = 60
M.min_to_tick = 60 * 60
M.hour_to_tick = 60 * 60 * 60

-- 公共世界：本场景只用太空时代的五个真星球。
-- 用真星球（而不是 game.create_surface 造裸 surface）是为了拿到星球原型级机制：
-- Fulgora 闪电、Aquilo 冻结、Vulcanus 巨虫领地、各自的 autoplace 与表面属性基准。
-- 裸 surface 只能靠 set_property 调那几个表面属性，这些机制一个都拿不到。
M.PUBLIC_PLANETS = {'nauvis', 'vulcanus', 'gleba', 'fulgora', 'aquilo'}

-- 公共库存的 link_id。player.index 从 1 开始，所以 0 永不碰撞。
-- 全服只有一个公共库存：所有弃厂的产出汇进同一个池子。
M.PUBLIC_LINK_ID = 0
M.SHIP_STAMINA_COST = 1000
M.RESPAWN_EQUIPMENT_COST = 1000

-- ══ 环心布局：8 个收货箱的两行，以及玩家进环的落点 ══
--
-- 【这几个值必须一起改】：落点绝不能落在箱阵占的格子上，否则玩家一进环就被挤走。
--
-- 横排两行各 4 个，夹着中间 4×4 的水池。8 个箱子是【并行存取口】不是 8 倍容量
-- （同 link_id 共享一份库存），机械臂站在箱阵外侧上下两面取货。
-- 竖排会吃掉可建带（现在只有 16 格高）的太多空间，而环是横向无限延伸的。
--
-- 箱行和池岸之间留 2 格空地：海洋泵要站陆地上、泵口朝水，四面都有岸才能四面取水，
-- 空出的 2 格正好摆下泵 + 一段管道。
M.CHEST_ROWS = {-5, 4}         -- 两行各自占的 tile y
M.CHEST_COL_FROM = -2          -- 每行 4 个，tile x 从这里
M.CHEST_COL_TO = 1             -- 到这里（闭区间）
-- 落点就在【环心】，也就是两行箱子中间那片浅水里。浅水可以走，不会卡住玩家。
M.RING_SPAWN = {0, 0}

-- ══ 可热改的配置项清单 ══
--
-- 【这张表是 ensure_defaults 的数据源，也是 /pw-config 指令的数据源】。
-- 一处定义、两处消费，所以「默认值」和「管理员看到的说明」不可能各说各话——
-- 分开维护的话，改了默认值忘了改文档是迟早的事。
--
-- 判空一律用 `== nil` 而不是 `or`：`storage.x = storage.x or 默认值` 对布尔 false 是错的
-- （false 会被当成「没设过」而被默认值覆盖，于是 false 永远存不住）。
-- 老写法为此给每个布尔项单独写了 if 分支，改成 == nil 之后那些特例全部消失。
--
-- 说明文案的 locale key 由字段名派生：pw.cfg-<字段名，下划线换短横>，两种语言各一份。
-- group 只决定 /pw-config 里的分组显示顺序，不影响任何行为。
--
-- applies 说明【改了这个值到底什么时候、对谁生效】。这一栏不是补充说明，是必需的：
-- 有些字段改完立刻全服生效，有些只对之后新建的东西管用，改了不重开就永远看不到效果，
-- 管理员没法从字段名看出区别，试一次不生效又会以为是 bug。取值：
--   live    立刻对所有人生效（每次用到时现读，不缓存）
--   grow    立刻重算，但环只会变长不会缩短（缩小要等下次重建）
--   repaint 只影响之后新涂的砖，已经铺好的地不动
--   reset   下次那个世界重置时才套用
--   reload  重新加载脚本或执行 /pw-repair 后生效
--   new     只对之后新建的东西生效，已存在的不变
--   dead    目前完全不起作用（留着是为了不假装它能用）
M.TUNABLE_GROUPS = {'stamina', 'ring', 'lifecycle', 'world', 'ship', 'cycle', 'tech', 'misc'}

M.TUNABLES = {
    {key = 'stamina_ticks_per_point', default = 60, group = 'stamina', applies = 'live'},
    {key = 'stamina_pending_cap', default = 100000, group = 'stamina', applies = 'live'},
    {key = 'stamina_balance_cap', default = 10000000, group = 'stamina', applies = 'live'},
    {key = 'stamina_initial_multiple', default = 0, group = 'stamina', applies = 'new'},
    {key = 'ring_width', default = 32, group = 'ring', applies = 'new'},
    {key = 'ring_concrete_width', default = 16, group = 'ring', applies = 'repaint'},
    {key = 'ring_base_half_length', default = 32, group = 'ring', applies = 'repaint'},
    {key = 'ring_length_per_level', default = 16, group = 'ring', applies = 'grow'},
    {key = 'ring_length_bonus', default = 4, group = 'ring', applies = 'grow'},
    {key = 'ring_pond_half', default = 2, group = 'ring', applies = 'repaint'},
    {key = 'ring_public_hours', default = 30, group = 'lifecycle', applies = 'live'},
    {key = 'ring_delete_multiple', default = 3, group = 'lifecycle', applies = 'live'},
    {key = 'ring_min_hours', default = 3, group = 'lifecycle', applies = 'live'},
    {key = 'ring_hide_private', default = true, group = 'lifecycle', applies = 'live'},
    {key = 'ring_always_day', default = true, group = 'ring', applies = 'live'},
    {key = 'public_size', default = 2048, group = 'world', applies = 'reset'},
    {key = 'dropoff_limit', default = 8, group = 'world', applies = 'live'},
    {key = 'world_climate_swing', default = 0.35, group = 'world', applies = 'reset'},
    {key = 'world_terrain_scale', default = 0.5, group = 'world', applies = 'reset'},
    {key = 'world_reset_offset_minutes', default = 10, group = 'world', applies = 'new'},
    {key = 'ship_life_hours', default = 50, group = 'ship', applies = 'live'},
    {key = 'ship_width_per_level', default = 16, group = 'ship', applies = 'new'},
    {key = 'ship_width_bonus', default = 4, group = 'ship', applies = 'new'},
    {key = 'ship_height', default = 512, group = 'ship', applies = 'new'},
    {key = 'ship_home_planet', default = 'nauvis', group = 'ship', applies = 'new'},
    {key = 'ship_lock_native_creation', default = true, group = 'ship', applies = 'reload'},
    {key = 'cycle_minutes', default = 60, group = 'cycle', applies = 'live'},
    {key = 'auto_convert_minutes', default = 1, group = 'cycle', applies = 'live'},
    {key = 'cycle_phase_minutes', default = 5, group = 'cycle', applies = 'new'},
    {key = 'cycle_base_offset_minutes', default = 2, group = 'cycle', applies = 'new'},
    {key = 'hud_refresh_ticks', default = 3600, group = 'cycle', applies = 'live'},
    {key = 'tech_loss_k_max', default = 0.5, group = 'tech', applies = 'live'},
    {key = 'detail_hours', default = 6, group = 'misc', applies = 'live'},
    {key = 'block_blueprint_library', default = false, group = 'misc', applies = 'dead'},
    {key = 'debug', default = false, group = 'misc', applies = 'live'},
}

-- 表类型的配置项：默认值太大、结构也各不相同，仍然在 ensure_defaults 里就地定义，
-- 这里只登记「它存在、归哪一组、怎么改」，供 /pw-config 一并列出。
-- example 是一条能直接粘进控制台的示例——表字段没法像标量那样直接赋一个数字。
M.TUNABLE_TABLES = {
    {key = 'world_resource_boost', group = 'world', applies = 'reset',
     example = '/sc storage.world_resource_boost.nauvis.size = 2'},
    {key = 'world_reset_minutes', group = 'world', example = '/sc storage.world_reset_minutes.nauvis = 30', applies = 'live'},
    -- 数组，不是按星球名索引：五颗星球共用同一套提前量，没有分开配的理由。
    {key = 'world_warn_minutes', group = 'world', applies = 'live',
     example = '/sc storage.world_warn_minutes = {10, 5, 1}'},
    {key = 'quality_exp', group = 'misc', example = '/sc storage.quality_exp.legendary = 12', applies = 'live'},
    -- 整张表一次性替换，不是改某一项：起手清单是「一份礼包」，逐项增删的写法
    -- （storage.starter_items[5] = ...）要求管理员先知道当前有几项，还容易在数组中间留空洞。
    {key = 'starter_items', group = 'misc', applies = 'new',
     example = "/sc storage.starter_items = {{name='iron-plate',count=500},{name='wood',count=100}}"},
    -- applies 是 live 而不是 new：起始装备在【每次发放时】现读，
    -- 改完对下一个复活的人就生效，不用等新玩家进来。
    {key = 'starter_equipment', group = 'misc', applies = 'live',
     example = "/sc storage.starter_equipment = {{name='modular-armor',count=1},{name='solar-panel-equipment',count=6}}"},
    {key = 'ring_tiles', group = 'ring', example = '/sc storage.ring_tiles.grown = \'refined-concrete\'', applies = 'repaint'},
}

-- 戴森环的地图生成设置。
--
-- 关键点一：width 是【引擎级硬边界】，|x| >= width/2 的区块根本不生成，零成本零代码。
--   32 是精确的 1 个区块列（-16..16），每一格都被用满。
--   横向布局：中间 16 格可建带（tutorial-grid），左右各 8 格临空带，合计宽度 32。
-- 关键点二：height = 0 表示【无限】，纵向边界交给 ring.lua 手工涂 out-of-map 的墙。
--   引擎硬边界只能是矩形、而且在已存在的 surface 上能不能改大是未验证的，
--   所以纵向的可增长长度必须自己涂。
-- 关键点三：treat_missing_as_default = false 让所有未显式列出的 entity/tile/decorative
--   都不生成，比逐个把 autoplace_controls 调成 0 更彻底，也不会漏掉 mod 新增的资源。
function M.ring_map_gen(seed, ring_width)
    return {
        width = ring_width,
        height = 0,
        seed = seed,
        water = 0,
        starting_area = 1,
        peaceful_mode = true,
        no_enemies_mode = true,
        default_enable_all_autoplace_controls = false,
        cliff_settings = {cliff_elevation_interval = 0, cliff_elevation_0 = 0},
        autoplace_settings = {
            entity = {treat_missing_as_default = false, settings = {}},
            -- 这里的 tile 只是引擎生成区块那一瞬间的占位默认值，
            -- on_chunk_generated 马上就会用 ring.lua 的 paint_area 整片覆盖掉，
            -- 跟环带实际铺什么砖（查 storage.ring_tiles 那张映射表）无关，随便选一个合法固体砖即可。
            tile = {treat_missing_as_default = false, settings = {['tutorial-grid'] = {}}},
            decorative = {treat_missing_as_default = false, settings = {}},
        },
        property_expression_names = {
            elevation = '50',   -- 地形压平，环带不需要起伏
        },
    }
end

-- 保证某玩家的经验表存在且 12 个键齐全。新增瓶种时也靠它补齐。
function M.ensure_exp_table(player_name)
    storage.exp = storage.exp or {}
    local tbl = storage.exp[player_name]
    if type(tbl) ~= 'table' then
        tbl = {}
        storage.exp[player_name] = tbl
    end
    for _, key in ipairs(geometry.SCIENCE_PACKS) do
        tbl[key] = tbl[key] or 0
    end
    return tbl
end

function M.ensure_defaults()
    -- 27 个标量配置项全部由 M.TUNABLES 那张表驱动，这里不再逐行写 storage.x = storage.x or 默认值。
    -- 好处不只是短：/pw-config 指令读的是同一张表，「默认值」和「管理员看到的说明」
    -- 从此没有分头维护、各说各话的可能。
    --
    -- 判空用 == nil 而不是 or：后者对布尔 false 是错的（false 会被当成「没设过」
    -- 而被默认值覆盖，于是 false 永远存不住）。老写法为此给每个布尔项单独写了 if 分支。
    for _, item in ipairs(M.TUNABLES) do
        if storage[item.key] == nil then storage[item.key] = item.default end
    end

    -- 科技价格是 Factorio 的全局难度设置，不属于 storage。每次补默认值时顺手校准，
    -- 这样新存档、旧存档以及 game.reload_script() 热更新都会生效。
    if game.difficulty_settings.technology_price_multiplier ~= 2 then
        game.difficulty_settings.technology_price_multiplier = 2
    end

    -- 【注意】ensure_defaults 只补【缺失】的字段，绝不覆盖已有值 —— 这是它能被
    -- 每分钟无脑调一遍的前提（见 tick.lua）。想把改乱的参数推回默认值是另一件事，
    -- 走 M.reset_tunables()，那条路是显式的、要管理员打 confirm 的。

    -- ══ 体力双池（可领取池 pending 按 tick 存 + 体力池 balance 按点存） ══
    storage.stamina = storage.stamina or {}
    -- 上限直接配点数，不再按小时换算。
    -- 新玩家初始体力池 = 可领取上限（stamina_pending_cap）的多少倍。
    -- 默认 0：不白送启动体力，所有人都从"攒"开始，第一次兑换就得先等体力回满一点。
    -- 写成派生倍数而不是写死的点数，将来想开个新手礼包时调 pending_cap 也不用两处同步改。
    -- 注意 Lua 里 0 是真值，所以 `storage.x or 0` 这个写法对 0 是正确的（不会被当成"没设过"）。

    -- ══ 经验（12 种，按科技瓶短名分列） ══
    storage.exp = storage.exp or {}
    storage.exp_log = storage.exp_log or {}

    -- ══ 兑换（配额制：1 点体力最多兑一组瓶子，见 exp.lua） ══
    storage.quality_exp = storage.quality_exp or
        {normal = 1, uncommon = 3, rare = 5, epic = 7, legendary = 9}

    -- ══ 戴森环形状 ══
    if storage.ring_width == nil then storage.ring_width = 32 end
    if storage.ring_concrete_width == nil then storage.ring_concrete_width = 16 end
    if storage.ring_base_half_length == nil then storage.ring_base_half_length = 32 end
    if storage.ring_length_per_level == nil then storage.ring_length_per_level = 16 end
    if storage.ring_length_bonus == nil then storage.ring_length_bonus = 4 end

    -- ring_length_per_level 表示每级增加的总长度；bonus 取 4 时，0 级仍是 64 格长。

    -- 语义砖名 → 实际砖原型名。geometry.lua 是纯函数、不读 storage，
    -- 所以它只返回语义值，由 ring.lua 查这张表映射成真实砖名。
    -- 好处：换砖只要改这里，不用碰那个有单元测试覆盖的核心函数。
    -- start / grown 目前映射到同一种砖（都是 tutorial-grid），但语义区分依然保留——
    -- geometry.tile_at 该返回哪个语义值完全不受这里影响，以后想让升级长出来的地皮
    -- 换一种视觉效果（比如换成另一种更破旧的地砖，和初始区域区分开），只需要改这一行配置，
    -- 不用碰 geometry.lua 那个有单元测试覆盖的核心函数。
    storage.ring_tiles = storage.ring_tiles or {
        start = 'tutorial-grid',   -- 初始那一圈：格子纹路当参考线
        grown = 'tutorial-grid',   -- 升级长出来的：暂时和初始区域用同一种砖
        space = 'empty-space',     -- 左右临空带
        void  = 'out-of-map',      -- 环外的墙
        -- 环心水池。用【浅水】而不是深水：浅水的碰撞掩码里没有 player 层，角色能直接趟过去，
        -- 不会把环心切成互不相通的两半；同时它带 water_tile 层，满足海洋泵
        -- 「泵前方两格必须是水」那条放置规则。引擎自己的注释写明它 walkable but not buildable。
        water = 'water-shallow',
    }

    -- ══ 戴森环离线生命周期 ══
    -- 两个阈值都是【每次扫描现读】的，绝不缓存成到期 tick，这样改配置能立即对全体生效。
    storage.ring_state = storage.ring_state or {}                  -- [玩家名] = 'private' / 'public'
    storage.public_rings = storage.public_rings or {}              -- [surface名] = {id, name, original_owner, created, expires, half_length/ring_width...}
    storage.private_ring_by_player = storage.private_ring_by_player or {}
    storage.private_ring_owner_by_surface = storage.private_ring_owner_by_surface or {}
    -- 新人的阈值按累计在线时长缩放（见 pockets.public_threshold / delete_threshold），
    -- 缩放结果不低于这个下限——避免 online_time = 0 的全新玩家一离线就立刻公共化。

    -- ══ 新玩家的起手物资 ══
    -- 戴森环里一颗矿都没有，不给起手物资，新人连第一台熔炉都造不出来，
    -- 更别提"造个木箱当投递口出门采矿"这条主循环的第一步。
    --
    -- 做成 storage 表而不是写死在 players.lua 里，是为了让管理员能按服务器的节奏调整：
    -- 想开快节奏就多给，想开硬核就清空（storage.starter_items = {}）。
    -- 数组顺序 = 发放顺序，无所谓；名字写错的项会被 grant_starter 静默跳过
    -- （用 prototypes.item 现查），不会因为一个错别字就让新玩家进不来。
    storage.starter_items = storage.starter_items or {
        {name = 'iron-plate', count = 500},
        {name = 'copper-plate', count = 200},
        {name = 'stone', count = 100},
        {name = 'wood', count = 100},
    }

    -- ══ 新玩家的起始装备 ══
    -- 和起手物资分开的原因：这两样的【发放时机】完全不同。
    -- 起手物资只在"从零开始"时发（新玩家、环被回收后重建）；
    -- 起始装备还会在【复活】时按冷却重发，是死亡之后的兜底补给。
    --
    -- 【顺序有意义】：带 equipment_grid 的装甲要排在前面，
    -- grant_equipment 先把第一件这样的装甲穿上，再把后面的模块插进它的装备栏。
    -- 反过来写的话，插模块时装备栏还不存在，模块会全部退回背包。
    --
    -- 【清单里可以混进普通物品，不必都是装备】：construction-robot 不在
    -- prototypes.equipment 里，equip_or_insert 的那道判据认得出来，会直接塞进背包。
    -- 这正是个人机器人指令模块要的：它从【背包】里取建造机器人放飞，
    -- 只给模块不给机器人的话，指令模块装上了也一动不动。
    storage.starter_equipment = storage.starter_equipment or {
        {name = 'modular-armor', count = 1},
        {name = 'personal-roboport-equipment', count = 1},
        {name = 'solar-panel-equipment', count = 6},
        {name = 'construction-robot', count = 10},
    }
    -- ══ 公共世界 ══
    -- 每星球各自的重置周期（分钟）。周期长短即难度分层：
    -- nauvis 两小时一轮，是新人的练兵场；aquilo 七小时一轮，值得长线经营。
    -- 除 nauvis 外四颗星球是 3/4/5/7 小时，彼此互质；每次重置后固定关闭两小时。
    -- 【按名字索引，不按下标】——constants.PUBLIC_PLANETS 的顺序是
    -- {nauvis, vulcanus, gleba, fulgora, aquilo}，和这张表里 fulgora/gleba 的排列顺序不同，
    -- 谁按下标去取谁就会把这两个星球的周期错配。
    --
    -- 【五个值必须全是 60 的整数倍】。错峰排期的「永不撞车」是纯算术保证的，
    -- 证明的前提正是这一条（见 worlds.schedule_all 的注释）：周期是 60 的倍数，
    -- 每个星球的重置时刻对 60 取余就恒等于它的首次偏移（0/10/20/30/40 分），
    -- 五个余数两两不同，于是永远不可能有两个星球在同一分钟重置。
    -- 改成 90 或 150 这种非整倍数会让相位随时间漂移，某天开始两颗星球同时清空。
    local world_reset_defaults = {
        nauvis = 120, vulcanus = 180, fulgora = 240, gleba = 300, aquilo = 420,
    }
    if type(storage.world_reset_minutes) ~= 'table' then
        storage.world_reset_minutes = {}
    end
    for name, minutes in pairs(world_reset_defaults) do
        if storage.world_reset_minutes[name] == nil then storage.world_reset_minutes[name] = minutes end
    end
    -- 公共世界的矿脉倍率。boost_resources 会在 reset_to_prototype 之后乘到原型值上，
    -- 所以如果某颗星球自己的原型或其它脚本先带了随机扰动，这里会基于扰动后的值继续缩放。
    storage.world_resource_boost = storage.world_resource_boost or {
        default = {
            size = 2,
            frequency = 1,
            richness = 1,      -- 所有星球单格矿量是原型的 1
        },
        nauvis = {
            size = 4,               -- Nauvis 矿脉面积是原型的 4 倍
            frequency = 2,          -- Nauvis 矿脉频率是原型的 2 倍
            richness = 1 / 8,
        },
    }
    -- 相邻星球的首次排期错开这么多分钟，避免两个世界同时重置。
    storage.world_reset_at = storage.world_reset_at or {}
    storage.world_run = storage.world_run or {}
    -- 开放阶段持续各星球自己的配置周期；切换为关闭时重置一次，关闭两小时后
    -- 再重置并开放。
    storage.world_travel_open = storage.world_travel_open or {}
    for _, name in ipairs(M.PUBLIC_PLANETS) do
        if name ~= 'nauvis' and storage.world_travel_open[name] == nil then
            storage.world_travel_open[name] = true
        end
    end
    -- 重置前多久提醒还站在星球上的人（分钟）。
    storage.world_warn_minutes = storage.world_warn_minutes or {5, 1}
    -- [星球名][分钟档] = true，记哪一档已经播过，reset_world 时整条清掉。
    storage.world_warned = storage.world_warned or {}

    -- ══ 飞船（太空平台） ══
    -- 全服公有、每人最多一艘、以主人的名字命名、寿命有限。
    -- 定位是「比星球活得久、比戴森环短命」的中间层：适合放这一轮要用的东西，
    -- 不适合当仓库，想留下的产出还是得靠关联箱送回环里。
    --
    -- 登记表【按平台 index 做主键】，主人只是它的一个属性（可以是 nil）：
    -- 玩家仍然可以从火箭井原生造平台，那种船脚本没参与创建、不知道是谁的，
    -- 按玩家名做主键的话它在表里根本没有位置可放。详见 scripts/ships.lua 顶部注释。
    storage.ships = storage.ships or {}                      -- [平台index] = {owner=玩家名或nil, created=登记tick, built=成形tick或nil, scuttled=删除发起tick或nil}
    storage.player_cleanup = storage.player_cleanup or {}     -- [玩家index] = {index=玩家index, name=玩家名, queued=登记tick, due=最早移除tick}
    -- 禁用原生的太空平台按钮，让 UI 成为建船的唯一入口。
    -- 这是归属制成立的前提：船必须都从 ships.create 出生，才谈得上"这是谁的船"。
    -- UI 按钮会直接应用起步包，让飞船当场成形；原生建船仍锁住，避免出现无主船。
    -- 设成 false 就恢复原版行为（那样会重新出现无主飞船，见 scripts/ships.lua）。

    -- ══ 相位调度器（大类周期任务：科技丢失、戴森环生命周期……） ══
    -- 用「显式相位」代替 v1 互质质数取模：周期和错开程度两个旋钮独立可调，
    -- 详细设计见 scripts/tick.lua 顶部注释。
        -- 周期任务的基础偏移。星球重置占用 mod 60 的 0/10/20/30/40 分，
        -- 加 2 分钟偏移后周期任务落在 2/7/12 分，和它们全都错开。
    storage.cycle_next_at = storage.cycle_next_at or {}             -- [任务key] = 下次触发的 tick
    -- 调度器轮询间隔（tick）。此值仅供文档和管理员参考——script.on_nth_tick 的参数
    -- 在控制阶段加载时就要确定，此时 storage 尚不可用，故实际使用的是字面量 3600（1 分钟），
    -- 修改此字段对轮询频率无影响。
    storage.scheduler_interval_ticks = storage.scheduler_interval_ticks or 3600

    -- ══ 科技丢失：P = k × 该科技的瓶子种数 / 100 ══

    -- ══ 权限：默认【不禁用任何东西】，包括蓝图库 ══
    -- v1 禁蓝图的理由（重置后 Ctrl+V 一秒恢复布局）在本版已不成立：
    -- 重置的是公共世界，而玩家的产线在戴森环里，本来就不会被重置。

    -- ══ 分级披露 ══
    -- 累计在线满这么多小时，才在 GUI 上多看到那些"能优化但不影响上手"的详细数字
    -- （比如戴森环精确长度、经验贡献分项、其他玩家的戴森环列表）。见 scripts/util.lua 的 is_veteran。

    -- ══ 调试 ══
end

-- 把【所有可调参数】推回默认值。/pw-reset-config 的实现。
--
-- 做法是「先全部清空，再走一遍 ensure_defaults」，而不是逐项赋默认值：
-- 标量的默认值在 M.TUNABLES 里，表的默认值写在 ensure_defaults 函数体内
-- （结构各不相同、体积也大，登记进 TUNABLES 反而更难读）。
-- 清空之后 ensure_defaults 的 `== nil` 和 `or {...}` 两套写法会把两类一起补齐，
-- 「默认值长什么样」始终只有一处定义，不会出现「重置出来的值和新开档不一样」。
--
-- 【只碰配置，绝不碰进度】：清空名单严格取自 TUNABLES / TUNABLE_TABLES 两张表，
-- 玩家经验、体力、环状态、飞船登记、排期这些运行时字段不在名单里，一个都不会动。
-- 加新配置项时记得登记进那两张表 —— 没登记的项在这里不会被重置，
-- 在 /pw-config 里也不会显示，两个症状会一起出现，比只坏一个容易发现。
function M.reset_tunables()
    local n = 0
    for _, item in ipairs(M.TUNABLES) do
        storage[item.key] = nil
        n = n + 1
    end
    for _, item in ipairs(M.TUNABLE_TABLES) do
        storage[item.key] = nil
        n = n + 1
    end
    M.ensure_defaults()
    return n
end

-- 有几个标量参数当前值和默认值不同 —— 给 /pw-reset-config 的预览用，
-- 让管理员在打 confirm 之前知道「这一下会改掉多少东西」。
-- 表类型不比较：深比较要写一套递归、还要处理数组顺序，而它给出的信息
-- （"starter_items 被人动过"）并不值这个复杂度。
-- 可调参数总数（标量 + 表）。/pw-reset-config 的预览用。
function M.tunable_count()
    return #M.TUNABLES + #M.TUNABLE_TABLES
end

function M.diverged_count()
    local n = 0
    for _, item in ipairs(M.TUNABLES) do
        if storage[item.key] ~= item.default then n = n + 1 end
    end
    return n
end

return M
