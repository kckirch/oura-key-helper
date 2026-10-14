# Oura Key Helper

## Platform
Native macOS companion, initially Apple Silicon; no phone jailbreak required. The consumer app bundles its USB runtime; developers explicitly set up a pinned build environment.

## Purpose
Let an owner recover their existing ring key with minimal input, then save/copy it and leave. Use filtered collection by default and remove helper-created phone data automatically.

## Boundaries
Only Oura's assa.sqlite and matching sidecars are saved as app payloads; first-run backup traffic can still include other apps' bytes, which are discarded. Backup metadata temporarily describes the broader device. No telemetry, uploads, automatic clipboard copies, restores, ring resets, or default backup-encryption changes. Passwords only decrypt the retained encrypted files locally. Existing Finder backups cannot be deleted by the helper.

## Lifecycle
Remove owned temporary data after success, cancellation, or failure; retry leftover cleanup on launch unless a recorded process is active. Show cleanup failures. Keep the recovered key in memory, export only on request, and guard quitting with an unsaved/uncopied key. Legacy encryption-recovery reminders must remain actionable.

## Limits
Filtered collection still requires real-device validation. It reduces storage, not first-run transfer volume. Encrypted local decryption has fixture coverage only. Unknown passwords cannot be bypassed. No unsupported privacy or compatibility guarantees.
