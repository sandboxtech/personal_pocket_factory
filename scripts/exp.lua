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

-- 扫背包，只认 12 种科技瓶。不改动背包，纯统计，供预览和实际兑换共用，
-- 保证「看到的」和「换到的」一致。mult 是该项的品质经验系数，供配额模拟按 take 折算实际经验。
function M.appraise(player)
    local inventory = util.main_inventory(player)
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

-- 配额制模拟一遍兑换：不改动任何状态。preview 和 convert 共用，保证「看到的」和「换到的」一致。
--
-- 规则：1 点体力最多兑换该物品一组（stack_size 个）瓶子，不足一组也要花掉整点——
-- 这逼着体力池宽裕时也别攒着舍不得花，但也不会因为背包里剩几个零头就浪费一整点。
-- 配额按 entries 出现的顺序消耗，一项吃不下所有数量时会在这项截断，剩下的项 take/points 都是 0。
local function simulate(player, quota)
    local entries = M.appraise(player)
    local total_gain, points_used = 0, 0
    local quota_left = quota

    for _, e in ipairs(entries) do
        e.take, e.points = 0, 0
    end

    for _, e in ipairs(entries) do
        local proto = prototypes.item[e.item]
        local stack_size = (proto and proto.stack_size) or 200
        local take = math.min(quota_left * stack_size, e.count)
        if take <= 0 then break end
        local points = math.ceil(take / stack_size)
        e.take, e.points = take, points
        total_gain = total_gain + take * e.mult
        points_used = points_used + points
        quota_left = quota_left - points
    end

    return entries, total_gain, points_used
end

-- 预览：不改动任何状态。entries 里每项附带 take（这次会吃掉多少个）和 points（花几点），GUI 用。
function M.preview(player)
    return simulate(player, stamina.balance(player.name))
end

-- 实际兑换。配额 = 体力池点数，1 点最多兑一组。
-- 顺序：先算清楚（simulate）→ 再扣体力 → 再移除物品 → 再加经验。
-- 体力扣不掉就整个中止，不会出现「物品没了但没给经验」。
function M.convert(player)
    local inventory = util.main_inventory(player)
    if not inventory then return nil, 'pw.convert-no-character' end

    local quota = stamina.balance(player.name)
    local entries, total_gain, points_used = simulate(player, quota)
    if #entries == 0 then return nil, 'pw.convert-nothing' end
    if total_gain <= 0 then return nil, 'pw.convert-no-stamina' end

    if not stamina.spend(player.name, points_used) then return nil, 'pw.convert-no-stamina' end

    for _, e in ipairs(entries) do
        if e.take > 0 then
            inventory.remove({name = e.item, count = e.take, quality = e.quality})
            M.add(player.name, e.pack, e.take * e.mult)
        end
    end

    storage.exp_log = storage.exp_log or {}
    storage.exp_log[player.name] = {entries = entries, total = total_gain, cost = points_used, tick = game.tick}

    -- 兑换完立刻重算环宽并扩容，玩家点完按钮就能看见世界变宽
    ring.apply_growth(player)

    return total_gain, entries, points_used
end

return M
