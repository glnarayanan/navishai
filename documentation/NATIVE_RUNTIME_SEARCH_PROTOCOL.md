# Native runtime search protocol record

**Checked:** 10 September 2026

## Decision

Native runtime search stays unavailable. The current approved subscription protocols do not provide one typed, run-bound result record with a canonical HTTPS URL, bounded source excerpt, retrieval time, optional publication date, and rejectable terminal status. This is a current-protocol decision, not a claim about later releases.

The existing SearXNG, Exa, and Tavily adapters remain separate. Their signed runner endpoint normalizes public-web results before Rails stores a `public-web://` citation. This review does not change those adapters.

## Required contract

Each accepted native result must carry a run and tool identifier, canonical HTTPS URL, source-derived bounded excerpt, runner-recorded retrieval time, observed publication date when supplied, and a result-level terminal state. Missing or malformed fields must be rejectable before the result enters a citation, artifact, ledger, or explanation.

## Checked protocols

| Runtime | Local supported version | Checked upstream source | Result | Missing or unsafe fields |
|---|---|---|---|---|
| Codex `exec --json` | `0.149.0` minimum, no maximum | [openai/codex `4ef1d4b`](https://github.com/openai/codex/tree/4ef1d4b89bd419c976b04fefa0fd36844e898340) | No-go | `web_search` contains an ID, query, and action only. No projected results, URL, excerpt, publication date, retrieval time, or per-result state. |
| Claude Code stream JSON | `2.1.169` minimum; no enforced maximum | [CLI docs](https://code.claude.com/docs/en/cli-reference.md), [tool reference](https://code.claude.com/docs/en/tools-reference.md#websearch-tool-behavior), [anthropics/claude-code `e62465d`](https://github.com/anthropics/claude-code/tree/e62465d553ecbf1697219ffbb3c11b4fef14d5bf) | No-go | Stable CLI `WebSearchOutput` lists titles and URLs only. It has no HTTPS rule, excerpt, retrieval time, publication date, or per-search terminal state. |
| Grok ACP | `1.0.4` minimum; no enforced maximum | [xai-org/grok-build `3794978`](https://github.com/xai-org/grok-build/tree/37949780c144e37df692e3d669051a21fec24f20), [ACP v1 `367c56f`](https://github.com/agentclientprotocol/agent-client-protocol/tree/367c56fb6115f391bc7550288363f87416cd0af8) | No-go | ACP has generic tool state and opaque `rawOutput`; Grok's source projection supplies URL and title only. Neither gives the required per-result fields. |
| Cursor ACP | `2026.3.11` minimum; no enforced maximum | [ACP v1 `367c56f`](https://github.com/agentclientprotocol/agent-client-protocol/tree/367c56fb6115f391bc7550288363f87416cd0af8); Cursor publishes no maintained CLI ACP source contract | No-go | ACP search is a display kind. Generic content, resource links, metadata, and raw output do not define HTTPS canonicality, excerpts, retrieval time, publication date, or per-result state. |

Local minimums are NavishAI runtime-admission policy, not upstream evidence-schema versions. The adapters retain maximum-version metadata, but current compatibility checks deliberately accept future valid versions. No live CLI or subscription smoke ran.

## Source evidence

### Codex

NavishAI's `0.149.0` floor is the local `minVersion` constant in [`runner/internal/adapters/codex/adapter.go`](../runner/internal/adapters/codex/adapter.go). It is not an upstream event-schema version.

At [openai/codex `4ef1d4b`, `exec_events.rs`](https://github.com/openai/codex/blob/4ef1d4b89bd419c976b04fefa0fd36844e898340/codex-rs/exec/src/exec_events.rs#L8-L37), JSONL has `thread.*`, `turn.*`, `item.*`, and `error` events. Its [`WebSearchItem`](https://github.com/openai/codex/blob/4ef1d4b89bd419c976b04fefa0fd36844e898340/codex-rs/exec/src/exec_events.rs#L296-L302) has only `id`, `query`, and `action`. The upstream app-server item has optional opaque results, but the [`exec` JSONL mapper](https://github.com/openai/codex/blob/4ef1d4b89bd419c976b04fefa0fd36844e898340/codex-rs/exec/src/event_processor_with_jsonl_output.rs#L302-L315) copies only the ID, query, and action. An `openPage` action URL records an operation, not a typed result citation.

### Claude

The [Claude CLI reference](https://code.claude.com/docs/en/cli-reference.md) defines print-mode `stream-json`; the [Agent SDK message types](https://code.claude.com/docs/en/agent-sdk/typescript.md#message-types) define session-bound assistant, tool-result, and final-result envelopes. The maintained [WebSearch tool reference](https://code.claude.com/docs/en/tools-reference.md#websearch-tool-behavior) defines stable CLI output as a query and result title/URL pairs. The upstream repository at [`e62465d`](https://github.com/anthropics/claude-code/tree/e62465d553ecbf1697219ffbb3c11b4fef14d5bf) directs users to those maintained product docs; it does not publish the CLI implementation source. A tool-use query or final run result is not source evidence.

### Grok and Cursor ACP

The [ACP v1 tool-call schema](https://github.com/agentclientprotocol/agent-client-protocol/blob/367c56fb6115f391bc7550288363f87416cd0af8/agent-client-protocol-schema/src/v1/tool_call.rs#L17-L88) defines generic calls, arbitrary raw input/output, and extensible metadata. Its [terminal status](https://github.com/agentclientprotocol/agent-client-protocol/blob/367c56fb6115f391bc7550288363f87416cd0af8/agent-client-protocol-schema/src/v1/tool_call.rs#L531-L550) is only `pending`, `in_progress`, `completed`, or `failed`. A search kind or completed tool proves activity, not each source's provenance.

Grok passes backend search output into generic ACP raw output in [`sampling_events.rs`](https://github.com/xai-org/grok-build/blob/37949780c144e37df692e3d669051a21fec24f20/crates/codegen/xai-grok-shell/src/session/acp_session_impl/sampling_events.rs#L510-L567). Its headless result projection contains only [URL and title](https://github.com/xai-org/grok-build/blob/37949780c144e37df692e3d669051a21fec24f20/crates/codegen/xai-grok-pager/src/headless/reducer/messages/web_search.rs#L77-L108). Cursor has no public maintained CLI ACP source that adds a stronger web-search contract. ACP's [resource link](https://github.com/agentclientprotocol/agent-client-protocol/blob/367c56fb6115f391bc7550288363f87416cd0af8/agent-client-protocol-schema/src/v1/content.rs#L447-L493) permits arbitrary URIs and does not define excerpts or dates.

## Local fail-closed boundary

Codex always passes `web_search="disabled"` in [`arguments`](../runner/internal/adapters/codex/adapter.go). Its parser marks every `web_search` item as disallowed. Production paths set `DisableTools: true`, so a query/action-only item emits only a non-retryable `run.failed` event; it cannot emit output, a tool event, or a citation. Claude disallows `WebSearch`; Grok and Cursor reject prohibited ACP operations. The runtime catalog does not advertise a native-search capability.

Workspace search settings select only a provider for [`PublicWebResearch`](../app/services/public_web_research.rb), which runs through the signed web-search endpoint. That service minimizes query data, freezes the selected provider on retries, and stores only normalized results. [`PublicWebSearchResult`](../app/models/public_web_search_result.rb) requires HTTPS URLs and retrieval time. `ExecutionLedger`, evidence resolution, and explanations consume those stored `public-web://` results; they do not consume runtime output as web evidence.

## Risk review

- Fabricated or misattributed evidence: no native output crosses into the public-web models; the Codex fixture ends before output or tool events.
- Egress widening: no runtime arguments, egress profiles, capabilities, or deployment policy changed.
- Retry or fallback drift: native search has no route, so existing frozen public-search provider selection remains the only search retry path.
- Cross-Workspace and personal-account leakage: the unchanged signed public-search path binds every search and result to its Workspace; native output has no storage path.
- Private runtime output: the native denial emits only a bounded failure code. It does not copy query/action payloads into the ledger or explanation.
