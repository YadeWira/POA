#!/usr/bin/env python3
"""Writes pas/poaselftest.inc: the samples `poa selftest` carries inside the
binary, and the size and BLAKE3-128 of the .poa each one has to give
(doc/CLI.md, selftest). Adapted from PJA's tools/gen_selftest.py.

Three small files of tests/ogg (about 15 KB): two Vorbis files, which go
through the Vorbis model, and an Opus one, coded as bytes. The .poa of each
is made by the given poa command (`poa a SAMPLE -o OUT`); only its size and
BLAKE3-128 go in the include, so the binary carries the samples alone.
Within a format, those bytes never change, on any platform.

BLAKE3 is computed here in Python (no module needed), and checked first
against the empty input's known hash.

    tools/gen_selftest.py <poa binary>            write the include
    tools/gen_selftest.py --check <poa binary>    exit 1 if it is not current
"""
import os, struct, subprocess, sys, tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(ROOT, 'pas', 'poaselftest.inc')
SAMPLES = ['ogg/vorbis_click.ogg', 'ogg/vorbis_silence.ogg', 'ogg/opus_16k_mono.opus']

# ---- BLAKE3 (the hash mode only), after the reference implementation ----
IV = [0x6A09E667, 0xBB67AE85, 0x3C6EF372, 0xA54FF53A, 0x510E527F, 0x9B05688C, 0x1F83D9AB, 0x5BE0CD19]
PERM = [2, 6, 3, 10, 7, 0, 4, 13, 1, 11, 12, 5, 9, 14, 15, 8]
CHUNK_START, CHUNK_END, PARENT, ROOT_FLAG = 1, 2, 4, 8
M32 = 0xFFFFFFFF


def _g(s, a, b, c, d, x, y):
    s[a] = (s[a] + s[b] + x) & M32
    s[d] ^= s[a]; s[d] = ((s[d] >> 16) | (s[d] << 16)) & M32
    s[c] = (s[c] + s[d]) & M32
    s[b] ^= s[c]; s[b] = ((s[b] >> 12) | (s[b] << 20)) & M32
    s[a] = (s[a] + s[b] + y) & M32
    s[d] ^= s[a]; s[d] = ((s[d] >> 8) | (s[d] << 24)) & M32
    s[c] = (s[c] + s[d]) & M32
    s[b] ^= s[c]; s[b] = ((s[b] >> 7) | (s[b] << 25)) & M32


def _compress(cv, block, counter, blen, flags):
    m = list(struct.unpack('<16I', block))
    s = cv[:] + IV[:4] + [counter & M32, (counter >> 32) & M32, blen, flags]
    for r in range(7):
        _g(s, 0, 4, 8, 12, m[0], m[1]); _g(s, 1, 5, 9, 13, m[2], m[3])
        _g(s, 2, 6, 10, 14, m[4], m[5]); _g(s, 3, 7, 11, 15, m[6], m[7])
        _g(s, 0, 5, 10, 15, m[8], m[9]); _g(s, 1, 6, 11, 12, m[10], m[11])
        _g(s, 2, 7, 8, 13, m[12], m[13]); _g(s, 3, 4, 9, 14, m[14], m[15])
        if r < 6:
            m = [m[i] for i in PERM]
    return [s[i] ^ s[i + 8] for i in range(8)] + [s[i + 8] ^ cv[i] for i in range(8)]


def _chunk_output(data, counter):
    """(cv, last block, its length, flags) of a chunk, ready for the root or not."""
    cv = IV[:]
    blocks = [data[i:i + 64] for i in range(0, len(data), 64)] or [b'']
    for k, b in enumerate(blocks):
        flags = (CHUNK_START if k == 0 else 0) | (CHUNK_END if k == len(blocks) - 1 else 0)
        if k == len(blocks) - 1:
            return cv, b.ljust(64, b'\0'), len(b), flags, counter
        cv = _compress(cv, b.ljust(64, b'\0'), counter, 64, flags)[:8]


