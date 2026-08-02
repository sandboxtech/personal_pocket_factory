# 戴森环计划 场景结构

异星工厂（Factorio 2.0 + Space Age）自定义多人场景。原名「口袋世界」，现改名「戴森环计划」
（英文场景目录名沿用旧名 personal_pocket_factory）。本文档面向开发者，记录当前架构和每条
设计决策背后的理由，不是玩家看的玩法说明（玩家文案在 `locale/` 和 `scripts/gui/help.lua` 里）。

## 核心玩法

每个玩家有一条专属的戴森环（独立 surface，高 64 tile、宽度随经验增长的环带），环里一颗矿
都没有。资源全在五个公共星球（Space Age 的五颗真星球）里，各自独立周期重置。玩家去公共星球
铺关联箱当投递口，货物自动流回戴森环正中央固定的收货箱阵。收货箱阵按 12 种科技瓶的种类分别
计入经验，经验决定环能长多宽，是全场景唯一跨重置保留的进度。公共星球重置时还会随机撤销全服
已研究的科技，科技树越深撤得越快，逼着玩家不断出门维持产能。

## 设计约束及其理由

### 一、所有玩家单 force

不创建任何额外 force，所有人都在 `game.forces.player`（`scripts/players.lua`）。

理由是存档体积：chart（地图勘探数据）是 per force per surface per chunk 存的，引擎按
RGB565 每像素 2 字节存原始像素（`LuaForce::get_chunk_chart` 的文档描述）。每多一个 force，
引擎就多存一整份地图，人数一多光 chart 就能把存档撑到几十 MB。产权隔离靠「每人一个独立
surface」实现，不需要用 force 来隔。

### 二、戴森环没有资源

这是整个玩法的支点，不是难度设置。没有这条约束，私人世界会自给自足，玩家没有出门的理由，
公开服会退化成「同服单人」。

实现上用 `autoplace_settings` 的 `treat_missing_as_default = false`（`constants.ring_map_gen`），
让所有未显式列出的 entity/tile/decorative 都不生成，比逐项把 autoplace_controls 归零更彻底，
也不会漏掉 mod 新增的资源。

### 三、环形状：纵向硬边界 + 横向手工涂砖的混合方案

v1 的口袋世界宽高都用 `MapGenSettings.width/height` 这种引擎级硬边界：零成本，但只能是
矩形，而且在已存在的 surface 上能不能改大从未验证过。戴森环要「中间实心、上下临空、两侧
随经验增长」的形状，硬边界做不出来。

现在的方案（`scripts/ring.lua` + `scripts/geometry.lua`）：

- **纵向**仍用硬边界：`map_gen_settings.height = 64`，`|y| >= 32` 的区块引擎根本不生成，
  零成本零代码，白拿一份高度上限。
- **横向**改成无限（`width = 0`），交给 `on_chunk_generated` 手工涂 `out-of-map` 的墙。
  涂出来的墙玩家走不过去，带不动引擎往外生成，唯一代价是玩家站在边缘时引擎会顺手预生成
  两三个溢出区块，量级是每人几个，可接受。

`geometry.lua` 是不碰任何 Factorio 全局的纯函数模块，环的宽度、等级、每格该铺哪种语义砖
全在这里算，可以用 `lua5.4 tests/test_geometry.lua` 脱离游戏跑单测。`ring.lua` 只负责把
这里算出的语义值查表（`storage.ring_tiles`）换成真实砖名再 `set_tiles`，且逐区块涂（不是
一次涂整条 64 高的带），避免往还未生成的兄弟区块里写 tile。

### 四、12 种经验分开记账

12 种科技瓶（`geometry.SCIENCE_PACKS`）各自独立记一份经验，戴森环等级
`L = Σᵢ 位数(expᵢ)`，位数即 `floor(log10(x)) + 1`（1~9 算 1 位），i 遍历 12 项；
半宽 `= max(32, 16 × (L − 10))`，即宽度 `= 32 × (L − 10)`，下限 64。

用位数而不是纯 `floor(log10)`，是为了让【攒到第 1 点就有第 1 级】：纯对数下
1~9 点一律贡献 0，玩家攒完第一瓶经验界面纹丝不动，看起来像没生效。
起征点 10 是配套算出来的 —— 集齐 12 种（各至少 1 点）恰好 12 级，
此时半宽正好落在下限 32 上，实际环宽和改公式之前逐点相同
（`tests/test_geometry.lua` 里有 L = 0..72 的全覆盖对照）。

