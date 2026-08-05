-- 全服总览：一页看全所有戴森环，以及每条环的主人名下那艘飞船。
--
-- 这一页取代了原来散在传送窗口里的「大家的戴森环」列表。合并的理由是它们回答的是
-- 同一个问题 ——「服务器上现在有谁、他们各自处在什么状态、我能去哪」。
-- 拆在两处的话，玩家要先点传送看环、再猜飞船在哪儿看，而飞船和环本来就是同一个人的两处资产。
--
-- 列表取的是【有环 或 有船】的玩家并集，不是只看有环的：
-- 环被回收（离线超时）但船还在的人，不该从这一页上凭空消失 —— 那正是别人最想知道
-- 「这人是不是快回来了」的时候。
--
-- ══ 分级披露 ══
-- 全员看得到：玩家名、在线/离线、有没有船、能不能进、前往按钮。
-- 仅老玩家（util.is_veteran）看得到：等级、环长、累计在线时长、离线小时数、飞船剩余寿命。
-- 新人需要的是「服务器上有人、我能去串门」这个事实，那一堆数字对他没有可操作性。
local constants = require('scripts.constants')
local pockets = require('scripts.pockets')
local ships = require('scripts.ships')
local util = require('scripts.util')
local popup = require('scripts.gui.popup')

local M = {}

-- 拆船确认的有效期。短到玩家不会在别的操作之后误点到一个还举着的按钮，
-- 长到足够看清按钮文字变了再点第二下。
--
-- 【必须声明在 render_my_ship 之前】：Lua 的 local 只对声明之后的代码可见，
-- 写在后面的话函数里读到的是同名全局（nil），要等真的点开窗口才炸。
-- tests/check_globals.sh 就是查这个的。
local SCUTTLE_WINDOW_TICKS = 60 * 10

