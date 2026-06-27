# die

> [English](./README.md) | 日本語

stderr にメッセージを書いて exit 1 する小さな CLI。

## 動機

bash script や justfile で `cmd || die "context"` のように書ける汎用 `die` を、shell 関数の自前定義ではなく **OS の単体 binary** として配布する。Perl/Ruby の `die` 相当を shell から呼べるようにする。

## インストール

実装言語の検討中 (= Go / Rust / MoonBit / Zig での並行実装と比較)。homebrew tap 配布を想定。

## 使い方

```sh
die [opts] -- ARGS...
die [-n] <FILE
```

### Options

| option | 動作 |
|---|---|
| `--sep STR` | ARGS を結合する文字、default `" "` |
| `--trim MODE` | ASCII whitespace 処理 (each / all / none)、default `each` |
| `--eol MODE` | 補完する EOL (auto / lf / crlf)、default `auto` |
| `-n` | 末尾 LF の自動補完を disable |

### 例

```sh
die -- "config error: missing token"
die --sep ', ' -- "stale build" "no manifest"
some-cmd | die
cmd_with_lf | die -n
```

### 動作

- 出力は常に **stderr**
- exit code は **常に 1** (option / env で変更不可)
- `--` の前は opts、後ろは ARGS。`--` は **必須**
- stdin (= file redirect / pipe) 入力時、default で末尾改行を保証 (= 内容に LF が無ければ補う)。`cat` と異なり「人が読む stderr」を要件に倒している
- ARGS 経由が優先、stdin と同時供給時は stdin を無視

## ドキュメント

- [DESIGN-ja.md](./docs/DESIGN-ja.md) — 仕様と設計判断
- [STRUCTURE.md](./docs/STRUCTURE.md) — リポジトリ物理構造
- [ROADMAP.md](./docs/ROADMAP.md) — 将来検討項目

## ライセンス

MIT License, Yoshiaki Kawazu (@kawaz)