为什么每项各自 floor 再相加，而不是先加起来最后 floor 一次：两者结果真的不同，两种瓶子
各攒到 99 点时，旧式 `floor(log10(99) × 2) = 3`，新式 `1 + 1 = 2`。差别在于旧式允许多个
类别的零头攒起来凑出一级，新式每项各算各的、零头一律丢弃，而且新式和 UI 上「1234 / 10000」
那种线性进度条天生一对：每项贡献就是自己的位数，进度条百分比和等级之间有直接因果关系。

为什么按种类分开而不是揉成一个总数：`log10(1) = 0`，任何一种瓶子没攒过，那一项就是 0。
这逼着玩家集齐 12 种、跑遍五个星球，而不是把某一种猛刷到天上。

### 五、科技丢失概率挂瓶子种数

每一轮漏水（`worlds.tick_tech_loss`，独立周期任务，不挂在星球重置上）先掷一个系数
`x ~ U(0, storage.tech_loss_k_max)`（默认上限 2），然后每个已研究科技以 `P = x × n / 100`
的概率被撤销，`n` 是该科技配方里不重复的科技瓶种数。

**`x` 一轮只掷一次，整张科技表共用**。挪进循环里逐科技各掷各的，等于几百次独立同分布判定，
大数定律会把随机性抹平，每轮丢失数几乎恒定 —— 玩家感觉不到骰子，只感觉到一条匀速下滑的线。
共用一个 `x` 则整表同起同落：`x` 趋近 0 的那轮几乎什么都不丢，趋近上限的那轮成片地掉。
期望没变（`E[x] = 上限/2 = 1`，正好是旧版那个固定系数），变的是节奏。

固定概率有个隐患：`automation` 和终局科技一样容易丢，玩家可能上线就发现造不出传送带。
挂到瓶子种数上之后，科技树越深越容易漏水，地基反而最稳固。更重要的是它形成了一个不需要
任何人为封顶的自然高度上限：科技树越往上，侵蚀速率越高，全服最终会停在「集体产能刚好能
补上漏水速度」的那个高度，水位由玩家的产能决定，不是由某个写死的数字决定。

Trigger 科技（`prototype.research_trigger ~= nil`）和无限科技（`level < max_level`）显式
豁免：前者不是研究出来的，撤销后没有合法途径拿回；后者用 level 计数，`researched` 恒为
false，参与判定会让规则难以解释。

### 六、关联箱的三道锁

关联箱的风险不是有人「猜中」别人的 `link_id`（`player.index` 是从 1 开始的小整数，穷举
成本近乎为零），而是任何人一旦能改自己箱子的 `link_id`，就有了一扇通向受害者全部库存的
窗口。三道锁各管一段，缺一不可（`scripts/chests.lua`）：

- `gui_mode = "admins"`：原版 `linked-chest` 原型自带（本机 `data/base/prototypes/entity/entities.lua`），
  普通玩家根本打不开这个界面，与本场景的权限组配置无关。
- `operable = false`：挡住**管理员**。原型的 `gui_mode` 只挡普通玩家，管理员（含单人游戏
  主机、小型服务器上常见的多个管理员）仍能打开界面改 `link_id`。代价是箱主自己也打不开
  收货箱，取货必须靠机械臂（不受 `operable` 影响，它只管玩家 GUI）。这条锁经过一次反复：
  早期版本收货箱 `operable = true`，实测确认「能打开界面的人就能编辑 link_id，而那包括
  所有管理员」，才改成 `false`。
- `force = 'neutral'`：挡住「凭空造一个能用该 link_id 的箱子」。玩家（含机器人代建）造出
  的东西恒属 `player` force，只有脚本能创建 `neutral` 实体，攻击者拿到别人的 `link_id`
  也造不出能挂上这个 id 的箱子来接货。这道锁替换了最初「逐个订阅复制/粘贴事件、事后纠正
  link_id」的方案：枚举事件的路子被打脸两次、还有几条悬而未决，根本问题是永远不知道
  漏了哪条；`neutral force` 不枚举，从根上让「凭空造箱子」这件事不成立。

这三道锁背后有一条尚未在游戏里验证过的前提，见文末〈待验证清单〉的 A 项：关联箱共享的
库存如果不是按 force 分命名空间存的，`neutral force` 这道锁就完全不设防。

