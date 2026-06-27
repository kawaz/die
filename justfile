# die justfile
#
# Task runner during the parallel-implementation phase. Each impl lives
# in its own directory (go/, rust/, mbt/, zig/) and exposes the same
# `bin/die` artifact via per-lang recipes. The shared shell-based test
# suite (tests/) is run against any one of them.
#
# bump-semver is consumed as an external CLI (= die does not dogfood
# itself yet; that happens after a winning implementation is picked).

set shell := ["bash", "-euo", "pipefail", "-c"]

set script-interpreter := ["bash", "-euo", "pipefail"]

set positional-arguments

# default behaviour: alias for `list`
default: list

# show the recipe list
list:
    @just --list --unsorted

# ---------- atomic (lint / test / build) ----------

# just --fmt (justfile self-format check)
[private]
lint-just:
    just --unstable --fmt --check

# shellcheck on tests/ (only if shellcheck and any *.sh present)
[private]
[script]
lint-shell:
    if ! command -v shellcheck >/dev/null 2>&1; then
        echo "shellcheck not installed, skipping" >&2
        exit 0
    fi
    shopt -s nullglob globstar
    files=(tests/**/*.sh)
    [ ${#files[@]} -gt 0 ] || exit 0
    shellcheck "${files[@]}"

# all lints (delegates per-language lints once impls exist)
lint: lint-just lint-shell

# run shared shell tests against IMPL (auto-detect first built impl when empty;
# skip with a warning if no impl has been built yet — bootstrap-friendly)
test IMPL='':
    @impl="$1"; \
    if [ -z "$impl" ]; then \
        for cand in go rust mbt zig; do \
            if [ -x "$cand/bin/die" ]; then impl="$cand"; break; fi; \
        done; \
    fi; \
    if [ -z "$impl" ]; then \
        echo "[test] no built impl found yet — skipping (run 'just build-<lang>' first)" >&2; \
        exit 0; \
    fi; \
    if [ ! -x "$impl/bin/die" ]; then \
        echo "[test] $impl/bin/die missing — build it first" >&2; exit 1; \
    fi; \
    if [ ! -x tests/run.sh ]; then \
        echo "[test] tests/run.sh not present yet — skipping" >&2; exit 0; \
    fi; \
    echo "running tests/ against $impl/bin/die"; \
    DIE_BIN="$PWD/$impl/bin/die" tests/run.sh

# build every implementation that has its source tree present (skip absent ones)
build:
    @for impl in go rust mbt zig; do \
        if [ -d "$impl" ]; then \
            echo "==> build-$impl"; \
            just "build-$impl"; \
        fi; \
    done

# ---------- per-language build recipes (added on demand) ----------

# go build → go/bin/die
[private]
build-go:
    cd go && go build -trimpath -ldflags "-s -w -X main.version=v$(cat ../VERSION)" -o bin/die ./...

# cargo build → rust/bin/die (release)
[private]
build-rust:
    cd rust && cargo build --release && mkdir -p bin && cp target/release/die bin/die

# moon build → mbt/bin/die (native backend)
[private]
build-mbt:
    cd mbt && moon build --target native --release && mkdir -p bin && cp target/native/release/build/main/main.exe bin/die

# zig build-exe → zig/bin/die
[private]
build-zig:
    cd zig && zig build -Doptimize=ReleaseSmall && mkdir -p bin && cp zig-out/bin/die bin/die

# lint + build + test (CI entry point; runs whatever impl is built)
ci: lint build test

# ---------- gates (push の内部、利用者が直接叩くことほぼなし) ----------

# working copy is clean
[private]
ensure-clean:
    bump-semver vcs is clean

# fail if the current bookmark / branch is not the default
[private]
check-on-default-branch:
    bump-semver vcs is on-default-branch

# fail if impl/tests changed since default-branch@origin without bumping VERSION
check-version-bumped: (_check-version-bumped "go/" "rust/" "mbt/" "zig/" "tests/")

[private]
[script]
_check-version-bumped *target_paths:
    bn=$(bump-semver vcs get default-branch)
    if ! bump-semver vcs diff -q "${bn}@origin" -- "$@"; then
        bump-semver compare gt VERSION "vcs:${bn}@origin"
    fi

# fail if VERSION is not greater than the latest release
[private]
[script]
check-against-latest-release:
    bn=$(bump-semver vcs get default-branch)
    bump-semver compare gt VERSION "vcs:${bn}@origin"

# README-ja → README, DESIGN-ja → DESIGN translation pair freshness
[private]
check-outdated-translations: ensure-clean
    bump-semver vcs outdated 'glob:**/*-ja.md' '$1/$2.md'

# ---------- release flow ----------

# bump VERSION (default: patch) and create a release commit
bump-version level="patch": ensure-clean
    bump-semver "$1" VERSION --write --quiet
    bump-semver vcs commit -m "Release v$(bump-semver get VERSION)" VERSION

# release push: default-branch only, all gates on
push: check-on-default-branch ci check-outdated-translations check-version-bumped
    bump-semver vcs push --branch "$(bump-semver vcs get default-branch)" --jj-bookmark-auto-advance
    @echo "[hint] gh-monitor:watch-workflow --sha $(bump-semver vcs get commit-id --rev "$(bump-semver vcs get default-branch)") --on-success release.yml 'just on-success-release' kawaz/die"

# feature push: any non-default bookmark/branch; ensure-clean + ci only
[script]
push-wip: ensure-clean ci
    bn=$(bump-semver vcs get default-branch)
    if cur=$(bump-semver vcs get current-branch 2>/dev/null); then
        target="$cur"
    else
        rc=$?
        if [ "$rc" -eq 4 ] && bump-semver vcs is jj; then
            ws=$(bump-semver vcs get worktree-name)
            [ -n "$ws" ] && [ "$ws" != "$bn" ] || exit 1
            bump-semver vcs bookmark set "$ws" -r @
            target="$ws"
        else
            exit "$rc"
        fi
    fi
    [ "$target" != "$bn" ] || exit 1
    bump-semver vcs push --branch "$target" --jj-bookmark-auto-advance

# release.yml workflow success → refresh homebrew tap and verify
on-success-release:
    git -C "$(brew --repository)/Library/Taps/kawaz/homebrew-tap" pull --ff-only
    brew upgrade kawaz/tap/die
    die --version 2>&1 || true

# ---------- utility ----------

# display VERSION + any built binary versions
version:
    echo "VERSION: $(cat VERSION)"
    for impl in go rust mbt zig; do \
        if [ -x "$impl/bin/die" ]; then \
            echo "$impl: $($impl/bin/die --version 2>&1 || echo '(no --version)')"; \
        fi; \
    done
    if command -v die >/dev/null 2>&1; then echo "installed: $(die --version 2>&1 || echo '(no --version)')"; fi
