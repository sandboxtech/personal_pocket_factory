# pocket_worlds 场景结构

异星工厂 (Factorio 2.0 + Space Age) 自定义场景，多人公开服向。

## 核心玩法

每个玩家有一个专属的**口袋世界**（独立 surface），只有他能进，没人能拆他的东西，但**一颗矿都没有**。
资源全在五个**公共世界**（SA 的真星球）里，有边界、会定期重置、五个**错峰**重置。
玩家去公共世界采集，背回口袋世界加工，再花**体力**把物资兑换成**经验**。
经验是唯一跨重置保留的东西。

一句话概括三层约束的关系：

> 口袋世界给你**产权**，公共世界给你**资源**，体力给你**节奏**。

## 四条设计约束及其理由

### 一、所有玩家单 force

本场景不创建任何额外 force，所有人都在 `game.forces.player`。

理由是存档体积。chart（地图勘探数据）是 **per force per surface per chunk** 存的，引擎按 RGB565 每像素 2 字节存原始像素数据（见 `LuaForce::get_chunk_chart` 的文档描述）。每多一个 force，引擎就多存一整份地图。人数一多，光 chart 就能把存档撑到几十 MB。

产权隔离本场景靠"每人一个独立 surface"实现，不需要用 force 来隔。这是 force 和 surface 两种隔离手段的取舍：force 隔离便宜但只能防拆，surface 隔离贵一点但给了独立空间和独立地图生成。

### 二、口袋世界没有资源

这是整个玩法的支点，不是难度设置。

没有这条约束，私人世界会自给自足，玩家就没有出门的理由，公开服会退化成"同服单人"，社交价值归零。有了这条约束，每个人都必须定期出门，公共世界才会有人。

实现上不是把 `autoplace_controls` 逐个调成 0，而是用 `autoplace_settings` 的 `treat_missing_as_default = false`，让所有未显式列出的 entity/tile/decorative 都不生成。这比逐项归零更彻底，也不会漏掉 mod 新增的资源。

### 三、地图有限大小

用 `MapGenSettings.width` / `height`（单位 tile，0 表示无限），这是**引擎级硬边界**。边界外是 out-of-map，引擎根本不生成区块，存档体积从根上受控，不需要自己铺虚空、也不需要事后 `delete_chunk` 去追。

口袋世界默认 256 tile（8×8 区块），公共世界默认 2048 tile（64×64 区块）。

注意：改 `map_gen_settings` 只影响**之后生成**的区块，所以必须在 `clear()` 之前设好。

### 四、错峰重置

五个公共世界各有独立的 `world_reset_at[星球名]`，首次排期时把它们均匀铺在一个周期里（第 i 个星球在 `period × i / N` 处），之后各自按周期滚动，永远保持错开。

五个同时重置的话，全服会在同一刻集体失去一切，节奏是一根锯齿。错开之后，任何时刻都有"刚重置的新鲜世界"和"快到期的成熟世界"，玩家永远有地方去，也永远有理由赶在某个世界到期前把东西搬走。

## 文件结构

