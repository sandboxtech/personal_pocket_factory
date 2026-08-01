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
-- 仅老玩家（util.is_veteran）看得到：等级、环宽、累计在线时长、离线小时数、飞船剩余寿命。
-- 新人需要的是「服务器上有人、我能去串门」这个事实，那一堆数字对他没有可操作性。
local constants = require('scripts.constants')
local pockets = require('scripts.pockets')
local ships = require('scripts.ships')
local util = require('scripts.util')
local popup = require('scripts.gui.popup')

local M = {}

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
        if ring_entry or ship_entry then
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
        local ta, tb = a.player.online_time or 0, b.player.online_time or 0
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
        head.add{type = 'button', name = 'pw_ov_ship_' .. platform.index,
                 caption = {'pw.overview-go-ship'}}
        head.add{type = 'label', caption = {'pw.overview-my-ship', platform.name, left}}
    else
        local build = head.add{type = 'button', name = 'pw_ov_build',
                               caption = {'pw.overview-build-ship'}}
        head.add{type = 'label', caption = {'pw.overview-no-ship-hint'}}
        -- 起步包不在背包里就先禁掉按钮，把「为什么点不了」写进 tooltip，
        -- 而不是让玩家点一次、吃一条报错才知道。真正的闸门仍在 ships.create 里。
        if storage.ship_require_starter_pack ~= false
                and player.get_item_count('space-platform-starter-pack') < 1 then
            build.enabled = false
            build.tooltip = {'pw.ship-no-pack'}
        end
    end
end

-- 一位玩家一行（其实是一个小 frame，里面三到四行）。
local function render_row(container, viewer, row)
    local veteran = util.is_veteran(viewer)
    local player = row.player
    local ring_entry, ship = row.ring, row.ship

    local frame = container.add{type = 'frame', direction = 'vertical'}
    frame.style.horizontally_stretchable = true

    -- ① 名字 + 在线状态
    local head = frame.add{type = 'flow', direction = 'horizontal'}
    head.style.vertical_align = 'center'
    head.add{type = 'label', caption = {'pw.overview-name', player.name}}
    if player.connected then
        head.add{type = 'label', caption = {'pw.overview-online'}}
    elseif veteran and ring_entry then
        head.add{type = 'label', caption = {'pw.overview-offline', ring_entry.idle_hours}}
    else
        head.add{type = 'label', caption = {'pw.overview-offline-plain'}}
    end

    -- ② 环的细节：只给老玩家。新人知道「这人有条环、能不能进」就够了。
    if ring_entry and veteran then
        local played = math.floor((player.online_time or 0) / constants.hour_to_tick)
        frame.add{type = 'label', caption = {'pw.overview-ring-detail',
            ring_entry.level, ring_entry.half_width * 2, played}}
    end

    -- ③ 飞船那一行。剩余寿命是个需要规划的数字（要不要现在上去搬东西），
    -- 所以和环宽一样归入「老玩家才看」。
    if ship then
        if veteran then
            frame.add{type = 'label', caption = {'pw.overview-ship-detail',
                ship.platform.name, ship.left_hours}}
        else
            frame.add{type = 'label', caption = {'pw.overview-ship-plain', ship.platform.name}}
        end
    end

    -- ④ 按钮行
    local actions = frame.add{type = 'flow', direction = 'horizontal'}
    actions.style.vertical_align = 'center'

    if ring_entry then
        local go = actions.add{type = 'button', name = 'pw_ov_ring_' .. ring_entry.owner_index,
                               caption = {'pw.overview-go-ring'}}
        if not ring_entry.enterable then
            go.enabled = false
            -- 还差多久才可进入。阈值因人而异（新人按在线时长缩放，见 pockets.public_threshold），
            -- 所以用这位主人自己的 public_hours 现算，不能甩一个全服统一的数字。
            go.tooltip = {'pw.overview-ring-locked',
                math.max(0, math.floor(ring_entry.public_hours - ring_entry.idle_hours))}
        end
    end

    if ship then
        actions.add{type = 'button', name = 'pw_ov_ship_' .. ship.index,
                    caption = {'pw.overview-go-ship'}}
    end
