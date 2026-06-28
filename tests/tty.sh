#!/usr/bin/env bash
#
# TTY-path e2e tests for `die`.
#
# DR-0008 spec: with no `--` and stdin classified as a real TTY (= terminal),
# die emits help to stderr and exits 1. This file uses python3's `pty`
# module to allocate a real pseudo-terminal and assign it to die's stdin,
# which is the only portable way to test "stdin is a TTY" outside of an
# actual interactive shell.
#
# Run as:
#   DIE_BIN=/path/to/die tests/tty.sh
#
# Skips itself with a recorded reason if python3 or pty.openpty() is
# unavailable (e.g. Windows runners without a Cygwin/MSYS2 python).
#
# tests/run.sh covers everything that does NOT require a real TTY (= every
# fstat type other than terminal: pipe, file, /dev/null, socket, …). The two
# files together cover the full DR-0008 stdin routing contour.

set -uo pipefail

DIE_BIN="${DIE_BIN:-${1:-}}"
if [ -z "${DIE_BIN}" ]; then
    echo "usage: DIE_BIN=<path-to-die> $0   (or: $0 <path-to-die>)" >&2
    exit 2
fi
if [ ! -x "${DIE_BIN}" ]; then
    echo "DIE_BIN '${DIE_BIN}' is not executable" >&2
    exit 2
fi

# python3 + pty availability check.
if ! command -v python3 >/dev/null 2>&1; then
    echo "SKIP tests/tty.sh: python3 not found (TTY-path tests need pty allocator)" >&2
    exit 0
fi
if ! python3 -c 'import pty; pty.openpty()' >/dev/null 2>&1; then
    echo "SKIP tests/tty.sh: pty.openpty() not available on this platform" >&2
    exit 0
fi

pass=0
fail=0
failures=()

