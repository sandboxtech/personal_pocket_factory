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
-- 半宽 = max(下限, 每级步长 × (等级 - 偏移))，配置是 (32, 16, 10)，即
-- 宽 = 32 × (等级 - 10)，下限 64。集齐 12 种（等级 12）时正好落在下限上。
check('等级 12（集齐，各 1 点）→ 半宽 32', geo.half_width(12, 32, 16, 10), 32)
check('等级 13 → 半宽 48',                geo.half_width(13, 32, 16, 10), 48)
check('等级 24（各 10 点）→ 半宽 224',     geo.half_width(24, 32, 16, 10), 224)
check('等级 84（各 100 万）→ 半宽 1184',   geo.half_width(84, 32, 16, 10), 1184)

-- 偏移以下一律夹到下限，绝不返回 0 或负数——负半宽会让 tile_at 把整条环判成 void，
-- 玩家会掉进一个一格地板都没有的世界。
check('等级 10 → 夹到下限 32', geo.half_width(10, 32, 16, 10), 32)
check('等级 0  → 夹到下限 32', geo.half_width(0, 32, 16, 10), 32)
check('等级 -5(脏数据) → 夹到下限 32', geo.half_width(-5, 32, 16, 10), 32)

-- ══ 换算不改变实际效果：集齐 12 种时，新旧公式给出的环宽必须逐点相同 ══
-- 旧：等级 L = Σ floor(log10)，半宽 = 32 + 16L
-- 新：等级 L' = Σ (floor(log10)+1) = L + 12，半宽 = max(32, 16 × (L' - 10)) = 32 + 16L
for old_level = 0, 72 do
    local old_half = 32 + 16 * old_level
    local new_half = geo.half_width(old_level + 12, 32, 16, 10)
    check(('换算等价 L=%d'):format(old_level), new_half, old_half)
end

-- ══ tile_at ══
-- 约定：tile 坐标 x 占据 [x, x+1)，所以有效范围是 x ∈ [-half, half)
-- 返回值现在是语义值：'start' / 'grown' / 'space' / 'void'（不是具体砖名，见 geometry.lua 顶部注释）
local HW, RH, CH, BHW = 32, 128, 64, 32
local function t(x, y) return geo.tile_at(x, y, HW, RH, CH, BHW) end

check('原点是初始区域',      t(0, 0), 'start')
check('右边界内最后一格',    t(31, 0), 'start')
check('右边界外第一格',      t(32, 0), 'void')
check('左边界内第一格',      t(-32, 0), 'start')
check('左边界外第一格',      t(-33, 0), 'void')

check('混凝土带上沿(含)',    t(0, -32), 'start')
check('混凝土带上沿外',      t(0, -33), 'space')
check('混凝土带下沿(不含)',  t(0, 32), 'space')
check('混凝土带下沿内',      t(0, 31), 'start')

check('环上沿内',            t(0, -64), 'space')
check('环上沿外',            t(0, -65), 'void')
check('环下沿内',            t(0, 63), 'space')
check('环下沿外',            t(0, 64), 'void')

-- 横向墙优先于纵向分带：环外就是环外，不管 y 在哪一段
check('横向越界压过纵向分带', t(100, 0), 'void')
check('横向越界压过临空带',   t(100, 40), 'void')

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
check('grown 场景: 临空带仍是 space',      tg(50, 40), 'space')

-- ══ 汇总 ══
print(string.format('%d/%d 通过', total - failures, total))
os.exit(failures == 0 and 0 or 1)
