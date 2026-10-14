# Oura Key Helper

## Platform
Native macOS companion, initially Apple Silicon; no phone jailbreak required.

## Purpose
Let an owner recover an existing Oura ring key from their locally backed-up official Oura app. Make consent, scope, file locations, failures, export, and temporary-backup deletion visible.

## Boundaries
The extractor reads only backup metadata needed to locate Oura and the ringconfiguration key fields in Oura's database. Creating an Apple backup copies broader phone data; the interface explicitly explains this. No telemetry, cloud uploads, automatic clipboard copies, ring resets, restores. Backup-encryption changes require explicit consent and the current password, with verified restoration and a persistent device-only recovery reminder. Existing user backups cannot be deleted by the helper. Every helper-created backup remains visible and deletable after cancellation or relaunch.

## First release limits
Existing encrypted backups are identified and refused. New backups can use the explicit temporary-encryption flow; automatic restoration is attempted but cannot be guaranteed after disconnect or force quit. Extraction against current real Oura versions still requires a device test. A user-installed libimobiledevice supplies USB backup creation; source and Mac build are independently available.