### 七、公共星球不放任何物资箱

`scripts/world_terrain.lua` 只碰地块斑块和树木疏密，绝不放箱子、物资箱或敌方据点。

理由：玩家用关联箱一趟就能把公共星球里任何白给的物资运回戴森环，而戴森环不重置。放在
公共星球的任何物资，最终都会变成永久收益，这和「星球会重置、环才是长期平台」的核心节奏
直接冲突。（据点同理不放：公共星球的定位是有时限的资源场，不是战斗关卡。）

### 八、相位调度器取代互质质数

v1 用几个刻意互质的取模基数（3607 / 3613 / 613）错开几个周期任务，缺点是「周期多长」和
「错开多少」焊死在同一个数字里：想调周期，几件任务的错开关系就跟着全变了，代码里也读不出
「科技丢失和戴森环生命周期到底差几分钟触发」，得心算取模基数才知道，而且取模答不出「还要
多久触发」这种 UI 倒计时需要的信息。

现在（`scripts/tick.lua`）每类任务在 `storage.cycle_next_at` 里各自记一个「下次触发的
tick」，周期（`storage.cycle_minutes`，默认 60 分钟）和相位间隔（`storage.cycle_phase_minutes`，
默认 5 分钟）是两个独立配置项，改一个不影响另一个。五个星球各自的重置周期（2/3/4/5/7 小时）
单独走一套按名字索引的 per-planet 排期，不并入这套相位表，两套周期用固定的分钟偏移互相
错开（见 `constants.cycle_base_offset_minutes` 旁的注释）。

## 文件结构

| 文件 | 职责 |
| --- | --- |
| `control.lua` | 入口。按依赖顺序加载各模块；`on_init` 建五星球 surface、套边界、首次错峰排期、解锁星图；`on_configuration_changed` 补齐新增默认字段。 |
| `scripts/constants.lua` | storage 默认值的唯一出生地（`ensure_defaults`）+ 全局常量（星球列表、戴森环 map_gen、旧存档迁移）。 |
| `scripts/events.lua` | 事件总线：同一事件多处 `events.on()` 订阅、内部只 `script.on_event` 一次再分发；`events.safe()` 把 handler 包成出错只播报不崩服。 |
| `scripts/geometry.lua` | 纯函数模块：环等级、半宽、tile 语义计算，戴森环形状的唯一真相源，可脱离游戏跑单测。 |
| `scripts/ring.lua` | 戴森环涂砖与扩容：把 geometry 算出的语义值查表换成真实砖名，`on_chunk_generated` 的订阅入口，升级时逐区块行重涂新增竖带。 |
| `scripts/bootstrap.lua` | 初始化/修复的那一套幂等步骤，`on_init`、`on_configuration_changed`、`/pw-repair` 三个调用方共用。 |
| `scripts/expio.lua` | 玩家进度（经验 + 体力）的导出与导入。导出走 `helpers.write_file`，导入只能靠加载阶段 `pcall(require, 'exp_import')`——引擎没有运行时读文件的 API。 |
| `scripts/chests.lua` | 关联箱：木箱↔关联箱转化、三道防偷锁、12 箱阵创建与 link_id 切换、投递口名额（先进先出）。 |
| `scripts/exp.lua` | 12 种经验记账 + 兑换：背包手动兑换与收货箱周期自动兑换共用同一套预览/结算逻辑。 |
| `scripts/stamina.lua` | 体力双池：可领取池按 tick 存、体力池按点存，读时惰性结算，离线玩家零开销、无取整漂移。 |
| `scripts/players.lua` | 玩家生命周期（创建/加入/重生）+ 权限组（默认不禁用任何权限，含蓝图库）。 |
| `scripts/pockets.lua` | 戴森环 surface 管理：惰性创建、进入、离线生命周期状态机（30h 变公共 / 50h 删除）、管理员删除。 |
| `scripts/worlds.lua` | 公共星球（五星球）：确保 surface 存在、套边界、按各自周期错峰排期、重置、科技丢失判定。 |
| `scripts/world_terrain.lua` | 公共星球地貌斑块：每轮重置换一套噪声参数，重新分布原生地块 + 调整树木疏密，绝不放箱子/敌人。 |
| `scripts/noise.lua` | 2D simplex 噪声 + 分形多倍频，供 `world_terrain.lua` 用。 |
| `scripts/tick.lua` | 相位调度器（取代互质取模）+ GUI 点击总路由，`script.on_nth_tick(3600)` 每约 1 分钟跑一次。 |
| `scripts/commands.lua` | 管理员指令：`/ring-delete <玩家名>`、`/ring-delete-all [confirm]`、`/pw-config`。 |
| `scripts/ships.lua` | 飞船（太空平台）：登记表按平台 index 主键、每人一艘、寿命到期销毁、禁用原生建船按钮。 |
| `scripts/gui/overview.lua` | 全服总览：一人一行的紧凑表格，所有戴森环 + 各人名下的飞船，兼造船入口。 |
| `scripts/gui/config.lua` | 管理员参数窗口：字段名 / 当前值 / 生效范围 / 说明，数据源是 `constants.TUNABLES`。 |
| `scripts/util.lua` | 无状态工具：数字可读化、进度条文本、取玩家本体角色、`is_veteran` 分级披露判定、星球图标标签。 |
| `scripts/gui/init.lua` | GUI 路由入口：HUD 刷新转发 + 点击事件分发到各窗口模块。 |
| `scripts/gui/popup.lua` | 弹窗骨架叶子模块（`HUD_NAME`/`POPUP_NAME`/`open_popup`/`close_popup`），专为打破循环依赖抽出。 |
| `scripts/gui/hud.lua` | 左上角常驻 HUD：传送图标行（戴森环 + 五星球）+ 等级/体力/按钮行。 |
| `scripts/gui/status.lua` | 合并的「状态」弹窗，依次拼装 claim/convert/exp 三段内容，统一开一个窗口。 |
| `scripts/gui/claim.lua` | 内容片段：体力池详情 + 可领取进度条 + 领取按钮。 |
| `scripts/gui/convert.lua` | 内容片段：背包科技瓶兑换预览 + 立即兑换按钮。 |
| `scripts/gui/exp.lua` | 内容片段：12 项经验的图标/进度条/数值表格。 |
| `scripts/gui/travel.lua` | 传送弹窗：回自己的环、五星球（带重置倒计时）、其他玩家的公共环列表。 |
| `scripts/gui/help.lua` | 玩法说明弹窗，老玩家额外看到具体数值。 |