| 文件 | 职责 |
| --- | --- |
| `control.lua` | 入口。`on_init` 建五个星球 surface、套边界、首次错峰排期、建物品价值表；`on_configuration_changed` 补齐新增默认字段。 |
| `info.json` / `description.json` | 场景元数据。依赖 base / space-age / quality / elevated-rails。 |
| `locale/` | 本地化。目前 zh-CN 和 en 两种，`pw.*` 键由代码引用，31 个 key 两边全覆盖。 |
| `scripts/constants.lua` | 全局常量 + `ensure_defaults()`：storage 默认值的**唯一出生地**。各模块使用点只留 nil 兜底。口袋世界的 map gen 配方也在这。 |
| `scripts/events.lua` | 事件总线。同一事件多处 `events.on()` 订阅、内部只 `script.on_event` 注册一次再分发，避免互相覆盖。`events.safe()` 把 handler 包成出错只播报不崩服。 |
| `scripts/util.lua` | 无状态工具：`readable` 大数字、`level_of` 经验转等级、`progress_bar` 文本进度条、`body_character` 取本体角色（兼容地图/遥控视角）。 |
| `scripts/values.lua` | **物品价值表**：递归展开配方求原矿当量，可挖原矿 = 1。首次使用时算一次并缓存进 `storage.item_value`。跳过 `recycling` 类配方，否则回收机会把成品算成废料价。 |
| `scripts/stamina.lua` | **体力**（沿用 endfield 的星星机制）：随时间恢复、离线也攒、到上限停。惰性补算（存 `last` tick + 读时结算）而不是每 tick 给全员加，离线玩家零开销。整数运算并保留余数，无浮点漂移。支持 `transfer` 转赠。 |
| `scripts/exp.lua` | **经验 + 兑换**。`appraise` 扫背包折算价值（不改动状态，预览和实际兑换共用同一个函数）；`formula` 是兑换公式，**目前是占位实现，见下方待办**；`convert` 先扣体力再移除物品，不会出现"物品没了但没给经验"。 |
| `scripts/pockets.lua` | **口袋世界**：惰性创建（surface 名用 `player.index` 避免玩家名里的非法字符）、`enter` 传送、`reclaim` 回收、`reclaim_offline` 周期回收离线超时玩家的世界。这是存档体积的主要闸门。 |
| `scripts/worlds.lua` | **公共世界**：`ensure_surfaces` 用 `game.planets[x].create_surface()` 显式建出五个星球；`apply_bounds` 套硬边界；`schedule_all` 错峰排期；`reset_world` 撤人→套边界→清空→排下一轮；`tick_check` 一次只重置一个，避免一 tick 清多个 surface 卡顿。 |
| `scripts/players.lua` | 玩家生命周期 + 权限组。新玩家钉死单 force、进权限组、进口袋世界、发起手物资；重生一律回口袋；离线期间口袋被回收过的话，上线时重建。**禁蓝图库**的动作列表在这。 |
| `scripts/gui.lua` | 左上角 HUD（等级/经验/体力 + 四个按钮）和三个弹窗（兑换、公共世界列表、玩法说明）。全用引擎自带 style，不引入任何图片资源。 |
| `scripts/tick.lua` | 周期任务调度 + GUI 点击路由。用 `on_tick` 取模门控而不是 `on_nth_tick`，且各任务的模数刻意取互质的数（3607 / 3613 / 613），让它们几乎不会撞在同一 tick 上。 |

## 关键 storage 字段

| 字段 | 含义 |
| --- | --- |
| `storage.stamina[玩家名]` | `{amount = 当前点数, last = 上次结算 tick}` |
| `storage.stamina_per_hour` / `stamina_cap` | 每小时恢复点数（默认 60，即 1 分钟 1 点）/ 上限（默认 1440，攒满 24 小时） |
| `storage.exp[玩家名]` | 累计经验（整数）。等级 = `floor(sqrt(exp))`，无上限 |
| `storage.exp_log[玩家名]` | 最近一次兑换的明细，供 GUI 回显 |
| `storage.convert_cost` / `convert_batch` | 每次兑换消耗的体力 / 单次最多处理多少种物品（防卡顿） |
| `storage.item_value` | 物品价值表缓存。`/c storage.item_value = nil` 可触发重建（游戏升级后用） |
| `storage.pocket_size` | 口袋世界边长（tile，默认 256） |
| `storage.pocket_keep_offline_minutes` | 离线多久后回收口袋世界（默认 30 分钟） |
| `storage.public_size` | 公共世界边长（tile，默认 2048） |
| `storage.world_reset_minutes` | 每个公共世界的重置周期（默认 120 分钟） |
| `storage.world_reset_at[星球名]` | 下次重置的 tick。**错峰的真相源** |
| `storage.world_run[星球名]` | 该星球已重置过几轮 |
| `storage.block_blueprint_library` | 默认 true。禁蓝图库，重置才有意义 |

