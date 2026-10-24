#!/usr/bin/env python3
"""AI-Boot i18n consistency check.

Checks, for every script in the overlay:
  1. every `$(t KEY)` / `$(t KEY)`-style call has a matching key in t()
  2. the English and Chinese tables in t() have exactly the same key set
  3. no key is defined twice in the same table
  4. (optional) no hard-coded non-ASCII text is printed to the screen outside
     of the t() tables and outside comments

Exit 0 when everything is fine, 1 otherwise.
Usage: check_i18n.py [overlay-dir]
"""
import os
import re
import sys


def read(path):
    with open(path, encoding='utf-8') as fh:
        return fh.read()


def t_tables(src):
    """Return (english_case, chinese_case) text of the t() function."""
    i = src.index('\nt() {')
    j = src.index('\n}\n', i)
    body = src[i:j]
    blocks = re.findall(r'case "\$key" in(.*?)esac', body, re.S)
    if len(blocks) != 2:
        raise SystemExit('t() must contain exactly 2 case blocks, found %d' % len(blocks))
    return blocks[0], blocks[1]


def keys_of(block):
    return [m.group(1) for m in re.finditer(r'^\s*([a-z_0-9]+)\)\s', block, re.M)]


def main():
    overlay = sys.argv[1] if len(sys.argv) > 1 else 'overlay'
    bindir = os.path.join(overlay, 'usr/local/bin')
    common = read(os.path.join(bindir, 'ai-boot-common.sh'))
    en, zh = t_tables(common)
    ke, kz = keys_of(en), keys_of(zh)

    problems = []

    dup_en = [k for k in set(ke) if ke.count(k) > 1]
    dup_zh = [k for k in set(kz) if kz.count(k) > 1]
    if dup_en:
        problems.append('t() 英文表有重复 key: %s' % dup_en)
    if dup_zh:
        problems.append('t() 中文表有重复 key: %s' % dup_zh)

    only_en = sorted(set(ke) - set(kz))
    only_zh = sorted(set(kz) - set(ke))
    if only_en:
        problems.append('只在英文表里的 key: %s' % only_en)
    if only_zh:
        problems.append('只在中文表里的 key: %s' % only_zh)

    # every $(t KEY) call in every script must exist
    known = set(ke) | set(kz)
    used = {}
    for f in sorted(os.listdir(bindir)):
        if not f.endswith('.sh'):
            continue
        text = read(os.path.join(bindir, f))
        for m in re.finditer(r'\$\(t ([a-z_0-9]+)\)', text):
            used.setdefault(m.group(1), set()).add(f)
    missing = sorted(k for k in used if k not in known)
    if missing:
        for k in missing:
            problems.append('用了不存在的 key: %s  (在 %s)' % (k, ', '.join(sorted(used[k]))))

    # hard-coded screen text in English mode
    hard = []
    for f in sorted(os.listdir(bindir)):
        if not f.endswith('.sh'):
            continue
        lines = read(os.path.join(bindir, f)).split('\n')
        try:
            i = next(k for k, l in enumerate(lines) if l.startswith('t() {'))
            j = next(k for k in range(i, len(lines)) if lines[k] == '}')
        except StopIteration:
            i = j = -1
        for k, l in enumerate(lines):
            if i <= k <= j:
                continue
            st = l.strip()
            if st.startswith('#') or not any(ord(c) > 0x7F for c in l):
                continue
            if re.search(r'\b(echo|ui_line|ui_title|ui_nav|confirm|press_any_key'
                         r'|read_line|read_secret)\b', l):
                if '>' in l and '2>&1' not in l:
                    continue
                code = l.split('#')[0]
                if any(ord(c) > 0x7F for c in code):
                    hard.append('%s:%d  %s' % (f, k + 1, st[:70]))
    if hard:
        problems.append('英文模式下会直接打印中文的位置（应为 0）:\n    ' + '\n    '.join(hard))

    print('t(): 英文 %d 个 key，中文 %d 个 key' % (len(ke), len(kz)))
    print('脚本引用的 key: %d 个' % len(used))
    if problems:
        for p in problems:
            print('FAIL: ' + p)
        return 1
    print('ok: 表对称、无重复、所有引用的 key 都存在、英文模式无硬编码中文')
    return 0


if __name__ == '__main__':
    sys.exit(main())
