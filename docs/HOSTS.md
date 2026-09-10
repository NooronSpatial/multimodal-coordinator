# What leaves this device (4x)

This is the page a caller reads before shipping this library in an app.
It answers three questions and nothing else:

1. **Which hosts can this library contact?** Every one, by name.
2. **What makes it contact them?** The exact call, and how to avoid it.
3. **What does a request carry about the person using the app?**

**The short codes**, all of which point at files in this repo. `D-nnn` is
a ruling in [DECISIONS.md](../DECISIONS.md). `AC-nnn` is a numbered
acceptance criterion and `§nnn` a section, both in [SPEC.md](../SPEC.md).
`F-n = A` names one of milestone 4x's design forks and the option Ryad
chose on it. `4x` is this milestone.

**The one-sentence answer**, and the rest of the page is the evidence:
this library contacts **exactly one host family — `huggingface.co` — and
only while it is downloading model weights.** Once the weights are on
disk, listening, thinking and speaking issue no requests at all.

**That sentence was UNTRUE when this page was first written, and 4x's own
recorder is what caught it.** With the neural voice's model already
installed, opening an utterance fired six requests to
`huggingface.co/api/models/Qwen/Qwen3-0.6B/revision/main` — a revision
check, on the speaking path, with the weights on disk. It is the ear's
old bug (the field note below) living on in the second mouth, and it was
fixed the same way: `NeuralVoice.loadedPipeline()` now names its local
model folder **and** its local tokenizer folder, so a load with the
weights present reads the disk and stops. The sentence above is true of
the code as it stands, and
`a REAL neural-voice load with the model on disk issues ZERO requests`
is the test that keeps it true. The story is kept here rather than tidied
away because a page a caller quotes to a person is worth exactly as much
as its worst sentence.

---

## The hosts

```
 WHAT A PERSON DOES                 WHAT THE LIBRARY DOES
 ──────────────────                 ─────────────────────
 taps "download the model"  ──────► huggingface.co        the ONLY host
                                      · mind weights        this library
                                      · ear weights         ever reaches
                                      · mouth weights
 speaks, listens, is answered ────►  nothing. no request. (AC-252)

 taps "use the built-in voice" ───► the operating system's own asset
                                    service, out of this process
                                    (Apple's speech models; no URL here)
```

| host | module | what it fetches | what triggers it | can a caller avoid it? |
|---|---|---|---|---|
| `huggingface.co` | `MultiModalKitMLX` | the mind's weights, tokenizer and config (~2.3 GB for the shipped model) | `LocalMindModel.download(reporting:)` — and **only** on a model built with `init(repoID:in:)`. | **Yes.** `LocalMindModel(weights:)` has no repo id at all: it never downloads, and `download` throws `.weightsAbsent` rather than guessing where to look. |
| `huggingface.co` | `MultiModalKitTTS` | Kokoro's weights (`kokoro-v1_0.safetensors`, 327,115,152 bytes) and one voice (`af_heart.safetensors`, 522,339 bytes) | `KokoroWeights.ensure(progress:)`. These are the only two URL literals in `Sources/`. | **Yes.** Place both files in the directory by hand; `isInstalled()` checks name *and* exact byte count, and `ensure()` then downloads nothing. |
| `huggingface.co` | `MultiModalKitTTS` | the other mouth's CoreML components and its tokenizer (a separate repo, ~1.1 GB + 11 MB) | `NeuralVoice.ensureModel()`, through the vendored speech kit's own hub client. | **Yes.** Pre-install into the two folders `modelInstalled()` checks; asking never fetches (D-078), and since 4x **loading** never fetches either — see the second field note below. |
| `huggingface.co` | `MultiModalKitWhisper` | the ear's CoreML model and its tokenizer (~142 MB for `base`) | `WhisperEngine.ensureModel()`, through the vendored recogniser's own hub client. | **Yes.** Pre-install. And see the field note below: once installed, the pipeline load is pinned to the local folder so it does **not** ping for a revision. |
| Apple's OS asset service | `MultiModalKit` | the built-in speech recogniser's model for a locale | `AssetInventory.assetInstallationRequest` inside `AppleSpeechEngine`, when the locale's model is absent. | **Partly.** The download is the OS's, not this process's — no URL exists in this repo to point elsewhere. A caller that never constructs the Apple ear never reaches it. |

