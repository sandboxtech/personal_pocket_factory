-- 通用工具函数：无状态、无副作用，任何模块都可以 require。
local constants = require('scripts.constants')

local M = {}

-- 大数字转可读串：12345 → 12.3k，1234567 → 1.23M。用于 GUI 展示经验/资源数量。
function M.readable(x)
    x = x or 0
    if x >= 1e9 then return string.format('%.2fG', x / 1e9) end
    if x >= 1e6 then return string.format('%.2fM', x / 1e6) end
    if x >= 1e3 then return string.format('%.1fk', x / 1e3) end
    return tostring(math.floor(x))
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

-- 是否是「老玩家」：累计在线时长够长，界面上给他看更多细节。
-- 新人看到的界面要清爽，先把「怎么玩」看明白，再谈那些需要经验才用得上的数字。
--
-- player.online_time 是这个存档里该玩家【全部会话累计】的在线 tick 数
-- （跨重连、跨断线续玩持续累加，不是"这一次会话"的时长），单机测试或没有
-- 存档历史时可能是 0，此时按新人处理，不会因为字段缺失而报错。
function M.is_veteran(player)
    if not player then return false end
    local hours = storage.detail_hours or 6
    return (player.online_time or 0) >= hours * constants.hour_to_tick
end

return M
