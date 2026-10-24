#!/usr/bin/env python3
"""检查脚本里调用了但**既不是已定义函数、也不是真实命令**的名字。

bash 只会在真的跑到那一行才报 "command not found"，所以这类 bug 能一路
活到用户手上（AI-Boot 5.0 的 start_ssh_service_quiet 就是这样漏掉的）。
做法：先剥掉引号里的内容（否则会把 echo "..." 里的英文单词当函数名），
再用 `command -v` 判断是不是真的存在这个命令。
"""
import os
import re
import shutil
import subprocess
import sys

KEYWORDS = {
    'if', 'then', 'else', 'elif', 'fi', 'for', 'while', 'until', 'do', 'done',
    'case', 'esac', 'in', 'function', 'select', 'time', 'coproc', 'return',
    'break', 'continue', 'local', 'declare', 'typeset', 'export', 'readonly',
    'shift', 'eval', 'exec', 'source', 'set', 'unset', 'trap', 'wait',
}


def is_real_command(name):
    if shutil.which(name):
        return True
    try:
        r = subprocess.run(['bash', '-c', 'command -v %s' % name],
                           capture_output=True, timeout=5)
        return r.returncode == 0
    except Exception:
        return True   # 判断不了就不报，宁可漏报也不要误报


def strip_quotes(line):
    out, i, n = [], 0, len(line)
    while i < n:
        c = line[i]
        if c in '"\'':
            q = c
            i += 1
            while i < n and line[i] != q:
                if line[i] == '\\':
                    i += 1
                i += 1
            i += 1
            out.append('""')
        else:
            out.append(c)
            i += 1
    return ''.join(out)


def main():
    d = sys.argv[1] if len(sys.argv) > 1 else 'overlay/usr/local/bin'
    files = [f for f in sorted(os.listdir(d)) if f.endswith('.sh')]
    text = {f: open(os.path.join(d, f), encoding='utf-8').read() for f in files}

    defined = set()
    for t in text.values():
        defined |= set(re.findall(r'^([a-z_][a-z0-9_]*)\s*\(\)\s*\{', t, re.M))

    # 凡是被 command -v / type -t 检查过的名字，视为"有存在性保护"，不算未定义调用
    GUARDED = set()
    for t in text.values():
        GUARDED |= set(re.findall(r'command\s+-v\s+([a-zA-Z0-9_]+)', t))
        GUARDED |= set(re.findall(r'type\s+-t\s+([a-zA-Z0-9_]+)', t))

    problems = []
    for f, t in text.items():
        for i, line in enumerate(t.split('\n'), 1):
            st = line.strip()
            if st.startswith('#'):
                continue
            code = strip_quotes(st.split(' #')[0])
            # for ((i=0;...)) 的循环头不是命令调用
            if re.match(r'^\s*(for|select)\s*\(\(', code):
                continue
            # "command -v xxx && xxx || yyy" 是存在性保护，被保护的名字不算未定义
            if 'command -v ' in code:
                code = re.sub(r'command -v\s+[a-zA-Z0-9_]+\s*(&&|\|\|)?', '', code)
                code = re.sub(r'^\s*(&&|\|\|)\s*', '', code)
            # case 分支标签行（形如 "  foo)" / "  foo|bar)" / "  a|b|c)"）不是调用
            st_code = code.strip()
            if re.match(r'^[A-Za-z0-9_|?*\[\]-]*\)\s*$', st_code):
                continue
            for m in re.finditer(r'(?:^|[;&|]\s*)([a-z_][a-z0-9_]*)', code):
                name = m.group(1)
                after = code[m.end():m.end() + 2]
                # 后面紧跟 = 或 ) 的是赋值/case 标签，不是函数调用
                if after.startswith('=') or after.startswith(')'):
                    continue
                # 前一个字符是 $ 的是变量展开
                if m.start() and code[m.start() - 1] == '$':
                    continue
                if name in KEYWORDS or name in defined or name in GUARDED:
                    continue
                if is_real_command(name):
                    continue
                problems.append('%s:%d  调用了不存在的东西: %s' % (f, i, name))
    if problems:
        for p in sorted(set(problems)):
            print('FAIL: ' + p)
        return 1
    print('ok: 没有"调用了不存在的东西"（本工程定义了 %d 个函数）' % len(defined))
    return 0


if __name__ == '__main__':
    sys.exit(main())
