# Demonstration Workspace

NavishAI seeds a small Customer Operations Workspace in development. It uses the same service paths as normal product work and includes:

- an Owner;
- a renewal-stage Account and Contact;
- urgent investigating and waiting-on-customer cases;
- SLA, note, tag, assignment, Memory, and audit records;
- deterministic account-health signals and an open renewal-risk review; and
- a backtested, published scorecard version.

Run:

```sh
bin/rails db:seed
```

Sign in with `owner@demo.navishai.local` and `navishai-demo-password`. Set `NAVISHAI_DEMO_EMAIL` and `NAVISHAI_DEMO_PASSWORD` before the first seed to choose other local credentials.

Production never seeds demo data by default. To create it on a disposable review deployment, set `NAVISHAI_SEED_DEMO=1` and `NAVISHAI_DEMO_PASSWORD` to a unique password of at least 12 characters, then run `bin/rails db:seed`. Do not seed the demo into a live customer deployment.

The seed is repeatable. If the `navishai-demo/customer-operations` Workspace already exists, another run leaves it unchanged.
