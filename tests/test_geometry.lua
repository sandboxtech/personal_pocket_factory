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
check('12 种各 1 → 12（集齐即 12 级，也是环长下限对应的等级）', geo.ring_level(all_one), 12)

local all_million = {}
for _, k in ipairs(geo.SCIENCE_PACKS) do all_million[k] = 1000000 end
check('12 种各 100 万 → 84', geo.ring_level(all_million), 84)

-- 缺一种就整整少一段：没攒过的那项贡献 0，不是 1
local eleven = {}
for _, k in ipairs(geo.SCIENCE_PACKS) do eleven[k] = 10 end
eleven[geo.SCIENCE_PACKS[12]] = 0
check('缺 1 种 → 22', geo.ring_level(eleven), 22)

-- ══ half_length ══
-- 长度 = 每级步长 × (等级和 + 加成)，配置是 (32, 16, 4)，即【长 = 16 × (等级和 + 4)】。
-- 半长是长度的一半，所以 half = 8 × (等级 + 4)。
--
-- 加成取 4 而不是别的数：等级 0（一点经验都没有）时长度正好是 64，
-- 也就是下限 base_half_length × 2 —— 起始长度和"还没开始攒"这个状态对上。
-- 此后【每一级都真的加长 16 格】，包括最开始那几级。
--
-- 这一点是上一版的问题所在：那时用的是 (等级 − 10)，配上下限 64 的结果是
-- 等级 0 到 12 长度全是 64 —— 集齐 12 种科技瓶一格都不涨，
-- 而"从第一点经验起就看得见进展"正是把等级改成十进制位数的全部理由。
check('等级 0 → 半长 32（长 64）',   geo.half_length(0, 32, 16, 4), 32)
check('等级 1 → 半长 40（长 80）',   geo.half_length(1, 32, 16, 4), 40)
check('等级 12（集齐各 1 点）→ 半长 128（长 256）', geo.half_length(12, 32, 16, 4), 128)
check('等级 24（各 10 点）→ 半长 224（长 448）',    geo.half_length(24, 32, 16, 4), 224)
check('等级 84（各 100 万）→ 半长 704（长 1408）',  geo.half_length(84, 32, 16, 4), 704)

-- 逐级递增：绝不能出现"升了一级长度没变"的区间
for lv = 0, 40 do
    check(('等级 %d → %d 每级都真的变长'):format(lv, lv + 1),
        geo.half_length(lv + 1, 32, 16, 4) - geo.half_length(lv, 32, 16, 4), 8)
end

-- 下限只是脏数据的兜底：等级为负时不能返回 0 或负数，
-- 否则 tile_at 会把整条环判成 void，玩家掉进一个一格地板都没有的世界。
check('等级 -5(脏数据) → 夹到下限 32', geo.half_length(-5, 32, 16, 4), 32)
check('等级 -100(脏数据) → 夹到下限 32', geo.half_length(-100, 32, 16, 4), 32)

-- 公式对照：长度必须严格等于 (等级和 + 4) × 16
for lv = 0, 84 do
    check(('公式对照 等级 %d'):format(lv), 2 * geo.half_length(lv, 32, 16, 4), (lv + 4) * 16)
end

-- ══ tile_at ══
-- 约定：tile 坐标 y 占据 [y, y+1)，所以有效长度范围是 y ∈ [-half, half)
-- 返回值现在是语义值：'start' / 'grown' / 'space' / 'void'（不是具体砖名，见 geometry.lua 顶部注释）
-- 环宽 32 = 中间 16 格可建带 + 左右各 8 格临空带。
local HL, RW, CW, BHL = 32, 32, 16, 32
local function t(x, y) return geo.tile_at(x, y, HL, RW, CW, BHL) end

check('原点是初始区域',      t(0, 0), 'start')
check('下边界内最后一格',    t(0, 31), 'start')
check('下边界外第一格',      t(0, 32), 'void')
check('上边界内第一格',      t(0, -32), 'start')
check('上边界外第一格',      t(0, -33), 'void')

check('可建带左沿(含)',      t(-8, 0), 'start')
check('可建带左沿外',        t(-9, 0), 'space')
check('可建带右沿(不含)',    t(8, 0), 'space')
check('可建带右沿内',        t(7, 0), 'start')

check('环左沿内',            t(-16, 0), 'space')
check('环左沿外',            t(-17, 0), 'void')
check('环右沿内',            t(15, 0), 'space')
check('环右沿外',            t(16, 0), 'void')

-- 纵向墙优先于横向分带：环外就是环外，不管 x 在哪一段
check('长度越界压过横向分带', t(0, 100), 'void')
check('长度越界压过临空带',   t(10, 100), 'void')

