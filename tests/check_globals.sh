#!/usr/bin/env bash
# 查「读写了一个谁也没定义过的全局变量」。
#
# 起因是一次真实的近失：重构时删掉了一段代码的【声明】却留下了【使用】，
# 于是 `wanted` 和 `pos_key` 变成了未定义的全局。luac -p 完全不报错
# （读一个不存在的全局在 Lua 里是合法的，值是 nil），要等进游戏跑到那一行
# 才会 "attempt to index a nil value"，而那一行藏在建环流程里，
# 触发条件是"进环"，很可能上线之后才被踩到。
#
# 原理：luac -l 把全局访问编译成 GETTABUP/SETTABUP _ENV "名字"，
# 直接从字节码清单里把这些名字捞出来，和白名单比对。
# 比正则扫源码可靠得多——不会被注释、字符串、局部变量同名之类的东西干扰。
#
# 白名单 = Lua 标准库 + Factorio 场景脚本能拿到的全局。
# 本项目所有模块都写成 `local M = {} ... return M`，不往 _ENV 里写任何东西，
# 所以【任何 SETTABUP 都是可疑的】，写入一律报错。
set -uo pipefail
cd "$(dirname "$0")/.."

ALLOWED='^(assert|collectgarbage|error|getmetatable|ipairs|next|pairs|pcall|print|rawequal|rawget|rawlen|rawset|require|select|setmetatable|tonumber|tostring|type|unpack|xpcall|_G|_ENV|string|table|math|os|io|debug|coroutine|package|bit32|serpent|game|storage|script|defines|prototypes|commands|remote|rendering|settings|helpers|log|localised_print|table_size)$'

fail=0
for f in control.lua scripts/*.lua scripts/gui/*.lua tests/*.lua; do
    [ -f "$f" ] || continue

    # 读取的全局
    while read -r name; do
        [ -z "$name" ] && continue
        if ! [[ "$name" =~ $ALLOWED ]]; then
            echo "  $f  读了未知全局: $name"
            fail=1
        fi
    done < <(luac -l -p "$f" 2>/dev/null | grep -oP 'GETTABUP.*_ENV "\K[A-Za-z_][A-Za-z0-9_]*' | sort -u)

    # 写入的全局：本项目一个都不该有
    while read -r name; do
        [ -z "$name" ] && continue
        echo "  $f  写了全局: $name（模块应只用 local + return M）"
        fail=1
    done < <(luac -l -p "$f" 2>/dev/null | grep -oP 'SETTABUP.*_ENV "\K[A-Za-z_][A-Za-z0-9_]*' | sort -u)
done

if [ "$fail" -eq 0 ]; then
    echo "✓ 未发现未定义全局，也没有全局写入"
else
    echo "发现问题，见上。"
fi
exit "$fail"
