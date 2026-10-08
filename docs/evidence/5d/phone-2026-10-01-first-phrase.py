import re, sys, statistics
text = open(sys.argv[1]).read()
turns = re.findall(r"## turn (\d+)\nmind: .*?\n\nheard: (.*?)\n\nreply: (.*?)\n\nat .*?\n\nfirst word (\S+)(?: ms)? · total (\d+) ms(.*?)\n", text, re.S)
tl = re.findall(r"turn (\d+): ② (\d+) · ③ (\d+) · ④ (\d+) · ⑤ (\d+) → felt (\d+) ms", text)
def first_phrase(reply, cap=120):
    buf = reply
    for i, ch in enumerate(buf):
        if ch in ".,:;?!" and i + 1 < len(buf) and buf[i+1].isspace():
            head = buf[:i+1]
            return head if len(head) <= cap else cut(buf, cap)
        if i + 1 > cap:
            return cut(buf, cap)
    return buf if len(buf) <= cap else cut(buf, cap)
def cut(buf, cap):
    head = buf[:cap]
    space = head.rfind(" ")
    return buf[:space] if space > 0 else head
spoken = [t for t in turns if "BARGED" not in t[5] or t[3] != "never"]
spoken = [t for t in turns if t[3] != "never" and not ("BARGED" in t[5] and t[2].strip() == "I don't have a specific")]
rows = []
for (n, heard, reply, first, total, rest), (tid, ear, gate, tok, snd, felt) in zip(spoken, tl):
    fp = first_phrase(reply.strip())
    rows.append((int(n), int(tid), len(fp), int(tok), int(snd), int(felt), int(total), fp))
print(f"{'log':>3} {'tl':>3} {'1st phrase ch':>13} {'④':>5} {'⑤':>5} {'felt':>5} {'mind total':>10}  first phrase")
for r in rows:
    print(f"{r[0]:>3} {r[1]:>3} {r[2]:>13} {r[3]:>5} {r[4]:>5} {r[5]:>5} {r[6]:>10}  {r[7][:60]}")
short = [r for r in rows if r[2] <= 15]
mid = [r for r in rows if 15 < r[2] <= 60]
long_ = [r for r in rows if r[2] > 60]
for name, group in [("first phrase ≤ 15 ch", short), ("16–60 ch", mid), ("> 60 ch", long_)]:
    if group:
        print(f"{name:>22}: n={len(group):>2} · ⑤ median {statistics.median(r[4] for r in group):>6.0f} · felt median {statistics.median(r[5] for r in group):>6.0f}")
xs = [r[2] for r in rows]; ys = [r[4] for r in rows]
mx, my = statistics.mean(xs), statistics.mean(ys)
cov = sum((x-mx)*(y-my) for x, y in zip(xs, ys)); vx = sum((x-mx)**2 for x in xs); vy = sum((y-my)**2 for y in ys)
print(f"correlation (first-phrase characters, ⑤): r = {cov/(vx*vy)**0.5:.2f} over {len(rows)} spoken turns")
