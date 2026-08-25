# Workspace archive

NavishAI exports one Workspace as gzip-compressed UTF-8 JSON with format key `navishai-workspace-v1`. The archive contains:

- the source Organisation name and slug;
- the full Workspace row, including its stable runner key;
- every PostgreSQL row with that Workspace ID, grouped by table and ordered by ID;
- the email, verification time, and source ID of each User referenced by those rows;
- each stored attachment's verified bytes, SHA-256 digest, and source attachment ID.

The archive excludes password digests, sessions, Rails credentials, environment variables, model CLI credentials, SMTP passwords, Intercom tokens, outbound-webhook signing secrets, and Supermemory private state. Credential keys and non-secret integration settings remain because they are Workspace configuration. PostgreSQL Memory records are authoritative. Import gives the restored Workspace fresh endpoint and ledger IDs and rebuilds external Memory entries instead of copying engine-private IDs.

Only an Owner can download a full Workspace export. NavishAI records table, row, and attachment counts in the audit event without copying archive content. Treat the file as customer data: encrypt it at rest, limit access, and remove it under the same retention policy as its source Workspace.

An Owner can import an archive from **Data controls** as a new Workspace in the same Organisation. Every user named by the archive must already have a verified local account. Import checks the format, tenant boundary, full table set, attachment digests, compressed size, and expanded size before it writes. It assigns fresh globally unique endpoint and ledger IDs, preserves internal links, restores verified attachment bytes, and queues current Memory records for external indexing. The limits are 8 MiB compressed and 64 MiB expanded.
