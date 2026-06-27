# Test Design Discipline — Industry & Academic Literature Survey

Date: 2026-06-27

---

## (a) Technique Comparison Table

| Technique | Purpose | What It Guarantees | When to Use | Overlap with kawaz's axes |
|-----------|---------|-------------------|------------|--------------------------|
| **Equivalence Partitioning** (ISTQB/29119) | Divide input space into classes with identical behaviour | One representative per class exercises all members | Any input-driven code with discrete valid/invalid ranges | Covers "same-value group" subset of boundary / input-space axes |
| **Boundary Value Analysis** (ISTQB/29119) | Test values at partition edges where off-by-one defects cluster | Exercises ±1 of each boundary in 2-value or 3-value flavour | Ordered types: integers, strings by length, dates, indices | Direct overlap with kawaz's "境界ケース"; BVA formalises *which* boundary values matter |
| **Decision Table Testing** (ISTQB/29119) | Enumerate all condition-outcome combinations as a table | Combinatorial completeness of business-rule interactions | Business rules with multiple independent boolean/multi-valued conditions | Extends kawaz's "複数条件 (デシジョンテーブル)" — provides systematic cell-reduction strategies (e.g. don't-care collapsing) |
| **State Transition Testing** (ISTQB/29119) | Drive FSM through all states and transitions including invalid ones | N-switch coverage (N=0: all states; N=1: all transitions; N=2: all transition pairs) | Stateful objects, protocol parsers, UI flows, auth sessions | Extends kawaz's "状態遷移" with explicit invalid-transition coverage |
| **Classification Tree Method** (29119-4, Grochtmann/Grimm 1993) | Hierarchical decomposition of parameter space; nodes are classes, leaves are test values | Systematic combinatorial coverage without pairwise-only constraint | Multi-parameter input spaces where parameters are logically structured | Structural complement to kawaz's "同値分割" — forces exhaustive enumeration of dimensions before combining |
| **Pairwise / Combinatorial Testing** (29119-4, NIST) | Select subset of combinations that covers every 2-way (or N-way) pair at least once | t-way interaction coverage; empirically catches ≥ 70% of defects for t=2 | Configuration testing, feature flags, platform matrices | Formalises kawaz's "ペア網羅 / 危険なペア優先" into a provably minimal test set |
| **Use Case / User Story Testing** (ISTQB) | Derive tests from actor-system interaction flows (main, alternative, error paths) | All declared interaction paths exercised | User-facing features with defined actor sequences | Partially overlaps kawaz's "正常系"; adds *alternative paths* and *abort paths* not in kawaz's list |
| **Property-Based Testing** (Hughes / QuickCheck, 2000) | Declare algebraic/relational invariants; engine generates thousands of random inputs to falsify | If property holds over N random cases, confidence in invariant is quantified; finds edge cases humans miss | Pure functions with invariants (round-trip, commutativity, monotonicity, oracle model) | Goes beyond kawaz's "エッジケース" — *systematically* exercises the entire input space against an abstract spec; adds "metamorphic" and "model-based" property strategies |
| **Specification by Example / BDD** (Adzic 2011; Cucumber/Gherkin) | Express acceptance criteria as Given/When/Then examples; automate them as living docs | Shared understanding between business and dev; examples that drift from behaviour fail CI | Features with domain-expert stakeholders; user-facing business rules | Supplies kawaz's missing *intent layer*: the why of each test is explicit in the scenario title |
| **Mutation Testing** (DeMillo 1978; Pitest, Stryker) | Inject artificial faults; measure what fraction tests kill | Mutation score = killed/total; code coverage ≠ assertion strength | When you need a numeric quality gate on test suite effectiveness | Not in kawaz's axes — orthogonal meta-technique: measures all other axes' *adequacy* |
| **Contract Testing / Consumer-Driven** (Pact) | Consumer writes the API contract it needs; provider verifies it | Every interaction consumer depends on is proven; provider can change unconstrained fields freely | Microservices, service boundaries, async event schemas | Kawaz's axes are intra-module; contract testing addresses *inter-service* boundary spec |
| **Formal Methods (TLA+, Alloy)** (Lamport; Jackson) | Model system as state machine; exhaustively verify temporal/structural properties | Proven absence of specified bad states across all reachable states | Distributed protocols, concurrency, security models where test space is infinite and consequences are catastrophic | Supersedes testing for invariant-class properties; complements kawaz's "並行性 / レース" axis where tests can only sample |

---

## (b) Axes Kawaz's Enumeration Missed

