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
-- util 只依赖 constants 和 ring，两者都不反向依赖 worlds，顶层 require 不成环。
local util = require('scripts.util')

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
-- 把矿脉调大。
--
-- 【为什么公共世界的矿必须比原版夸张】：这些星球一两个小时就清空一次。
-- 原版的矿脉尺寸是按「一局几十小时、慢慢铺开」调的，放在这里就意味着玩家刚把采矿场
-- 建起来、传送带刚接通，世界就没了 —— 建设时间占了整轮的大半，真正产出的时间没多少。
-- 调大矿脉不是放水，是把「单位时间能挖多少」拉回到和世界寿命匹配的量级。
--
-- 【遍历 prototypes.autoplace_control 按 category 挑，而不是写死矿物名单】：
-- 五个星球的矿完全不同（钨、方解石、废料、锂……），写死名单必然漏，
-- 而且漏掉的那个星球会安静地保持原版尺寸，没人会发现。
-- category == 'resource' 是引擎自己给的分类，新增 mod 矿也会自动被覆盖到。
-- 地形/悬崖/敌人（terrain/cliff/enemy）不动：那些不是产出，调了只会改变地貌观感。
local function boost_resources(mgs)
    local boost = storage.world_resource_boost
    if type(boost) ~= 'table' then return end

    mgs.autoplace_controls = mgs.autoplace_controls or {}
    for name, proto in pairs(prototypes.autoplace_control) do
        if proto.category == 'resource' then
            local c = mgs.autoplace_controls[name] or {}
            c.size = boost.size or c.size
            c.frequency = boost.frequency or c.frequency
            -- richness 不是每种矿都支持（proto.richness 说明它认不认这个字段）。
            -- 对不支持的矿硬塞 richness 是无意义的，跳过更干净。
            if proto.richness then c.richness = boost.richness or c.richness end
            mgs.autoplace_controls[name] = c
        end
    end
end

function M.apply_bounds(surface, seed)
    local size = storage.public_size or 2048
    local mgs = surface.map_gen_settings
    mgs.width = size
    mgs.height = size
    if seed then mgs.seed = seed end
    boost_resources(mgs)
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

-- 某星球的重置周期（tick）。配置缺项时兜底 120 分钟。
--
-- 【按名字索引】storage.world_reset_minutes——它是个 {星球名 = 分钟} 的 table，
-- 不是数组，绝不能按下标取，见 constants.lua 里那张表旁边的顺序警告。
function M.period_of(planet_name)
    local t = storage.world_reset_minutes
    local minutes = (type(t) == 'table' and t[planet_name]) or 120
    return minutes * constants.min_to_tick
end

-- 错峰排期：每个星球按【自己的】周期首次排期，且第 i 个星球（i 从 0 开始）
-- 额外再往后错开 i × offset 分钟，保证从第一轮起就互不重合，不用等转完一整圈。
--
-- 为什么这样就永不撞车（纯算术，不需要任何运行时冲突检测；见文末的模拟脚本验证）：
-- 五个周期（60/120/180/240/300 分钟）全都是 60 分钟的整数倍，偏移是 0/10/20/30/40 分钟。
-- 一个星球此后【每一次】重置时刻 = 首次时刻 + k × 自己的周期（k = 0,1,2,...），
-- 而"自己的周期"本身是 60 分钟的整数倍，所以不管 k 是多少，
-- 这个时刻对 60 分钟取余恒等于首次时刻对 60 分钟取余，也就是恒等于
-- （某个所有星球共享的基准偏移 + 该星球的 i × 10 分钟）对 60 取余。
-- 五个 i × 10（0/10/20/30/40）两两不同，所以任何两个星球的重置时刻
-- 永远落在 mod 60 的不同余数上，永远不可能重合。
function M.schedule_all(force_respread)
    storage.world_reset_at = storage.world_reset_at or {}
    local offset = (storage.world_reset_offset_minutes or 10) * constants.min_to_tick
    for i, name in ipairs(constants.PUBLIC_PLANETS) do
        if force_respread or not storage.world_reset_at[name] then
            storage.world_reset_at[name] = game.tick + M.period_of(name) + (i - 1) * offset
        end
    end
