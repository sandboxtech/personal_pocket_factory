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

-- ══ 环心布局：12 个收货箱的两列，以及玩家进环的落点 ══
--
-- 【这三个值必须放在一起看，也必须一起改】：落点绝不能落在箱阵占的格子上，
-- 否则玩家一进环就被挤到不知道哪儿去。它们原先散在 chests / pockets / gui.overview
-- 三个文件的四处字面量里，改箱阵坐标时极容易漏掉出生点那一处。
--
-- 两列各 6 个，中间特意留出 6 格空地（tile x 从 -3 到 2）：
-- 箱阵是【12 个并行存取口】而不是 12 倍容量（同 link_id 共享一份库存），
-- 中间那片空地就是留给机械臂和传送带把货接出去的地方，贴在一起反而没处下手。
M.CHEST_COLUMNS = {-4, 3}      -- 两列各自占的 tile x
M.CHEST_ROW_FROM = -3          -- 每列 6 个，tile y 从这里
M.CHEST_ROW_TO = 2             -- 到这里（闭区间）
-- 落点就在【环心】。两列外移之后中间那 6 格是空的，原点正落在其中，
-- 玩家一进环站在箱阵正当中，左右各三格就是收货口，视野和动线都最短。
-- （外移之前原点被箱子占着，落点只能挪到箱阵外侧去。）
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
--   grow    立刻重算，但环只会变宽不会变窄（缩小要等下次重建）
--   repaint 只影响之后新涂的砖，已经铺好的地不动
--   reset   下次那个世界重置时才套用
--   new     只对之后新建的东西生效，已存在的不变
--   dead    目前完全不起作用（留着是为了不假装它能用）
M.TUNABLE_GROUPS = {'stamina', 'ring', 'lifecycle', 'world', 'ship', 'cycle', 'tech', 'misc'}

M.TUNABLES = {
    {key = 'stamina_ticks_per_point', default = 60, group = 'stamina', applies = 'live'},
    {key = 'stamina_pending_cap', default = 100000, group = 'stamina', applies = 'live'},
    {key = 'stamina_balance_cap', default = 10000000, group = 'stamina', applies = 'live'},
    {key = 'stamina_initial_multiple', default = 0, group = 'stamina', applies = 'new'},
    {key = 'ring_height', default = 128, group = 'ring', applies = 'new'},
    {key = 'ring_concrete_height', default = 64, group = 'ring', applies = 'repaint'},
    {key = 'ring_base_half_width', default = 32, group = 'ring', applies = 'repaint'},
    {key = 'ring_per_level', default = 16, group = 'ring', applies = 'grow'},
    {key = 'ring_level_bonus', default = 2, group = 'ring', applies = 'grow'},
    {key = 'ring_pond_half', default = 3, group = 'ring', applies = 'repaint'},
    {key = 'ring_public_hours', default = 30, group = 'lifecycle', applies = 'live'},
    {key = 'ring_delete_hours', default = 50, group = 'lifecycle', applies = 'live'},
    {key = 'ring_min_hours', default = 1, group = 'lifecycle', applies = 'live'},
    {key = 'public_size', default = 2048, group = 'world', applies = 'reset'},
    {key = 'world_reset_offset_minutes', default = 10, group = 'world', applies = 'new'},
    {key = 'ship_life_hours', default = 50, group = 'ship', applies = 'live'},
    {key = 'ship_width_per_level', default = 16, group = 'ship', applies = 'new'},
    {key = 'ship_width_bonus', default = 4, group = 'ship', applies = 'new'},
    {key = 'ship_height', default = 512, group = 'ship', applies = 'new'},
    {key = 'ship_home_planet', default = 'nauvis', group = 'ship', applies = 'new'},
    {key = 'ship_lock_native_creation', default = true, group = 'ship', applies = 'live'},
    {key = 'cycle_minutes', default = 60, group = 'cycle', applies = 'live'},
    {key = 'cycle_phase_minutes', default = 5, group = 'cycle', applies = 'new'},
    {key = 'cycle_base_offset_minutes', default = 2, group = 'cycle', applies = 'new'},
    {key = 'hud_refresh_ticks', default = 3600, group = 'cycle', applies = 'live'},
    {key = 'tech_loss_k', default = 1, group = 'tech', applies = 'live'},
    {key = 'detail_hours', default = 6, group = 'misc', applies = 'live'},
    {key = 'block_blueprint_library', default = false, group = 'misc', applies = 'dead'},
    {key = 'debug', default = false, group = 'misc', applies = 'live'},
}

