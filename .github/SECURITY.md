# Security policy

Thank you for helping keep NavishAI and the people who use it safe.

## Reporting a vulnerability

Please report security issues privately. **Do not open a public issue, pull
request or discussion** for a suspected vulnerability.

Use either private channel:

- **GitHub:** open a private report from the repository's
  [Security tab](https://github.com/glnarayanan/navishai/security/advisories/new)
  ("Report a vulnerability").
- **Email:** write to **hello@navishai.com** with the subject line
  `Security report`.

Include:

- what the issue is and what an attacker could do with it
- the affected page, route, file or commit
- steps to reproduce, or a minimal proof of concept
- any logs, screenshots or requests that help (remove secrets and personal data)
- how you would like to be credited, if at all

## What happens next

- We acknowledge your report and confirm whether we can reproduce it.
- We keep you updated while we work on a fix.
- We agree a disclosure date with you once a fix is available.
- We credit you in the fix notes unless you ask us not to.

## Scope

In scope: the code in this repository and its current `main` branch. There are
no versioned releases yet, so older commits are not supported.

Out of scope:

- issues in third-party services or dependencies with no impact on NavishAI
  (report those upstream)
- denial-of-service or load testing
- social engineering, phishing or physical attacks
- reports from automated scanners with no demonstrated impact

## Testing rules

- Only test against your own local copy or an account you own.
- Do not access, change or delete data that is not yours.
- Stop and report as soon as you find a way to reach someone else's data.
- Do not run tests that degrade the service for other users.

We will not pursue action against good-faith research that follows these
rules. There is no paid bug bounty.

The controls the application already enforces are documented in
[documentation/SECURITY.md](../documentation/SECURITY.md).
