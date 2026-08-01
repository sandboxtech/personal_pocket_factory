-- 管理员指令。全部注册在这里，方便一眼看全。
local constants = require('scripts.constants')
local pockets = require('scripts.pockets')

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

-- 把一个 storage 值渲染成【能直接粘回控制台】的 Lua 字面量。
-- 字符串要带引号、布尔要是 true/false —— 少了这层，管理员照着显示的值抄一遍
-- 会写出 storage.ship_home_planet = nauvis 这种把星球名当全局变量读的语句（值是 nil）。
local function literal(value)
    if type(value) == 'string' then return "'" .. value .. "'" end
    return tostring(value)
end

-- /pw-config [关键词]
--
-- 列出所有可热改的参数：当前值、一句话说明、以及照抄就能用的 /sc 语句。
-- 数据源是 constants.TUNABLES / TUNABLE_TABLES —— 和 ensure_defaults 读的是同一张表，
-- 所以这里列出来的东西不可能和实际生效的默认值脱节。
--
-- 带关键词时只显示字段名或分组名包含该词的项。27 个标量一次全刷出来对聊天框是个负担，
-- 而管理员多半是冲着某一类来的（"体力上限多少来着"），给个过滤比分页实在。
commands.add_command('pw-config', {'pw.cmd-config-help'}, function(command)
    local caller, reply = admin_gate(command)
    if not reply then return end

    local filter = command.parameter and string.lower(string.match(command.parameter, '^%s*(%S*)') or '')
    if filter == '' then filter = nil end

    reply({'pw.cmd-config-head'})

    local shown = 0
    for _, group in ipairs(constants.TUNABLE_GROUPS) do
        local rows = {}

        for _, item in ipairs(constants.TUNABLES) do
            if item.group == group and (not filter or string.find(string.lower(item.key), filter, 1, true)) then
                rows[#rows + 1] = {'pw.cmd-config-row', item.key,
                    literal(storage[item.key]), {'pw.cfg-' .. string.gsub(item.key, '_', '-')}}
            end
        end
        for _, item in ipairs(constants.TUNABLE_TABLES) do
            if item.group == group and (not filter or string.find(string.lower(item.key), filter, 1, true)) then
                rows[#rows + 1] = {'pw.cmd-config-row-table', item.key, item.example,
                    {'pw.cfg-' .. string.gsub(item.key, '_', '-')}}
            end
        end

        -- 组标题只在这一组真有内容时才打，否则加了关键词之后会刷出一串空组
        if #rows > 0 then
            reply({'pw.cmd-config-group', {'pw.cfg-group-' .. group}})
            for _, row in ipairs(rows) do
                reply(row)
                shown = shown + 1
            end
        end
    end

    if shown == 0 then
        reply({'pw.cmd-config-none', filter or ''})
    end
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
