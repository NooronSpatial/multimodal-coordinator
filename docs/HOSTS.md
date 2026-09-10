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
| `huggingface.co` | `MultiModalKitTTS` | the other mouth's CoreML components and its tokenizer (a separate repo, ~1.1 GB + 11 MB) | `NeuralVoice.ensureModel()`, through the vendored speech kit's own hub client. | **Yes.** Pre-install into the two folders `modelInstalled()` checks; asking never fetches (D-078). |
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

**Proven, by test** (`NetworkSilenceTests`):

- No module in `Sources/` names `identifierForVendor`,
  `advertisingIdentifier`, or the keychain. Nothing about the device or
  the person is read, so nothing about them can be sent.
- No module builds a request with a bearer token on it, and none sets
  `httpAdditionalHeaders` on a session.
- The two weight URLs this library holds carry no query string, no user
  info, no password and no fragment. They are `https`, and they name a
  file — nothing else.

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
  host this page does not **declare**. **Add a host without writing it
  down and the suite goes red.** That is the whole of AC-253.
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

| category | what was searched for | found |
|---|---|---|
| file timestamp | `creationDateKey`, `contentModificationDateKey`, `.creationDate`, `.modificationDate`, `getattrlist`, `lstat` | none. The install code reads `attributesOfItem` for **size and type only** |
| disk space | `volumeAvailableCapacity`, `NSFileSystemFreeSize`, `statfs`, `statvfs` | none |
| user defaults | `UserDefaults`, `NSUserDefaults` | none in any library target |
| system boot time | `systemUptime`, `mach_absolute_time` | none. The memory reader uses `task_info` and `os_proc_available_memory`, neither of which is a required-reason API |
| active keyboards | `activeInputModes`, `UITextInputMode` | none. This library has no UI and reads no keyboard |

That table is not prose: the same symbol list lives in
`NetworkSilenceTests`, and it is checked **in both directions**, **per
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

- **The vendored dependencies ship no privacy manifest of their own.**
  The recogniser/mouth kit, the tensor library, the language-model
  library, the hub client and the Kokoro fork carry none. Their library
  targets were searched for the same four categories and only their
  *example apps* matched — but "we grepped it" is weaker than "the vendor
  declared it", and a consumer whose app is rejected for a third-party
  reason should know where to look.
- **These manifests describe this library, not the app.** An app that
  adds analytics, an account, or its own network calls declares those
  itself. Nothing here can speak for that.

---

## The proofs

Every claim on this page is checked by
`Tests/MultiModalKitTests/Diagnostics/NetworkSilenceTests.swift`.

| what is proven | how |
|---|---|
| the recorder is really intercepting | one deliberate request to `localhost` port 1 — the control. Without it, every silence proof below would pass by seeing nothing rather than by nothing happening |
| the recorder is blind to a package's own session | the second control: the same request on a session built the way the vendored hub client builds one, which the recorder must **not** see. This is what bounds AC-252 below |
| an offline install cycle issues zero requests (AC-252) | `installState`, `modelInstalled`, `expectedBytes`, `estimatedWorkingSetBytes`, `readiness` and constructing the generator, over a temporary weights tree |
| a real load-and-generate cycle issues zero requests (AC-252) | gated on `MMK_MLX_MODEL` and the Metal shader library, exactly as this repo's other live tests are |
| every host in `Sources/` is documented (AC-253) | the scanner, over every `.swift` file under `Sources/` |
| the guard actually bites (AC-253) | the scanner is run over hand-written text containing an undocumented host, and must report it |
| no credential, no identifier (AC-254) | the forbidden-symbol list above, and the two weight URLs |
| the credential caveat is not quietly dropped (AC-254) | the test requires this page to name `HF_TOKEN` and the `Authorization` header |
| the manifests exist, are declared, and claim nothing false (AC-255) | each file is parsed as a property list and checked against the source |

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

**What would make AC-252 whole**, named rather than left implicit: a
recorder installed as `configuration.protocolClasses` on a session the
library is handed, which is what `WeightsFetching` (§181 item 3) makes
possible and what this half of 4x cannot do without it.
