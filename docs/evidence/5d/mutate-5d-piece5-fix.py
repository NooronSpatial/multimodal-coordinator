# 5d piece 5's fix — the mutation runner (AC-381; D-148, D-149): the floor, our own token
# loop, the voice's hold. Each mutation breaks ONE rule; apply, build, run the rows, revert
# with git. NO VERDICT when no summary line came. M120 is expected to survive, and says so.
import os, re, signal, subprocess, sys
REPO = "/Users/ryad/Developer/multimodal-coordinator"
FILTER = "VoiceFloorTests|TokenLoopTests|VoiceFirstTests|NeuralVoiceFailurePathTests|DecodeStepRecordTests|MLXVendorLoopTests"
AUDIO = "Sources/MultiModalKit/Conversation/TurnCoordinator+Audio.swift"
G = "Sources/MultiModalKit/Conversation/TurnCoordinator+ThinkInTheGate.swift"
MUTATIONS = [
    ("M112", "the floor never makes anyone wait", "Sources/MultiModalKit/Audio/VoiceFloor.swift",
     "                    if state.holds == 0 || Task.isCancelled { return true }\n",
     "                    if true { return true }\n"),
    ("M113", "a cancel does not end a wait", "Sources/MultiModalKit/Audio/VoiceFloor.swift",
     "            let waiter = state.withLock { $0.waiters.removeValue(forKey: id) }\n            waiter?.resume()\n",
     "            _ = id\n"),
    ("M114", "a hold given back twice counts twice", "Sources/MultiModalKit/Audio/VoiceFloor.swift",
     "        if first { floor.release() }\n", "        _ = first\n        floor.release()\n"),
    ("M115", "the loop does not wait for the floor", "Sources/MultiModalKitMLX/TokenLoop.swift",
     "            if let floor { await floor.waitWhileTaken() }\n", "            _ = floor\n"),
    ("M116", "the loop speaks the stop token", "Sources/MultiModalKitMLX/TokenLoop.swift",
     "            if isStop(token) {\n", "            if isStop(token) && false {\n"),
    ("M117", "the budget reads as cancelled", "Sources/MultiModalKitMLX/TokenLoop.swift",
     "tokens.tokenCount >= maxTokens { return .length }", "tokens.tokenCount >= maxTokens { return .cancelled }"),
    ("M118", "the voice takes the floor for every decode", "Sources/MultiModalKitTTS/Decode/NeuralVoiceRun+Render.swift",
     "                let hold = isFirst ? floor?.take() : nil\n", "                let hold = floor?.take()\n"),
    ("M119", "the voice never gives the floor back", "Sources/MultiModalKitTTS/Decode/NeuralVoiceRun+Render.swift",
     "                defer { hold?.giveBack() }\n", "                _ = hold\n"),
    ("M120", "the local mind forgets the floor (expected to SURVIVE: no unit row reaches LocalMind)", "Sources/MultiModalKitMLX/LocalMind.swift",
     "floor: filters.floor, each: { id in", "floor: nil, each: { id in"),
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