## 关键 storage 字段

### 配置项（`constants.ensure_defaults()` 设置，可 `/c storage.x = y` 热改）

| 字段 | 含义 | 默认 |
| --- | --- | --- |
| `stamina_ticks_per_point` / `stamina_pending_cap` / `stamina_balance_cap` / `stamina_initial_multiple` | 体力：每点对应多少 tick / 可领取池点数上限 / 体力池点数上限 / 新玩家初始体力池 = pending_cap × 这个倍数 | 60 / 100000 / 10000000 / 10 |
| `quality_exp` | 品质 → 经验系数 | normal=1, uncommon=3, rare=5, epic=7, legendary=9 |
| `ring_height` / `ring_concrete_height` / `ring_base_half_width` / `ring_per_level` | 环带总高 / 中间可建带高度 / 起步半宽 / 每级两侧各外推多少 tile | 64 / 32 / 32 / 16 |
| `ring_tiles` | 语义砖名（start/grown/space/void）→ 真实砖原型名 | 见 `constants.lua` |
| `ring_public_hours` / `ring_delete_multiple` / `ring_min_hours` | 离线多久变公共（老玩家上限）/ 删除阈值是它的几倍 / 缩放后的下限 | 30 / 3 / 3 |
| `ring_hide_private` | 私人环是否从遥控视角平面列表隐藏（公共环一律显示） | true |
| `ring_always_day` | 戴森环永昼（`surface.always_day`），太阳能 24 小时满出力 | true |
| `world_climate_swing` / `world_terrain_scale` | 每轮气候摆幅 / 地貌块大小，都写进引擎的 `property_expression_names`，仅 Nauvis 有效 | 0.35 / 0.5 |
| `public_size` / `dropoff_limit` | 公共星球边长（tile）/ 每人同时能放几个投递口（全宇宙合计） | 2048 / 12 |
| `world_warn_minutes` | 重置前多久提醒星球上的人（分钟数组）；半路降落的按实际剩余时间单独提示 | {5, 1} |
| `world_reset_minutes` | 各星球重置周期（table，按星球名索引；必须都是 60 的整数倍，错峰证明依赖这一点） | nauvis 120 / vulcanus 180 / fulgora 240 / gleba 300 / aquilo 420 |
| `world_reset_offset_minutes` | 相邻星球首次排期的错开分钟数 | 10 |
| `starter_items` | 新玩家起手物资，整张表替换；未知物品名跳过 | 铁板 500 / 铜板 200 / 石 100 / 木 100 |
| `starter_equipment` / `starter_equipment_hours` | 起始装备清单（带装备栏的装甲排在前面）/ 复活补发的冷却小时数 | 模块装甲 + 机器人指令模块 + 6 太阳能板 + 10 建造机器人 / 3 |
| `cycle_minutes` / `cycle_phase_minutes` / `cycle_base_offset_minutes` | 相位调度器：大类任务周期 / 相位间隔 / 与星球重置错开的基础偏移 | 60 / 5 / 2 |
| `tech_loss_k_max` | 漏水系数上限，每轮取 `x ~ U(0, 上限)`，`P = x × 瓶子种数 / 100` | 2 |
| `block_blueprint_library` | 权限组是否禁蓝图库 | false（默认不禁） |
| `detail_hours` | 分级披露门槛：累计在线满多少小时算「老玩家」 | 6 |
| `debug` | 管理员调试播报 | false |

