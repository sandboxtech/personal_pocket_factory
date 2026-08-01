-- 纯函数单测。不加载任何 Factorio API。
-- 跑法：lua5.4 tests/test_geometry.lua （从场景根目录）
package.path = 'scripts/?.lua;' .. package.path
local geo = require('geometry')

local failures, total = 0, 0

local function check(label, actual, expected)
    total = total + 1
    if actual ~= expected then
        failures = failures + 1
        print(string.format('FAIL  %s\n      期望 %s，实得 %s',
            label, tostring(expected), tostring(actual)))
    end
end

-- ══ SCIENCE_PACKS ══
check('恰好 12 种瓶子', #geo.SCIENCE_PACKS, 12)
check('短名转物品名', geo.pack_item_name('automation'), 'automation-science-pack')
check('短名转物品名(终局)', geo.pack_item_name('promethium'), 'promethium-science-pack')

-- ══ ring_level ══
-- 等级 = 各项经验的【十进制位数】之和：1~9 算 1 位、10~99 算 2 位，以此类推。
-- 也就是 floor(log10(x)) + 1，攒到 1 点就有 1 级，不用等到 10 点。
-- amount < 1 的项贡献 0（log10(0) 是负无穷，不夹住等级会变成 -inf）。
check('空表',            geo.ring_level({}), 0)
check('经验为 0',        geo.ring_level({automation = 0}), 0)
check('经验小于 1',      geo.ring_level({automation = 0.5}), 0)
check('经验为负(脏数据)', geo.ring_level({automation = -100}), 0)
check('经验为 1 → 1 位', geo.ring_level({automation = 1}), 1)
check('经验为 9 → 1 位', geo.ring_level({automation = 9}), 1)
check('单种 10 → 2 位',  geo.ring_level({automation = 10}), 2)
check('单种 999 → 3 位', geo.ring_level({automation = 999}), 3)
check('单种 1000 → 4 位',geo.ring_level({automation = 1000}), 4)
check('未知键被忽略',    geo.ring_level({automation = 10, ['不存在的瓶子'] = 1e9}), 2)

-- 每项【各自取位数再相加】，而不是【先加起来再取一次位数】。
-- 两种瓶子各 99 点：各自 2 位，合计 4；若先相加（198）再取位数只有 3。
-- 零头不跨项攒：这是 12 种分开记账的全部意义。
check('两种各 99 → 各 2 位 = 4', geo.ring_level({automation = 99, logistic = 99}), 4)
check('三种各 9 → 各 1 位 = 3',  geo.ring_level({automation = 9, logistic = 9, military = 9}), 3)

local all_ten = {}
for _, k in ipairs(geo.SCIENCE_PACKS) do all_ten[k] = 10 end
check('12 种各 10 → 24', geo.ring_level(all_ten), 24)

local all_one = {}
for _, k in ipairs(geo.SCIENCE_PACKS) do all_one[k] = 1 end
check('12 种各 1 → 12（集齐即 12 级，也是环宽下限对应的等级）', geo.ring_level(all_one), 12)

local all_million = {}
for _, k in ipairs(geo.SCIENCE_PACKS) do all_million[k] = 1000000 end
check('12 种各 100 万 → 84', geo.ring_level(all_million), 84)

-- 缺一种就整整少一段：没攒过的那项贡献 0，不是 1
local eleven = {}
for _, k in ipairs(geo.SCIENCE_PACKS) do eleven[k] = 10 end
eleven[geo.SCIENCE_PACKS[12]] = 0
check('缺 1 种 → 22', geo.ring_level(eleven), 22)

-- ══ half_width ══
-- 宽度 = 每级步长 × (等级和 + 加成)，配置是 (32, 16, 2)，即【宽 = 32 × (等级和 + 2)】。
-- 半宽是宽度的一半，所以 half = 16 × (等级 + 2)。
--
-- 加成取 2 而不是别的数：等级 0（一点经验都没有）时宽度正好是 64，
-- 也就是下限 base_half_width × 2 —— 起步宽度和"还没开始攒"这个状态对上。
-- 此后【每一级都真的加宽 32 格】，包括最开始那几级。
--
-- 这一点是上一版的问题所在：那时用的是 (等级 − 10)，配上下限 64 的结果是
-- 等级 0 到 12 宽度全是 64 —— 集齐 12 种科技瓶一格都不涨，
-- 而"从第一点经验起就看得见进展"正是把等级改成十进制位数的全部理由。
check('等级 0 → 半宽 32（宽 64）',   geo.half_width(0, 32, 16, 2), 32)
check('等级 1 → 半宽 48（宽 96）',   geo.half_width(1, 32, 16, 2), 48)
check('等级 12（集齐各 1 点）→ 半宽 224（宽 448）', geo.half_width(12, 32, 16, 2), 224)
check('等级 24（各 10 点）→ 半宽 416（宽 832）',    geo.half_width(24, 32, 16, 2), 416)
check('等级 84（各 100 万）→ 半宽 1376（宽 2752）', geo.half_width(84, 32, 16, 2), 1376)

-- 逐级递增：绝不能出现"升了一级宽度没变"的区间
for lv = 0, 40 do
    check(('等级 %d → %d 每级都真的变宽'):format(lv, lv + 1),
        geo.half_width(lv + 1, 32, 16, 2) - geo.half_width(lv, 32, 16, 2), 16)
end

-- 下限只是脏数据的兜底：等级为负时不能返回 0 或负数，
-- 否则 tile_at 会把整条环判成 void，玩家掉进一个一格地板都没有的世界。
check('等级 -5(脏数据) → 夹到下限 32', geo.half_width(-5, 32, 16, 2), 32)
check('等级 -100(脏数据) → 夹到下限 32', geo.half_width(-100, 32, 16, 2), 32)

-- 公式对照：宽度必须严格等于 (等级和 + 2) × 32
for lv = 0, 84 do
    check(('公式对照 等级 %d'):format(lv), 2 * geo.half_width(lv, 32, 16, 2), (lv + 2) * 32)
end

-- ══ tile_at ══
-- 约定：tile 坐标 x 占据 [x, x+1)，所以有效范围是 x ∈ [-half, half)
-- 返回值现在是语义值：'start' / 'grown' / 'space' / 'void'（不是具体砖名，见 geometry.lua 顶部注释）
-- 环高 64 = 中间 32 格可建带 + 上下各 16 格临空带。
local HW, RH, CH, BHW = 32, 64, 32, 32
local function t(x, y) return geo.tile_at(x, y, HW, RH, CH, BHW) end

check('原点是初始区域',      t(0, 0), 'start')
check('右边界内最后一格',    t(31, 0), 'start')
check('右边界外第一格',      t(32, 0), 'void')
check('左边界内第一格',      t(-32, 0), 'start')
check('左边界外第一格',      t(-33, 0), 'void')

check('混凝土带上沿(含)',    t(0, -16), 'start')
check('混凝土带上沿外',      t(0, -17), 'space')
check('混凝土带下沿(不含)',  t(0, 16), 'space')
check('混凝土带下沿内',      t(0, 15), 'start')

check('环上沿内',            t(0, -32), 'space')
check('环上沿外',            t(0, -33), 'void')
check('环下沿内',            t(0, 31), 'space')
check('环下沿外',            t(0, 32), 'void')

-- 横向墙优先于纵向分带：环外就是环外，不管 y 在哪一段
check('横向越界压过纵向分带', t(100, 0), 'void')
check('横向越界压过临空带',   t(100, 20), 'void')

-- ══ tile_at：初始区域 vs 升级长出来的区域（base_half_width 语义）══
-- half_width == base_half_width 时，整条混凝土带都还是 'start'，没有 'grown' 的空间。
check('初始区域内(原点)',    t(0, 0), 'start')
check('初始区域内(x=31)',    t(31, 0), 'start')
check('初始区域内(x=-32)',   t(-32, 0), 'start')

-- half_width 大于 base_half_width：外侧是升级长出来的 'grown'。
local HW2, BHW2 = 80, 32
local function tg(x, y) return geo.tile_at(x, y, HW2, RH, CH, BHW2) end

check('grown 场景: 初始区域内仍是 start',  tg(0, 0), 'start')
check('grown 场景: base 右边界外第一格',   tg(32, 0), 'grown')
check('grown 场景: base 左边界外第一格',   tg(-33, 0), 'grown')
check('grown 场景: 新半宽内最后一格',      tg(79, 0), 'grown')
check('grown 场景: 新半宽外第一格(墙)',    tg(80, 0), 'void')
check('grown 场景: 临空带仍是 space',      tg(50, 20), 'space')

-- ══ tile_at：环心水池 ══
-- 出生点一片 4×4 浅水，半径 2（tile x/y 各从 -2 到 1）。
-- 存在的理由是【开局引导】：原版第一套电力是锅炉 + 蒸汽机，要水；
-- 环里没水的话玩家造不出电，造不出电就点不亮实验室，点不亮实验室就研究不出太阳能，
-- 于是连第一个红瓶都出不来。给水不破坏「环里没有资源」——一颗矿还是没有。
--
-- 水池判定必须【优先于】start/grown，否则会被中间那条可建带整片盖掉。
local H, C, B = 64, 32, 32       -- ring_height / concrete_height / base_half_width
local POND = 2                   -- 水池半径

check('水池中心',        geo.tile_at(0, 0, 64, H, C, B, POND), 'water')
check('水池左上角',      geo.tile_at(-2, -2, 64, H, C, B, POND), 'water')
check('水池右下角(闭区间内)', geo.tile_at(1, 1, 64, H, C, B, POND), 'water')
-- 左闭右开：x = 2 和 y = 2 已经在池子外
check('水池右边界外',    geo.tile_at(2, 0, 64, H, C, B, POND), 'start')
check('水池下边界外',    geo.tile_at(0, 2, 64, H, C, B, POND), 'start')
check('水池左边界外',    geo.tile_at(-3, 0, 64, H, C, B, POND), 'start')

-- 【箱阵横排】：占 tile y = -5 和 y = 4，绝不能被水淹掉。
-- 这两行是整个箱阵的边界样本：x 取到最左(-3)和最右(2)。
check('上行箱位左端是陆地', geo.tile_at(-3, -5, 64, H, C, B, POND), 'start')
check('上行箱位右端是陆地', geo.tile_at(2, -5, 64, H, C, B, POND), 'start')
check('下行箱位左端是陆地', geo.tile_at(-3, 4, 64, H, C, B, POND), 'start')
check('下行箱位右端是陆地', geo.tile_at(2, 4, 64, H, C, B, POND), 'start')

-- 【池岸四面都是陆地】：海洋泵必须站在陆地上、泵口朝水。
-- 上一版池子 6×6、箱行紧贴在 -4/3，上下岸一格不剩，泵只能从左右两侧架。
-- 池子缩到 4×4、箱行退到 -5/4 之后，上下各空出 2 格（y = -4/-3 和 y = 2/3），
-- 取水面从两面变四面 —— 下面这四条断言就是那两条新路径的保证
-- （左右两侧已由上面的「水池左/右边界外」覆盖，不再重复断言）。
check('池上岸紧邻一格是陆地', geo.tile_at(0, -3, 64, H, C, B, POND), 'start')
check('池上岸第二格是陆地',   geo.tile_at(0, -4, 64, H, C, B, POND), 'start')
check('池下岸紧邻一格是陆地', geo.tile_at(0, 2, 64, H, C, B, POND), 'start')
check('池下岸第二格是陆地',   geo.tile_at(0, 3, 64, H, C, B, POND), 'start')

-- 水池不能越过环的边界，也不能盖掉临空带和墙
check('环外仍是墙',      geo.tile_at(-100, 0, 64, H, C, B, POND), 'void')
check('临空带不受影响',  geo.tile_at(0, 20, 64, H, C, B, POND), 'space')

-- 不传 pond_half（或传 0）时行为和加水池之前完全一致，老调用点不受影响
check('无水池参数时环心是 start', geo.tile_at(0, 0, 64, H, C, B), 'start')
check('水池半径 0 时环心是 start', geo.tile_at(0, 0, 64, H, C, B, 0), 'start')

-- ══ 汇总 ══
-- 【自检：有没有断言压根没跑】
-- 把本文件里 check( 的出现次数数一遍，和实际执行到的 total 对比。
-- 起因是一段新断言被插到了 os.exit() 后面，成了死代码：测试照常报"全部通过"，
-- 而那几条根本没执行。测试不跑比没有测试更糟——它会主动汇报一个假的成功。
local declared = 0
for line in io.lines('tests/test_geometry.lua') do
    if line:match('^%s*check%(') then declared = declared + 1 end
end
-- 判据是【执行数不少于书写数】而不是相等：循环里的 check 一行会跑很多次
-- （等价性对照那段一行就跑 73 次），相等永远不成立。少于书写数才说明有断言没跑到。
if total < declared then
    print(string.format('FAIL  文件里写了 %d 条断言，实际只跑到 %d 条（有断言不可达？）',
        declared, total))
    failures = failures + 1
end

print(string.format('%d/%d 通过', total - failures, total))
os.exit(failures == 0 and 0 or 1)

