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

-- 戴森环等级 = 各项经验的【十进制位数】之和，i 遍历 12 种科技瓶。
-- 位数 = floor(log10(x)) + 1：1~9 是 1 位，10~99 是 2 位，以此类推。
--
-- 用位数而不是 floor(log10)，是为了让【攒到第 1 点就有第 1 级】。
-- 纯 log10 下 1~9 点一律贡献 0，玩家攒了半天第一瓶经验界面纹丝不动，
-- 看起来像没生效；位数则一进账就有反馈，后面每翻 10 倍再 +1，节奏不变。
--
-- 每一项【各自取位数再相加】，而不是【先加起来最后取一次】—— 两者结果真的不同：
--   两种瓶子各 99 点：各自 2 位合计 4；先加成 198 再取位数只有 3。
-- 差别在于后者允许多个类别的零头攒起来凑级（12 项各差一点点，加起来能白送好几级），
-- 前者则每项各算各的、零头一律丢弃。这正是 12 种分开记账的全部意义。
--
-- 它还和 UI 上那个「1234 / 10000」的进度条天生一对：
-- 既然每项的贡献就是它自己的位数，进度条显示的就正好是「这一项离下一级还差多远」，
-- 百分比和等级之间有了直接因果关系。
--
-- exp < 1 的项贡献 0 而不是 1：log10(0) 是负无穷、log10(0.5) 是负数，
-- 不夹住的话等级会变成 -inf 或负数；而且「没攒过的瓶子不该白给一级」本身就是规则 ——
-- 缺一种就整整少一段，这是逼玩家跑遍五个星球的那根杠杆。
function M.ring_level(exp_table)
    local sum = 0
    for _, key in ipairs(M.SCIENCE_PACKS) do
        local amount = exp_table[key] or 0
        if amount >= 1 then
            sum = sum + math.floor(math.log(amount, 10)) + 1
        end
    end
    return sum
end

-- 半宽（tile）。环以原点为中心向两侧对称生长，每升一级两侧各外推 per_level。
--
-- level_bonus 是【白送的级数】：半宽 = per_level × (等级 + level_bonus)，
-- 配置 (32, 16, 2) 即【宽度 = 32 × (等级和 + 2)】。
-- 取 2 让等级 0（一点经验都没攒）时宽度正好是下限 64，起步宽度和"还没开始"这个状态对上。
--
-- 【曾经写成减法（等级 − 10），那是个真实的设计缺陷】：
-- 那组参数是为了让改用十进制位数计级之后宽度和之前逐点相同而反推出来的，
-- 数值上确实做到了，但配上下限 64 的后果是【等级 0 到 12 宽度全都是 64】——
-- 集齐 12 种科技瓶一格都不涨。而"从第一点经验起就看得见进展"正是把等级
-- 改成位数的全部理由，那个偏移把这个理由整个抵消了。
-- 教训：改公式时只验证"数值没变"不够，还要检查【新定义下这条曲线本身还合不合理】。
--
-- 仍然夹下限，但它现在只是脏数据的兜底（等级 >= 0 时永远不会触发）：
-- 半宽为负会让 tile_at 把整条环判成 void，玩家掉进一个一格地板都没有的世界。
function M.half_width(level, base_half_width, per_level, level_bonus)
    local grown = per_level * (level + (level_bonus or 0))
    if grown < base_half_width then return base_half_width end
    return grown
end

-- 给定 tile 坐标，返回该铺哪种【语义】砖，而不是具体的砖原型名。
--
-- 为什么不直接返回具体的砖原型名（比如 'tutorial-grid'）：
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
function M.tile_at(x, y, half_width, ring_height, concrete_height, base_half_width, pond_half)
    if x < -half_width or x >= half_width then
        return 'void'
    end

    -- 环心的一小片浅水（'water'），半径 pond_half，不传或传 0 就没有水池。
    --
    -- 【它解决的是开局死锁，不是取水麻烦】：原版第一套电力是锅炉 + 蒸汽机，要水。
    -- 环里没有水的话，玩家造不出电；造不出电就点不亮实验室；点不亮实验室就研究不出
    -- 太阳能板 —— 于是连第一个红瓶都出不来，整局卡死在起点。
    -- 给水不破坏「环里没有资源」这条核心约束：一颗矿还是没有，水只是公共设施。
    --
    -- 判定【必须排在 start/grown 之前】：那两者覆盖整条中间可建带，写在后面就永远轮不到水池。
    -- 用浅水（映射见 storage.ring_tiles.water）而不是深水：浅水的碰撞掩码里没有 player 层，
    -- 角色能直接趟过去，不会把环心切成互不相通的两半；同时它有 water_tile 层，
    -- 满足海洋泵 tile_buildability_rules 里「泵前方两格必须是水」那一条。
    if pond_half and pond_half > 0
            and x >= -pond_half and x < pond_half
            and y >= -pond_half and y < pond_half then
        return 'water'
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