end

function M.show(player)
    local inner = popup.open_popup(player, {'pw.overview-title'})

    local scroll = inner.add{type = 'scroll-pane', name = 'pw_ov_scroll', direction = 'vertical'}
    scroll.style.width = popup.WIDTH - 12
    scroll.style.maximal_height = 640

    render_my_ship(scroll, player)
    scroll.add{type = 'line', direction = 'horizontal'}

    local rows, unowned = build_rows()
    if #rows == 0 then
        scroll.add{type = 'label', caption = {'pw.overview-empty'}}
    end
    for _, row in ipairs(rows) do
        render_row(scroll, player, row)
    end

    -- 无主飞船：玩家从火箭井原生造的平台，脚本不知道主人是谁。
    -- 仍然列出来（它们照样占着服务器、照样会到期销毁），只是没有「主人」这一栏。
    if #unowned > 0 then
        scroll.add{type = 'line', direction = 'horizontal'}
        scroll.add{type = 'label', caption = {'pw.overview-unowned-head'}}
        for _, ship in ipairs(unowned) do
            local flow = scroll.add{type = 'flow', direction = 'horizontal'}
            flow.style.vertical_align = 'center'
            flow.add{type = 'button', name = 'pw_ov_ship_' .. ship.index,
                     caption = {'pw.overview-go-ship'}}
            if util.is_veteran(player) then
                flow.add{type = 'label', caption = {'pw.overview-ship-detail',
                    ship.platform.name, ship.left_hours}}
            else
                flow.add{type = 'label', caption = {'pw.overview-ship-plain', ship.platform.name}}
            end
        end
    end
end

-- 把玩家送上某艘飞船。
--
-- 【绝不能在找不到落脚点时兜底成原点】：平台表面上没铺基座的地方就是真空，
-- 传送过去角色直接没命。找不到就老实报错，让玩家自己想办法。
local function board(player, platform_index)
    local platform = game.forces.player.platforms[platform_index]
    if not (platform and platform.valid) then
        player.print({'pw.overview-ship-gone'})
        return
    end
    -- 平台在，但 surface 还没有：船停在等起步包的状态（apply_starter_pack 失败过）。
    -- 这和「船没了」是两码事，报错要分开说，否则玩家会以为船被销毁了。
    local surface = platform.surface
    if not (surface and surface.valid) then
        player.print({'pw.overview-ship-not-ready'})
        return
    end

    -- 以中枢为落脚参考点：那是平台上唯一保证有基座的地方。
    -- 中枢不存在（起步包还没落地）时退回原点【作为搜索中心】，
    -- 但仍然要求 find_non_colliding_position 真的找到一个能站的格子。
    local hub = platform.hub
    local origin = (hub and hub.valid) and hub.position or {0, 0}
    local pos = surface.find_non_colliding_position('character', origin, 64, 1)
    if not pos then
        player.print({'pw.overview-ship-no-room'})
        return
    end
    player.teleport(pos, surface)
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

    local pos = surface.find_non_colliding_position('character', {4, 0}, 64, 1) or {4, 0}
    player.teleport(pos, surface)
end

function M.on_click(player, name)
    if name == 'pw_ov_build' then
        local platform, err = ships.create(player)
        if not platform then
            player.print({err or 'pw.ship-create-failed'})
        end
        M.show(player)   -- 无论成败都重开，玩家立刻看到最新状态
        return true
    end

    local ship_index = string.match(name, '^pw_ov_ship_(%d+)$')
    if ship_index then
        board(player, tonumber(ship_index))
        popup.close_popup(player)
        return true
    end

    local owner_index = string.match(name, '^pw_ov_ring_(%d+)$')
    if owner_index then
        visit_ring(player, tonumber(owner_index))
        popup.close_popup(player)
        return true
    end

    return false
end

return M
