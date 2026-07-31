-- 体力系统。沿用 endfield_factorio 的星星机制：随时间恢复、离线也在攒、攒到上限就不再涨。
--
-- 存储形态：storage.stamina[玩家名] = { amount = 当前点数, last = 上次结算的 tick }
-- 用"上次结算 tick + 惰性补算"而不是每 tick 给所有人加，是为了：
--   1. 离线玩家不需要遍历，登录时一次补齐；
--   2. 不占 on_tick 预算，人数再多也没有额外开销。
--
-- 全部用整数运算并保留余数（last 只前进"已兑现"的那部分 tick），所以不会有浮点漂移，
-- 也不会因为每次读取的时机不同而少给或多给零头。
local constants = require('scripts.constants')

local M = {}

-- 每点体力需要多少 tick。由 storage.stamina_per_hour 反推，至少 1 防除零。
local function ticks_per_point()
    local per_hour = storage.stamina_per_hour or 60
    if per_hour <= 0 then return math.huge end
    return math.max(1, math.floor(constants.hour_to_tick / per_hour))
end

-- 取（并顺带补算）某玩家的体力记录。create=false 且没记录时返回 nil。
local function record(name, create)
    storage.stamina = storage.stamina or {}
    local rec = storage.stamina[name]
    if not rec then
        if not create then return nil end
        rec = {amount = 0, last = game.tick}
        storage.stamina[name] = rec
    end
    return rec
end

-- 把「上次结算到现在」这段时间折算成体力加进去。所有读写体力的入口都先调它。
-- 到达上限后 last 直接推到当前 tick，溢出的时间不累积（满了就是浪费，和手游体力一致）。
local function settle(rec)
    local cap = storage.stamina_cap or 1440
    local per = ticks_per_point()
    if per == math.huge then rec.last = game.tick; return rec end

    local elapsed = game.tick - (rec.last or game.tick)
    if elapsed <= 0 then return rec end

    local gained = math.floor(elapsed / per)
    if gained > 0 then
        rec.amount = math.min(cap, (rec.amount or 0) + gained)
        rec.last = (rec.last or game.tick) + gained * per   -- 只推进已兑现的部分，余数留到下次
    end
    if rec.amount >= cap then rec.last = game.tick end       -- 满了就不再攒余数
    return rec
end

-- 当前体力（整数）。这是所有 GUI / 校验的读取口。
function M.get(player_name)
    local rec = record(player_name, true)
    settle(rec)
    return rec.amount or 0
end

-- 距离下一点体力还差多少 tick，供 GUI 画恢复进度条。满了返回 0。
function M.ticks_to_next(player_name)
    local rec = record(player_name, true)
    settle(rec)
    if (rec.amount or 0) >= (storage.stamina_cap or 1440) then return 0 end
    local per = ticks_per_point()
    if per == math.huge then return 0 end
    return per - ((game.tick - (rec.last or game.tick)) % per)
end

-- 扣体力。够扣返回 true 并扣除，不够返回 false 且不改动。
function M.spend(player_name, amount)
    amount = math.floor(amount or 0)
    if amount <= 0 then return true end
    local rec = record(player_name, true)
    settle(rec)
    if (rec.amount or 0) < amount then return false end
    rec.amount = rec.amount - amount
    return true
end

-- 加体力（管理员补偿 / 活动奖励用）。会被上限截断。
function M.add(player_name, amount)
    amount = math.floor(amount or 0)
    if amount == 0 then return end
    local rec = record(player_name, true)
    settle(rec)
    rec.amount = math.max(0, math.min(storage.stamina_cap or 1440, (rec.amount or 0) + amount))
end

-- 玩家之间转赠体力。成功返回 true，余额不足或目标无效返回 false。
-- 转赠会让"离线攒体力"变成可交易的资源，挂机玩家因此对活跃玩家有价值。
function M.transfer(from_name, to_name, amount)
    amount = math.floor(amount or 0)
    if amount <= 0 or from_name == to_name then return false end
    if not M.spend(from_name, amount) then return false end
    M.add(to_name, amount)
    return true
end

return M
