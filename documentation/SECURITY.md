# Phase A security evidence and limits

Retained controls: local verification/password reset, revocable expiring sessions,
invitation role bounds, first Owner, generic OIDC state/nonce/PKCE and signed-token
checks, protected short-lived break-glass recovery, per-workspace membership
authorization, serialized last-Owner protection, CSP/nonces, security headers,
production host/HTTPS enforcement, rate limits and sensitive log filters.

Workspace reads start from the signed-in user's memberships. Organisation ownership
grants no access to sibling workspaces. Foreign keys, uniqueness and role/status
checks remain in PostgreSQL. These are application authorization and database
constraints, **not PostgreSQL RLS**. Last-Owner protection is a Ruby callback using
a transaction advisory lock; raw SQL can bypass it. Do not grant application users
direct database access.

Audit actions/metadata are allowlisted with scalar/type/size and sensitive-key
validation. Subject workspace mismatches are rejected. Persisted events are Ruby
read-only and PostgreSQL rejects update/delete/truncate. No expiry exception,
notification fanout or old-domain audit vocabulary remains. Tests exercise model
and direct-SQL failures. Database administrators can still disable triggers.

This slice has no corpus, source retention/export/deletion, evaluation execution,
external target disclosure or grader calibration. Those controls must be designed
and tested with the later domain, not represented by legacy code. OIDC provider and
SMTP tests use local stubs; no live identity provider or mail delivery was verified.
Direct risk-based review replaces unavailable Ponytail Audit and CE Code Review.
