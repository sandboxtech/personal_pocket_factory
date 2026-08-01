#!/usr/bin/env python3
"""locale 一致性检查：两种语言的键集、占位符、以及键和代码的对应关系。

查六件事：
  1. 两种语言的键集完全相同（少一条就是某个客户端语言下显示 "Unknown key"）
  2. 同一个键在两种语言里用的占位符集合相同
  3. 代码里引用了但 locale 没有的键
  4. locale 里有但没人用的死键
  5. 每个调用点传的实参个数 == 该键最大的占位符编号
  6. 中文文案里不出现破折号（项目文案约定）

第 5 条是这里唯一查得到、别处都查不到的东西：locale 少传一个参数不会报错，
只会在游戏里显示成 "__3__" 这种没被替换的占位符，而那要人眼看到才发现。

【动态拼出来的键】/pw-config 的说明键是 'pw.cfg-' .. 字段名 拼出来的，
静态 grep 永远扫不到，不特殊处理的话 31 个 cfg-* 会被全部误报成死键。
所以这里从 constants.lua 的 TUNABLES / TUNABLE_TABLES / TUNABLE_GROUPS 里
把字段名读出来，按同样的规则还原成键名。这个还原规则和 commands.lua 里那行
string.gsub(item.key, '_', '-') 是一对，改一处就要改另一处。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ZH = os.path.join(ROOT, 'locale/zh-CN/locale.cfg')
EN = os.path.join(ROOT, 'locale/en/locale.cfg')

# [pw] 段之外的键，不参与「有没有人用」的核对
META = {'description', 'scenario-name'}


def parse(path):
    """键 -> 原始文本。跳过注释、空行、段头。"""
    out = {}
    for line in open(path, encoding='utf-8'):
        t = line.strip()
        if '=' in t and not t.startswith(('#', ';', '[')):
            k, v = t.split('=', 1)
            out[k] = v
    return out


def placeholders(text):
    return set(re.findall(r'__\d+__', text))


def max_placeholder(text):
    idx = [int(m) for m in re.findall(r'__(\d+)__', text)]
    return max(idx) if idx else 0


def lua_files():
    for base, _dirs, files in os.walk(ROOT):
        if '.git' in base:
            continue
        for name in sorted(files):
            if name.endswith('.lua'):
                yield os.path.join(base, name)


def split_top(text):
    """按顶层逗号切分实参，忽略嵌套括号和字符串里的逗号。"""
    args, depth, quote, cur = [], 0, None, ''
    i = 0
    while i < len(text):
        c = text[i]
        if quote:
            if c == '\\':
                cur += text[i:i + 2]
                i += 2
                continue
            if c == quote:
                quote = None
        elif c in '"\'':
            quote = c
        elif c in '([{':
            depth += 1
        elif c in ')]}':
            depth -= 1
        elif c == ',' and depth == 0:
            args.append(cur.strip())
            cur = ''
            i += 1
            continue
        cur += c
        i += 1
    if cur.strip():
        args.append(cur.strip())
    return args


def dynamic_keys():
    """/pw-config 的说明键：从 constants.lua 的清单里按命名规则还原。"""
    src = open(os.path.join(ROOT, 'scripts/constants.lua'), encoding='utf-8').read()
    keys = set()
    for field in re.findall(r"\{key = '(\w+)'", src):
        keys.add('cfg-' + field.replace('_', '-'))
    m = re.search(r'M\.TUNABLE_GROUPS = \{([^}]*)\}', src)
    if m:
        for g in re.findall(r"'(\w+)'", m.group(1)):
            keys.add('cfg-group-' + g)
    # 生效范围徽标：gui/config.lua 里同样是 'pw.cfg-applies-' .. applies 拼出来的，
    # 每种取值有徽标和 tooltip 两条。取值集合就是 TUNABLES 里出现过的所有 applies。
    for a in set(re.findall(r"applies = '(\w+)'", src)):
        keys.add('cfg-applies-' + a)
        keys.add('cfg-applies-' + a + '-tip')
    return keys


def main():
    zh, en = parse(ZH), parse(EN)
    problems = []

    only_zh = sorted(set(zh) - set(en))
    only_en = sorted(set(en) - set(zh))
    if only_zh:
        problems.append('只在 zh-CN 里有的键: ' + ', '.join(only_zh))
    if only_en:
        problems.append('只在 en 里有的键: ' + ', '.join(only_en))

    for k in sorted(set(zh) & set(en)):
        if placeholders(zh[k]) != placeholders(en[k]):
            problems.append('占位符两语言不一致: %s (zh=%s en=%s)'
                            % (k, sorted(placeholders(zh[k])), sorted(placeholders(en[k]))))

    # 代码里引用的键 + 动态拼出来的键
    used = set()
    call_sites = []          # (文件, 键, 实参个数)
    for path in lua_files():
        src = open(path, encoding='utf-8').read()
        # 负向先行断言排除【拼接前缀】：commands.lua 里的 {'pw.cfg-' .. 字段名} 中，
        # 'pw.cfg-' 只是半截前缀，不是一个真实的键。不排掉就会被当成"代码引用了但 locale 没有"。
        used |= set(re.findall(r"'pw\.([\w-]+)'(?!\s*\.\.)", src))
        for m in re.finditer(r"\{'pw\.([\w-]+)'", src):
            depth, end = 0, None
            for j in range(m.start(), len(src)):
                if src[j] == '{':
                    depth += 1
                elif src[j] == '}':
                    depth -= 1
                    if depth == 0:
                        end = j
                        break
            if end is None:
                continue
            n = len(split_top(src[m.start() + 1:end])) - 1
            call_sites.append((os.path.relpath(path, ROOT), m.group(1), n))
    used |= dynamic_keys()

    missing = sorted(used - set(zh))
    if missing:
        problems.append('代码引用了但 locale 没有: ' + ', '.join(missing))

    dead = sorted(set(zh) - used - META)
    if dead:
        problems.append('locale 有但没人用: ' + ', '.join(dead))

    for path, key, n in call_sites:
        if key in zh:
            need = max_placeholder(zh[key])
            if n != need:
                problems.append('%s: pw.%s 传了 %d 个实参，locale 需要 %d 个' % (path, key, n, need))

    for k, v in zh.items():
        if '——' in v or '—' in v:
            problems.append('中文文案含破折号（项目约定不用）: ' + k)

    if problems:
        print('locale 检查发现 %d 个问题：' % len(problems))
        for p in problems:
            print('  ' + p)
        return 1
    print('✓ locale 一致：%d 个键，两种语言键集/占位符相同，无缺键无死键，实参个数全部对得上' % len(zh))
    return 0


if __name__ == '__main__':
    sys.exit(main())
