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
-- noise 是纯函数模块（不 require 任何东西、不碰 storage/game），只用它的 hash01
-- 从种子确定性地派生本轮气候偏置。不成环。
local noise = require('scripts.noise')
-- events 是纯总线（只 require 引擎自带的东西），谁都可以依赖它，不成环。
local events = require('scripts.events')

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

-- 把矿脉调大。公共世界几小时清空一次，原版矿脉尺寸是按几十小时一局调的，
-- 照搬会让建设时间吃掉整轮的大半。
--
-- 【只放大已有的矿，绝不新增条目】：autoplace_controls 里出现某个矿名，含义是
-- "这颗星球生成这种矿"，不是"如果生成就用这个尺寸"。遍历全局矿种写进去的话，
-- Nauvis 会真的长出废料，SA「每颗星球有独特资源」的设计被整个抹平。
--
-- 仍按 category == 'resource' 过滤：这张表里还有地形/悬崖/敌人的控制项，
-- 把 size 塞给敌人控制项会真的改变虫子数量。
local function boost_resources(mgs)
    local boost = storage.world_resource_boost
    if type(boost) ~= 'table' then return end

    for name, c in pairs(mgs.autoplace_controls or {}) do
        local proto = prototypes.autoplace_control[name]
        if proto and proto.category == 'resource' then
            c.size = boost.size or c.size
            c.frequency = boost.frequency or c.frequency
            -- richness 不是每种矿都支持（proto.richness 说明它认不认这个字段）。
            -- 对不支持的矿硬塞 richness 是无意义的，跳过更干净。
            if proto.richness then c.richness = boost.richness or c.richness end
            mgs.autoplace_controls[name] = c
        end
    end
end

-- 先还原成原型自带的地图生成设置，洗掉脚本历史上写进去的东西。
-- 【map_gen_settings 是存进存档的】：光把 boost_resources 改对不能让废料从 Nauvis 消失，
-- 那个键已经躺在存档里，新循环遍历"已有的键"照样会看见它。
-- 幂等，宽高/种子/boost 都在本函数之后重新叠，还原不会丢掉需要的设置。
local function reset_to_prototype(surface)
    local planet = game.planets[surface.name]
    if not (planet and planet.valid) then return end
    -- 太空平台之类没有 planet 对象的 surface 走不到这里；真出意外也不该中断重置流程。
    local ok, err = pcall(function() planet.reset_map_gen_settings() end)
    if not ok then
        log('[pw] reset_map_gen_settings 失败（沿用现有设置）：' .. tostring(err))
    end
end

-- 每轮换一套气候，让「这轮草原、下轮沙漠」在【生成之前】就定下来，
-- 引擎连装饰物带悬崖一起自洽地算出来。想改地貌就改地图生成的输入，不要在输出上打补丁。
--
-- 只对 Nauvis 生效：aux/moisture 是 Nauvis 专有的气候控制
-- （base/prototypes/planet/planet-map-gen.lua:6-7）。其余四星走各自的地表表达式，
-- 仍然每轮换种子，只是没有"整体偏干/偏湿"这一维。
local function randomize_climate(mgs, planet_name, seed)
    if planet_name ~= 'nauvis' then return end

    mgs.property_expression_names = mgs.property_expression_names or {}

    -- 地貌块大小。引擎里 nauvis_segmentation_multiplier = 1.5 * control:water:frequency
    -- （core/prototypes/noise-programs.lua 第 361 行），调小 → 每片地貌铺得更大。
    -- 【副作用是引擎自带的、拆不开的】：这个变量同时是水的 frequency，调小意味着
    -- 湖泊更少更大。写下来是因为它看起来像"只调地貌大小"，实际不是。
    local scale = storage.world_terrain_scale
    if scale and scale > 0 then
        mgs.property_expression_names['control:water:frequency'] = tostring(scale)
    end

    local swing = storage.world_climate_swing or 0.35
    if swing <= 0 then return end
    -- moisture = clamp(0.5 + control:moisture:bias + 噪声, 0, 1)
    -- aux      = clamp(0.5 + control:aux:bias      + 噪声, 0, 1)
    -- （core/prototypes/noise-programs.lua 第 67 / 115 行）
    -- 偏置平移的是整颗星球的干湿倾向和红土/沙倾向，噪声本身不动 ——
    -- 所以地貌纹理还是原版那套，只是这一轮整体偏到了光谱的某一端。
    --
    -- 值写成字符串：property_expression_names 的值是【表达式名或字面量】，两者都用字符串
    -- 表达（本项目 constants.ring_map_gen 里的 elevation = '50' 是同一种用法的实证）。
    -- hash01 从种子确定性派生，同一轮永远得到同一套气候，多人和回滚重放都不会分叉。
    local function bias(salt)
        return tostring((noise.hash01(seed * salt) * 2 - 1) * swing)
    end
    mgs.property_expression_names['control:moisture:bias'] = bias(1.7)
    mgs.property_expression_names['control:aux:bias'] = bias(3.1)
