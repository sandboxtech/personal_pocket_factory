# 戴森环计划 v2 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把现有 `personal_pocket_factory` 场景改造成「戴森环计划」——个人世界变成宽度由 12 种科技瓶经验驱动的环带，关联箱做跨星球物流，公共世界重置时全服科技按 `k × 瓶子种数 %` 概率漏水。

**Architecture:** 三层。**纯函数层**（`geometry.lua`）只做数学，不碰任何 Factorio API，有真单元测试；**领域层**（`ring` / `chests` / `pockets` / `worlds` / `exp`）各管一件事，通过 `events` 总线解耦；**表现层**（`gui/`）拆成六个小文件。`storage` 是唯一状态源，默认值统一在 `constants.ensure_defaults()` 出生。

**Tech Stack:** Lua 5.4（Factorio 2.0 + Space Age 运行时）。语法体检用 `luac -p`。纯函数单测用 `lua5.4` 直接跑。其余用游戏内 `/c` 控制台脚本验证。

**Spec:** `docs/superpowers/specs/2026-07-31-dyson-ring-design.md`

---

## Global Constraints

以下约束对**每一个任务**都生效，不再逐任务重复：

- **单 force**：不创建任何额外 force，所有玩家留在 `game.forces.player`。理由是 chart 数据是 per force per surface per chunk 存的。
- **不禁用玩家任何权限**：`BLOCKED_ACTIONS` 为空，`storage.block_blueprint_library` 默认 `false`。
- **storage 访问点一律保留 nil 兜底**：老存档继承时字段可能还没补上，直接索引会崩。
- **默认值的唯一出生地是 `constants.ensure_defaults()`**：幂等、不覆盖已调过的值。使用点只留 nil 兜底，不在使用点写默认值。
- **可配置的数字一律进 `storage`**，绝不写死在代码里。判据：开服后有可能因为"手感不对"而想改的数字，就必须是配置项。
- **阈值每次现读，绝不缓存成"到期 tick"**（离线生命周期尤其）。存了到期 tick，改配置就只对新数据生效。
- **每个 `.lua` 改完必须跑 `luac -p`**，语法错会导致整个场景加载失败。
- **不使用 git**（本项目不是仓库）。任务之间无提交步骤。
- **多人同步安全**：只用 `math.random`（Factorio 已替换成确定性实现），不用 `os.time` / `os.clock`。事件订阅必须在模块 require 顶层完成。
- 环带几何常量（`ring_height=128`、`concrete_height=64`、`base_half_width=32`、`per_level=16`）全部走 `storage`，代码里不出现字面量。

---

## 前置：安装 lua5.4

Task 1 的单元测试需要 lua 解释器。若 `lua5.4 -v` 报 command not found，先执行：

```bash
sudo apt-get install -y lua5.4
```

装不上也能继续——`luac -p` 的语法体检和游戏内验证不受影响，只是 Task 1 的测试跑不了（那就必须在游戏里用 `/c` 逐条核对 Task 1 的测试用例表）。

---

## 文件结构

| 文件 | 职责 | 状态 |
| --- | --- | --- |
| `scripts/geometry.lua` | **纯函数**：等级、半宽、坐标→砖种。零 Factorio 依赖，唯一有真单测的模块 | 新增 |
| `scripts/constants.lua` | 12 瓶表、`ensure_defaults()`、`storage.exp` 迁移 | 大改 |
| `scripts/util.lua` | 无状态工具。删 `level_of`（sqrt 等级已废弃） | 小改 |
| `scripts/ring.lua` | 涂砖：`on_chunk_generated` + 升级扩容重涂。调 `geometry` 算，自己只管写 tile | 新增 |
| `scripts/chests.lua` | 12 箱阵创建、木箱↔关联箱转换、`link_id` 绑定与公共/个人切换 | 新增 |
| `scripts/pockets.lua` | 戴森环 surface 生命周期：创建、进入、30h/50h 状态机 | 大改 |
| `scripts/exp.lua` | 12 种经验记账、只吃科技瓶的兑换、升级触发扩容 | 大改 |
| `scripts/worlds.lua` | 公共世界重置 + 科技丢失 | 小改 |
| `scripts/players.lua` | 玩家生命周期。权限组放空 | 小改 |
| `scripts/commands.lua` | 管理员指令 `/ring-delete` | 新增 |
| `scripts/tick.lua` | 周期调度 + GUI 点击路由 | 小改 |
| `scripts/gui/init.lua` | 点击路由分发 | 新增 |
| `scripts/gui/hud.lua` | 左上角常驻条 | 新增 |
| `scripts/gui/convert.lua` | 兑换窗口 | 新增 |
| `scripts/gui/travel.lua` | 传送窗口（戴森环 + 五星球 + 公共环列表） | 新增 |
| `scripts/gui/exp.lua` | 12 种经验明细窗口 | 新增 |
| `scripts/gui/help.lua` | 玩法说明 | 新增 |
| `scripts/gui.lua` | 拆分后删除 | 删除 |
| `scripts/values.lua` | 物品价值表，失去用途 | 删除 |
| `scripts/events.lua` / `stamina.lua` | 不动 | 不变 |
| `tests/test_geometry.lua` | 纯函数单测 | 新增 |
| `locale/{zh-CN,en}/locale.cfg` | 全面改写 | 大改 |
| `control.lua` | 入口接线 | 改 |
| `PROJECT.md` | 更新架构文档 | 改 |

**命名注意**：几何模块叫 `scripts/geometry.lua`（纯数学），涂砖模块叫 `scripts/ring.lua`（碰 API），
经验明细窗口叫 `scripts/gui/exp.lua`。Spec 里写的 `gui/ring.lua` 改成 `gui/exp.lua`，
避免和 `scripts/ring.lua` 混淆——窗口内容本来就是 12 种经验。

---

## Task 1: 几何纯函数 + 单元测试

整个环带形状的唯一真相源。边界条件密集（`exp=0` 时 `log10` 是负无穷、`x` 恰好等于半宽算里还是算外、`y` 的三段分界），而且错了的表现是"世界形状不对"这种要开游戏才看得见的 bug。所以先在这里把数学锁死。

**Files:**
- Create: `scripts/geometry.lua`
- Test: `tests/test_geometry.lua`

**Interfaces:**
- Consumes: 无（这是最底层）
- Produces:
  - `geometry.SCIENCE_PACKS` → 12 个字符串的数组，元素是瓶子短名（`'automation'` …）
  - `geometry.pack_item_name(short)` → `string`，短名转物品原型名（`'automation'` → `'automation-science-pack'`）
  - `geometry.ring_level(exp_table)` → `integer`，`floor(Σ max(0, log10(expᵢ)))`
  - `geometry.half_width(level, base_half_width, per_level)` → `integer`
  - `geometry.tile_at(x, y, half_width, ring_height, concrete_height)` → `'concrete'` / `'empty-space'` / `'out-of-map'`

- [ ] **Step 1: 写失败的测试**

创建 `tests/test_geometry.lua`：

```lua
-- 纯函数单测。不加载任何 Factorio API。
-- 跑法：lua5.4 tests/test_geometry.lua （从场景根目录）
package.path = 'scripts/?.lua;' .. package.path
local geo = require('geometry')

local failures, total = 0, 0

local function check(label, actual, expected)
    total = total + 1
    if actual ~= expected then
        failures = failures + 1
        print(string.format('FAIL  %s\n      期望 %s，实得 %s',
            label, tostring(expected), tostring(actual)))
    end
end

-- ══ SCIENCE_PACKS ══
check('恰好 12 种瓶子', #geo.SCIENCE_PACKS, 12)
check('短名转物品名', geo.pack_item_name('automation'), 'automation-science-pack')
check('短名转物品名(终局)', geo.pack_item_name('promethium'), 'promethium-science-pack')

-- ══ ring_level ══
-- log10(0) 是负无穷、log10(1)=0，两个都必须夹到 0，否则等级会变成 -inf 或负数
check('空表',            geo.ring_level({}), 0)
check('经验为 0',        geo.ring_level({automation = 0}), 0)
check('经验为 1',        geo.ring_level({automation = 1}), 0)
check('经验小于 1',      geo.ring_level({automation = 0.5}), 0)
check('经验为负(脏数据)', geo.ring_level({automation = -100}), 0)
check('单种 10',         geo.ring_level({automation = 10}), 1)
check('单种 999',        geo.ring_level({automation = 999}), 2)
check('单种 1000',       geo.ring_level({automation = 1000}), 3)
check('未知键被忽略',    geo.ring_level({automation = 10, 不存在的瓶子 = 1e9}), 1)

local all_ten = {}
for _, k in ipairs(geo.SCIENCE_PACKS) do all_ten[k] = 10 end
check('12 种各 10 → 12', geo.ring_level(all_ten), 12)

local all_million = {}
for _, k in ipairs(geo.SCIENCE_PACKS) do all_million[k] = 1000000 end
check('12 种各 100 万 → 72', geo.ring_level(all_million), 72)

-- 缺一种就少一整段：这是 12 种分开记账的全部意义
local eleven = {}
for _, k in ipairs(geo.SCIENCE_PACKS) do eleven[k] = 10 end
eleven[geo.SCIENCE_PACKS[12]] = 0
check('缺 1 种 → 11', geo.ring_level(eleven), 11)

-- ══ half_width ══
check('L=0',  geo.half_width(0, 32, 16), 32)
check('L=1',  geo.half_width(1, 32, 16), 48)
check('L=12', geo.half_width(12, 32, 16), 224)
check('L=72', geo.half_width(72, 32, 16), 1184)

-- ══ tile_at ══
-- 约定：tile 坐标 x 占据 [x, x+1)，所以有效范围是 x ∈ [-half, half)
local HW, RH, CH = 32, 128, 64
local function t(x, y) return geo.tile_at(x, y, HW, RH, CH) end

check('原点是混凝土',        t(0, 0), 'concrete')
check('右边界内最后一格',    t(31, 0), 'concrete')
check('右边界外第一格',      t(32, 0), 'out-of-map')
check('左边界内第一格',      t(-32, 0), 'concrete')
check('左边界外第一格',      t(-33, 0), 'out-of-map')

check('混凝土带上沿(含)',    t(0, -32), 'concrete')
check('混凝土带上沿外',      t(0, -33), 'empty-space')
check('混凝土带下沿(不含)',  t(0, 32), 'empty-space')
check('混凝土带下沿内',      t(0, 31), 'concrete')

check('环上沿内',            t(0, -64), 'empty-space')
check('环上沿外',            t(0, -65), 'out-of-map')
check('环下沿内',            t(0, 63), 'empty-space')
check('环下沿外',            t(0, 64), 'out-of-map')

-- 横向墙优先于纵向分带：环外就是环外，不管 y 在哪一段
check('横向越界压过纵向分带', t(100, 0), 'out-of-map')
check('横向越界压过临空带',   t(100, 40), 'out-of-map')

-- ══ 汇总 ══
print(string.format('%d/%d 通过', total - failures, total))
os.exit(failures == 0 and 0 or 1)
```

- [ ] **Step 2: 跑测试确认失败**

```bash
cd /mnt/c/Users/syx/AppData/Roaming/Factorio/scenarios/personal_pocket_factory
lua5.4 tests/test_geometry.lua
```

预期：`module 'geometry' not found`（文件还没建）

- [ ] **Step 3: 写最小实现**

创建 `scripts/geometry.lua`：

```lua
-- 戴森环的几何与等级计算。【纯函数模块】
--
-- 本文件不 require 任何东西、不碰任何 Factorio 全局（game / storage / prototypes 一个都不用），
-- 所以能用普通 lua 解释器跑单元测试：lua5.4 tests/test_geometry.lua
--
-- 这是整个环带形状的唯一真相源。所有边界判断都只在这里做一次，
-- ring.lua 只负责把这里算出来的砖种写进 surface。
local M = {}

-- 12 种科技瓶的短名。顺序即 UI 里的展示顺序（按 Space Age 的解锁进度排）。
-- storage.exp[玩家名] 就用这些短名当键。
M.SCIENCE_PACKS = {
    'automation', 'logistic', 'military', 'chemical',
    'production', 'utility', 'space', 'metallurgic',
    'agricultural', 'electromagnetic', 'cryogenic', 'promethium',
}

-- 短名 → 物品原型名。12 种瓶子的原型名统一是 <短名>-science-pack。
function M.pack_item_name(short)
    return short .. '-science-pack'
end

-- 戴森环等级 = floor( Σ max(0, log10(expᵢ)) )
--
-- 为什么每种单独取 log10 再求和：Σ log10(expᵢ) = log10(∏ expᵢ)。
-- 因为 log10(1) = 0，任何一种瓶子没攒过，那一项就是 0 —— 这是 12 种分开记账的全部理由，
-- 它逼玩家集齐 12 种，而不是把红瓶刷到天上。
--
-- exp ≤ 1 的项直接跳过：log10(0) 是负无穷、log10(0.5) 是负数，
-- 不夹住的话整个等级会变成 -inf 或负数，环宽会算成负的。
function M.ring_level(exp_table)
    local sum = 0
    for _, key in ipairs(M.SCIENCE_PACKS) do
        local amount = exp_table[key] or 0
        if amount > 1 then
            sum = sum + math.log(amount, 10)
        end
    end
    return math.floor(sum)
end

-- 半宽（tile）。环以原点为中心向两侧对称生长，每升一级两侧各外推 per_level。
function M.half_width(level, base_half_width, per_level)
    return base_half_width + per_level * level
end

-- 给定 tile 坐标，返回该铺哪种砖。
--
-- 坐标约定：tile 坐标 x 占据 [x, x+1)，所以有效横向范围是 x ∈ [-half_width, half_width)，
-- 纵向同理。左闭右开，和 Factorio 的 tile 语义一致。
--
-- 判断顺序有意义：横向的墙优先于纵向的分带。环外就是环外，不管 y 落在哪一段。
function M.tile_at(x, y, half_width, ring_height, concrete_height)
    if x < -half_width or x >= half_width then
        return 'out-of-map'
    end

    local concrete_half = concrete_height / 2
    if y >= -concrete_half and y < concrete_half then
        return 'concrete'
    end

    local ring_half = ring_height / 2
    if y >= -ring_half and y < ring_half then
        return 'empty-space'
    end

    -- 引擎的 height 硬边界本来就不会生成这里，走到这一步说明配置不一致，兜底成墙。
    return 'out-of-map'
end

return M
```

