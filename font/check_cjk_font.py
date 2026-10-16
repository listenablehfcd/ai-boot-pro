# 本脚本（check_cjk_font.py）由 AI Boot Pro 项目编写，采用 MIT 许可证。
# 注意：它生成的字体产物（aiboot-cjk.psf.gz）源自 GNU Unifont，
#       按 GPL v2+ 分发，与本脚本的 MIT 许可相互独立。
#!/usr/bin/env python3
"""Assert that the AI-Boot console font covers every character the UI prints.

Usage: check_cjk_font.py <font.psf.gz> <overlay-dir>
Exit 0 when every non-ASCII character used on screen has a glyph, exit 1 otherwise.
"""
import gzip
import os
import struct
import sys


def load_table(path):
    raw = gzip.open(path, 'rb').read() if path.endswith('.gz') else open(path, 'rb').read()
    if raw[:4] != b'\x72\xb5\x4a\x86':
        raise SystemExit('%s: not a PSF2 font' % path)
    _magic, _ver, hsize, flags, length, charsize, height, width = struct.unpack('<8I', raw[:32])
    if length not in (256, 512):
        raise SystemExit('%s: %d glyphs, the kernel only accepts 256 or 512' % (path, length))
    if not (flags & 1):
        raise SystemExit('%s: no unicode table (flags=%d)' % (path, flags))
    table = raw[hsize + length * charsize:]
    covered = set()
    i = 0
    for _ in range(length):
        while i < len(table) and table[i] != 0xFF:
            b = table[i]
            if b < 0x80:
                n = 1
            elif b >> 5 == 0b110:
                n = 2
            elif b >> 4 == 0b1110:
                n = 3
            else:
                n = 4
            try:
                covered.add(ord(table[i:i + n].decode('utf-8')))
            except Exception:
                pass
            i += n
        i += 1
    return covered, (length, charsize, height, width)


def needed_chars(overlay):
    chars = []
    for root, _dirs, files in os.walk(overlay):
        for f in files:
            p = os.path.join(root, f)
            try:
                raw = open(p, 'rb').read()
            except Exception:
                continue
            if b'\x00' in raw:
                continue          # binary (e.g. the font itself) - not UI text
            text = raw.decode('utf-8', errors='ignore')
            for line in text.splitlines():
                if line.lstrip().startswith('#'):
                    continue      # comments never reach the screen
                chars.extend(ch for ch in line if ord(ch) > 0x7F)
    return chars


def main():
    font, overlay = sys.argv[1], sys.argv[2]
    covered, meta = load_table(font)
    print('font: %s  glyphs=%d charsize=%d %dx%d  covered=%d code points'
          % (font, meta[0], meta[1], meta[3], meta[2], len(covered)))
    uniq = sorted(set(needed_chars(overlay)))
    missing = [c for c in uniq if ord(c) not in covered]
    print('ui:   %d distinct non-ASCII characters on screen' % len(uniq))
    if missing:
        print('MISSING %d: %s' % (len(missing), ''.join(missing)))
        return 1
    print('ok: every character the UI prints has a glyph')
    return 0


if __name__ == '__main__':
    sys.exit(main())
