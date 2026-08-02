-- 玩家进度（12 项经验 + 体力）的导出与导入。
--
-- 【为什么导出容易、导入要绕一圈】：引擎只提供写文件（helpers.write_file 写进
-- script-output 目录），【没有任何运行时读文件的 API】。scenario 能读到磁盘上的东西
-- 只有一条路：在脚本加载阶段 require 一个 lua 文件。require 只能在加载阶段调用，
-- 事件处理函数里调会直接报错，所以本模块在【顶层】pcall 一次 require，
-- 把结果存成模块级变量，指令再去用它。
--
-- 于是导入的完整流程是：
--   ① 把导出的 exp_import.lua 复制进 scenario 目录（和 control.lua 同级）
--   ② /c game.reload_script()      ← 这一步才是真正把文件读进来的时刻
--   ③ /pw-import                   ← 预览
--   ④ /pw-import confirm           ← 落盘
--
-- 【为什么导出的是 JSON 字符串而不是 lua 表】：只需要一套序列化（helpers.table_to_json），
-- 而且玩家名里的引号、反斜杠、中文全部由引擎处理，不用自己写转义。
-- exp_import.lua 只是把那串 JSON 用长括号包了一层，内容和 .json 文件逐字节相同。
local geometry = require('scripts.geometry')
local constants = require('scripts.constants')
local stamina = require('scripts.stamina')

local M = {}

M.FORMAT = 'pw-progress'
M.VERSION = 1

-- 导入文件的固定文件名。导出时就直接生成这个名字，管理员复制过来即可，不用改名 ——
-- 少一步「改名」就少一类「改错了名字然后以为功能坏了」的报错。
M.IMPORT_MODULE = 'exp_import'

-- 【顶层 require，只在脚本加载时跑一次】。文件不存在是最常见的情况（绝大多数时候
-- 服务器根本没打算导入），所以失败必须是安静的、绝不能影响场景启动。
local loaded = nil
do
    local ok, result = pcall(require, M.IMPORT_MODULE)
    if ok then loaded = result end
end

-- 把 require 到的东西归一成 table。导出文件返回的是 JSON 字符串（见文件头的说明），
-- 但手工写的导入文件直接 return 一个 lua 表也是合理的，两种都收。
local function as_table(value)
    if type(value) == 'table' then return value end
    if type(value) == 'string' then
        local ok, parsed = pcall(helpers.json_to_table, value)
        if ok and type(parsed) == 'table' then return parsed end
    end
    return nil
end

-------------------------------------------------------------------------------
-- 导出
-------------------------------------------------------------------------------

-- 体力导出成【点数】，不导 tick。
--
-- 两个理由，每个都足以单独决定这件事：
--   ① storage.stamina.pending 的单位是 tick，换算成点要除以 stamina_ticks_per_point，
--      而那是个可调参数。原样搬 tick 到另一台参数不同的服务器上，同一个数字会变成
--      完全不同的体力量。点数是和配置无关的量，搬到哪儿都是同样多。
--   ② rec.last 是【本存档时间轴上的 tick】，跨存档毫无意义：导进一个 tick 更小的存档
--      会算出负的 elapsed，导进更大的则会瞬间把可领取池灌满。所以干脆不导出它，
--      导入时一律重置为当前 tick。
-- 代价是丢掉不足一点的余数（最多不到 1 点），可以忽略。
local function export_stamina(player_name)
    return {
        claimable = stamina.claimable(player_name),
        balance = stamina.balance(player_name),
    }
end

-- 采集当前全部玩家进度。返回 {data, count}。
--
-- 【按玩家名遍历 storage.exp，而不是遍历 game.players】：storage 一律按玩家名索引，
-- 而且很可能存着已经不在 game.players 里的名字（换服、删档重来、改名之前的旧记录）。
-- 导出的意义正是保住这些数据，按在线玩家遍历会把它们默默丢掉。
function M.collect()
    storage.exp = storage.exp or {}
    local players, count = {}, 0
    for name, exp in pairs(storage.exp) do
        if type(exp) == 'table' then
            local out = {}
            for _, key in ipairs(geometry.SCIENCE_PACKS) do
                out[key] = exp[key] or 0
            end
            players[name] = {exp = out, stamina = export_stamina(name)}
            count = count + 1
        end
    end
    return {
        format = M.FORMAT,
        version = M.VERSION,
        tick = game.tick,
        players = players,
    }, count
end

-- 写文件。返回 {count, json_name, lua_name}，没有任何数据可导时返回 nil。
--
-- for_player 的取值：有调用者就写到【他自己那台机器】的 script-output
-- （管理员在客户端敲指令，文件出现在自己电脑上，这正是"导出到本地"的本意）；
-- 从服务器控制台执行则传 0，只写服务器那份。引擎文档写明 0 的含义是
-- "only write to the server's output if present"。
function M.write(for_player)
    local data, count = M.collect()
    if count == 0 then return nil end

    local json = helpers.table_to_json(data)
    local json_name = string.format('%s-%d.json', M.FORMAT, game.tick)
    local lua_name = M.IMPORT_MODULE .. '.lua'

    helpers.write_file(json_name, json, false, for_player)
    -- 长括号里的内容【不做任何转义】，所以 JSON 里的引号和反斜杠原样写入即可。
    -- 用 [===[ 这一级是为了不和 JSON 内容里可能出现的 ]] / ]=] 撞车 ——
    -- 玩家名要正好包含 ]===] 才会出问题，那已经不是现实中会发生的事。
    helpers.write_file(lua_name, 'return [===[\n' .. json .. '\n]===]\n', false, for_player)

    return {count = count, json_name = json_name, lua_name = lua_name}