### The field note that is worth more than the table

The Whisper ear's load used to ping `huggingface.co` on **every** pipeline
load, even with the model already on disk — a revision check. It was
found in airplane mode, not in a code review, and the fix is the comment
that now sits on `WhisperEngine.loadedPipeline()`: naming
`config.modelFolder` makes the load local and silent. **The on-device
promise applies to STARTUP, not only to transcription.** That bug is the
reason AC-252 exists as a test rather than a paragraph.

### The same bug, found again in the second mouth (4x)

The fix above was applied to the ear and not to the mouth. 4x's review
armed this milestone's recorder around a neural-voice load with the model
already installed and got six requests to
`huggingface.co/api/models/Qwen/Qwen3-0.6B/revision/main`. The mouth's
weights were pinned by nobody, and its **tokenizer** — a different repo
entirely — was named by repo id, which TTSKit resolves as
`tokenizerFolder?.path ?? model.tokenizerRepo`. A repo id means the hub.

`NeuralVoice.loadedPipeline()` now hands the kit both folders, and only
when `modelInstalled()` says all six compiled components and both
tokenizer files are really there, so a machine with nothing still gets
its download. Two lessons worth keeping: **a fix applied to one engine is
not applied to the other**, and **a model folder is not the whole
install** — the tokenizer beside it is its own trip to the network.

### Named in the binary, never called by this library

These hosts are reachable in code that is linked into an app, and nothing
in this package ever calls the code that reaches them. They are listed
because "we never call it" is a claim a reader should be able to check,
not a claim they should have to take on trust.

| host | where | why it is never reached |
|---|---|---|
| `router.huggingface.co` | the vendored hub package's inference client, linked in through `Hub` | this library runs models **on the device**. It has no inference client, sends no prompt anywhere, and names none of those types. |
| `localhost` | the speech kit's own CLI server and its example clients | a default bind address in an executable target and in example projects. This package links neither. It is also the address this repo's own control test dials (`localhost` port 1), which is test code, never a product. |
| `hf-mirror.com` | the hub package's own test suite | test code; never linked into a product. |
| `www.apple.com` | the `DOCTYPE` line of every `PrivacyInfo.xcprivacy` in this repo | an XML *identifier*, not an address. Property-list parsers resolve it from a local catalogue and never fetch it — the same line appears in every plist Apple's own tools write. |

A caller who wants proof rather than a promise can read the `Sources/`
tree: `MultiModalKitMLX` contains **no URL literal at all** — see
"Why this list is written by hand" below.

**What this table is about, exactly.** It lists hosts a RUNNING app can
reach. `Package.swift` carries five `https://github.com/…` literals, and
`github.com` is deliberately absent above: those are resolved by the
build system on a developer's machine before an app exists, and no
shipped binary contains them. The scanner's scope is `Sources/` for the
same reason.

---

## What a request carries

`AC-254` asks whether the weight fetch carries a user identifier or a
credential. The answer has a proven half and an argued half, and mixing
them would be exactly the dishonesty this repo exists to avoid.

**Proven, by test** (`PrivacyContractTests.swift`, with the rule itself in
`PrivacyRules.swift`):

- No module in `Sources/` names `identifierForVendor`,
  `advertisingIdentifier`, or the keychain. Nothing about the device or
  the person is read, so nothing about them can be sent.
- No `.swift` file under `Sources/` names the header field
  `"Authorization"`, `"Proxy-Authorization"` or `"Cookie"`, sets
  `httpAdditionalHeaders`, or names the hub clients' own token arguments
  (`hfToken`, `HF_TOKEN`). This library sets **no request header at all**,
  which is what makes so strict a rule affordable.
- The two weight URLs this library holds carry no query string, no user
  info, no password and no fragment. They are `https`, and they name a
  file — nothing else.

