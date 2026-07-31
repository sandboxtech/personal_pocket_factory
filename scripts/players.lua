-- 玩家生命周期 + 权限组。
--
-- 单 force 设计：所有玩家都留在 game.forces.player，本场景不创建任何额外 force。
-- 理由是 chart（地图勘探数据）是 per force per surface per chunk 存的，
-- 引擎按 RGB565 每像素 2 字节存原始像素（见 LuaForce::get_chunk_chart 的文档），
-- 每多一个 force 就多存一整份地图。人数一多，光 chart 就能把存档撑到几十 MB。
-- 产权隔离本场景靠"每人一个独立 surface"实现，不需要用 force 来隔。
local constants = require('scripts.constants')
local events = require('scripts.events')
local pockets = require('scripts.pockets')

local M = {}

-- 本场景【默认不禁用玩家任何权限】，包括蓝图库。
--
-- v1 禁蓝图的理由是「允许蓝图库的话，重置后 Ctrl+V 一秒恢复布局，重置就只剩重跑一遍物流」。
-- 但这条理由在本版已经不成立：重置的是【公共世界】，而玩家的产线在【戴森环】里，
-- 本来就不会被重置。公共世界上只有采集前哨，那本来就该是能快速重铺的东西。
-- 本版真正的持续压力来自科技漏水和弃厂公有化，蓝图一个都加速不了。
--
-- 关联箱的防偷因此不能靠权限组，改用实体级的 operable = false，见 chests.lua。
local BLOCKED_ACTIONS = {}

local GROUP_NAME = 'pw_default'

-- 建（或取）本场景的权限组，并按 storage.block_blueprint_library 配置禁用动作。
-- defines.input_action[name] 取不到时（版本改名/拼错）返回 nil，直接传给 set_allows_action 会崩，
-- 所以逐个校验、跳过并写 log。
function M.setup_perm_group()
    local perms = game.permissions
    local group = perms.get_group(GROUP_NAME) or perms.create_group(GROUP_NAME)
    if not group then return nil end

    local blocked = storage.block_blueprint_library ~= false
    for _, action_name in ipairs(BLOCKED_ACTIONS) do
        local action = defines.input_action[action_name]
        if action then
            group.set_allows_action(action, not blocked)
        else
            log('[pw] 权限组跳过无效 input_action 名: ' .. tostring(action_name))
        end
    end
    return group
end

-- 把玩家放进本场景的权限组。管理员想手动调用 /permissions 改组的话，脚本不会覆盖组内动作配置。
local function assign_group(player)
    local group = game.permissions.get_group(GROUP_NAME) or M.setup_perm_group()
    if group then group.add_player(player) end
end

-- 新玩家的起手物资。口袋世界没有资源，不给起手就真的寸步难行。
local STARTER_ITEMS = {
    {name = 'iron-plate', count = 100},
    {name = 'copper-plate', count = 100},
    {name = 'stone-furnace', count = 4},
    {name = 'burner-mining-drill', count = 2},
    {name = 'wood', count = 20},
    {name = 'pistol', count = 1},
    {name = 'firearm-magazine', count = 20},
}

local function grant_starter(player)
    for _, item in ipairs(STARTER_ITEMS) do
        if prototypes.item[item.name] then
            player.insert(item)
        end
    end
end

events.on(defines.events.on_player_created, function(event)
    local player = game.players[event.player_index]
    if not player then return end

    player.force = game.forces.player   -- 单 force：显式钉死，不给任何人开新 force
    assign_group(player)
    pockets.enter(player)
    grant_starter(player)
    player.print({'pw.welcome'})
end)

events.on(defines.events.on_player_joined_game, function(event)
    local player = game.players[event.player_index]
    if not player then return end
    assign_group(player)
    -- 离线期间环被回收过的话，这里重建。玩家不会掉进一个已经不存在的 surface。
    if not pockets.get(player) then
        pockets.enter(player)
        player.print({'pw.ring-rebuilt'})
    else
        -- 公共期回来的话立刻收回：箱子换回个人 id，访客请出去
        pockets.restore_on_join(player)
    end
end)

events.on(defines.events.on_player_respawned, function(event)
    local player = game.players[event.player_index]
    if not player then return end
    -- 死了一律回自己的口袋世界，这里是唯一安全的地方
    pockets.enter(player)
end)

return M
