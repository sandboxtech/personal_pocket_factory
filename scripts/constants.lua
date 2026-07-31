-- 全局常量 + storage 默认值的【唯一出生地】。
-- ensure_defaults() 在 on_init / on_configuration_changed / 每次世界重置时都会调用，幂等、不覆盖已调过的值。
-- 各模块使用点只保留 nil 兜底（老存档继承时 storage 字段可能还没补上，直接索引会崩）。
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

-- 口袋世界的表面名前缀。surface 名不能带特殊字符，玩家名直接拼在后面。
M.POCKET_PREFIX = 'pocket_'

-- 公共库存的 link_id。player.index 从 1 开始，所以 0 永不碰撞。
-- 全服只有一个公共库存：所有弃厂的产出汇进同一个池子。
M.PUBLIC_LINK_ID = 0

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

-- 把 v1 的 storage.exp[玩家名]（一个 number）迁移成 12 键 table。
-- 老经验整个折算进 automation 一项 —— 那时候经验不分种类，归给第一种最不容易引起争议。
-- 幂等：已经是 table 的不动。
local function migrate_exp()
    storage.exp = storage.exp or {}
    for name, value in pairs(storage.exp) do
        if type(value) == 'number' then
            local fresh = {}
            for _, key in ipairs(geometry.SCIENCE_PACKS) do fresh[key] = 0 end
            fresh.automation = value
            storage.exp[name] = fresh
        end
    end
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
    storage.stamina_ticks_per_point = storage.stamina_ticks_per_point or 3600   -- 每点体力 = 1 分钟
    storage.stamina_pending_cap_hours = storage.stamina_pending_cap_hours or 30    -- 可领取池上限 30 小时
    storage.stamina_balance_cap_hours = storage.stamina_balance_cap_hours or 3000  -- 体力池上限 3000 小时
    storage.stamina_initial = storage.stamina_initial or 10000                     -- 新玩家初始体力池

    -- ══ 经验（12 种，按科技瓶短名分列） ══
    storage.exp = storage.exp or {}
    storage.exp_log = storage.exp_log or {}
    migrate_exp()                                                  -- v1 的 number 转 table

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
    storage.ring_public_hours = storage.ring_public_hours or 30    -- 离线多久后变公共
    storage.ring_delete_hours = storage.ring_delete_hours or 50    -- 离线多久后删表面

    -- ══ 公共世界 ══
    storage.public_size = storage.public_size or 2048
    storage.world_reset_minutes = storage.world_reset_minutes or 120
    storage.world_reset_at = storage.world_reset_at or {}
    storage.world_run = storage.world_run or {}

    -- ══ 科技丢失：P = k × 该科技的瓶子种数 / 100 ══
    storage.tech_loss_k = storage.tech_loss_k or 1

    -- ══ 权限：默认【不禁用任何东西】，包括蓝图库 ══
    -- v1 禁蓝图的理由（重置后 Ctrl+V 一秒恢复布局）在本版已不成立：
    -- 重置的是公共世界，而玩家的产线在戴森环里，本来就不会被重置。
    if storage.block_blueprint_library == nil then
        storage.block_blueprint_library = false
    end

    -- ══ 调试 ══
    storage.debug = storage.debug or false
end

return M
