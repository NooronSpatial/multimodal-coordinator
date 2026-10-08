"""Reads a CI log of the main suite step and prints its stalls.

For every test: its start (the 'started' line) and its end (the 'passed /
failed after' line). A stall is a stretch of the log with no line at all;
the tests 'in flight' across it are the ones started before and ended after.
"""
import re
import sys
from datetime import datetime

STAMP = re.compile(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d+)Z (.*)$")
START = re.compile(r'◇ Test (.+?) started\.')
END = re.compile(r'[✔✘] Test (.+?) (?:passed|failed) after ([\d.]+) seconds')
RUN = re.compile(r'Test run with (\d+) tests')


def stamp(text):
    return datetime.strptime(text[:26], "%Y-%m-%dT%H:%M:%S.%f")


def read(path):
    lines = []
    in_suite = False
    for raw in open(path, encoding="utf-8", errors="replace"):
        parts = raw.rstrip("\n").split("\t")
        if len(parts) < 3:
            continue
        step, body = parts[1], parts[2]
        m = STAMP.match(body)
        if not m:
            continue
        when, text = stamp(m.group(1)), m.group(2)
        if "Test run started" in text or ("◇ Test" in text and not in_suite):
            in_suite = True
        if in_suite:
            lines.append((when, text))
        if in_suite and RUN.search(text):
            break
    return lines


def main(path, gap_floor=1.5):
    lines = read(path)
    if not lines:
        print("no suite found"); return
    t0 = lines[0][0]
    starts, ends = {}, {}
    for when, text in lines:
        s = START.search(text)
        if s:
            starts.setdefault(s.group(1), when)
        e = END.search(text)
        if e:
            ends[e.group(1)] = (when, float(e.group(2)), text.startswith("✘"))
    total = (lines[-1][0] - t0).total_seconds()
    print(f"{path}: suite {total:.1f} s, {len(starts)} started, {len(ends)} ended")
    for (a, _), (b, _) in zip(lines, lines[1:]):
        gap = (b - a).total_seconds()
        if gap < gap_floor:
            continue
        print(f"  STALL {gap:.1f} s from t+{(a - t0).total_seconds():.1f} s")
        flight = [n for n, w in starts.items() if w <= a and (n not in ends or ends[n][0] >= b)]
        for name in sorted(flight, key=lambda n: starts[n]):
            began = (starts[name] - t0).total_seconds()
            end = ends.get(name)
            took = f"{end[1]:.1f} s" + (" RED" if end and end[2] else "") if end else "never ended"
            print(f"     in flight since t+{began:5.1f}  {took:>10}  {name[:110]}")


if __name__ == "__main__":
    for p in sys.argv[1:]:
        main(p)
        print()
