-- 导入数据校验的单测。不加载任何 Factorio API。
-- 跑法：lua5.4 tests/test_expio.lua （从场景根目录）
--
-- 【为什么这一段值得单测】：导入是唯一一条把【外部文件里的任意数据】写进 storage 的路径。
-- 一个 NaN 经验不会当场报错，它会让 ring_level 算出 NaN、半长算出 NaN，
-- 直到涂砖那一刻才炸，而那时的报错信息里没有任何东西指向"导入"这一步。
-- 所以脏数据必须在 validate 里就被挡住，而 validate 恰好是纯函数，能在游戏外测。
package.path = '?.lua;' .. package.path
local expio = require('scripts.expio')

local failures, total = 0, 0

local function check(label, actual, expected)
    total = total + 1
    if actual ~= expected then
        failures = failures + 1
        print(string.format('FAIL  %s\n      期望 %s，实得 %s',
            label, tostring(expected), tostring(actual)))
    end
end

local function snapshot(players)
    return {format = expio.FORMAT, version = expio.VERSION, tick = 0, players = players}
end

-- ══ 格式把关：认不出来的一律返回 nil，绝不半信半疑地导一部分 ══
check('不是表', expio.validate(42), nil)
check('缺 format', expio.validate({players = {}}), nil)
check('format 不对', expio.validate({format = 'something-else', players = {}}), nil)
check('players 不是表', expio.validate(snapshot('nope')), nil)
check('空 players 是合法的', #expio.validate(snapshot({})).entries, 0)

-- ══ 正常一条 ══
local ok = expio.validate(snapshot({
    ['阿夏'] = {exp = {automation = 1234, promethium = 7}, stamina = {claimable = 3, balance = 250}},
}))
check('一名玩家', #ok.entries, 1)
check('玩家名', ok.entries[1].name, '阿夏')
check('给了的经验照收', ok.entries[1].exp.automation, 1234)
check('末位经验照收', ok.entries[1].exp.promethium, 7)
-- 【缺的键补 0 而不是留 nil】：留 nil 的话 ring_level 遍历 12 项时会对 nil 做算术。
check('没给的经验补 0', ok.entries[1].exp.logistic, 0)
check('可领取', ok.entries[1].claimable, 3)
check('余额', ok.entries[1].balance, 250)
check('干净数据没有坏字段', ok.bad_fields, 0)

-- ══ 脏数据：一律归 0 并计数，绝不写进 storage ══
local dirty = expio.validate(snapshot({
    ['a'] = {exp = {
        automation = -5,           -- 负数：经验没有负值的语义
        logistic = 0 / 0,          -- NaN：能通过除相等以外的所有比较
        military = math.huge,      -- 无穷：math.floor 之后仍是无穷
        chemical = 'lots',         -- 类型不对
        automations = 10,          -- 拼错的键，源文件里最常见的错误
    }},
}))
check('负数归 0', dirty.entries[1].exp.automation, 0)
check('NaN 归 0', dirty.entries[1].exp.logistic, 0)
check('无穷归 0', dirty.entries[1].exp.military, 0)
check('字符串归 0', dirty.entries[1].exp.chemical, 0)
-- 五个坏字段都要被数出来。静默忽略是最糟的：管理员看到"导入成功"就不会再查，
-- 而一个拼错的键意味着那项经验悄悄归了零。
check('坏字段全部计数', dirty.bad_fields, 5)

-- ══ 小数截断、缺失的体力 ══
local frac = expio.validate(snapshot({
    ['b'] = {exp = {automation = 10.9}},
}))
check('小数向下取整', frac.entries[1].exp.automation, 10)
check('没给体力则为 0', frac.entries[1].claimable, 0)
check('没给余额则为 0', frac.entries[1].balance, 0)

-- ══ 玩家名本身不合法 ══
local badname = expio.validate(snapshot({[''] = {exp = {}}}))
check('空名字被跳过', #badname.entries, 0)
check('空名字计入坏字段', badname.bad_fields, 1)

-- 断言真的都跑到了。这个自检是必须的：os.exit 就在下面几行，
-- 往文件末尾追加的断言曾经整段变成死代码，而汇总仍然报"全部通过"。
local declared = 0
for line in io.lines('tests/test_expio.lua') do
    if line:match('^%s*check%(') then declared = declared + 1 end
end
if total < declared then
    print(string.format('FAIL  只跑了 %d 条断言，文件里写了 %d 条', total, declared))
    failures = failures + 1
end

print(string.format('%d/%d 通过', total - failures, total))
os.exit(failures == 0 and 0 or 1)