end

function M.apply_bounds(surface, seed)
    local size = storage.public_size or 2048
    reset_to_prototype(surface)
    local mgs = surface.map_gen_settings
    mgs.width = size
    mgs.height = size
    if seed then mgs.seed = seed end
    boost_resources(mgs)

    -- 气候覆写单独试一次，失败了退回到"只有边界和矿脉"的设置重新写。
    -- property_expression_names 的键是引擎内部表达式名，写错一个字符整条赋值就抛错，
    -- 而这条赋值是重置流程的必经之路。边界和矿脉是刚需，气候只是好看。
    local plain = surface.map_gen_settings
    plain.width, plain.height = size, size
    if seed then plain.seed = seed end
    boost_resources(plain)

    randomize_climate(mgs, surface.name, seed or mgs.seed or 0)
    local ok, err = pcall(function() surface.map_gen_settings = mgs end)
    if not ok then
        log('[pw] 气候覆写失败，本轮沿用原生气候：' .. tostring(err))
        surface.map_gen_settings = plain
    end
end

-- 由星球名和轮次确定性地派生种子。用确定性而不是 math.random：回滚重放得到同样的地图，
-- 多人下也不依赖随机数状态。
-- bit32.bxor 而不是 5.3+ 的 `~`：场景脚本跑在 Lua 5.2，那个运算符会直接语法错误。
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
-- 永不撞车是纯算术保证的，不需要运行时冲突检测：五个周期都是 60 分钟的整数倍，
-- 所以每个星球【每一次】重置时刻 mod 60 恒等于它的首次偏移 mod 60，
-- 而五个偏移（0/10/20/30/40）两两不同。
-- 【改周期必须仍是 60 的整数倍】，否则这个保证立刻失效。
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

-- 星球传送窗口：Nauvis 是母星，永远开放；其余星球只在本轮前半段允许直传。
-- 这里故意绑定到重置排期：重置后一段时间是采集窗口，临近清空的一半时间不再让玩家直接进场。
function M.is_travel_open(planet_name)
    if planet_name == 'nauvis' then return true end
    storage.world_reset_at = storage.world_reset_at or {}
    local at = storage.world_reset_at[planet_name]
    if not at then return true end
    return (at - game.tick) > M.period_of(planet_name) / 2
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