- [ ] **Step 4: 跑测试确认通过**

```bash
lua5.4 tests/test_geometry.lua
```

预期：`34/34 通过`，退出码 0

- [ ] **Step 5: 语法体检**

```bash
luac -p scripts/geometry.lua && echo "语法 OK"
```

---

## Task 2: constants.lua 改造（配置 + 迁移）

所有默认值的唯一出生地。这一步做完，老存档能平滑升级到新的数据结构。

**Files:**
- Modify: `scripts/constants.lua`（整体重写 `ensure_defaults`，保留 `sec_to_tick` 等时间常量）
- Modify: `scripts/util.lua`（删 `level_of` / `exp_to_next`）

**Interfaces:**
- Consumes: `geometry.SCIENCE_PACKS`
- Produces:
  - `constants.PUBLIC_LINK_ID` = `0`
  - `constants.ring_map_gen(seed, ring_height)` → `MapGenSettings` table
  - `constants.ensure_defaults()` → 无返回，幂等
  - `storage.exp[玩家名]` 保证是 12 键 table

- [ ] **Step 1: 改 `scripts/constants.lua`**

保留文件顶部的 `M.sec_to_tick` / `min_to_tick` / `hour_to_tick` 和 `M.PUBLIC_PLANETS` 不动。
删除 `M.quality_exp`（挪进 storage）和 `M.pocket_map_gen`（换成 `ring_map_gen`）。
在文件顶部加 `local geometry = require('scripts.geometry')`。

新增：

```lua
-- 公共库存的 link_id。player.index 从 1 开始，所以 0 永不碰撞。
-- 全服只有一个公共库存：所有弃厂的产出汇进同一个池子。
M.PUBLIC_LINK_ID = 0

-- 戴森环的地图生成设置。
--
-- 关键点一：height 是【引擎级硬边界】，|y| >= height/2 的区块根本不生成，零成本零代码。
--   128 是精确的 4 个区块行（-64..-32 / -32..0 / 0..32 / 32..64），每行都被用满。
--   取 96 的话占用区块数一模一样，却有一半空间被 out-of-map 浪费掉。
-- 关键点二：width = 0 表示【无限】，横向边界交给 ring.lua 手工涂 out-of-map 的墙。
--   引擎硬边界只能是矩形、而且在已存在的 surface 上能不能改大是未验证的，
--   所以横向的可增长边界必须自己涂。
-- 关键点三：treat_missing_as_default = false 让所有未显式列出的 entity/tile/decorative
--   都不生成，比逐个把 autoplace_controls 调成 0 更彻底，也不会漏掉 mod 新增的资源。
function M.ring_map_gen(seed, ring_height)
    return {
        width = 0,
        height = ring_height,
        seed = seed,
        water = 0,
        starting_area = 1,
        peaceful_mode = true,
        no_enemies_mode = true,
        default_enable_all_autoplace_controls = false,
        cliff_settings = {cliff_elevation_interval = 0, cliff_elevation_0 = 0},
        autoplace_settings = {
            entity = {treat_missing_as_default = false, settings = {}},
            tile = {treat_missing_as_default = false, settings = {['concrete'] = {}}},
            decorative = {treat_missing_as_default = false, settings = {}},
        },
        property_expression_names = {
            elevation = '50',   -- 地形压平，环带不需要起伏
        },
    }
end

-- 把 v1 的 storage.exp[玩家名]（一个 number）迁移成 12 键 table。
-- 老经验整个折算进 automation 一项 —— 那时候经验不分种类，归给第一种最不容易引起争议。
-- 幂等：已经是 table 的不动。
local function migrate_exp()
    storage.exp = storage.exp or {}
    for name, value in pairs(storage.exp) do
        if type(value) == 'number' then
            local fresh = {}
            for _, key in ipairs(geometry.SCIENCE_PACKS) do fresh[key] = 0 end
            fresh.automation = value
            storage.exp[name] = fresh
        end
    end
end

-- 保证某玩家的经验表存在且 12 个键齐全。新增瓶种时也靠它补齐。
function M.ensure_exp_table(player_name)
    storage.exp = storage.exp or {}
    local tbl = storage.exp[player_name]
    if type(tbl) ~= 'table' then
        tbl = {}
        storage.exp[player_name] = tbl
    end
    for _, key in ipairs(geometry.SCIENCE_PACKS) do
        tbl[key] = tbl[key] or 0
    end
    return tbl
end
```

`ensure_defaults()` 整体替换成：

```lua
function M.ensure_defaults()
    -- ══ 体力（沿用 v1：随时间恢复、离线也攒、到上限停） ══
    storage.stamina = storage.stamina or {}
    storage.stamina_per_hour = storage.stamina_per_hour or 60
    storage.stamina_cap = storage.stamina_cap or 1440

    -- ══ 经验（12 种，按科技瓶短名分列） ══
    storage.exp = storage.exp or {}
    storage.exp_log = storage.exp_log or {}
    migrate_exp()                                                  -- v1 的 number 转 table

    -- ══ 兑换 ══
    storage.convert_cost = storage.convert_cost or 1               -- 门票制：固定扣这么多体力
    storage.quality_exp = storage.quality_exp or
        {normal = 1, uncommon = 3, rare = 5, epic = 7, legendary = 9}

    -- ══ 戴森环形状 ══
    storage.ring_height = storage.ring_height or 128               -- 环带总高，同时是 map_gen 的 height
    storage.ring_concrete_height = storage.ring_concrete_height or 64  -- 中间可建带，其余均分给上下的临空带
    storage.ring_base_half_width = storage.ring_base_half_width or 32  -- L=0 时的半宽
    storage.ring_per_level = storage.ring_per_level or 16          -- 每升一级两侧各外推多少 tile

    -- ══ 戴森环离线生命周期 ══
    -- 两个阈值都是【每次扫描现读】的，绝不缓存成到期 tick，这样改配置能立即对全体生效。
    storage.ring_state = storage.ring_state or {}                  -- [玩家名] = 'private' / 'public'
    storage.ring_public_hours = storage.ring_public_hours or 30    -- 离线多久后变公共
    storage.ring_delete_hours = storage.ring_delete_hours or 50    -- 离线多久后删表面

    -- ══ 公共世界 ══
    storage.public_size = storage.public_size or 2048
    storage.world_reset_minutes = storage.world_reset_minutes or 120
    storage.world_reset_at = storage.world_reset_at or {}
    storage.world_run = storage.world_run or {}

    -- ══ 科技丢失：P = k × 该科技的瓶子种数 / 100 ══
    storage.tech_loss_k = storage.tech_loss_k or 1

    -- ══ 权限：默认【不禁用任何东西】，包括蓝图库 ══
    -- v1 禁蓝图的理由（重置后 Ctrl+V 一秒恢复布局）在本版已不成立：
    -- 重置的是公共世界，而玩家的产线在戴森环里，本来就不会被重置。
    if storage.block_blueprint_library == nil then
        storage.block_blueprint_library = false
    end

    -- ══ 调试 ══
    storage.debug = storage.debug or false
end
```

**注意**：`block_blueprint_library` 必须用 `== nil` 判断，不能用 `or`——
`false or X` 会求值成 X，管理员设成 `false` 后每次调用都会被覆盖回去。

- [ ] **Step 2: 改 `scripts/util.lua`**

删掉 `M.level_of` 和 `M.exp_to_next` 两个函数（sqrt 等级制已被 `geometry.ring_level` 取代）。
`readable` / `progress_bar` / `body_character` / `main_inventory` 保留不动。

- [ ] **Step 3: 语法体检**

```bash
luac -p scripts/constants.lua scripts/util.lua && echo "语法 OK"
```

- [ ] **Step 4: 确认没有残留引用**

```bash
grep -rn "level_of\|exp_to_next\|quality_exp\|pocket_map_gen\|pocket_size\|convert_batch\|item_value\|pocket_keep_offline\|pocket_run" scripts/ control.lua
```

预期：只剩下**还没改到的文件**里的引用（`exp.lua` / `gui.lua` / `pockets.lua` / `values.lua`）。
这些会在后续任务里逐个清掉。把输出记下来当待办清单。

---

## Task 3: ring.lua 涂砖 + pockets 改造（能生成正确形状的环）

做完这一步，新玩家上线就能落进一条 64×128 的环带里。

**Files:**
- Create: `scripts/ring.lua`
- Modify: `scripts/pockets.lua`
- Modify: `control.lua`

**Interfaces:**
- Consumes: `geometry.*`、`constants.ensure_exp_table`
- Produces:
  - `ring.is_ring_surface(surface)` → `boolean`
  - `ring.owner_name_of(surface)` → `string?`（surface 名反查玩家名）
  - `ring.level_of(player_name)` → `integer`
  - `ring.half_width_of(player_name)` → `integer`
  - `ring.ensure_chunks(surface, x_from, x_to, y_from, y_to)` → 无返回，逐区块请求生成并同步落地
  - `ring.paint_area(surface, x_from, x_to, y_from, y_to, half_width)` → 无返回，涂 `[x_from,x_to) × [y_from,y_to)` 这个矩形
  - `ring.on_chunk_generated(event)` → 事件处理器
  - `ring.apply_growth(player)` → `boolean`（等级变了并重涂过返回 true）
  - `pockets.surface_name(player)` / `pockets.get(player)` / `pockets.ensure(player)` / `pockets.enter(player)`（签名不变，行为改）

- [ ] **Step 1: 创建 `scripts/ring.lua`**