**What that scan can and cannot see**, because the first version of this
page claimed more than it delivered. It matched only a `Bearer` written as
a string *literal* inside `setValue`/`addValue`, so the ordinary two-line
form — hoist the value into a variable, then set it — attached a
credential with the test green. Naming the header **field** instead of the
value fixes that case. It still cannot see a header name assembled at run
time (`"Author" + "ization"`, an interpolation, a constant from a
dependency), exactly as the host scanner cannot see an assembled host.
This is a guard against a change made in the open, not a proof against a
change made in hiding — and `the credential scan reports a credential
attached the ordinary way` is where the rule is shown to bite over
hand-written text rather than only over a tree that has never had a
credential in it.

**Argued, by reading the fetch path — the one caveat.**

**Three of the four weight fetches can carry a developer's token, not
one.** The first version of this page said the caveat was the mind's
alone and cleared "the other three"; a review of the vendored sources
proved that wrong, and the correction is worth more than the original
claim was.

There are two vendored hub clients, and they behave identically here.
The mind's weights go through one; the ear's and the second mouth's go
through the other, by way of the speech kit's `ModelDownloader`. Both
are constructed by this library with **no** token — `HubApi(downloadBase:
into)` for the mind, and a `modelToken` this package never sets for the
other two. And for both clients, "no token given" does not mean "no
authentication": it means *resolve one from the environment*. In their
documented order they look at the `HF_TOKEN` environment variable, then
`HUGGING_FACE_HUB_TOKEN`, then a token file named by `HF_TOKEN_PATH`,
then `$HF_HOME/token`, then `~/.cache/huggingface/token`, then
`~/.huggingface/token`. If one is found, it goes on the request as an
`Authorization: Bearer …` header.

Which fetch is which, declared so a test can check it rather than trust
the paragraph above:

```token-bearing
the mind
the ear
the second mouth
```

```header-free
kokoro
```

Kokoro's is the only fetch with no hub client behind it: it is a plain
`URLSession.shared.download` of a named file, with no headers of its own.

What that means, plainly:

- **On a person's phone this cannot happen.** An app sandbox has no
  `HF_TOKEN` environment variable and no `~/.cache/huggingface/token`.
  There is nothing for the client to find.
- **On a developer's Mac it can.** If you have signed in with the hub's
  command-line tool, the download from *your* machine carries *your*
  token. That is your credential, never the app user's — but it is a
  credential, and this page will not pretend otherwise.
- **This library cannot currently switch it off.** Both vendored hub
  clients accept a token to *use*; neither exposes a way to demand
  *none*. Forcing it would mean reaching past them to the underlying
  session — a change to `LocalMindInstall.swift` and to the two
  `ensureModel()` paths, and a fork worth ruling rather than a line worth
  sneaking in. **Reported here, not decided.** It is now three call sites
  rather than one, which makes the fork bigger, not smaller.

---

## Why this list is written by hand

A generated list would be wrong, and the test proves it: the single most
important host in this library appears in **no source literal at all**.
`Sources/MultiModalKitMLX/LocalMindInstall.swift` reaches
`huggingface.co` on every weight download and never writes the name — the
host is the vendored client's default. A `grep` for `https://` over
`Sources/` finds only the two Kokoro URLs and would have called this
library's largest download invisible.

So the document is the source of truth and the test is the guard, not the
other way round:

- `every host in Sources/ is named in docs/HOSTS.md` — scans every
  `.swift` file under `Sources/`, comments included, and fails naming any
  host this page does not **declare**. **Write a host as a full
  `http(s)://…` literal in a `.swift` file under `Sources/` without
  declaring it below, and the suite goes red.**
- **What the scanner cannot see**, stated because the sentence above used
  to be an unqualified absolute. Only a full URL literal is found. A host
  assembled by interpolation (`"https://\(region).telemetry.test/v1"`),
  by concatenation (`"https://" + host`), by `URLComponents` (`c.host =
  "telemetry.test"`) or written scheme-relative (`//telemetry.test/v1`)
  is invisible to it. That is not a bug to be fixed by a cleverer parser:
  it is the same reason this list is written by hand and reviewed rather
  than generated. The scanner is a guard against a host added in the
  open, and the review is the guard against the rest.
