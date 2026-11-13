#!/usr/bin/env python3
"""KAGURA-6502 BASIC image tool.

  mkimage.py basic <basic.bin> <base_hex> <out.bin> <out_psram.hex>
      Fill the 16-bit checksum into the image header (+12), check the header,
      write the final image and a PSRAM preload file for the testbench
      ("@<byte address>" + one byte per line, $readmemh format).
  mkimage.py rom <bios.bin> <out.hex>
      One byte per line ($readmemh) for the Boot ROM BSRAM.
  mkimage.py frame <image.bin> <base_hex> <out.bin>
      Wrap an image into a BIOS loader 'L' frame followed by 'B' (boot).
"""
import sys


def basic(src, base, out_bin, out_hex):
    b = bytearray(open(src, 'rb').read())
    assert b[:8] == b'K65BASIC', 'missing header magic'
    end = b[10] | b[11] << 8
    assert end == base + len(b), f'header end ${end:04X} != base+len ${base + len(b):04X}'
    assert end <= 0xC000, 'image overlaps the bank window'
    s = sum(b[24:]) & 0xFFFF   # header is 24 bytes (kagura.inc HDR_LEN)
    b[12], b[13] = s & 0xFF, s >> 8
    open(out_bin, 'wb').write(b)
    with open(out_hex, 'w', newline='\n') as f:
        f.write(f'@{base:x}\n')
        f.writelines(f'{x:02x}\n' for x in b)
    cold = b[8] | b[9] << 8
    warm = b[14] | b[15] << 8
    print(f'BASIC image ${base:04X}-${end - 1:04X} ({len(b)} bytes), checksum ${s:04X}, '
          f'cold ${cold:04X}, warm ${warm:04X}')


def rom(src, out_hex):
    b = open(src, 'rb').read()
    assert len(b) in (2048, 4096), len(b)
    with open(out_hex, 'w', newline='\n') as f:
        f.writelines(f'{x:02x}\n' for x in b)
    used = len(b.rstrip(b'\xff'))
    print(f'Boot ROM {len(b)} bytes ({src})')


def frame(src, base, out):
    b = open(src, 'rb').read()
    s = sum(b) & 0xFFFF
    f = bytes([ord('L'), base & 0xFF, base >> 8, len(b) & 0xFF, len(b) >> 8]) + b + \
        bytes([s & 0xFF, s >> 8, ord('B')])
    open(out, 'wb').write(f)
    print(f'loader frame: {len(f)} bytes')


if __name__ == '__main__':
    cmd = sys.argv[1]
    if cmd == 'basic':
        basic(sys.argv[2], int(sys.argv[3], 16), sys.argv[4], sys.argv[5])
    elif cmd == 'rom':
        rom(sys.argv[2], sys.argv[3])
    elif cmd == 'frame':
        frame(sys.argv[2], int(sys.argv[3], 16), sys.argv[4])
    else:
        sys.exit(__doc__)
