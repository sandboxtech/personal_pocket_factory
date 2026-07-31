-- 戴森环的几何与等级计算。【纯函数模块】
--
-- 本文件不 require 任何东西、不碰任何 Factorio 全局（game / storage / prototypes 一个都不用），
-- 所以能用普通 lua 解释器跑单元测试：lua5.4 tests/test_geometry.lua
--
-- 这是整个环带形状的唯一真相源。所有边界判断都只在这里做一次，
-- ring.lua 只负责把这里算出来的砖种写进 surface。
local M = {}

-- 12 种科技瓶的短名。顺序即 UI 里的展示顺序（按 Space Age 的解锁进度排）。
-- storage.exp[玩家名] 就用这些短名当键。
M.SCIENCE_PACKS = {
    'automation', 'logistic', 'military', 'chemical',
    'production', 'utility', 'space', 'metallurgic',
    'agricultural', 'electromagnetic', 'cryogenic', 'promethium',
}

-- 短名 → 物品原型名。12 种瓶子的原型名统一是 <短名>-science-pack。
function M.pack_item_name(short)
    return short .. '-science-pack'
end

-- 戴森环等级 = floor( Σ max(0, log10(expᵢ)) )
--
-- 为什么每种单独取 log10 再求和：Σ log10(expᵢ) = log10(∏ expᵢ)。
-- 因为 log10(1) = 0，任何一种瓶子没攒过，那一项就是 0 —— 这是 12 种分开记账的全部理由，
-- 它逼玩家集齐 12 种，而不是把红瓶刷到天上。
--
-- exp ≤ 1 的项直接跳过：log10(0) 是负无穷、log10(0.5) 是负数，
-- 不夹住的话整个等级会变成 -inf 或负数，环宽会算成负的。
function M.ring_level(exp_table)
    local sum = 0
    for _, key in ipairs(M.SCIENCE_PACKS) do
        local amount = exp_table[key] or 0
        if amount > 1 then
            sum = sum + math.log(amount, 10)
        end
    end
    return math.floor(sum)
end

-- 半宽（tile）。环以原点为中心向两侧对称生长，每升一级两侧各外推 per_level。
function M.half_width(level, base_half_width, per_level)
    return base_half_width + per_level * level
end

-- 给定 tile 坐标，返回该铺哪种【语义】砖，而不是具体的砖原型名。
--
-- 为什么不直接返回 'tutorial-grid' / 'dust-lumpy' 这些真名：
-- 本文件是纯函数模块，不能读 storage（换砖名是运营层面的事，不该逼这里去碰全局状态）。
-- 语义值只有四种：
--   'start'  初始那一圈（L=0 时就有的地皮）
--   'grown'  升级长出来的地皮（攒经验换来的，地面本身就是成长记录）
--   'space'  上下的临空带
--   'void'   环外的墙
-- 真正的砖名映射交给 ring.lua 查 storage.ring_tiles。
--
-- 坐标约定：tile 坐标 x 占据 [x, x+1)，所以有效横向范围是 x ∈ [-half_width, half_width)，
-- 纵向同理。左闭右开，和 Factorio 的 tile 语义一致。
--
-- 判断顺序有意义：横向的墙优先于纵向的分带。环外就是环外，不管 y 落在哪一段。
function M.tile_at(x, y, half_width, ring_height, concrete_height, base_half_width)
    if x < -half_width or x >= half_width then
        return 'void'
    end

    local concrete_half = concrete_height / 2
    if y >= -concrete_half and y < concrete_half then
        -- 左闭右开和横向范围一致：x = -base_half_width 算 'start'。
        if x >= -base_half_width and x < base_half_width then
            return 'start'
        end
        return 'grown'
    end

    local ring_half = ring_height / 2
    if y >= -ring_half and y < ring_half then
        return 'space'
    end

    -- 引擎的 height 硬边界本来就不会生成这里，走到这一步说明配置不一致，兜底成墙。
    return 'void'
end

return M
