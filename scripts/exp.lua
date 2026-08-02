-- 12 种经验 + 兑换。本场景唯一的跨重置进度。
--
-- 每种科技瓶对应一种经验，分开记账。戴森环的宽度 = 32 × (2 + floor(Σ log10(expᵢ)))。
-- 因为 log10(1) = 0，任何一种瓶子没攒过那一项就是 0 —— 这逼玩家集齐 12 种、跑遍五个星球。
--
-- 为什么不需要跨瓶种定价：12 种各自独立取 log10、互不换算，
-- 普罗米修斯瓶只喂普罗米修斯那一项，跟红瓶从不在同一个数里比大小。
-- 所以 1 瓶 = 1 经验 × 品质系数就够了，v1 那套递归展开配方求原矿当量的 values.lua 失去了全部存在理由。
local geometry = require('scripts.geometry')
local constants = require('scripts.constants')
local stamina = require('scripts.stamina')
local ring = require('scripts.ring')
local util = require('scripts.util')

local M = {}

-- 物品名 → 瓶子短名的反查表。建一次缓存在模块里（纯常量，不进 storage）。
local ITEM_TO_PACK = {}
for _, short in ipairs(geometry.SCIENCE_PACKS) do
    ITEM_TO_PACK[geometry.pack_item_name(short)] = short
end

function M.get(player_name)
    return constants.ensure_exp_table(player_name)
end

function M.add(player_name, pack_short, amount)
    amount = math.floor(amount or 0)
    if amount <= 0 then return end
    local tbl = constants.ensure_exp_table(player_name)
    tbl[pack_short] = (tbl[pack_short] or 0) + amount
end

-- 扫某份 inventory，只认 12 种科技瓶。不改动 inventory，纯统计，供预览和实际兑换共用，
-- 保证「看到的」和「换到的」一致。mult 是该项的品质经验系数，供配额模拟按 take 折算实际经验。
-- 背包兑换和箱子自动兑换（M.tick_auto_convert）都吃这同一个函数，唯一区别是 inventory 的来源。
function M.appraise_inventory(inventory)
    if not inventory then return {}, 0 end

    local quality_exp = storage.quality_exp or
        {normal = 1, uncommon = 3, rare = 5, epic = 7, legendary = 9}

    local entries, total = {}, 0
    for _, item in pairs(inventory.get_contents()) do
        local short = ITEM_TO_PACK[item.name]
        if short then
            local mult = quality_exp[item.quality] or 1
            local gain = item.count * mult
            entries[#entries + 1] = {
                pack = short, item = item.name, quality = item.quality,
                count = item.count, mult = mult, gain = gain,
            }
            total = total + gain
        end
    end
    return entries, total
end

-- 兼容旧调用点：扫玩家背包。
function M.appraise(player)
    return M.appraise_inventory(util.main_inventory(player))
end

-- 配额制模拟一遍兑换：不改动任何状态。preview 和实际兑换共用，保证「看到的」和「换到的」一致。
--
-- 规则：1 点体力 = 1 个瓶子，配额（quota）就是体力点数，直接当「还能兑几个瓶子」用，
-- 不再按物品的堆叠上限折算成组——那个"组"的概念（连带查一次物品原型才能拿到的那个字段）
-- 整个不需要了。配额按 entries 出现的顺序消耗，一项吃不下所有数量时会在这项截断，
-- 剩下的项 take/points 都是 0。
local function simulate_inventory(inventory, quota)
    local entries = M.appraise_inventory(inventory)
    local total_gain, points_used = 0, 0
    local quota_left = quota

    for _, e in ipairs(entries) do
        e.take, e.points = 0, 0
    end

    for _, e in ipairs(entries) do
        local take = math.min(quota_left, e.count)
        if take <= 0 then break end
        e.take, e.points = take, take   -- 1 点体力 = 1 个瓶子，花的点数就是拿走的数量
        total_gain = total_gain + take * e.mult
        points_used = points_used + take
        quota_left = quota_left - take
    end

    return entries, total_gain, points_used
end

-- 预览：不改动任何状态。entries 里每项附带 take（这次会吃掉多少个）和 points（花几点），GUI 用。
function M.preview(player)
    return simulate_inventory(util.main_inventory(player), stamina.balance(player.name))
end

