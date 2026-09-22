# The simulator has no background transfer daemon (5a, piece 6)

**Found by running the demo**, not by reading anything. 2026-09-22, this Mac
(macOS 26.6.1, Xcode 27), iPhone 17 simulator on iOS 26.5, the Models tab's
first tap.

## What happened

Tapping **Download** on *Whisper base* (149 MB) failed instantly, before a
single byte, with the library's own typed failure carrying the system's words:

```
failed: the download of coremldata.bin failed: Error Domain=NSURLErrorDomain
Code=-1 "unknown error" UserInfo={
  NSErrorFailingURLStringKey=https://huggingface.co/argmaxinc/whisperkit-coreml/
    resolve/main/openai_whisper-base/AudioEncoder.mlmodelc/analytics/coremldata.bin,
  _NSURLErrorRelatedURLSessionTaskErrorKey=(
    "BackgroundDownloadTask <84595752-6340-4077-A60F-AEB48E676278>.<1>"
  ),
  NSLocalizedDescription=unknown error}
```

## The two measurements that named the cause

**1. The same URL, a background session, on this Mac** — `hfprobe.swift`, a
plain process, both configurations:

```
background: status 200, 243 bytes, error: none
default:    status 200, 243 bytes, error: none
```

So it is not the URL, not the redirect to the LFS CDN, and not the library's
plan: a background session downloads that exact file fine where a background
daemon exists.

**2. The same download, in the same simulator, on a FOREGROUND session** —
`ModelDownloads.backgroundConfiguration` temporarily returning
`URLSessionConfiguration.default`, everything else untouched:

| step | what the screen showed |
|---|---|
| before the tap | `Whisper base · the ear · 149 MB · not installed` — the size, offline |
| during | `Downloading · 35%` with a byte bar |
| after | `✓ installed` in green, Delete enabled |
| after Delete | `not installed · deleted.` |

The full cycle the milestone promises, on a device, through `any ModelBacked`.

## The ruling this produced

`ModelDownloads.backgroundConfiguration` now returns a **foreground**
configuration under `#if targetEnvironment(simulator)` and the background one
everywhere else. What the simulator loses is stated on that function: a
transfer there dies when the app is suspended — which is the only thing that
platform can do. The alternative was a simulator on which no model can be
downloaded at all, which would make every developer's first run of this
library a failure.

`ModelDownloadsConfigurationTests` pins both halves, per platform.

## What is still owed to the phone (AC-300)

Everything the simulator structurally cannot show, and it is Ryad's gate:

1. Start the mind's 2.2 GB, lock the phone five minutes, unlock — the
   percentage has moved.
2. Kill the app mid-transfer, relaunch, tap again — it continues, and the
   server is asked for a range rather than the whole file.
3. The wake-up: the system relaunches the app in the background when the
   last file lands, and `ModelDownloads.handleEvents` calls the app's
   completion handler once. macOS never sends
   `urlSessionDidFinishEvents(forBackgroundURLSession:)`, so that call has
   never run outside iOS.
