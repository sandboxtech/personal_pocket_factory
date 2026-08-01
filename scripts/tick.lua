-- 周期任务调度（相位调度器）+ GUI 点击路由。
--
-- 每类任务在 storage.cycle_next_at 里各自记一个"下次触发的 tick"，周期
-- （cycle_minutes）和相位间隔（cycle_phase_minutes）是两个独立配置项。
-- 不用取模是因为取模答不出"还要多久触发"，而传送页面的倒计时需要这个数。
--
-- 【1 分钟一次就够】：本场景没有任何东西变化快于一分钟（体力每分钟涨 1 点，
-- 倒计时全是分钟级）。所有任务都是"tick >= at 才触发"，放宽检查间隔只会让触发
-- 最多晚一分钟，不会漏判。
-- events 总线只包 script.on_event 不认 on_nth_tick，所以这里直接调，外面套 events.safe。
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
    -- 自动兑换是【唯一一个用自己周期】的任务：默认 1 分钟一次，其余任务仍走
    -- storage.cycle_minutes（60 分钟）。理由见 exp.tick_auto_convert 的注释 ——
    -- 在线玩家要的是"塞进收货箱的瓶子很快变成经验"这种即时反馈，一小时一次太迟钝。
    -- 代价是它会周期性地和星球重置撞在同一分钟（1 分钟的周期没法和任何东西错开），
    -- 但这个任务很轻（每人读一个箱子的库存），撞上也不会有卡顿尖峰。
    { key = 'auto_convert', phase_index = 2, period_key = 'auto_convert_minutes',
      fn = function() exp.tick_auto_convert() end },
    { key = 'ship_lifecycle', phase_index = 3, fn = function() ships.tick_lifecycle() end },
}

-- 需要被 UI 读到倒计时的任务，各自镜像一份到 storage 字段。
-- 本文件顶层 require 了 worlds，所以 worlds 不能反过来 require 本文件（模块级循环）——
-- 于是由调度器负责写，worlds 只管读，依赖方向保持单向。
local MIRRORED = {
    tech_loss = 'tech_loss_next_at',
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

-- HUD 刷新走和上面周期任务同一套"存下次触发 tick"写法。
local function ensure_hud_scheduled()
    if not storage.hud_next_refresh_at then
        storage.hud_next_refresh_at = game.tick + (storage.hud_refresh_ticks or 3600)
    end
end

script.on_nth_tick(3600, events.safe('nth_tick', function()
    local tick = game.tick
    storage.cycle_next_at = storage.cycle_next_at or {}

    -- 补齐新增的默认字段。【game.reload_script() 不触发 on_init 也不触发
    -- on_configuration_changed】，而那是本项目的实际更新方式，新增的 storage 字段
    -- 一个都不会被写进去 —— 后果还不是报错而是静默错误（starter_items 读出 nil，
    -- `or {}` 兜出空表，新玩家一件起手物资都拿不到）。
    -- 只补【缺失】的字段，不改管理员设过的值，也不更新老字段的旧值。
    constants.ensure_defaults()

    -- 大类周期任务：逐个检查是否到了各自的下次触发时刻（存 tick，不取模）。
    for _, task in ipairs(CYCLE_TASKS) do
        ensure_scheduled(task)
        local at = storage.cycle_next_at[task.key]
        if tick >= at then
            task.fn()
            -- 任务可以指定自己的周期字段（period_key），没指定就用全局的 cycle_minutes。
            local minutes = (task.period_key and storage[task.period_key])
                or storage.cycle_minutes or 60
            local period = minutes * constants.min_to_tick
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

    -- 公共世界重置不并入上面那套相位表：它是 per-planet 各自独立的周期。
    -- 预警要【每分钟都查】，不能塞进"到期才查"的分支 —— 它比重置早好几分钟触发。
    worlds.tick_warn()

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
