<!-- PROBE-R on Ryad's iPhone, 2026-09-29, pasted by Ryad from the demo's share sheet. Raw, unedited below the rule.
     The probe did not record the phone's model or iOS version; its share text now does (the same PR). -->

# PROBE-R — the reply retry's vendor fact (5b §213, F-18)

availability: available
prompt: Log 84 kilos, please.
caveat: main actor of an idle app — the counts are solid, the times indicative

## trial 1
- 1 · fails after the tool: bodies run 1 · from record 0 · no word · total 3921 ms
  threw: ToolCallError(tool: TranscribeDemo.ProbeLogWeight(name: "log_weight", description: "Records the person\'s weight, in kilograms, in their log.", ledger: TranscribeDemo.RetryLedger), underlyingError: PROBE-R: the turn failed on purpose, right after the tool ran)
- A · replay: bodies run 0 · from record 1 · first word 6714 ms · total 7362 ms
  said: Your weight has been logged successfully.
- B · seeded, same words: bodies run 0 · from record 0 · first word 3015 ms · total 4487 ms
  said: I already logged 84 kilos. Is there anything else you need help with?
- C · seeded, empty prompt: bodies run 0 · from record 0 · first word 2791 ms · total 3986 ms
  said: I have successfully logged your weight of 84 kg.

## trial 2
- 1 · fails after the tool: bodies run 1 · from record 0 · no word · total 2191 ms
  threw: ToolCallError(tool: TranscribeDemo.ProbeLogWeight(name: "log_weight", description: "Records the person\'s weight, in kilograms, in their log.", ledger: TranscribeDemo.RetryLedger), underlyingError: PROBE-R: the turn failed on purpose, right after the tool ran)
- A · replay: bodies run 0 · from record 1 · first word 2831 ms · total 2910 ms
  said: I have successfully logged your weight of 84 kg.
- B · seeded, same words: bodies run 0 · from record 1 · first word 956 ms · total 1006 ms
  said: I have already logged 84 kilos.
- C · seeded, empty prompt: bodies run 0 · from record 0 · first word 681 ms · total 737 ms
  said: I have successfully logged 84 kg.

## trial 3
- 1 · fails after the tool: bodies run 1 · from record 0 · no word · total 682 ms
  threw: ToolCallError(tool: TranscribeDemo.ProbeLogWeight(name: "log_weight", description: "Records the person\'s weight, in kilograms, in their log.", ledger: TranscribeDemo.RetryLedger), underlyingError: PROBE-R: the turn failed on purpose, right after the tool ran)
- A · replay: bodies run 0 · from record 1 · first word 1368 ms · total 1484 ms
  said: I have logged your weight of 84 kg.
- B · seeded, same words: bodies run 0 · from record 1 · first word 1231 ms · total 1294 ms
  said: I have already logged 84 kilos.
- C · seeded, empty prompt: bodies run 0 · from record 0 · first word 683 ms · total 733 ms
  said: I have logged your weight.

VERDICT this run: F-18 A held in 3 of 3 trials — no body ran twice, and a reply was written every time.
