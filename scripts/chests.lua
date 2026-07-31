-- 关联箱：跨星球物流。
--
-- 玩法：玩家在【公共世界】铺出去的关联箱是一堆投递口，全部通向自己戴森环正中央那组收货箱。
-- 于是背包容量不再是瓶颈，但出门的意义反而更强了 ——
-- 张力从「搬运」转移到「暴露在重置风险里的时间」：
-- 星球重置时投递口全没了，家里的货还在，所以要赶在重置前把投递口铺到矿脉旁边并尽量多送。
--
-- 同一件物品的语义由所在星球决定（在家是储物，出门是投递口），
-- 玩家不需要管理两种箱子，也不会出现「我把珍贵的关联箱浪费在家里了」的懊恼。
local constants = require('scripts.constants')
local events = require('scripts.events')
local ring = require('scripts.ring')

local M = {}

local WOOD = 'wooden-chest'
local LINKED = 'linked-chest'

-- 12 个收货箱的位置：两列 × 六行，以原点双向对称。
-- 12 个同 link_id 的箱子共享的是【同一个库存】，所以这不是 12 倍容量，
-- 是 12 个并行存取口 —— 12 个机械臂可以同时从同一批货里抓取，
-- 而单个箱子只能被有限几个机械臂围住。用箱子数量换吞吐量，不是换容量。
local function array_positions()
    local out = {}
    for _, x in ipairs({-1, 0}) do
        for y = -3, 2 do
            out[#out + 1] = {x = x + 0.5, y = y + 0.5}
        end
    end
    return out
end

-- 某人的 12 箱阵此刻应该用哪个 link_id。
-- 公共期（离线 30-50 小时）指向全服公共库存，其余时候指向他自己。
function M.expected_link_id(player_name)
    storage.ring_state = storage.ring_state or {}
    if storage.ring_state[player_name] == 'public' then
        return constants.PUBLIC_LINK_ID
    end
    local player = game.players[player_name]
    return player and player.index or constants.PUBLIC_LINK_ID
end

-- 建 12 箱阵。幂等：已存在的位置跳过。
--
-- 调用位置有顺序依赖：pockets.ensure 里本函数在 storage.ring_state[player.name] 赋值之前调用，
-- 此时该玩家的 ring_state 还是 nil（不是 'public'），expected_link_id 会走「返回 player.index」
-- 这条分支 —— 这正是新建戴森环时想要的结果（新环永远先归属主人自己）。
-- 但这依赖调用顺序，将来若把本调用挪到 ring_state 赋值之后，行为不会变
-- （因为赋的值正是 'private'，同样不等于 'public'），只是这里先记一笔，免得误以为顺序不重要就随手挪动。
-- 这里直接用 expected_link_id 而不是「真相源」rightful_link_id，不是漏改：
-- 调用点保证了这 12 个箱子必然在 player 自己的环上（surface 是 M.ensure_array 的入参、
-- 由 pockets.ensure 传进来的就是这个玩家自己刚建好的环），rightful_link_id 的环内分支
-- 最终也是转调 M.expected_link_id(owner)，owner 算出来就是这个 player.name ——两者在这里等价。
-- rightful_link_id 存在的意义是给「不知道箱子归属、需要现查」的场合用（on_built），
-- 这里归属是入参直接给定的，不需要绕那一圈。
function M.ensure_array(surface, player)
    local link_id = M.expected_link_id(player.name)
    for _, pos in ipairs(array_positions()) do
        local existing = surface.find_entity(LINKED, pos)
        if not existing then
            local chest = surface.create_entity{
                name = LINKED, position = pos,
                -- force = 'neutral'：防偷的第一道锁。
                -- 玩家（包括机器人代建）造出来的东西恒属 player force，只有脚本能创建
                -- neutral 实体——所以就算攻击者拿到了别人的 link_id，他也造不出一个
                -- 能挂上这个 id 的 neutral 箱子来接货。详细的两道锁分工见下面 operable 的注释。
                force = 'neutral', raise_built = false,
            }
            if chest then
                chest.link_id = link_id
                chest.destructible = false   -- 不可摧毁
                chest.minable = false        -- 不可挖走
                -- operable = false —— 挡住【管理员】的那道锁。
                --
                -- 原版 linked-chest 原型自带 gui_mode = "admins"（Factorio 安装目录
                -- data/base/prototypes/entity/entities.lua），普通玩家根本打不开这个
                -- 界面。所以防偷是两道锁分工，各管一半人群：
                --   · gui_mode = "admins"  挡住普通玩家
                --   · operable = false     挡住管理员
                --   · neutral force        挡住「凭空造一个能用这个 link_id 的箱子」（玩家造的恒属 player force）
                --
                -- 曾经试过设成 true 让箱主能自己开箱取货，但实测发现：能打开界面的人就能编辑 link_id，
                -- 而「能打开的人」包括所有管理员 —— 单人游戏的主机、以及小型服务器上通常不止一个的管理员。
                -- 一旦有人（哪怕无意）改了 link_id，那个箱子就指向别人的库存了。
                --
                -- 代价：箱主自己也打不开自己的收货箱，取货必须靠机械臂。这是明确接受的。
                -- 机械臂和传送带完全不受 operable 影响 —— 它只管玩家 GUI。
                chest.operable = false
            end
        else
            -- 「已存在」分支也要重设这四项，不能只在新建时设——
            -- 否则老存档里已经建好的箱阵（例如本次修复之前创建的、还是 player force 的）
            -- 不会被这次修复补上，ensure_array 就不是真正幂等的。
            existing.link_id = link_id
            existing.destructible = false
            existing.minable = false
            -- operable = false 的理由见上面新建分支里的同名注释：operable = false 是挡住
            -- 管理员的那道锁。原型自带 gui_mode = "admins" 挡住普通玩家，但管理员（包括
            -- 单人游戏主机）被放行。防偷是两道锁分工，operable = false 不是冗余，是唯一
            -- 挡住管理员误改 link_id 的那道锁。防偷真正靠的还是下面的 neutral force。
            existing.operable = false
            existing.force = 'neutral'
        end
    end
end

-- 把某人 12 箱阵的 link_id 整体切换（公共化 / 回归时用）。
function M.set_array_link(player, link_id)
    local surface = game.surfaces[ring.surface_name_for(player.index)]
    if not (surface and surface.valid) then return 0 end
    local changed = 0
    -- 不存箱子的 LuaEntity 引用：surface 重建后引用会失效，每次现查最可靠。
    for _, chest in pairs(surface.find_entities_filtered{name = LINKED}) do
        chest.link_id = link_id
        changed = changed + 1
    end
    return changed
end

-- 某个关联箱【应该】是谁的。on_built 靠这一个函数判定「新建/接管的箱子该绑哪个 link_id」，
-- 避免规则散落多处、改一处漏一处。
function M.rightful_link_id(chest)
    -- 戴森环里的箱阵：按环的 private/public 状态推导。
    if ring.is_ring_surface(chest.surface) then
        local owner = ring.owner_name_of(chest.surface)
        if owner then return M.expected_link_id(owner) end
        return constants.PUBLIC_LINK_ID
    end
    -- 公共世界的投递口：归建造者。last_user 由 create_entity{player=...} 设置，
    -- 或者由引擎在玩家/机器人建造时自动写入。
    -- 取不到建造者时兜底成公共库存 —— 宁可让这个箱子变成公共的，
    -- 也不能留一个「link_id 可以是任意值」的口子。
    local user = chest.last_user
    return user and user.index or constants.PUBLIC_LINK_ID
end

-------------------------------------------------------------------------------
-- 木箱 ↔ 关联箱
-------------------------------------------------------------------------------

-- 手搓木箱直接换成关联箱物品。
-- 组装机产的木箱抓不到（那是 entity 在造），所以放置时还有一道兜底，见下面的 on_built。
events.on(defines.events.on_player_crafted_item, function(event)
    local stack = event.item_stack
    if not (stack and stack.valid and stack.valid_for_read) then return end
    if stack.name ~= WOOD then return end
    local player = game.players[event.player_index]
    if not player then return end

    local count = stack.count
    stack.clear()
    player.insert{name = LINKED, count = count}
end)

-- 在原位把一个实体换成另一种。返回新实体。
-- quality 必须在 destroy() 之前捕获：本项目有品质体系，组装机可能用品质模块产出高品质木箱，
-- 不捕获的话品质会在 swap 时被静默重置成 normal —— 不可逆的价值损失且没有任何提示。
local function swap(entity, new_name, player_index)
    local surface, position, force = entity.surface, entity.position, entity.force
    local quality = entity.quality
    entity.destroy()
    return surface.create_entity{
        name = new_name, position = position, force = force, quality = quality,
        player = player_index, raise_built = false,
    }
end

local function on_built(event)
    local entity = event.entity
    if not (entity and entity.valid) then return end
    if entity.name ~= WOOD and entity.name ~= LINKED then return end

    -- 建造者：手动建有 player_index，机器人建则看 last_user
    local player_index = event.player_index
    if not player_index and entity.last_user then player_index = entity.last_user.index end

    local in_ring = ring.is_ring_surface(entity.surface)

    if in_ring then
        -- 戴森环里关联箱退化回木箱：家里要有普通储物箱可用。
        -- 12 个预置收货箱是脚本 create_entity 出来的，不触发本事件，不会被误伤。
        -- 万一将来接了 script_raised_built，判据是 destructible == false（玩家放的永远可摧毁）。
        if entity.name == LINKED and entity.destructible then
            swap(entity, WOOD, player_index)
        end
        return
    end

    -- 公共世界：木箱兜底转成关联箱，然后一律绑 ID
    local chest = entity
    if chest.name == WOOD then
        chest = swap(chest, LINKED, player_index)
        if not (chest and chest.valid) then return end
    end

    -- neutral force 是防偷的核心：这里处理的是「攻击者挖走别人的投递口、拿到
    -- linked-chest 物品、自己放下」这条路径——放下时会再次经过本函数，一律转成
    -- neutral，他手上不会留下一个能自由改 link_id 的 player-force 箱子。
    chest.force = 'neutral'

    -- link_id 怎么算只有 rightful_link_id 这一处定义，这里不再自己拼 player_index。
    chest.link_id = M.rightful_link_id(chest)

    -- operable = false 让谁都打不开这个箱子的界面，改不了 link_id。
    -- 机械臂和传送带完全不受影响 —— operable 只管玩家 GUI。
    -- 代价：手动往投递口倒背包也做不到了（包括主人自己）。
    -- 这是有意的：投递口从「随手的邮筒」变成「必须建设的采集前哨」。
    -- 这层锁不是冗余的 —— operable = false 是唯一挡住管理员误改 link_id 的那道锁
    -- （原型自带 gui_mode = "admins" 只挡普通玩家，但放行管理员）。防偷是两道锁分工：
    -- gui_mode = "admins" 挡普通玩家，operable = false 挡管理员，neutral force 挡攻击者造假。
    chest.operable = false
end

events.on(defines.events.on_built_entity, on_built)
events.on(defines.events.on_robot_built_entity, on_built)

return M
