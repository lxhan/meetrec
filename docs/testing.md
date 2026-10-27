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

Force-kill/power loss recovery is not implemented. An unfinished m4a can remain
unplayable; do not treat graceful shutdown fixes as crash resilience.