# Drive die with stdin attached to a real pseudo-terminal.
#
# Usage: tty_case NAME EXPECT_EXIT EXPECT_STDERR_NONEMPTY MUST_SUBSTR -- CMD ARGS...
#   EXPECT_EXIT             : integer expected exit code
#   EXPECT_STDERR_NONEMPTY  : "1" if stderr is expected to contain >=1 byte,
#                             "0" if stderr is expected to be empty
#   MUST_SUBSTR             : if non-empty, stderr must literally contain this
#                             substring (used to assert "this is help text",
#                             not just any error string). Pass '' to skip.
#
# stdout is asserted to be empty (die invariant).
# stdin is connected to a freshly-allocated pty; the master side is closed
# immediately so the child sees EOF right away (no interactive input is sent).
tty_case() {
    local name=$1 expect_exit=$2 expect_err_nonempty=$3 must_substr=$4
    shift 4
    if [ "${1:-}" != "--" ]; then
        echo "internal: tty_case '${name}' missing -- separator" >&2
        return 2
    fi
    shift

    # Pass argv + MUST_SUBSTR to python via env to avoid quoting hazards.
    local _tmp_out _tmp_err _tmp_meta
    _tmp_out=$(mktemp); _tmp_err=$(mktemp); _tmp_meta=$(mktemp)
    MUST_SUBSTR_FOR_PY="${must_substr}" \
    STDOUT_FILE="${_tmp_out}" STDERR_FILE="${_tmp_err}" META_FILE="${_tmp_meta}" \
    python3 - "$@" <<'PYEOF'
import os, pty, subprocess, sys, json
argv = sys.argv[1:]
out_path = os.environ["STDOUT_FILE"]
err_path = os.environ["STDERR_FILE"]
meta_path = os.environ["META_FILE"]
master, slave = pty.openpty()
result = {"timeout": False, "exit": -1, "out_len": -1, "err_len": -1, "error": ""}
try:
    proc = subprocess.Popen(argv, stdin=slave, stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, close_fds=True)
    os.close(slave); os.close(master)
    try:
        out, err = proc.communicate(timeout=10)
    except subprocess.TimeoutExpired:
        proc.kill()
        out, err = proc.communicate()
        result["timeout"] = True
    with open(out_path, "wb") as f: f.write(out)
    with open(err_path, "wb") as f: f.write(err)
    result["exit"] = proc.returncode
    result["out_len"] = len(out)
    result["err_len"] = len(err)
except Exception as e:
    result["error"] = str(e)
with open(meta_path, "w") as f: json.dump(result, f)
PYEOF

    local actual_exit actual_out_len actual_err_len timeout error err_text
    actual_exit=$(python3 -c 'import sys,json; print(json.load(open(sys.argv[1])).get("exit", -99))' "${_tmp_meta}")
    actual_out_len=$(python3 -c 'import sys,json; print(json.load(open(sys.argv[1])).get("out_len", -99))' "${_tmp_meta}")
    actual_err_len=$(python3 -c 'import sys,json; print(json.load(open(sys.argv[1])).get("err_len", -99))' "${_tmp_meta}")
    timeout=$(python3 -c 'import sys,json; print(json.load(open(sys.argv[1])).get("timeout", False))' "${_tmp_meta}")
    error=$(python3 -c 'import sys,json; print(json.load(open(sys.argv[1])).get("error", ""))' "${_tmp_meta}")
    err_text=$(cat "${_tmp_err}")
    rm -f "${_tmp_out}" "${_tmp_err}" "${_tmp_meta}"

    local ok=1
    [ "${actual_exit}" = "${expect_exit}" ] || ok=0
    [ "${actual_out_len}" = "0" ] || ok=0
    if [ "${expect_err_nonempty}" = "1" ]; then
        [ "${actual_err_len}" -gt 0 ] || ok=0
    else
        [ "${actual_err_len}" = "0" ] || ok=0
    fi
    if [ -n "${must_substr}" ]; then
        case "${err_text}" in *"${must_substr}"*) ;; *) ok=0 ;; esac
    fi
    [ "${timeout}" = "False" ] || ok=0
    [ -z "${error}" ] || ok=0

    if [ "${ok}" = "1" ]; then
        pass=$((pass + 1))
        printf '  PASS  %s\n' "${name}"
    else
        fail=$((fail + 1))
        failures+=("${name}")
        printf '  FAIL  %s\n' "${name}"
        printf '        exit:        want=%s got=%s\n' "${expect_exit}" "${actual_exit}"
        printf '        stdout_len:  want=0 got=%s\n' "${actual_out_len}"
        if [ "${expect_err_nonempty}" = "1" ]; then
            printf '        stderr_len:  want>0 got=%s\n' "${actual_err_len}"
        else
            printf '        stderr_len:  want=0 got=%s\n' "${actual_err_len}"
        fi
        if [ -n "${must_substr}" ]; then
            printf '        stderr_contains_%q=%s\n' "${must_substr}" \
                "$(case "${err_text}" in *"${must_substr}"*) echo yes ;; *) echo no ;; esac)"
        fi
        [ "${timeout}" = "False" ] || printf '        timeout!\n'
        [ -z "${error}" ] || printf '        python error: %s\n' "${error}"
    fi
}

echo "== running TTY-path tests against ${DIE_BIN} =="

# DR-0008: no `--` + stdin TTY → full help text (contains "Usage:") to
# stderr, exit 1. The substring check distinguishes the help branch from
# any other error path (e.g. unknown-option error has no "Usage:").
tty_case 'tty/no-dash-dash-tty-stdin-help' 1 1 'Usage:' -- "${DIE_BIN}"

# `die --help` under a TTY also emits the full help text.
tty_case 'tty/help-option-under-tty'       1 1 'Usage:' -- "${DIE_BIN}" --help

# DR-0008: `--` present + stdin TTY → ARG path (TTY is ignored, ARGS win).
# Output is the ARG bytes, NOT help — so stderr must NOT contain "Usage:".
# We only assert exit=1 + stderr non-empty here; full byte match is in run.sh.
tty_case 'tty/dash-dash-arg-under-tty'     1 1 '' -- "${DIE_BIN}" -- foo

echo
echo "==== summary: pass=${pass} fail=${fail} ===="
if [ "${fail}" -gt 0 ]; then
    printf 'failures:\n'
    for f in "${failures[@]}"; do printf '  - %s\n' "${f}"; done
    exit 1
fi
exit 0
