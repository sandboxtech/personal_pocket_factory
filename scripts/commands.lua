-- 管理员指令。全部注册在这里，方便一眼看全。
local pockets = require('scripts.pockets')
local constants = require('scripts.constants')
-- bootstrap 里 require 的那几个模块（players/worlds/ships/pockets/constants）
-- 没有一个反向 require commands，顶层 require 不成环。
local bootstrap = require('scripts.bootstrap')
local expio = require('scripts.expio')
local ring = require('scripts.ring')
-- gui.init 只 require 各个 gui 子模块，它们依赖 constants/util/pockets 一类的叶子模块，
-- 没有一个反向 require commands，顶层 require 不成环。
local gui = require('scripts.gui.init')
-- gui.config 只 require constants 和 gui.popup，两者都不反向依赖 commands，顶层 require 不成环。
local config_gui = require('scripts.gui.config')

local M = {}

-- 只给调用者看的回复。从服务器控制台执行时没有 caller，退回 game.print。
local function replier(command)
    local caller = command.player_index and game.players[command.player_index]
    return caller, function(msg)
        if caller then caller.print(msg) else game.print(msg) end
    end
end

-- 管理员闸门。返回 caller 和 reply，非管理员返回 nil。
-- 单人游戏从控制台执行时 caller 为 nil，一律放行（那本来就是主机自己）。
local function admin_gate(command)
    local caller, reply = replier(command)
    if caller and not caller.admin then
        caller.print({'pw.cmd-admin-only'})
        return nil
    end
    return caller, reply
end

-- /pw-config
--
-- 打开管理员配置总览窗口：所有可热改的参数、当前值、【改了什么时候生效】、一句话说明。
-- 内容和渲染都在 scripts/gui/config.lua，这里只负责鉴权和开窗。
--
-- 早先这条指令是往聊天框里逐行打的，31 个配置项一次刷出来会把之前的消息全顶掉，
-- 还没法回滚和复制。配置这种"对照着看、挑一个抄出来改"的东西天生需要一个可滚动的表格。
commands.add_command('pw-config', {'pw.cmd-config-help'}, function(command)
    local caller, reply = admin_gate(command)
    if not reply then return end
    if not caller then
        -- 从服务器控制台执行时没有玩家可以开窗口
        reply({'pw.cmd-config-console'})
        return
    end
    config_gui.show(caller)
end)

-- /ring-delete <玩家名>
--
-- 删除指定玩家的戴森环表面。经验一点不动 —— 玩家下次进环时按经验立刻恢复到原样，
-- 丢的只有建筑和关联库存。和离线超时删除那条规则完全一致，只是由管理员手动触发。
--
-- 【目标在不在线都照做】。老版本对在线目标拒绝执行，前提是「删表面必然要处理
-- 人在里面怎么办」——而这个前提是错的：引擎自己会处理站在被删表面上的角色，
-- 玩家随后走正常复活流程，本场景又把复活接管成「一律回自己的环」
-- （players.lua 的 on_player_respawned，环没了就当场重建）。
-- 既然没有需要脚本收拾的烂摊子，那条拒绝就只是让指令行为变得难以预期。
commands.add_command('ring-delete', {'pw.cmd-ring-delete-help'}, function(command)
    local caller = command.player_index and game.players[command.player_index]
    if caller and not caller.admin then
        caller.print({'pw.cmd-admin-only'})
        return
    end

    local function reply(msg)
        if caller then caller.print(msg) else game.print(msg) end
    end

    local target_name = command.parameter and string.match(command.parameter, '^%s*(.-)%s*$')
    if not target_name or target_name == '' then
        reply({'pw.cmd-ring-delete-usage'})
        return
    end

    local target = game.players[target_name]
    if not target then
        reply({'pw.cmd-no-player', target_name})
        return
    end

    local ok, err = pockets.delete_ring(target)
    if not ok then
        reply({err or 'pw.cmd-no-ring'})
        return
    end

    reply({'pw.cmd-ring-deleted', target_name})
    local who = caller and caller.name or {'pw.console-label'}

    -- 【当事人在线的话，必须告诉他】。
    -- 老版本对在线目标直接拒绝执行，所以不存在这个问题；那条限制去掉之后，
    -- 一个在环里的人会随表面删除而死亡、然后在重新长出来的空环里复活，
    -- 全程没有任何解释 —— 从他的视角看就是"莫名其妙死了一次，工厂全没了"。
    -- 这条提示不是礼貌，是让一个不可撤销的操作至少有个来源可查。
    if target.connected then
        target.print({'pw.ring-deleted-by-admin', who})
    end

    for _, p in pairs(game.connected_players) do
        if p.admin and p ~= caller then
            p.print({'pw.cmd-ring-deleted-broadcast', target_name, who})
        end
    end
end)

