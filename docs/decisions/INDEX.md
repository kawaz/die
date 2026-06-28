# Decision Records 一覧

## Active

- [DR-0001-spec-and-option-removal](./DR-0001-spec-and-option-removal.md) — 仕様確定 + option を撤廃した設計
- [DR-0002-pipe-lf-normalization](./DR-0002-pipe-lf-normalization.md) — pipe 末尾改行 normalization の default on
- [DR-0003-parallel-implementation-language](./DR-0003-parallel-implementation-language.md) — 実装言語の並行比較方針
- [DR-0005-drop-eol-option-respect-os-textmode](./DR-0005-drop-eol-option-respect-os-textmode.md) — --eol 廃止、OS text-mode 慣習に従う (Windows は CRT が \n→\r\n 自動変換)
- [DR-0006-n-is-cat-equivalent-default-is-cursor-safe](./DR-0006-n-is-cat-equivalent-default-is-cursor-safe.md) — `-n` は cat 同等 byte 透過 / default は「カーソル崩れない」だけ (refines DR-0002 / DR-0005)
- [DR-0007-adopt-zig-archive-others](./DR-0007-adopt-zig-archive-others.md) — Zig 採用、他言語実装は archive bookmark に保存 (closes DR-0003)
- [DR-0008-stdin-tty-routing-and-help-option](./DR-0008-stdin-tty-routing-and-help-option.md) — stdin routing は TTY 判定軸 (`GetConsoleMode` + Cygwin pty 名前判定)、`--help` option 導入 (refines DR-0001; exit code は DR-0009 で refine)
- [DR-0009-exit-code-policy-and-version-option](./DR-0009-exit-code-policy-and-version-option.md) — `--help` / `--version` は exit 0 (meta query)、それ以外は exit 1 / `--version` option を導入 (refines DR-0001, DR-0008)

## Archived

<!-- 現役の文脈を汚す古い DR は decisions/archive/ に退避し、ここに記載 -->

## Moved to research/

<!-- 判断記録の体を成さなくなり research/ に降格した DR -->

## Superseded

- [DR-0004-eol-option](./DR-0004-eol-option.md) — --eol auto/lf/crlf で末尾改行の方言を切替 (Superseded by DR-0005 2026-06-27)
