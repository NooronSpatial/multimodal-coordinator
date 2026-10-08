# The barge rows' mutations, re-run after D-143 (F-42 A): the rows now wait for the
# coordinator's verdict (BargeVerdict's probe) instead of 2 s of nothing. M85-M92
# are piece 3's own, unchanged; M93-M95 aim at what the old 2 s wait was best at,
# a barge that comes AFTER the end ("a leak that ended cannot barge later").
import os, re, signal, subprocess, sys
REPO = "/Users/ryad/Developer/multimodal-coordinator"
FILTER = "BargeLoudnessTests|BargeWindowTests|EnergyVADTests|AudioPumpTests|TurnCoordinatorTests|TurnTimelineTests"
AUDIO = "Sources/MultiModalKit/Conversation/TurnCoordinator+Audio.swift"
MUTATIONS = [
    ("M85", "the window ignores loudness again (the old rule)", AUDIO,
     "            guard loud, chunk.start >= candidate.deadline else { return nil }\n",
     "            guard chunk.start >= candidate.deadline else { return nil }\n"),
    ("M86", "a chunk the VAD said nothing about counts as quiet", AUDIO,
     "            let loud = chunk.isLoud != false\n",
     "            let loud = chunk.isLoud == true\n"),
    ("M87", "the pump drops the VAD's verdict", "Sources/MultiModalKit/Audio/AudioPump.swift",
     "isLoud: vad.lastChunkIsLoud)", "isLoud: nil)"),
    ("M88", "the detector's verdict misses the exact threshold", "Sources/MultiModalKit/Audio/EnergyVAD.swift",
     "        lastChunkIsLoud = rms >= config.threshold\n", "        lastChunkIsLoud = rms > config.threshold\n"),
    ("M89", "an abandoned candidate's words enter the ledger again",
     "Sources/MultiModalKit/Conversation/TurnCoordinator+Transcripts.swift",
     " && !abandonedUtterances.contains(utterance)", ""),
    ("M90", "an abandoned candidate is never reported", AUDIO,
     "                report(candidate, verdictAt: ended, accepted: false)\n", ""),
    ("M91", "loud time counts the quiet chunks too", AUDIO,
     "            if loud, chunk.start >= candidate.onset {\n", "            if chunk.start >= candidate.onset {\n"),
    ("M92", "the measured window back to 600 ms", "Sources/MultiModalKit/Conversation/TurnCoordinator.swift",
     "    public static let measured = Duration.milliseconds(320)\n",
     "    public static let measured = Duration.milliseconds(600)\n"),
    ("M93", "a leak that ended keeps its candidate armed", AUDIO,
     "            }\n            pendingBarge = nil\n            return nil\n        }\n        guard case .speechStarted",
     "            }\n            return nil\n        }\n        guard case .speechStarted"),
    ("M94", "the end of speech is ignored (4k's mutation: the arm deleted)", AUDIO,
     "        if case .speechEnded(let ended) = event {\n",
     "        if case .speechEnded(let ended) = event, ended.frames < 0 {\n"),
    ("M95", "no window: every onset while speaking barges at once", AUDIO,
     "        if case .speaking = state, config.bargeWindow > .zero {\n",
     "        if case .speaking = state, config.bargeWindow < .zero {\n"),
]
def run(cmd, timeout=900):
    proc = subprocess.Popen(cmd, cwd=REPO, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, start_new_session=True)
    try:
        out, _ = proc.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL); out, _ = proc.communicate(); out = "TIMED OUT\n" + (out or "")
    return proc.returncode, re.sub(r"\x1b\[[0-9;]*m", "", out or "")
log = []
for name, what, path, old, new in MUTATIONS:
    full = f"{REPO}/{path}"; text = open(full).read()
    if text.count(old) != 1:
        log.append(f"## {name} — {what}\nSKIPPED: anchor matched {text.count(old)} times\n"); continue
    open(full, "w").write(text.replace(old, new, 1))
    code, build = run("swift build --build-tests 2>&1")
    if code != 0:
        errs = sorted(set(re.findall(r"\S+\.swift:\d+:\d+: error: .*", build)))[:3]
        verdict = "DID NOT BUILD:\n" + "\n".join(errs)
    else:
        _, out = run(f"swift test --skip-build --filter '{FILTER}' 2>&1", timeout=600)
        failed = sorted(set(re.findall(r'Test "([^"]+)"(?: with \d+ test cases)? failed', out)))
        summary = [l for l in out.splitlines() if "Test run with" in l]
        verdict = ("KILLED — red rows:\n" + "\n".join(f"  - {t}" for t in failed)) if failed else \
                  ("SURVIVED — every row green" if summary else "NO VERDICT — no summary line")
    rc, _ = run(f"git checkout -- {path}")
    entry = f"## {name} — {what}\nfile: {path}\n{verdict}\nreverted: {'yes' if rc == 0 else 'NO'}\n"
    log.append(entry); print(entry, flush=True)
_, st = run("git status --porcelain -- Sources Tests")
log.append(f"source tree after the run: {'clean' if not st.strip() else 'DIRTY: ' + st.strip()}\n")
open(sys.argv[1], "w").write("\n".join(log)); print(log[-1])
