-- 体力双池系统。沿用 endfield_factorio「星星」机制的形状：随时间恢复、离线也在攒、攒到上限就不再涨。
--
-- 存储形态：storage.stamina[玩家名] = {
--     last    = 上次结算的 tick,
--     pending = 【可领取池】，单位 tick，上限 stamina_pending_cap 点对应的 tick 数,
--     balance = 【体力池】，单位【点】，上限 stamina_balance_cap 点,
-- }
--
-- 关键细节（照抄 endfield 的 show_star / claim_charge）：可领取池按 tick 存，只在显示
-- 或领取时才换算成"点"。如果按点存，每次结算跨过半点就得决定丢掉还是四舍五入——
-- 丢零头长期少给，四舍五入长期多给，两种都会随时间累积出偏差。存 tick 全程整数精确，
-- 结算只前进"当前 tick"，领取只扣走"凑够整点"的那部分 tick，余数原样留在 pending 里，
-- 所以不管领取的时机多凑巧，都不会多给也不会少给。
--
-- 体力池（balance）本身只在 claim / add 里以整点数变动，不存在换算，天然没有零头问题。
--
-- 两个上限（stamina_pending_cap / stamina_balance_cap）直接配点数，不再按小时换算——
-- 老版本是"配小时数，乘 hour_to_tick 再折算成点"，本版直接把点数写进 storage，
-- pending 因为内部按 tick 存，仍要在这里把"点上限"换算成"tick 上限"；
-- balance 本来就按点存，点上限直接读、直接比较即可。

local M = {}

-- 每点体力需要多少 tick。
local function ticks_per_point()
    return math.max(1, storage.stamina_ticks_per_point or 3600)
end

-- 可领取池（pending）的 tick 上限：点数上限 × 每点的 tick 数。
local function pending_cap_ticks()
    return math.max(0, (storage.stamina_pending_cap or 100000) * ticks_per_point())
end

-- 体力池（balance）的点数上限：直接就是配置的点数，无需换算。
local function balance_cap_points()
    return math.max(0, storage.stamina_balance_cap or 10000000)
end

-- 可领取池满额时对应多少点。HUD 显示"可领 X / 上限 Y"用。
function M.pending_cap_points()
    return math.max(0, storage.stamina_pending_cap or 100000)
end

-- 体力池的点数上限。HUD 显示"余额 X / 上限 Y"用。
function M.balance_cap_points()
    return balance_cap_points()
end

-- 取（并按需创建）某玩家的体力记录。新记录从 last=当前 tick、两池皆空开始。
local function record(name)
    storage.stamina = storage.stamina or {}
    local rec = storage.stamina[name]
    if not rec then
        rec = {last = game.tick, pending = 0, balance = 0}
        storage.stamina[name] = rec
    end
    return rec
end

-- 结算：把「上次结算到现在」这段时间折算进 pending（封顶），last 推到当前 tick。
-- 所有读写体力的入口都先调用它。pending 全程按 tick 存、直接前进 last 到 now，
-- 不需要像"按点结算"那样为保留余数而分两步推进，天然没有漂移。
function M.settle(player_name)
    local rec = record(player_name)
    local now = game.tick
    local elapsed = now - (rec.last or now)
    if elapsed > 0 then
        rec.pending = math.min(pending_cap_ticks(), (rec.pending or 0) + elapsed)
    end
    rec.last = now
    return rec
end

-- 当前可领取池的 tick 数（已结算）。
function M.pending_ticks(player_name)
    return M.settle(player_name).pending or 0
end

-- 可领取的整点数（不足一点的部分留在 pending 里，不会被截断丢弃）。
function M.claimable(player_name)
    return math.floor(M.pending_ticks(player_name) / ticks_per_point())
end

-- 可领取池的进度，夹在 [0,1]，HUD 进度条用。
function M.pending_fraction(player_name)
    local cap = pending_cap_ticks()
    if cap <= 0 then return 0 end
    return math.max(0, math.min(1, M.pending_ticks(player_name) / cap))
end

-- 体力池当前点数（已结算）。
function M.balance(player_name)
    return M.settle(player_name).balance or 0
end

-- 领取：把 pending 里凑够的整点数转入 balance（封顶），pending 保留不足一点的余数。
-- 体力池已满时领不进去（room 会截断到 0）。返回实际领取的点数。
function M.claim(player_name)
    local rec = M.settle(player_name)
    local per = ticks_per_point()
    local n = math.floor((rec.pending or 0) / per)
    local room = balance_cap_points() - (rec.balance or 0)
    n = math.max(0, math.min(n, room))
    if n <= 0 then return 0 end
    rec.balance = (rec.balance or 0) + n
    rec.pending = (rec.pending or 0) - n * per
    return n
end

-- 扣体力点数。够扣返回 true 并扣除，不够返回 false 且不改动。
function M.spend(player_name, points)
    points = math.floor(points or 0)
    if points <= 0 then return true end
    local rec = M.settle(player_name)
    if (rec.balance or 0) < points then return false end
    rec.balance = rec.balance - points
    return true
end

-- 直接加体力点数（管理员补偿 / 新玩家初始赠送用），封顶。
function M.add(player_name, points)
    points = math.floor(points or 0)
    if points == 0 then return end
    local rec = M.settle(player_name)
    rec.balance = math.max(0, math.min(balance_cap_points(), (rec.balance or 0) + points))
end

return M