-- 把这颗星球的产量/击杀/建造曲线归零。
--
-- 【surface.clear() 不清统计】：它只删实体和区块，产量曲线原样留着。不清的话，
-- 一颗星球的生产图是十几轮世界首尾相接 —— 每轮重置那一刻断崖式归零再重新爬起来，
-- 既看不出本轮到底产了多少，也看不出跟上一轮比是好是坏。
--
-- 【2.0 的统计是按 force × surface × 类别拆开的】，没有一键清空：
-- 1.1 的 LuaForce.clear_statistics() 已经不存在，现在要 4 类各取一个
-- LuaFlowStatistics 再调它的 clear()。这个拆分对本场景反而是好事 ——
-- 清 Nauvis 的统计【碰不到任何人戴森环里的曲线】。玩家在环里的生产是长期资产，
-- 星球是两小时一轮的消耗品，这两条线本来就不该混在一张图里。
--
-- 【必须等 clear 真正做完，所以挂在 on_surface_cleared 上而不是紧跟 clear() 之后】：
-- surface.clear(true) 是【异步】的，调用返回时区块还没清完。紧跟着清统计的话，
-- 清空过程中万一产生任何计数，都会写在我们清完之后 —— 顺序看着对，实际是反的。
-- 挂事件则没有这个疑问：引擎结算完才触发，那时统计里再没有本轮的东西会进来。
local STATISTIC_GETTERS = {
    'get_item_production_statistics',
    'get_fluid_production_statistics',
    'get_kill_count_statistics',
    'get_entity_build_count_statistics',
}
local function clear_statistics(surface)
    local force = game.forces.player
    if not (force and force.valid) then return end
    for _, getter in ipairs(STATISTIC_GETTERS) do
        -- pcall 包住：统计只是观感，取不到某一类不该让整个世界重置流程中断。
        local ok, err = pcall(function() force[getter](force, surface).clear() end)
        if not ok then
            log('[pw] 清统计失败 ' .. getter .. '：' .. tostring(err))
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

    -- Nauvis 是新人的起点，也是节奏最快的那颗星球（两小时一轮）。每轮把地图的
    -- 游玩时长归零，让存档看起来永远是"刚开的服"，而不是一个越滚越旧的数字。
    --
    -- 【只对 Nauvis 做】：五颗星球都做的话它每小时要被重置好几次，那个计数就彻底没有意义了。
    --
    -- 【本场景不读 game.ticks_played，所以这不影响任何机制】—— 全部时长判定
    -- （戴森环公共化/回收阈值、老玩家界面）走的是 util.played_hours，
    -- 那是一份【只增不减】的快照，正是为了挡住这一行可能的副作用而存在的：
    -- 引擎文档只说 reset_time_played "重置这张地图的游玩时长"，没说清 per-player 的
    -- online_time 算不算在内。快照让答案是什么都无所谓。详见 util.played_hours 的注释。
    if planet_name == 'nauvis' then
        local ok, err = pcall(function() game.reset_time_played() end)
        if not ok then
            log('[pw] reset_time_played 失败（不影响重置本身）：' .. tostring(err))
        end
    end

    storage.world_reset_at = storage.world_reset_at or {}
    storage.world_reset_at[planet_name] = game.tick + M.period_of(planet_name)
    -- 预警记录跟着新一轮清空，否则这颗星球从此再也不会预警第二次。
    storage.world_warned = storage.world_warned or {}
    storage.world_warned[planet_name] = nil

    -- 播报里不带轮次号。storage.world_run 仍然要维护（它是派生新种子和新地块分布的
    -- 依据，见 derive_seed / world_terrain），但那是内部计数，对玩家没有任何可操作性：
    -- 知道这是第 37 轮既不改变他现在该干什么，数字还会一直变大，读起来像是在计时罚站。
    game.print({'pw.world-reset', util.surface_label(planet_name)})
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

