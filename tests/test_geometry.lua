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
-- log10(0) 是负无穷、log10(1)=0，两个都必须夹到 0，否则等级会变成 -inf 或负数
check('空表',            geo.ring_level({}), 0)
check('经验为 0',        geo.ring_level({automation = 0}), 0)
check('经验为 1',        geo.ring_level({automation = 1}), 0)
check('经验小于 1',      geo.ring_level({automation = 0.5}), 0)
check('经验为负(脏数据)', geo.ring_level({automation = -100}), 0)
check('单种 10',         geo.ring_level({automation = 10}), 1)
check('单种 999',        geo.ring_level({automation = 999}), 2)
check('单种 1000',       geo.ring_level({automation = 1000}), 3)
check('未知键被忽略',    geo.ring_level({automation = 10, ['不存在的瓶子'] = 1e9}), 1)

-- 新旧公式的区分性用例：新式是「每项各自 floor 再相加」，旧式是「先加起来最后 floor 一次」。
-- 两种瓶子各 99 点：
--   旧式 floor(log10(99) × 2) = floor(1.9956 × 2) = floor(3.9912) = 3
--   新式 floor(log10(99)) + floor(log10(99)) = 1 + 1 = 2
-- 新式不允许两项的零头（0.9956 各一份）攒起来凑出第 3 级。
check('新旧公式分歧: 两种各 99 → 新式 2（旧式会是 3）',
    geo.ring_level({automation = 99, logistic = 99}), 2)

-- 三种瓶子各 9 点：
--   旧式 floor(log10(9) × 3) = floor(0.9542 × 3) = floor(2.8627) = 2
--   新式 floor(log10(9)) × 3 = 0 × 3 = 0（9 < 10，每项单独看都还没到第 1 级）
-- 这条最能说明零头不会跨项攒起来：三个 9 点在旧式下能拼出 2 级，新式下一级都拼不出来。
check('新旧公式分歧: 三种各 9 → 新式 0（旧式会是 2）',
    geo.ring_level({automation = 9, logistic = 9, military = 9}), 0)

local all_ten = {}
for _, k in ipairs(geo.SCIENCE_PACKS) do all_ten[k] = 10 end
check('12 种各 10 → 12', geo.ring_level(all_ten), 12)

local all_million = {}
for _, k in ipairs(geo.SCIENCE_PACKS) do all_million[k] = 1000000 end
check('12 种各 100 万 → 72', geo.ring_level(all_million), 72)

-- 缺一种就少一整段：这是 12 种分开记账的全部意义
local eleven = {}
for _, k in ipairs(geo.SCIENCE_PACKS) do eleven[k] = 10 end
eleven[geo.SCIENCE_PACKS[12]] = 0
check('缺 1 种 → 11', geo.ring_level(eleven), 11)

-- ══ half_width ══
check('L=0',  geo.half_width(0, 32, 16), 32)
check('L=1',  geo.half_width(1, 32, 16), 48)
check('L=12', geo.half_width(12, 32, 16), 224)
check('L=72', geo.half_width(72, 32, 16), 1184)

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