-- ══ tile_at：初始区域 vs 升级长出来的区域（base_half_width 语义）══
-- half_length == base_half_length 时，整条可建带都还是 'start'，没有 'grown' 的空间。
check('初始区域内(原点)',    t(0, 0), 'start')
check('初始区域内(y=31)',    t(0, 31), 'start')
check('初始区域内(y=-32)',   t(0, -32), 'start')

-- half_length 大于 base_half_length：上下外侧是升级长出来的 'grown'。
local HL2, BHL2 = 80, 32
local function tg(x, y) return geo.tile_at(x, y, HL2, RW, CW, BHL2) end

check('grown 场景: 初始区域内仍是 start',  tg(0, 0), 'start')
check('grown 场景: base 下边界外第一格',   tg(0, 32), 'grown')
check('grown 场景: base 上边界外第一格',   tg(0, -33), 'grown')
check('grown 场景: 新半长内最后一格',      tg(0, 79), 'grown')
check('grown 场景: 新半长外第一格(墙)',    tg(0, 80), 'void')
check('grown 场景: 临空带仍是 space',      tg(10, 50), 'space')

-- ══ tile_at：环心水池 ══
-- 出生点一片 4×4 浅水，半径 2（tile x/y 各从 -2 到 1）。
-- 存在的理由是【开局引导】：原版第一套电力是锅炉 + 蒸汽机，要水；
-- 环里没水的话玩家造不出电，造不出电就点不亮实验室，点不亮实验室就研究不出太阳能，
-- 于是连第一个红瓶都出不来。给水不破坏「环里没有资源」——一颗矿还是没有。
--
-- 水池判定必须【优先于】start/grown，否则会被中间那条可建带整片盖掉。
local W, C, B = 32, 16, 32       -- ring_width / concrete_width / base_half_length
local POND = 2                   -- 水池半径

check('水池中心',        geo.tile_at(0, 0, 64, W, C, B, POND), 'water')
check('水池左上角',      geo.tile_at(-2, -2, 64, W, C, B, POND), 'water')
check('水池右下角(闭区间内)', geo.tile_at(1, 1, 64, W, C, B, POND), 'water')
-- 左闭右开：x = 2 和 y = 2 已经在池子外
check('水池右边界外',    geo.tile_at(2, 0, 64, W, C, B, POND), 'start')
check('水池下边界外',    geo.tile_at(0, 2, 64, W, C, B, POND), 'start')
check('水池左边界外',    geo.tile_at(-3, 0, 64, W, C, B, POND), 'start')

-- 【箱阵横排】：占 tile y = -5 和 y = 4，绝不能被水淹掉。
-- 这两行是整个箱阵的边界样本：x 取到最左(-3)和最右(2)。
check('上行箱位左端是陆地', geo.tile_at(-3, -5, 64, W, C, B, POND), 'start')
check('上行箱位右端是陆地', geo.tile_at(2, -5, 64, W, C, B, POND), 'start')
check('下行箱位左端是陆地', geo.tile_at(-3, 4, 64, W, C, B, POND), 'start')
check('下行箱位右端是陆地', geo.tile_at(2, 4, 64, W, C, B, POND), 'start')

-- 【池岸四面都是陆地】：海洋泵必须站在陆地上、泵口朝水。
-- 上一版池子 6×6、箱行紧贴在 -4/3，上下岸一格不剩，泵只能从左右两侧架。
-- 池子缩到 4×4、箱行退到 -5/4 之后，上下各空出 2 格（y = -4/-3 和 y = 2/3），
-- 取水面从两面变四面 —— 下面这四条断言就是那两条新路径的保证
-- （左右两侧已由上面的「水池左/右边界外」覆盖，不再重复断言）。
check('池上岸紧邻一格是陆地', geo.tile_at(0, -3, 64, W, C, B, POND), 'start')
check('池上岸第二格是陆地',   geo.tile_at(0, -4, 64, W, C, B, POND), 'start')
check('池下岸紧邻一格是陆地', geo.tile_at(0, 2, 64, W, C, B, POND), 'start')
check('池下岸第二格是陆地',   geo.tile_at(0, 3, 64, W, C, B, POND), 'start')

-- 水池不能越过环的边界，也不能盖掉临空带和墙
check('环外仍是墙',      geo.tile_at(-100, 0, 64, W, C, B, POND), 'void')
check('临空带不受影响',  geo.tile_at(10, 0, 64, W, C, B, POND), 'space')

-- 不传 pond_half（或传 0）时行为和加水池之前完全一致，老调用点不受影响
check('无水池参数时环心是 start', geo.tile_at(0, 0, 64, W, C, B), 'start')
check('水池半径 0 时环心是 start', geo.tile_at(0, 0, 64, W, C, B, 0), 'start')

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
