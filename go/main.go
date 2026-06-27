// Command die writes a message to stderr and exits 1.
//
// Usage:
//
//	die [opts] -- ARGS...
//	die [-n] <FILE
//
// Spec: see ../docs/DESIGN.md and ../docs/decisions/DR-0001 / DR-0002.
package main

import (
	"fmt"
	"io"
	"os"
	"strings"
)

// version is overwritten at build time via -ldflags "-X main.version=...".
var version = "dev"

const (
	exitFail   = 1
	helpText   = `die — print ARGS (or stdin) to stderr and exit 1.

Usage:
  die [opts] -- ARGS...
  die [-n] <FILE

Options:
  --sep STR       Joiner between ARGS, default " "
  --trim MODE     Whitespace handling: each (default) | all | none
  -n              Disable trailing-LF normalization (stdin path)

Behavior:
  - Output is always stderr, exit code is always 1.
  - "--" is required when ARGS are present.
  - With no ARGS, stdin (pipe/redirect) is forwarded to stderr; a missing
    trailing LF is appended unless -n is given.
  - On a TTY with no ARGS, this help is printed and exit 1.
`
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdin, os.Stderr))
}

func run(args []string, stdin io.Reader, stderr io.Writer) int {
	sep := " "
	trim := "each"
	normalize := true

	// Phase 1: parse opts (everything before "--"). Any non-opt token before
	// "--" is treated as a missing-"--" error (DR-0001: "die foo" is invalid).
	var rest []string
	sawDashDash := false
	i := 0
	for i < len(args) {
		a := args[i]
		switch {
		case a == "--":
			sawDashDash = true
			rest = args[i+1:]
			i = len(args)
		case a == "-n":
			normalize = false
			i++
		case a == "--sep":
			if i+1 >= len(args) {
				return usageErr(stderr, "--sep requires a value")
			}
			sep = args[i+1]
			i += 2
		case strings.HasPrefix(a, "--sep="):
			sep = strings.TrimPrefix(a, "--sep=")
			i++
		case a == "--trim":
			if i+1 >= len(args) {
				return usageErr(stderr, "--trim requires a value")
			}
			mode, ok := parseTrim(args[i+1])
			if !ok {
				return usageErr(stderr, fmt.Sprintf("--trim must be each|all|none, got %q", args[i+1]))
			}
			trim = mode
			i += 2
		case strings.HasPrefix(a, "--trim="):
			raw := strings.TrimPrefix(a, "--trim=")
			mode, ok := parseTrim(raw)
			if !ok {
				return usageErr(stderr, fmt.Sprintf("--trim must be each|all|none, got %q", raw))
			}
			trim = mode
			i++
		default:
			return usageErr(stderr, fmt.Sprintf("unknown option or missing -- before ARGS: %q", a))
		}
	}

	// ARG path: anything after "--", including zero args.
	if sawDashDash {
		out := joinArgs(rest, sep, trim)
		out = appendLF(out, normalize)
		_, _ = io.WriteString(stderr, out)
		return exitFail
	}

	// No "--" and the opt loop consumed everything cleanly → stdin path.
	// (A non-opt token would have been rejected above with usage error.)

	// Decide stdin handling: TTY → help; otherwise → forward.
	if isTTY(stdin) {
		_, _ = io.WriteString(stderr, helpText)
		return exitFail
	}
	data, err := io.ReadAll(stdin)
	if err != nil {
		fmt.Fprintf(stderr, "die: reading stdin: %v\n", err)
		return exitFail
	}
	out := appendLFBytes(data, normalize)
	_, _ = stderr.Write(out)
	return exitFail
}

func parseTrim(v string) (string, bool) {
	switch v {
	case "each", "all", "none":
		return v, true
	default:
		return "", false
	}
}

// joinArgs trims/joins per DR-0001 spec.
func joinArgs(args []string, sep, trim string) string {
	switch trim {
	case "each":
		parts := make([]string, len(args))
		for i, a := range args {
			parts[i] = strings.TrimSpace(a)
		}
		return strings.Join(parts, sep)
	case "all":
		return strings.TrimSpace(strings.Join(args, sep))
	case "none":
		return strings.Join(args, sep)
	}
	return strings.Join(args, sep)
}

// appendLF ensures the trailing byte is LF unless `normalize` is false. CRLF
// terminators are treated as LF (i.e. not duplicated). Empty input becomes
// "\n" (or "" with normalize=false). Pre-existing duplicate LFs (e.g. "\n\n")
// are preserved.
func appendLF(s string, normalize bool) string {
	if !normalize {
		return s
	}
	if len(s) == 0 || s[len(s)-1] != '\n' {
		return s + "\n"
	}
	return s
}

func appendLFBytes(b []byte, normalize bool) []byte {
	if !normalize {
		return b
	}
	if len(b) == 0 || b[len(b)-1] != '\n' {
		return append(b, '\n')
	}
	return b
}

func usageErr(stderr io.Writer, msg string) int {
	fmt.Fprintf(stderr, "die: %s\n", msg)
	return exitFail
}

// isTTY reports whether r is a terminal. Only os.File is considered; any
// other Reader (bytes.Buffer in tests etc.) is treated as non-TTY.
func isTTY(r io.Reader) bool {
	f, ok := r.(*os.File)
	if !ok {
		return false
	}
	fi, err := f.Stat()
	if err != nil {
		return false
	}
	return (fi.Mode() & os.ModeCharDevice) != 0
}
