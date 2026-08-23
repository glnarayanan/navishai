# Domain language

Use these terms in product copy, code, tests, and design notes.

- **Organisation:** a NavishAI tenant that owns one or more isolated Workspaces.
- **Workspace:** the access, policy, and data-isolation boundary for daily work.
- **User:** a person who signs in to NavishAI. A Membership gives a User one role in one Workspace.
- **Account:** a customer company inside one Workspace. It is not a NavishAI User, Organisation, or login account.
- **Contact:** a customer person inside one Workspace, optionally linked to one Account.
- **Source identity:** one stable record from one source namespace, linked to an Account or Contact after matching or review.
- **Source namespace:** an opaque key for one connector instance. It is not a provider name.
- **Identity key:** an exact normalized email for a Contact or domain for an Account. Names and fuzzy similarity are not identity keys.
- **Ambiguous identity:** a Source identity whose keys point to more than one canonical record. Automated work stays blocked until an authorised human reviews it.
- **Merge:** a directed, reversible alias from one Account or Contact to another. Source identities and history stay on their original record.
- **Canonical record:** the current root reached by following active merge history.
- **Unmerge:** closure of one active merge. It restores the prior alias split but does not undo facts added after the merge.
