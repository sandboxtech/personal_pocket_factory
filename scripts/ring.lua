-- 戴森环的涂砖与扩容。几何计算全部委托给 geometry.lua，本文件只负责把砖写进 surface。
--
-- 为什么是「无限地图 + 手工涂砖」而不是 v1 的「引擎硬边界」：
--   引擎硬边界（map_gen_settings.width/height）零成本，但只能是矩形，
--   而且在已存在的 surface 上能不能改大是未验证的。
--   新戴森环要「中间实心、左右临空、上下可增长」，硬边界做不出来。
--   于是横向仍用硬边界（width=32，白拿），纵向改成无限 + 自己涂 out-of-map 的墙。
--
-- 代价：存档体积不再由引擎兜底。但涂出来的墙是不可通行的，玩家走不过去，
-- 也就带不动引擎往外生成 —— 只有他站在边缘时引擎顺手预生成的两三个区块会溢出，涂掉留着即可。
local geometry = require('scripts.geometry')
local constants = require('scripts.constants')

local M = {}

local LEGACY_PREFIXES = {'ring_', 'ring2_', 'ring3_'}
local PUBLIC_PREFIX = 'public_'

local function private_maps()
    storage.private_ring_by_player = storage.private_ring_by_player or {}
    storage.private_ring_owner_by_surface = storage.private_ring_owner_by_surface or {}
    return storage.private_ring_by_player, storage.private_ring_owner_by_surface
end

local function player_from_ref(player_or_index)
    if type(player_or_index) == 'number' then return game.players[player_or_index] end
    return player_or_index
end

local function surface_owner_index(surface_name)
    local _, owners = private_maps()
    return owners[surface_name]
end

local function record_private_surface(player, surface_name)
    if not (player and player.valid and surface_name) then return end
    local by_player, owners = private_maps()
    local old_name = by_player[player.index]
    if old_name and old_name ~= surface_name then owners[old_name] = nil end
    by_player[player.index] = surface_name
    owners[surface_name] = player.index
end

local function fallback_private_name(player)
    return player.name .. '#' .. tostring(player.index)
end

function M.surface_name_for(player_or_index)
    local player = player_from_ref(player_or_index)
    if not (player and player.valid) then return nil end

    local by_player, owners = private_maps()
    local current_name = by_player[player.index]
    local current = current_name and game.surfaces[current_name]
    if current and current.valid then
        local desired = player.name
        local conflict = game.surfaces[desired]
        if current.name ~= desired and (not conflict or surface_owner_index(desired) == player.index) then
            local old_name = current.name
            local ok = pcall(function() current.name = desired end)
            if ok then
                owners[old_name] = nil
                record_private_surface(player, desired)
                return desired
            end
        end
        return current.name
    end

    local desired = player.name
    local existing = game.surfaces[desired]
    if existing and existing.valid then
        if owners[desired] == player.index then
            by_player[player.index] = desired
            return desired
        end
        desired = fallback_private_name(player)
        local n = 2
        while game.surfaces[desired] and owners[desired] ~= player.index do
            desired = fallback_private_name(player) .. '_' .. tostring(n)
            n = n + 1
        end
    end
    by_player[player.index] = desired
    return desired
end

function M.record_private_surface(player, surface_name)
    record_private_surface(player, surface_name)
end

function M.forget_private_surface(player)
    if not (player and player.valid) then return end
    local by_player, owners = private_maps()
    local old_name = by_player[player.index]
    if old_name then owners[old_name] = nil end
    by_player[player.index] = nil
end