- A host that only ever appears in a comment still belongs here, under
  "named in the binary, never called": a host a reader believes the
  library can reach is a host the reader should be able to look up.

### The list, declared

The tables above are for people. This block is for the test, and it is
the list the scanner matches against — **whole names, one per line**:

```hosts
huggingface.co
router.huggingface.co
hf-mirror.com
localhost
www.apple.com
```

**And the other direction**, added in 4x's review because an allowlist
that only ever grows is not an allowlist. Four of the five entries above
are named by nothing the scanner reads — they come from the tables of
code that is *linked but never called*. So each of those is declared here
too, and the test requires the two blocks to agree: a declared host that
`Sources/` does not name must appear below, and a host listed below must
be declared above. Deleting the call site that justifies an entry, or
adding an entry with no justification, now shows up.

```hosts-never-called
router.huggingface.co
hf-mirror.com
localhost
www.apple.com
```

**Why a block and not the prose**, both reasons found by review rather
than by design:

1. The check used to ask "does the page contain this string?". A brand
   new `gingface.co` was therefore already "documented" — it is a
   substring of the `huggingface.co` on this page. A new host could hide
   inside an old one.
2. The scanner used to walk characters to a stop set that held `:` but
   not `@`, so `https://user:pw@somewhere.test/` was read as the host
   `user` — which this page's own words ("no **user** info", "**user**
   defaults") then "documented". A URL carrying a password could be added
   to `Sources/` and AC-253 stayed green.

The scanner now parses with `URLComponents`, which knows where a host
ends and strips user info, port, query and fragment, and it compares
against the lines above by whole-name equality.

---

## The privacy manifests (AC-255, F-4 = A)

Ryad ruled F-4 = A: **ship `PrivacyInfo.xcprivacy` per module**, so a
consumer inherits the declaration and the App Store question answers
itself, instead of every caller re-deriving it forever (D-106).

Six library products can be linked, so there are six manifests, one per
target, each declared in `Package.swift` as
`.copy("PrivacyInfo.xcprivacy")`. A manifest that is not declared as a
resource never reaches the consumer's app — it is a file in a folder —
so the test checks the declaration as well as the file.

| module | what its manifest declares |
|---|---|
| `MultiModalKit` | no tracking · no data collected · no tracking domains · **no** required-reason API |
| `MultiModalKitMLX` | the same |
| `MultiModalKitWhisper` | the same |
| `MultiModalKitTTS` | the same |
| `MultiModalKitTesting` | the same |
| `MultiModalKitBench` | the same |

**Why "no data collected" is true and not merely convenient.** This
library has no analytics, no crash reporter, no logging destination off
the device, and no server of its own. Audio, transcripts and replies are
values that live in memory and in the caller's own storage. The only
bytes that cross the network move in one direction: model weights coming
*down*.

**Why no required-reason API is declared.** Apple's five common
categories were checked against the source, symbol by symbol, rather than
guessed — because *a manifest claiming a reason the code does not use is
as wrong as a missing one*. It is an untrue statement filed with a store.

The strings below are quoted **verbatim** from `PackageOnDisk.triggers`
in `Tests/MultiModalKitTests/Diagnostics/PrivacyRules.swift`. That matters
after 4x's review: the table used to print the bare type name
`UserDefaults` while the code searched `UserDefaults(` and
`UserDefaults.standard`, so a reader auditing this guard was told a
stricter search ran than really runs.

| category | what was searched for (verbatim) | found |
|---|---|---|
| file timestamp | `creationDateKey`, `contentModificationDateKey`, `attributeModificationDateKey`, `.creationDate`, `.modificationDate`, `NSFileCreationDate`, `NSFileModificationDate`, `getattrlist`, `fstatat(`, `lstat(`, `fstat(` | none. The install code reads `attributesOfItem` for **size and type only** |
| disk space | `volumeAvailableCapacity`, `volumeTotalCapacity`, `NSFileSystemFreeSize`, `NSFileSystemSize`, `systemFreeSize`, `statfs(`, `statvfs(` | none |
| user defaults | `UserDefaults(`, `UserDefaults.standard`, `NSUserDefaults`, `AppStorage` | none in any library target |
| system boot time | `systemUptime`, `mach_absolute_time` | none. The memory reader uses `task_info` and `os_proc_available_memory`, neither of which is a required-reason API |
| active keyboards | `activeInputModes`, `UITextInputMode` | none. This library has no UI and reads no keyboard |

