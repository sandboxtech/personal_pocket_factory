-- 管理员指令。全部注册在这里，方便一眼看全。
local pockets = require('scripts.pockets')
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
-- 丢的只有建筑和关联库存。和离线 50 小时那条规则完全一致，只是由管理员手动触发。
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

return M
