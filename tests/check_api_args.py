#!/usr/bin/env python3
"""把 Lua 源码里的引擎 API 调用和 Factorio 的 runtime-api.json 对一遍位置参数。

起因是一个真实事故：LuaForce.set_surface_hidden 的签名是 (surface, hidden)，
代码写成了 set_surface_hidden(true, surface)。luac -p 查不出来（语法完全合法），
单元测试也覆盖不到（那是引擎调用），进游戏才抛 InvalidSurfaceIdentification，
而这行当时排在建箱阵之前，被事件总线的 pcall 吞掉后表现为「戴森环里的箱子凭空消失」——
从表象完全联想不到根因。

本脚本专查这一类【位置写反】的错误，判据是保守的、不误报的两条：
  1. 参数个数超过该方法的上限，或少于必填参数个数；
  2. 布尔字面量 true/false 出现在一个类型不是 boolean 的位置上。
第 2 条正是上面那个 bug 的形状：布尔字面量落在 SurfaceIdentification 的位置。

不做完整类型推导——那需要真正的 Lua 语义分析，收益不抵复杂度。
方法名在多个类里重名且签名冲突时跳过（无法确定被调对象的类），宁可漏报不误报。

用法：python3 tests/check_api_args.py [runtime-api.json 路径]
退出码 0 = 没有问题，1 = 发现可疑调用。
"""
import json
import os
import re
import sys

DEFAULT_API = ("/mnt/c/Program Files (x86)/Steam/steamapps/common/"
               "Factorio/doc-html/runtime-api.json")

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def load_signatures(api_path):
    """method_name -> (min_args, max_args, [param_type...]) 或 None（签名冲突，跳过）。"""
    with open(api_path, encoding="utf-8") as fh:
        api = json.load(fh)

    # takes_table 在 runtime-api v6 里挪进了 method.format，不再是顶层字段。
    # 读错位置的话它恒为 None，108 个「具名表参数」方法会被当成位置参数来核对。
    # 本项目目前所有表参数调用都写成 f{...} 的花括号语法、压根匹配不上下面那个正则，
    # 所以读错也侥幸没误报——但这属于「规则恰好算出正确答案」，不能留着。
    def takes_table(method):
        return bool(method.get("format", {}).get("takes_table")
                    or method.get("takes_table"))

    sigs = {}
    for cls in api["classes"]:
        for method in cls.get("methods", []):
            if takes_table(method):
                continue  # 具名表参数不存在「位置写反」这回事
            params = sorted(method.get("parameters", []),
                            key=lambda p: p.get("order", 0))
            types = [p["type"] if isinstance(p["type"], str) else None
                     for p in params]
            required = sum(1 for p in params if not p.get("optional"))
            sig = (required, len(params), tuple(types))
            name = method["name"]
            if name in sigs and sigs[name] != sig:
                sigs[name] = None  # 重名且签名不同：无法判定，放弃
            else:
                sigs[name] = sig
    return {k: v for k, v in sigs.items() if v is not None}


def split_args(text):
    """按顶层逗号切分实参。括号/花括号/方括号/字符串内部的逗号不算。"""
    args, depth, quote, current = [], 0, None, ""
    i = 0
    while i < len(text):
        ch = text[i]
        if quote:
            if ch == "\\":
                current += text[i:i + 2]
                i += 2
                continue
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
        elif ch == "," and depth == 0:
            args.append(current.strip())
            current = ""
            i += 1
            continue
        current += ch
        i += 1
    if current.strip():
        args.append(current.strip())
    return args


def match_call(line, start):
    """从 '(' 处向后找配对的 ')'，返回内部文本；跨行或不配对返回 None。"""
    depth, quote = 0, None
    for i in range(start, len(line)):
        ch = line[i]
        if quote:
            if ch == "\\":
                continue
            if ch == quote:
                quote = None
        elif ch in "\"'":
            quote = ch
        elif ch in "([{":
            depth += 1
        elif ch in ")]}":
            depth -= 1
            if depth == 0:
                return line[start + 1:i]
    return None


CALL_RE = re.compile(r"(?<![\w.:])([\w.]+)[.:](\w+)\s*\(")

# 本项目自己的模块方法，和引擎重名也不该被检查。
LOCAL_PREFIXES = ("M.", "constants.", "geometry.", "util.", "events.", "popup.",
                  "ring.", "chests.", "pockets.", "worlds.", "exp.", "stamina.",
                  "noise.", "gui.", "claim.", "convert.", "travel.", "help.",
                  "status.", "hud.", "string.", "table.", "math.", "os.")


def check_file(path, sigs):
    problems = []
    with open(path, encoding="utf-8") as fh:
        for lineno, line in enumerate(fh, 1):
            code = line.split("--", 1)[0]
            for m in CALL_RE.finditer(code):
                receiver, method = m.group(1), m.group(2)
                if any(f"{receiver}.".startswith(p) for p in LOCAL_PREFIXES):
                    continue
                sig = sigs.get(method)
                if not sig:
                    continue
                inner = match_call(code, m.end() - 1)
                if inner is None:
                    continue  # 跨行调用，本脚本不处理
                if inner.strip().startswith("{"):
                    continue  # 表构造实参，不是位置参数
                args = split_args(inner)
                required, maximum, types = sig
                where = f"{os.path.relpath(path, ROOT)}:{lineno}"
                call = f"{receiver}.{method}"
                if len(args) > maximum:
                    problems.append(
                        f"{where}  {call} 传了 {len(args)} 个参数，签名最多 {maximum} 个")
                    continue
                if args and len(args) < required:
                    problems.append(
                        f"{where}  {call} 传了 {len(args)} 个参数，签名至少要 {required} 个")
                    continue
                for idx, arg in enumerate(args):
                    if arg in ("true", "false") and idx < len(types):
                        expected = types[idx]
                        if expected and expected != "boolean":
                            problems.append(
                                f"{where}  {call} 第 {idx + 1} 个参数传了布尔字面量 "
                                f"{arg}，但签名这个位置是 {expected}（疑似参数写反）")
    return problems


def main():
    api_path = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_API
    if not os.path.exists(api_path):
        print(f"跳过：找不到 runtime-api.json（{api_path}）")
        return 0

    sigs = load_signatures(api_path)
    targets = []
    for base, _dirs, files in os.walk(ROOT):
        if ".git" in base:
            continue
        for name in sorted(files):
            if name.endswith(".lua"):
                targets.append(os.path.join(base, name))

    problems = []
    for path in sorted(targets):
        problems.extend(check_file(path, sigs))

    if problems:
        print(f"发现 {len(problems)} 处可疑调用：")
        for p in problems:
            print("  " + p)
        return 1
    print(f"检查了 {len(targets)} 个 Lua 文件、{len(sigs)} 个引擎方法签名，未发现位置参数问题。")
    return 0


if __name__ == "__main__":
    sys.exit(main())
