# die justfile (Zig implementation, post-DR-0007 unification)
#
# Layout: build.zig + build.zig.zon + src/ at the repo root (idiomatic Zig
# project). The shared shell e2e suite (tests/run.sh) drives the built
# binary; per-language unit tests live alongside src/main.zig as `test`
# blocks, run via `zig build test`.

set shell := ["bash", "-euo", "pipefail", "-c"]

set script-interpreter := ["bash", "-euo", "pipefail"]

set positional-arguments

# default behaviour: alias for `list`
default: list

# show the recipe list
list:
    @just --list --unsorted

# ---------- atomic (lint / unit / build / e2e / ci) ----------

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

# zig fmt (source format check)
[private]
lint-zig:
    zig fmt --check build.zig src/

# all lints
lint: lint-just lint-shell lint-zig

# zig unit tests (test blocks in src/main.zig)
unit:
    zig build test --summary all

# release build → bin/die (ReleaseSmall for the smallest binary)
build:
    zig build -Doptimize=ReleaseSmall
    mkdir -p bin
    cp zig-out/bin/die bin/die
    ls -lh bin/die

# e2e tests via the shared shell suite (non-TTY paths)
test: build
    DIE_BIN="$PWD/bin/die" tests/run.sh

# TTY-path e2e tests via python pty (skips if python3/pty unavailable)
test-tty: build
    DIE_BIN="$PWD/bin/die" tests/tty.sh

# CI entry point: lint + unit + build + e2e + tty
ci: lint unit build test test-tty

# ---------- gates (used by `just push`; rarely invoked directly) ----------

# working copy is clean
[private]
ensure-clean:
    bump-semver vcs is clean

# fail if the current bookmark / branch is not the default
[private]
check-on-default-branch:
    bump-semver vcs is on-default-branch

# fail if source / build / tests changed since default-branch@origin
# without bumping build.zig.zon's .version
check-version-bumped: (_check-version-bumped "build.zig" "src/" "tests/")

[private]
[script]
_check-version-bumped *target_paths:
    bn=$(bump-semver vcs get default-branch)
    if ! bump-semver vcs diff -q "${bn}@origin" -- "$@"; then
        bump-semver compare gt build.zig.zon "vcs:${bn}@origin"
    fi

# fail if build.zig.zon's .version is not greater than the latest release
[private]
[script]
check-against-latest-release:
    bn=$(bump-semver vcs get default-branch)
    bump-semver compare gt build.zig.zon "vcs:${bn}@origin"

# README-ja → README, DESIGN-ja → DESIGN translation pair freshness
[private]
check-outdated-translations: ensure-clean
    bump-semver vcs outdated 'glob:**/*-ja.md' '$1/$2.md'

# ---------- release flow ----------

# bump .version in build.zig.zon (default: patch) and create a release commit
bump-version level="patch": ensure-clean
    bump-semver "$1" build.zig.zon --write --quiet
    bump-semver vcs commit -m "Release v$(bump-semver get build.zig.zon)" build.zig.zon

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

# release.yml workflow success → refresh homebrew tap and reinstall
on-success-release:
    git -C "$(brew --repository)/Library/Taps/kawaz/homebrew-tap" pull --ff-only
    brew upgrade kawaz/tap/die
    die -- "die smoke test (post-upgrade)" || true
    echo "VERSION: $(bump-semver get build.zig.zon)"

# ---------- utility ----------

# display VERSION (from build.zig.zon) + bin --version output + size for built / installed
version:
    echo "VERSION: $(bump-semver get build.zig.zon)"
    if [ -x ./bin/die ]; then \
        echo "binary: ./bin/die ($(./bin/die --version 2>&1) / size $(wc -c <./bin/die | tr -d ' ') B)"; \
    fi
    if command -v die >/dev/null 2>&1; then \
        echo "installed: $(command -v die) ($(die --version 2>&1) / size $(wc -c <"$(command -v die)" | tr -d ' ') B)"; \
    fi

# build then run the local binary, forwarding all args (e.g. `just run --help`).
# Note: die always exits 1 by spec (DR-0001), so just reports the recipe as
# "failed" with exit 1 — that is the correct, normal outcome for `just run`.
run *ARGS: build
    ./bin/die "$@"