### 非配置的运行时状态

| 字段 | 含义 |
| --- | --- |
| `stamina[玩家名]` | `{last, pending, balance}`，体力双池数据 |
| `exp[玩家名]` | 12 键 table，各科技瓶累计经验 |
| `exp_log[玩家名]` | 最近一次兑换明细 |
| `ring_state[玩家名]` | `'private'` / `'public'`，离线状态机的真相源 |
| `ring_applied_half[玩家名]` | 已经涂到的半宽，扩容时用来判断新增竖带的范围 |
| `world_reset_at[星球名]` / `world_run[星球名]` | 错峰排期真相源 / 已重置轮次 |
| `tech_loss_next_at` | 相位调度器写、`worlds.tech_loss_time_left()` 读，倒计时 UI 用 |
| `cycle_next_at[任务key]` | 相位调度器每类任务的下次触发 tick |
| `hud_next_refresh_at` | HUD 刷新调度 |
| `starter_equipment_at[玩家名]` | 上次领取起始装备的 tick，复活冷却判定用 |
| `dropoffs[player_index]` | `{surface, x, y}` 数组，按放置先后排列的投递口登记表；超过 `dropoff_limit` 时淘汰下标 1 |

## 数据流速览

```
on_init:
    ensure_defaults -> setup_perm_group（默认不禁任何权限）-> unlock_all_planets
    worlds.ensure_surfaces()   五星球 game.planets[x].create_surface()
    worlds.apply_bounds()      逐个套 width/height
    worlds.schedule_all(true)  首次错峰排期（各自周期 + i×10 分钟偏移）

on_player_created:
    钉死 force -> assign_group -> pockets.enter（pockets.ensure 惰性建 + 幂等自愈：
    create_surface(关污染) -> 涂初始区块 -> chests.ensure_array 建 12 箱阵
    -> ring_state/applied_half 记账 -> set_spawn_position -> 最后才 sync_label/sync_visibility）
    -> grant_starter -> stamina.add(初始体力，默认倍数 0 即不送)
    -> gui.refresh_hud（主动建 HUD，不等周期任务）

    【顺序不是随手排的】sync_visibility 必须在最后：它是纯观感功能，曾经排在建箱阵
    之前并因为参数写反抛错，把整条建环流程截断，表现为「地板在、箱子没了」。
    ensure 的这几步全部幂等，每次进环都重跑一遍，半成品环因此能自愈。

on_player_joined_game:
    assign_group -> 环不存在则 pockets.enter 重建，否则 pockets.ensure（自愈）
    + pockets.restore_on_join（公共期立刻收回：link_id 改回 player.index，
    访客被请出去）-> gui.refresh_hud

相位调度器（script.on_nth_tick(3600)，约 1 分钟一次）:
    phase 0  worlds.tick_tech_loss()      全科技表判定，按瓶子种数掷概率撤销
    phase 1  pockets.tick_lifecycle()     扫描离线玩家，private->public->删除两个跃迁
    phase 2  exp.tick_auto_convert()      吃每人戴森环收货箱共享库存，转经验、重算环宽
    （不进相位表）worlds.next_reset_at() 到期就重置一个星球；到点刷新在线玩家 HUD

兑换（玩家点「状态」窗口的兑换按钮，`exp.convert`）:
    exp.preview 用体力池点数模拟一遍（quota = balance）
    -> 实际执行：先 stamina.spend 扣体力，扣不掉就整个中止
    -> 再移除背包物品 -> exp.add 记经验 -> ring.apply_growth 重算宽度并涂新增竖带

重置（worlds.tick_check 每次只处理一个到期的星球）:
    evacuate 撤人 -> derive_seed 按下一轮次号派生新种子
    -> apply_bounds(surface, seed) 套边界并换种子 -> surface.clear(true) 异步重新生成
    -> world_reset_at / world_run 更新 -> 全服广播
```

