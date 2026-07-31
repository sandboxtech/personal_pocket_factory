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
local HW, RH, CH = 32, 128, 64
local function t(x, y) return geo.tile_at(x, y, HW, RH, CH) end

check('原点是混凝土',        t(0, 0), 'concrete')
check('右边界内最后一格',    t(31, 0), 'concrete')
check('右边界外第一格',      t(32, 0), 'out-of-map')
check('左边界内第一格',      t(-32, 0), 'concrete')
check('左边界外第一格',      t(-33, 0), 'out-of-map')

check('混凝土带上沿(含)',    t(0, -32), 'concrete')
check('混凝土带上沿外',      t(0, -33), 'empty-space')
check('混凝土带下沿(不含)',  t(0, 32), 'empty-space')
check('混凝土带下沿内',      t(0, 31), 'concrete')

check('环上沿内',            t(0, -64), 'empty-space')
check('环上沿外',            t(0, -65), 'out-of-map')
check('环下沿内',            t(0, 63), 'empty-space')
check('环下沿外',            t(0, 64), 'out-of-map')

-- 横向墙优先于纵向分带：环外就是环外，不管 y 在哪一段
check('横向越界压过纵向分带', t(100, 0), 'out-of-map')
check('横向越界压过临空带',   t(100, 40), 'out-of-map')

-- ══ 汇总 ══
print(string.format('%d/%d 通过', total - failures, total))
os.exit(failures == 0 and 0 or 1)
