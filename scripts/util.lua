-- 通用工具函数：无状态、无副作用，任何模块都可以 require。
local M = {}

-- 大数字转可读串：12345 → 12.3k，1234567 → 1.23M。用于 GUI 展示经验/资源数量。
function M.readable(x)
    x = x or 0
    if x >= 1e9 then return string.format('%.2fG', x / 1e9) end
    if x >= 1e6 then return string.format('%.2fM', x / 1e6) end
    if x >= 1e3 then return string.format('%.1fk', x / 1e3) end
    return tostring(math.floor(x))
end

-- 经验 → 等级：level = floor(sqrt(exp))。与 endfield_factorio 同口径，方便老玩家理解。
-- 平方曲线意味着升到 N 级需要 N² 经验，前期快、后期慢，且没有等级上限。
function M.level_of(exp)
    return math.floor(math.sqrt(math.max(0, exp or 0)))
end

-- 升到下一级还差多少经验。GUI 进度条用。
function M.exp_to_next(exp)
    local lv = M.level_of(exp)
    return (lv + 1) * (lv + 1) - (exp or 0)
end

-- 文本进度条：frac ∈ [0,1] → '████░░░░░░'。GUI 里不用图片资源就能画条。
function M.progress_bar(frac, width)
    width = width or 10
    frac = math.max(0, math.min(1, frac or 0))
    local filled = math.floor(frac * width + 0.5)
    return string.rep('█', filled) .. string.rep('░', width - filled)
end

-- 安全取玩家的【本体角色实体】，不经过 player.controller：
--   · 正常控制时 = player.character；
--   · 玩家切到【地图/遥控视角】时 player.character 变 nil，但本体角色仍被引擎 associate 到该玩家。
-- 这样不管玩家在什么视角，只要角色还活着就能拿到背包；真·无角色(死亡)才返回 nil。
function M.body_character(player)
    if not player then return nil end
    if player.character and player.character.valid then return player.character end
    for _, c in pairs(player.get_associated_characters()) do
        if c.valid then return c end
    end
    return nil
end

-- 取玩家主背包 inventory，没有则 nil。
function M.main_inventory(player)
    local character = M.body_character(player)
    if not character then return nil end
    return character.get_inventory(defines.inventory.character_main)
end

return M