```lua
-- 戴森环的涂砖与扩容。几何计算全部委托给 geometry.lua，本文件只负责把砖写进 surface。
--
-- 为什么是「无限地图 + 手工涂砖」而不是 v1 的「引擎硬边界」：
--   引擎硬边界（map_gen_settings.width/height）零成本，但只能是矩形，
--   而且在已存在的 surface 上能不能改大是未验证的。
--   戴森环要「中间实心、上下临空、两侧可增长」，硬边界做不出来。
--   于是纵向仍用硬边界（height=128，白拿），横向改成无限 + 自己涂 out-of-map 的墙。
--
-- 代价：存档体积不再由引擎兜底。但涂出来的墙是不可通行的，玩家走不过去，
-- 也就带不动引擎往外生成 —— 只有他站在边缘时引擎顺手预生成的两三个区块会溢出，涂掉留着即可。
local geometry = require('scripts.geometry')
local constants = require('scripts.constants')

local M = {}

local PREFIX = 'ring_'

function M.surface_name_for(player_index)
    return PREFIX .. tostring(player_index)
end

function M.is_ring_surface(surface)
    if not (surface and surface.valid) then return false end
    return string.sub(surface.name, 1, #PREFIX) == PREFIX
end

-- surface 名反查玩家名。surface 名里存的是 player.index（玩家名可能含非法字符），
-- 而 storage 一律按玩家名索引（改名后仍能继承），所以这里要转一道。
function M.owner_name_of(surface)
    if not M.is_ring_surface(surface) then return nil end
    local index = tonumber(string.sub(surface.name, #PREFIX + 1))
    if not index then return nil end
    local player = game.players[index]
    return player and player.name or nil
end

function M.level_of(player_name)
    local exp = constants.ensure_exp_table(player_name)
    return geometry.ring_level(exp)
end

function M.half_width_of(player_name)
    return geometry.half_width(
        M.level_of(player_name),
        storage.ring_base_half_width or 32,
        storage.ring_per_level or 16)
end

-- 保证 [x_from, x_to) × [y_from, y_to) 覆盖到的区块都已生成。
--
-- 逐区块请求而不是给一个大半径：request_to_generate_chunks 的 radius 是【正方形】的，
-- 纵向多请求无所谓（引擎的 height 硬边界会挡掉），横向却会真的生成出去 ——
-- 用「按环高算出来的半径」去请求，每个新玩家会白造上百个废区块。
-- 存档体积是本项目的头号约束，不能这么浪费。
function M.ensure_chunks(surface, x_from, x_to, y_from, y_to)
    local cx_from = math.floor(x_from / 32)
    local cx_to   = math.floor((x_to - 1) / 32)
    local cy_from = math.floor(y_from / 32)
    local cy_to   = math.floor((y_to - 1) / 32)
    for cx = cx_from, cx_to do
        for cy = cy_from, cy_to do
            surface.request_to_generate_chunks({cx * 32 + 16, cy * 32 + 16}, 0)
        end
    end
    surface.force_generate_chunk_requests()
end

-- 把 [x_from, x_to) × [y_from, y_to) 这个矩形按几何规则涂一遍。
-- 一次 set_tiles 批量提交，不要逐 tile 调（那样会触发一堆事件、慢得多）。
--
-- y 范围是参数而不是「总是整条环高」：调用方按【单个区块】的范围调用，
-- 这样绝不会往还没生成的兄弟区块里写 tile。
-- （写不进去的话是静默失败 —— 双层 pcall 加一小时去重播报会把它盖住，
--   表现是某些玩家某些行的砖是错的，几乎不可能被发现。）
function M.paint_area(surface, x_from, x_to, y_from, y_to, half_width)
    local ring_height = storage.ring_height or 128
    local concrete_height = storage.ring_concrete_height or 64

    local tiles = {}
    for x = x_from, x_to - 1 do
        for y = y_from, y_to - 1 do
            tiles[#tiles + 1] = {
                name = geometry.tile_at(x, y, half_width, ring_height, concrete_height),
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

-- 新区块生成时涂砖。只涂【本区块自己】那 32×32，不碰兄弟区块。
-- 引擎保证只有 |y| < ring_height/2 的区块会来，所以纵向不用额外夹紧。
function M.on_chunk_generated(event)
    local surface = event.surface
    if not M.is_ring_surface(surface) then return end
    local owner = M.owner_name_of(surface)
    if not owner then return end

    local area = event.area
    M.paint_area(surface,
        math.floor(area.left_top.x), math.floor(area.right_bottom.x),
        math.floor(area.left_top.y), math.floor(area.right_bottom.y),
        M.half_width_of(owner))
end

-- 等级变化后扩容。只涂【新增的那两条竖带】，不碰玩家已经建过东西的老地皮。
--
-- 【关键约束】本函数绝不能把玩家铺的太空平台基座刷回 empty-space。
-- 目前天然安全：新增竖带此前是 out-of-map，玩家不可能在上面铺过东西。
-- 将来若加「重新校准全环砖块」之类的功能，这是第一个会被踩坏的东西。
function M.apply_growth(player)
    if not (player and player.valid) then return false end
    local surface = game.surfaces[M.surface_name_for(player.index)]
    if not (surface and surface.valid) then return false end

    storage.ring_applied_half = storage.ring_applied_half or {}
    local old_half = storage.ring_applied_half[player.name] or 0
    local new_half = M.half_width_of(player.name)
    if new_half <= old_half then return false end

    local ring_height = storage.ring_height or 128
    local y_half = math.floor(ring_height / 2)

    -- 新增竖带要处理两种区块，缺一不可：
    --   · 这次才生成的 —— on_chunk_generated 会自动涂（那时 half_width_of 已读到新等级）
    --   · 本来就存在的 —— 之前作为环外溢出被生成、涂成 out-of-map，不会再触发事件，必须显式重涂
    -- 所以生成之后仍要显式涂一遍（幂等，两种情况都覆盖）。
    local function grow_strip(x_from, x_to)
        if x_from >= x_to then return end
        M.ensure_chunks(surface, x_from, x_to, -y_half, y_half)
        -- 逐区块行涂，避免一次跨多个区块行写入
        local cy_from = math.floor(-y_half / 32)
        local cy_to   = math.floor((y_half - 1) / 32)
        for cy = cy_from, cy_to do
            local y0 = math.max(-y_half, cy * 32)
            local y1 = math.min(y_half, (cy + 1) * 32)
            M.paint_area(surface, x_from, x_to, y0, y1, new_half)
        end
    end

    grow_strip(-new_half, -old_half)   -- 左侧新增带
    grow_strip(old_half, new_half)     -- 右侧新增带

    storage.ring_applied_half[player.name] = new_half
    return true
end

return M
```

- [ ] **Step 2: 改 `scripts/pockets.lua`**

整体重写（生命周期状态机留到 Task 6，这一步只做创建/进入）：

```lua
-- 戴森环：每个玩家一个专属 surface，一条高 128 的环带，没有任何资源。
--
-- 定位：戴森环是【加工厂】，公共世界是【矿场】。
-- 环里一颗矿都没有，所有原料必须从公共世界运回来（靠关联箱，见 chests.lua）。
-- 这条约束保证私人世界不会自给自足，玩家必须出门，公开服才不会退化成「同服单人」。
local constants = require('scripts.constants')
local ring = require('scripts.ring')

local M = {}

-- surface 名用 player.index 而不是 player.name：玩家名可能含空格或特殊字符，
-- 而 index 在存档内稳定且必定合法。storage 里仍然按玩家名索引，方便改名后继承。
function M.surface_name(player)
    return ring.surface_name_for(player.index)
end

function M.get(player)
    return game.surfaces[M.surface_name(player)]
end

-- 惰性创建。已存在直接返回，不重复建。
function M.ensure(player)
    local existing = M.get(player)
    if existing and existing.valid then return existing end

    -- 种子按玩家 index 派生，保证同一个人每次重开拿到的地形一致，换人则不同。
    local seed = (player.index * 7919 + 104729) % 2147483647
    local surface = game.create_surface(
        M.surface_name(player),
        constants.ring_map_gen(seed, storage.ring_height or 128))

    surface.always_day = true        -- 永昼：这里是工作间，不需要夜战和照明负担
    surface.freeze_daytime = true
    surface.show_clouds = false

    -- 关掉污染。注意是 {} 不是 nil ——
    -- Pollutant 概念是 { pollutant = LuaAirbornePollutantPrototype? }，文档写明 "If nil, pollution is disabled"，
    -- 而 override_pollution_type = nil 的含义是【不覆盖、跟随默认】，是个静默的 no-op。
    -- 因为 Lua 里 {pollutant = nil} 求值就是空表 {}，两种写法长得几乎一样、含义完全相反。
    -- 值得做的理由不只是清掉地图上的红云：污染扩散是 per-surface 每 tick 算的，
    -- 而戴森环是每个玩家一份 surface，人一多就是一堆永远不会有虫子来的污染云在白烧 UPS。
    surface.override_pollution_type = {}

    -- 同步生成出生区，玩家马上就要落地，异步排队会落进还没生成的区块。
    -- 按环的【实际尺寸】逐区块请求，不要给一个按环高算出来的大半径 ——
    -- radius 是正方形的，横向会真的生成出去（见 ring.ensure_chunks 的注释）。
    local half = ring.half_width_of(player.name)
    local y_half = math.floor((storage.ring_height or 128) / 2)
    ring.ensure_chunks(surface, -half, half, -y_half, y_half)

    storage.ring_applied_half = storage.ring_applied_half or {}
    storage.ring_applied_half[player.name] = half

    storage.ring_state = storage.ring_state or {}
    storage.ring_state[player.name] = 'private'

    if storage.debug then
        for _, p in pairs(game.connected_players) do
            if p.admin then
                p.print('[pw] 已创建戴森环 ' .. surface.name .. ' 半宽 ' .. half)
            end
        end
    end
    return surface
end

-- 把玩家送进自己的戴森环。没有就先建。
function M.enter(player)
    local surface = M.ensure(player)
    if not (surface and surface.valid) then return false end
    -- 出生点在收货箱阵右侧，避开箱阵本身（箱阵占 x∈{-1,0}、y∈{-3..2}）
    local pos = surface.find_non_colliding_position('character', {4, 0}, 32, 1) or {4, 0}
    player.teleport(pos, surface)
    return true
end

return M
```

- [ ] **Step 3: 改 `control.lua`**

```lua
-- 戴森环计划 scenario 入口。
-- 各子模块在 require 时自行通过 events 总线注册事件，这里只负责按依赖顺序加载 + 初始化。
require('scripts.players')
require('scripts.tick')

local constants = require('scripts.constants')
local events = require('scripts.events')
local worlds = require('scripts.worlds')
local players = require('scripts.players')
local ring = require('scripts.ring')

-- 区块生成时涂砖。走 events 总线而不是直接 script.on_event，避免和别处的订阅互相覆盖。
events.on(defines.events.on_chunk_generated, events.safe('chunk', ring.on_chunk_generated))

script.on_init(function()
    constants.ensure_defaults()
    players.setup_perm_group()

    worlds.ensure_surfaces()
    for _, name in ipairs(constants.PUBLIC_PLANETS) do
        local surface = game.surfaces[name]
        if surface then worlds.apply_bounds(surface) end
    end
    worlds.schedule_all(true)
end)

script.on_configuration_changed(function()
    constants.ensure_defaults()
    players.setup_perm_group()
    worlds.ensure_surfaces()
    worlds.schedule_all(false)
end)
```

**注意**：`values.ensure()` 那一行删掉了（`values.lua` 在 Task 5 删除）。
若此刻 `scripts/values.lua` 还在也无所谓，没人 require 它。

- [ ] **Step 4: 语法体检**

```bash
luac -p scripts/ring.lua scripts/pockets.lua control.lua && echo "语法 OK"
```

- [ ] **Step 5: 游戏内验证**

启动场景（新建游戏 → 选「戴森环计划」），进游戏后 `/c`：

```lua
/c local s = game.player.surface
game.print('surface: ' .. s.name)
game.print('污染类型(应为nil): ' .. tostring(s.pollutant_type))
game.print('原点砖(应为concrete): ' .. s.get_tile(0, 0).name)
game.print('(0,-40)砖(应为empty-space): ' .. s.get_tile(0, -40).name)
game.print('(0,40)砖(应为empty-space): ' .. s.get_tile(0, 40).name)
game.print('(40,0)砖(应为out-of-map): ' .. s.get_tile(40, 0).name)
game.print('(-40,0)砖(应为out-of-map): ' .. s.get_tile(-40, 0).name)
game.print('(0,-70)区块应未生成: ' .. tostring(s.is_chunk_generated({0, -3})))
```

预期输出：

```
surface: ring_1
污染类型(应为nil): nil
原点砖(应为concrete): concrete
(0,-40)砖(应为empty-space): empty-space
(0,40)砖(应为empty-space): empty-space
(40,0)砖(应为out-of-map): out-of-map
(-40,0)砖(应为out-of-map): out-of-map
(0,-70)区块应未生成: false
```

**若 `empty-space` 那两行报错或返回别的砖**：说明 `empty-space` 不能设在普通 surface 上。
降级：把 `geometry.tile_at` 里的 `'empty-space'` 改成 `'out-of-map'`，
同时 Task 7 的「纵向生长」失效，需要回头找你确认。

**若 `污染类型` 不是 nil**：`override_pollution_type = {}` 没生效。
降级：在 `tick.lua` 里加一个周期任务 `surface.clear_pollution()`。

---

## Task 4: chests.lua（12 箱阵 + 木箱↔关联箱）

**Files:**
- Create: `scripts/chests.lua`
- Modify: `scripts/pockets.lua`（`ensure` 里调 `chests.ensure_array`）
- Modify: `control.lua`（require chests）

**Interfaces:**
- Consumes: `ring.is_ring_surface`、`constants.PUBLIC_LINK_ID`
- Produces:
  - `chests.ensure_array(surface, player)` → 无返回，幂等建 12 箱阵
  - `chests.set_array_link(player, link_id)` → 把某人 12 箱阵的 link_id 全改成给定值
  - `chests.expected_link_id(player_name)` → `uint`（按 `ring_state` 推导）

- [ ] **Step 1: 创建 `scripts/chests.lua`**