## 开发约定

- **Factorio 跑 Lua 5.2，本机 luac / lua5.4 是 5.4。** `~` `&` `|` `<<` `>>` `//` 这些运算符，
  以及 `math.type` / `table.move` / `string.pack` 这些库函数都是 Lua 5.3+ 才有的，本机
  `luac -p` 语法检查**不会报错**，但进游戏会直接语法错误、整个场景加载失败。位运算一律用
  `bit32` 库（`scripts/worlds.lua` 的 `derive_seed`、`scripts/noise.lua` 的 `bit32.band` 都
  是这么写的）。

- **`require` 只能在模块顶层调用**，函数体内 `require` 会报错，堵死了「延迟 require 绕开
  循环依赖」这条常见退路。正确做法是**抽出叶子模块**：`scripts/gui/popup.lua` 就是从
  `gui/init.lua` 里抽出来的，因为 `claim`/`convert`/`exp`/`travel`/`help`/`status` 几个
  窗口模块都要用它，若留在 `init.lua` 里就得反过来 require `init`，形成环。同理
  `tech_loss_next_at` 由 `tick.lua`（调度器）写、`worlds.lua` 只读，而不是反过来，因为
  `tick.lua` 已在顶层 require 了 `worlds`。遇到循环依赖先想「哪个函数能抽成叶子模块」，
  不是「把 require 挪到用到它的地方」。

- **常驻 UI 必须在玩家进场时主动创建**，不能只靠周期任务顺手建出来。HUD 曾经的唯一调用点
  是周期刷新任务，刷新间隔是 10 秒时进场十秒内看起来正常，后来相位调度器改成 60 秒一次
  （`on_nth_tick(3600)`），新玩家要等一分钟才第一次看到 UI，表现成「界面消失了」。真正的
  问题不是频率，是没人负责在进场那一刻创建。现在 `on_player_created` /
  `on_player_joined_game` 都会主动调一次 `gui.refresh_hud(player)`。

- **`ensure_defaults()` 的幂等性意味着老存档看不到新默认值**：`storage.x = storage.x or
  默认值` 这种写法，一旦某个字段在某个存档里已经有值，新默认值永远覆盖不了它。测试新配置
  项要么 `/c storage.x = nil` 之后重载，要么直接开一个新档。

- **查引擎 API 一律按【类】列全量，不要按猜的关键词 grep。** 本机有一份权威的
  `runtime-api.json`（`Steam/steamapps/common/Factorio/doc-html/`），把某个类的
  `methods` / `attributes` 整个打印出来只要几秒。曾经为了「怎么把玩家送上飞船」，
  用 `driver` / `vehicle` / `teleport` 当关键词搜，一无所获，于是从「太空平台中枢原型
  没有载具字段」推出「进不去」，自己实现了一套「在中枢旁找空格子再 teleport」——
  而引擎其实有现成的 `LuaPlayer.enter_space_platform(platform)`（配套还有
  `leave_space_platform`）。**关键词搜索只能证明"我搜的这个词没命中"，永远证明不了
  "这个能力不存在"**，而后者才是当时真正要回答的问题。
  另外 `tests/check_api_args.py` 会拿 `runtime-api.json` 核对所有引擎调用的位置参数，
  专抓「布尔字面量落在非布尔参数位」这类写反（`set_surface_hidden(true, surface)`
  就是这么被发现的）。注意 `takes_table` 在 runtime-api v6 里位于 `method.format` 下，
  不是顶层字段。

