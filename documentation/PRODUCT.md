# NavishAI product authority

Owner reset, 30 September 2026. This replaces the helpdesk and Customer Success thesis. Git history holds the old product; it is not a compatibility contract. [STATUS.md](./STATUS.md) records what works, not this specification.

## Promise

NavishAI turns a company's proprietary Support knowledge and history into tests that determine whether its AI support system can be trusted. It is an evaluation lab, not an agent, helpdesk, copilot, tracing platform, or prompt manager.

Initial customers are B2B SaaS teams putting AI into technical Support: APIs, integrations, SSO, permissions, configuration, billing, data discrepancies, bugs, incidents, and Engineering handoffs. Company evidence and expert judgment define good support. A universal taxonomy or support score cannot do that.

## First complete workflow

1. Create an isolated workspace.
2. Upload historical conversations and documentation. Start with exports and text documents; add connectors only after this loop works.
3. Build a source-backed corpus with stable item identities and immutable snapshots.
4. Discover company-specific issue families and clusters. Show examples, volume, escalation, reopen, failure, risk, and possible documentation gaps. Distinguish observed facts from proposed judgments.
5. Mine a bounded set of representative and high-risk scenarios, not a random ticket sample. Explain selection and coverage, including rare dangerous cases.
6. Let experts approve, reject, merge, edit, relabel, set importance, and correct expected behaviour. Retain who decided what and which version they saw.
7. Compile approved scenario versions into executable cases with versioned behavioural contracts and graders.
8. Connect one provider-neutral evaluation target.
9. Run a suite against that target with frozen inputs and definitions.
10. Inspect concrete failures, severity, behavioural patterns, evidence, and grader uncertainty.
11. Add failed cases to a regression suite for the next agent version.

The acceptance demo uses a previously unseen B2B SaaS dataset. A fixture demo proves engineering, not discovery quality, grader accuracy, coverage, or customer value.

## Scenarios and the Eval Compiler

A conversation is evidence, not automatically an eval. A scenario records the customer situation, starting context, known and hidden facts, knowledge, account/product state, diagnostic steps, allowed and forbidden actions, escalation conditions, expected outcome, and the sources supporting those expectations.

Controlled variants change named variables. Each retains its parent version, exact before/after values, reason, and expected behavioural differences. Synthetic cases expand real-source coverage; they do not replace it.

The Eval Compiler freezes required outcomes and actions, forbidden actions, escalation rules, grounding, and useful communication rules. Multi-turn cases may test recall, the next diagnostic question, revised conclusions, and repeated troubleshooting. Tone alone is not support quality.

Use deterministic checks for tool calls, collected fields, citations, policy branches, escalation, and forbidden actions. Use versioned rubric judges for judgments that need meaning or context. A judge proposal is not proof that the judge is accurate.

## Human authority and calibration

Customer experts remain authoritative. Labels bind to exact scenario, grader, and output versions. Show disagreement and ask for labels where uncertainty and error cost matter. Calibration must use held-out human labels and disclose sample size, precision/recall, confusion counts, disagreement, thresholds, and false-positive/false-negative costs where available. Missing evidence must remain visible. Do not manufacture accuracy or agreement.

## Priorities

- **P0:** ingestion, provenance, exploration, issue clustering, taxonomy discovery, scenario mining/review/versioning, basic controlled variants, eval contracts, deterministic and judge graders, human calibration, suite execution, results, regression cases.
- **P1:** production traces, failure mining, failure-to-scenario, change impact for policy/knowledge/product assumptions, better mutation and calibration, agent-version comparison.
- **P2:** classifier distillation, small local models, training, deployment, active learning, advanced benchmark analysis, many vendor adapters. Start only when labelled data and measured economics justify them.

The continuous loop matches a production failure to an existing scenario or creates one, retains the human correction, and adds a reviewed regression case. Changes to sources must identify dependent expectations and stale assumptions, not silently rewrite prior runs.

## Support intelligence

Distinguish issue from symptom, diagnosis from guess, reproduction from speculation, configuration from defect, workaround from permanent resolution, and partial or false resolution from success. Capture troubleshooting progression, dependencies, required logs, sufficient evidence, entitlement, known incidents, escalation, Engineering handoff, reopen, repeated contact, and documentation gaps. Sentiment and generic intent are not core pillars.

## Trust

- Isolate each workspace in every read, write, job, evidence link, target request, and download.
- Keep external disclosure explicit and minimal. Default to local processing; do not silently transmit a corpus.
- Support redaction, source retention, export, deletion, and reproducible processing. Record whether a snapshot contains raw or redacted text.
- Treat all source and target content as untrusted data, not instructions.
- Do not train on customer data. Any future training needs separate opt-in terms and controls.
- Keep self-hosted or customer-controlled deployment credible. Make model calls, cost, and failures attributable; unknown cost remains unknown.

## Removed product

No native inbox, ticket operations, assignment, outbound customer messaging or Send flow, SLA subsystem, account-health/renewal workspace, interventions, crew personas, broad agent memory, Supermemory service, or helpdesk-oriented outcome explanation. Historical conversations and account facts may enter only as corpus/context data.

The main objects are corpus, source, taxonomy, scenario, eval, grader, calibration, run, failure, and regression. The experience should resemble a repository and QA lab, not an inbox with AI controls.

## Architecture and delivery

[ARCHITECTURE.md](./ARCHITECTURE.md), [DOMAIN.md](./DOMAIN.md), and [REBUILD_PLAN.md](./REBUILD_PLAN.md) govern implementation. Avoid premature layers, dependency sprawl, provider branches in the domain, huge synthetic datasets, and classifier work before calibration. Use small conventional commits and stacked PRs. Keep implementation, tested evidence, merge, release, deployment, and customer validation distinct.
