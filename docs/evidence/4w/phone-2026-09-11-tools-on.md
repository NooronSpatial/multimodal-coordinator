# Conversation log — MultiModalKit demo

picker says: mind=Local · ear=Whisper · mouth=Neural · speaker shield=true · tools=on
session tool: ON · say: "Use the session tool to find out what today's session is." · the stub answers: "Today's session is a forty minute easy run. Readiness is seventy-one out of a hundred: you slept well, but yesterday's ride is still in your legs, so keep it easy."
expected: local mind, measured on the Mac's 0.6B weights: this shape — the sentence beside the app's spoken instruction — NOT called (0/3); it called only with no instruction at all (3/3). This phone's 4B is unmeasured, and the Apple mind's live half never ran (AC-223 carried): the per-turn tool line is the answer, not this note.
Apple ear (SpeechTranscriber) locales on this device: 30 total · Arabic: NONE
local model: mlx-community/Qwen3-4B-4bit · installed: true · MLX runnable here: true
memory headroom: 3628 MB before this app's limit
voice loaded: true
MLX memory now: active 2315 MB · peak 2865 MB
weights expected at: /var/mobile/Containers/Data/Application/33D7BE58-FCDB-4983-A195-EEB5542E9595/Documents/Qwen3-4B-4bit

NOTE: the `mind:` line under each turn is the brain that
ACTUALLY answered, taken from the generator the coordinator
held — not from the picker above. If they disagree, that is
the finding.

## turn 1
mind: **Local (MLX)**

heard: Good morning.

reply: Good morning! How can I assist you today?

at 4 s · thermal serious · 3558 MB free

first word 577 ms · total 1083 ms · MLX peak 2605 MB

session tool: NOT called (tools on)

voice: 3675 ms audio · RTF 0.250 · cushion 0 ms

## turn 2
mind: **Local (MLX)**

heard: What's your name?

reply: I am an AI assistant. How can I help you today?

at 13 s · thermal serious · 3558 MB free

first word 585 ms · total 1217 ms · MLX peak 2634 MB

session tool: NOT called (tools on)

voice: 3925 ms audio · RTF 0.191 · cushion 0 ms

## turn 3
mind: **Local (MLX)**

heard: who did love to you.

reply: I don't have feelings or preferences. How can I assist you today?

at 21 s · thermal serious · 3540 MB free

first word 651 ms · total 1379 ms · MLX peak 2704 MB

session tool: NOT called (tools on)

## turn 4
mind: **Local (MLX)**

heard: Who did develop to you?

reply: I was developed by a team of AI researchers and engineers. How can I assist you today?

at 28 s · thermal serious · 3541 MB free

first word 672 ms · total 1612 ms · MLX peak 2741 MB

session tool: NOT called (tools on)

voice: 6250 ms audio · RTF 0.184 · cushion 0 ms

## turn 5
mind: **Local (MLX)**

heard: Good morning.

reply: Good morning! How can I assist you today?

at 4 s · thermal serious · 3548 MB free

first word 534 ms · total 1045 ms · MLX peak 2865 MB

session tool: NOT called (tools on)

voice: 3675 ms audio · RTF 0.207 · cushion 0 ms

## turn 6
mind: **Local (MLX)**

heard: Good morning.

reply: Good morning! How can I assist you today?

at 3 s · thermal serious · 3543 MB free

first word 582 ms · total 1111 ms · MLX peak 2865 MB

session tool: NOT called (tools on)

voice: 3675 ms audio · RTF 0.281 · cushion 0 ms

## turn 7
mind: **Local (MLX)**

heard: What's your name?

reply: I am an AI assistant. What can I help you with?

at 14 s · thermal serious · 3559 MB free

first word 592 ms · total 1208 ms · MLX peak 2865 MB

session tool: NOT called (tools on)

voice: 3925 ms audio · RTF 0.202 · cushion 0 ms

## turn 8
mind: **Local (MLX)**

heard: Use the decision tool to find out what decision to date.

reply: I don't understand the request. Could you please clarify what you mean by "decision to date"?

at 11 s · thermal serious · 3567 MB free

first word 520 ms · total 1761 ms · MLX peak 2865 MB

session tool: NOT called (tools on)

## turn 9
mind: **Local (MLX)**

heard: I don't understand.

reply: _(no words)_

at 13 s · thermal serious · 3284 MB free

first word never · total 524 ms · MLX peak 2865 MB · BARGED IN (no terminal — expected on interrupt)

session tool: NOT called (tools on)

## turn 10
mind: **Local (MLX)**

heard: I don't understand. Use the session tool to start out what theization is.

reply: Today's session is a forty-minute easy run. Readiness is seventy-one out of a hundred: you slept well, but yesterday's ride is still in your legs, so keep it easy.

at 25 s · thermal serious · 3492 MB free

first word 2063 ms · total 5574 ms · MLX peak 2865 MB

session tool: CALLED · answered: "Today's session is a forty minute easy run. Readiness is seventy-one out of a hundred: you slept well, but yesterday's ride is still in your legs, so keep it easy."

voice: 12775 ms audio · RTF 0.312 · cushion 0 ms