```lua
-- 关联箱：跨星球物流。
--
-- 玩法：玩家在【公共世界】铺出去的关联箱是一堆投递口，全部通向自己戴森环正中央那组收货箱。
-- 于是背包容量不再是瓶颈，但出门的意义反而更强了 ——
-- 张力从「搬运」转移到「暴露在重置风险里的时间」：
-- 星球重置时投递口全没了，家里的货还在，所以要赶在重置前把投递口铺到矿脉旁边并尽量多送。
--
-- 同一件物品的语义由所在星球决定（在家是储物，出门是投递口），
-- 玩家不需要管理两种箱子，也不会出现「我把珍贵的关联箱浪费在家里了」的懊恼。
local constants = require('scripts.constants')
local events = require('scripts.events')
local ring = require('scripts.ring')

local M = {}

local WOOD = 'wooden-chest'
local LINKED = 'linked-chest'

-- 12 个收货箱的位置：两列 × 六行，以原点双向对称。
-- 12 个同 link_id 的箱子共享的是【同一个库存】，所以这不是 12 倍容量，
-- 是 12 个并行存取口 —— 12 个机械臂可以同时从同一批货里抓取，
-- 而单个箱子只能被有限几个机械臂围住。用箱子数量换吞吐量，不是换容量。
--
-- 这 12 个箱子和公共世界的投递口一样是 operable = false，
-- 也就是说它们是【给机械臂用的接口】，不是【给人用的界面】——
-- 主人取货要在旁边架机械臂把货拖进普通箱子。理由见 ensure_array 里的注释。
local function array_positions()
    local out = {}
    for _, x in ipairs({-1, 0}) do
        for y = -3, 2 do
            out[#out + 1] = {x = x + 0.5, y = y + 0.5}
        end
    end
    return out
end

-- 某人的 12 箱阵此刻应该用哪个 link_id。
-- 公共期（离线 30-50 小时）指向全服公共库存，其余时候指向他自己。
function M.expected_link_id(player_name)
    storage.ring_state = storage.ring_state or {}
    if storage.ring_state[player_name] == 'public' then
        return constants.PUBLIC_LINK_ID
    end
    local player = game.players[player_name]
    return player and player.index or constants.PUBLIC_LINK_ID
end

-- 建 12 箱阵。幂等：已存在的位置跳过。
function M.ensure_array(surface, player)
    local link_id = M.expected_link_id(player.name)
    for _, pos in ipairs(array_positions()) do
        local existing = surface.find_entity(LINKED, pos)
        if not existing then
            local chest = surface.create_entity{
                name = LINKED, position = pos,
                force = game.forces.player, raise_built = false,
            }
            if chest then
                chest.link_id = link_id
                chest.destructible = false   -- 不可摧毁
                chest.minable = false        -- 不可挖走
                chest.operable = false       -- 见下方说明
            end
        else
            -- 已存在的也要重设全部属性，否则老存档里建好的箱阵不会被修上。
            -- 「幂等」不能只是「不重复创建」，还得是「反复调用后状态一致」。
            existing.link_id = link_id
            existing.destructible = false
            existing.minable = false
            existing.operable = false
        end
    end
end

-- 把某人 12 箱阵的 link_id 整体切换（公共化 / 回归时用）。
function M.set_array_link(player, link_id)
    local surface = game.surfaces[ring.surface_name_for(player.index)]
    if not (surface and surface.valid) then return 0 end
    local changed = 0
    -- 不存箱子的 LuaEntity 引用：surface 重建后引用会失效，每次现查最可靠。
    for _, chest in pairs(surface.find_entities_filtered{name = LINKED}) do
        chest.link_id = link_id
        changed = changed + 1
    end
    return changed
end

-------------------------------------------------------------------------------
-- 木箱 ↔ 关联箱
-------------------------------------------------------------------------------

-- 手搓木箱直接换成关联箱物品。
-- 组装机产的木箱抓不到（那是 entity 在造），所以放置时还有一道兜底，见下面的 on_built。
events.on(defines.events.on_player_crafted_item, function(event)
    local stack = event.item_stack
    if not (stack and stack.valid and stack.valid_for_read) then return end
    if stack.name ~= WOOD then return end
    local player = game.players[event.player_index]
    if not player then return end

    local count = stack.count
    stack.clear()
    player.insert{name = LINKED, count = count}
end)

-- 在原位把一个实体换成另一种。返回新实体。
local function swap(entity, new_name, player_index)
    local surface, position, force = entity.surface, entity.position, entity.force
    entity.destroy()
    return surface.create_entity{
        name = new_name, position = position, force = force,
        player = player_index, raise_built = false,
    }
end

local function on_built(event)
    local entity = event.entity
    if not (entity and entity.valid) then return end
    if entity.name ~= WOOD and entity.name ~= LINKED then return end

    -- 建造者：手动建有 player_index，机器人建则看 last_user
    local player_index = event.player_index
    if not player_index and entity.last_user then player_index = entity.last_user.index end

    local in_ring = ring.is_ring_surface(entity.surface)

    if in_ring then
        -- 戴森环里关联箱退化回木箱：家里要有普通储物箱可用。
        -- 12 个预置收货箱是脚本 create_entity 出来的，不触发本事件，不会被误伤。
        -- 万一将来接了 script_raised_built，判据是 destructible == false（玩家放的永远可摧毁）。
        if entity.name == LINKED and entity.destructible then
            swap(entity, WOOD, player_index)
        end
        return
    end

    -- 公共世界：木箱兜底转成关联箱，然后一律绑 ID
    local chest = entity
    if chest.name == WOOD then
        chest = swap(chest, LINKED, player_index)
        if not (chest and chest.valid) then return end
    end

    if player_index then
        chest.link_id = player_index
    end

    -- 防偷的全部机制就这一行。
    --
    -- link_id 是玩家可改的，攻击方式不是改【别人的】箱子，而是把【自己的】箱子 link_id
    -- 设成受害者的 player.index —— 那一瞬间就有了一个通向他全部库存的窗口。
    -- 而 player.index 是从 1 开始的小整数，穷举成本近乎为零。
    --
    -- operable = false 让谁都打不开这个箱子的界面，link_id 自然改不了。
    -- 机械臂和传送带完全不受影响 —— operable 只管玩家 GUI。
    --
    -- 代价：手动往投递口倒背包也做不到了（包括主人自己）。
    -- 这是有意的：投递口从「随手的邮筒」变成「必须建设的采集前哨」。
    chest.operable = false
end

events.on(defines.events.on_built_entity, on_built)
events.on(defines.events.on_robot_built_entity, on_built)

-- 公共期里，别人能进你的环，而 12 个收货箱是 operable = true 的 ——
-- 访客可以把其中一个的 link_id 改成第三个玩家的 index 来偷他。
-- 这些箱子的正确 link_id 永远可推导，所以关闭界面时重算一次写回即可。
events.on(defines.events.on_gui_closed, function(event)
    local entity = event.entity
    if not (entity and entity.valid and entity.name == LINKED) then return end
    if not ring.is_ring_surface(entity.surface) then return end
    local owner = ring.owner_name_of(entity.surface)
    if not owner then return end
    entity.link_id = M.expected_link_id(owner)
end)

return M
```

- [ ] **Step 2: 在 `pockets.ensure` 里建箱阵**

`scripts/pockets.lua` 顶部加 `local chests = require('scripts.chests')`，
并在 `M.ensure` 的 `force_generate_chunk_requests()` 之后、`storage.ring_applied_half` 之前插入：

```lua
    chests.ensure_array(surface, player)
```

- [ ] **Step 3: `control.lua` 加载 chests**

在 `require('scripts.tick')` 下面加一行：

```lua
require('scripts.chests')
```

（chests.lua 在 require 顶层注册事件，必须被加载到。）

- [ ] **Step 4: 语法体检**

```bash
luac -p scripts/chests.lua scripts/pockets.lua control.lua && echo "语法 OK"
```

- [ ] **Step 5: 游戏内验证**

新建游戏后 `/c`：

```lua
/c local p = game.player
local s = p.surface
local arr = s.find_entities_filtered{name = 'linked-chest'}
game.print('箱阵数量(应为12): ' .. #arr)
game.print('link_id(应为' .. p.index .. '): ' .. tostring(arr[1] and arr[1].link_id))
game.print('可摧毁(应为false): ' .. tostring(arr[1] and arr[1].destructible))
game.print('可挖(应为false): ' .. tostring(arr[1] and arr[1].minable))
game.print('可开(应为true): ' .. tostring(arr[1] and arr[1].operable))
p.insert{name = 'wooden-chest', count = 5}
game.print('--- 现在手动做以下三件事 ---')
game.print('1. 在环里放一个木箱 → 应该还是木箱')
game.print('2. 传送到 nauvis 放一个木箱 → 应该变成关联箱、link_id=' .. p.index .. '、打不开')
game.print('3. 手搓一个木箱 → 背包里应该出现关联箱')
```

预期：

```
箱阵数量(应为12): 12
link_id(应为1): 1
可摧毁(应为false): false
可挖(应为false): false
可开(应为true): true
```

然后手动跑那三件事。第 2 步传送用 `/c game.player.teleport({0,0}, game.surfaces.nauvis)`。

**若第 3 步手搓不出关联箱**：`linked-chest` 物品可能带 `only-in-cursor` 之类的 flag。
降级：删掉 `on_player_crafted_item` 那段，只保留放置时的 `swap`——
玩家仍然拿着木箱出门，放下就变关联箱，玩法不受影响。

---

## Task 5: exp.lua 12 种记账 + 兑换（兑换后环立即变宽）

**Files:**
- Modify: `scripts/exp.lua`（整体重写）
- Delete: `scripts/values.lua`

**Interfaces:**
- Consumes: `geometry.SCIENCE_PACKS`、`geometry.pack_item_name`、`constants.ensure_exp_table`、`ring.apply_growth`、`stamina.spend`
- Produces:
  - `exp.get(player_name)` → 12 键 table
  - `exp.add(player_name, pack_short, amount)` → 无返回
  - `exp.appraise(player)` → `entries, total`，`entries` 是 `{ {pack=短名, item=物品名, quality=品质名, count=数量, gain=经验} ... }`
  - `exp.preview(player)` → `entries, total_gain, cost`
  - `exp.convert(player)` → `total_gain, entries` 或 `nil, 错误key`

- [ ] **Step 1: 重写 `scripts/exp.lua`**

```lua
-- 12 种经验 + 兑换。本场景唯一的跨重置进度。
--
-- 每种科技瓶对应一种经验，分开记账。戴森环的宽度 = 32 × (2 + floor(Σ log10(expᵢ)))。
-- 因为 log10(1) = 0，任何一种瓶子没攒过那一项就是 0 —— 这逼玩家集齐 12 种、跑遍五个星球。
--
-- 为什么不需要跨瓶种定价：12 种各自独立取 log10、互不换算，
-- 普罗米修斯瓶只喂普罗米修斯那一项，跟红瓶从不在同一个数里比大小。
-- 所以 1 瓶 = 1 经验 × 品质系数就够了，v1 那套递归展开配方求原矿当量的 values.lua 失去了全部存在理由。
local geometry = require('scripts.geometry')
local constants = require('scripts.constants')
local stamina = require('scripts.stamina')
local ring = require('scripts.ring')
local util = require('scripts.util')

local M = {}

-- 物品名 → 瓶子短名的反查表。建一次缓存在模块里（纯常量，不进 storage）。
local ITEM_TO_PACK = {}
for _, short in ipairs(geometry.SCIENCE_PACKS) do
    ITEM_TO_PACK[geometry.pack_item_name(short)] = short
end

function M.get(player_name)
    return constants.ensure_exp_table(player_name)
end

function M.add(player_name, pack_short, amount)
    amount = math.floor(amount or 0)
    if amount <= 0 then return end
    local tbl = constants.ensure_exp_table(player_name)
    tbl[pack_short] = (tbl[pack_short] or 0) + amount
end

-- 扫背包，只认 12 种科技瓶。不改动背包，纯统计，供预览和实际兑换共用，
-- 保证「看到的」和「换到的」一致。
function M.appraise(player)
    local inventory = util.main_inventory(player)
    if not inventory then return {}, 0 end

    local quality_exp = storage.quality_exp or
        {normal = 1, uncommon = 3, rare = 5, epic = 7, legendary = 9}

    local entries, total = {}, 0
    for _, item in pairs(inventory.get_contents()) do
        local short = ITEM_TO_PACK[item.name]
        if short then
            local mult = quality_exp[item.quality] or 1
            local gain = item.count * mult
            entries[#entries + 1] = {
                pack = short, item = item.name, quality = item.quality,
                count = item.count, gain = gain,
            }
            total = total + gain
        end
    end
    return entries, total
end

-- 预览：不改动任何状态。GUI 用。
function M.preview(player)
    local entries, total = M.appraise(player)
    return entries, total, math.floor(storage.convert_cost or 1)
end

-- 实际兑换。体力走【门票制】：固定扣 convert_cost 点，背包里 12 种瓶子一次全兑。
-- 先扣体力再移除物品：扣不掉就整个中止，不会出现「物品没了但没给经验」。
function M.convert(player)
    local inventory = util.main_inventory(player)
    if not inventory then return nil, 'pw.convert-no-character' end

    local entries, total = M.appraise(player)
    if total <= 0 then return nil, 'pw.convert-nothing' end

    local cost = math.floor(storage.convert_cost or 1)
    if not stamina.spend(player.name, cost) then return nil, 'pw.convert-no-stamina' end

    for _, e in ipairs(entries) do
        inventory.remove({name = e.item, count = e.count, quality = e.quality})
        M.add(player.name, e.pack, e.gain)
    end

    storage.exp_log = storage.exp_log or {}
    storage.exp_log[player.name] = {entries = entries, total = total, cost = cost, tick = game.tick}

    -- 兑换完立刻重算环宽并扩容，玩家点完按钮就能看见世界变宽
    ring.apply_growth(player)

    return total, entries
end

return M
```

- [ ] **Step 2: 删掉 values.lua**

```bash
rm scripts/values.lua
```

- [ ] **Step 3: 确认没有残留引用**

```bash
grep -rn "values" scripts/ control.lua
```

预期：只剩 `gui.lua` 里的（Task 9 会整个删掉 `gui.lua`）。若 `control.lua` 里还有，删掉。

- [ ] **Step 4: 语法体检**

```bash
luac -p scripts/exp.lua && echo "语法 OK"
```

- [ ] **Step 5: 游戏内验证**

```lua
/c local p = game.player
local exp = require('scripts.exp')
local ring = require('scripts.ring')
game.print('初始等级(应为0): ' .. ring.level_of(p.name))
game.print('初始半宽(应为32): ' .. ring.half_width_of(p.name))
p.insert{name = 'automation-science-pack', count = 1000}
local gain = exp.convert(p)
game.print('获得经验(应为1000): ' .. tostring(gain))
game.print('新等级(应为3): ' .. ring.level_of(p.name))
game.print('新半宽(应为80): ' .. ring.half_width_of(p.name))
game.print('(-70,0)砖(扩容后应为concrete): ' .. p.surface.get_tile(-70, 0).name)
game.print('(79,0)砖(应为concrete): ' .. p.surface.get_tile(79, 0).name)
game.print('(80,0)砖(应为out-of-map): ' .. p.surface.get_tile(80, 0).name)
```

预期：

```
初始等级(应为0): 0
初始半宽(应为32): 32
获得经验(应为1000): 1000
新等级(应为3): 3
新半宽(应为80): 80
(-70,0)砖(扩容后应为concrete): concrete
(79,0)砖(应为concrete): concrete
(80,0)砖(应为out-of-map): out-of-map
```

（`log10(1000) = 3`，半宽 `32 + 16×3 = 80`。）

---