**Why the strings are narrower than the type names.** `UserDefaults(` and
`UserDefaults.standard`, not `UserDefaults`, so a doc comment that
*mentions* the API is not read as a call to it — the wide form was tried
in review and turned `MultiModalKitBench` red over the sentence "every
lever in the demo writes to `UserDefaults`" in
`Sources/MultiModalKitBench/BenchStage.swift`. `AppStorage` is on the list
because `@AppStorage` is the commonest SwiftUI route into user defaults
and a target adding it would otherwise ship an untrue manifest. And bare
`stat(` is deliberately **absent**: it is a substring of `statfs(` and
`statvfs(`, which belong to the disk-space row, so it would demand the
wrong category for a correct call. `fstat(`, `fstatat(` and `lstat(`
carry that family without the collision.

That table is not prose: the same symbol list lives in
`Tests/MultiModalKitTests/Diagnostics/PrivacyRules.swift`, and
`PrivacyContractTests.swift` checks it **in both directions**, **per
module**, on every run. A module may not declare a category its own
source never calls, and its source may not start calling one without
that module's manifest being updated and this page being rewritten.

**The first version got the second direction backwards**, and 4x's review
caught it: it asserted that `Sources/` names no required-reason API *at
all*, whatever the manifests declared. So a module that did the correct
thing — call the API **and** declare the category — still turned the
suite red, and the failure message told the developer to declare what
they had already declared. A guard that punishes the correct state is
worse than no guard, because it teaches people to delete it.

### What a consumer still has to do themselves

Being honest about the edge of what this repo can answer:

- **The five packages this library depends on directly ship no privacy
  manifest of their own.** The recogniser/mouth kit, the tensor library,
  the language-model library, the hub client and the Kokoro fork carry
  none. Two packages linked *transitively* do carry one — swift-crypto
  (seven files) and ZIPFoundation (one) — so the sentence is about the
  five named, not about the whole dependency tree. Their library targets
  were searched for the same **five** categories, and the only match
  outside an example app is `.contentModificationDateKey` in `mlx-swift`'s
  `Source/Encuda` (`encuda-compile.swift` and `encuda-link.swift`), which
  is an `executableTarget` behind a build-tool plugin: it runs on a
  developer's machine and is never linked into an app. But "we grepped
  it" is weaker than "the vendor declared it", and a consumer whose app
  is rejected for a third-party reason should know where to look.
- **These manifests describe this library, not the app.** An app that
  adds analytics, an account, or its own network calls declares those
  itself. Nothing here can speak for that.

---

## The proofs

Every claim on this page is checked by three files, all in
`Tests/MultiModalKitTests/Diagnostics/`:

- `NetworkSilenceTests.swift` — AC-252 only: the recorder, its three
  controls and the silence proofs.
- `PrivacyContractTests.swift` — AC-253, AC-254 and AC-255: the host
  list, the credential scan and the six privacy manifests.
- `PrivacyRules.swift` — the rules themselves, as pure types
  (`SourceHostScanner`, `CredentialScan`, `RequiredReasonCheck`,
  `ManifestDeclarations`) plus `PackageOnDisk`, the one reader for this
  repository's own files.

**This page used to name only the first file**, for every row below,
because the tests were split into three and every cross-reference was
left behind — on this page, and inside all six shipped
`PrivacyInfo.xcprivacy` files, which are copied into a consumer's app
bundle, so the wrong pointer shipped. A reader following the page to audit AC-254 opened
`NetworkSilenceTests.swift` and found no credential check in it. So the
mapping is no longer prose: the block below is machine-checked by
`the proofs block names the file each check lives in`, which fails if a
named test is not defined in the file named beside it. A split cannot
drift silently again.

