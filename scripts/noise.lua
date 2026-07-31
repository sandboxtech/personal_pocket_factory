-- 2D simplex 噪声 + 分形多倍频。取自 endfield_factorio 的 scripts/noise.lua（同一开发者的姊妹场景），
-- 精简到本场景实际用得上的部分：只做「公共世界每轮重置后地貌不同」，不做矿脉/市场/战利品那套。
--
-- 从 endfield 搬过来的东西（按重要性）：
--   1. M.fractal          多层不同频率叠加 → 自然不规则的团块，不是网格状的死板图案。
--   2. M.seeded_transform + M.fractal_warped
--      —— 这是精髓：由种子确定性地派生「旋转角 / 拉伸比 / 缩放」三个参数，
--      同一套噪声函数套上不同坐标变换就长出完全不同的斑块形状/朝向/大小，且完全可复现
--      （同一 seed 永远长出同一张图，回滚重放、多人同步都不会长歪）。
--   3. M.chunk_sampler    低频噪声按稀疏网格采样 + 双线性插值，把「区块内逐格取值」的成本
--      从上千次 fractal 降到约 100 次——公共世界的区块又多又大，这是能不能用得起噪声的前提。
--
-- 砍掉的东西：
--   endfield 那份用一整张倍频模板表(scrap/smooth/coast/coast_detail...)伺候废料矿/海岸线/市场选址，
--   本场景只做地块斑块 + 装饰物疏密两件事，用不上那么多模板，只保留 blob（斑块）和 fine（疏密）。
--   也没有搬 endfield 里那些依赖 storage.run 全局气质旋钮(knobs)、跨星异物(EXOTIC)、
--   战利品池(DEFAULT_LOOT)的调用方代码——那些是 map_features.lua 的事，本场景不需要。
--
-- simplex 算法本体（d2）：Stefan Gustavson 的公有领域实现，整段照搬，未改动。
--
-- 【重要】本模块用 bit32.band 而不是 5.3+ 的 `&` 运算符：Factorio 场景脚本跑在 Lua 5.2 环境里，
-- 5.2 没有原生位运算符，只有 bit32 库；本机 luac/lua5.4 是 5.4（没有 bit32），
-- 这只影响"能不能在本机沙盒直接跑起来验证"，不代表该写 `&`——线上环境是 5.2，写 `&` 会直接语法错误。
-- 本模块不含任何函数体内 require（顶层也没有 require，纯自洽），符合 Factorio 场景脚本的硬性要求。

local bit32_band = bit32.band
local math_floor = math.floor
local math_sqrt = math.sqrt

local grad3 = {
    {1, 1, 0}, {-1, 1, 0}, {1, -1, 0}, {-1, -1, 0},
    {1, 0, 1}, {-1, 0, 1}, {1, 0, -1}, {-1, 0, -1},
    {0, 1, 1}, {0, -1, 1}, {0, 1, -1}, {0, -1, -1},
}

local p = {
    151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225, 140, 36, 103, 30, 69, 142,
    8, 99, 37, 240, 21, 10, 23, 190, 6, 148, 247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117,
    35, 11, 32, 57, 177, 33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68, 175, 74, 165, 71,
    134, 139, 48, 27, 166, 77, 146, 158, 231, 83, 111, 229, 122, 60, 211, 133, 230, 220, 105, 92, 41,
    55, 46, 245, 40, 244, 102, 143, 54, 65, 25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89, 18,
    169, 200, 196, 135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186, 3, 64, 52, 217, 226, 250,
    124, 123, 5, 202, 38, 147, 118, 126, 255, 82, 85, 212, 207, 206, 59, 227, 47, 16, 58, 17, 182, 189,
    28, 42, 223, 183, 170, 213, 119, 248, 152, 2, 44, 154, 163, 70, 221, 153, 101, 155, 167, 43, 172, 9,
    129, 22, 39, 253, 19, 98, 108, 110, 79, 113, 224, 232, 178, 185, 112, 104, 218, 246, 97, 228, 251,
    34, 242, 193, 238, 210, 144, 12, 191, 179, 162, 241, 81, 51, 145, 235, 249, 14, 239, 107, 49, 192,
    214, 31, 181, 199, 106, 157, 184, 84, 204, 176, 115, 121, 50, 45, 127, 4, 150, 254, 138, 236, 205,
    93, 222, 114, 67, 29, 24, 72, 243, 141, 128, 195, 78, 66, 215, 61, 156, 180,
}
local perm = {}
for i = 0, 511 do perm[i + 1] = p[bit32_band(i, 255) + 1] end