## Task 6: 离线生命周期状态机（30h 变公共 / 50h 删除）

**Files:**
- Modify: `scripts/pockets.lua`（加 `tick_lifecycle` / `restore_on_join` / `delete_ring`）
- Modify: `scripts/players.lua`（`on_player_joined_game` 里调 `restore_on_join`）
- Modify: `scripts/tick.lua`（周期调度）

**Interfaces:**
- Consumes: `chests.set_array_link`、`chests.expected_link_id`、`constants.PUBLIC_LINK_ID`
- Produces:
  - `pockets.delete_ring(player)` → `boolean, 错误key?`
  - `pockets.restore_on_join(player)` → 无返回
  - `pockets.tick_lifecycle()` → 无返回
  - `pockets.make_public(player)` → `boolean`，执行 private→public 跃迁（周期扫描和"访客进入"两条路都调它）
  - `pockets.all_rings()` → 数组 `{ {owner_name=, owner_index=, idle_hours=, half_width=, state=, enterable=} ... }`（GUI 用）

- [ ] **Step 1: 在 `scripts/pockets.lua` 追加生命周期代码**

文件顶部加 `local chests = require('scripts.chests')`（Task 4 已加则跳过）。追加：

```lua
-------------------------------------------------------------------------------
-- 离线生命周期：30 小时变公共，50 小时删除
--
-- 这把「回收」从一个二元开关变成了有中间态的过程，而中间态本身是玩法 ——
-- 弃厂不是消失，是先变成公共资产：它继续运转、产出汇进全服公共池，任人拆解取用。
--
-- 同时修掉了 v1 一个很粗暴的设定（离线半小时回来工厂就没了）：
-- 现在 30 小时才开始有后果，50 小时才真的删，而且删的只是建筑，进度一点不丢。
-------------------------------------------------------------------------------

-- 把还留在某 surface 上的玩家撤回各自的戴森环。
local function evacuate(surface, except_name)
    for _, p in pairs(game.connected_players) do
        if p.surface == surface and p.name ~= except_name then
            p.print({'pw.ring-evacuated'})
            M.enter(p)
        end
    end
end

-- 删除某人的戴森环。经验一点不动，下次上线重新长出来。
function M.delete_ring(player)
    if not (player and player.valid) then return false, 'pw.cmd-no-player' end
    if player.connected then return false, 'pw.cmd-player-online' end

    local surface = M.get(player)
    if not (surface and surface.valid) then return false, 'pw.cmd-no-ring' end

    evacuate(surface, nil)
    game.delete_surface(surface)

    storage.ring_state = storage.ring_state or {}
    storage.ring_state[player.name] = nil
    storage.ring_applied_half = storage.ring_applied_half or {}
    storage.ring_applied_half[player.name] = nil
    return true
end

-- 玩家上线：若他的环在公共期，立刻收回。
function M.restore_on_join(player)
    storage.ring_state = storage.ring_state or {}
    if storage.ring_state[player.name] ~= 'public' then return end

    storage.ring_state[player.name] = 'private'
    chests.set_array_link(player, player.index)

    local surface = M.get(player)
    if surface and surface.valid then
        evacuate(surface, player.name)   -- 把还在里面逛的访客请出去
    end
    player.print({'pw.ring-reclaimed'})
end

-- 离线多久了（小时）。在线玩家返回 0。
function M.idle_hours(player)
    if player.connected then return 0 end
    return (game.tick - (player.last_online or 0)) / constants.hour_to_tick
end

-- private → public 跃迁。周期扫描和「访客点进来」两条路都走这里，保证行为一致。
-- 已经是 public 的直接返回 false，幂等。
function M.make_public(player)
    storage.ring_state = storage.ring_state or {}
    if storage.ring_state[player.name] == 'public' then return false end
    if not M.get(player) then return false end

    storage.ring_state[player.name] = 'public'
    chests.set_array_link(player, constants.PUBLIC_LINK_ID)
    game.print({'pw.ring-public', player.name})
    return true
end

-- 周期任务：扫描离线玩家，做 private → public 和 public → 删除 两个跃迁。
--
-- 【关键】阈值每次现读、现算 idle，绝不缓存成「到期 tick」。
-- 存了到期 tick 的话，改配置就只对新数据生效，服务器会处于两套规则并存的状态。
function M.tick_lifecycle()
    storage.ring_state = storage.ring_state or {}
    local hour = constants.hour_to_tick
    local public_at = (storage.ring_public_hours or 30) * hour
    local delete_at = (storage.ring_delete_hours or 50) * hour

    for _, player in pairs(game.players) do
        if not player.connected then
            local idle = game.tick - (player.last_online or 0)
            local state = storage.ring_state[player.name]

            if idle >= delete_at then
                if M.get(player) then
                    M.delete_ring(player)
                    game.print({'pw.ring-deleted', player.name})
                end
            elseif idle >= public_at and state == 'private' then
                M.make_public(player)
            end
        end
    end
end

-- 所有存在的戴森环，供传送窗口列出。
--
-- 列【全部】而不是只列公共的：玩家看得到别人的环有多大、离线多久、还有多久能进，
-- 这比一个空列表有信息量得多，也让「等某人超时」变成一件可以规划的事。
-- 但 enterable 只对已超过 ring_public_hours 的为 true —— 看得到不等于进得去。
function M.all_rings()
    storage.ring_state = storage.ring_state or {}
    local public_hours = storage.ring_public_hours or 30
    local out = {}
    for _, player in pairs(game.players) do
        if M.get(player) then
            local idle = M.idle_hours(player)
            out[#out + 1] = {
                owner_name = player.name,
                owner_index = player.index,
                idle_hours = math.floor(idle),
                half_width = ring.half_width_of(player.name),
                state = storage.ring_state[player.name] or 'private',
                enterable = idle >= public_hours,
            }
        end
    end
    return out
end
```

- [ ] **Step 2: 改 `scripts/players.lua`**

`on_player_joined_game` 的 handler 整体替换成：

```lua
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
```

同时把 `BLOCKED_ACTIONS` 整体清空（保留变量和循环，方便管理员日后往里加）：

```lua
-- 本场景【默认不禁用玩家任何权限】，包括蓝图库。
--
-- v1 禁蓝图的理由是「允许蓝图库的话，重置后 Ctrl+V 一秒恢复布局，重置就只剩重跑一遍物流」。
-- 但这条理由在本版已经不成立：重置的是【公共世界】，而玩家的产线在【戴森环】里，
-- 本来就不会被重置。公共世界上只有采集前哨，那本来就该是能快速重铺的东西。
-- 本版真正的持续压力来自科技漏水和弃厂公有化，蓝图一个都加速不了。
--
-- 关联箱的防偷因此不能靠权限组，改用实体级的 operable = false，见 chests.lua。
local BLOCKED_ACTIONS = {}
```

`STARTER_ITEMS` 里的 `wooden-chest` 若有则删掉（木箱现在有特殊语义，起手给容易让新人困惑）；
当前 v1 的 STARTER_ITEMS 没有木箱，无需改动。

- [ ] **Step 3: 改 `scripts/tick.lua`**

把 `pockets.reclaim_offline()` 那一段换成：

```lua
    -- 约每分钟：戴森环离线生命周期（30h 变公共 / 50h 删除）
    if tick % 3613 == 0 then
        pockets.tick_lifecycle()
    end
```

- [ ] **Step 4: 语法体检**

```bash
luac -p scripts/pockets.lua scripts/players.lua scripts/tick.lua && echo "语法 OK"
```

- [ ] **Step 5: 游戏内验证**

单人环境下没法真的离线 30 小时，用改配置来压缩时间：

```lua
/c local p = game.player
local pockets = require('scripts.pockets')
local chests = require('scripts.chests')
storage.ring_public_hours = 0      -- 立刻满足变公共条件
storage.ring_delete_hours = 99999  -- 但别删
-- 伪造离线：临时把 ring_state 设回 private 再手动跑一次跃迁
storage.ring_state[p.name] = 'private'
chests.set_array_link(p, 0)
storage.ring_state[p.name] = 'public'
local arr = p.surface.find_entities_filtered{name = 'linked-chest'}
game.print('公共期 link_id(应为0): ' .. tostring(arr[1].link_id))
pockets.restore_on_join(p)
arr = p.surface.find_entities_filtered{name = 'linked-chest'}
game.print('回归后 link_id(应为' .. p.index .. '): ' .. tostring(arr[1].link_id))
game.print('回归后状态(应为private): ' .. tostring(storage.ring_state[p.name]))
storage.ring_public_hours = 30
storage.ring_delete_hours = 50
```

预期：

```
公共期 link_id(应为0): 0
回归后 link_id(应为1): 1
回归后状态(应为private): private
```

---

## Task 7: worlds.lua 科技丢失

**Files:**
- Modify: `scripts/worlds.lua`

**Interfaces:**
- Consumes: 无新增
- Produces:
  - `worlds.pack_count(tech)` → `integer`，该科技配方里不重复的科技瓶种数
  - `worlds.loss_chance(tech)` → `number`，`k × n / 100`，不可丢的返回 0
  - `worlds.expected_losses()` → `number`，全表期望丢失数（GUI 预告用）
  - `worlds.roll_tech_loss()` → 被撤销的科技名数组

- [ ] **Step 1: 在 `scripts/worlds.lua` 追加**

```lua
-------------------------------------------------------------------------------
-- 科技丢失
--
-- 每个公共世界重置时全表判定：P(丢失) = k × 该科技的瓶子种数 / 100。
--
-- 为什么挂到瓶子种数而不是固定概率：固定 5% 的话，automation 和终局科技一样容易丢，
-- 玩家可能上线就发现造不出传送带。挂到种数上之后，科技树越深越容易漏水，地基反而最稳固。
-- 更重要的是它形成了一个自然的高度上限而不需要任何人为封顶：
-- 越往上侵蚀速率越高，全服最终停在「集体产能刚好补上漏水速度」的那个高度。
-- 水位由玩家的产能决定，不是由某个写死的数字决定。
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
    -- 但仍然显式跳过 —— 「规则恰好算出正确答案」和「规则明确表达意图」是两回事。
    if proto.research_trigger then return 0 end

    -- 无限科技不参与：它们 researched 恒为 false、用 level 计数，改 level 会让规则难以解释。
    if proto.max_level and proto.level and proto.level < proto.max_level then return 0 end

    return (storage.tech_loss_k or 1) * M.pack_count(tech) / 100
end

-- 全表期望丢失数。传送窗口的重置预告用 —— 报一个「预计丢失约 X 项」比报百分比直观得多。
function M.expected_losses()
    local sum = 0
    for _, tech in pairs(game.forces.player.technologies) do
        sum = sum + M.loss_chance(tech)
    end
    return sum
end

-- 掷骰子，返回被撤销的科技名数组。
-- math.random 在 Factorio 里是确定性的、多人同步安全的。
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
```

- [ ] **Step 2: 科技丢失是【独立周期任务】，不挂在星球重置上**

**不要**把 `roll_tech_loss` 塞进 `reset_world`。它自成一个周期任务，
由 Task 12 的相位调度器按固定周期（默认 1 小时）调用。

理由：挂在星球重置上的话，科技丢失的节奏就被五个星球的周期（1/2/3/4/5 小时）绑架了 ——
玩家会发现"Nauvis 一重置就掉科技"，把两件本来无关的事在心理上焊死。
拆开之后，星球重置管"地上的东西没了"，科技漏水管"图纸慢慢忘了"，
两条压力线各走各的，玩家也更容易分别理解和应对。

在 `worlds.lua` 里导出一个供调度器调用的入口：

```lua
-- 周期任务：全服科技漏水判定一轮。由 tick.lua 的相位调度器按固定周期调用，
-- 【不】挂在星球重置上 —— 那会把「地上的东西没了」和「图纸慢慢忘了」两条压力线焊死。
function M.tick_tech_loss()
    local lost = M.roll_tech_loss()
    if #lost > 0 then
        game.print({'pw.tech-lost', #lost, table.concat(lost, ', ')})
    end
    return #lost
end
```

`reset_world` 保持原样，**不加**任何科技相关的调用。

- [ ] **Step 3: 语法体检**

```bash
luac -p scripts/worlds.lua && echo "语法 OK"
```

- [ ] **Step 4: 游戏内验证**

```lua
/c local worlds = require('scripts.worlds')
local f = game.forces.player
f.technologies['automation'].researched = true
f.technologies['logistics'].researched = true
game.print('automation 瓶种数(应为1): ' .. worlds.pack_count(f.technologies['automation']))
game.print('automation 概率(应为0.01): ' .. worlds.loss_chance(f.technologies['automation']))
game.print('logistics 瓶种数(应为2): ' .. worlds.pack_count(f.technologies['logistics']))
game.print('logistics 概率(应为0.02): ' .. worlds.loss_chance(f.technologies['logistics']))
game.print('未研究的概率(应为0): ' .. worlds.loss_chance(f.technologies['solar-energy']))
game.print('全表期望丢失: ' .. string.format('%.2f', worlds.expected_losses()))
-- k 调到 100 让每个可丢科技必定丢，验证 roll 真的会撤销
storage.tech_loss_k = 100
local lost = worlds.roll_tech_loss()
game.print('必丢模式下丢失数(应 >= 2): ' .. #lost)
game.print('automation 现在(应为false): ' .. tostring(f.technologies['automation'].researched))
storage.tech_loss_k = 1
```

预期：概率分别是 0.01 / 0.02，未研究的是 0，`k=100` 时把已研究的全撤销。

