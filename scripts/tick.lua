-- 周期任务调度（相位调度器）+ GUI 点击路由。
--
-- 用【显式相位】代替 v1 的互质质数取模（3607 / 3613 / 613）：
-- 老写法把"周期多长"和"错开多少"焊死在同一个数字里 —— 取模基数本身就是周期，
-- 想调周期，几件任务的错开关系就跟着全变了，而且从代码里根本读不出
-- "科技丢失和戴森环生命周期到底差几分钟触发"这种信息，得心算取模基数才知道。
--
-- 新写法：每类任务在 storage.cycle_next_at 里各自记一个"下次触发的 tick"，
-- 周期（storage.cycle_minutes）和相位间隔（storage.cycle_phase_minutes）是两个
-- 独立的配置项，改一个不影响另一个 —— "科技整点掉、戴森环 05 分查"是看得见的配置，
-- 不是质数取模那种"改一个动全身"的隐式安排。
-- 用"存下次触发 tick"而不是取模，是因为取模答不出"还要多久触发"，
-- 而 UI（传送页面的倒计时）需要这个信息。
--
-- 性能：本文件是全场景唯一的高频调度入口。原来挂在【每 tick 触发】的事件上，引擎每秒调 60 次 Lua。
-- 为什么 1 分钟就够：本场景【没有任何东西的变化快于一分钟】——
-- 体力每分钟涨 1 点，所有倒计时显示的都是分钟，周期任务本身也是小时级。
-- 比一分钟更勤地刷新，看到的永远是同一个数。
-- 改用 script.on_nth_tick(3600)（约 1 分钟一次）后 Lua 调用次数降到 1/3600，
-- 且不影响正确性：下面所有周期任务都是"维护一个下次触发 tick、tick >= at 才触发"的写法，
-- 不是取模判断，检查间隔从 1 tick 放宽到 3600 tick 只是让触发时刻最多晚约 1 分钟（3599/3600 秒），
-- 不会漏判、也不会因为跳过了某个 tick 而错过取模命中的那一刻。
-- events 总线（scripts/events.lua）目前只包住 script.on_event，不认 on_nth_tick，
-- 所以这里直接调 script.on_nth_tick，外面套一层 events.safe 保出错不崩服。
local events = require('scripts.events')
local pockets = require('scripts.pockets')
local worlds = require('scripts.worlds')
local constants = require('scripts.constants')
local gui = require('scripts.gui.init')
local exp = require('scripts.exp')
local ships = require('scripts.ships')

local M = {}

-- 周期任务表。每项：{ key, phase_index, fn }
--   周期统一是 storage.cycle_minutes（默认 60 分钟）；
--   第 i 项在这个周期内的第 i × storage.cycle_phase_minutes（默认 5 分钟）触发，
--   触发后下一次排在"这次的触发时刻 + 一个周期"，不是"现在 + 一个周期"，
--   避免因为某一 tick 处理慢/卡顿而让相位随时间慢慢漂移。
--
-- 加一个新的周期任务只需要在这里追加一行，不用改下面的调度逻辑，
-- 也不用手工挑一个"不会撞车"的取模常数 —— 相位序号本身就负责错开。
--
-- 相位 0/1/2/3 加上 2 分钟基础偏移后，落在每小时的第 2/7/12/17 分钟，
-- 和五个星球重置占用的 0/10/20/30/40 分全部错开（证明见 ensure_scheduled 的注释）。
local CYCLE_TASKS = {
    { key = 'tech_loss', phase_index = 0, fn = function() worlds.tick_tech_loss() end },
    { key = 'ring_lifecycle', phase_index = 1, fn = function() pockets.tick_lifecycle() end },
    { key = 'auto_convert', phase_index = 2, fn = function() exp.tick_auto_convert() end },
    { key = 'ship_lifecycle', phase_index = 3, fn = function() ships.tick_lifecycle() end },
}

-- 把 tech_loss 的下次触发时刻镜像进 storage.tech_loss_next_at 一份，
-- 供 worlds.tech_loss_time_left() 读（GUI 倒计时用）。
--
-- 为什么不让 worlds.tech_loss_time_left() 直接调 M.time_left('tech_loss')：
-- 本文件在模块顶层 require 了 worlds（调度 tick_tech_loss 要用到），
-- Factorio 又不允许在函数体内 require 来延迟绕开循环，所以 worlds 绝对不能
-- 反过来 require 本文件，否则就是模块级循环依赖。于是选择反方向的耦合：
-- 调度器（本文件）知道 worlds 那个字段的存在并负责写它，worlds 只管读，
-- 依赖方向保持单向（tick → worlds），不新增边。
-- 需要被 UI 读到倒计时的任务，各自镜像到一个 storage 字段。
-- 加一项就在这张表里加一行，不用改下面的调度逻辑。
local MIRRORED = {
    tech_loss = 'tech_loss_next_at',
    auto_convert = 'auto_convert_next_at',
}