local F2 = 0.5 * (math_sqrt(3.0) - 1.0)
local G2 = (3.0 - math_sqrt(3.0)) / 6.0

-- 2D simplex，返回约 [-1,1]
local function d2(xin, yin, seed)
    xin = xin + seed
    yin = yin + seed
    local n0, n1, n2
    local s = (xin + yin) * F2
    local i = math_floor(xin + s)
    local j = math_floor(yin + s)
    local t = (i + j) * G2
    local X0 = i - t
    local Y0 = j - t
    local x0 = xin - X0
    local y0 = yin - Y0
    local i1, j1
    if x0 > y0 then i1, j1 = 1, 0 else i1, j1 = 0, 1 end
    local x1 = x0 - i1 + G2
    local y1 = y0 - j1 + G2
    local x2 = x0 - 1 + 2 * G2
    local y2 = y0 - 1 + 2 * G2
    local ii = bit32_band(i, 255)
    local jj = bit32_band(j, 255)
    local gi0 = perm[ii + perm[jj + 1] + 1] % 12
    local gi1 = perm[ii + i1 + perm[jj + j1 + 1] + 1] % 12
    local gi2 = perm[ii + 1 + perm[jj + 1 + 1] + 1] % 12
    local t0 = 0.5 - x0 * x0 - y0 * y0
    if t0 < 0 then n0 = 0.0 else t0 = t0 * t0 n0 = t0 * t0 * (x0 * grad3[gi0 + 1][1] + y0 * grad3[gi0 + 1][2]) end
    local t1 = 0.5 - x1 * x1 - y1 * y1
    if t1 < 0 then n1 = 0.0 else t1 = t1 * t1 n1 = t1 * t1 * (x1 * grad3[gi1 + 1][1] + y1 * grad3[gi1 + 1][2]) end
    local t2 = 0.5 - x2 * x2 - y2 * y2
    if t2 < 0 then n2 = 0.0 else t2 = t2 * t2 n2 = t2 * t2 * (x2 * grad3[gi2 + 1][1] + y2 * grad3[gi2 + 1][2]) end
    return 70.0 * (n0 + n1 + n2)
end

local M = {}
M.d2 = d2

-- 倍频模板（modifier=频率，越小团块越大；weight=权重）。只留本场景用得上的两组：
--   blob 通用中等团块——地块斑块替换用它，斑块大小适中、边界自然不规则。
--   fine 细密——装饰物/树木疏密判定用它，波长短，稀疏带碎一些，不会整块一起消失。
M.octaves = {
    blob = {
        {modifier = 0.01, weight = 1}, {modifier = 0.04, weight = 0.4}, {modifier = 0.1, weight = 0.15},
    },
    fine = {
        {modifier = 0.05, weight = 1}, {modifier = 0.15, weight = 0.3},
    },
}

-- 分形噪声：多层 simplex 叠加，返回约 [-1,1]。
function M.fractal(octaves, x, y, seed)
    local noise, total = 0, 0
    for i = 1, #octaves do
        noise = noise + d2(x * octaves[i].modifier, y * octaves[i].modifier, seed) * octaves[i].weight
        total = total + octaves[i].weight
        seed = seed + 10000
    end
    return noise / total
end

