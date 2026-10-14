# Native Mac utility
Operate mode: one task, explicit consent, native system controls. Use SwiftUI system typography, semantic colors, Form sections, a clear progress state, native file pickers and save dialogs. Keep keys hidden by default. Backup creation and existing-backup reading are distinct actions. Deletion is a destructive action naming the helper-owned folder and requires confirmation. Always show failures and retained temporary backups. No custom dashboard styling, assurance badges, or unsupported privacy claims.

Keep the first screen compact: live connection status, ownership confirmation, and the two backup actions. Longer privacy/storage details stay collapsed; full backup scope and deletion consequences appear at the action’s confirmation. Backup paths use a File location disclosure. Only active work, results, and errors show the operation-status area.

For encrypted connections, Create temporary backup opens a native secure-password sheet naming the temporary setting change and broader backup scope. Never prefill or persist the password. A pending restoration blocks new backups and exposes Restore encryption; cancellation cannot interrupt restoration.
