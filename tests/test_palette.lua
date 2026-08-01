-- 噪声值 → 调色板下标的单测。不加载任何 Factorio API。
-- 跑法：lua5.4 tests/test_palette.lua （从场景根目录）
--
-- 【为什么值得单测】：这个函数错了不会报错，只会让整颗星球长得不对 ——
-- 下标算偏一格就是整张地貌图偏一种砖，越界不夹住就是 palette[nil] 传进 set_tiles 后抛错，
-- 而这两种症状都要开游戏、等一轮世界重置才看得见。
package.path = '?.lua;' .. package.path
local palette = require('scripts.palette')

local failures, total = 0, 0

local function check(label, actual, expected)
    total = total + 1
    if actual ~= expected then
        failures = failures + 1
        print(string.format('FAIL  %s\n      期望 %s，实得 %s',
            label, tostring(expected), tostring(actual)))
    end
end

local N = 4        -- 4 条色带，v 空间里每条宽 0.5

-- ══ 不抖动时就是老的纯量化行为 ══
check('下界落第一条',      palette.index(-1, N, 0, 0), 1)
check('第一条内',          palette.index(-0.9, N, 0, 0), 1)
check('第一/二条边界',     palette.index(-0.5, N, 0, 0), 2)
check('中点落第三条',      palette.index(0, N, 0, 0), 3)
check('第三/四条边界',     palette.index(0.5, N, 0, 0), 4)
check('上界仍是最后一条',  palette.index(1, N, 0, 0), N)

-- ══ 越界一律夹住，绝不返回 nil 下标 ══
-- palette[nil] 会把 nil 塞进 set_tiles 的 name 字段，整批涂砖当场抛错。
check('远低于下界',        palette.index(-99, N, 0, 0), 1)
check('远高于上界',        palette.index(99, N, 0, 0), N)
check('抖动把边缘推出界',  palette.index(-1, N, -1, 5), 1)
check('抖动把边缘推出上界', palette.index(1, N, 1, 5), N)

-- ══ 抖动：单位是【色带宽度】，blend=1 最多推一整条 ══
-- 一条色带宽 2/N = 0.5。v = -0.5 不抖动时是第 2 条（上面已断言），
-- 满幅抖动正好把它推到相邻的那条：-1 × 1 × 0.5 → 第 1 条，+1 × 1 × 0.5 → 第 3 条。
-- 「blend = 1 最多推一整条」这句话的确切含义就是这两行。
check('满幅抖动往前推一条', palette.index(-0.5, N, -1, 1), 1)
check('满幅抖动往后推一条', palette.index(-0.5, N, 1, 1), 3)
-- 抖动不足一条时推不动界内深处的格子：v = -0.9 离界还有 0.4，
-- 而 blend 0.2 只能推 0.1。
check('界内深处不受小抖动影响', palette.index(-0.9, N, 1, 0.2), 1)

-- ══ 退化输入 ══
-- 调用方（world_terrain.palette_for）已经保证 #palette >= 2，这里是兜底：
-- 返回 1 而不是 0 或 nil，因为 Lua 数组下标从 1 开始，palette[1] 一定存在。
check('单色调色板',        palette.index(0.7, 1, 0.5, 1), 1)
check('n 为 0',            palette.index(0, 0, 0, 0), 1)
check('n 为 nil',          palette.index(0, nil, 0, 0), 1)
check('jitter 为 nil',     palette.index(0, N, nil, 1), 3)
check('blend 为 nil',      palette.index(0, N, 1, nil), 3)

-- ══ 遍历全域：任何输入都必须落在 [1, n] 内 ══
-- 这一条覆盖的是上面逐点断言列不完的组合。夹不住的话下标会变成 nil。
local out_of_range = 0
for i = -30, 30 do
    for j = -4, 4 do
        local idx = palette.index(i / 10, N, j / 4, 1)
        if idx < 1 or idx > N or idx ~= math.floor(idx) then
            out_of_range = out_of_range + 1
        end
    end
end
check('全域扫描无越界/无小数下标', out_of_range, 0)

-- 断言真的都跑到了。os.exit 就在下面几行，往末尾追加的断言曾经整段变成死代码。
local declared = 0
for line in io.lines('tests/test_palette.lua') do
    if line:match('^%s*check%(') then declared = declared + 1 end
end
if total < declared then
    print(string.format('FAIL  只跑了 %d 条断言，文件里写了 %d 条', total, declared))
    failures = failures + 1
end

print(string.format('%d/%d 通过', total - failures, total))
os.exit(failures == 0 and 0 or 1)
