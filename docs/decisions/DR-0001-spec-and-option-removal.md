# DR-0001: 仕様確定 + option を撤廃した設計

- Status: Active
- Date: 2026-06-27

## Context

`die` は「stderr にメッセージを書いて exit 1 する」だけの超小粒な CLI。仕様策定にあたり、shell script で `cmd || die "msg"` のように使われる前提で「何でも気軽に渡せる」性質を最優先する必要があった。

## Decision

### Usage

```
die [opts] -- ARGS...
die [-n] <FILE
```

### Options

| option | 動作 |
|---|---|
| `--sep STR` | ARGS の区切り文字、default `" "` |
| `--trim each\|all\|none` | whitespace 処理、default `each` |
| `-n` | 末尾 LF 自動補完を disable (詳細は DR-0002) |

### 不変条件

- 出力先: 常に **stderr**
- exit code: 常に **1**
- `--` 必須 (= opts と ARGS の境界マーカー、省略時は syntax error)
- 環境変数: 一切採用しない (= 挙動はすべて argv に閉じる)

### 動作詳細

- ARGS (= `--` の後ろ) が空 + stdin が pipe / redirect → stdin を読んで stderr に転送
- ARGS と stdin の同時供給 → ARGS 優先、stdin は無視 (= 寛容)
- ARGS 空 + stdin が TTY → help を stderr に出して exit 1

### `--trim` MODE の意味

- `each`: 各 ARG の前後 ASCII whitespace を trim (= `" foo "` → `"foo"`)
- `all`: 全 ARG を `--sep` で連結後、全体の前後 ASCII whitespace を trim
- `none`: 何もしない

trim 対象は **ASCII whitespace 6 種** (`SP HT LF VT FF CR` = POSIX `[[:space:]]` 相当) のみ。NBSP (U+00A0) や U+2028 等の Unicode 拡張 whitespace は意図的に trim しない。shell の常識的な空白観 (= default IFS = `SP HT LF` + 一般的な空白制御文字) に倣う設計。

## Alternatives Considered

仕様策定で却下した案 (= 設計哲学の justify):

- **option 自由形式** (= `die -e 2 "msg"` のような flag 経路)
  - 不採用理由: leading `-` の ARG が flag 誤解釈されるリスクがある。`die "$@"` で `$@` の中身が利用者制御不能な場合に事故源になる。`--` 必須化で完全に insulate
- **環境変数経由の挙動制御** (= `DIE_SEP` 等)
  - 不採用理由: env は subshell を切らないと leak する事故源。invocation 単位で argv に閉じる方が predictable。kawaz の他リポ (= bump-semver 等) でも env 制御は廃止方向、設計哲学と一致
- **`--code` / `DIE_CODE` (= exit code 制御)**
  - 不採用理由: `die` は「失敗で死ぬ」の単一責任 tool。exit code を制御したい場面は別経路 (`cmd; exit 2`) で表現できる。exit 1 固定で十分
- **`-N` (= 明示 on の short option)**
  - 不採用理由: default 値の明示は不要 (= 書かなくても同じ)。help を膨らませる boilerplate
- **`-n` の long form (`--trailing-newline=on/off`)**
  - 不採用理由: `-n` は die の唯一の short option。よく使う方だけ short を用意し、ロングは省略
- **`die --` (= 改行のみを stderr に出力)**
  - 不採用理由: YAGNI。`echo >&2; exit 1` で代用可、規則性のためだけに残すのは過剰
- **`--help` の別経路実装**
  - 不採用理由: ARG に `--help` 文字列を素直に渡したいケース (例: error message に「see --help for details」を書く) を制約しない。`die` 単独 + stdin TTY のときだけ help を出す挙動で十分

## Consequences

### Pros

- option 撤廃 + `--` 必須化により「何でも渡せる」が CLI の特性として明確
- env 廃止で invocation 単位で挙動が完結 (= 並列実行 / subshell の事故ゼロ)
- 仕様が小さく確定しているため実装は短時間で完成見込み

### Cons / Trade-offs

- `--` 必須は **既存の bash `die()` 関数定義** (= `die "msg"` で動く) と挙動が異なる → README / help で明示
- ARG 空 + stdin TTY で help が出る挙動は最初の利用者には驚き → help 文に「TTY なら help」と書くことで認知化

## 関連

- [DR-0002](./DR-0002-pipe-lf-normalization.md) — pipe 末尾改行 normalization の default on
- [DR-0003](./DR-0003-parallel-implementation-language.md) — 実装言語の並行比較方針
- [DESIGN.md](../DESIGN.md) / [DESIGN-ja.md](../DESIGN-ja.md) — 仕様の本文
