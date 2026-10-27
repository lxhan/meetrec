# MeetRec

Local macOS menu-bar recorder for microphone + system audio. No cloud, account,
bot, analytics, network client, or third-party Swift dependencies.

Independently maintained for reliable local call recording. No upstream-sync
commitment. **Use this repository's source; releases from other repositories do
not contain these safety changes.**

## Build and use

Requires macOS 14.2+ and Xcode 15+/Swift 5.9+ (tested locally with Swift 6.2.4).

```bash
git clone https://github.com/lxhan/meetrec.git
cd meetrec
swift test
./make-app.sh
open MeetRec.app
```

Build creates `MeetRec.app` locally; it does not install, launch, kill an existing
recorder, select a keychain signing identity, or reset permissions. Quit/save any
running instance before rebuilding. Default signing is ad-hoc with hardened
runtime and microphone entitlement; it is **not notarized or sandboxed**.

For stable signing across rebuilds, explicitly select your own identity:

```bash
./make-app.sh --sign 'Apple Development: Your Name (TEAMID)'
```

Ad-hoc rebuilds may require re-granting permissions. App-specific TCC reset is an
explicit last resort, never a default build side effect:

```bash
./make-app.sh --reset-permissions
```

On launch, grant **Microphone** and **Screen Recording** when requested. macOS
uses Screen Recording permission for ScreenCaptureKit system audio; no video is
saved. Relaunch guidance is provided. Keep `com.local.meetrec` bundle identity
stable. Do not grant additional permissions or disable system security globally.

Click menu-bar icon → **Start Recording**. **Stop & Reveal** saves and reveals the
file. Quit/relaunch also stops capture and awaits file finalization, including if
startup is still in progress. Start fails rather than silently recording mic-only.
Runtime capture/encoder errors stop recording and remain visible in menu bar/UI.
Hardware shutdown has a deadline: if an OS audio call hangs, file delivery is
fenced, output is finalized, and a persistent warning requires quit/relaunch.
Capture may remain active until quitting in that exceptional case.

| Shortcut | Action |
|---|---|
| `⌥⌘R` | Start/stop |
| `⌥⌘M` | Toggle microphone in saved mix |
| `⌥⌘S` | Toggle system audio in saved mix |

## Interrupted-call recovery

While recording, a private write-ahead journal stores the post-mute mixed audio
in one-minute PCM parts under `~/Recordings/MeetRec/.recovery/`. It checkpoints to
disk roughly every second and is independent of AAC finalization.

- Normal stop verifies and syncs the final `.m4a`, then removes its journal.
- After a crash/force-kill, next launch automatically exports available audio as
  `Recovered_UUID.caf` in the recording folder. Core Audio File playback is supported
  by macOS and VLC; recovered files are uncompressed, not AAC.
- **Recover Interrupted Calls** retries exports after a failure without restarting.
- Live sessions are locked and skipped; failed exports retain original segments.
- Temporary journal uses about **0.7 GB/hour**, plus compressed recording. Recovery
  temporarily needs enough extra disk space for another uncompressed copy.
- Audio still in device/application buffers can be lost on abrupt termination.
  Disk flushes reduce power-loss exposure, but are not a guarantee against hardware
  failure or filesystem corruption. Real-device/power-loss testing remains necessary.

## Files and privacy

Recordings go to:

```
~/Recordings/MeetRec/YYYY-MM-DD_HHmmss_UUID.m4a
```

- Unique filenames; existing recordings are never deleted to start a new one.
- App recording directory is owner-only (`0700`); saved audio is `0600`.
- AAC 128 kbps, 48 kHz, dual-mono: both channels contain the same mix.
- Microphone tries voice processing (echo cancellation/noise reduction/AGC),
  falling back to plain capture if initialization fails or no buffers arrive.
- **System capture includes other audible applications**, not just meeting app.
- **Mute excludes samples from file, not device capture.** Stop recording to stop
  capture. The meter is hidden for muted channels; this is not a hardware mute.
- Files are not app-encrypted. Other software running as your user, backups, or a
  synced/custom filesystem location may access them. Use FileVault where appropriate.
- No plaintext diagnostic log is created. Opt-in diagnostics use OS-managed
  unified logging with private fields:

```bash
defaults write com.local.meetrec DiagnosticsEnabled -bool true
# Disable after troubleshooting:
defaults delete com.local.meetrec DiagnosticsEnabled
```

Optional microphone settings (restart app after changing):

```bash
defaults write com.local.meetrec MicGainDb -float 6  # clamped to -60…24 dB
defaults write com.local.meetrec DisableAEC -bool true
```

Obtain participant consent where required. For transcription, use a separate local
tool; uploading recordings to external services is outside MeetRec's local-only design.

## Recording safety

- Unique recording names; refusal to overwrite existing files/symlinks.
- Explicit starting/recording/stopping/failed lifecycle; idempotent shutdown.
- Capture-delivery fences, bounded hardware shutdown, and full buffered-tail drain
  before file finalization; stuck devices require restart instead of hanging saves.
- Source/encoder failures propagated to persistent UI error state; no false save success.
- Write-ahead audio journal, locked sessions, automatic crash recovery, verified
  export before source deletion, and encoder-finalization deadline.
- Timestamp-indexed bounded rings, shared host-clock timing, catch-up draining,
  bounded pending capture submissions and encoder readiness timeout.
- Complete packet-aware sample conversion and resampler-tail flushing, including
  converter-delay compensation on the host-clock timeline.
- Queue-serialized mute state; borrowed capture buffers copied before queueing;
  stale-session callbacks cannot stop a new recording.
- Native `NSStatusItem`/`NSPopover`, inspired by upstream PR #3, without changing
  bundle ID as a workaround. Hotkeys register at launch, not only after opening UI.
- Relaunch uses argument-array `open`, never interpolated shell code.
- Private storage, opt-in private diagnostics, explicit signing/TCC build options.
- Automated regression tests and macOS CI.

## Verification

```bash
swift test -Xswiftc -warnings-as-errors
swift test --sanitize=thread
./make-app.sh
codesign --verify --deep --strict MeetRec.app
```

Tests use fake capture devices and synthetic PCM; they do not request microphone
or screen permission. Coverage includes file collisions, symlinks/permissions,
start/stop races, shutdown during startup, stale callbacks, capture/writer failure,
ring wrapping/gaps/overflow, concurrent mute/submission, shutdown deadlines,
late hardware completion, full encoded tail, journal rotation, truncated writes,
recovery locking, exact recovered samples, and actual SIGKILL of a journal writer.

**Not yet validated:** real call audio quality, AirPods/device changes, long-call
clock behavior, sleep/wake, and recent macOS menu-bar behavior. See
[manual smoke-test checklist](docs/testing.md).

### Remaining limitations

- No pause/resume, app/device selector, separate source tracks, or transcription.
- Interrupted AAC files may remain unplayable; recovery exports journal audio as
  `.caf` instead. Buffered, not-yet-journaled audio and catastrophic disk failures
  remain outside recovery guarantees. Keep a backup for important meetings.
- System audio silence can legitimately omit buffers; stream errors are reported,
  but absence alone does not prove failure. Microphone uses buffer liveness, not
  signal volume, to detect interruptions.
- Input-device switching does not automatically follow new default; output changes
  remain hardware-dependent. Long interruptions/overload fail explicitly rather
  than allocating unbounded memory or hiding gaps.
- Neither notarization nor reproducible source/binary equivalence is established.

## License

MIT; original attribution retained in [LICENSE](LICENSE).
Originally based on [BozhengLong/meetrec](https://github.com/BozhengLong/meetrec)
commit `f98e39b`.
