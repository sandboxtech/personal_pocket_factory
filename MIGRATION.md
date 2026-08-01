# 迁移指南：8-01 上午版 → 当前版

适用于运行着 `62acc60`（8-01 11:42，加 QQ 群那版）的服务器。

**结论先说**：`.lua` 和 `locale/` 全量替换即可，存档不用重开、玩家经验和体力一点不动。
但**必须跑一次 `/pw-repair`**，而且有 **6 个旧配置值不会被自动更新**，要手工改。

---

## 为什么不能只替换文件就完事

热替换脚本靠的是 `game.reload_script()`，而它**既不触发 `on_init` 也不触发 `on_configuration_changed`**。
新版本新增的 storage 字段、新建的权限组、新的世界初始化步骤，全都挂在那两个事件上，
不跑就等于没有。`/pw-repair` 就是把那一整套幂等步骤单独拎出来手动执行。

更麻烦的是另一半：`ensure_defaults` 判空用的是 `== nil`。
**它只补"缺失的键"，绝不动"已经有值的键"** —— 这是故意的，否则管理员的任何自定义都会在每次重载时被冲掉。
代价就是：凡是**默认值变了但键早就存在**的配置项，旧值会一直留着，`/pw-repair` 永远救不了它们。

---

## 升级步骤

### 1. 替换文件

```
control.lua
scripts/          ← 整个目录覆盖
locale/           ← 整个目录覆盖
info.json
```

**删掉这两个文件**（新版本已经没有它们，留着不会报错但会误导后来的人）：

```
scripts/palette.lua
tests/test_palette.lua
```

### 2. 重载并修复

```
/c game.reload_script()
/pw-repair
```

`/pw-repair` 幂等，随时可以重复执行。它会：补齐缺失的配置字段、重建权限组、
补建五个星球的 surface、解锁星图、按新几何校准所有戴森环、
并对五颗星球跑一次 `apply_bounds`（顺带洗掉旧版写进存档的地图生成污染，见下面「废料」那条）。

### 3. 手工改掉 6 个旧值

这些键在旧存档里**已经有值**，`ensure_defaults` 不会碰它们。逐条粘进控制台：

```
/sc storage.ring_min_hours = 3
/sc storage.ring_height = 64
/sc storage.ring_concrete_height = 32
/sc storage.ring_pond_half = 2
/sc storage.world_reset_minutes = {nauvis=120, vulcanus=180, fulgora=240, gleba=300, aquilo=360}
/sc storage.tech_loss_k_max = 2
```

顺手清掉两个改了名的死键（不清也不会出错，只是 `/pw-config` 里看不到、又一直占着存档）：

```
/sc storage.tech_loss_k = nil; storage.ring_delete_hours = nil
/sc storage.world_patch_tiles = nil
```

> **偷懒选项**：`/pw-reset-config confirm` 一次把所有参数推回默认值，玩家进度不受影响。
> 但它是**全量**的 —— 你之前对任何参数做过的自定义会一起没。
> 不加 `confirm` 只看预览，会告诉你有几项和默认值不同。

### 4.（可选，但建议）重置全服戴森环

```
/ring-delete-all confirm
```

**经验和体力完全不受影响**，玩家点一下回环按钮，环就按经验重新长回来。

为什么建议：环的几何这一版**改了三次**，而旧环是照旧尺寸生成的：

| | 旧版 | 新版 |
| --- | --- | --- |
| 环高 | 128（中间 64 可建） | 64（中间 32 可建） |
| 收货箱 | 竖排两列，x = ±3 | 横排两行，y = -5 / 4 |
| 水池 | 6×6 | 4×4 |

`ring_height` 是**建面时**写进 map_gen 的引擎级硬边界，改配置管不了已经存在的 surface。
收货箱的 `ensure_array` 是"这个位置没有就建"，**不会拆掉旧位置上的箱子** ——
于是旧环会同时存在旧的 12 个和新的 12 个。不重置的话这些都得手工收拾。

不想动玩家的环也行，代价就是老环维持旧形状、多一组孤儿箱子。**新玩家的环一律是新形状。**

---

## 这一版改了什么

### 玩家能直接看到的

| 改动 | 说明 |
| --- | --- |
| **戴森环按玩家名显示** | 遥控视角左侧不再是 `ring_5`，而是玩家名字（`surface.localised_name`，不动 `surface.name`） |
| **环变小了** | 高 64（中间 32 可建 + 上下各 16 临空）。宽度公式没变 |
| **收货箱横排** | 上下两行各 6 个，夹着水池，机械臂从箱阵外侧取货。竖直方向是稀缺资源，转 90 度省出上下各 12 格建设带 |
| **水池 4×4** | 和箱行之间各留 2 格岸，取水面从左右两侧变成**四面都能架海洋泵** |
| **投递口 12 个** | 从 1 个改成 12 个，全宇宙合计。放第 13 个时**最早那个**自动退回背包 |
| **起始装备** | 没有环的玩家进服直接补发；复活时按 3 小时冷却补发。内容：模块装甲 + 个人机器人指令模块 + 6 太阳能板 **+ 10 建造机器人** |
| **科技漏水改了公式** | 每轮先掷一个 0~2 的系数，该轮所有科技共用。有的轮次风平浪静，有的成片地掉 |
| **星球周期各 +1 小时** | 120 / 180 / 240 / 300 / 360 分钟 |
| **生命周期阈值** | 最短 3 小时、最长 30 小时；回收阈值改成公共化阈值的 **3 倍**（9~90 小时） |
| **地貌改用引擎原生生成** | 见下面「地貌」 |
| **Nauvis 每轮重置归零地图游玩时长** | `game.reset_time_played()`。不影响任何机制 |
| **戴森环永昼** | 太阳能 24 小时满出力。老环靠周期任务自动补上，不用重建 |
| **星球重置时清自己的统计** | 产量/击杀/建造曲线归零，戴森环的曲线不受影响 |
| **重置前 5 分钟 / 1 分钟预警** | 只发给【身体真的在那颗星球上】的人；半路降落的单独收到实际剩余时间 |

