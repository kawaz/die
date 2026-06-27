# Test Design Enforcement Mechanisms in Claude Code

Date: 2026-06-27

## Context

Goal: force an AI agent to declare a test's purpose / scope / category *before* writing it. "The rule says so" alone is insufficient — agents that are prone to skipping will skip checklists and TaskCreate alike unless there is a structural barrier.

---

## (a) Mechanism Comparison Table

| # | Mechanism | Sabotage-resistance | Cost | Friction | Composability |
|---|-----------|--------------------|----|---------|--------------|
| 1 | Rule text alone | Very Low — agent reads, forgets, skips under pressure | Zero | Zero | Base layer only |
| 2 | TaskCreate checklist | Low — agent creates tasks then marks done without real work | Low | Medium | Stackable |
| 3 | PreToolUse(Write) hook | High — blocks the Write call itself; agent cannot skip silently | Medium | Medium-High | Excellent — fires regardless of which mechanism triggered the Write |
| 4 | Slash command `/test-add` | Medium — opt-in; agent can bypass by writing directly | Low | Low (when used) | Pairs well with hook |
| 5 | Skill with mandatory steps | Medium — agent must invoke skill; SKILL.md can assert sequencing | Low-Medium | Low | Stackable on top of rule |
| 6 | Sub-agent (specialist) | Medium-High — isolation means the sub-agent's system prompt is the only context; less drift | High | High (coordination cost) | Composable but heavy |
| 7 | Workflow (phase-by-phase) | Medium-High — phases enforce ordering; hard to reorder | High | High | Best for large batch adds; overkill for single tests |
| 8 | Linter / meta-test in CI | High — CI fails on merge; sabotage is visible and permanent | Medium | Low at write time, High at PR time | Ideal closing layer |
| 9 | Mutation test as forcing function | Very High — quality is numerically measurable; a skipped declaration that produces a weak test shows up as score regression | High | High (infra cost) | Best as a long-term quality gate |

---

## (b) Recommended Stack

**Tier 1 (structural barrier): PreToolUse(Write) hook**
**Tier 2 (closing gate): Linter / meta-test in CI**
**Tier 3 (guidance): Rule text + Skill**

Rationale: The core insight from kawaz's observation is that advisory mechanisms (rules, checklists, tasks) are skipped precisely when the agent is under pressure to produce output quickly. The only mechanisms that cannot be silently bypassed are those that block the output path or fail CI retroactively.

The PreToolUse(Write) hook fires synchronously before any Write to a test file. The agent receives a prompt that requires it to emit a structured justification comment before proceeding. If the agent tries to write a test file without the block, the hook can reject the call (via `"decision": "block"` return). This is structural, not advisory.

The CI linter closes the escape hatch of a hook that was configured with a warn-only mode, or tests written via Bash rather than Write. It asserts that every test function has the required metadata comment. A failing CI job is hard evidence, reviewable by humans.

Rule text + Skill remain necessary as the *explanation layer* — they tell the agent what the required comment format looks like and why it matters. Without them the hook's error message is cryptic.

Slash command (`/test-add`) is a nice-to-have that makes the happy path pleasant but is not load-bearing for sabotage resistance.

Sub-agent and Workflow are worth considering only when the task involves writing a large test suite from scratch; for incremental test additions they add coordination cost without proportional resistance gain.

Mutation testing is the ideal long-term gate but has high infra cost; defer until the test suite is mature.

---

## (c) Implementation Sketch — PreToolUse(Write) Hook

Add to `.claude/settings.json` (project level):

```json
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "bash -c 'f=\"$CLAUDE_TOOL_INPUT_FILE_PATH\"; case \"$f\" in *_test.*|*/tests/*|*/test/*|*_spec.*) exit 1 ;; *) exit 0 ;; esac'"
          }
        ]
      }
    ]
  }
}
```

When the path matches a test file pattern, the command exits 1, which signals the hook system to block the tool call and return an error to the agent. The error message (injected via stderr or a companion rule) instructs:

```
[test-design-guard] Writing a test file requires a design declaration.
Add the following block at the top of each test function BEFORE this Write call:

  // TEST-DESIGN
  // purpose: <one sentence: what behaviour this test proves>
  // scope:   <unit | integration | e2e>
  // category: <normal | error | boundary | regression | security>
  // completion-criterion: <what "passing" means in observable terms>

Re-submit the Write with the completed block present.
```

The hook script can be extended to grep the proposed file content (available via `$CLAUDE_TOOL_INPUT_CONTENT` or a tmp file) and exit 0 only when the required block is found, making the guard self-enforcing rather than blocking-then-trusting:

```bash
#!/usr/bin/env bash
file="$CLAUDE_TOOL_INPUT_FILE_PATH"
# Only guard test files
case "$file" in
  *_test.*|*/tests/*|*/test/*|*_spec.*) ;;
  *) exit 0 ;;
esac
# Read proposed content from env or stdin
content="$CLAUDE_TOOL_INPUT_CONTENT"
if echo "$content" | grep -q '// TEST-DESIGN'; then
  exit 0
else
  echo "[test-design-guard] Missing TEST-DESIGN block. Declare purpose/scope/category/completion-criterion before writing." >&2
  exit 1
fi
```

This two-line check turns the hook from a blanket block into a content-aware gate: the agent *can* write the test, but only after it has thought through and typed the declaration. The CI linter then verifies the same pattern on every test function in the merged code, catching any Bash-path writes the hook missed.