```proofs
theRecorderIsReallyIntercepting NetworkSilenceTests.swift
anUnmarkedRequestIsWatchedButNeverFailed NetworkSilenceTests.swift
theRecorderIsBlindToACustomDefaultSession NetworkSilenceTests.swift
askingAboutAnInstallIssuesNoRequest NetworkSilenceTests.swift
aRealVoiceLoadIssuesNoRequest NetworkSilenceTests.swift
aRealReplyIssuesNoRequest NetworkSilenceTests.swift
theListStatesWhatTheRecorderCannotSee NetworkSilenceTests.swift
everyHostInSourceIsDocumented PrivacyContractTests.swift
anUndocumentedHostIsReported PrivacyContractTests.swift
theListNamesTheHubNoLiteralNames PrivacyContractTests.swift
theDeclaredHostsAgreeWithTheSource PrivacyContractTests.swift
theWeightURLsSayNothingAboutTheCaller PrivacyContractTests.swift
theLibrarySuppliesNoCredentialAndReadsNoIdentifier PrivacyContractTests.swift
anAttachedCredentialIsReported PrivacyContractTests.swift
theListStatesTheCredentialCaveat PrivacyContractTests.swift
everyLinkedModuleShipsAManifest PrivacyContractTests.swift
noManifestClaimsAReasonTheCodeDoesNotUse PrivacyContractTests.swift
aDeclaredCategoryInUseIsNotAComplaint PrivacyContractTests.swift
aNewLibraryProductWithoutAManifestIsNamed PrivacyContractTests.swift
```

| what is proven | how | where |
|---|---|---|
| the recorder is really intercepting | one deliberate MARKED request to `localhost` port 1 — the control. Without it, every silence proof below would pass by seeing nothing rather than by nothing happening. The error is checked too: the recorder must have *claimed* the request, not merely logged it | `NetworkSilenceTests.swift` |
| the recorder never breaks another test | an UNMARKED request to `localhost` port 1 must be watched and waved through. This is the poisoning proof — see "what AC-252 does not prove" below | `NetworkSilenceTests.swift` |
| the recorder is blind to a package's own session | the same request on a session built the way the vendored hub client builds one, which the recorder must **not** see. This is what bounds AC-252 | `NetworkSilenceTests.swift` |
| an offline install cycle issues zero requests (AC-252) | `installState`, `modelInstalled`, `expectedBytes`, `estimatedWorkingSetBytes`, `readiness` and constructing the generator, over a temporary weights tree | `NetworkSilenceTests.swift` |
| a real neural-voice load issues zero requests (AC-252) | gated on the model being on this machine's disk; this is the guard on the headline sentence at the top of this page | `NetworkSilenceTests.swift` |
| a real load-and-generate cycle issues zero requests (AC-252) | gated on `MMK_MLX_MODEL` and the Metal shader library, exactly as this repo's other live tests are | `NetworkSilenceTests.swift` |
| every host in `Sources/` is documented (AC-253) | the scanner, over every `.swift` file under `Sources/` | `PrivacyContractTests.swift` |
| the guard actually bites (AC-253) | the scanner is run over hand-written text containing an undocumented host, and must report it | `PrivacyContractTests.swift` |
| the declared list does not grow silently (AC-253) | every declared host that `Sources/` does not name must be declared again under `hosts-never-called`, and vice versa | `PrivacyContractTests.swift` |
| no credential, no identifier (AC-254) | `CredentialScan` over `Sources/`, and the two weight URLs | `PrivacyContractTests.swift` |
| that credential rule actually bites (AC-254) | the scan is run over hand-written source that attaches a credential the ordinary way — the form the first version missed | `PrivacyContractTests.swift` |
| the credential caveat is not quietly dropped (AC-254) | the test requires this page to name `HF_TOKEN`, `HUGGING_FACE_HUB_TOKEN` and the `Authorization` header, and to declare which fetches can carry one | `PrivacyContractTests.swift` |
| the manifests exist, are declared, and claim nothing false (AC-255) | each file is parsed as a property list and checked against the source, per module | `PrivacyContractTests.swift` |
| this table points at the file each check really lives in | the `proofs` block above, read by a test | `PrivacyContractTests.swift` |

