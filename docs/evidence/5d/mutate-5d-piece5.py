# 5d piece 5's mutation runner (AC-376, D-146): the first sound in its parts. Each mutation
# breaks ONE rule — the coordinator carrying the parts, each part's two ends, the rest —
# apply, build, run the rows, revert with git. NO VERDICT when no summary line came.
import os, re, signal, subprocess, sys
REPO = "/Users/ryad/Developer/multimodal-coordinator"
FILTER = "FirstSoundPartsTests|TurnTimelineTests|DecodeStepRecordTests|ThinkInTheGateTests|TurnCoordinatorTests"
AUDIO = "Sources/MultiModalKit/Conversation/TurnCoordinator+Audio.swift"
G = "Sources/MultiModalKit/Conversation/TurnCoordinator+ThinkInTheGate.swift"
MUTATIONS = [
    ("M108", "the coordinator drops the voice's parts", "Sources/MultiModalKit/Conversation/TurnCoordinator+Stages.swift",
     "                        firstSoundParts: live.synthesisRun?.firstSoundParts))", "                        firstSoundParts: nil))"),
    ("M109", "(a) runs to the first audio, not to the decode asked for", "Sources/MultiModalKitTTS/Decode/NeuralVoiceRun.swift",
     "FirstSoundParts(words: birth.duration(to: asked),", "FirstSoundParts(words: birth.duration(to: audio),"),
    ("M110", "(b) is measured from the birth", "Sources/MultiModalKitTTS/Decode/NeuralVoiceRun.swift",
     "decode: asked.duration(to: audio))", "decode: birth.duration(to: audio))"),
    ("M111", "the rest forgets the decode", "Sources/MultiModalKit/Conversation/TurnTimeline.swift",
     "        firstSoundParts.map { firstSound - $0.words - $0.decode }", "        firstSoundParts.map { firstSound - $0.words }"),
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
