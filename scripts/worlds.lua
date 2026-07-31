-- 公共世界：太空时代的五个真星球，有限大小，各自独立计时、错峰重置。
--
-- 为什么用真星球而不是 game.create_surface 造裸 surface：
--   真星球的 surface 带着星球原型级的全部机制（Fulgora 闪电、Aquilo 冻结、Vulcanus 巨虫领地、
--   各自的 autoplace 和表面属性基准）。裸 surface 只能靠 set_property 调几个数值，这些一个都拿不到。
--
-- 为什么要显式 create_surface：
--   SA 里星球 surface 是【玩家真的开船降落时】才由引擎创建的。新存档只有 nauvis，
--   其余四个在有人去过之前 game.surfaces['vulcanus'] 就是 nil。
--   force.unlock_space_location() 只解锁星图上的传送点，不创建 surface，这是两件事。
--   game.planets[name].create_surface() 才是把 surface 建出来的那个调用，幂等。
--
-- 为什么错峰：
--   五个星球同时重置的话，全服会在同一刻集体失去一切，节奏是一根锯齿。
--   错开之后，任何时刻都有"刚重置的新鲜世界"和"快到期的成熟世界"，玩家永远有地方去，
--   也永远有理由赶在某个世界到期前把东西搬走。
local constants = require('scripts.constants')
-- 提到顶层：函数体内 require 是 v1 遗留的潜伏 bug（只有公共世界重置走到 evacuate()
-- 时才会触发，一直没被发现）。pockets 只依赖 constants/ring/chests，均不依赖 worlds，
-- 提到顶层不会形成新环。
local pockets = require('scripts.pockets')

local M = {}

-- 确保五个星球的 surface 都存在。幂等，可以反复调。
function M.ensure_surfaces()
    for _, name in ipairs(constants.PUBLIC_PLANETS) do
        local planet = game.planets[name]
        if planet then
            planet.create_surface()   -- 已存在则什么都不做
        end
    end
end

-- 给公共世界套上有限边界，并可选地换一颗新种子。
--
-- width/height 是 MapGenSettings 的引擎级硬边界，边界外是 out-of-map，引擎不生成区块，
-- 存档体积从根上受控。
-- 【注意】改 map_gen_settings 只影响【之后生成】的区块，所以必须在 clear() 之前设好。
--
-- seed 传了才换。首次建面时不需要换（用星球自带的种子），
-- 重置时必须换 —— 否则 clear() 会用同一颗种子重新生成【同一张图】，
-- 「每轮都是新鲜世界」这个前提就垮了。
function M.apply_bounds(surface, seed)
    local size = storage.public_size or 2048
    local mgs = surface.map_gen_settings
    mgs.width = size
    mgs.height = size
    if seed then mgs.seed = seed end
    surface.map_gen_settings = mgs
end

-- 由星球名和轮次确定性地派生一颗种子。
--
-- 确定性（而不是 math.random）是有意的：同一个存档回滚重放会得到同样的地图，
-- 便于复现问题；而且多人下不依赖随机数状态，不会有同步隐患。
--
-- 用 bit32.bxor 而不是 5.3+ 的 `~` 运算符：Factorio 的场景脚本跑在 Lua 5.2 环境里，
-- 5.2 没有原生位运算符（`~` 在 5.2 里根本不是合法的二元运算符，会直接语法错误），
-- 只提供 bit32 库；本项目的 scripts/noise.lua 顶部 `local bit32_band = bit32.band`
-- 已经是这个环境里 bit32 可用、且是正确写法的实证。
--
-- 结果必须落在 uint32 范围内 —— Factorio 的 seed 是 uint32，超范围会被截断或报错。
function M.derive_seed(planet_name, run)
    local h = 2166136261                      -- FNV-1a 的 offset basis
    for i = 1, #planet_name do
        h = bit32.bxor(h, string.byte(planet_name, i)) * 16777619 % 4294967296
    end
    h = bit32.bxor(h, run) * 16777619 % 4294967296
    return h % 2147483647                     -- 保守地夹进 int32 正数范围
end

-- 错峰排期：把五个星球的首次重置时间均匀铺在一个周期里。
-- 第 i 个星球的首次重置在 period × i / N 处，之后每 period 重置一次，永远保持错开。
function M.schedule_all(force_respread)
    storage.world_reset_at = storage.world_reset_at or {}
    local period = (storage.world_reset_minutes or 120) * constants.min_to_tick
    local total = #constants.PUBLIC_PLANETS
    for i, name in ipairs(constants.PUBLIC_PLANETS) do
        if force_respread or not storage.world_reset_at[name] then
            storage.world_reset_at[name] = game.tick + math.floor(period * i / total)
        end
    end
end

-- 距离某世界下次重置还有多少 tick。GUI 倒计时用。负数表示已过期待处理。
function M.time_left(planet_name)
    storage.world_reset_at = storage.world_reset_at or {}
    return (storage.world_reset_at[planet_name] or game.tick) - game.tick
end

-- 把还留在某世界上的玩家撤回各自的口袋世界。重置前调用，避免把人清进虚空。
local function evacuate(surface)
    for _, player in pairs(game.connected_players) do
        if player.surface == surface then
            player.print({'pw.world-evacuated', surface.name})
            pockets.enter(player)
        end
    end
end