**注意**：`logistics` 科技在 2.0 里要红绿两种瓶，所以 n=2。若实际输出不是 2，
说明该科技的配方和预期不同——换一个已知瓶种数的科技重试即可，公式本身没错。

---

## Task 8: commands.lua 管理员指令

**Files:**
- Create: `scripts/commands.lua`
- Modify: `control.lua`（require commands）

**Interfaces:**
- Consumes: `pockets.delete_ring`
- Produces: 注册 `/ring-delete` 指令，无 Lua 层导出

- [ ] **Step 1: 创建 `scripts/commands.lua`**

```lua
-- 管理员指令。全部注册在这里，方便一眼看全。
local pockets = require('scripts.pockets')

local M = {}

-- /ring-delete <玩家名>
--
-- 删除指定玩家的戴森环表面。经验一点不动 —— 玩家下次上线时环按经验立刻恢复到原样，
-- 丢的只有建筑和关联库存。和离线 50 小时那条规则完全一致，只是由管理员手动触发。
--
-- 目标在线时【拒绝执行】。删表面必然要处理「人在里面怎么办」，
-- 而任何处理方式都是在玩家没有心理准备时动他的世界。
-- 拒绝执行把这个决定推回给管理员：想删就先请人下线。
commands.add_command('ring-delete', {'pw.cmd-ring-delete-help'}, function(command)
    local caller = command.player_index and game.players[command.player_index]
    if caller and not caller.admin then
        caller.print({'pw.cmd-admin-only'})
        return
    end

    local function reply(msg)
        if caller then caller.print(msg) else game.print(msg) end
    end

    local target_name = command.parameter and string.match(command.parameter, '^%s*(.-)%s*$')
    if not target_name or target_name == '' then
        reply({'pw.cmd-ring-delete-usage'})
        return
    end

    local target = game.players[target_name]
    if not target then
        reply({'pw.cmd-no-player', target_name})
        return
    end

    local ok, err = pockets.delete_ring(target)
    if not ok then
        reply({err or 'pw.cmd-no-ring'})
        return
    end

    reply({'pw.cmd-ring-deleted', target_name})
    for _, p in pairs(game.connected_players) do
        if p.admin and p ~= caller then
            p.print({'pw.cmd-ring-deleted-broadcast', target_name, caller and caller.name or '<console>'})
        end
    end
end)

return M
```

- [ ] **Step 2: `control.lua` 加载**

在 `require('scripts.chests')` 下面加：

```lua
require('scripts.commands')
```

- [ ] **Step 3: 语法体检**

```bash
luac -p scripts/commands.lua control.lua && echo "语法 OK"
```

- [ ] **Step 4: 游戏内验证**

```
/ring-delete
```
预期：提示用法。

```
/ring-delete 不存在的人
```
预期：提示查无此人。

```
/ring-delete <你自己的名字>
```
预期：提示"该玩家在线"，环**没有**被删。

---

## Task 9: GUI 拆分成六个文件

**Files:**
- Create: `scripts/gui/init.lua` / `hud.lua` / `convert.lua` / `travel.lua` / `exp.lua` / `help.lua`
- Delete: `scripts/gui.lua`
- Modify: `scripts/tick.lua`

**Interfaces:**
- Consumes: `exp.*`、`ring.*`、`pockets.*`、`worlds.*`、`stamina.*`、`geometry.SCIENCE_PACKS`
- Produces:
  - `gui.refresh_hud(player)`（`gui/init.lua` 转发到 `hud`）
  - `gui.on_click(event)`
  - 各窗口模块导出 `M.show(player)`
  - 公共辅助：`gui/init.lua` 导出 `open_popup(player, title)` / `close_popup(player)`

- [ ] **Step 1: 创建 `scripts/gui/init.lua`**

```lua
-- GUI 路由 + 弹窗骨架。各窗口模块只管往容器里填内容。
-- 全部用引擎自带 style，不引入任何图片资源，scenario 目录就能跑起来。
local M = {}

M.HUD_NAME = 'pw_hud'
M.POPUP_NAME = 'pw_popup'

-- 关掉可能已存在的弹窗，保证同时只有一个，不会叠罗汉
function M.close_popup(player)
    local existing = player.gui.screen[M.POPUP_NAME]
    if existing then existing.destroy() end
end

-- 建一个居中的空弹窗框架，返回内容容器供调用方填充
function M.open_popup(player, title)
    M.close_popup(player)
    local frame = player.gui.screen.add{
        type = 'frame', name = M.POPUP_NAME, caption = title, direction = 'vertical'}
    frame.auto_center = true
    local inner = frame.add{type = 'flow', name = 'inner', direction = 'vertical'}
    frame.add{type = 'button', name = 'pw_close', caption = {'pw.close'}}
    return inner
end

-- 子模块要用 open_popup，所以必须在 M 定义之后 require（循环依赖）
local hud = require('scripts.gui.hud')
local convert = require('scripts.gui.convert')
local travel = require('scripts.gui.travel')
local exp_window = require('scripts.gui.exp')
local help = require('scripts.gui.help')

function M.refresh_hud(player)
    hud.refresh(player)
end

function M.on_click(event)
    local element = event.element
    if not (element and element.valid) then return end
    local player = game.players[event.player_index]
    if not player then return end
    local name = element.name

    if name == 'pw_close' then
        M.close_popup(player)
    elseif name == 'pw_btn_convert' then
        convert.show(player)
    elseif name == 'pw_btn_travel' then
        travel.show(player)
    elseif name == 'pw_btn_exp' then
        exp_window.show(player)
    elseif name == 'pw_btn_help' then
        help.show(player)
    elseif convert.on_click(player, name) then
        return
    elseif travel.on_click(player, name) then
        return
    end
end

return M
```

**循环依赖处理**：`gui/init.lua` 在定义完 `open_popup` / `close_popup` 之后才 require 子模块，
子模块顶部写 `local gui = require('scripts.gui.init')` 时拿到的是已经填好那两个函数的同一张表。
这是 Lua 的 package.loaded 机制，可行但脆弱——**子模块里不要在顶层调用 `gui.xxx()`**，
只能在函数体内调（那时 init 已经加载完）。

- [ ] **Step 2: 创建 `scripts/gui/hud.lua`**

```lua
local geometry = require('scripts.geometry')
local ring = require('scripts.ring')
local stamina = require('scripts.stamina')

local M = {}

function M.refresh(player)
    local gui = require('scripts.gui.init')
    local root = player.gui.top[gui.HUD_NAME]
    if not root then
        root = player.gui.top.add{type = 'frame', name = gui.HUD_NAME, direction = 'horizontal'}
    end
    root.clear()

    local level = ring.level_of(player.name)
    local width = ring.half_width_of(player.name) * 2

    root.add{type = 'label', caption = {'pw.hud-ring', level, width}}
    root.add{type = 'label', caption = {'pw.hud-stamina',
        stamina.get(player.name), storage.stamina_cap or 1440}}

    root.add{type = 'button', name = 'pw_btn_convert', caption = {'pw.btn-convert'},
             tooltip = {'pw.btn-convert-tip'}}
    root.add{type = 'button', name = 'pw_btn_travel', caption = {'pw.btn-travel'},
             tooltip = {'pw.btn-travel-tip'}}
    root.add{type = 'button', name = 'pw_btn_exp', caption = {'pw.btn-exp'},
             tooltip = {'pw.btn-exp-tip'}}
    root.add{type = 'button', name = 'pw_btn_help', caption = {'pw.btn-help'}}
end

return M
```

- [ ] **Step 3: 创建 `scripts/gui/convert.lua`**

```lua
local exp = require('scripts.exp')
local stamina = require('scripts.stamina')
local util = require('scripts.util')

local M = {}

function M.show(player)
    local gui = require('scripts.gui.init')
    local inner = gui.open_popup(player, {'pw.convert-title'})
    local entries, total, cost = exp.preview(player)

    if #entries == 0 then
        inner.add{type = 'label', caption = {'pw.convert-nothing'}}
    else
        for _, e in ipairs(entries) do
            inner.add{type = 'label', caption = {'pw.convert-row',
                '[item=' .. e.item .. ']', e.count, e.quality, util.readable(e.gain)}}
        end
    end

    inner.add{type = 'label', caption = {'pw.convert-total', util.readable(total), cost}}
    inner.add{type = 'label', caption = {'pw.convert-have', stamina.get(player.name)}}

    local button = inner.add{type = 'button', name = 'pw_do_convert', caption = {'pw.convert-do'}}
    if total <= 0 or stamina.get(player.name) < cost then
        button.enabled = false
        button.tooltip = {'pw.convert-cannot'}
    end
end

-- 返回 true 表示本模块处理了这次点击
function M.on_click(player, name)
    if name ~= 'pw_do_convert' then return false end
    local gui = require('scripts.gui.init')
    local gain, err = exp.convert(player)
    if gain then
        player.print({'pw.convert-done', util.readable(gain)})
    else
        player.print({err or 'pw.convert-nothing'})
    end
    gui.close_popup(player)
    require('scripts.gui.hud').refresh(player)
    return true
end

return M
```

- [ ] **Step 4: 创建 `scripts/gui/travel.lua`**

```lua
local constants = require('scripts.constants')
local pockets = require('scripts.pockets')
local worlds = require('scripts.worlds')

local M = {}

function M.show(player)
    local gui = require('scripts.gui.init')
    local inner = gui.open_popup(player, {'pw.travel-title'})

    -- 一、回自己的戴森环
    inner.add{type = 'button', name = 'pw_go_ring', caption = {'pw.travel-home'}}

    -- 二、五个公共世界
    inner.add{type = 'label', caption = {'pw.travel-worlds-head'}}
    inner.add{type = 'label', caption = {'pw.travel-tech-warn',
        string.format('%.1f', worlds.expected_losses())}}

    for _, name in ipairs(constants.PUBLIC_PLANETS) do
        local row = inner.add{type = 'flow', direction = 'horizontal'}
        local surface = game.surfaces[name]
        local left = math.max(0, math.floor(worlds.time_left(name) / constants.min_to_tick))
        local run = (storage.world_run or {})[name] or 0

        row.add{type = 'label', caption = {'pw.travel-world-row', name, left, run}}
        local go = row.add{type = 'button', name = 'pw_go_' .. name, caption = {'pw.travel-go'}}
        if not (surface and surface.valid) then
            go.enabled = false
            go.tooltip = {'pw.world-not-ready', name}
        end
    end

    -- 三、所有玩家的戴森环：全部列出（含离线时长），但只有超过 ring_public_hours 的能进
    local rings = pockets.all_rings()
    if #rings > 0 then
        inner.add{type = 'label', caption = {'pw.travel-rings-head',
            storage.ring_public_hours or 30}}
        for _, entry in ipairs(rings) do
            local row = inner.add{type = 'flow', direction = 'horizontal'}
            row.add{type = 'label', caption = {'pw.travel-ring-row',
                entry.owner_name, entry.half_width * 2, entry.idle_hours}}
            local go = row.add{type = 'button', name = 'pw_go_ring_' .. entry.owner_index,
                               caption = {'pw.travel-go'}}
            if not entry.enterable then
                go.enabled = false
                -- 还差多久才可进入，给玩家一个可规划的数字
                go.tooltip = {'pw.travel-ring-locked',
                    math.max(0, (storage.ring_public_hours or 30) - entry.idle_hours)}
            end
        end
    end
end

function M.on_click(player, name)
    local gui = require('scripts.gui.init')

    if name == 'pw_go_ring' then
        pockets.enter(player)
        gui.close_popup(player)
        return true
    end

    -- 别人的戴森环。必须在下面的 'pw_go_' 前缀判断【之前】匹配，
    -- 否则会被当成星球名 'ring_7' 传给 worlds.travel。
    local ring_index = string.match(name, '^pw_go_ring_(%d+)$')
    if ring_index then
        local owner = game.players[tonumber(ring_index)]
        local surface = owner and pockets.get(owner)
        if not (surface and surface.valid) then
            player.print({'pw.travel-ring-gone'})
            gui.close_popup(player)
            return true
        end

        -- 再校验一次门槛：按钮可能是在阈值改动前渲染的，也可能主人刚上线。
        -- UI 的 enabled 只是提示，真正的闸门在这里。
        if pockets.idle_hours(owner) < (storage.ring_public_hours or 30) then
            player.print({'pw.travel-ring-locked-msg', owner.name})
            gui.close_popup(player)
            return true
        end

        -- 惰性公共化：有人真的走进来的那一刻才切 link_id，不必等周期扫描。
        -- make_public 幂等，已经是 public 的直接返回 false。
        pockets.make_public(owner)

        local pos = surface.find_non_colliding_position('character', {4, 0}, 64, 1) or {4, 0}
        player.teleport(pos, surface)
        gui.close_popup(player)
        return true
    end

    if string.sub(name, 1, 6) == 'pw_go_' then
        worlds.travel(player, string.sub(name, 7))
        gui.close_popup(player)
        return true
    end

    return false
end

return M
```

**注意匹配顺序**：`pw_go_public_N` 必须在 `pw_go_` 前缀判断**之前**匹配，
否则会被当成星球名 `public_N` 传给 `worlds.travel`。上面的顺序是对的。

- [ ] **Step 5: 创建 `scripts/gui/exp.lua`**

