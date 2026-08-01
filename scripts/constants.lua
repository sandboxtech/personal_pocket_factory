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
    -- ══ 体力双池（可领取池 pending 按 tick 存 + 体力池 balance 按点存） ══
    storage.stamina = storage.stamina or {}
    storage.stamina_ticks_per_point = storage.stamina_ticks_per_point or 60     -- 每点体力 = 1 秒
    -- 上限直接配点数，不再按小时换算。
    storage.stamina_pending_cap = storage.stamina_pending_cap or 100000       -- 可领取池上限（点）
    storage.stamina_balance_cap = storage.stamina_balance_cap or 10000000     -- 体力池上限（点）
    -- 新玩家初始体力池 = 可领取上限（stamina_pending_cap）的多少倍。
    -- 默认 0：不白送启动体力，所有人都从"攒"开始，第一次兑换就得先等体力回满一点。
    -- 写成派生倍数而不是写死的点数，将来想开个新手礼包时调 pending_cap 也不用两处同步改。
    -- 注意 Lua 里 0 是真值，所以 `storage.x or 0` 这个写法对 0 是正确的（不会被当成"没设过"）。
    storage.stamina_initial_multiple = storage.stamina_initial_multiple or 0

    -- ══ 经验（12 种，按科技瓶短名分列） ══
    storage.exp = storage.exp or {}
    storage.exp_log = storage.exp_log or {}

    -- ══ 兑换（配额制：1 点体力最多兑一组瓶子，见 exp.lua） ══
    storage.quality_exp = storage.quality_exp or
        {normal = 1, uncommon = 3, rare = 5, epic = 7, legendary = 9}

    -- ══ 戴森环形状 ══
    storage.ring_height = storage.ring_height or 128               -- 环带总高，同时是 map_gen 的 height
    storage.ring_concrete_height = storage.ring_concrete_height or 64  -- 中间可建带，其余均分给上下的临空带
    storage.ring_base_half_width = storage.ring_base_half_width or 32  -- L=0 时的半宽
    storage.ring_per_level = storage.ring_per_level or 16          -- 每升一级两侧各外推多少 tile

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
    }

    -- ══ 戴森环离线生命周期 ══
    -- 两个阈值都是【每次扫描现读】的，绝不缓存成到期 tick，这样改配置能立即对全体生效。
    storage.ring_state = storage.ring_state or {}                  -- [玩家名] = 'private' / 'public'
    storage.ring_public_hours = storage.ring_public_hours or 30    -- 离线多久后变公共（老玩家的固定上限）
    storage.ring_delete_hours = storage.ring_delete_hours or 50    -- 离线多久后删表面（老玩家的固定上限）
    -- 新人的阈值按累计在线时长缩放（见 pockets.public_threshold / delete_threshold），
    -- 缩放结果不低于这个下限——避免 online_time = 0 的全新玩家一离线就立刻公共化。
    storage.ring_min_hours = storage.ring_min_hours or 1

    -- ══ 公共世界 ══
    storage.public_size = storage.public_size or 2048
    -- 每星球各自的重置周期（分钟）。周期长短即难度分层：
    -- nauvis 一小时一轮，是新人的练兵场；aquilo 五小时一轮，值得长线经营。
    -- 【按名字索引，不按下标】——constants.PUBLIC_PLANETS 的顺序是
    -- {nauvis, vulcanus, gleba, fulgora, aquilo}，和这张表里 fulgora/gleba 的排列顺序不同，
    -- 谁按下标去取谁就会把这两个星球的周期错配。
    storage.world_reset_minutes = storage.world_reset_minutes or {
        nauvis = 60, vulcanus = 120, fulgora = 180, gleba = 240, aquilo = 300,
    }
    -- 相邻星球的首次排期错开这么多分钟，避免两个世界同时重置。
    storage.world_reset_offset_minutes = storage.world_reset_offset_minutes or 10
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
    storage.ship_life_hours = storage.ship_life_hours or 50  -- 寿命（小时），到点先撤人再销毁
    storage.ship_width = storage.ship_width or 256           -- 引擎级硬边界，和戴森环同一个思路
    storage.ship_height = storage.ship_height or 512
    storage.ship_home_planet = storage.ship_home_planet or 'nauvis'   -- 默认环绕哪颗星球
    -- 禁用原生的太空平台按钮，让 UI 成为建船的唯一入口。
    -- 这是归属制成立的前提：船必须都从 ships.create 出生，才谈得上"这是谁的船"。
    -- 起步包仍然要用火箭发上去，门槛一点没降 —— 换掉的只是"谁来按下创建"这一步。
    -- 设成 false 就恢复原版行为（那样会重新出现无主飞船，见 scripts/ships.lua）。
    if storage.ship_lock_native_creation == nil then
        storage.ship_lock_native_creation = true
    end

    -- ══ 相位调度器（大类周期任务：科技丢失、戴森环生命周期……） ══
    -- 用「显式相位」代替 v1 互质质数取模：周期和错开程度两个旋钮独立可调，
    -- 详细设计见 scripts/tick.lua 顶部注释。
    storage.cycle_minutes = storage.cycle_minutes or 60             -- 每大类任务的周期
    storage.cycle_phase_minutes = storage.cycle_phase_minutes or 5  -- 各类之间的相位间隔
    storage.cycle_base_offset_minutes = storage.cycle_base_offset_minutes or 2
        -- 周期任务的基础偏移。星球重置占用 mod 60 的 0/10/20/30/40 分，
        -- 加 2 分钟偏移后周期任务落在 2/7/12 分，和它们全都错开。
    storage.cycle_next_at = storage.cycle_next_at or {}             -- [任务key] = 下次触发的 tick
    -- 调度器轮询间隔（tick）。此值仅供文档和管理员参考——script.on_nth_tick 的参数
    -- 在控制阶段加载时就要确定，此时 storage 尚不可用，故实际使用的是字面量 3600（1 分钟），
    -- 修改此字段对轮询频率无影响。
    storage.scheduler_interval_ticks = storage.scheduler_interval_ticks or 3600
    storage.hud_refresh_ticks = storage.hud_refresh_ticks or 3600   -- HUD 刷新间隔（tick）

    -- ══ 科技丢失：P = k × 该科技的瓶子种数 / 100 ══
    storage.tech_loss_k = storage.tech_loss_k or 1

    -- ══ 权限：默认【不禁用任何东西】，包括蓝图库 ══
    -- v1 禁蓝图的理由（重置后 Ctrl+V 一秒恢复布局）在本版已不成立：
    -- 重置的是公共世界，而玩家的产线在戴森环里，本来就不会被重置。
    if storage.block_blueprint_library == nil then
        storage.block_blueprint_library = false
    end

    -- ══ 分级披露 ══
    -- 累计在线满这么多小时，才在 GUI 上多看到那些"能优化但不影响上手"的详细数字
    -- （比如戴森环精确宽度、经验贡献分项、其他玩家的戴森环列表）。见 scripts/util.lua 的 is_veteran。
    storage.detail_hours = storage.detail_hours or 6

    -- ══ 调试 ══
    storage.debug = storage.debug or false
end

return M
