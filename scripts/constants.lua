-- 全局常量 + storage 默认值的【唯一出生地】。
-- ensure_defaults() 在 on_init / on_configuration_changed / 每次世界重置时都会调用，幂等、不覆盖已调过的值。
-- 各模块使用点只保留 nil 兜底（老存档继承时 storage 字段可能还没补上，直接索引会崩）。
local M = {}

M.sec_to_tick = 60
M.min_to_tick = 60 * 60
M.hour_to_tick = 60 * 60 * 60

-- 品质 → 经验倍率。兑换时物品价值乘以这个系数，高品质物资更值钱。
M.quality_exp = {
    normal = 1,
    uncommon = 2,
    rare = 3,
    epic = 4,
    legendary = 5,
}

-- 公共世界：本场景只用太空时代的五个真星球。
-- 用真星球（而不是 game.create_surface 造裸 surface）是为了拿到星球原型级机制：
-- Fulgora 闪电、Aquilo 冻结、Vulcanus 巨虫领地、各自的 autoplace 与表面属性基准。
-- 裸 surface 只能靠 set_property 调那几个表面属性，这些机制一个都拿不到。
M.PUBLIC_PLANETS = {'nauvis', 'vulcanus', 'gleba', 'fulgora', 'aquilo'}

-- 口袋世界的表面名前缀。surface 名不能带特殊字符，玩家名直接拼在后面。
M.POCKET_PREFIX = 'pocket_'

-- 口袋世界的地图生成设置：没有任何资源、没有敌人、有限大小。
-- 关键点在 autoplace_settings 的 treat_missing_as_default = false：
-- 它让所有【未显式列出】的 entity/tile/decorative 都不生成，比逐个把 autoplace_controls 调成 0 更彻底。
-- width/height 是引擎级硬边界（MapGenSettings 字段，单位 tile，0 表示无限），
-- 边界外是 out-of-map，引擎根本不生成区块，存档体积天然受控，不需要自己铺虚空。
function M.pocket_map_gen(size, seed)
    return {
        width = size,
        height = size,
        seed = seed,
        water = 0,
        starting_area = 1,
        peaceful_mode = true,
        no_enemies_mode = true,
        default_enable_all_autoplace_controls = false,
        cliff_settings = {cliff_elevation_interval = 0, cliff_elevation_0 = 0},
        autoplace_settings = {
            entity = {treat_missing_as_default = false, settings = {}},
            tile = {treat_missing_as_default = false, settings = {['grass-1'] = {}}},
            decorative = {treat_missing_as_default = false, settings = {}},
        },
        property_expression_names = {
            -- 地形整体压平：口袋世界不需要地形起伏，平地最好摆产线。
            elevation = '50',
        },
    }
end

function M.ensure_defaults()
    -- ══ 体力（沿用 endfield 的星星机制：随时间恢复、离线也攒、可花费） ══
    storage.stamina = storage.stamina or {}                        -- [玩家名] = {amount=当前体力, last=上次结算tick}
    storage.stamina_per_hour = storage.stamina_per_hour or 60      -- 每小时恢复多少点（60 = 1分钟1点）
    storage.stamina_cap = storage.stamina_cap or 1440              -- 体力上限（1440 = 攒满24小时就不再涨）

    -- ══ 经验 ══
    storage.exp = storage.exp or {}                                -- [玩家名] = 累计经验（整数）。等级 = floor(sqrt(exp))
    storage.exp_log = storage.exp_log or {}                        -- [玩家名] = 最近一次兑换的明细，供 GUI 回显

    -- ══ 兑换 ══
    storage.convert_cost = storage.convert_cost or 1               -- 每次兑换消耗的体力
    storage.convert_batch = storage.convert_batch or 200           -- 单次兑换最多处理多少种物品，防一次点击卡顿
    storage.item_value = storage.item_value or nil                 -- 物品价值表缓存，由 values.lua 首次使用时建

    -- ══ 口袋世界 ══
    storage.pocket_size = storage.pocket_size or 256               -- 边长（tile）。256 = 8×8 区块
    storage.pocket_run = storage.pocket_run or {}                  -- [玩家名] = 该口袋世界创建时的轮次，用于判断是否该重置
    storage.pocket_keep_offline_minutes = storage.pocket_keep_offline_minutes or 30
                                                                   -- 离线超过这么久，口袋世界被回收（delete_surface）

    -- ══ 公共世界 ══
    storage.public_size = storage.public_size or 2048              -- 公共世界边长（tile）。2048 = 64×64 区块
    storage.world_reset_minutes = storage.world_reset_minutes or 120   -- 每个公共世界的重置周期（分钟）
    storage.world_reset_at = storage.world_reset_at or {}          -- [星球名] = 下次重置的 tick。错峰的真相源
    storage.world_run = storage.world_run or {}                    -- [星球名] = 该星球已重置过几轮

    -- ══ 权限 ══
    storage.block_blueprint_library = storage.block_blueprint_library ~= false
                                                                   -- 默认 true：禁蓝图库，重置才有意义

    -- ══ 调试 ══
    storage.debug = storage.debug or false                         -- true 时向管理员打印每次生成/重置的细节
end

return M