```lua
local geometry = require('scripts.geometry')
local exp = require('scripts.exp')
local ring = require('scripts.ring')
local util = require('scripts.util')

local M = {}

function M.show(player)
    local gui = require('scripts.gui.init')
    local inner = gui.open_popup(player, {'pw.exp-title'})
    local table_data = exp.get(player.name)

    inner.add{type = 'label', caption = {'pw.exp-help'}}

    local sum = 0
    for _, short in ipairs(geometry.SCIENCE_PACKS) do
        local amount = table_data[short] or 0
        local contribution = amount > 1 and math.log(amount, 10) or 0
        sum = sum + contribution
        inner.add{type = 'label', caption = {'pw.exp-row',
            '[item=' .. geometry.pack_item_name(short) .. ']',
            util.readable(amount),
            string.format('%.2f', contribution)}}
    end

    local level = ring.level_of(player.name)
    inner.add{type = 'label', caption = {'pw.exp-sum',
        string.format('%.2f', sum), level, ring.half_width_of(player.name) * 2}}
    inner.add{type = 'label', caption = {'pw.exp-next',
        string.format('%.2f', level + 1 - sum)}}
end

return M
```

- [ ] **Step 6: 创建 `scripts/gui/help.lua`**

```lua
local M = {}

function M.show(player)
    local gui = require('scripts.gui.init')
    local inner = gui.open_popup(player, {'pw.help-title'})
    local label = inner.add{type = 'label', caption = {'pw.help-body'}}
    label.style.single_line = false
    label.style.maximal_width = 560
end

return M
```

- [ ] **Step 7: 删旧 gui.lua，改 tick.lua 的 require**

```bash
rm scripts/gui.lua
```

`scripts/tick.lua` 顶部的 `local gui = require('scripts.gui')` 改成：

```lua
local gui = require('scripts.gui.init')
```

- [ ] **Step 8: 语法体检**

```bash
luac -p scripts/gui/*.lua scripts/tick.lua && echo "语法 OK"
```

- [ ] **Step 9: 游戏内验证**

进游戏后肉眼确认：

1. 左上角 HUD 有四个按钮，显示等级和环宽
2. 点【兑换经验】→ 弹窗列出背包里的科技瓶（先 `/c game.player.insert{name='automation-science-pack',count=50}`）
3. 点【传送】→ 列出「回戴森环」+ 五个星球（含倒计时和科技丢失预告）
4. 点【经验】→ 12 行，每行一个瓶子图标 + 经验 + log10 贡献 + 底部汇总
5. 点【玩法】→ 说明文本
6. 每个弹窗的【关闭】都能关掉，且同时只存在一个弹窗

---

## Task 10: locale 双语改写

**Files:**
- Modify: `locale/zh-CN/locale.cfg`
- Modify: `locale/en/locale.cfg`

- [ ] **Step 1: 收集所有用到的 key**

```bash
grep -rhno "'pw\.[a-z0-9-]*'" scripts/ control.lua | sed "s/.*'pw\.\([a-z0-9-]*\)'.*/\1/" | sort -u
```

把输出存成清单。下一步要保证 zh-CN 和 en 都**全覆盖**这个清单，一个不漏——
缺了的 key 在游戏里会显示成 `Unknown key: pw.xxx`。

- [ ] **Step 2: 重写 `locale/zh-CN/locale.cfg`**

`[pw]` 段按功能分组，每个带参数的 key 上面写注释说明 `__1__` `__2__` 是什么。
必须覆盖的 key（按 Task 1-9 里实际用到的）：

```
welcome, close, ring-rebuilt, ring-evacuated, ring-reclaimed, ring-public, ring-deleted
hud-ring, hud-stamina
btn-convert, btn-convert-tip, btn-travel, btn-travel-tip, btn-exp, btn-exp-tip, btn-help
convert-title, convert-row, convert-total, convert-have, convert-do,
convert-cannot, convert-done, convert-nothing, convert-no-stamina, convert-no-character
travel-title, travel-home, travel-worlds-head, travel-tech-warn, travel-world-row,
travel-go, travel-public-head, travel-public-row, travel-public-gone, world-not-ready
exp-title, exp-help, exp-row, exp-sum, exp-next
world-reset, tech-lost
cmd-ring-delete-help, cmd-ring-delete-usage, cmd-admin-only, cmd-no-player,
cmd-player-online, cmd-no-ring, cmd-ring-deleted, cmd-ring-deleted-broadcast
help-title, help-body
```

同时改文件顶部的 `scenario-name=` 和 `description=`：场景名改成「戴森环计划」，
个人世界统一叫「你的戴森环」，描述里写清四件事——环带靠 12 种科技瓶经验变宽、
关联箱做跨星球投递、公共世界会重置且科技会漏水、离线 30 小时环变公共 50 小时删除。

- [ ] **Step 3: 同步 `locale/en/locale.cfg`**

同一份 key 清单的英文版。`scenario-name=Dyson Ring Project`。

- [ ] **Step 4: 验证覆盖率**

```bash
comm -23 <(grep -rhno "'pw\.[a-z0-9-]*'" scripts/ control.lua | sed "s/.*'pw\.\([a-z0-9-]*\)'.*/\1/" | sort -u) \
         <(sed -n '/^\[pw\]/,$p' locale/zh-CN/locale.cfg | grep -o '^[a-z0-9-]*=' | tr -d '=' | sort -u)
```

预期：**无输出**（代码里用到的 key 全部有翻译）。en 同样跑一遍。

- [ ] **Step 5: 游戏内验证**

进游戏，把四个弹窗全点一遍，确认**没有任何一处显示 `Unknown key`**。
再 `/c game.player.locale = 'en'`（或改客户端语言）复查英文版。

---

## Task 11: PROJECT.md 更新

**Files:**
- Modify: `PROJECT.md`

- [ ] **Step 1: 重写第三条约束**

原文论证的是「用引擎硬边界，不需要自己铺虚空、也不需要事后 delete_chunk」。
改成混合方案的论证：**纵向仍用引擎硬边界（`height=128`，白拿，且是精确 4 个区块行），
横向改成无限 + 手工涂 out-of-map 的墙**。说明取舍：硬边界只能是矩形、且在已存在的 surface
上能不能改大是未验证的，戴森环那个形状和无缝扩容它都做不到。代价是存档体积不再由引擎兜底，
但涂出来的墙不可通行，玩家带不动引擎往外生成。

- [ ] **Step 2: 删掉第四条之外的过时内容，新增两条约束**

- **删**：禁蓝图库那条（理由已不成立——重置的是公共世界，产线在戴森环里）
- **加**：「12 种经验分开记账」——因为 `Σ log10(expᵢ) = log10(∏ expᵢ)`，缺一种整项为 0，逼玩家集齐
- **加**：「科技丢失概率挂瓶子种数」——形成自然的高度上限，不需要人为封顶

- [ ] **Step 3: 更新文件表**

按本计划的「文件结构」章节重写那张表。删 `values.lua` / `gui.lua` 行，
加 `geometry.lua` / `ring.lua` / `chests.lua` / `commands.lua` / `gui/` 六个文件。

- [ ] **Step 4: 更新 storage 字段表和数据流速览**

storage 表按 spec 第八章的「可配置参数总表」和「非配置的运行时状态」两张表重写。
数据流速览加三条：`on_chunk_generated → ring 涂砖`、
`兑换 → exp.convert → ring.apply_growth`、`tick → pockets.tick_lifecycle`。

- [ ] **Step 5: 更新开发约定**

加一条：「几何数学改动后跑 `lua5.4 tests/test_geometry.lua`」。

- [ ] **Step 6: 最终全量体检**

```bash
luac -p control.lua scripts/*.lua scripts/gui/*.lua && echo "全部语法 OK"
lua5.4 tests/test_geometry.lua
grep -rn "values\|level_of\|exp_to_next\|pocket_size\|convert_batch\|item_value\|pocket_keep_offline\|pocket_run\|quality_exp\b" scripts/ control.lua
```

预期：语法全过、单测全过、grep 只剩 `storage.quality_exp`（那是新字段，合法）。

---

## Task 12: 每星球独立重置周期 + 周期任务错开

用户在执行中追加的需求 R1/R2。原设计是五星球统一 120 分钟、按 `period × i / N` 错峰；
改成**每星球各有自己的周期**，首次排期再错开 10 分钟。

**Files:**
- Modify: `scripts/constants.lua`（新增两个配置项，删掉标量 `world_reset_minutes`）
- Modify: `scripts/worlds.lua`（`schedule_all` / `reset_world` 读新配置）
- Modify: `scripts/tick.lua`（周期任务模数再错开）

**Interfaces:**
- Consumes: `constants.PUBLIC_PLANETS`、`constants.min_to_tick`
- Produces: `worlds.period_of(planet_name)` → 该星球的重置周期（tick）

- [ ] **Step 1: `constants.ensure_defaults()` 换掉重置周期配置**

把 `storage.world_reset_minutes = storage.world_reset_minutes or 120` 这一行替换成：

```lua
    -- 每星球各自的重置周期（分钟）。周期长短即难度分层：
    -- nauvis 一小时一轮，是新人的练兵场；aquilo 五小时一轮，值得长线经营。
    storage.world_reset_minutes = storage.world_reset_minutes or {
        nauvis = 60, vulcanus = 120, fulgora = 180, gleba = 240, aquilo = 300,
    }
    -- 相邻星球的首次排期错开这么多分钟，避免两个世界同时重置。
    storage.world_reset_offset_minutes = storage.world_reset_offset_minutes or 10
```

**注意类型变了**（number → table）。加一段迁移，和 `migrate_exp` 同样的写法：

```lua
-- v2 早期版本里 world_reset_minutes 是个标量（统一周期）。改成 per-planet table 之后，
-- 老存档继承过来会是 number，直接当表索引会返回 nil，重置周期会退化成兜底值。
local function migrate_world_periods()
    if type(storage.world_reset_minutes) == 'number' then
        storage.world_reset_minutes = nil   -- 交给 ensure_defaults 重建成默认表
    end
end
```

在 `ensure_defaults` 里、设默认值**之前**调用它。

- [ ] **Step 2: `scripts/worlds.lua` 读新配置**

新增：

```lua
-- 某星球的重置周期（tick）。配置缺项时兜底成 120 分钟。
function M.period_of(planet_name)
    local table_or_nil = storage.world_reset_minutes
    local minutes = (type(table_or_nil) == 'table' and table_or_nil[planet_name]) or 120
    return minutes * constants.min_to_tick
end
```

`schedule_all` 整体替换成：

```lua
-- 错峰排期：每个星球用自己的周期，首次排期再按索引错开 offset 分钟。
--
-- 为什么这样就永不撞车：五个周期（60/120/180/240/300 分钟）都是 60 的整数倍，
-- 而偏移是 0/10/20/30/40 分钟，所以第 i 个星球的重置时刻恒定落在 mod 60 的第 (10i) 个余数上，
-- 各自不同、永远不会重合。不需要任何运行时的冲突检测。
function M.schedule_all(force_respread)
    storage.world_reset_at = storage.world_reset_at or {}
    local offset = (storage.world_reset_offset_minutes or 10) * constants.min_to_tick
    for i, name in ipairs(constants.PUBLIC_PLANETS) do
        if force_respread or not storage.world_reset_at[name] then
            storage.world_reset_at[name] = game.tick + M.period_of(name) + (i - 1) * offset
        end
    end
end
```

`reset_world` 里排下一轮那一行改成：

```lua
    storage.world_reset_at[planet_name] = game.tick + M.period_of(planet_name)
```

- [ ] **Step 3: `scripts/tick.lua` 把周期任务错开**

模数全部取**互质的质数**，让几件重活几乎不会落在同一 tick 上：

```lua
    if tick % 3607 == 0 then worlds.tick_check() end        -- 公共世界重置
    if tick % 3613 == 0 then pockets.tick_lifecycle() end   -- 戴森环 30h/50h
    if tick % 3617 == 0 then ships.tick_lifecycle() end     -- 飞船 50h（Task 13）
    if tick % 613 == 0 then                                 -- HUD 刷新
        for _, player in pairs(game.connected_players) do gui.refresh_hud(player) end
    end
```

（3607 / 3613 / 3617 / 613 都是质数，两两互质。这个技巧沿用 v1 的做法。）

- [ ] **Step 4: 语法体检**

```bash
luac -p scripts/constants.lua scripts/worlds.lua scripts/tick.lua && echo "语法 OK"
lua5.4 tests/test_geometry.lua
```

- [ ] **Step 5: 排期正确性验证（纯 Lua，不需要游戏）**

写一个临时脚本验证「永不撞车」这个论断，跑完删掉：

```lua
-- 模拟 30 天，检查有没有两个星球在同一分钟重置
local period = {nauvis=60, vulcanus=120, fulgora=180, gleba=240, aquilo=300}
local order = {'nauvis','vulcanus','gleba','fulgora','aquilo'}  -- 注意与 PUBLIC_PLANETS 同序
local fire = {}
for i, name in ipairs(order) do
    local t = period[name] + (i-1)*10
    while t < 60*24*30 do
        fire[t] = fire[t] or {}
        table.insert(fire[t], name)
        t = t + period[name]
    end
end
local collisions = 0
for t, names in pairs(fire) do
    if #names > 1 then collisions = collisions + 1 end
end
print('30 天内撞车次数（应为 0）:', collisions)
```

预期：`30 天内撞车次数（应为 0）: 0`

**注意 `PUBLIC_PLANETS` 的顺序是 `{nauvis, vulcanus, gleba, fulgora, aquilo}`，
而用户给的周期是 fulgora 3h / gleba 4h** —— 两者顺序不同。
配置表按**名字**索引，不要按下标，否则 gleba 和 fulgora 的周期会对调。

