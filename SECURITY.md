# Security policy

This project has no security support SLA and no independently audited release.
Use reviewed source and test with non-sensitive audio before relying on it.

## Reporting

For a suspected vulnerability, use GitHub's private vulnerability reporting if
available, or contact repository owner privately. Do not post meeting audio,
credentials, personal paths, or sensitive diagnostic output in public issues.
Routine non-sensitive bugs can be filed as GitHub issues.

## Threat model and boundaries

- Records microphone and broad system audio on user action; no network client,
  analytics, cloud transcription, auto-update downloader, privileged helper, or
  third-party Swift dependencies.
- Screen Recording permission is broad. Implementation saves audio only, but
  granting permission still requires trusting the code you actually run.
- Local-only is not encryption. Directory/file permissions protect against other
  ordinary local accounts, not malware running as your user, administrators,
  untrusted backups or cloud-synced storage.
- Mute discards audio in the file mixer; it does not disable hardware capture.
- Hardened runtime enabled in packaging; app is not sandboxed or notarized.
- Default local build uses ad-hoc signing. Explicit user-supplied identity is
  required for stable signing; no automatic keychain-identity selection.
- No shell-interpolated relaunch, remote install commands or implicit permission resets.
- Filenames are unique; AVAssetWriter refuses existing outputs. No deletion of
  pre-existing recording files during startup.
- Graceful stop/quit finalizes output. A private, unencrypted PCM journal supports
  interrupted-call recovery; it can contain sensitive call audio and uses about
  0.7 GB/hour. Journal files are removed only after a verified successful save/export.
  Failed recovery leaves source segments intact. Buffered/unwritten audio, disk
  corruption, and catastrophic hardware failure are not recoverable guarantees.
- Unified diagnostic logging is opt-in and private; avoid sharing captured audio
  or enabling private-data collection outside a controlled troubleshooting session.

Code signatures and checksums establish integrity relative to their signer/source,
not safety or reproducible source/binary equivalence. Never bypass system security
globally to run this app. Obtain participant consent where required.
