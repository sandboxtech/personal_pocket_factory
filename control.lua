-- 戴森环计划 scenario 入口。
-- 各子模块在 require 时自行通过 events 总线注册事件，这里只负责按依赖顺序加载 + 初始化。
require('scripts.players')
require('scripts.tick')
require('scripts.chests')
require('scripts.commands')
require('scripts.ships')          -- 飞船子系统：模块内部已在顶层订阅 on_surface_created
require('scripts.world_terrain')   -- 公共世界地貌斑块：模块内部已在顶层订阅 on_chunk_generated

-- 初始化那一套步骤全部搬进了 scripts/bootstrap.lua（三个调用方共用），
-- 所以这里只剩两个真正用得到的模块：涂砖的事件订阅，和初始化入口。
local events = require('scripts.events')
local ring = require('scripts.ring')
local bootstrap = require('scripts.bootstrap')

-- 区块生成时涂砖。走 events 总线而不是直接 script.on_event，避免和别处的订阅互相覆盖。
events.on(defines.events.on_chunk_generated, events.safe('chunk', ring.on_chunk_generated))

-- 第一次运行本场景时触发。
-- 【这两个事件和 /pw-repair 跑的是同一套步骤】，全部在 scripts/bootstrap.lua 里。
-- 抄三份的话，往后加一步就必然漏掉一两处，而漏掉的那处只在升级上来的老存档上出问题。
script.on_init(function()
    bootstrap.run(true)   -- 新开局：把五个世界的重置时刻均匀铺开
end)

-- 场景脚本变化后加载老存档时触发：补齐新增的默认字段，保证平滑升级。
-- 【注意它不是万能的】：这个事件只在 mod 列表/版本变化时触发，
-- 用 game.reload_script() 热替换脚本时【不会】触发（那条路靠 tick.lua 里
-- 每分钟一次的 ensure_defaults 兜底，以及管理员手动执行 /pw-repair）。
script.on_configuration_changed(function()
    bootstrap.run(false)  -- 已排期的世界保持原计划，只给新增的补排
end)