-- 重置单个公共世界：撤人 → 套边界 → 清空 → 排下一轮。
-- surface.clear(true) 是异步的，引擎会在结算后触发 on_surface_cleared，
-- 地形按新的 map_gen_settings 重新生成。
function M.reset_world(planet_name)
    local surface = game.surfaces[planet_name]
    if not surface or not surface.valid then return false end

    evacuate(surface)

    -- 种子要用【新一轮】的轮次号派生，所以先把 next_run 算出来（不落盘），
    -- 用它连同星球名派生新种子，随边界一起在 clear() 之前设好；
    -- 真正写回 storage.world_run 放到 clear() 之后，和原来的落盘时机保持一致。
    storage.world_run = storage.world_run or {}
    local next_run = (storage.world_run[planet_name] or 0) + 1
    local seed = M.derive_seed(planet_name, next_run)

    M.apply_bounds(surface, seed)
    surface.clear(true)

    storage.world_run[planet_name] = next_run

    storage.world_reset_at = storage.world_reset_at or {}
    storage.world_reset_at[planet_name] = game.tick + (storage.world_reset_minutes or 120) * constants.min_to_tick

    game.print({'pw.world-reset', planet_name, storage.world_run[planet_name]})
    return true
end

-- 周期任务：检查有没有世界到期。由 tick.lua 每分钟调用。
-- 一次只重置一个，即使多个同时到期也分开做，避免一 tick 内清多个 surface 造成卡顿尖峰。
function M.tick_check()
    storage.world_reset_at = storage.world_reset_at or {}
    for _, name in ipairs(constants.PUBLIC_PLANETS) do
        local at = storage.world_reset_at[name]
        if at and game.tick >= at then
            M.reset_world(name)
            return name
        end
    end
    return nil
end

-------------------------------------------------------------------------------
-- 科技丢失
--
-- 周期性判定：P(丢失) = k × 该科技的瓶子种数 / 100。
--
-- 为什么挂到瓶子种数而不是固定概率：固定 5% 的话，automation 和终局科技一样容易丢，
-- 玩家可能上线就发现造不出传送带。挂到种数上之后，科技树越深越容易漏水，地基反而最稳固。
-- 更重要的是它形成了一个自然的高度上限而不需要任何人为封顶：
-- 越往上侵蚀速率越高，全服最终停在「集体产能刚好补上漏水速度」的那个高度。
-- 水位由玩家的产能决定，不是由某个写死的数字决定。
--
-- 这是一个【独立周期任务】，不挂在星球重置上（不在 reset_world 里调）。
-- 挂到星球重置的话，科技丢失的节奏会被五个星球的周期（1/2/3/4/5 小时）绑架，
-- 玩家会把「地上的东西没了」和「图纸慢慢忘了」两条本来无关的压力线在心理上焊死。
-- 拆开之后各走各的周期，由 Task 12 的相位调度器按固定周期调用 M.tick_tech_loss()。
-------------------------------------------------------------------------------

-- 该科技配方里有几种【不重复的】科技瓶。
function M.pack_count(tech)
    local seen, count = {}, 0
    for _, ingredient in pairs(tech.research_unit_ingredients or {}) do
        if not seen[ingredient.name] then
            seen[ingredient.name] = true
            count = count + 1
        end
    end
    return count
end

-- 某科技这次被撤销的概率。不可丢的一律返回 0。
function M.loss_chance(tech)
    if not tech.researched then return 0 end

    local proto = tech.prototype
    -- Trigger 科技永不丢失：它们不是「研究」出来的而是触发出来的，
    -- 撤销后玩家没有合法途径重新拿到。
    -- 它们天然没有 research_unit_ingredients、n=0、概率本来就是 0，
    -- 但仍然显式跳过 —— 「规则恰好算出正确答案」和「规则明确表达意图」是两回事，
    -- 后者才经得起改动。
    if proto.research_trigger then return 0 end

    -- 无限科技不参与：它们 researched 恒为 false、用 level 计数，改 level 会让规则难以解释。
    if proto.max_level and proto.level and proto.level < proto.max_level then return 0 end

    return (storage.tech_loss_k or 1) * M.pack_count(tech) / 100
end

-- 全表期望丢失数。纯读取、无副作用 —— GUI 会频繁调它做重置预告，
-- 报一个「预计丢失约 X 项」比报百分比直观得多。
function M.expected_losses()
    local sum = 0
    for _, tech in pairs(game.forces.player.technologies) do
        sum = sum + M.loss_chance(tech)
    end
    return sum
end

-- 掷骰子，返回被撤销的科技名数组。
-- math.random 在 Factorio 里是确定性的、多人同步安全的，不要用 os.time/os.clock 之类的东西。
function M.roll_tech_loss()
    local lost = {}
    for name, tech in pairs(game.forces.player.technologies) do
        local chance = M.loss_chance(tech)
        if chance > 0 and math.random() < chance then
            tech.researched = false
            lost[#lost + 1] = name
        end
    end
    return lost
end

-- 周期任务：全服科技漏水判定一轮。由【未来的】Task 12 相位调度器按固定周期调用，
-- 【不】挂在星球重置上 —— 理由见本节顶部注释。
function M.tick_tech_loss()
    local lost = M.roll_tech_loss()
    if #lost > 0 then
        game.print({'pw.tech-lost', #lost, table.concat(lost, ', ')})
    end
    return #lost
end

-- 送玩家去某个公共世界的出生点。
function M.travel(player, planet_name)
    local surface = game.surfaces[planet_name]
    if not surface or not surface.valid then
        player.print({'pw.world-not-ready', planet_name})
        return false
    end
    local origin = player.force.get_spawn_position(surface)
    surface.request_to_generate_chunks(origin, 2)
    surface.force_generate_chunk_requests()
    local pos = surface.find_non_colliding_position('character', origin, 128, 1) or origin
    player.teleport(pos, surface)
    return true
end

return M