local function sync_task_mirror(key, at)
    local field = MIRRORED[key]
    if field then storage[field] = at end
end

-- 排好某个任务的下一次触发 tick（仅当它还没排过期时，幂等）。
--
-- 加基础偏移（storage.cycle_base_offset_minutes）是为了和星球重置错开：
-- 星球重置占用 mod 60 的 0/10/20/30/40 分（见 worlds.lua 的 schedule_all），
-- 周期任务不加偏移的话相位 0/1/2 会落在 0/5/10 分，其中 0 分撞 nauvis、
-- 10 分撞 vulcanus。加 2 分钟偏移后落在 2/7/12 分，和五个星球的偏移全部错开，
-- 具体证明见 scripts/constants.lua 里 cycle_base_offset_minutes 旁的注释
-- 和 task-29-report.md 里的对照表。
local function ensure_scheduled(task)
    if not storage.cycle_next_at[task.key] then
        local base = (storage.cycle_base_offset_minutes or 2) * constants.min_to_tick
        local phase = (storage.cycle_phase_minutes or 5) * constants.min_to_tick
        local at = game.tick + base + phase * task.phase_index
        storage.cycle_next_at[task.key] = at
        sync_task_mirror(task.key, at)
    end
end

-- 某周期任务距下次触发还有多少 tick。没排期返回 nil。
-- 供 GUI 做倒计时用（取模没法回答这个问题，这也是改用显式相位的核心原因）。
function M.time_left(key)
    local at = storage.cycle_next_at and storage.cycle_next_at[key]
    if not at then return nil end
    return at - game.tick
end

-- HUD 刷新：原来是"取模"节流阀（tick % hud_refresh_ticks == 0）。
-- 检查频率从每 tick 降到每 3600 tick（调度器间隔）之后，613 这种模数更是完全不会命中
-- （game.tick 是 3600 的倍数时才检查，613 % 3600 ≠ 0，取模条件永不碰撞）。
-- 所以改成和上面周期任务同一套"存下次触发 tick"写法：不取模、直接比大小，
-- 检查频率再怎么降都不影响命中，只影响命中的时刻最多晚多少。
local function ensure_hud_scheduled()
    if not storage.hud_next_refresh_at then
        storage.hud_next_refresh_at = game.tick + (storage.hud_refresh_ticks or 3600)
    end
end

script.on_nth_tick(3600, events.safe('nth_tick', function()
    local tick = game.tick
    storage.cycle_next_at = storage.cycle_next_at or {}

    -- 大类周期任务：逐个检查是否到了各自的下次触发时刻（存 tick，不取模）。
    for _, task in ipairs(CYCLE_TASKS) do
        ensure_scheduled(task)
        local at = storage.cycle_next_at[task.key]
        if tick >= at then
            task.fn()
            local period = (storage.cycle_minutes or 60) * constants.min_to_tick
            local next_at = at + period   -- 从"这次该触发的时刻"累加，不从"现在"累加，防止相位漂移
            storage.cycle_next_at[task.key] = next_at
            sync_task_mirror(task.key, next_at)
        end
    end

    -- 原生建船按钮的闸门：幂等地重锁一次。
    -- 按钮的解锁是引擎内部行为，我没法从原型里枚举出全部会重新解锁它的路径
    -- （space-platform 科技只解锁配方，不管这个按钮），所以不枚举、直接每分钟压一遍。
    -- 代价是一次布尔判断，收益是无论哪条路径把它解开都最迟一分钟内被锁回去。
    ships.enforce_lock()

    -- 公共世界重置：不并入上面那套相位表 —— 它是 per-planet 各自独立的周期
    -- （见 constants.world_reset_minutes），不是"一类任务一个相位"这种形状。
    -- 但同样从"取模"改成"查下次触发时刻"：storage.world_reset_at 本来就是
    -- 这个形状（每个星球一个到期 tick），worlds.next_reset_at() 取其中最近的一个，
    -- 真到期了才调用 tick_check()，而不是像 v1 那样用一个和真实周期无关的
    -- 取模常数（3607）去隔几十秒抽查一次。
    local next_reset = worlds.next_reset_at()
    if next_reset and tick >= next_reset then
        worlds.tick_check()
    end

    -- HUD 刷新：见上面 ensure_hud_scheduled 的注释，同样是"下次触发 tick"写法。
    ensure_hud_scheduled()
    if tick >= storage.hud_next_refresh_at then
        for _, player in pairs(game.connected_players) do
            gui.refresh_hud(player)
        end
        storage.hud_next_refresh_at = tick + (storage.hud_refresh_ticks or 3600)
    end
end))

events.on(defines.events.on_gui_click, events.safe('gui_click', function(event)
    gui.on_click(event)
end))

return M