所有默认值统一由 `constants.ensure_defaults()` 设置，`on_init` / `on_configuration_changed` 都会调，幂等不覆盖已调过的值。

## 数据流速览

```
on_init:
    ensure_defaults -> setup_perm_group（禁蓝图库）
    worlds.ensure_surfaces()   五个星球 game.planets[x].create_surface()
    worlds.apply_bounds()      套 width/height 硬边界
    worlds.schedule_all(true)  错峰排期：period × i / N
    values.ensure()            递归建物品价值表，缓存进 storage

on_player_created:
    钉死 game.forces.player -> 进权限组 -> pockets.enter（惰性建口袋）-> 发起手物资

on_player_joined_game:
    进权限组 -> 口袋不存在则重建（离线期间被回收过）

on_player_respawned:
    一律回口袋世界

on_tick（经 events 总线 + 互质模数门控）:
    % 3607  worlds.tick_check()      有世界到期就重置一个（撤人→套边界→clear→排下一轮）
    % 3613  pockets.reclaim_offline() 回收离线超时玩家的口袋世界
    % 613   gui.refresh_hud()         刷新在线玩家 HUD

玩家点【兑换经验】:
    exp.appraise 扫背包 -> values.of 折算原矿当量 × 品质系数 -> exp.formula 决定给多少经验/扣多少体力
    -> stamina.spend 先扣体力 -> 移除物品 -> exp.add 加经验
```

## 待办

### 1. 兑换公式（`exp.lua` 的 `M.formula`，必须先定）

目前是占位实现（方向 A：固定扣 1 点体力，背包全兑）。文件里写了三个方向和各自的玩法后果：

- **A 体力当门票**：固定扣费、背包全兑。体力几乎不是瓶颈，产量才是。节奏慢而稳。
- **B 体力当配额**：每点体力兑换固定额度的价值。体力是硬上限，离线攒体力有直接价值，转赠系统会真正活起来。代价是高产玩家会被卡住。
- **C 体力当倍率**：玩家自己决定投入多少体力，经验按递增函数放大。策略性最强，但最难平衡。

推荐 B，因为它最能把"挂机玩家和勤快玩家各有位置"落到实处。

### 2. 经验的用途（当前最大的缺口）

经验现在只有一个数字和一个等级，**没有任何兑现**。玩家攒它没有理由。至少要选一条：

- 口袋世界随等级变大（最贴合本场景的主题，`storage.pocket_size` 已经是可调参数，改成按等级算即可）
- 起手物资随等级增加（endfield 的职业系统就是这个思路）
- 解锁公共世界（高等级才能去 Aquilo 之类）
- 挂到 Factorio 原生的无限产能科技上（xx 项目里 `set_tech_level` 的做法，零解释成本）

### 3. 玩家之间的交互（当前完全没有）

单 force，但每个人在自己的 surface 上，实际上互不相干。可选的连接方式：

- 体力转赠（`stamina.transfer` 已实现，但还没接 GUI 和命令）
- 关联箱跨面物流（`linked-chest` + 脚本分配 `link_id`，`gui_mode = "admins"` 保证玩家改不了 ID 偷别人的箱子）
- 一个共享的交易枢纽 surface

### 4. 其余

- 公共世界重置前的分级预警（现在只有 GUI 倒计时，应该在 10 分钟 / 1 分钟时全服广播）
- 玩家在公共世界离线时的保护（现在重置会把他留在那里的东西一起清掉）
- 排行榜 / 荣誉榜
- 管理员工具（改参数、强制重置某世界、查生成摘要）
- 更多语言（目前只有 zh-CN 和 en）

## 开发约定

- storage 访问点一律保留 nil 兜底，老存档继承时字段可能还没补上，直接索引会崩
- 改完 `.lua` 跑 `luac -p` 体检
- 代码改动必须重载存档才生效，Factorio 多人服无法热重载场景代码（代码烤进存档）
- `storage` 数据可以 `/c storage.x = y` 不停服热改
