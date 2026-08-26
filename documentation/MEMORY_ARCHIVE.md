# Memory archive format

NavishAI exports Workspace memory as UTF-8 JSON with format key `navishai-memory-v1`. The archive contains:

- the source Workspace key and export time;
- every Memory record, scope reference, source reference, time, confidence, retention rule, and supersession link;
- agent Memory proposals and human correction proposals, including terminal review state;
- deletion tombstones and their external-removal state.

The archive does not contain Supermemory document IDs or index state. PostgreSQL records are authoritative, and import creates fresh index entries for every current, non-deleted record.

Import is a restore operation. The target Workspace key and referenced Account, Contact, Case, Crew, Agent, User, Membership, and artifact rows must already match the archive. The target must contain no Memory records. Import locks the Workspace before it checks that rule, so concurrent imports, deletion, and other Workspace writes have one database order. NavishAI rejects another Workspace's archive, unknown formats, broken supersession links, missing references, malformed records, and files over 20 MiB. The whole import commits or rolls back as one transaction.

Managers, Admins, and Owners may export, import, or rebuild the index from the Memory page. Each action creates a user-attributed audit with counts but no Memory content. Keep archives under the same access and retention controls as customer source data.
