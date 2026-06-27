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
	"runtime"
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
  --eol MODE      End-of-line for the appended terminator:
                  auto (default; CRLF on Windows, LF elsewhere) | lf | crlf
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
	eol := defaultEOL()
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
		case a == "--eol":
			if i+1 >= len(args) {
				return usageErr(stderr, "--eol requires a value")
			}
			e, ok := parseEOL(args[i+1])
			if !ok {
				return usageErr(stderr, fmt.Sprintf("--eol must be auto|lf|crlf, got %q", args[i+1]))
			}
			eol = e
			i += 2
		case strings.HasPrefix(a, "--eol="):
			raw := strings.TrimPrefix(a, "--eol=")
			e, ok := parseEOL(raw)
			if !ok {
				return usageErr(stderr, fmt.Sprintf("--eol must be auto|lf|crlf, got %q", raw))
			}
			eol = e
			i++
		default:
			return usageErr(stderr, fmt.Sprintf("unknown option or missing -- before ARGS: %q", a))
		}
	}

	// ARG path: anything after "--", including zero args.
	if sawDashDash {
		out := joinArgs(rest, sep, trim)
		out = appendEOL(out, normalize, eol)
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
	out := appendEOLBytes(data, normalize, eol)
	_, _ = stderr.Write(out)
	return exitFail
}

// parseEOL returns the resolved 2-character (or 1-character) terminator,
// translating auto into the build-time platform default.
func parseEOL(v string) (string, bool) {
	switch v {
	case "auto":
		return defaultEOL(), true
	case "lf":
		return "\n", true
	case "crlf":
		return "\r\n", true
	default:
		return "", false
	}
}

func defaultEOL() string {
	if runtime.GOOS == "windows" {
		return "\r\n"
	}
	return "\n"
}

func parseTrim(v string) (string, bool) {
	switch v {
	case "each", "all", "none":
		return v, true
	default:
		return "", false
	}
}

// joinArgs trims/joins per DR-0001 spec. trim removes ONLY the 6 ASCII
// whitespace bytes (' ', '\t', '\n', '\v', '\f', '\r'); Unicode whitespace
// (NBSP, U+2028, etc.) is intentionally left alone — kawaz wants shell-default
// IFS semantics, not Unicode-extended whitespace.
func joinArgs(args []string, sep, trim string) string {
	switch trim {
	case "each":
		parts := make([]string, len(args))
		for i, a := range args {
			parts[i] = trimASCII(a)
		}
		return strings.Join(parts, sep)
	case "all":
		return trimASCII(strings.Join(args, sep))
	case "none":
		return strings.Join(args, sep)
	}
	return strings.Join(args, sep)
}

func trimASCII(s string) string {
	return strings.TrimFunc(s, isASCIIWhitespace)
}

func isASCIIWhitespace(r rune) bool {
	switch r {
	case ' ', '\t', '\n', '\v', '\f', '\r':
		return true
	}
	return false
}

// appendEOL appends `eol` to s if normalisation is enabled AND s does not
// already end with LF or CRLF. Pre-existing terminators are left alone — `eol`
// only controls which terminator is appended to an unterminated input.
func appendEOL(s string, normalize bool, eol string) string {
	if !normalize {
		return s
	}
	if endsWithEOL(s) {
		return s
	}
	return s + eol
}

func appendEOLBytes(b []byte, normalize bool, eol string) []byte {
	if !normalize {
		return b
	}
	if bytesEndWithEOL(b) {
		return b
	}
	return append(b, eol...)
}

func endsWithEOL(s string) bool {
	return len(s) > 0 && s[len(s)-1] == '\n'
}

func bytesEndWithEOL(b []byte) bool {
	return len(b) > 0 && b[len(b)-1] == '\n'
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
