-- 管理员指令。全部注册在这里，方便一眼看全。
local pockets = require('scripts.pockets')

local M = {}

-- /ring-delete <玩家名>
--
-- 删除指定玩家的戴森环表面。经验一点不动 —— 玩家下次上线时环按经验立刻恢复到原样，
-- 丢的只有建筑和关联库存。和离线 50 小时那条规则完全一致，只是由管理员手动触发。
--
-- 目标在线时【拒绝执行】。删表面必然要处理「人在里面怎么办」，
-- 而任何处理方式都是在玩家没有心理准备时动他的世界。
-- 拒绝执行把这个决定推回给管理员：想删就先请人下线。
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
    for _, p in pairs(game.connected_players) do
        if p.admin and p ~= caller then
            p.print({'pw.cmd-ring-deleted-broadcast', target_name, who})
        end
    end
end)

-- /ring-repair
--
-- 把所有已存在的戴森环重新过一遍 ensure，补齐缺失的部分。
-- 存在的理由：曾经有一版代码在建环中途抛错（隐藏 surface 的参数写反），
-- 环建出来了、地板也涂好了，唯独 12 个收货箱没建，而老的 ensure 一见环存在就直接返回，
-- 这类半成品环永远修不好。现在 ensure 幂等自愈，这条指令只是给管理员一个
-- 不必让所有人重连就能全服扫一遍的入口。
--
-- 不会新建任何环（见 pockets.repair_all），所以对已按规则回收掉的环没有副作用。
commands.add_command('ring-repair', {'pw.cmd-ring-repair-help'}, function(command)
    local caller = command.player_index and game.players[command.player_index]
    if caller and not caller.admin then
        caller.print({'pw.cmd-admin-only'})
        return
    end

    local count = pockets.repair_all()
    local msg = {'pw.cmd-ring-repaired', count}
    if caller then caller.print(msg) else game.print(msg) end
end)

return M
