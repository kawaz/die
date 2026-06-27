# DESIGN-ja

> [English](./DESIGN.md) | 日本語

`die` の仕様と設計判断。

## ドメイン

shell script / justfile で「**メッセージを stderr に書いて失敗 exit する**」を 1 行で書きたい場面が頻出する。bash で `die() { echo "$*" >&2; exit 1; }` を自前定義する慣習は古くからあるが、

- 各 script で書き直す boilerplate
- shell 関数なので OS 横断で共通配布できない
- justfile / docker image / 他 shell でそれぞれ別実装になる

これを **OS の単体 binary** として 1 個配布すれば、`brew install die` 1 発で全環境で使える。`/usr/bin/yes` や `/usr/bin/false` の側にいる、超小粒な base utility。

## 仕様

### Usage

```
die [opts] -- ARGS...
die [-n] <FILE
```

### Options

| option | 動作 |
|---|---|
| `--sep STR` | ARGS を結合する区切り文字、default `" "` |
| `--trim MODE` | ASCII whitespace 処理 (`each` / `all` / `none`)、default `each` |
| `-n` | LF normalization を disable (= cat 同等 byte 透過出力) |

`--trim` の MODE:

- `each`: 各 ARG の前後 ASCII whitespace を trim (= `" foo "` → `"foo"`)
- `all`: 全 ARG を `--sep` で連結後、全体の前後 ASCII whitespace を trim
- `none`: 何もしない

`--trim` が消すのは ASCII whitespace 6 種 (SP, HT, LF, VT, FF, CR = POSIX `[[:space:]]`) のみ。NBSP や U+2028 等の Unicode whitespace は意図的に対象外 (= shell の常識的な空白観に倣う)。

### 不変条件

- **出力先**: 常に stderr
- **exit code**: 常に 1
- **`--` 必須**: opts と ARGS の境界マーカー。`die foo` (= `--` なし) は syntax error
- **環境変数**: 一切採用しない (= 挙動はすべて argv に閉じる)

### stdin 経由

- ARGS (= `--` の後ろ) が **空** + stdin が pipe / redirect → stdin を読んで stderr に転送
- ARGS と stdin の **同時供給** → ARGS 優先、stdin は無視 (= 寛容)
- ARGS 空 + stdin が TTY → help を stderr に出して exit 1

### 末尾 LF normalization

`-n` を渡さない限り、入力末尾に LF が無ければ 1 つ補う。重複改行 (= 末尾 `\n\n` 等) は維持。

- ARG 経路: 連結後の末尾 char が LF でなければ補う
- stdin 経路: 同じ

`cat` の「バイナリ安全 = 一切改変しない」とは要件が違う。`die` は「人が読む stderr」を一級要件にしており、ターミナルが行頭で揃わない事故を default で防ぐ。

Windows では default モードで CRT text-mode が `\n` を `\r\n` に自動変換する。die はこの変換に介入しない。`-n` 時は CRT 変換を抑止して真の byte 透過を実現する (Rust / MoonBit / Zig は `_setmode(_O_BINARY)` を呼ぶ; Go は WriteFile が元から binary 透過)。

## 設計判断

### option を `--` 必須化した理由

「気軽に何でも渡せる」を担保するため。option 自由形式 (= `die -e 2 "msg"`) だと leading `-` の ARG が flag 誤解釈されるリスクがある。`die -- "$@"` の形に強制することで、ARG 内容の自由度を完全に確保。

### 環境変数を採用しなかった理由

env 経由の挙動制御 (= `DIE_SEP` 等) は subshell を切らないと env が漏れて事故になる。argv に閉じれば invocation 単位で完結する predictable な動作になる。

### `--code` / `DIE_CODE` を実装しなかった理由

`die` は「**失敗で死ぬ**」役割の単一責任 tool。exit code を制御したい場面は別経路 (`cmd; exit 2` 等) で表現できる。exit 1 固定で十分。

### `-N` (明示 on) を実装しなかった理由

default 値の明示は不要 (= 書かなくても同じ)。help を膨らませる boilerplate にしかならない。`-n` (off) 1 つだけで十分。

### `-n` の long form (`--trailing-newline=on/off`) を実装しなかった理由

`-n` は die の唯一の short option。よく使う方だけ short を用意し、ロングは複雑化を避けて省略。

### help の出し方

`die` 単独 + stdin TTY なら help を stderr に出す (= exit 1)。`--help` を別経路で用意しない理由は **option 撤廃の徹底**: ARG に `--help` 文字列を素直に渡したいケース (例: error message に「see --help for details」を書く) を制約しない。

### 「pipe 文脈で改行付与」が `cat` と違う件の説明責任

`die` を `cat <file | die` で使うと **末尾改行欠落を補う**点で `cat` と挙動が違う。これは die の用途 (= 人が読む stderr) を踏まえた意図的判断であり、`-n` で `cat` と同じバイト安全モードにできる。help / README で明示し、混乱を防ぐ。

## 配布

実装言語は **DR-0001** で並行実装比較 (Go / Rust / MoonBit / Zig) を経て決定。homebrew tap (kawaz/tap) 配布を想定。

## 関連

- [DR-0001](./decisions/DR-0001-spec-and-option-removal.md) — 仕様確定 + option を撤廃した設計
- [DR-0002](./decisions/DR-0002-pipe-lf-normalization.md) — pipe 末尾改行 normalization の default on
- [DR-0003](./decisions/DR-0003-parallel-implementation-language.md) — 実装言語の並行比較方針
