# Manual smoke tests (real-device validation still required)

Automated tests use synthetic PCM and fake devices only. Do not claim real audio
capture, echo-cancellation quality, macOS permission behavior, or OS-specific UI
compatibility from a passing unit test suite.

Use non-sensitive audio and obtain any required recording consent.

- [ ] Build app, inspect signature/entitlements, launch; icon visible and process stays alive.
- [ ] Before opening popover, use record hotkey; it works immediately.
- [ ] Deny microphone: visible failure; no capture left running.
- [ ] Deny Screen Recording: visible failure; microphone stops; no mic-only success.
- [ ] Grant permissions and use guided relaunch; no shell involved, grants persist with stable signing.
- [ ] Record system audio plus microphone; inspect both audible sources in saved file.
- [ ] Rapidly stop/restart in one minute; all earlier files remain intact.
- [ ] Hold record hotkey; no duplicate pipeline. Repeated stop does not double-finalize.
- [ ] Quit while recording; quit waits for save; file plays through last spoken words.
- [ ] Quit while startup permission dialog is pending; finish startup then stop cleanly.
- [ ] Use permission relaunch during recording; current file is finalized first.
- [ ] Mute each side independently, then unmute; muted span has no corresponding source audio.
- [ ] Disconnect microphone, revoke capture permission or stop SCK stream; visible failure, no false save-success UI.
- [ ] AirPods, built-in speakers, external DAC: playback/recording quality acceptable; assess AEC and ducking by ear.
- [ ] Switch input/output devices; document actual behavior (auto input follow not implemented).
- [ ] Long call under CPU load: no growing memory, source drift, truncated tail or unexpected silent gaps.
- [ ] Sleep/wake or suspend process over 10 seconds: explicit failure rather than hidden timeline compression.
- [ ] Nearly full test volume (not primary disk): failure surfaced; preserve any usable prefix when encoder permits.
- [ ] `stat -f '%Lp %N' ~/Recordings/MeetRec` reports 700; saved audio reports 600.
- [ ] Build while app running refuses safely; no process killed or recording removed.
- [ ] Build without signing flags does not use your real signing certificate or reset TCC.
- [ ] Test minimum supported macOS and latest macOS, especially native menu-bar item visibility.

## Call apps and interruption recovery

- [ ] Google Meet/browser call: both sides audible, no duplicated echo; mute and stop work.
- [ ] Native Zoom and Microsoft Teams: same checks, including during call reconnect.
- [ ] Arbitrary system audio + microphone: no app-specific assumptions.
- [ ] During a non-sensitive test recording, force-kill MeetRec; relaunch and verify
  automatic `.caf` recovery includes journaled speech through the interruption.
- [ ] Encoder/container failure: recovery retains accepted audio independently of AAC.
- [ ] Interrupted recovery export: original `.pcm` parts remain; next retry succeeds.
- [ ] Another running session is skipped, not exported/deleted as a crashed call.
- [ ] Healthy stop: final `.m4a` plays, associated journal is removed, file modes remain private.
- [ ] Check disk requirements: journal ~0.7 GB/hour plus AAC; recovery needs an extra PCM copy.

Automated tests include actual SIGKILL of a synthetic journal-writing subprocess.
They do not simulate power loss or verify hardware flush guarantees. An unfinished
m4a may remain unplayable, while its journal recovers separately as `.caf`. Audio
still buffered in the device/application can be lost. Keep independent backup for
important calls until real-device validation passes.