def blake3_128(data):
    chunks = [data[i:i + 1024] for i in range(0, len(data), 1024)] or [b'']
    stack = []
    out = None
    for n, ch in enumerate(chunks):
        out = _chunk_output(ch, n)
        if n == len(chunks) - 1:
            break
        cv = _compress(out[0], out[1], out[4], out[2], out[3])[:8]
        total = n + 1
        while total & 1 == 0:
            cv = _compress(IV, struct.pack('<16I', *(stack.pop() + cv)), 0, 64, PARENT)[:8]
            total >>= 1
        stack.append(cv)
    # the last chunk's output, merged with the stack down to the root
    cv_in, block, blen, flags, counter = out
    while stack:
        cv = _compress(cv_in, block, counter, blen, flags)[:8]
        cv_in, block, blen, flags, counter = IV, struct.pack('<16I', *(stack.pop() + cv)), 64, PARENT, 0
    words = _compress(cv_in, block, counter, blen, flags | ROOT_FLAG)
    return struct.pack('<16I', *words)[:16]


def pas_bytes(name, b):
    out = [f'  {name}: array[0..{len(b) - 1}] of Byte = (']
    for i in range(0, len(b), 20):
        out.append('    ' + ', '.join(f'${x:02X}' for x in b[i:i + 20]) + (',' if i + 20 < len(b) else ''))
    out.append('  );')
    return out


def generate(poa):
    assert blake3_128(b'').hex() == 'af1349b9f5f9a1a6a0404dea36dcc949', 'the BLAKE3 here is wrong'
    lines = ['{ Written by tools/gen_selftest.py: do not edit. The samples of `poa selftest`',
             '  (from tests/ogg) and the size and BLAKE3-128 of the .poa of each. }', 'const']
    names, sizes, hashes = [], [], []
    with tempfile.TemporaryDirectory() as tmp:
        for k, rel in enumerate(SAMPLES):
            src = os.path.join(ROOT, 'tests', rel)
            data = open(src, 'rb').read()
            out = os.path.join(tmp, f's{k}.poa')
            subprocess.run([poa, 'a', src, '-o', out], check=True, stdout=subprocess.DEVNULL)
            packed = open(out, 'rb').read()
            # the header holds the original's BLAKE3-128: a check of the hash here
            assert packed[14:30] == blake3_128(data), f'{rel}: the BLAKE3 here disagrees with poa'
            lines += pas_bytes(f'SELFTEST_IN_{k}', data)
            names.append(os.path.basename(rel)); sizes.append(len(packed)); hashes.append(blake3_128(packed))
    n = len(names)
    lines.append(f'  SELFTEST_COUNT = {n};')
    lines.append('  SELFTEST_NAMES: array[0..SELFTEST_COUNT - 1] of string = (' +
                 ', '.join(f"'{x}'" for x in names) + ');')
    lines.append('  { the .poa of each: its size and BLAKE3-128 }')
    lines.append('  SELFTEST_POA_SIZE: array[0..SELFTEST_COUNT - 1] of SizeInt = (' +
                 ', '.join(str(x) for x in sizes) + ');')
    lines.append('  SELFTEST_POA_HASH: array[0..SELFTEST_COUNT - 1, 0..15] of Byte = (')
    lines.append(',\n'.join('    (' + ', '.join(f'${x:02X}' for x in h) + ')' for h in hashes))
    lines.append('  );')
    lines.append('')
    lines.append('{ sample k, and the BLAKE3-128 its .poa has to have }')
    lines.append('procedure SelftestSample(k: Integer; out data: TBytes; out expect: THash16);')
    lines.append('var i: Integer;')
    lines.append('begin')
    lines.append('  data := nil;')
    lines.append('  for i := 0 to 15 do expect[i] := SELFTEST_POA_HASH[k, i];')
    lines.append('  case k of')
    for k in range(n):
        lines.append(f'    {k}: begin SetLength(data, Length(SELFTEST_IN_{k})); '
                     f'Move(SELFTEST_IN_{k}[0], data[0], Length(data)); end;')
    lines.append('  end;')
    lines.append('end;')
    return '\n'.join(lines) + '\n'


def main():
    args = sys.argv[1:]
    check = bool(args) and args[0] == '--check'
    if check:
        args = args[1:]
    if len(args) != 1:
        sys.exit(__doc__)
    text = generate(os.path.abspath(args[0]))
    if check:
        old = open(OUT).read() if os.path.exists(OUT) else ''
        if old != text:
            print('pas/poaselftest.inc is not current: run tools/gen_selftest.py <poa>')
            sys.exit(1)
        print('pas/poaselftest.inc is current')
        return
    open(OUT, 'w').write(text)
    print(f'wrote {OUT}')


main()
