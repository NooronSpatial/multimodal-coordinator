import sys, glob, wave, struct, os
import numpy as np

LEVEL = 0.001          # the SilenceMeter's level (F-27 A)
GAP = 0.060            # every quiet stretch of 60 ms or more inside the words: the boundaries, now short

def read(path):
    # AVAudioFile writes float32 CAF/WAV; try soundfile-free parsing via numpy on the data chunk
    import subprocess, tempfile
    data = open(path, "rb").read()
    # find 'data' chunk in a RIFF/WAVE (float32) file
    if data[:4] == b"RIFF":
        pos = 12; rate = None; fmt_bits = None
        while pos < len(data):
            cid = data[pos:pos+4]; size = struct.unpack("<I", data[pos+4:pos+8])[0]
            body = data[pos+8:pos+8+size]
            if cid == b"fmt ":
                fmt, ch, rate = struct.unpack("<HHI", body[:8]); fmt_bits = struct.unpack("<H", body[14:16])[0]
            if cid == b"data":
                x = np.frombuffer(body, dtype=np.float32 if fmt_bits == 32 else np.int16).astype(np.float64)
                if fmt_bits == 16: x /= 32768
                return rate, x
            pos += 8 + size + (size & 1)
    raise SystemExit(f"{path}: not a RIFF float file (first bytes {data[:4]!r})")

def runs(mask):
    out = []; start = None
    for i, v in enumerate(mask):
        if v and start is None: start = i
        if not v and start is not None: out.append((start, i)); start = None
    if start is not None: out.append((start, len(mask)))
    return out

for path in sorted(glob.glob(os.path.join(sys.argv[1], "*.wav"))):
    rate, x = read(path)
    ms = lambda n: n / rate * 1000
    nz = np.nonzero(x)[0]; loud = np.nonzero(np.abs(x) > LEVEL)[0]
    if len(loud) == 0: print(os.path.basename(path), "no audible samples"); continue
    first_nz, first_loud, last_loud, last_nz = nz[0], loud[0], loud[-1], nz[-1]
    print(f"\n{os.path.basename(path)} · {len(x)/rate:.2f} s at {rate} Hz")
    print(f"  player start (first non-zero) {ms(first_nz):7.0f} ms · first word (>{LEVEL}) {ms(first_loud):7.0f} ms"
          f"  → quiet before the first word: {ms(first_loud-first_nz):5.0f} ms (exact zeros in it: {np.sum(x[first_nz:first_loud]==0)/max(1,first_loud-first_nz):.0%})")
    print(f"  last word {ms(last_loud):7.0f} ms · last non-zero {ms(last_nz):7.0f} ms · end {ms(len(x)):7.0f} ms"
          f"  → quiet after the last word, while non-zero: {ms(last_nz-last_loud):5.0f} ms")
    quiet = np.abs(x[first_loud:last_loud+1]) <= LEVEL
    for a, b in runs(quiet):
        if (b - a) / rate >= GAP:
            seg = x[first_loud + a: first_loud + b]
            print(f"  PAUSE at {ms(first_loud+a):7.0f} ms · {ms(b-a):5.0f} ms long · exact zeros {np.mean(seg==0):.0%} · peak |x| {np.max(np.abs(seg)):.5f}")
