# A REPLAY of Ryad's 21 spoken replies (phone, 2026-10-01) under different
# phrase rules. A projection, not a measurement: each turn's own speeds come
# from its log lines; the model is checked against the measured first sound.
import re, sys, statistics
text = open(sys.argv[1]).read()
PAD = 0.745            # Kokoro's quiet per phrase, s (Mac captures: ~0.325 + ~0.42)
LEAD_PAD = 0.325
blocks = re.findall(r"## turn (\d+)\n(.*?)(?=\n## turn |\n## timeline)", text, re.S)
tl = re.findall(r"turn (\d+): ② (\d+) · ③ (\d+) · ④ (\d+) · ⑤ (\d+) → felt (\d+) ms", text)
turns = []
for n, body in blocks:
    m = re.search(r"reply: (.*?)\n\nat ", body, re.S)
    fw = re.search(r"first word (\d+) ms · total (\d+) ms", body)
    if not m or not fw or "(no words)" in m.group(1): continue
    if "BARGED" in body and len(m.group(1)) < 30: continue        # cut before its first sound
    v = re.search(r"voice: (\d+) ms audio · RTF ([\d.]+)", body)
    turns.append(dict(n=int(n), reply=" ".join(m.group(1).split()), first=int(fw.group(1))/1000,
                      total=int(fw.group(2))/1000, audio=int(v.group(1))/1000 if v else None,
                      rtf=float(v.group(2)) if v else None))
def phrases(reply, caps):
    out, buf, i = [], reply, 0
    while buf:
        cap = caps[min(len(out), len(caps)-1)]
        cut = None
        for j, ch in enumerate(buf):
            if ch in ".,:;?!" and j+1 < len(buf) and buf[j+1] == " ": cut = j+1; break
            if j+1 >= cap:
                sp = buf.rfind(" ", 0, cap); cut = sp if sp > 0 else cap; break
        if cut is None: out.append(buf); break
        out.append(buf[:cut]); buf = buf[cut:].lstrip()
    return out
rtfs = [t["rtf"] for t in turns if t["rtf"]]
def speech_rate(t, n_today):
    if t["audio"]: return len(t["reply"]) / max(0.5, t["audio"] - PAD * n_today)
    return 15.0
def replay(t, caps, trim, keep_lead=0.04, keep_tail=0.15):
    reply = t["reply"]; ps = phrases(reply, caps)
    n_today = len(phrases(reply, [120]))
    rate = speech_rate(t, n_today)                    # chars per second of SPEECH
    rtf = t["rtf"] or statistics.median(rtfs)
    cps = max(1, len(reply) - 4) / max(0.05, t["total"] - t["first"])   # the mind, chars/s
    pos, decoder_free, play_end, gaps, first_sound = 0, 0.0, None, [], None
    for k, p in enumerate(ps):
        pos += len(p) + 1
        text_ready = min(pos, len(reply)) / cps        # after the first token
        if k == len(ps) - 1: text_ready = t["total"] - t["first"]   # the flush
        speech = len(p) / rate
        synth = rtf * (speech + PAD)                   # the model still makes its padding
        start_dec = max(text_ready, decoder_free); ready = start_dec + synth; decoder_free = ready
        audible = speech + ((keep_lead + keep_tail) if trim else PAD)
        if play_end is None:
            first_sound = ready; play_end = ready + audible
        else:
            gaps.append(max(0.0, ready - play_end) + ((keep_lead + keep_tail) if trim else PAD))
            play_end = max(ready, play_end) + audible
    lead = keep_lead if trim else LEAD_PAD
    return first_sound, first_sound + lead, gaps
rows = []
for t, (tid, ear, gate, tok, snd, felt) in zip(turns, tl):
    s_today, w_today, g_today = replay(t, [120], False)
    rows.append((t, int(snd)/1000, s_today, w_today, g_today))
err = [abs(r[2] - r[1]) for r in rows]
print(f"CHECK — the replay against the measured first sound (⑤): median error {statistics.median(err)*1000:.0f} ms,"
      f" max {max(err)*1000:.0f} ms over {len(rows)} turns")
for caps, trim, name in [([120], False, "today"), ([120], True, "trim only"),
                         ([20, 120], True, "trim + first phrase ≤ 20"),
                         ([20, 40, 120], True, "trim + 20, then 40, then 120"),
                         ([30, 60, 120], True, "trim + 30, then 60, then 120")]:
    words, worst_gap, starved = [], [], 0
    for t, measured, *_ in rows:
        s, w, g = replay(t, caps, trim)
        words.append(w)
        if g:
            extra = [x - ((0.04 + 0.15) if trim else PAD) for x in g]
            worst_gap.append(max(g)); starved += sum(1 for x in extra if x > 0.15)
        else: worst_gap.append(0)
    print(f"{name:>30}: first WORD median {statistics.median(words)*1000:5.0f} ms (max {max(words)*1000:5.0f})"
          f" · longest silence inside median {statistics.median(worst_gap)*1000:4.0f} ms (max {max(worst_gap)*1000:5.0f})"
          f" · boundaries where the voice runs dry > 150 ms: {starved}")

# CALIBRATION: one factor k on the voice's synthesis time (synth = k · RTF · audio),
# chosen to fit the MEASURED first sound; then the rules replayed again with it.
import itertools
base_replay = replay
def replay_k(k):
    def r(t, caps, trim, keep_lead=0.04, keep_tail=0.15):
        saved = t["rtf"]; t["rtf"] = (saved or statistics.median(rtfs)) * k
        try: return base_replay(t, caps, trim, keep_lead, keep_tail)
        finally: t["rtf"] = saved
    return r
best = min((statistics.median([abs(replay_k(k)(t, [120], False)[0] - m) for t, m, *_ in rows]), k)
           for k in [x / 20 for x in range(4, 21)])
k = best[1]
fit = [(t["n"], m, replay_k(k)(t, [120], False)[0]) for t, m, *_ in rows]
errs = [s - m for _, m, s in fit]
print(f"\nCALIBRATED k = {k:.2f}: median |error| {statistics.median([abs(e) for e in errs])*1000:.0f} ms,"
      f" median signed {statistics.median(errs)*1000:+.0f} ms, max |error| {max(abs(e) for e in errs)*1000:.0f} ms")
print("  turn  measured ⑤  replayed ⑤")
for n, m, s in fit: print(f"  {n:>4}  {m*1000:9.0f}  {s*1000:10.0f}")
for caps, trim, name in [([120], False, "today"), ([120], True, "trim only"),
                         ([20, 120], True, "trim + first phrase ≤ 20"),
                         ([20, 40, 120], True, "trim + 20, then 40, then 120"),
                         ([30, 60, 120], True, "trim + 30, then 60, then 120")]:
    words, worst, dry = [], [], 0
    for t, m, *_ in rows:
        s, w, g = replay_k(k)(t, caps, trim)
        words.append(w); worst.append(max(g) if g else 0)
        dry += sum(1 for x in g if x - ((0.19) if trim else PAD) > 0.15)
    print(f"{name:>30}: first WORD median {statistics.median(words)*1000:5.0f} ms (max {max(words)*1000:5.0f})"
          f" · longest silence inside: median {statistics.median(worst)*1000:4.0f}, max {max(worst)*1000:5.0f} ms"
          f" · boundaries run dry > 150 ms: {dry}")
