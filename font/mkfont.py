# 本脚本（mkfont.py）由 AI Boot Pro 项目编写，采用 MIT 许可证。
# 注意：它生成的字体产物（aiboot-cjk.psf.gz）源自 GNU Unifont，
#       按 GPL v2+ 分发，与本脚本的 MIT 许可相互独立。
#!/usr/bin/env python3
"""Build the AI-Boot 512-glyph console font (415 CJK slots, stretched ASCII).

Why this exists
---------------
The kernel framebuffer console only accepts a font with exactly 256 or 512
glyphs (anything else -> ioctl(KDFONTOP) EINVAL), so a full CJK console font is
impossible.  We ship a 512-glyph subset that covers every character the UI can
print, and `tools/check_cjk_font.py` asserts that coverage.

Layout
------
    glyph 0        blank, unmapped
    glyph 1..31    CJK #1..#31     (control codes are never drawn on screen,
                                    so these slots are free)
    glyph 32..126  U+0020..U+007E  ASCII, horizontally STRETCHED 2x so each
                                    character fills the whole 16px cell
                                    (solid frames, no inter-character gaps)
    glyph 127      blank, unmapped
    glyph 128..511 CJK #32..#415
Total CJK capacity = 31 + 384 = 415.

Usage: mkfont.py <unifont.hex> <overlay-dir> <out.psf.gz> [out.psf]
"""
import gzip
import os
import struct
import sys

SLOTS = 512
CJK_A = list(range(1, 32))        # 31 slots
ASCII_LO, ASCII_HI = 32, 126      # U+0020..U+007E
CJK_B = list(range(128, 512))     # 384 slots
CAPACITY = len(CJK_A) + len(CJK_B)


def needed_chars(overlay):
    """Exactly the rule used by tools/check_cjk_font.py."""
    chars = []
    for root, _dirs, files in os.walk(overlay):
        for f in files:
            p = os.path.join(root, f)
            try:
                raw = open(p, 'rb').read()
            except Exception:
                continue
            if b'\x00' in raw:
                continue                      # binary (e.g. the font itself)
            text = raw.decode('utf-8', errors='ignore')
            for line in text.splitlines():
                if line.lstrip().startswith('#'):
                    continue                  # comments never reach the screen
                chars.extend(ch for ch in line if ord(ch) > 0x7F)
    return sorted(set(chars), key=ord)


def load_unifont(path):
    """unifont.hex -> {codepoint: hex string} (32 or 64 hex digits)."""
    bm = {}
    with open(path, encoding='utf-8', errors='ignore') as fh:
        for line in fh:
            line = line.strip()
            if ':' not in line:
                continue
            cp_s, bits = line.split(':', 1)
            bits = bits.strip()
            if len(bits) >= 64:
                bm[int(cp_s, 16)] = bits[:64]
            elif len(bits) >= 32:
                bm[int(cp_s, 16)] = bits[:32]
    return bm


def expand2(b):
    """8 pixels -> 16 pixels, each pixel doubled."""
    r = 0
    for i in range(8):
        if b & (1 << (7 - i)):
            r |= 3 << ((7 - i) * 2)
    return r


def glyph(bm, cp, stretch):
    bits = bm.get(cp)
    if bits is None:
        return b'\x00' * 32
    out = bytearray(32)
    if len(bits) == 32:                       # half width 8x16
        for r in range(16):
            b = int(bits[r * 2:r * 2 + 2], 16)
            if stretch:
                e = expand2(b)
                out[r * 2] = (e >> 8) & 0xFF
                out[r * 2 + 1] = e & 0xFF
            else:
                out[r * 2] = b
    else:                                     # full width 16x16
        for r in range(32):
            out[r] = int(bits[r * 2:r * 2 + 2], 16)
    return bytes(out)


def utf8(cp):
    if cp < 0x80:
        return bytes([cp])
    if cp < 0x800:
        return bytes([0xC0 | (cp >> 6), 0x80 | (cp & 0x3F)])
    return bytes([0xE0 | (cp >> 12), 0x80 | ((cp >> 6) & 0x3F), 0x80 | (cp & 0x3F)])


def main():
    hexfile, overlay, outgz = sys.argv[1], sys.argv[2], sys.argv[3]
    outpsf = sys.argv[4] if len(sys.argv) > 4 else None

    bm = load_unifont(hexfile)
    needed = needed_chars(overlay)
    if len(needed) > CAPACITY:
        raise SystemExit('need %d characters but only %d CJK slots exist'
                         % (len(needed), CAPACITY))

    # glyph index -> code point (-1 = blank, unmapped)
    cps = [-1] * SLOTS
    for a in range(ASCII_LO, ASCII_HI + 1):
        cps[a] = a
    queue = [ord(c) for c in needed]
    k = 0
    for idx in CJK_A + CJK_B:
        if k < len(queue):
            cps[idx] = queue[k]
            k += 1

    data = bytearray()
    table = bytearray()
    missing = []
    for i in range(SLOTS):
        cp = cps[i]
        if cp < 0:
            data += b'\x00' * 32
            table += b'\xff'
            continue
        if cp not in bm:
            missing.append(cp)
        data += glyph(bm, cp, ASCII_LO <= i <= ASCII_HI)
        table += utf8(cp) + b'\xff'

    header = struct.pack('<8I', 0x864AB572, 0, 32, 1, SLOTS, 32, 16, 16)
    raw = header + bytes(data) + bytes(table)

    if outpsf:
        with open(outpsf, 'wb') as fh:
            fh.write(raw)
    with gzip.open(outgz, 'wb', compresslevel=9) as fh:
        fh.write(raw)

    print('needed chars = %d / %d slots' % (len(needed), CAPACITY))
    print('missing glyphs in unifont.hex = %d %s'
          % (len(missing), ' '.join('U+%04X' % c for c in missing[:20])))
    print('wrote %s (%d bytes raw)' % (outgz, len(raw)))


if __name__ == '__main__':
    main()