-- 由种子确定性派生一组"本轮专属"的噪声变换参数（同一 seed 永远得到同一组）：
--   angle   随机旋转方向
--   stretch 各向异性拉伸：1=圆团，越大越拉成长条
--   zoom    整体特征大小：越大斑块越大
-- → 每轮公共世界重置后，地块斑块的形状/方向/大小都不一样，但同一轮内所有区块用同一组参数，
--   不会出现"隔壁区块画风突变"的接缝感。
local function hash01(n)   -- 经典 sin 哈希，返回 [0,1)
    local x = math.sin(n) * 43758.5453
    return x - math.floor(x)
end
M.hash01 = hash01

function M.seeded_transform(seed)
    local angle = hash01(seed * 1.7) * math.pi * 2
    local stretch = 1                                 -- 默认圆团
    if hash01(seed * 2.9) > 0.85 then                 -- 仅 ~15% 轮次拉成长条（不是每轮都长条）
        stretch = 1.6 + hash01(seed * 5.5) * 2.4      -- 1.6~4
    end
    local zoom = 0.7 + hash01(seed * 4.3) * 0.7       -- 0.7~1.4：整体特征大小
    return angle, stretch, zoom
end

-- 先按变换(旋转+拉伸+缩放)处理坐标，再喂给 fractal → 方向/长宽/大小随本轮种子而变的噪声场。
function M.fractal_warped(octaves, x, y, seed, angle, stretch, zoom)
    local c, s = math.cos(angle), math.sin(angle)
    local rx = (x * c - y * s) / (stretch * zoom)     -- 旋转后沿一轴拉伸 → 长条
    local ry = (x * s + y * c) / zoom
    return M.fractal(octaves, rx, ry, seed)
end

-- 区块降采样器：低频噪声按 step(默认4) 网格采样，返回 (px,py)→双线性插值 的取值闭包。
-- 用于"区块内大量逐点取同一张低频噪声"的场合（本场景：地块斑块替换/装饰物疏密判定）：
-- 固定约 100 次 fractal（10×10 网格）换无限次取值，这是公共世界能用得起噪声的关键。
-- 注意：高频细节被插值抹平，只适合波长 ≥ 4×step 的倍频组（本模块的 blob/fine 均满足）。
--
-- angle/stretch/zoom 可选（缺省 = 恒等变换，退化为不warp的普通 fractal 采样）——
-- 传本轮 M.seeded_transform 的返回值，就能让降采样网格本身也按本轮种子扭曲，
-- 这样"斑块形状每轮不同"这条不会在性能优化这一步被悄悄丢掉。
function M.chunk_sampler(octaves, lt, seed, angle, stretch, zoom, step)
    angle = angle or 0
    stretch = stretch or 1
    zoom = zoom or 1
    step = step or 4
    local x0, y0 = lt.x - 1, lt.y - 1
    local ng = math.ceil(34 / step)   -- 网格 0..ng，覆盖区块 ±1 圈
    local grid = {}
    for gy = 0, ng do
        local row = {}
        for gx = 0, ng do
            row[gx] = M.fractal_warped(octaves, x0 + gx * step, y0 + gy * step, seed, angle, stretch, zoom)
        end
        grid[gy] = row
    end
    local inv = 1 / step
    return function(px, py)
        local fx, fy = (px - x0) * inv, (py - y0) * inv
        local ix, iy = math.floor(fx), math.floor(fy)
        if ix < 0 then ix = 0 elseif ix >= ng then ix = ng - 1 end
        if iy < 0 then iy = 0 elseif iy >= ng then iy = ng - 1 end
        local tx, ty = fx - ix, fy - iy
        local r0, r1 = grid[iy], grid[iy + 1]
        return (r0[ix] * (1 - tx) + r0[ix + 1] * tx) * (1 - ty)
             + (r1[ix] * (1 - tx) + r1[ix + 1] * tx) * ty
    end
end

return M