| Missing Axis | One-Line Explanation |
|---|---|
| **Alternative / abort paths (use-case actors)** | Beyond "正常系" there are defined non-error alternative flows (user cancels, chooses option B); BDD scenario suites systematically enumerate these via scenario outlines |
| **Metamorphic properties** | If input X produces output Y, a transformed input f(X) should produce predictable output g(Y) — catches bugs when an oracle is unavailable (e.g., image processing, ML inference) |
| **Model-based oracle properties** | Run a simple reference implementation in parallel and assert the results match; PBT strategy beyond pure algebraic invariants |
| **Interaction-coverage completeness (t-way)** | For N feature flags / config knobs, full pairwise (2-way) or higher-order combinatorial coverage — not just "dangerous pairs" but *all* pairs, provably |
| **Transition pair / N-switch coverage** | Beyond "state A → state B", test sequences of transitions: "A → B → C" — defects that appear only in transition chains are missed by single-transition coverage |
| **Mutation score gate** | Whether the existing tests *detect* a change to the implementation — a meta-axis measuring test strength, not test variety |
| **Consumer contract** | The set of API fields/event fields this consumer actually uses — only relevant at service boundaries but completely absent from unit-level test design thinking |
| **Formal invariant (always/never)** | Properties that must hold in every reachable state (not just for sampled inputs): liveness, safety, deadlock-freedom — reachable only via model checking |

---

## (c) Recommended Case Comment Template

Distilled from BDD (Given/When/Then intent layer), Specification by Example (concrete example as spec anchor), and Property-Based Testing (invariant declaration):

```
// TEST-CASE
// title:     <imperative sentence: what behaviour this case proves>
//            e.g. "strips trailing newline when -n flag is set"
// axis:      <from: normal | error | boundary | edge | decision | state-transition
//             | property | regression | security | perf | concurrency | contract>
// given:     <precondition / world state>
// when:      <the action under test>
// then:      <observable postcondition — what "passing" means in concrete terms>
// invariant: <optional: property that must hold regardless of input variation>
//            e.g. "output byte count <= input byte count"
// oracle:    <optional: how correctness is judged — reference impl / algebraic rule / snapshot>
```

**Why each field:**

- `title` (BDD) — forces the author to name the *behaviour*, not the mechanism; reviewers can read the title alone and understand intent
- `axis` (ISTQB taxonomy) — declares which coverage dimension this case contributes; enables gap analysis across the suite
- `given/when/then` (Specification by Example) — decouples spec from automation; if the framework changes, the spec survives
- `invariant` (PBT) — optional but prompts the author to ask "what must always be true?"; even one property per function dramatically increases coverage confidence
- `oracle` (PBT / model-based) — makes explicit how correctness is judged; catches tests that assert *output equals expected* with no principled reason for the expected value

---

## Sources

- ISO/IEC/IEEE 29119-4:2021 — [https://www.iso.org/standard/79430.html](https://www.iso.org/standard/79430.html)
- ISTQB CTFL Syllabus v4.0.1 — [https://istqb.org/wp-content/uploads/2024/11/ISTQB_CTFL_Syllabus_v4.0.1.pdf](https://istqb.org/wp-content/uploads/2024/11/ISTQB_CTFL_Syllabus_v4.0.1.pdf)
- Hughes, J. "Specification Based Testing with QuickCheck" (FMCAD 2011) — [https://www.cs.utexas.edu/~hunt/FMCAD/FMCAD11/papers/inv8.pdf](https://www.cs.utexas.edu/~hunt/FMCAD/FMCAD11/papers/inv8.pdf)
- Adzic, G. *Specification by Example* (2011) — [https://gojko.net/books/specification-by-example/](https://gojko.net/books/specification-by-example/)
- Pact contract testing — [https://docs.pact.io/](https://docs.pact.io/)
- Mutation testing overview (Pitest/Stryker) — [https://dev.to/agileactors/measure-the-quality-of-your-tests-with-mutation-testing-1bcd](https://dev.to/agileactors/measure-the-quality-of-your-tests-with-mutation-testing-1bcd)
- TLA+ primer — [https://jack-vanlightly.com/blog/2023/10/10/a-primer-on-formal-verification-and-tla](https://jack-vanlightly.com/blog/2023/10/10/a-primer-on-formal-verification-and-tla)
- t_wada TDD workshop report — [https://developers.cyberagent.co.jp/blog/archives/11977/](https://developers.cyberagent.co.jp/blog/archives/11977/)
- Wikipedia ISO/IEC 29119 — [https://en.wikipedia.org/wiki/ISO/IEC_29119](https://en.wikipedia.org/wiki/ISO/IEC_29119)
