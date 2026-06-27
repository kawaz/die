# テスト設計規律 + 強制 mechanism の体系化 (synthesis)

Date: 2026-06-27. Sources: cc-ecosystem / industry-bok / kawaz-repos / enforcement reports.

---

## 1. テスト設計規律の体系

| 軸 | 何を保証 | 適用場面 | industry 対応概念 |
|---|---|---|---|
| **正常系** | 主要フローが動く | 常に | Use-case main path |
| **代替/中断パス** | actor の選択肢・キャンセルが正しく動く | ユーザ操作を持つ機能 | BDD scenario outline |
| **エラー系** | 不正入力・失敗で正しく失敗する | 常に | Error/exception path |
| **同値分割** | 同じ振る舞いになる入力クラスを代表値1つで網羅 | 入力空間が広い | ISTQB EP |
| **境界値** | off-by-one が集中する境界±1 を押さえる | 順序型・長さ・インデックス | ISTQB BVA |
| **デシジョンテーブル** | 複数条件の組合せを網羅(don't-care 削減込み) | ビジネスルール | ISTQB Decision Table |
| **ペア網羅 (t-way)** | 全2-way ペアを証明可能な最小集合でカバー | 設定フラグ・プラットフォーム行列 | Pairwise / NIST t-way |
| **状態遷移 (N-switch)** | N=0: 全状態 / N=1: 全遷移 / N=2: 遷移ペア | FSM・プロトコル・セッション | ISTQB State Transition |
| **プロパティ / 不変条件** | 入力変換後も成立する代数的性質 | 純粋関数・ラウンドトリップ | Property-Based Testing |
| **メタモルフィック** | oracle がないとき変換ペアで間接検証 | ML推論・画像処理 | Metamorphic Testing |
| **回帰** | 過去 bug が再発しない | 修正時は必ず | Regression anchor |
| **並行性/競合** | 並列実行でも不変条件が崩れない | 共有状態・チャネル | Concurrency testing |
| **セキュリティ/認可** | injection・権限昇格パスが閉じている | 外部入力を受ける層 | Security boundary |
| **性能境界** | 大入力でタイムアウト・OOM しない | クリティカルパス | Performance threshold |

kawaz の tdd-twada には「代替/中断パス」「メタモルフィック」「ペア網羅(全量)」「N-switch」が未明示。

---

## 2. テストケースに込めるべき項目

| 項目 | 説明 | 必須/任意 | 例 |
|---|---|---|---|
| `title` | "この case が証明する振る舞い" を動詞文で | **必須** | `"strips trailing newline when -n flag is set"` |
| `axis` | 上表1の軸から1つ選ぶ | **必須** | `boundary` / `decision` / `regression` |
| `given` | 前提条件・世界状態 | **必須** | `stdin is empty` |
| `when` | テスト対象の操作 | **必須** | `die -n "foo"` |
| `then` | 観測可能な事後条件 (具体値) | **必須** | `exit 0, stdout == "foo"` |
| `invariant` | 入力によらず常に成立すべき性質 | 任意 | `output_bytes <= input_bytes` |
| `oracle` | 正解の判定方法 (参照実装/代数規則) | 任意 | `reference_impl(x) == sut(x)` |
| `dr_ref` | 関連する DR 番号 (bump-semver 方式) | 任意 | `DR-0006` |

コメントブロック形式は `// TEST-DESIGN` ヘッダで統一 (enforcement hook と対応)。

---

## 3. tdd-twada.md の改訂 / 後継 rule 提案

**残すもの:** RED→GREEN→REFACTOR サイクル規律、"テストは動く仕様書" の思想、改変禁止ルール。

**削るもの:** 箇条書き形式の "観点リスト" (コンテキスト量に対して網羅性が低い)。

**追加するもの:**
- 上表 1 の軸分類と `TEST-DESIGN` コメントブロック書式を規範として組み込む
- "代替/中断パス" "メタモルフィック" の明示
- bump-semver 方式の `DR-xxxx` 参照をスペッククリティカルなグループに推奨
- e2e vs unit 責務分割の宣言を要求 (die/tests/run.sh パターン)
- 後継ファイル名: `tdd-and-test-design.md` (tdd-twada.md を supersede)

---

## 4. 強制 mechanism の最終推奨

**3層スタック:**

| 層 | 機構 | サボり耐性 | 役割 |
|---|---|---|---|
| **Tier 1 (構造バリア)** | `PreToolUse(Write)` hook — テストファイル書き込み時に `TEST-DESIGN` ブロックをgrep, 不在なら `exit 1` でブロック | 高 — agent は出力経路を迂回できない | 書き時点での強制 |
| **Tier 2 (closing gate)** | CI linter — 全テスト関数に `TEST-DESIGN` コメントがあるか assert | 高 — CI 失敗は可視かつ永続 | Bash 経由書き込みの漏れも捕捉 |
| **Tier 3 (説明層)** | `tdd-and-test-design.md` rule + `/test-design` skill | なし — advisory | hook エラーを読めるようにする |

**kawaz の "サボる懸念" への回答:** TaskCreate は task を作って即 done にできる。rule text は読み飛ばせる。hook だけは Write 呼び出しそのものをブロックするため、agent は `TEST-DESIGN` ブロックを書かない限り test ファイルを1行も書けない。CI linter はその防線が漏れた場合の二重確認。両方ともに `bypassPermissions` 無効化の対象外。

---

## 5. 次のアクション

1. **`kawaz/die` の `.claude/settings.json`** に `PreToolUse(Write)` hook を追加 (enforcement-report §c のスクリプトをベースに `TEST-DESIGN` grep 版を採用)
2. **CI linter script** (`tests/lint-test-design.sh` など) を追加し、`run.sh` または workflow から呼ぶ
3. **`tdd-and-test-design.md`** を `for-all/rules/` に新規作成、`tdd-twada.md` に `Superseded by tdd-and-test-design.md` を付記
4. **`/test-design` skill** (`SKILL.md`) を kawaz-die または claude-rules-personal に追加 (上表 2 のテンプレートを提示する参照 skill)
5. **bump-semver 方式の DR-ref パターン** を `tdd-and-test-design.md` に "推奨パターン" として明記し、スペッククリティカルなテストグループへ適用を促す