-- 只看名字，不要求 surface 还存在。给「surface 已经被删掉，但手上还有它的名字」
-- 那类场合用（比如登记表里留下的旧坐标、聊天播报里回溯一个已消失的平面）。
function M.is_ring_name(surface_name)
    if type(surface_name) ~= 'string' then return false end
    if surface_owner_index(surface_name) then return true end
    if string.sub(surface_name, 1, #PUBLIC_PREFIX) == PUBLIC_PREFIX then return true end
    for _, prefix in ipairs(LEGACY_PREFIXES) do
        if string.sub(surface_name, 1, #prefix) == prefix then return true end
    end
    return false
end

function M.is_public_ring_name(surface_name)
    if type(surface_name) ~= 'string' then return false end
    return string.sub(surface_name, 1, #PUBLIC_PREFIX) == PUBLIC_PREFIX
end

function M.is_legacy_ring_name(surface_name)
    if type(surface_name) ~= 'string' then return false end
    for _, prefix in ipairs(LEGACY_PREFIXES) do
        if string.sub(surface_name, 1, #prefix) == prefix then return true end
    end
    return false
end

function M.public_ring_name_for(id)
    return PUBLIC_PREFIX .. tostring(id)
end

function M.public_ring_id_of_name(surface_name)
    if not M.is_public_ring_name(surface_name) then return nil end
    return tonumber(string.sub(surface_name, #PUBLIC_PREFIX + 1))
end

function M.owner_index_of_name(surface_name)
    if type(surface_name) ~= 'string' then return nil end
    local mapped = surface_owner_index(surface_name)
    if mapped then return mapped end
    for _, prefix in ipairs(LEGACY_PREFIXES) do
        if string.sub(surface_name, 1, #prefix) == prefix then
            return tonumber(string.sub(surface_name, #prefix + 1))
        end
    end
    return nil
end

function M.is_ring_surface(surface)
    if not (surface and surface.valid) then return false end
    return M.is_ring_name(surface.name)
end

-- surface 名反查玩家名。surface 名里存的是 player.index（玩家名可能含非法字符），
-- 而 storage 一律按玩家名索引（改名后仍能继承），所以这里要转一道。
function M.owner_name_of(surface)
    if not M.is_ring_surface(surface) then return nil end
    local index = M.owner_index_of_name(surface.name)
    if not index then return nil end
    local player = game.players[index]
    return player and player.name or nil
end

function M.level_of(player_name)
    local exp = constants.ensure_exp_table(player_name)
    return geometry.ring_level(exp)
end

function M.half_length_of(player_name)
    return geometry.half_length(
        M.level_of(player_name),
        storage.ring_base_half_length or 32,
        storage.ring_length_per_level or 16,
        storage.ring_length_bonus or 4)
end

M.half_width_of = M.half_length_of

-- 保证 [x_from, x_to) × [y_from, y_to) 这片区域内的区块都已生成。
-- 逐区块请求而不是给一个大半径 —— request_to_generate_chunks 的 radius 是【正方形】的，
-- 横向多请求无所谓（引擎 width 硬边界会挡掉），纵向却会真的生成出去，
-- 每个新玩家白造上百个废区块。存档体积是本项目的头号约束，不能这么浪费。
function M.ensure_chunks(surface, x_from, x_to, y_from, y_to)
    local cx_from = math.floor(x_from / 32)
    local cx_to   = math.floor((x_to - 1) / 32)
    local cy_from = math.floor(y_from / 32)
    local cy_to   = math.floor((y_to - 1) / 32)
    for cx = cx_from, cx_to do
        for cy = cy_from, cy_to do
            -- 半径传 0 = 只要这一个区块；中心点用区块中心更稳妥。
            surface.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0)
        end
    end
    surface.force_generate_chunk_requests()
end

-- 把 [x_from, x_to) × [y_from, y_to) 的区域按几何规则涂一遍。
-- 一次 set_tiles 批量提交，不要逐 tile 调（那样会触发一堆事件、慢得多）。
--
-- 调用方须保证这个矩形没有跨到未生成的区块 —— 涂到未生成的区块上要么被引擎静默丢弃
-- （白费一次 set_tiles），要么抛错被 events 的 pcall 吞掉、留下涂错却没人发现的砖。
-- on_chunk_generated 每次只传本区块的范围，apply_growth 逐区块行调用，都是为了这条。
function M.paint_area(surface, x_from, x_to, y_from, y_to, half_length, layout)
    local orientation = (layout and layout.orientation) or 'vertical'
    local ring_width
    local concrete_width
    local base_half_length
    if orientation == 'horizontal' then
        ring_width = (layout and layout.ring_height) or 64
        concrete_width = (layout and layout.concrete_height) or 32
        base_half_length = (layout and layout.base_half_width) or 32
    else
        ring_width = (layout and layout.ring_width) or storage.ring_width or 32
        concrete_width = (layout and layout.concrete_width) or storage.ring_concrete_width or 16
        base_half_length = (layout and layout.base_half_length) or storage.ring_base_half_length or 32
    end
    local pond_half = (layout and layout.pond_half) or storage.ring_pond_half or 2
    -- geometry.lua 只返回语义值（'start'/'grown'/'space'/'void'），
    -- 真正的砖原型名查这张表。取不到时兜底成墙，绝不把 nil 塞进 set_tiles。
    local ring_tiles = storage.ring_tiles or {}

    local tiles = {}
    for x = x_from, x_to - 1 do
        for y = y_from, y_to - 1 do
            local semantic = geometry.tile_at(
                x, y, half_length, ring_width, concrete_width, base_half_length, pond_half, orientation)
            tiles[#tiles + 1] = {
                name = ring_tiles[semantic] or 'out-of-map',
                position = {x, y},
            }
        end
    end
    if #tiles > 0 then
        -- correct_tiles=false：本场景的砖是脚本完全掌控的，不需要引擎做过渡处理。
        -- remove_colliding_entities=false：绝不因为涂砖删掉玩家的建筑。
        surface.set_tiles(tiles, false, false)
    end
end

-- 新区块生成时涂砖。只涂【触发事件的这一个区块】，不涂整条环宽带——
-- 32 宽会跨 2 个区块列，同一批生成里先到的那一列如果涂整条带，
-- 会往还没生成的兄弟区块里 set_tiles（要么被引擎丢弃白做一次，要么抛错被 pcall 吞掉、
-- 留下涂错却没人发现的砖）。引擎保证只有 |x| < ring_width/2 的区块会来，横向不用额外判断。
function M.on_chunk_generated(event)
    local surface = event.surface
    if not M.is_ring_surface(surface) then return end
    local owner = M.owner_name_of(surface)
    local public_record = nil
    if not owner then
        public_record = storage.public_rings and storage.public_rings[surface.name]
        if not public_record then return end
    end

    local area = event.area
    M.paint_area(surface,
        math.floor(area.left_top.x), math.floor(area.right_bottom.x),
        math.floor(area.left_top.y), math.floor(area.right_bottom.y),
        owner and M.half_length_of(owner) or public_record.half_length or public_record.half_width,
        public_record)
end

local function paint_chunked(surface, x_from, x_to, y_from, y_to, half_length)
    M.ensure_chunks(surface, x_from, x_to, y_from, y_to)
    local cx_from = math.floor(x_from / 32)
    local cx_to   = math.floor((x_to - 1) / 32)
    local cy_from = math.floor(y_from / 32)
    local cy_to   = math.floor((y_to - 1) / 32)
    for cx = cx_from, cx_to do
        for cy = cy_from, cy_to do
            local x0 = math.max(x_from, cx * 32)
            local x1 = math.min(x_to, (cx + 1) * 32)
            local y0 = math.max(y_from, cy * 32)
            local y1 = math.min(y_to, (cy + 1) * 32)
            M.paint_area(surface, x0, x1, y0, y1, half_length)
        end
    end
end

-- 等级变化后扩容。只涂【新增的上下两段】，不碰玩家已经建过东西的老地皮。
--
-- 【关键约束】本函数绝不能把玩家铺的太空平台基座刷回 empty-space。
-- 目前天然安全：新增长度此前是 out-of-map 或环外溢出的临空带，玩家不可能在上面铺过东西。
-- 将来若加「重新校准全环砖块」之类的功能，这是第一个会被踩坏的东西。
function M.apply_growth(player)
    if not (player and player.valid) then return false end
    local surface = game.surfaces[M.surface_name_for(player)]
    if not (surface and surface.valid) then return false end

    storage.ring_applied_half_length = storage.ring_applied_half_length or {}
    local old_half = storage.ring_applied_half_length[player.name] or 0
    local new_half = M.half_length_of(player.name)
    if new_half <= old_half then return false end

    local ring_width = storage.ring_width or 32
    local x_half = math.floor(ring_width / 2)

    -- 新增长度需要覆盖两种区块：新生成的（on_chunk_generated 会自动涂，但那时机不确定，
    -- 显式再涂一遍是幂等的）和本来就存在的（之前作为环外溢出被生成、涂成 out-of-map 的，
    -- 不会再触发生成事件，必须在这里显式重涂）。
    paint_chunked(surface, -x_half, x_half, -new_half, -old_half, new_half)
    paint_chunked(surface, -x_half, x_half, old_half, new_half, new_half)

    storage.ring_applied_half_length[player.name] = new_half
    return true
end

return M