---

## Task 13: 飞船（太空平台）子系统

用户在执行中追加的需求 R3/R4/R5。

**Files:**
- Create: `scripts/ships.lua`
- Modify: `scripts/constants.lua`（配置项）
- Modify: `scripts/gui/travel.lua`（建船按钮 + 飞船列表）
- Modify: `scripts/tick.lua`（已在 Task 12 Step 3 接好）
- Modify: `control.lua`（require ships）

**Interfaces:**
- Consumes: `pockets.enter`（撤人用）、`constants.hour_to_tick`
- Produces:
  - `ships.of(player)` → `LuaSpacePlatform?`
  - `ships.create(player)` → `platform` 或 `nil, 错误key`
  - `ships.all()` → 数组 `{ {owner_name=, index=, age_hours=, left_hours=} ... }`
  - `ships.tick_lifecycle()` → 无返回

### 为什么必须用 UI 按钮建船，而不是让玩家走原版流程

查证结论（Task 13 的全部设计都建立在这上面）：

- `LuaForce.create_space_platform{name?, planet, starter_pack}` → `LuaSpacePlatform?`
- `LuaForce.platforms` :: `dictionary[uint32 → LuaSpacePlatform]`（含待删除的）
- `LuaSpacePlatform.name` **可写**；`.surface` 只读；`.destroy(ticks?)`「Schedules for deletion」
- **引擎没有「平台被创建」的事件，也没有创建时间戳**

没有创建事件意味着拿不到「谁造的」——平台是 force 级的，单 force 下引擎根本不记录归属。
于是「每人最多 1 艘」和「以玩家名命名」都无从执行。
**脚本自己造船**是唯一能同时拿到归属和创建时刻的路径。

- [ ] **Step 1: `constants.ensure_defaults()` 加配置**

```lua
    -- ══ 飞船（太空平台） ══
    storage.ships = storage.ships or {}                      -- [玩家名] = {index=平台index, created=创建tick}
    storage.ship_life_hours = storage.ship_life_hours or 50  -- 寿命，到点先撤人再摧毁
    storage.ship_width = storage.ship_width or 256           -- 引擎级硬边界，和戴森环同一个思路
    storage.ship_height = storage.ship_height or 512
    storage.ship_home_planet = storage.ship_home_planet or 'nauvis'   -- 默认环绕哪颗星球
    storage.ship_require_starter_pack = storage.ship_require_starter_pack ~= false
                                                             -- 默认 true：建船要消耗一个太空平台起步包
```

- [ ] **Step 2: 创建 `scripts/ships.lua`**

```lua
-- 飞船（太空平台）。全服公有、每人最多一艘、以玩家名命名、50 小时寿命。
--
-- 为什么由脚本造而不是让玩家走原版星图流程：
--   引擎【没有「平台被创建」的事件，也没有创建时间戳】。平台是 force 级的，
--   单 force 下引擎根本不记录「谁造的」。于是「每人最多 1 艘」和「以玩家名命名」都无从执行。
--   脚本自己造是唯一能同时拿到归属和创建时刻的路径。
--
-- 「全服公有」是单 force 的自然结果，不需要额外代码：平台属于 force，所有人本来就都能上去。
-- 以玩家名命名只是为了让人知道该找谁，不代表所有权。
local constants = require('scripts.constants')

local M = {}

local STARTER_PACK = 'space-platform-starter-pack'

-- 取某玩家名下的平台。记录还在但平台已消失（被引擎删了）时顺手清账。
function M.of(player)
    storage.ships = storage.ships or {}
    local record = storage.ships[player.name]
    if not record then return nil end
    local platform = player.force.platforms[record.index]
    if not (platform and platform.valid) then
        storage.ships[player.name] = nil
        return nil
    end
    return platform
end

-- 给飞船 surface 套上引擎级硬边界。和戴森环同一个思路：
-- 边界外是 out-of-map，引擎根本不生成区块，存档体积从根上受控。
-- 注意必须在区块生成之前设好，改 map_gen_settings 只影响【之后生成】的区块。
local function apply_bounds(platform)
    local surface = platform.surface
    if not (surface and surface.valid) then return end
    local mgs = surface.map_gen_settings
    mgs.width = storage.ship_width or 256
    mgs.height = storage.ship_height or 512
    surface.map_gen_settings = mgs
end

-- 造一艘。成功返回 platform，失败返回 nil 加一个本地化 key。
function M.create(player)
    if M.of(player) then return nil, 'pw.ship-already-have' end

    local inventory = player.get_main_inventory()
    local need_pack = storage.ship_require_starter_pack ~= false
    if need_pack then
        if not (inventory and inventory.get_item_count(STARTER_PACK) > 0) then
            return nil, 'pw.ship-no-pack'
        end
    end

    local planet = storage.ship_home_planet or 'nauvis'
    local platform = player.force.create_space_platform{
        name = player.name,
        planet = planet,
        starter_pack = STARTER_PACK,
    }
    if not platform then return nil, 'pw.ship-create-failed' end

    if need_pack then inventory.remove{name = STARTER_PACK, count = 1} end

    apply_bounds(platform)

    storage.ships = storage.ships or {}
    storage.ships[player.name] = {index = platform.index, created = game.tick}
    game.print({'pw.ship-created', player.name})
    return platform
end

-- 所有在册飞船，供 GUI 列出。顺手清掉已失效的记录。
function M.all()
    storage.ships = storage.ships or {}
    local life = (storage.ship_life_hours or 50) * constants.hour_to_tick
    local out = {}
    for name, record in pairs(storage.ships) do
        local player = game.players[name]
        local platform = player and M.of(player)
        if platform then
            local age = game.tick - (record.created or game.tick)
            out[#out + 1] = {
                owner_name = name,
                index = record.index,
                age_hours = math.floor(age / constants.hour_to_tick),
                left_hours = math.max(0, math.floor((life - age) / constants.hour_to_tick)),
            }
        end
    end
    return out
end

-- 周期任务：摧毁超龄的飞船。先撤人再炸，和戴森环 50 小时删除同一套规矩。
function M.tick_lifecycle()
    storage.ships = storage.ships or {}
    local life = (storage.ship_life_hours or 50) * constants.hour_to_tick

    for name, record in pairs(storage.ships) do
        if game.tick - (record.created or game.tick) >= life then
            local player = game.players[name]
            local platform = player and M.of(player)
            if platform then
                local pockets = require('scripts.pockets')
                local surface = platform.surface
                if surface and surface.valid then
                    for _, p in pairs(game.connected_players) do
                        if p.surface == surface then
                            p.print({'pw.ship-evacuated', name})
                            pockets.enter(p)
                        end
                    end
                end
                platform.destroy()
                game.print({'pw.ship-expired', name})
            end
            storage.ships[name] = nil
        end
    end
end

return M
```

- [ ] **Step 3: `scripts/gui/travel.lua` 加建船按钮和飞船列表**

在星球那一段之后、戴森环列表之前插入：

```lua
    -- 飞船：自己没有就显示建造按钮，有了就显示剩余寿命
    local ships = require('scripts.ships')
    inner.add{type = 'label', caption = {'pw.travel-ships-head', storage.ship_life_hours or 50}}
    if ships.of(player) then
        inner.add{type = 'label', caption = {'pw.ship-have'}}
    else
        inner.add{type = 'button', name = 'pw_ship_create', caption = {'pw.ship-create'},
                  tooltip = {'pw.ship-create-tip'}}
    end
    for _, entry in ipairs(ships.all()) do
        local row = inner.add{type = 'flow', direction = 'horizontal'}
        row.add{type = 'label', caption = {'pw.travel-ship-row',
            entry.owner_name, entry.age_hours, entry.left_hours}}
    end
```

`M.on_click` 里加：

```lua
    if name == 'pw_ship_create' then
        local ships = require('scripts.ships')
        local platform, err = ships.create(player)
        if not platform then player.print({err or 'pw.ship-create-failed'}) end
        gui.close_popup(player)
        return true
    end
```

- [ ] **Step 4: `control.lua` 加载 ships，`tick.lua` 接周期任务**

`control.lua` 加 `local ships = require('scripts.ships')`（或纯 require）；
`tick.lua` 的周期调度已在 Task 12 Step 3 写好，这里只需确认 `ships` 已 require。

- [ ] **Step 5: 语法体检**

```bash
luac -p scripts/ships.lua scripts/gui/travel.lua scripts/tick.lua control.lua && echo "语法 OK"
```

- [ ] **Step 6: 游戏内验证（推迟到场景可加载之后）**

```lua
/c local ships = require('scripts.ships')
local p = game.player
p.insert{name='space-platform-starter-pack', count=2}
local s1 = ships.create(p)
game.print('第一艘(应成功): ' .. tostring(s1 ~= nil))
game.print('平台名(应为玩家名): ' .. tostring(s1 and s1.name))
game.print('起步包应被扣掉1个，剩: ' .. p.get_main_inventory().get_item_count('space-platform-starter-pack'))
local s2, err = ships.create(p)
game.print('第二艘(应失败): ' .. tostring(s2) .. ' 错误=' .. tostring(err))
storage.ship_life_hours = 0
ships.tick_lifecycle()
game.print('寿命归零后(应为nil): ' .. tostring(ships.of(p)))
storage.ship_life_hours = 50
```

预期：第一艘成功、名字是玩家名、起步包扣 1、第二艘失败并返回 `pw.ship-already-have`、
寿命归零后被摧毁。

**未验证的风险**：`create_space_platform` 的 `starter_pack` 参数是
「建平台所需的起步包」，脚本调用时引擎会不会**自己**从某处扣除、
或者要求玩家先发射火箭——文档没写清楚。若脚本调用不消耗任何东西，
那我们手动 `inventory.remove` 就是唯一的成本来源；若引擎也扣一次，会变成扣两次。
**实测时务必核对起步包数量的变化。**

另外 `apply_bounds` 改 `map_gen_settings` 只影响之后生成的区块，
而平台创建时可能已经生成了起始区块——实测时确认边界是否真的生效。

---

## 附录：五项 API 验证的集中脚本

Task 3/4 的验证步骤里已经分散覆盖了这五项。若想在动工前一次跑完，
起一个空场景（普通新游戏即可），`/c` 粘贴：

```lua
/c
-- 1. empty-space 砖能不能设在普通 surface 上
local s = game.player.surface
local ok1 = pcall(function() s.set_tiles({{name='empty-space', position={200,200}}}, false, false) end)
game.print('1. empty-space 可设置: ' .. tostring(ok1) .. ' 实得砖=' .. s.get_tile(200,200).name)

-- 2. linked-chest 物品能不能插入和放置
local ok2 = pcall(function() game.player.insert{name='linked-chest', count=1} end)
game.print('2. linked-chest 物品可插入: ' .. tostring(ok2))
local c = s.create_entity{name='linked-chest', position={205,205}, force='player'}
game.print('   实体可创建: ' .. tostring(c ~= nil) .. ' link_id可写: ' ..
    tostring(pcall(function() c.link_id = 7 end)))

-- 3. override_pollution_type = {} 是否真的关掉污染
local test = game.create_surface('pollution_test', {width=0, height=128})
test.override_pollution_type = {}
game.print('3. 污染类型(应为nil): ' .. tostring(test.pollutant_type))

-- 4. width=0 height=128 的实际生成范围
test.request_to_generate_chunks({0,0}, 4)
test.force_generate_chunk_requests()
game.print('4. 区块(0,0)已生成(应true): ' .. tostring(test.is_chunk_generated({0,0})))
game.print('   区块(0,-3)已生成(应false): ' .. tostring(test.is_chunk_generated({0,-3})))
game.print('   区块(10,0)可生成(应true): ' .. tostring(test.is_chunk_generated({10,0})))

-- 5. 太空平台基座能否铺在普通 surface 的 empty-space 上
local ok5 = pcall(function() s.set_tiles({{name='space-platform-foundation', position={200,200}}}, false, false) end)
game.print('5. 基座可设置: ' .. tostring(ok5) .. ' 实得砖=' .. s.get_tile(200,200).name)
game.delete_surface(test)
```

各项的降级方案见 spec 第九章。

---

## 自检记录

**Spec 覆盖**：spec 十章逐节对照——
2.1 几何→Task 1+3｜2.2 宽度→Task 1｜2.3 涂砖扩容→Task 3｜2.4 箱阵→Task 4｜
2.5 生命周期→Task 6｜2.6 出生→Task 3｜2.7 纵向生长→Task 3 的验证项 5（玩家行为，无需代码）｜
2.8 关污染→Task 3｜三 关联箱→Task 4｜四 经验兑换→Task 2+5｜五 科技丢失→Task 7｜
六 UI→Task 9｜7.1 权限→Task 6 Step 2｜7.2 指令→Task 8｜八 文件/配置→Task 2｜
九 风险→附录｜十 沿用不变→无需改动。**无缺口**。

**类型一致性**：`geometry.ring_level(exp_table)` 吃的是 12 键 table，
`constants.ensure_exp_table` 产出的正是这个形状，`exp.get` 转发它，`ring.level_of` 消费它——链路一致。
`chests.expected_link_id` 和 `pockets.tick_lifecycle` 都用 `storage.ring_state[玩家名]` 作真相源，键类型一致（玩家名字符串）。
`ring.surface_name_for(player_index)` 吃 index，`ring.owner_name_of(surface)` 吐玩家名，两者是互逆的一对。