end

-- 距离某世界下次重置还有多少 tick。GUI 倒计时用。负数表示已过期待处理。
function M.time_left(planet_name)
    storage.world_reset_at = storage.world_reset_at or {}
    return (storage.world_reset_at[planet_name] or game.tick) - game.tick
end

-- 五个公共世界里，最近一个到期时刻。没有任何世界排期过时返回 nil。
-- tick.lua 拿它做门控：查"下一个到期时刻是不是已经到了"，
-- 而不是像 v1 那样用一个和真实周期无关的取模常数（3607）去隔几十秒抽查一次。
function M.next_reset_at()
    storage.world_reset_at = storage.world_reset_at or {}
    local nearest = nil
    for _, name in ipairs(constants.PUBLIC_PLANETS) do
        local at = storage.world_reset_at[name]
        if at and (not nearest or at < nearest) then nearest = at end
    end
    return nearest
end

-- 把还留在某世界上的玩家撤回各自的口袋世界。重置前调用，避免把人清进虚空。
local function evacuate(surface)
    for _, player in pairs(game.connected_players) do
        if player.surface == surface then
            player.print({'pw.world-evacuated', util.surface_label(surface.name)})
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
    storage.world_reset_at[planet_name] = game.tick + M.period_of(planet_name)

    game.print({'pw.world-reset', util.surface_label(planet_name), storage.world_run[planet_name]})
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
-- 拆开之后各走各的周期，由 scripts/tick.lua 的相位调度器按固定周期调用 M.tick_tech_loss()。
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

-- 这个科技能不能「掉一级」——等级制科技（无限科技，以及有限的多级科技）专用。
--
-- proto.level 是这个科技的【起始等级】，tech.level 是它【当前所在的等级】。
-- 二者相等说明一级都还没研究出来，没有东西可掉；tech.level 更大才说明
-- 玩家已经把它推高过，有已研究的级数可以往回退。
--
-- LuaTechnology.level 是可写的，引擎文档原话：
-- "For level-based technology writing to this is the same as researching the
--  technology to the previous level."
-- 也就是说 tech.level = tech.level - 1 恰好等价于「退掉最近研究的那一级」，
-- 不需要自己去撤销任何加成效果。
function M.can_downgrade(tech)
    local proto = tech.prototype
    local base = proto.level or 1
    return (tech.level or base) > base
end

-- 某科技这次被侵蚀的概率。没有东西可丢的一律返回 0。
function M.loss_chance(tech)
    local proto = tech.prototype
    -- Trigger 科技永不丢失：它们不是「研究」出来的而是触发出来的，
    -- 撤销后玩家没有合法途径重新拿到。
    -- 它们天然没有 research_unit_ingredients、n=0、概率本来就是 0，
    -- 但仍然显式跳过 —— 「规则恰好算出正确答案」和「规则明确表达意图」是两回事，
    -- 后者才经得起改动。
    if proto.research_trigger then return 0 end

    -- 「有东西可丢」的两种形态，缺一不可：
    --   · 普通科技：researched == true，丢法是整个撤销；
    --   · 等级制/无限科技：researched 恒为 false（永远还能再研究一级），
    --     但只要当前等级高于起始等级，就有已研究的级数可以掉。
    -- 无限科技【参与】侵蚀是有意的：它们往往是后期产能的主要来源，
    -- 若整类豁免，玩家把产能全压在无限科技上就能完全绕开漏水机制。
    -- 丢法改成「降一级」而不是「清零」，是因为无限科技根本没有「未研究」这个状态可回退，
    -- 而且清零几十级的采矿产能在体感上是灭顶之灾，不是持续压力。
    if not (tech.researched or M.can_downgrade(tech)) then return 0 end

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

