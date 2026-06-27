# ROADMAP

`die` の今後の検討項目。

## v0.1.0 (= 初版)

- 仕様確定 (= DR-0001)
- 並行実装 (Go / Rust / MoonBit / Zig) と比較
- 採用言語決定 (1 実装に絞る)
- homebrew tap (kawaz/tap) 配布
- dogfood (= kawaz/bump-semver, claude-cmux-msg 等の justfile / shell script で利用)

## 将来候補 (= YAGNI で見送り中)

- `--prefix STR` (= ログレベル prefix、`ERROR:` 等)
- color output (= TTY なら赤、それ以外スルー)

これらは追加されない可能性が高い (= die は単一責任の小道具)。dogfood で具体的な需要が見えたら DR 起票して判断。
