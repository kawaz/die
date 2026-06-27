# Test Design Patterns Survey — kawaz Repos (2026-06-27)

Survey of 8 repos to extract house style before writing a new global test rule.

## (a) Per-repo Summary

| repo | framework | unit count | e2e count | DR-ref comments | test=spec contour |
|---|---|---|---|---|---|
| bump-semver | Go `testing` | ~822 | 0 | yes (per-file header, inline) | **high** — `spec_table_test.go` mirrors DR tables verbatim |
| authsock-warden | Rust `#[test]` + `#[tokio::test]` | 221 | 4 | minimal (module-level only) | medium |
| claude-cmux-msg | Bun `describe/test` | 479 | 0 | no explicit DR refs | medium — Japanese test names encode intent |
| claude-push-guard | Bash `assert_case` | 0 | 13 | inline label | medium — labels are short spec sentences |
| kuu.mbt | MoonBit `test` | 917 | 0 | no DR refs | medium — test names are intent strings |
| grapheme.mbt | MoonBit `test` (auto-generated) | 766 | 0 | generated from Unicode spec | high — each test cites UAX29 rule number |
| stable-which | Rust `#[test]` | 157 | 0 (dir exists, empty) | minimal | medium — function names describe behaviour |
| die (this repo) | Bash run.sh + per-lang unit | 67 (unit) + 19 (e2e) | 19 | inline block comment | **high** — e2e header states responsibility split |

## (b) Dominant House Style

Three patterns appear consistently across repos:

**1. Table-driven / parametric (Go, MoonBit)**

```go
// bump-semver: suffix_test.go
// --- DR-0013: stripKnownSuffix unit tests ----------------------------------
func TestStripKnownSuffix_LiteralSuffixes(t *testing.T) {
    cases := []struct{ in, want, suffix string }{
        {"Cargo.toml.bak", "Cargo.toml", ".bak"},
```

**2. Test name as spec sentence (TS/Bun, Rust, MoonBit)**

```typescript
// claude-cmux-msg: peer-filter.test.ts
test("tag: の name が空はエラー", () => {
  expect(() => parseByAxis("tag:")).toThrow(/name が空/);
});
```

```rust
// authsock-warden: registry.rs
fn load_secret_transitions_to_active() {
    let mut key = ManagedKey::new(...);
    key.load_secret(secret, ...);
    assert_eq!(key.state, KeyState::Active);
}
```

**3. DR-reference header on spec-critical test groups (Go)**

```go
// bump-semver: spec_table_test.go (file-level doc)
// Spec-driven tests transcribed from DR-0006
// (docs/decisions/DR-0006-pre-release-and-compare.md).
// These tests intentionally reproduce the DR's tables verbatim so that
// the DR remains the single source of truth.

// bump-semver: suffix_test.go (per-group)
// --- DR-0013: stripKnownSuffix unit tests ----------------------------------
```

**4. e2e / unit responsibility split declared in prose (die, authsock-warden)**

```bash
# die: tests/run.sh — block comment at top
# This suite covers what only e2e can measure: ...
# Pure logic coverage is delegated to per-language unit tests: ...
# The reason: language-internal logic does not change when running on
# different OSes ...
```

## (c) Best-Disciplined Example

**bump-semver** (`spec_table_test.go` + `suffix_test.go`) is the most rigorous:

- Every test group opens with a DR section reference identifying *which decision* the tests guard.
- A dedicated `spec_table_test.go` file transcribes DR tables verbatim — test and spec stay in sync by construction.
- Test function names encode the category (`TestSpec_Parse`, `TestStripKnownSuffix_LiteralSuffixes`), making failure output self-documenting.
- 826 Go test functions across 59 files; zero e2e tests (pure unit for business logic).

Runner-up: **die/tests/run.sh** — the only repo that writes an explicit e2e-vs-unit *responsibility split* comment block. This pattern prevents spec drift by declaring what each layer is *not* responsible for. Worth lifting to a global rule.

**Outlier (minimal discipline):** `stable-which` has 157 unit tests with descriptive names but no DR-reference headers and an empty `tests/` directory (e2e planned but not yet written). `claude-local-issue` has no tests at all.
