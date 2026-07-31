-- 经验系统 + 兑换。本场景唯一的跨重置进度。
--
-- 经验存 storage.exp[玩家名]，是一个整数，等级 = floor(sqrt(exp))，没有上限。
-- 经验的唯一来源是【兑换】：消耗体力 + 背包里的物资 → 经验。
-- 物资价值由 values.lua 折算成原矿当量，再乘品质系数。
--
-- 为什么用体力闸住兑换：
--   没有闸门的话，产量最高的玩家会把经验曲线拉到别人追不上的地方，公开服的新人永远没有意义。
--   体力随时间恢复、离线也攒、还能转赠，于是"上线少但攒了体力的人"和"天天在线产量高的人"各有各的位置。
local constants = require('scripts.constants')
local values = require('scripts.values')
local stamina = require('scripts.stamina')
local util = require('scripts.util')

local M = {}

-- 取玩家经验。create=true 时确保有记录。
function M.get(player_name)
    storage.exp = storage.exp or {}
    return storage.exp[player_name] or 0
end

function M.add(player_name, amount)
    storage.exp = storage.exp or {}
    amount = math.floor(amount or 0)
    if amount <= 0 then return end
    storage.exp[player_name] = (storage.exp[player_name] or 0) + amount
end

function M.level(player_name)
    return util.level_of(M.get(player_name))
end

-- 扫背包，把每种物品折算成价值。返回 { {name=, count=, quality=, value=} ... } 和总价值。
-- 不改动背包，纯统计，供预览和实际兑换共用，保证"看到的"和"换到的"一致。
function M.appraise(player)
    local inventory = util.main_inventory(player)
    if not inventory then return {}, 0 end

    local entries = {}
    local total = 0
    local budget = storage.convert_batch or 200
    for _, item in pairs(inventory.get_contents()) do
        if #entries >= budget then break end
        local unit = values.of(item.name)
        local quality_mult = constants.quality_exp[item.quality] or 1
        local worth = unit * item.count * quality_mult
        if worth > 0 then
            entries[#entries + 1] = {
                name = item.name,
                count = item.count,
                quality = item.quality,
                value = worth,
            }
            total = total + worth
        end
    end
    return entries, total
end

-------------------------------------------------------------------------------
-- TODO(设计决策)：兑换公式。这是整个经济的核心，请你来定。
--
-- 输入：
--   stamina_available  玩家当前体力（整数）
--   resource_value     背包物资折算出来的总价值（浮点，原矿当量 × 品质系数）
-- 输出：
--   exp_gained         本次应该给多少经验（整数）
--   stamina_cost       本次应该扣多少体力（整数）
--   consume_all        true = 清空背包里所有可兑换物资；false = 只消耗一部分（需要你另外定按什么比例扣）
--
-- 三种方向，玩法后果完全不同：
--
--   A. 体力当门票。固定扣 storage.convert_cost 点体力，背包全兑，exp = floor(resource_value)。
--      体力几乎不是瓶颈，产量才是。鼓励攒一大背包再兑，节奏慢而稳。
--
--   B. 体力当配额。每点体力只能兑换固定额度的价值，exp = floor(min(resource_value, stamina × 额度))。
--      体力是硬上限，离线攒体力有直接价值，挂机玩家的体力对活跃玩家值钱，转赠系统会真正活起来。
--      代价是产量高的玩家会被体力卡住，可能觉得憋屈。
--
--   C. 体力当倍率。玩家自己决定投入多少体力，exp = floor(resource_value × f(投入体力))，
--      f 可以是 1 + 投入/10 之类的递增函数。策略性最强，要决定"什么时候重仓"，
--      但也最难平衡，容易被算出最优解之后变成固定套路。
--
-- 我的倾向是 B，因为它最能把你要的"挂机玩家和勤快玩家各有位置"落到实处，
-- 而且体力转赠会自然长出玩家之间的交易。但这条会直接决定服务器的节奏，你比我清楚你的玩家群。
--
-- 在下面实现它。函数已经接好线：convert() 会调用它，GUI 的预览也走同一个函数，改一处两边同步。
-------------------------------------------------------------------------------
function M.formula(stamina_available, resource_value)
    -- 占位实现（方向 A），先让场景能跑起来。替换成你选的方案。
    local cost = math.floor(storage.convert_cost or 1)
    if stamina_available < cost then
        return 0, 0, false
    end
    return math.floor(resource_value), cost, true
end

-- 预览：不改动任何状态，返回这次兑换能拿多少经验、要花多少体力。GUI 用。
function M.preview(player)
    local _, total = M.appraise(player)
    local have = stamina.get(player.name)
    local gain, cost = M.formula(have, total)
    return gain, cost, total
end

-- 实际兑换。成功返回 gain, cost；失败返回 nil 加一个失败原因 key（供本地化）。
function M.convert(player)
    local inventory = util.main_inventory(player)
    if not inventory then return nil, 'pw.convert-no-character' end

    local entries, total = M.appraise(player)
    if total <= 0 then return nil, 'pw.convert-nothing' end

    local have = stamina.get(player.name)
    local gain, cost, consume_all = M.formula(have, total)
    if gain <= 0 then return nil, 'pw.convert-no-stamina' end
    if not stamina.spend(player.name, cost) then return nil, 'pw.convert-no-stamina' end

    -- 先扣体力再移除物品：体力扣不掉就整个中止，不会出现"物品没了但没给经验"。
    if consume_all then
        for _, e in ipairs(entries) do
            inventory.remove({name = e.name, count = e.count, quality = e.quality})
        end
    end

    M.add(player.name, gain)
    storage.exp_log = storage.exp_log or {}
    storage.exp_log[player.name] = {gain = gain, cost = cost, value = total, tick = game.tick}
    return gain, cost
end

return M
