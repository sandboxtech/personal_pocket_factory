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
local util = require('scripts.util')

local M = {}

local WOOD = 'wooden-chest'
local LINKED = 'linked-chest'

-- 12 个收货箱的位置：两行 × 六列（横排），以原点双向对称。坐标来自 constants
-- （和玩家进环的落点放在一起定义，改箱阵坐标时不会漏掉出生点，见那里的注释）。
--
-- 12 个同 link_id 的箱子共享的是【同一个库存】，所以这不是 12 倍容量，
-- 是 12 个并行存取口 —— 12 个机械臂可以同时从同一批货里抓取，
-- 而单个箱子只能被有限几个机械臂围住。用箱子数量换吞吐量，不是换容量。
-- 两行之间夹着环心水池（中间还留了 2 格岸给海洋泵），机械臂站在箱阵外侧（上下两面）取货，
-- 理由见 constants 那边的注释。
local function array_positions()
    local out = {}
    for _, y in ipairs(constants.CHEST_ROWS) do
        for x = constants.CHEST_COL_FROM, constants.CHEST_COL_TO do
            out[#out + 1] = {x = x + 0.5, y = y + 0.5}
        end
    end
    return out
end

-- 某人的 12 箱阵此刻应该用哪个 link_id。
-- 公共期（离线超过公共化阈值、还没到删除阈值）指向全服公共库存，其余时候指向他自己。
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
                -- 防偷三道锁，各管一路：
                --   · gui_mode = "admins"（原版 linked-chest 原型自带）挡普通玩家
                --   · operable = false 挡管理员 —— 能打开界面的人就能编辑 link_id，
                --     一改那个箱子就指向别人的库存了
                --   · neutral force 挡「凭空造一个用这个 link_id 的箱子」（玩家造的恒属 player force）
                --
                -- 代价是箱主自己也打不开，取货必须靠机械臂。operable 只管玩家 GUI，
                -- 机械臂和传送带完全不受影响。
                chest.operable = false
            else
                -- create_entity 返回 nil（位置被占、砖不可建造等）。这一支曾经是完全静默的，
                -- 而「箱子没了」是玩家最容易注意到、最难自己诊断的故障，
                -- 所以哪怕只是少了一个箱子也要留下痕迹。
                log(string.format('[pw] 收货箱创建失败 surface=%s pos=(%.1f,%.1f) owner=%s',
                    surface.name, pos.x, pos.y, player.name))
            end
        else
            -- 「已存在」分支也要重设这四项，不是冗余：
            -- link_id 会随环的 private/public 状态来回切（见 M.set_array_link），
            -- 每次 ensure 重新按 expected_link_id 对齐一遍，箱阵就不会和环的状态脱节。
            -- 另外三项是"任何时候都该是这个值"的不变量，一起压一遍代价可忽略。
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

-------------------------------------------------------------------------------
-- 投递口名额
--
-- 玩家自己放的关联箱有个数上限（storage.dropoff_limit，默认 12），
-- 作用域是【全宇宙合计】，不按星球分别计数。
--
-- 总额度而不是「每颗星球一个」：名额押在哪儿本身就该是个决策，按星球平摊会抹掉它。
--
-- 超额时淘汰最早的那个而不是拒绝放置：拒绝要求玩家记住自己在哪几颗星球上还留着箱子，
-- 而那些多半早被世界重置清空了，无从查证 —— 玩家会卡在「说我满了但找不到满在哪」。
-------------------------------------------------------------------------------

local function same_spot(rec, surface_name, position)
    return rec.surface == surface_name and rec.x == position.x and rec.y == position.y
end

-- 收回一个超额的投递口。箱子已经不在了（被挖走 / 被世界重置清掉）就静默跳过。
-- near_chest 只用来提供"东西掉在哪儿"的坐标：玩家此刻就站在新箱子旁边。
local function evict(player_index, rec, near_chest, limit)
    local surface = rec.surface and game.surfaces[rec.surface]
    if not (surface and surface.valid) then return end
    local old_chest = surface.find_entity(LINKED, {rec.x, rec.y})
    if not (old_chest and old_chest.valid) then return end

    -- 关联箱的库存是共享的（挂在 link_id 上，不挂在箱子实体上），
    -- 摧毁箱子本身不会丢失货物——货仍留在那份共享库存里，
    -- 所以这里不需要、也不应该在摧毁前搬运任何物品。
    old_chest.destroy()

    local player = game.players[player_index]
    if not player then return end

    -- 把箱子【退还】给玩家，而不是让它凭空消失。
    -- 名额是位置上的限制，不该顺带变成材料上的惩罚：每挪一次投递口就白烧一个箱子，
    -- 会让人不敢随便挪，而"挪到更好的矿脉旁边"恰恰是这条规则想鼓励的决策。
    --
    -- 背包塞不下时 insert 返回 0，剩下的直接掉在脚边，绝不静默吞掉。
    local inserted = player.insert{name = LINKED, count = 1}
    if inserted < 1 then
        near_chest.surface.spill_item_stack{
            position = near_chest.position,
            stack = {name = LINKED, count = 1},
            enable_looted = true,
            force = player.force,
        }
    end
    player.print({'pw.dropoff-replaced', util.surface_label(rec.surface), limit})
end

-- 把新放下的投递口登记进名额表，并淘汰超出上限的最老几个。
function M.register_dropoff(player_index, chest)
    storage.dropoffs = storage.dropoffs or {}
    local list = storage.dropoffs[player_index] or {}
    local surface_name = chest.surface.name
    local position = chest.position

    -- 【原地重建】：新箱子恰好落在登记表里已有的坐标上（旧箱子早已不在，
    -- 这个位置现在站着的就是新箱子本身）。先把那条旧记录摘掉，否则同一个位置
    -- 会在表里出现两次，淘汰时还可能把刚建好的这个当成"最早的那个"销毁。
    -- 按坐标摘、而不是比较实体，是因为旧记录指向的实体这时候通常已经不存在了。
    for i = #list, 1, -1 do
        if same_spot(list[i], surface_name, position) then table.remove(list, i) end
    end

    list[#list + 1] = {surface = surface_name, x = position.x, y = position.y}

    -- 夹到至少 1：上限被误设成 0 或负数时，下面的循环会把刚放下的这个也淘汰掉，
    -- 玩家会看到"箱子放下就消失"这种完全无法自诊断的现象。
    local limit = math.max(1, math.floor(storage.dropoff_limit or 12))
    while #list > limit do
        evict(player_index, table.remove(list, 1), chest, limit)
    end

    storage.dropoffs[player_index] = list
end

local function on_built(event)
    local entity = event.entity
    if not (entity and entity.valid) then return end
    if entity.name ~= WOOD and entity.name ~= LINKED then return end

    -- 建造者：手动建有 player_index，机器人建则看 last_user
    local player_index = event.player_index
    if not player_index and entity.last_user then player_index = entity.last_user.index end

    local in_ring = ring.is_ring_surface(entity.surface)

    -- 木箱 → 关联箱的兜底转换只发生在【非戴森环】的表面：
    -- 戴森环里木箱就是普通储物箱，保持原样不动（家里要有普通储物箱可用）。
    -- 这里兜底的是组装机/蓝图产出的、以实体形式直接摆上来的木箱——
    -- 玩家手搓的木箱在 on_player_crafted_item 里已经在物品状态就换成了关联箱物品，不会走到这里。
    local chest = entity
    if chest.name == WOOD then
        if in_ring then return end
        chest = swap(chest, LINKED, player_index)
        if not (chest and chest.valid) then return end
    end

    -- 走到这里 chest.name 必为 LINKED，不区分是否在戴森环里，以下这套规则统一生效：
    -- 戴森环里关联箱不再退化回木箱——玩家可以在自己环里放关联箱，它会经由
    -- rightful_link_id 绑到自己（或环的 public 状态对应）的 link_id 上，
    -- 和那 12 个系统收货箱共享同一份库存，放了没有额外用处，但无害。

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

    -- 判定「这是不是玩家放的箱子」的唯一依据是 entity.destructible：
    -- 戴森环里那 12 个系统收货箱固定 destructible = false，且是脚本 create_entity
    -- （raise_built = false）造出来的，本来就不会触发 on_built_entity/on_robot_built_entity，
    -- 不会走到这里；这里仍然显式判一次 destructible 作为双重保险——
    -- 玩家放的箱子永远是可摧毁的，destructible == false 就是系统箱区别于玩家箱的唯一标志。
    --
    -- 取不到建造者（player_index 为空，例如机器人建造时 last_user 也拿不到）就不做限制——
    -- 这种箱子已经在 rightful_link_id 里兜底成公共库存了，不属于「某个玩家的投递口」。
    if player_index and chest.destructible then
        M.register_dropoff(player_index, chest)
    end
end

events.on(defines.events.on_built_entity, on_built)
events.on(defines.events.on_robot_built_entity, on_built)

-- ══ 挖走 / 被摧毁时清理登记表 ══
-- 现在戴森环里也可能存在被登记的玩家关联箱（见上面 on_built），所以不再按 surface
-- 排除戴森环——任何平面上的都要清理。
-- 那 12 个系统收货箱 destructible = false、minable = false，本来就不会触发
-- on_player_mined_entity 也不会触发 on_entity_died；这里仍然显式判一次 destructible
-- 作为双重保险，和 on_built 里的判据保持一致：destructible == false 是系统箱的唯一标志。
-- 不清理也不会出大错：下次放置时 find_entity 在旧坐标找不到箱子，会静默跳过——
-- 但留着指向空气的登记项是脏数据，清掉更干净。
local function forget_chest(entity)
    if not (entity and entity.valid) then return end
    if entity.name ~= LINKED then return end
    if not entity.destructible then return end
    -- 实体这一刻仍然有效，position 必须现在取——事件处理完之后实体就没了。
    local surface_name = entity.surface.name
    local position = entity.position
    storage.dropoffs = storage.dropoffs or {}
    for _, list in pairs(storage.dropoffs) do
        -- 倒着删：正着走 table.remove 会跳过紧跟其后的那一项。
        for i = #list, 1, -1 do
            if same_spot(list[i], surface_name, position) then table.remove(list, i) end
        end
    end
end

events.on(defines.events.on_player_mined_entity, function(event)
    forget_chest(event.entity)
end)

events.on(defines.events.on_entity_died, function(event)
    forget_chest(event.entity)
end)

return M
