-- 物品价值表：把每个物品折算成【原矿当量】，作为兑换经验的基数。
--
-- 口径：可开采的原矿 = 1，其余物品 = 递归展开其配方的原料成本 ÷ 产出数量。
-- 这是 endfield_factorio 的 gen_item_values.py 的运行时版本。那边是 Python 离线扫数据生成 Lua 表，
-- 这里必须在运行时算，因为 scenario 没有 data 阶段、也不能带生成好的产物文件进存档。
--
-- 性能：只在首次需要时算一次，结果缓存进 storage.item_value，之后都是查表。
-- 配方数量在千级、递归有 visiting 环检测和深度上限，一次几十毫秒，可以接受。
local M = {}

local MAX_DEPTH = 24        -- 递归深度上限，防配方成环导致栈溢出
local DEFAULT_VALUE = 1     -- 算不出来的物品兜底价值

-- 选一个配方作为某物品的"主要来源"：产出该物品、且产出数量最多的那个。
-- 这样回收类配方（把成品拆成废料）不会被误当成成品的来源。
local function main_recipe_for(item_name, recipe_index)
    return recipe_index[item_name]
end

-- 建立 物品名 → 配方原型 的索引。每个物品只留一个"最划算"的配方。
local function build_recipe_index()
    local index = {}
    local best_ratio = {}
    for _, recipe in pairs(prototypes.recipe) do
        -- 跳过回收类配方：它们把成品拆回原料，拿来估值会把成品算得极便宜。
        if recipe.category ~= 'recycling' then
            for _, product in pairs(recipe.products or {}) do
                if product.type == 'item' then
                    local amount = product.amount or ((product.amount_min or 0) + (product.amount_max or 0)) / 2
                    if amount and amount > 0 then
                        local ingredient_count = 0
                        for _, ing in pairs(recipe.ingredients or {}) do
                            ingredient_count = ingredient_count + (ing.amount or 1)
                        end
                        -- ratio 越小代表"用更少原料造出更多成品"，取最划算的那个配方作为主来源
                        local ratio = ingredient_count / amount
                        if best_ratio[product.name] == nil or ratio < best_ratio[product.name] then
                            best_ratio[product.name] = ratio
                            index[product.name] = recipe
                        end
                    end
                end
            end
        end
    end
    return index
end

-- 递归求单个物品的价值。visiting 记录当前递归链上的物品，命中即判为环、直接兜底返回。
local function value_of(item_name, index, cache, visiting, depth)
    local cached = cache[item_name]
    if cached then return cached end
    if depth > MAX_DEPTH or visiting[item_name] then return DEFAULT_VALUE end

    local recipe = main_recipe_for(item_name, index)
    if not recipe then
        -- 没有配方 = 原矿或者只能从地里挖 / 从天上掉的东西，价值定为 1
        cache[item_name] = DEFAULT_VALUE
        return DEFAULT_VALUE
    end

    visiting[item_name] = true
    local total = 0
    for _, ing in pairs(recipe.ingredients or {}) do
        local unit
        if ing.type == 'fluid' then
            -- 流体按 1/10 计价：一份流体通常比一份固体便宜得多，不这样算会让化工链虚高
            unit = 0.1
        else
            unit = value_of(ing.name, index, cache, visiting, depth + 1)
        end
        total = total + unit * (ing.amount or 1)
    end
    visiting[item_name] = nil

    -- 除以本配方产出该物品的数量，得到单个成品的成本
    local out_amount = 1
    for _, product in pairs(recipe.products or {}) do
        if product.type == 'item' and product.name == item_name then
            out_amount = product.amount or ((product.amount_min or 0) + (product.amount_max or 0)) / 2 or 1
            break
        end
    end
    if out_amount <= 0 then out_amount = 1 end

    local result = total / out_amount
    if result <= 0 then result = DEFAULT_VALUE end
    cache[item_name] = result
    return result
end

-- 建全表并写进 storage。只在 storage.item_value 为空时执行。
function M.ensure()
    if storage.item_value then return storage.item_value end
    local index = build_recipe_index()
    local cache = {}
    for name in pairs(prototypes.item) do
        value_of(name, index, cache, {}, 0)
    end
    storage.item_value = cache
    log('[pw] 物品价值表已生成，共 ' .. tostring(table_size(cache)) .. ' 项')
    return cache
end

-- 查单个物品的价值。表没建就先建。
function M.of(item_name)
    local tbl = M.ensure()
    return tbl[item_name] or DEFAULT_VALUE
end

-- 管理员重算：物品价值表跟着游戏版本/mod 变，升级后可以 /c storage.item_value = nil 再触发重建。
function M.rebuild()
    storage.item_value = nil
    return M.ensure()
end

return M
