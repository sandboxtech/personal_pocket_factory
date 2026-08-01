-- 通用工具函数：无状态、无副作用，任何模块都可以 require。
local constants = require('scripts.constants')
local ring = require('scripts.ring')

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

-- 星球名 → 带图标的本地化标签，形如 "[planet=nauvis] Nauvis"。
-- GUI 里任何要展示星球名字的地方（尤其是 tooltip）都不该甩一个原始 surface 名当纯文本——
-- 那既没图标也没跟着客户端语言翻译。space-location-name.<name> 是引擎自带的本地化 key
-- （base/space-age 两个 mod 的 locale 都注册了这一节，Nauvis/Vulcanus/.../solar-system-edge
-- 全部覆盖），直接嵌套引用即可，不用在本 mod 里再抄一份星球名翻译。
function M.planet_label(name)
    return {'', '[planet=' .. name .. '] ', {'space-location-name.' .. name}}
end

-- 任意 surface 名 → 带图标的可读标签。
--
-- 【规则：凡是要让玩家看到"某个平面"的地方，一律走这里，绝不甩裸 surface 名】。
-- 裸名有三重问题：没图标、不跟客户端语言翻译、而且对戴森环来说 'ring_7' 这种内部标识
-- 对玩家完全没有意义 —— 他看到"你在 ring_7 的投递口没了"根本不知道说的是谁家。
--
-- 三种平面各自的处理：
--   · 五个公共星球 → planet_label，图标 + 引擎自带的星球名翻译
--   · 戴森环       → "某某的戴森环"，用星图边缘那个图标（和 HUD 上的回环按钮一致）
--   · 太空平台     → 平台名本来就是玩家自己取的，配个起步包图标即可
function M.surface_label(surface_name)
    if not surface_name then return '?' end

    -- 星球判定走原型表而不是 constants.PUBLIC_PLANETS：即便将来公共星球名单变了，
    -- 一个真星球的 surface 名也永远能在这里被认出来。
    if prototypes.space_location[surface_name] then
        return M.planet_label(surface_name)
    end

    local surface = game.surfaces[surface_name]
    if surface and surface.valid then
        if ring.is_ring_surface(surface) then
            local owner = ring.owner_name_of(surface)
            if owner then return {'pw.label-ring-of', owner} end
            return {'pw.label-ring'}
        end
        local platform = surface.platform
        if platform and platform.valid then
            return {'', '[item=space-platform-starter-pack] ', platform.name}
        end
    end

    -- surface 已经不存在了（被删掉的戴森环、重置中的世界）。名字里还能认出是戴森环的，
    -- 仍然给一个像样的说法，而不是把 'ring_7' 甩给玩家。
    if ring.is_ring_name(surface_name) then return {'pw.label-ring'} end
    return surface_name
end

return M