### What AC-252 does NOT prove

**`URLProtocol.registerClass` reaches `URLSession.shared`, and nothing
else.** It is **not** consulted by a session a package builds for itself
— not even one built on a **default** configuration. The first version of
this page claimed the wider reach and rested "both weight fetches are
watched" on it. That was wrong, it was measured rather than argued, and
the measurement is now a test of its own
(`theRecorderIsBlindToACustomDefaultSession`): one request on a custom
`.default` session, and the recorder must **not** have seen it.

What the recorder therefore watches, and what it misses:

| fetch | session it runs on | seen? |
|---|---|---|
| Kokoro's weights and voice | `URLSession.shared.download` | **yes** |
| either hub client's `httpGet` metadata call | `URLSession.shared` | **yes** |
| the mind's ~2.3 GB snapshot | the hub client's own `.default` session | no |
| the ear's and the second mouth's models | the speech kit's own `.default` session | no |
| either hub client's `HEAD` metadata call | a `.default` session with a redirect delegate | no |

That split matters for the field note above: the Whisper revision-check
bug lived in the `httpGet`/`HEAD` metadata family, and the `httpGet` half
of it **is** watched. The 2.3 GB download itself is not, and this page
will not pretend it is.

It also does not see:

- a raw BSD socket, or a `Network.framework` connection;
- a session built with an **ephemeral** or **background** configuration;
- anything a system daemon does out-of-process on the app's behalf —
  which includes the OS speech-model download in the table above.

So a green run means *"no request left through `URLSession.shared`"* —
not through a session a package builds for itself, and never *"no byte
left this device"*. A caller who needs the stronger claim should watch
the device with a network monitor, which is a measurement, not a unit
test — and measurements in this project belong in `INSTRUMENTS.md`.

### The one thing the recorder must never do, and the one it still can

`URLProtocol.registerClass` is **process-global**. The first version of
the silence suite therefore claimed and failed *every* request in the
process while it was armed, and 4x's review caught that doing real
damage on a clean tree: a neural-voice load running in another suite died
with this suite's own refusal error, and in the same run the silence
proof went red on six requests it had never issued. A test that breaks
other tests is worse than no test.

- **Fixed, by construction.** The recorder now fails a request only when
  the request carries the marker header that this suite puts on its own
  probes. Everything else is watched and waved through, exactly as it
  would be with no recorder in the process. `an unmarked request is
  watched but NEVER failed by the recorder` breaks that rule on purpose
  to show it holds.
- **The price, paid openly.** The old recorder *killed* a leaking
  request; this one only watches it. So on the day a silence proof goes
  red for a real regression, the request it names really did leave
  through `URLSession.shared` — the run reports it, it does not prevent
  it. That is the cost of not being allowed to kill anybody else's
  request, and it is the right way round: this suite's job is to tell the
  truth about what left the device, not to lie to its neighbours while
  doing it.
- **Not fixed, and named rather than discovered.** The recorder is still
  *offered* every request in the process, and the silence proofs read
  what it overheard — they must, because a leak from the code under test
  arrives unmarked exactly as a neighbour's request does. So a suite
  running in parallel that really issues a request makes the silence
  proof go **red**. That direction is the safe one: a loud false alarm
  that names the URLs it saw, never a quiet false pass. Removing even
  that means running the whole package's tests serially
  (`swift test --no-parallel`), which is a CI decision, or moving AC-252
  onto a session the library is handed, which is `WeightsFetching`
  (§181 item 3) and has not landed.

The one source of overheard traffic this repo actually had is gone: the
neural voice's load is pinned to its local folders, as the ear's already
was.

**What would make AC-252 whole**, named rather than left implicit: a
recorder installed as `configuration.protocolClasses` on a session the
library is handed, which is what `WeightsFetching` (§181 item 3) makes
possible and what this half of 4x cannot do without it.