-- 表类型的配置项：默认值太大、结构也各不相同，仍然在 ensure_defaults 里就地定义，
-- 这里只登记「它存在、归哪一组、怎么改」，供 /pw-config 一并列出。
-- example 是一条能直接粘进控制台的示例——表字段没法像标量那样直接赋一个数字。
M.TUNABLE_TABLES = {
    {key = 'world_resource_boost', group = 'world', applies = 'reset',
     example = '/sc storage.world_resource_boost.size = 6'},
    {key = 'world_reset_minutes', group = 'world', example = '/sc storage.world_reset_minutes.nauvis = 30', applies = 'live'},
    {key = 'quality_exp', group = 'misc', example = '/sc storage.quality_exp.legendary = 12', applies = 'live'},
    {key = 'ring_tiles', group = 'ring', example = '/sc storage.ring_tiles.grown = \'refined-concrete\'', applies = 'repaint'},
    {key = 'world_patch_tiles', group = 'world', applies = 'reset',
     example = '/sc storage.world_patch_tiles.nauvis = {\'grass-1\',\'sand-1\'}'},
}

-- 戴森环的地图生成设置。
--
-- 关键点一：height 是【引擎级硬边界】，|y| >= height/2 的区块根本不生成，零成本零代码。
--   128 是精确的 4 个区块行（-64..-32 / -32..0 / 0..32 / 32..64），每行都被用满。
--   取 96 的话占用区块数一模一样，却有一半空间被 out-of-map 浪费掉。
-- 关键点二：width = 0 表示【无限】，横向边界交给 ring.lua 手工涂 out-of-map 的墙。
--   引擎硬边界只能是矩形、而且在已存在的 surface 上能不能改大是未验证的，
--   所以横向的可增长边界必须自己涂。
-- 关键点三：treat_missing_as_default = false 让所有未显式列出的 entity/tile/decorative
--   都不生成，比逐个把 autoplace_controls 调成 0 更彻底，也不会漏掉 mod 新增的资源。
function M.ring_map_gen(seed, ring_height)
    return {
        width = 0,
        height = ring_height,
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
    -- 等级的【起征点】。等级是 12 项经验的十进制位数之和，集齐 12 种（各至少 1 点）就是 12 级；
    -- 取 10 让那一刻的半宽正好等于下限 ring_base_half_width，即「集齐 12 种」才是起跑线。
    -- 换句话说宽 = 32 × (等级 − 10)，下限 64。这组数字是为了让改用位数计级之后
    -- 实际环宽和之前逐点相同，推导见 scripts/geometry.lua 的 half_width。

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
        space = 'empty-space',     -- 上下临空带
        void  = 'out-of-map',      -- 环外的墙
        -- 环心水池。用【浅水】而不是深水：浅水的碰撞掩码里没有 player 层，角色能直接趟过去，
        -- 不会把环心切成互不相通的两半；同时它带 water_tile 层，满足海洋泵
        -- 「泵前方两格必须是水」那条放置规则。引擎自己的注释写明它 walkable but not buildable。
        water = 'water-shallow',
    }

    -- ══ 戴森环离线生命周期 ══
    -- 两个阈值都是【每次扫描现读】的，绝不缓存成到期 tick，这样改配置能立即对全体生效。
    storage.ring_state = storage.ring_state or {}                  -- [玩家名] = 'private' / 'public'
    -- 新人的阈值按累计在线时长缩放（见 pockets.public_threshold / delete_threshold），
    -- 缩放结果不低于这个下限——避免 online_time = 0 的全新玩家一离线就立刻公共化。

    -- ══ 公共世界 ══
    -- 每星球各自的重置周期（分钟）。周期长短即难度分层：
    -- nauvis 一小时一轮，是新人的练兵场；aquilo 五小时一轮，值得长线经营。
    -- 【按名字索引，不按下标】——constants.PUBLIC_PLANETS 的顺序是
    -- {nauvis, vulcanus, gleba, fulgora, aquilo}，和这张表里 fulgora/gleba 的排列顺序不同，
    -- 谁按下标去取谁就会把这两个星球的周期错配。
    storage.world_reset_minutes = storage.world_reset_minutes or {
        nauvis = 60, vulcanus = 120, fulgora = 180, gleba = 240, aquilo = 300,
    }
    -- 公共世界的矿脉尺寸倍率。这些星球一两小时就清空一次，原版尺寸是按「一局几十小时」
    -- 调的，直接用会让建设时间吃掉整轮的大半。数值是 MapGenSize：1 = 原版，2 = 大，
    -- 4 = 非常大，6 = 界面上的最大档。见 worlds.boost_resources，按 category 覆盖全部矿种。
    storage.world_resource_boost = storage.world_resource_boost or {
        size = 6,        -- 矿脉铺开的面积，主要影响「一片矿能撑多久」
        frequency = 2,   -- 矿脉出现的密度，影响「走多远能碰到下一片」
        richness = 4,    -- 单格矿量，影响「同样面积能挖出多少」
    }

    -- 相邻星球的首次排期错开这么多分钟，避免两个世界同时重置。
    storage.world_reset_at = storage.world_reset_at or {}
    storage.world_run = storage.world_run or {}

    -- ══ 公共世界地貌斑块 ══
    -- 每个星球一组「可用于斑块替换」的原生地块名，供 scripts/world_terrain.lua 在
    -- on_chunk_generated 时用噪声在同组砖之间重新分布，让每轮重置后的地貌看起来不一样
    -- （这轮草多沙少、下轮反过来），而不是无中生有地造出原版没有的新地貌。
    --
    -- 选取原则（严格核实过，见 task-31-report.md 逐条对照）：
    --   1. 必须是该星球【原生】的地块原型名（本机 data/base 或 data/space-age 的
    --      prototypes/tile 下真实存在，逐个用 grep 核对过 collision_mask）。
    --   2. 只挑 collision_mask = tile_collision_masks.ground() 的普通地面砖——
    --      不挑水/熔岩/氨海之类（ground() 之外的 mask，走进去要么淹死要么烧死）、
    --      不挑人造建筑砖（比如 Fulgora 的 fulgoran-paving/walls/conduit/machinery，
    --      那是废墟遗迹的一部分，混进"自然斑块"里会很违和）。
    --   3. 每星球至少两种，斑块替换才有意义；核实不到足够安全砖名的星球留空表，
    --      world_terrain.lua 会跳过（不瞎猜砖名，写错会在 set_tiles 时报错炸服）。
    storage.world_patch_tiles = storage.world_patch_tiles or {
        -- Nauvis：草/泥/沙/红土，data/base/prototypes/tile/tiles.lua 第 1229~1855 行。
        nauvis = {
            'grass-1', 'grass-2', 'grass-3', 'grass-4',
            'dirt-1', 'dirt-2', 'dirt-3', 'dirt-4', 'dirt-5', 'dirt-6', 'dirt-7', 'dry-dirt',
            'sand-1', 'sand-2', 'sand-3',
            'red-desert-0', 'red-desert-1', 'red-desert-2', 'red-desert-3',
        },
        -- Vulcanus：火山灰/岩/褶皱地表，data/space-age/prototypes/tile/tiles-vulcanus.lua。
        -- 明确排除 lava / lava-hot / lava-2（collision_mask = lava()，走进去会死）。
        vulcanus = {
            'volcanic-ash-light', 'volcanic-ash-dark', 'volcanic-ash-flats',
            'volcanic-pumice-stones', 'volcanic-smooth-stone', 'volcanic-smooth-stone-warm',
            'volcanic-ash-cracks', 'volcanic-folds-flat', 'volcanic-folds', 'volcanic-folds-warm',
            'volcanic-soil-dark', 'volcanic-soil-light', 'volcanic-ash-soil',
            'volcanic-jagged-ground', 'volcanic-cracks-hot', 'volcanic-cracks-warm', 'volcanic-cracks',
        },
        -- Fulgora：废土沙尘/丘/岩，data/space-age/prototypes/tile/tiles-fulgora.lua 第 185~330 行。
        -- 明确排除 fulgoran-paving/walls/conduit/machinery（人造遗迹砖，不是自然地貌）
        -- 和 oil-ocean-shallow/deep（油海，collision_mask 是水系）。
        fulgora = {
            'fulgoran-dust', 'fulgoran-dunes', 'fulgoran-sand', 'fulgoran-rock',
        },
        -- Gleba：自然有机土 + 高地岩石，data/space-age/prototypes/tile/tiles-gleba.lua。
        -- 明确排除 wetland-*/gleba-deep-lake（collision_mask 是水系）、
        -- artificial-*-soil/overgrowth-*-soil（那是"农田"语义，不是原生荒野地貌）、
        -- lowland-*（layer_group = water-overlay，和湿地水面渲染强耦合，脱离水面语境替换会有视觉瑕疵）。
        gleba = {
            'natural-yumako-soil', 'natural-jellynut-soil',
            'highland-dark-rock', 'highland-dark-rock-2', 'highland-yellow-rock', 'pit-rock',
        },
        -- Aquilo：雪原/冻土，data/space-age/prototypes/tile/tiles-aquilo.lua 第 252~479 行。
        -- 明确排除 ice-rough/ice-smooth/ice-platform（collision_mask = meltable_tile，会融化改变碰撞）
        -- 和 brash-ice/ammoniacal-ocean（水系）。
        aquilo = {
            'snow-flat', 'snow-crests', 'snow-lumpy', 'snow-patchy',
            'dust-flat', 'dust-crests', 'dust-lumpy', 'dust-patchy',
        },
    }

    -- ══ 飞船（太空平台） ══
    -- 全服公有、每人最多一艘、以主人的名字命名、寿命有限。
    -- 定位是「比星球活得久、比戴森环短命」的中间层：适合放这一轮要用的东西，
    -- 不适合当仓库，想留下的产出还是得靠关联箱送回环里。
    --
    -- 登记表【按平台 index 做主键】，主人只是它的一个属性（可以是 nil）：
    -- 玩家仍然可以从火箭井原生造平台，那种船脚本没参与创建、不知道是谁的，
    -- 按玩家名做主键的话它在表里根本没有位置可放。详见 scripts/ships.lua 顶部注释。
    storage.ships = storage.ships or {}                      -- [平台index] = {owner=玩家名或nil, created=创建tick}
    -- 禁用原生的太空平台按钮，让 UI 成为建船的唯一入口。
    -- 这是归属制成立的前提：船必须都从 ships.create 出生，才谈得上"这是谁的船"。
    -- 起步包仍然要用火箭发上去，门槛一点没降 —— 换掉的只是"谁来按下创建"这一步。
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
    -- （比如戴森环精确宽度、经验贡献分项、其他玩家的戴森环列表）。见 scripts/util.lua 的 is_veteran。

    -- ══ 调试 ══
end

return M