end

-------------------------------------------------------------------------------
-- 导入
-------------------------------------------------------------------------------

-- 一个数值字段能不能收。
--
-- 三层判断缺一不可：类型必须是数字；NaN 要单独挡（NaN ~= NaN 是唯一可靠的判据，
-- 它能通过 >= 0 之外的所有比较）；负数直接拒绝，经验和体力都没有负值的语义。
-- 脏数据宁可整条跳过也不能写进 storage —— 一个 NaN 经验会让 ring_level 算出 NaN，
-- 进而让半长变成 NaN，涂砖时才炸，而那时已经完全看不出根因在导入这一步。
local function clean_number(value)
    if type(value) ~= 'number' then return nil end
    if value ~= value then return nil end            -- NaN
    if value < 0 then return nil end
    if value == math.huge then return nil end
    return math.floor(value)
end

-- 校验并归一化一份导入数据。返回 {entries, bad_fields}，格式不认识则返回 nil。
--   entries    = { {name=, exp={12 键}, claimable=, balance=}, ... }
--   bad_fields = 被丢弃的字段数（类型不对、负数、不认识的键）
--
-- 【只认识 12 个经验键，其余一律丢弃并计数】。静默忽略是最糟的选择：
-- 导入文件里一个拼错的键（automations）会让那项经验悄悄归零，
-- 而管理员看到"导入成功"就不会再去查。所以数出来，报给他看。
function M.validate(raw)
    local data = as_table(raw)
    if not data then return nil end
    if data.format ~= M.FORMAT then return nil end
    if type(data.players) ~= 'table' then return nil end

    local entries, bad = {}, 0
    for name, rec in pairs(data.players) do
        if type(name) == 'string' and name ~= '' and type(rec) == 'table' then
            local exp = {}
            local src = type(rec.exp) == 'table' and rec.exp or {}
            for _, key in ipairs(geometry.SCIENCE_PACKS) do
                exp[key] = clean_number(src[key]) or 0
            end
            -- 数一数源数据里有多少个我们不认识、或者值不合法的键
            for key, value in pairs(src) do
                if exp[key] == nil or clean_number(value) == nil then bad = bad + 1 end
            end

            local st = type(rec.stamina) == 'table' and rec.stamina or {}
            entries[#entries + 1] = {
                name = name,
                exp = exp,
                claimable = clean_number(st.claimable) or 0,
                balance = clean_number(st.balance) or 0,
            }
        else
            bad = bad + 1
        end
    end
    return {entries = entries, bad_fields = bad}
end

-- require 进来的那份数据，已校验。没有文件 / 格式不对时返回 nil。
function M.pending()
    if loaded == nil then return nil end
    return M.validate(loaded)
end

-- 这份数据里有几个名字是当前存档认识的玩家。预览用 ——
-- 认不出来【不是错误】（导入常常发生在玩家进服之前，storage 按名字索引，
-- 人来了自然对上号），但和"一个都对不上"区分开能让管理员早一步发现自己拿错了文件。
function M.known_count(result)
    local n = 0
    for _, entry in ipairs(result.entries) do
        if game.players[entry.name] then n = n + 1 end
    end
    return n
end

-- 落盘。返回实际写入的玩家数。
--
-- 【覆盖，不合并】：导入的语义是"把进度恢复成这份快照"，取 max 或相加都会让
-- 同一个文件导两次得到不同结果，那种指令没法用来做迁移和回滚。
-- 文件里没提到的玩家一个字段都不动 —— 那不是"清零"，只是这份快照不涉及他们。
function M.apply(result)
    storage.exp = storage.exp or {}
    storage.stamina = storage.stamina or {}
    local per = math.max(1, storage.stamina_ticks_per_point or 60)

    for _, entry in ipairs(result.entries) do
        -- 先 ensure 一遍，保证 12 个键齐全（万一将来加了第 13 种瓶子，
        -- 老快照导进来也不会缺键，缺的那项从 0 开始）。
        local exp = constants.ensure_exp_table(entry.name)
        for _, key in ipairs(geometry.SCIENCE_PACKS) do
            exp[key] = entry.exp[key] or 0
        end

        -- last 一律取当前 tick，绝不用文件里的值：它是另一条时间轴上的坐标，
        -- 搬过来要么算出负的流逝时间，要么瞬间把可领取池灌满。理由详见 export_stamina。
        storage.stamina[entry.name] = {
            last = game.tick,
            pending = entry.claimable * per,
            balance = entry.balance,
        }
    end
    return #result.entries
end

return M