### 新指令

| 指令 | 作用 |
| --- | --- |
| `/pw-repair` | 上面第 2 步那一套。幂等 |
| `/pw-reset-config [confirm]` | 所有参数推回默认值，玩家进度不动 |
| `/pw-export` | 导出所有人的经验 + 体力到 `script-output` |
| `/pw-import [confirm]` | 从 `exp_import.lua` 恢复 |

导入要走 `require`，因为**引擎没有运行时读文件的 API**，详细步骤见 README。

### 修掉的 bug

**所有星球都长废料。** 旧版 `boost_resources` 把**全部**矿种写进了**每颗**星球的 `autoplace_controls`，
于是 Nauvis 上有废料、有钨、有方解石。

光把那个循环改对**并不能修好已有存档** —— `map_gen_settings` 是存进存档的，
那些被写进去的键已经躺在里面了，新循环遍历"已有的键"时照样会看见、照样调大。
所以真正的修复是在每次重置前先调 `planet.reset_map_gen_settings()` 回到原型状态，再叠加边界和矿脉。

**这一条要等各星球下一轮重置才生效**，或者跑 `/pw-repair`（它会对五颗星球都跑一遍 `apply_bounds`）。

### 地貌：删掉了整整一层

旧版在引擎原生生成完之后，挂 `on_chunk_generated` 用自己的噪声场把地块名**整片重涂一遍**。
这一层已经**整个删除**，公共世界现在是纯粹的引擎原生生成。

删它的三个理由：

1. 量化是阶跃函数，两种砖的分界恰好落在噪声等值线上 —— 整颗星球看起来像一张**等高线图**；
2. 重涂只换砖名，引擎在生成阶段算好的**装饰物、悬崖、树种分布**仍然对应原来的地块，于是草地上长着沙漠的装饰物；
3. 砖名单同时充当"哪些格子有资格被换"的筛选集，想减少色带就必然缩小筛选集，于是大半张地图根本不会被碰。

它原本想达成的目的（每轮地貌观感不同）改用**引擎自己的气候旋钮**实现 ——
在生成**之前**平移 `moisture` / `aux` 偏置，引擎连装饰物带悬崖一起自洽地算出来：

```
/sc storage.world_climate_swing = 0.35   -- 每轮气候摆幅，0 = 每轮一样
/sc storage.world_terrain_scale = 0.5    -- 地貌块大小，越小块越大
```

两个都只对 Nauvis 有效（`aux`/`moisture` 是 Nauvis 专有的气候控制），
其余四星仍然每轮换种子，地图照样全新，只是没有"整体偏干/偏湿"这一维。

`world_terrain_scale` 有个**引擎自带、拆不开的副作用**：它同时是水的 frequency，
调小意味着湖泊更少更大。

### 配置项的增删改

| 键 | 变化 |
| --- | --- |
| `tech_loss_k` | **改名** → `tech_loss_k_max`，默认 1 → 2 |
| `ring_delete_hours` | **改名** → `ring_delete_multiple`，含义从"小时数"变成"公共化阈值的倍数"，默认 50 → 3 |
| `ring_min_hours` | 1 → **3** |
| `ring_height` / `ring_concrete_height` | 128 / 64 → **64 / 32** |
| `ring_pond_half` | 3 → **2** |
| `world_reset_minutes` | 各 **+60 分钟** |
| `world_patch_tiles` | **删除** |
| `dropoff_limit` | **新增**，12 |
| `ring_hide_private` | **新增**，true |
| `starter_items` / `starter_equipment` / `starter_equipment_hours` | **新增**，可热改，`/pw-config` 里直接显示当前发的是什么 |
| `world_climate_swing` / `world_terrain_scale` | **新增**，0.35 / 0.5 |
| `ring_always_day` | **新增**，true |
| `world_warn_minutes` | **新增**，{5, 1} |

内部 storage 键 `player_chests` 改成了 `dropoffs`（结构从单条记录变成先进先出的列表）。
旧键不会自动清，想清就 `/sc storage.player_chests = nil`。

---

## 升级后自查

跑完上面四步，按顺序确认：

1. `/pw-config` 打得开，`world` 组里能看到 `world_climate_swing` 和 `world_terrain_scale`
2. `/pw-config` 里 `ring_min_hours` 显示 **3**、`ring_height` 显示 **64**
3. 进自己的环：水池 4×4，上下各一行 6 个箱子，中间隔着 2 格岸
4. 手搓一个木箱放到环外 —— 变成关联箱，塞东西进去能到环里的收货箱
5. 等 Nauvis 下一轮重置，上去看**有没有废料**（有就是第 2 步没跑成）

### 有一件事需要你在游戏里替我确认

`game.reset_time_played()` 的引擎文档只有一句 "Resets the amount of time played for this map"，
**没说清 per-player 的 `online_time` 算不算在 "this map" 里面**。我没法在游戏外验证。

万一它会一起清零，戴森环的公共化/回收阈值（按累计在线时长缩放）就会**每两小时全服集体退回新人档**。
所以我没有直接读 `online_time`，而是在 `util.played_hours` 里存了一份**只增不减的快照**取较大值 ——
无论引擎那边到底怎么算，缩放都不会倒退。

也就是说：**这件事已经不会造成故障了**，但如果你想知道答案，
在 Nauvis 重置前后各跑一次下面这行对比即可：

```
/c game.print(game.player.online_time .. " / " .. game.ticks_played)
```