- 改完 `.lua` 跑一次语法检查：`luac -p control.lua scripts/*.lua scripts/gui/*.lua`。
  改了 `geometry.lua` 或任何几何/等级数学，跑 `lua5.4 tests/test_geometry.lua`（当前 123/123）。

- **改完任何 `.lua` 或 locale，跑 `bash tests/run_all.sh`。** 五道检查各自堵的是别的
  检查看不见的一类问题，缺一不可：

  | 检查 | 堵住的问题 | 为什么别的检查抓不到 |
  |---|---|---|
  | `luac -p` | 语法错 | — |
  | Lua 5.2 兼容 | `~` `//` `<<` `table.move` 等 5.3+ 写法 | 本机 luac 是 5.4，这些能过编译，进游戏才加载失败 |
  | `check_globals.sh` | 读写未定义的全局 | 读不存在的全局在 Lua 里合法（值 nil），要跑到那一行才炸 |
  | `check_api_args.py` | 引擎调用位置参数写反 | 语法完全合法；`set_surface_hidden(true, surface)` 就是这么漏掉的 |
  | `check_locale.py` | 缺键/死键/占位符实参个数对不上 | 少传一个参数不报错，只在界面上显示成没替换的 `__3__` |

- **新增可热改的配置项，只改 `constants.TUNABLES` 一处**，再补两条
  `pw.cfg-<字段名，下划线换短横>` 的 locale 说明。`ensure_defaults` 和 `/pw-config`
  读的是同一张表，不存在「改了默认值忘了改文档」这种事。

## 待验证清单

以下几项从设计初期就标注「上线前必须实测」，目前仍未在真实游戏里跑过，风险各不相同。

**A~E 关系到关联箱三道锁能不能真的挡住偷窃，是当前实现选择「不实测直接换方案」赌下来的
前提**，任何一条不成立都可能让防偷设计整体失效：

- **A. 关联箱共享库存是否按 force 分命名空间。** 官方文档对 `link_id` 只写了一句「The
  link ID this linked container is using」，未提 force；这是三道锁里 `neutral force`
  那道锁成立的前提，如果不成立，`neutral force` 完全不设防。测法：分别建一个 `player`
  force 和一个 `neutral` force 的 `linked-chest`，设成同一个 `link_id`，塞东西进
  `player` 箱，看 `neutral` 箱能不能读到。
- **B. 机械臂能否存取 `operable = false` 的 `neutral` force 箱子。** 这些箱子是取货的
  唯一出口，不行的话整条取货流程断掉。
- **C. 玩家能否挖走 `neutral` force 的投递口**（`destructible = true`，需求要求可摧毁）。
- **D. 虫子是否会攻击 `neutral` 箱**（若会，Nauvis/Gleba 的投递口要考虑额外防护）。
- **E. `find_entities_filtered{name=...}` 不传 force 参数时是否跨 force 搜索**（影响
  `chests.set_array_link` 和 `exp.tick_auto_convert` 能不能在混合 force 的 surface 上
  找全所有关联箱；目前戴森环里所有关联箱都会被 `on_built` 强制转成 `neutral`，风险已
  收窄，但没有回归验证过）。

首次实机验收（当初计划让 Task 3-8 各自进游戏验证，因场景当时加载不了而推迟，之后一直
没有集中补跑，仍然只有 `luac -p` + 代码审查这一层保障）：

- 环形状：原点混凝土带、上下 `empty-space`、左右 `out-of-map` 墙、`|y| >= 64` 的区块
  确实不生成。
- 12 箱阵：数量、`link_id`、不可摧毁不可挖、机械臂可正常存取；木箱三态转换（戴森环内
  不变、公共星球变关联箱、手搓直接产出关联箱物品）。
- 兑换：攒够对应数量的科技瓶后等级和半宽按公式变化，扩容后新增的竖带砖块正确。
- 离线生命周期：公共期 `link_id` 变成 `0`，主人回归后恢复成 `player.index`。
- 科技丢失：`automation`（n=1，应为 1%）、`logistic`（n=2，应为 2%）等具体科技的概率
  与瓶子种数对应；`k` 调到很大时是否真的必丢。
- `/ring-delete` 的三种拒绝路径（非管理员调用、玩家名不存在、目标在线）。

另有一项遗留：`worlds.reset_world` 换种子后调用 `surface.clear(true)`，是否真的按
新种子重新生成地图（而不是沿用旧地图缓存），还没有实机确认过。
