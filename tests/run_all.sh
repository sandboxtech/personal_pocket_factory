#!/usr/bin/env bash
# 一条命令跑完所有静态检查。改完任何 .lua 或 locale 都该跑一次。
#
# 五道检查各自堵的是【别的检查看不见】的一类问题：
#   luac -p          语法。本机是 5.4，Factorio 是 5.2，5.3+ 的语法这里会通过、进游戏才炸，
#                    所以另有 check_lua52 专门扫那些运算符和库函数。
#   check_globals    读写了未定义的全局。luac -p 不管这个（读不存在的全局在 Lua 里合法，值是 nil），
#                    要等运行到那一行才 "attempt to index a nil value"。
#   check_api_args   引擎调用的位置参数写反。签名以 runtime-api.json 为准。
#   test_geometry    环等级/半长/砖块语义的纯函数单测。
#   test_expio       导入数据的校验：脏数据（NaN/负数/拼错的键）必须在写进 storage 之前被挡住。
#   check_locale     两语言键集、占位符、缺键死键、以及每个调用点的实参个数。
set -uo pipefail
cd "$(dirname "$0")/.."

fail=0
step() {
    echo "── $1"
    shift
    if ! "$@"; then fail=1; fi
}

echo "── 语法（luac -p）"
for f in control.lua scripts/*.lua scripts/gui/*.lua; do
    luac -p "$f" || fail=1
done
echo "✓ 语法检查通过"

# Lua 5.3+ 专属语法/库函数：本机 luac 是 5.4，这些写法能过语法检查，
# 但 Factorio 跑在 5.2 上会直接加载失败。只扫代码，不扫注释。
echo "── Lua 5.2 兼容性"
bad=0
for f in control.lua scripts/*.lua scripts/gui/*.lua; do
    stripped=$(sed 's/--.*$//' "$f")
    if echo "$stripped" | grep -nE '(math\.type|table\.move|string\.pack|string\.unpack)|<<|>>|//|[^=~<>]~[^=]' >/dev/null; then
        echo "  $f 可能含 Lua 5.3+ 写法："
        echo "$stripped" | grep -nE '(math\.type|table\.move|string\.pack|string\.unpack)|<<|>>|//|[^=~<>]~[^=]' | head -3
        bad=1
    fi
done
[ "$bad" -eq 0 ] && echo "✓ 未发现 5.3+ 专属写法" || fail=1

step "未定义全局" bash tests/check_globals.sh
step "引擎 API 位置参数" python3 tests/check_api_args.py
step "几何单元测试" lua5.4 tests/test_geometry.lua
step "导入校验单元测试" lua5.4 tests/test_expio.lua
step "locale 一致性" python3 tests/check_locale.py

echo
if [ "$fail" -eq 0 ]; then
    echo "全部通过。"
else
    echo "有检查未通过，见上。"
fi
exit "$fail"