-- 掷骰子。返回两个数组：被整个撤销的科技名、被降级的科技（带降到第几级）。
-- math.random 在 Factorio 里是确定性的、多人同步安全的，不要用 os.time/os.clock 之类的东西。
--
-- 【判定顺序】先问「能不能降级」，再问「是不是已研究」，不能反过来：
-- 有限的多级科技研究到顶之后 researched 会变成 true，先判 researched 的话
-- 就会把一个 20 级的科技一次性清成未研究，而不是老老实实退一级。
-- 普通单级科技 proto.level == tech.level == 1，can_downgrade 返回 false，
-- 自然落到下面那支，行为和以前完全一致。
function M.roll_tech_loss()
    local lost, downgraded = {}, {}
    for name, tech in pairs(game.forces.player.technologies) do
        local chance = M.loss_chance(tech)
        if chance > 0 and math.random() < chance then
            -- 播报里用 [technology=名字] 富文本而不是裸科技名：
            -- 裸名是内部标识（'productivity-module-3' 这种），既不跟客户端语言翻译，
            -- 一次掉七八项时也是一大串没人读得下去的英文。图标一眼能认，鼠标悬停还有原生 tooltip。
            -- 这个标签是引擎原生的，Factorio 自带 locale 里就在用（[technology=legendary-quality]）。
            local icon = '[technology=' .. name .. ']'
            if M.can_downgrade(tech) then
                local new_level = tech.level - 1
                tech.level = new_level
                -- 降级必须带上退到第几级，只给个图标玩家不知道损失了多少
                downgraded[#downgraded + 1] = icon .. ' Lv.' .. new_level
            elseif tech.researched then
                tech.researched = false
                lost[#lost + 1] = icon
            end
        end
    end
    return lost, downgraded
end

-- 周期任务：全服科技漏水判定一轮。由 scripts/tick.lua 的相位调度器按固定周期调用，
-- 【不】挂在星球重置上 —— 理由见本节顶部注释。
function M.tick_tech_loss()
    local lost, downgraded = M.roll_tech_loss()
    if #lost > 0 then
        game.print({'pw.tech-lost', #lost, table.concat(lost, ' ')})
    end
    -- 降级单独播报：对玩家来说「某科技没了」和「某科技退了一级」是两件要分开应对的事，
    -- 混进同一条消息里会让人误以为无限科技被清零了。
    if #downgraded > 0 then
        game.print({'pw.tech-downgraded', #downgraded, table.concat(downgraded, '  ')})
    end
    return #lost + #downgraded
end

-- 距离下一次科技流失判定还剩多少 tick，供传送页面做倒计时。
--
-- storage.tech_loss_next_at 由 scripts/tick.lua 的相位调度器维护
-- （它是 storage.cycle_next_at['tech_loss'] 的一份镜像）。这里选择"worlds 只读、
-- tick 负责写"而不是让本函数转调 tick.time_left('tech_loss')，是因为依赖方向
-- 已经定死为单向：tick.lua 在模块顶层 require 了 worlds（调度 tick_tech_loss 要用到），
-- Factorio 又不允许在函数体内 require 来延迟绕开循环，所以 worlds 绝对不能反过来
-- require tick。选择"tick 写、worlds 读"这个方向，两边都只在顶层 require 自己
-- 真正需要的模块，不产生新的依赖边。
-- 也不在 constants.ensure_defaults() 里给它设默认值：一旦预置假值，
-- 调度器还没跑第一轮时 UI 会显示一个从未生效过的倒计时，比"未排期"更误导人。
-- 所以字段不存在时老老实实返回 nil，调用方（travel.lua）要自己处理这个「尚未排期」的分支。
function M.tech_loss_time_left()
    local at = storage.tech_loss_next_at
    if not at then return nil end
    return at - game.tick
end

-- 送玩家去某个公共世界的出生点。
function M.travel(player, planet_name)
    local surface = game.surfaces[planet_name]
    if not surface or not surface.valid then
        player.print({'pw.world-not-ready', util.surface_label(planet_name)})
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