-- 兑换的核心实现：吃某份 inventory，把兑得的经验记到 player_name 名下。
-- 背包兑换（M.convert，玩家点按钮）和箱子自动兑换（M.tick_auto_convert，周期任务吃收货箱共享库存）
-- 共用这一份实现，不另外复制一份逻辑——两者的差别只是 inventory 从哪儿来、记账记给谁。
--
-- 顺序：先算清楚（simulate_inventory）→ 再扣体力 → 再移除物品 → 再加经验。
-- 体力扣不掉就整个中止，不会出现「物品没了但没给经验」。
--
-- 是否重算环宽（ring.apply_growth）不在这里做：调用方各自决定什么时候调，
-- 因为箱子自动兑换要在离线玩家身上也生效，不能假设调用时手上有一个「当前操作的 player」在场景里活跃。
local function convert_inventory(inventory, player_name)
    if not inventory then return nil, 'pw.convert-no-character' end

    local quota = stamina.balance(player_name)
    local entries, total_gain, points_used = simulate_inventory(inventory, quota)
    if #entries == 0 then return nil, 'pw.convert-nothing' end
    if total_gain <= 0 then return nil, 'pw.convert-no-stamina' end

    if not stamina.spend(player_name, points_used) then return nil, 'pw.convert-no-stamina' end

    for _, e in ipairs(entries) do
        if e.take > 0 then
            inventory.remove({name = e.item, count = e.take, quality = e.quality})
            M.add(player_name, e.pack, e.take * e.mult)
        end
    end

    storage.exp_log = storage.exp_log or {}
    storage.exp_log[player_name] = {entries = entries, total = total_gain, cost = points_used, tick = game.tick}

    return total_gain, entries, points_used
end

-- 实际兑换（背包路径）。配额 = 体力池点数，1 点兑 1 个瓶子。
function M.convert(player)
    local inventory = util.main_inventory(player)
    local total_gain, entries, points_used = convert_inventory(inventory, player.name)
    if total_gain then
        -- 兑换完立刻重算环宽并扩容，玩家点完按钮就能看见世界变宽
        ring.apply_growth(player)
    end
    return total_gain, entries, points_used
end

-- 周期任务：把每个玩家戴森环收货箱里的科技瓶自动兑换成经验。
--
-- 遍历所有玩家而不只在线的：离线时工厂也该继续产出经验。
--
    -- 【跳过公共期玩家】：他们的系统收货箱已经切到全服公共库存
-- （chests.expected_link_id），把公共的货记到缺席主人头上是错的。
--
-- 【两档节奏】在线 auto_convert_minutes（默认 1 分钟），离线
-- auto_convert_offline_minutes（默认 10 分钟）。反馈延迟只对在线的人有意义，
-- 离线玩家只关心回来时总量对不对，没理由每分钟把全服离线的环都扫一遍。
-- 总产出不受节奏影响：配额是体力点数，换得勤只是把同样多的体力分更多次花掉。
function M.tick_auto_convert()
    storage.ring_state = storage.ring_state or {}

    -- 离线闸门。到点了就把下次时刻推后一个周期，本轮连离线玩家一起处理。
    local offline_period = (storage.auto_convert_offline_minutes or 10) * constants.min_to_tick
    local offline_due = (storage.auto_convert_offline_at or 0) <= game.tick
    if offline_due then
        storage.auto_convert_offline_at = game.tick + offline_period
    end

    for _, player in pairs(game.players) do
        -- 在线的每轮都过；离线的只在闸门打开的那一轮过。
        if (player.connected or offline_due)
                and storage.ring_state[player.name] ~= 'public' then
            local surface = game.surfaces[ring.surface_name_for(player.index)]
            if surface and surface.valid then
                -- 系统收货箱共享同一份 inventory（都挂着同一个 link_id），
                -- 随便找到其中一个读它的 chest inventory 就是那份共享库存本身，
                -- 不需要、也不应该逐箱分别兑换（会把同一份货重复吃掉）。
                local chest = surface.find_entities_filtered{name = 'linked-chest', limit = 1}[1]
                if chest and chest.valid then
                    local inventory = chest.get_inventory(defines.inventory.chest)
                    local total_gain = convert_inventory(inventory, player.name)
                    if total_gain then
                        -- 离线时也要让环该变宽就变宽，回来时直接看到长大的环。
                        ring.apply_growth(player)
                        -- 在线玩家给个提示；离线的不用管（player.print 对离线玩家仍然安全，
                        -- 但打印出来的消息没人看得到，不如干脆跳过）。
                        if player.connected then
                            player.print({'pw.auto-convert-done', util.readable(total_gain)})
                        end
                    end
                end
            end
        end
    end
end

return M
