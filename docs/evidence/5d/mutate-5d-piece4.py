# 5d piece 4's mutation runner (AC-372, D-144): think in the gate. Each mutation breaks
# ONE rule — the hold, the reply ticket, the tool rule, the opt-in, the held failure, the
# timeline, the throw-away, the report, each real mind's answer — apply, build, run the
# rows, revert with git. NO VERDICT when no summary line came.
import os, re, signal, subprocess, sys
REPO = "/Users/ryad/Developer/multimodal-coordinator"
FILTER = "ThinkInTheGateTests|MayActTests|TurnCoordinatorTests|TurnTimelineTests|ThinkGateTests|BargeWindowTests|BargeLoudnessTests"
AUDIO = "Sources/MultiModalKit/Conversation/TurnCoordinator+Audio.swift"
G = "Sources/MultiModalKit/Conversation/TurnCoordinator+ThinkInTheGate.swift"
MUTATIONS = [
    ("M96", "nothing is held: an early reply's words leave at once", G,
     "        guard live.held == nil else {\n            current?.held?.append(update)\n            return false\n        }\n", ""),
    ("M97", "no reply ticket: a thrown-away reply's stragglers get through", G,
     "        guard live.reply == reply else {\n            staleRepliesDropped += 1\n            return false\n        }\n", ""),
    ("M98", "the reply ticket is not raised when the early reply is thrown away", G,
     "        replyTickets += 1\n        current?.reply = replyTickets\n        current?.held = nil\n", "        current?.held = nil\n"),
    ("M99", "a mind that may act is opened early anyway", G,
     "        guard config.thinksInTheGate, !replyGenerator.mayActDuringReply else { return }\n",
     "        guard config.thinksInTheGate else { return }\n"),
    ("M100", "the app's opt-in is ignored: always early", G,
     "        guard config.thinksInTheGate, !replyGenerator.mayActDuringReply else { return }\n",
     "        guard !replyGenerator.mayActDuringReply else { return }\n"),
    ("M101", "a held open failure is forgotten at the gate's end", G,
     "        if let failure = live.heldOpenFailure {\n", "        if let failure = live.heldOpenFailure, false {\n"),
    ("M102", "③ does not end at the gate's end", G,
     "        current?.held = nil\n        current?.openedAt = now\n", "        current?.held = nil\n"),
    ("M103", "the timeline never says how long the mind thought in the gate",
     "Sources/MultiModalKit/Conversation/TurnCoordinator+Stages.swift",
     ",\n                        thoughtInTheGate: live.thoughtInTheGate))", "))"),
    ("M104", "an onset in the gate does not throw the early reply away",
     "Sources/MultiModalKit/Conversation/TurnCoordinator+Audio.swift",
     "            await throwAwayEarlyReply()\n", ""),
    ("M105", "a kept early reply is never reported", G,
     "            latencyReporter?.earlyReply(EarlyReply(turn: turn, kept: true, thought: thought))\n", ""),
    ("M106", "the Apple mind says it never acts", "Sources/MultiModalKit/Conversation/AppleReplyGenerator.swift",
     "    public var mayActDuringReply: Bool { !tools.isEmpty }\n", "    public var mayActDuringReply: Bool { false }\n"),
    ("M107", "the MLX mind says it always acts", "Sources/MultiModalKitMLX/MLXReplyGenerator.swift",
     "    public var mayActDuringReply: Bool { !source.tools.isEmpty }\n", "    public var mayActDuringReply: Bool { true }\n"),
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
