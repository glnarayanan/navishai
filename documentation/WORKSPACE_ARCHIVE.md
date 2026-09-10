# Workspace archive

NavishAI exports one Workspace as a gzip-compressed tar archive with format key `navishai-workspace-v2`. `manifest.json` contains metadata and database rows; `attachment_objects/<stored attachment ID>` entries contain attachment bytes without base64 expansion. The archive contains:

- the source Organisation name and slug;
- the full Workspace row, including its stable runner key;
- every PostgreSQL row with that Workspace ID, grouped by table and ordered by ID;
- the email, verification time, and source ID of each User referenced by those rows;
- each stored attachment's verified bytes, SHA-256 digest, and source attachment ID.

The archive excludes password digests, sessions, Rails credentials, environment variables, model CLI credentials, SMTP passwords, Intercom and Notion service/OAuth tokens, OAuth attempts, outbound-webhook signing secrets, and Supermemory private state. Credential keys and non-secret integration settings remain because they are Workspace configuration. Imported connectors and personal AI accounts are disconnected; personal account UUIDs and historical run references are remapped, and personal runtime approvals are cleared. PostgreSQL Memory records are authoritative. Import gives the restored Workspace fresh endpoint and ledger IDs and rebuilds external Memory entries instead of copying engine-private IDs.

Only an Owner can download a full Workspace export. NavishAI records table, row, and attachment counts in the audit event without copying archive content. Treat the file as customer data: encrypt it at rest, limit access, and remove it under the same retention policy as its source Workspace.

An Owner can import an archive from **Data controls** as a new Workspace in the same Organisation. Every user named by the archive must already have a verified local account. Import checks the format, tenant boundary, full table set, and exact attachment-object ID set, size, and digest before it writes. Duplicate, missing, extra, or tampered objects are rejected. It assigns fresh globally unique endpoint and ledger IDs, preserves internal links, restores verified attachment bytes, and queues current Memory records for external indexing. The compressed archive is limited to 60 MiB and its expanded JSON manifest to 64 MiB. Attachment objects stream through temporary files and retain the 5 MiB per-file and 50 MiB per-archive limits. Export enforces the same limits, so it never creates an archive this release cannot import.

The integrated proof in `test/integration/phase_completion_proof_test.rb` verifies that one GET-only historical Intercom record, its bounded preservation report, exact counts, and report digest survive the archive round trip. It also verifies that the imported available Memory record reconstructs from PostgreSQL without copying an engine-private document ID.