-- 把环列表、船列表按主人对齐成一张表，顺带把无主飞船单独拣出来。
-- 返回 rows（每项 {player, ring, ship}）和 unowned（无主飞船数组）。
local function build_rows()
    local rings = {}
    for _, entry in ipairs(pockets.all_rings()) do
        rings[entry.owner_name] = entry
    end

    local owned, unowned = {}, {}
    for _, ship in ipairs(ships.all()) do
        if ship.owner then owned[ship.owner] = ship else unowned[#unowned + 1] = ship end
    end

    local rows = {}
    for _, player in pairs(game.players) do
        local ring_entry, ship_entry = rings[player.name], owned[player.name]
        -- 环已回收并进入永久删除队列的离线玩家不再展示。这里显式过滤，避免
        -- Surface 或飞船的异步删除尚未结算时，旧登记让玩家短暂重新出现在列表里。
        if not pockets.is_player_pending_cleanup(player) and (ring_entry or ship_entry) then
            rows[#rows + 1] = {player = player, ring = ring_entry, ship = ship_entry}
        end
    end

    -- 在线的排前面，其次按累计在线时长降序，同分再按名字。
    -- 【最后那条按名字的比较不是装饰】：table.sort 的比较函数必须给出全序，
    -- 否则相等元素的先后取决于排序算法内部状态，多人下各客户端可能排出不同顺序。
    -- 本项目是单 force、GUI 又是各客户端各自渲染的，排序不参与游戏状态，
    -- 但让它确定下来不花任何代价，而且省得以后有人把这份顺序拿去写进 storage。
    table.sort(rows, function(a, b)
        if a.player.connected ~= b.player.connected then return a.player.connected end
        -- 同样走快照：万一 game.reset_time_played() 会清 online_time，
        -- 直接读它会让全服排序在每轮 Nauvis 重置后集体塌成按名字排。
        local ta, tb = util.played_hours(a.player), util.played_hours(b.player)
        if ta ~= tb then return ta > tb end
        return a.player.name < b.player.name
    end)

    return rows, unowned
end

-- 顶部一段：自己的飞船 / 造船入口。放在总览页而不是传送页，
-- 是为了让「看船」和「造船」在同一个地方，不用记住两个入口。
local function render_my_ship(container, player)
    local head = container.add{type = 'flow', direction = 'horizontal'}
    head.style.vertical_align = 'center'

    local platform, record = ships.of(player)
    if platform then
        local left = math.floor(math.max(0, ships.left_ticks(record)) / constants.hour_to_tick)
        if ships.is_ready(platform) then
            head.add{type = 'label', caption = {'pw.overview-my-ship', platform.name, left}}
        else
            head.add{type = 'label', caption = {'pw.overview-my-ship-waiting', platform.name}}
        end

        -- 拆船：两步确认。第一次点只是"举起"，第二次点才真拆。
        --
        -- 单步就拆太危险：船上所有东西跟着一起没，而且不可撤销。
        -- 但也不想为此开一个模态确认框——本页已经是个弹窗，再叠一层弹窗更难用。
        -- 折中是让按钮自己变成确认态，有效期很短（storage.ship_scuttle_armed 记时刻），
        -- 过期自动作废，玩家不会在几分钟后误点到一个还举着的按钮。
        storage.ship_scuttle_armed = storage.ship_scuttle_armed or {}
        local armed_at = storage.ship_scuttle_armed[player.name]
        local armed = armed_at and (game.tick - armed_at) < SCUTTLE_WINDOW_TICKS

        local scuttle = head.add{type = 'button', name = 'pw_ov_scuttle',
                                 caption = {armed and 'pw.overview-scuttle-confirm' or 'pw.overview-scuttle'}}
        scuttle.tooltip = {armed and 'pw.overview-scuttle-confirm-tip' or 'pw.overview-scuttle-tip'}
    else
        head.add{type = 'button', name = 'pw_ov_build', caption = {'pw.overview-build-ship'},
                 tooltip = {'pw.overview-build-ship-tip', constants.SHIP_STAMINA_COST}}
        head.add{type = 'label', caption = {'pw.overview-no-ship-hint'}}
    end
end

-- 按钮上的图标。纯图标 + tooltip，不放文字：
-- 一行要塞下操作、名字、状态、环的数据、飞船，文字按钮会把这一行撑得很宽，
-- 人数一多就得横向滚动 —— 而横向滚动是列表类界面里最难用的东西。
-- 这也和屏幕最上方那排纯图标传送按钮的做法一致（见 gui/hud.lua）。
local RING_ICON = '[space-location=solar-system-edge]'

-- 一位玩家【一行】，四个单元格填进外面传进来的 table：操作 / 名字状态 / 环 / 飞船。
--
-- 用 table 而不是每人一个 frame，是为了【跨行对齐】：扫一列就能比较所有人的等级或
-- 飞船寿命，而一堆各自为政的 frame 只能一个一个读。人多的时候这个差别很大。
--
-- 【每行必须正好填满 column_count 个单元格】——某一列在当前条件下没内容时也要塞一个
-- empty-widget 占位，否则后面所有行都会串列。
local function render_row(grid, viewer, row)
    local veteran = util.is_veteran(viewer)
    local player = row.player
    local ring_entry, ship = row.ring, row.ship

    -- ① 操作：能去的地方各一颗图标按钮
    local actions = grid.add{type = 'flow', direction = 'horizontal'}
    actions.style.vertical_align = 'center'
    actions.style.horizontal_spacing = 2

    if ring_entry then
        local go = actions.add{type = 'button', style = 'tool_button',
                               name = 'pw_ov_ring_' .. ring_entry.owner_index, caption = RING_ICON}
        go.tooltip = {'pw.overview-go-ring-tip'}
        if not ring_entry.enterable then
            go.enabled = false
            -- 还差多久才可进入。阈值因人而异（新人按在线时长缩放，见 pockets.public_threshold），
            -- 所以用这位主人自己的 public_hours 现算，不能甩一个全服统一的数字。
            go.tooltip = {'pw.overview-ring-locked',
                math.max(0, math.floor(ring_entry.public_hours - ring_entry.idle_hours))}
        end
    end

    -- ② 名字 + 在线状态
    local who = grid.add{type = 'flow', direction = 'horizontal'}
    who.style.vertical_align = 'center'
    who.add{type = 'label', caption = {'pw.overview-name', player.name}}
    if player.connected then
        who.add{type = 'label', caption = {'pw.overview-online'}}
    elseif veteran and ring_entry then
        who.add{type = 'label', caption = {'pw.overview-offline', ring_entry.idle_hours}}
    else
        who.add{type = 'label', caption = {'pw.overview-offline-plain'}}
    end

    -- ③ 环的细节：只给老玩家。新人知道「这人有条环、能不能进」就够了。
    if ring_entry and veteran then
        -- 和阈值缩放读同一个来源，否则界面显示的时长会和实际保护时长对不上。
        local played = math.floor(util.played_hours(player))
        grid.add{type = 'label', caption = {'pw.overview-ring-detail',
            ring_entry.level, ring_entry.half_length * 2, played}}
    else
        grid.add{type = 'empty-widget'}
    end

    -- ④ 飞船。剩余寿命和环长一样归入「老玩家才看」。
    if ship then
        grid.add{type = 'label', caption = veteran
            and {'pw.overview-ship-detail', ship.platform.name, ship.left_hours}
            or  {'pw.overview-ship-plain', ship.platform.name}}
    else
        grid.add{type = 'empty-widget'}
    end
end

-- 无主飞船只展示信息，不提供直接传送入口。
local function render_ship_list(container, viewer, list)
    local grid = container.add{type = 'table', column_count = 1}
    grid.style.horizontal_spacing = 8
    grid.style.vertical_spacing = 2
    local veteran = util.is_veteran(viewer)
    for _, ship in ipairs(list) do
        grid.add{type = 'label', caption = veteran
            and {'pw.overview-ship-detail', ship.platform.name, ship.left_hours}
            or  {'pw.overview-ship-plain', ship.platform.name}}
    end
end

local function render_public_ring_list(container, list)
    local grid = container.add{type = 'table', column_count = 2}
    grid.style.horizontal_spacing = 8
    grid.style.vertical_spacing = 2
    for _, public_ring in ipairs(list) do
        local go = grid.add{type = 'button', style = 'tool_button',
                            name = 'pw_ov_public_' .. public_ring.id, caption = RING_ICON}
        go.tooltip = {'pw.overview-go-public-ring-tip'}
        grid.add{type = 'label', caption = {'pw.overview-public-ring-detail',
            public_ring.original_owner or public_ring.name, public_ring.left_hours}}
    end
end

function M.show(player)
    local inner = popup.open_popup(player, {'pw.overview-title'})

    -- 「我的飞船 / 造船」钉在滚动区【外面】：这是本页唯一属于你自己的操作，
    -- 翻到第 30 个人时也不该把它滚出视野。
    render_my_ship(inner, player)
    inner.add{type = 'line', direction = 'horizontal'}

    local scroll = inner.add{type = 'scroll-pane', name = 'pw_ov_scroll', direction = 'vertical'}
    scroll.style.width = popup.WIDTH - 12
    scroll.style.maximal_height = 560

    local rows, unowned = build_rows()
    local public_rings = pockets.public_rings()
    if #rows == 0 and #public_rings == 0 and #unowned == 0 then
        scroll.add{type = 'label', caption = {'pw.overview-empty'}}
    elseif #rows > 0 then
        -- 一位玩家一行，四列对齐。人多了由 scroll-pane 纵向滚动，
        -- 横向绝不滚：所有单元格的内容都是短的（图标按钮 / 名字 / 几个数字）。
        local grid = scroll.add{type = 'table', name = 'pw_ov_grid', column_count = 4}
        grid.style.horizontal_spacing = 8
        grid.style.vertical_spacing = 2
        for _, row in ipairs(rows) do
            render_row(grid, player, row)
        end
    end

    if #public_rings > 0 then
        if #rows > 0 then scroll.add{type = 'line', direction = 'horizontal'} end
        scroll.add{type = 'label', caption = {'pw.overview-public-rings-head'}}
        render_public_ring_list(scroll, public_rings)
    end

    -- 无主飞船：玩家从火箭井原生造的平台，脚本不知道主人是谁。
    -- 仍然列出来（它们照样占着服务器、照样会到期销毁），只是没有「主人」这一栏。
    if #unowned > 0 then
        scroll.add{type = 'line', direction = 'horizontal'}
        scroll.add{type = 'label', caption = {'pw.overview-unowned-head'}}
        render_ship_list(scroll, player, unowned)
    end
end

-- 进别人的戴森环。原来住在 travel.lua 里，随列表一起搬过来。
local function visit_ring(player, owner_index)
    local owner = game.players[owner_index]
    local surface = owner and pockets.get(owner)
    if not (surface and surface.valid) then
        player.print({'pw.travel-ring-gone'})
        return
    end

    -- 再校验一次门槛：按钮可能是在阈值改动前渲染的，也可能主人刚上线。
    -- UI 的 enabled 只是提示，真正的闸门在这里。
    if pockets.idle_hours(owner) < (pockets.public_threshold(owner) / constants.hour_to_tick) then
        player.print({'pw.travel-ring-locked-msg', owner.name})
        return
    end

    -- 惰性公共化：有人真的走进来的那一刻才切 link_id，不必等周期扫描。make_public 幂等。
    pockets.make_public(owner)

    local pos = surface.find_non_colliding_position('character', constants.RING_SPAWN, 64, 1)
        or constants.RING_SPAWN
    player.teleport(pos, surface)
end

function M.on_click(player, name)
    if name == 'pw_ov_build' then
        local platform, err = ships.create(player)
        if not platform then
            if err == 'pw.ship-no-stamina' then
                player.print({err, constants.SHIP_STAMINA_COST})
            else
                player.print({err or 'pw.ship-create-failed'})
            end
        end
        M.show(player)   -- 无论成败都重开，玩家立刻看到最新状态
        return true
    end

    if name == 'pw_ov_scuttle' then
        storage.ship_scuttle_armed = storage.ship_scuttle_armed or {}
        local armed_at = storage.ship_scuttle_armed[player.name]
        if armed_at and (game.tick - armed_at) < SCUTTLE_WINDOW_TICKS then
            storage.ship_scuttle_armed[player.name] = nil
            -- 拆的永远是【调用者自己】名下那艘：ships.scuttle 只收一个 player 参数，
            -- 没有"按 index 拆"的入口，越权在签名层面就不成立。
            if not ships.scuttle(player) then
                player.print({'pw.overview-ship-gone'})
            end
        else
            storage.ship_scuttle_armed[player.name] = game.tick
        end
        M.show(player)
        return true
    end

    local owner_index = string.match(name, '^pw_ov_ring_(%d+)$')
    if owner_index then
        visit_ring(player, tonumber(owner_index))
        popup.close_popup(player)
        return true
    end

    local public_id = string.match(name, '^pw_ov_public_(%d+)$')
    if public_id then
        if not pockets.enter_public_ring(player, tonumber(public_id)) then
            player.print({'pw.travel-ring-gone'})
        end
        popup.close_popup(player)
        return true
    end

    return false
end

return M