-- /ring-delete-all [confirm]
--
-- 删掉全服所有玩家的戴森环。经验一点不动，没的只有建筑和关联库存 ——
-- 每个人下次点回环按钮时，环按他的经验立刻长回原来的宽度。用于赛季重置。
--
-- 【不带参数只做预览，不删任何东西】。Factorio 控制台没有撤销，而这条指令一次抹掉
-- 全服所有人的工厂，破坏面比 /ring-delete 大一个数量级，值得多按一次回车。
--
-- 【一视同仁，不跳过在线玩家】。一个「号称删除所有、实际悄悄跳过在线玩家」的指令
-- 最危险：管理员以为重置完了，其实没有。要么全做要么不做，中间状态最坑人。
-- 当时在环里的人会随表面删除而死亡，然后正常复活回自己（重新长出来的）环里，
-- 这条路径不需要脚本额外做什么，见 pockets.delete_all_rings 的注释。
--
-- 预览里仍然单独报一下「其中几条的主人在线」——不是因为要区别对待，
-- 而是那几个人会当场掉背包，管理员按下 confirm 前有权知道这件事。
commands.add_command('ring-delete-all', {'pw.cmd-ring-delete-all-help'}, function(command)
    local caller = command.player_index and game.players[command.player_index]
    if caller and not caller.admin then
        caller.print({'pw.cmd-admin-only'})
        return
    end

    local function reply(msg)
        if caller then caller.print(msg) else game.print(msg) end
    end

    local rings = pockets.all_rings()
    if #rings == 0 then
        reply({'pw.cmd-ring-delete-all-none'})
        return
    end

    local arg = command.parameter and string.match(command.parameter, '^%s*(%S*)')
    if arg ~= 'confirm' then
        local online = 0
        for _, entry in ipairs(rings) do
            local owner = game.players[entry.owner_index]
            if owner and owner.connected then online = online + 1 end
        end
        reply({'pw.cmd-ring-delete-all-preview', #rings, online})
        return
    end

    local deleted = pockets.delete_all_rings()
    local who = caller and caller.name or {'pw.console-label'}
    game.print({'pw.cmd-ring-delete-all-done', deleted, who})
end)

-- /pw-repair
--
-- 幂等地把世界重新弄成「它应该有的样子」：补齐缺失的配置默认值、重建权限组、
-- 解锁星图全部地点、锁回原生建船按钮、补建缺失的公共世界 surface、
-- 把每颗星球的地图设置还原到原型状态再叠加矿脉倍率、把每条已存在的戴森环重新 ensure 一遍。
--
-- 【为什么需要这条指令】：这些步骤平时挂在 on_init 和 on_configuration_changed 上，
-- 但本项目的实际更新方式是「只替换 scenario 目录里的 lua 文件，再 game.reload_script()」——
-- reload_script 重新加载脚本、重新注册事件，却【不触发这两个事件中的任何一个】。
-- 于是新版本新增的字段、新增的初始化步骤全都不会跑，症状是静默的功能缺失
-- （典型：新玩家一件起手物资都拿不到，因为 storage.starter_items 是 nil）。
--
-- 不需要 confirm：每一步都是幂等的补齐动作，不删任何东西、不覆盖任何管理员改过的值。
-- 想把改乱的参数推回默认值是另一回事，那条路是 /pw-reset-config，它要 confirm。
commands.add_command('pw-repair', {'pw.cmd-repair-help'}, function(command)
    local caller, reply = admin_gate(command)
    if not reply then return end

    local result = bootstrap.run(false)   -- false：绝不重排已有世界的重置时刻
    reply({'pw.cmd-repair-done', result.rings, result.planets})

    -- 全服播报：修复会顺手改动所有人的环（补收货箱、改列表里的显示名），
    -- 别人正好在场时该知道这是管理员干的，而不是自己遇到了什么灵异现象。
    local who = caller and caller.name or {'pw.console-label'}
    game.print({'pw.cmd-repair-broadcast', who})
end)

-- /pw-reset-config [confirm]
--
-- 把【所有可调参数】推回默认值。玩家进度（经验、体力、戴森环、飞船、排期）一律不动 ——
-- 清空名单严格取自 constants.TUNABLES / TUNABLE_TABLES 两张表，运行时状态不在其中。
--
-- 要 confirm，而 /pw-repair 不要：这条会【覆盖】管理员自己调过的每一个值，
-- 是真正会丢东西的操作（丢的是调参，不是存档）。不加参数只打印预览。
commands.add_command('pw-reset-config', {'pw.cmd-reset-config-help'}, function(command)
    local caller, reply = admin_gate(command)
    if not reply then return end

    local arg = command.parameter and string.match(command.parameter, '^%s*(%S*)')
    if arg ~= 'confirm' then
        -- 预览先报「有几项和默认值不同」——管理员真正想知道的是"这一下会改掉多少东西"，
        -- 而不是"总共有多少项配置"。两个数一起给，差值本身就说明了影响面。
        reply({'pw.cmd-reset-config-preview', constants.diverged_count(), constants.tunable_count()})
        return
    end

    local n = constants.reset_tunables()
    local who = caller and caller.name or {'pw.console-label'}
    game.print({'pw.cmd-reset-config-done', n, who})
end)

-- /pw-export
--
-- 把全部玩家进度（12 项经验 + 体力）写进 script-output：
--   pw-progress-<tick>.json  给人看、给外部工具用
--   exp_import.lua           直接就是导入文件，复制进 scenario 目录即可，不用改名
--
-- 【按玩家名导出，不是按在线玩家】：storage 一律按名字索引，里面很可能有已经不在
-- game.players 里的名字（换服、删档、改名前的旧记录）。导出的意义正是保住这些。
commands.add_command('pw-export', {'pw.cmd-export-help'}, function(command)
    local caller, reply = admin_gate(command)
    if not reply then return end

    -- 有调用者就写到他自己那台机器上（"导出到本地"的本意），
    -- 从服务器控制台执行则传 0，只写服务器那份。
    local result = expio.write(caller and caller.index or 0)
    if not result then
        reply({'pw.cmd-export-none'})
        return
    end
    reply({'pw.cmd-export-done', result.count, result.json_name, result.lua_name})
end)

-- /pw-import [confirm]
--
-- 从 scenario 目录里的 exp_import.lua 恢复进度。
--
-- 【为什么要先 reload_script】：引擎【没有运行时读文件的 API】，scenario 读磁盘
-- 只有"加载阶段 require"这一条路。所以文件是在脚本加载那一刻被读进来的，
-- 刚复制进去还没重新加载脚本时，这条指令看到的仍是 nil（或上一次的旧内容）。
-- 完整流程：复制文件 → /c game.reload_script() → /pw-import → /pw-import confirm。
--
-- 要 confirm：这是【覆盖】不是合并，会把文件里每个玩家的经验和体力整个替换掉。
commands.add_command('pw-import', {'pw.cmd-import-help'}, function(command)
    local caller, reply = admin_gate(command)
    if not reply then return end

    local result = expio.pending()
    if not result then
        reply({'pw.cmd-import-none'})
        return
    end

    local arg = command.parameter and string.match(command.parameter, '^%s*(%S*)')
    if arg ~= 'confirm' then
        reply({'pw.cmd-import-preview', #result.entries,
            expio.known_count(result), result.bad_fields})
        return
    end

    local n = expio.apply(result)

    -- 经验变了，环宽就得跟着变。只对在线玩家立刻重涂：离线玩家的环下次进去时
    -- pockets.ensure 会按新等级把地涂好，现在去动一个没人在的表面没有意义。
    -- HUD 同理，顺手刷一次，免得数字停在导入之前的旧值上。
    for _, entry in ipairs(result.entries) do
        local player = game.players[entry.name]
        if player and player.valid and player.connected then
            ring.apply_growth(player)
            gui.refresh_hud(player)
        end
    end

    local who = caller and caller.name or {'pw.console-label'}
    game.print({'pw.cmd-import-done', n, who})
end)

return M