-- 用 physical_surface 而不是 surface：后者含遥控视角，那些人的身体在自己环里，
-- 星球清空一根毛都掉不了。预警要发给会挨打的人，不是围观的人。
local function players_physically_on(surface)
    local out = {}
    for _, player in pairs(game.connected_players) do
        if player.physical_surface == surface then
            out[#out + 1] = player
        end
    end
    return out
end

-- 提前多久预警（分钟）。默认 {5, 1}。
local function warn_minutes()
    local t = storage.world_warn_minutes
    if type(t) ~= 'table' then return {5, 1} end
    return t
end

local function notify(player, key, planet_name, minutes)
    player.print({key, util.surface_label(planet_name), minutes})
    -- 光有文字不够：玩家正在铺传送带、眼睛盯着鼠标，聊天框那一行很容易整条错过。
    -- pcall 包住是因为音效路径是字符串，写错了会抛错 —— 而"提醒"绝不该反过来打断游戏。
    pcall(function() player.play_sound{path = 'utility/new_objective'} end)
end

-- 周期任务：到点给还站在星球上的人发预警。由 tick.lua 每分钟调用。
--
-- 【每档只发一次】，记在 storage.world_warned[星球名][分钟数] 里，reset_world 时清空。
-- 不记的话每分钟都会重发一遍 —— 5 分钟档会连着刷 5 条。
--
-- 【判据是 left <= 阈值 而不是 left == 阈值】：本函数每分钟才跑一次，
-- 而 world_reset_at 不保证正好落在分钟边界上，用等号会整档漏掉。
-- 代价是文案上的分钟数最多比实际早说 60 秒，比"该提醒的时候没提醒"划算得多。
function M.tick_warn()
    storage.world_reset_at = storage.world_reset_at or {}
    storage.world_warned = storage.world_warned or {}

    for _, name in ipairs(constants.PUBLIC_PLANETS) do
        local at = storage.world_reset_at[name]
        local surface = game.surfaces[name]
        if at and surface and surface.valid then
            local left = at - game.tick
            local fired = storage.world_warned[name] or {}
            for _, minutes in ipairs(warn_minutes()) do
                if left <= minutes * constants.min_to_tick and not fired[minutes] then
                    fired[minutes] = true
                    for _, player in ipairs(players_physically_on(surface)) do
                        notify(player, 'pw.world-reset-warning', name, minutes)
                    end
                end
            end
            storage.world_warned[name] = fired
        end
    end
end

-- 刚落到某颗星球上的人，如果这颗星球已经进了预警窗口，单独告诉他还剩多久。
--
-- 【这一条不能靠上面那个周期任务覆盖】：预警是"到点广播一次"，发完就结束了。
-- 一个在第 4 分钟才降落的人永远收不到那条 5 分钟预警，而他恰恰是最需要知道的人 ——
-- 他刚开始建，最容易一头扎进去，然后眼睁睁看着一切在几分钟后消失。
--
-- 分钟数【向上取整现算】，不是复用预警档位：这里回答的是"我还有多久"，
-- 要的是真实剩余量，说"还有 5 分钟"而实际只剩 40 秒会把人坑得更惨。
local function on_player_changed_surface(event)
    local player = game.players[event.player_index]
    if not (player and player.valid and player.connected) then return end
    -- 认 physical_surface 而不是事件里的 surface_index：进遥控视角也会触发这个事件，
    -- 而那时人还在自己环里，什么都不会失去，不该收到这条。
    local surface = player.physical_surface
    if not (surface and surface.valid) then return end

    local at = (storage.world_reset_at or {})[surface.name]
    if not at then return end          -- 不是公共星球，或者还没排期

    local left = at - game.tick
    if left <= 0 then return end

    -- 窗口取配置里最大的那一档：管理员把预警改成 {10,5,1} 之后，
    -- 落地提示的窗口跟着变成 10 分钟，不需要另外再配一个数。
    local widest = 0
    for _, minutes in ipairs(warn_minutes()) do
        if minutes > widest then widest = minutes end
    end
    if left > widest * constants.min_to_tick then return end

    notify(player, 'pw.world-reset-arrival', surface.name,
        math.max(1, math.ceil(left / constants.min_to_tick)))
end
events.on(defines.events.on_player_changed_surface,
    events.safe('worlds_arrival_warn', on_player_changed_surface))

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
-- 挂到星球重置的话，科技丢失的节奏会被五个星球的周期（2/3/4/5/7 小时）绑架，
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

-- 这一轮漏水的【强度系数】x：每次判定开一次骰子，整张科技表共用这一个值。
--
-- 为什么是「每轮一个 x」而不是「每个科技各掷各的」：
-- 后者是几百次独立同分布的判定，大数定律会把随机性抹得干干净净 ——
-- 每轮丢的数量几乎恒定，玩家感觉不到骰子存在，只感觉到一条匀速下滑的线。
-- 每轮共用一个 x，整表就同起同落：x 接近 0 的那轮几乎什么都不丢，
-- x 接近上限的那轮成片地掉。总量的期望没变（E[x] = 上限 / 2 = 1，
-- 正好是旧版那个固定系数），变的只是节奏 —— 从持续渗水变成偶尔一场暴雨。
--
-- 上限写成 storage.tech_loss_k_max 而不是字面量 2：这个数字是漏水速度的总闸门，
-- 调它等于同时调期望值和波动幅度，是最可能需要现场热改的参数。
function M.roll_coefficient()
    return math.random() * (storage.tech_loss_k_max or 2)
end

-- 当前正在研究的科技，其【直接前置】在本轮科技漏水中免疫。
-- 只看 direct prerequisites，不递归向上追祖先科技：玩家正在补的那条链路不能被脚本从脚下抽走，
-- 但更早的地基仍然参与漏水，免得一项高阶研究把半棵科技树都罩住。
local function current_research_prerequisites()
    local current = game.forces.player.current_research
    if not (current and current.valid) then return nil end

    local out = {}
    for _, prereq in pairs(current.prerequisites or {}) do
        if prereq and prereq.valid then
            out[prereq.name] = true
        end
    end
    return out
end

-- 某科技在系数为 k 的这一轮里被侵蚀的概率。没有东西可丢的一律返回 0。
-- k 省略时取分布的期望值（上限的一半）——「没给系数」的唯一合理解释是问平均情况，
-- expected_losses 就是这么用的。
function M.loss_chance(tech, k, protected)
    if protected and protected[tech.name] then return 0 end

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

    k = k or (storage.tech_loss_k_max or 2) / 2
    return k * M.pack_count(tech) / 100
end

-- 全表期望丢失数。纯读取、无副作用 —— GUI 会频繁调它做重置预告，
-- 报一个「预计丢失约 X 项」比报百分比直观得多。
-- 不传 k，拿的是长期平均值；单看某一轮的实际丢失数会围着它上下摆很大。
function M.expected_losses()
    local sum = 0
    local protected = current_research_prerequisites()
    for _, tech in pairs(game.forces.player.technologies) do
        sum = sum + M.loss_chance(tech, nil, protected)
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
    -- 【一轮一个系数】：在循环外面掷，循环里所有科技共用。挪进循环就等于
    -- 每个科技各掷各的，随机性会被大数定律抹平，见 M.roll_coefficient 的说明。
    local k = M.roll_coefficient()
    local protected = current_research_prerequisites()
    for name, tech in pairs(game.forces.player.technologies) do
        local chance = M.loss_chance(tech, k, protected)
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

-- 清空结算完毕 → 把这颗星球的统计归零。
--
-- 只认公共星球：事件对任何被 clear 的 surface 都触发，绝不能顺带抹掉某个人环里的曲线。
local function on_surface_cleared(event)
    local surface = game.surfaces[event.surface_index]
    if not (surface and surface.valid) then return end
    for _, name in ipairs(constants.PUBLIC_PLANETS) do
        if surface.name == name then
            clear_statistics(surface)
            return
        end
    end
end
events.on(defines.events.on_surface_cleared, events.safe('worlds_stats', on_surface_cleared))

-- 送玩家去某个公共世界的出生点。
function M.travel(player, planet_name)
    local surface = game.surfaces[planet_name]
    if not surface or not surface.valid then
        player.print({'pw.world-not-ready', util.surface_label(planet_name)})
        return false
    end
    if not M.is_travel_open(planet_name) then
        player.print({'pw.world-closed', util.surface_label(planet_name)})
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
