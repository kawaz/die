# Test-Design Discipline in the Claude Code Ecosystem

Scan date: 2026-06-27. Claude Code v2.1.195.

---

## (a) Existing Tools That Fit

### nizos/tdd-guard (OSS plugin, most relevant)

`PreToolUse` hook (Edit / Write / MultiEdit) intercepts every file-write and passes it to an AI validator that checks TDD compliance. Blocks writes if: no failing test exists first, implementation goes beyond what tests require, or multiple tests are added simultaneously. Supports Vitest, Jest, pytest, Go, Rust, RSpec, PHPUnit and more. Install: `/plugin marketplace add nizos/tdd-guard`. Focus: enforcement of the red-green-refactor sequence at write-time.

### obra/superpowers — `test-driven-development` skill (OSS plugin)

A SKILL.md-based multi-phase gate workflow. Requires Claude to declare RED before writing anything, prove the test fails, write minimal GREEN, then REFACTOR. Has explicit "Do NOT proceed until …" phase constraints. Does NOT target test-design quality (boundary analysis, decision tables, equivalence class); it enforces cycle discipline only.

### anthropic/claude-plugins-official — `code-modernization` plugin: `test-engineer` agent

An agent (`agents/test-engineer.md`) for characterization / contract / equivalence testing of legacy code during rewrites. Instructs Claude to: cover every branch of legacy code, use concrete literal inputs/outputs, assert actual legacy behavior as oracle. The closest existing artifact to "test-design discipline" but scoped to legacy characterization, not greenfield TDD.

### anthropic/claude-plugins-official — `hookify` plugin: `require-tests-run` example

Pre-packaged hookify rule (disabled by default, in `examples/require-tests-stop.local.md`) that blocks `Stop` if no test-runner command (`npm test` / `pytest` / `cargo test`) appears in the session transcript. Ensures tests were *run*, not that they were *designed well*.

### anthropic/claude-plugins-official — `feature-dev` plugin

7-phase workflow (Discovery → Codebase Exploration → Clarifying Questions → Architecture → Implementation → Quality Review → Summary). Phase 6 launches parallel `code-reviewer` agents. No dedicated test-design phase; tests are implicit in "Quality Review".

---

## (b) Gaps — What Nobody Is Doing Yet

1. **Pre-write test-purpose declaration.** No tool requires Claude to state, before writing a test: "this case covers [boundary / normal / error / regression / decision-table row X/Y]". tdd-guard blocks mis-sequenced writes; it does not require intent declaration.

2. **Test-design checklist at write-time.** No plugin surfaces a structured checklist (boundary values, equivalence-class selection, decision-table coverage, state-transition cases, regression anchor) as a mandatory gate before the first test file is created.

3. **Form-over-substance detection.** No tool distinguishes "test that asserts a meaningful property" from "test that passes with any implementation because the assertion is trivially weak" (e.g. `assert result is not None`). All existing tools check that a test *exists and runs*; none check that its assertion is load-bearing.

4. **Completion-criteria declaration before coding.** No plugin enforces "write down what done looks like (inputs, outputs, failure modes) before writing any code or test". feature-dev's Clarifying Questions phase is closest but is about requirements, not test-design contracts.

5. **Cross-language test-design parity.** tdd-guard lists supported frameworks but does not teach per-framework boundary idioms. test-engineer agent is legacy-only.

---

## (c) Implementation Surfaces in Claude Code

| Surface | How it could enforce test design | Trade-off |
|---|---|---|
| **`PreToolUse` hook on `Write`/`Edit` (command or agent type)** | Block any write to a `*_test.*` / `test_*.py` file unless a structured comment header (purpose / category / oracle) is present in the new content. | Robust enforcement that survives `bypassPermissions`; fragile to naming conventions; easy to game with a boilerplate header. |
| **`Stop` hook (hookify `block` action)** | Block session end unless transcript contains a test-design declaration keyword set. | Simple to implement; catches omissions at the end, not at write-time; stops but does not redirect. |
| **Skill (SKILL.md) invoked explicitly** | Provide the checklist as an invocable skill (`/test-design`) that Claude reads before writing; include boundary / equivalence / decision-table prompts. | Zero enforcement strength — Claude can ignore or skip; best as a reference, not a gate. |
| **`PostToolUse` hook on `Write` (agent type)** | After each test file write, spawn an agent that reads the file and rates assertion quality; inject feedback into context. | High signal quality; higher latency and token cost per write; non-blocking (can only inject context, not deny). |
| **CLAUDE.md rule (plain text)** | Declare the test-design protocol in project CLAUDE.md; Claude reads it every session. | Zero enforcement; but trivially portable, zero install friction. Weakest, but most universal. |
| **Plugin with `agent`-type `PreToolUse` hook** | Full validation agent reads the proposed test, checks for boundary/equivalence/regression coverage before allowing the write. | Strongest signal; ~1-3s latency per write; `deny` is bypassPermissions-proof; distributable via plugin marketplace. |
