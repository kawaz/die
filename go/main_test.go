package main

import (
	"strings"
	"testing"
)

// ─── TestTrimASCII ──────────────────────────────────────────────────────────

func TestTrimASCII(t *testing.T) {
	t.Run("each ASCII whitespace byte trimmed individually", func(t *testing.T) {
		cases := []struct {
			name  string
			input string
			want  string
		}{
			{"SP leading+trailing", " x ", "x"},
			{"HT leading+trailing", "\tx\t", "x"},
			{"LF leading+trailing", "\nx\n", "x"},
			{"VT leading+trailing", "\vx\v", "x"},
			{"FF leading+trailing", "\fx\f", "x"},
			{"CR leading+trailing", "\rx\r", "x"},
		}
		for _, tc := range cases {
			t.Run(tc.name, func(t *testing.T) {
				got := trimASCII(tc.input)
				if got != tc.want {
					t.Errorf("trimASCII(%q) = %q, want %q", tc.input, got, tc.want)
				}
			})
		}
	})

	t.Run("combined leading and trailing ASCII whitespace", func(t *testing.T) {
		got := trimASCII(" \t\n\v\f\r hello \r\f\v\n\t ")
		if got != "hello" {
			t.Errorf("got %q, want %q", got, "hello")
		}
	})

	t.Run("all-whitespace input returns empty string", func(t *testing.T) {
		got := trimASCII(" \t\n\v\f\r")
		if got != "" {
			t.Errorf("got %q, want empty string", got)
		}
	})

	t.Run("empty input returns empty string", func(t *testing.T) {
		got := trimASCII("")
		if got != "" {
			t.Errorf("got %q, want empty string", got)
		}
	})

	t.Run("interior whitespace is preserved", func(t *testing.T) {
		input := "hello \t world"
		got := trimASCII(input)
		if got != input {
			t.Errorf("got %q, want %q", got, input)
		}
	})

	t.Run("Unicode whitespace NBSP U+00A0 is NOT trimmed", func(t *testing.T) {
		input := " x "
		got := trimASCII(input)
		if got != input {
			t.Errorf("NBSP should not be trimmed: got %q, want %q", got, input)
		}
	})

	t.Run("Unicode whitespace U+2028 line separator is NOT trimmed", func(t *testing.T) {
		input := " x "
		got := trimASCII(input)
		if got != input {
			t.Errorf("U+2028 should not be trimmed: got %q, want %q", got, input)
		}
	})

	t.Run("Unicode whitespace U+3000 ideographic space is NOT trimmed", func(t *testing.T) {
		input := "　x　"
		got := trimASCII(input)
		if got != input {
			t.Errorf("U+3000 should not be trimmed: got %q, want %q", got, input)
		}
	})

	t.Run("no-op on plain string", func(t *testing.T) {
		got := trimASCII("hello")
		if got != "hello" {
			t.Errorf("got %q, want %q", got, "hello")
		}
	})
}

// ─── TestJoinArgs ───────────────────────────────────────────────────────────

func TestJoinArgs(t *testing.T) {
	t.Run("0 args returns empty string", func(t *testing.T) {
		got := joinArgs(nil, " ", "each")
		if got != "" {
			t.Errorf("got %q, want empty", got)
		}
	})

	t.Run("1 arg returned as-is (each)", func(t *testing.T) {
		got := joinArgs([]string{"hello"}, " ", "each")
		if got != "hello" {
			t.Errorf("got %q, want %q", got, "hello")
		}
	})

	t.Run("1 arg with surrounding spaces trimmed (each)", func(t *testing.T) {
		got := joinArgs([]string{" hello "}, " ", "each")
		if got != "hello" {
			t.Errorf("got %q, want %q", got, "hello")
		}
	})

	t.Run("3 args joined with default sep (each)", func(t *testing.T) {
		got := joinArgs([]string{"a", "b", "c"}, " ", "each")
		if got != "a b c" {
			t.Errorf("got %q, want %q", got, "a b c")
		}
	})

	t.Run("3 args with surrounding spaces trimmed each (each)", func(t *testing.T) {
		got := joinArgs([]string{" a ", " b ", " c "}, " ", "each")
		if got != "a b c" {
			t.Errorf("got %q, want %q", got, "a b c")
		}
	})

	t.Run("empty sep joins without separator (each)", func(t *testing.T) {
		got := joinArgs([]string{"a", "b", "c"}, "", "each")
		if got != "abc" {
			t.Errorf("got %q, want %q", got, "abc")
		}
	})

	t.Run("multi-char sep (each)", func(t *testing.T) {
		got := joinArgs([]string{"a", "b", "c"}, ", ", "each")
		if got != "a, b, c" {
			t.Errorf("got %q, want %q", got, "a, b, c")
		}
	})

	t.Run("trim=all trims whole joined result", func(t *testing.T) {
		got := joinArgs([]string{" a ", " b "}, " ", "all")
		// joined = " a   b ", then trimmed globally
		if got != "a   b" {
			t.Errorf("got %q, want %q", got, "a   b")
		}
	})

	t.Run("trim=all with leading/trailing whitespace in result", func(t *testing.T) {
		got := joinArgs([]string{"  ", "hello", "  "}, " ", "all")
		// joined = "    hello   ", trimmed = "hello"
		if got != "hello" {
			t.Errorf("got %q, want %q", got, "hello")
		}
	})

	t.Run("trim=none preserves all whitespace", func(t *testing.T) {
		got := joinArgs([]string{" a ", " b "}, " ", "none")
		if got != " a   b " {
			t.Errorf("got %q, want %q", got, " a   b ")
		}
	})

	t.Run("empty arg among non-empty args (each)", func(t *testing.T) {
		got := joinArgs([]string{"a", "", "c"}, " ", "each")
		if got != "a  c" {
			t.Errorf("got %q, want %q", got, "a  c")
		}
	})

	t.Run("empty arg that is all-whitespace becomes empty after each trim", func(t *testing.T) {
		got := joinArgs([]string{"a", "   ", "c"}, " ", "each")
		if got != "a  c" {
			t.Errorf("got %q, want %q", got, "a  c")
		}
	})

	t.Run("0 args with trim=all returns empty string", func(t *testing.T) {
		got := joinArgs(nil, " ", "all")
		if got != "" {
			t.Errorf("got %q, want empty", got)
		}
	})

	t.Run("0 args with trim=none returns empty string", func(t *testing.T) {
		got := joinArgs(nil, " ", "none")
		if got != "" {
			t.Errorf("got %q, want empty", got)
		}
	})

	t.Run("Unicode whitespace in arg not trimmed by each", func(t *testing.T) {
		got := joinArgs([]string{" x "}, " ", "each")
		if got != " x " {
			t.Errorf("NBSP should not be trimmed: got %q", got)
		}
	})

	t.Run("Unicode whitespace in arg not trimmed by all", func(t *testing.T) {
		got := joinArgs([]string{" x "}, " ", "all")
		if got != " x " {
			t.Errorf("NBSP should not be trimmed by all: got %q", got)
		}
	})
}

// ─── TestAppendLF ───────────────────────────────────────────────────────────

func TestAppendLF(t *testing.T) {
	cases := []struct {
		name      string
		input     string
		normalize bool
		want      string
	}{
		// normalize=true (default, no -n)
		{"no tail LF, normalize=true", "X", true, "X\n"},
		{"LF tail, normalize=true", "X\n", true, "X\n"},
		{"CRLF tail, normalize=true", "X\r\n", true, "X\r\n"},
		{"CR tail (no LF), normalize=true", "X\r", true, "X\r\n"},
		{"double LF tail, normalize=true", "X\n\n", true, "X\n\n"},
		{"empty, normalize=true", "", true, "\n"},

		// normalize=false (-n)
		{"no tail LF, normalize=false", "X", false, "X"},
		{"LF tail, normalize=false", "X\n", false, "X\n"},
		{"CRLF tail, normalize=false", "X\r\n", false, "X\r\n"},
		{"CR tail (no LF), normalize=false", "X\r", false, "X\r"},
		{"double LF tail, normalize=false", "X\n\n", false, "X\n\n"},
		{"empty, normalize=false", "", false, ""},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := appendLF(tc.input, tc.normalize)
			if got != tc.want {
				t.Errorf("appendLF(%q, %v) = %q, want %q", tc.input, tc.normalize, got, tc.want)
			}
		})
	}
}

func TestAppendLFBytes(t *testing.T) {
	cases := []struct {
		name      string
		input     []byte
		normalize bool
		want      []byte
	}{
		{"no tail LF, normalize=true", []byte("X"), true, []byte("X\n")},
		{"LF tail, normalize=true", []byte("X\n"), true, []byte("X\n")},
		{"CRLF tail, normalize=true", []byte("X\r\n"), true, []byte("X\r\n")},
		{"CR tail, normalize=true", []byte("X\r"), true, []byte("X\r\n")},
		{"double LF tail, normalize=true", []byte("X\n\n"), true, []byte("X\n\n")},
		{"empty, normalize=true", []byte{}, true, []byte("\n")},
		{"no tail LF, normalize=false", []byte("X"), false, []byte("X")},
		{"empty, normalize=false", []byte{}, false, []byte{}},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got := appendLFBytes(tc.input, tc.normalize)
			if string(got) != string(tc.want) {
				t.Errorf("appendLFBytes(%q, %v) = %q, want %q", tc.input, tc.normalize, got, tc.want)
			}
		})
	}
}

// ─── TestParseTrim ──────────────────────────────────────────────────────────

func TestParseTrim(t *testing.T) {
	t.Run("accepts each", func(t *testing.T) {
		v, ok := parseTrim("each")
		if !ok || v != "each" {
			t.Errorf("parseTrim(\"each\") = %q, %v; want \"each\", true", v, ok)
		}
	})
	t.Run("accepts all", func(t *testing.T) {
		v, ok := parseTrim("all")
		if !ok || v != "all" {
			t.Errorf("parseTrim(\"all\") = %q, %v; want \"all\", true", v, ok)
		}
	})
	t.Run("accepts none", func(t *testing.T) {
		v, ok := parseTrim("none")
		if !ok || v != "none" {
			t.Errorf("parseTrim(\"none\") = %q, %v; want \"none\", true", v, ok)
		}
	})

	invalids := []string{"", "Each", "EACH", "trim", "both", " each", "each ", "each\n"}
	for _, raw := range invalids {
		raw := raw
		t.Run("rejects "+strings.TrimSpace(strings.ReplaceAll(raw, "\n", "\\n"))+" ("+raw+")", func(t *testing.T) {
			_, ok := parseTrim(raw)
			if ok {
				t.Errorf("parseTrim(%q) should return false", raw)
			}
		})
	}
}

// ─── TestRun (integration) ──────────────────────────────────────────────────

func TestRunArgPath(t *testing.T) {
	t.Run("basic ARGS join and LF append", func(t *testing.T) {
		var buf strings.Builder
		code := run([]string{"--", "hello", "world"}, nil, &buf)
		if code != 1 {
			t.Errorf("exit code %d, want 1", code)
		}
		if got := buf.String(); got != "hello world\n" {
			t.Errorf("output %q, want %q", got, "hello world\n")
		}
	})

	t.Run("--sep changes separator", func(t *testing.T) {
		var buf strings.Builder
		run([]string{"--sep", ",", "--", "a", "b", "c"}, nil, &buf)
		if got := buf.String(); got != "a,b,c\n" {
			t.Errorf("output %q, want %q", got, "a,b,c\n")
		}
	})

	t.Run("--trim=none preserves whitespace", func(t *testing.T) {
		var buf strings.Builder
		run([]string{"--trim=none", "--", " a ", " b "}, nil, &buf)
		if got := buf.String(); got != " a   b \n" {
			t.Errorf("output %q, want %q", got, " a   b \n")
		}
	})

	t.Run("-n disables LF normalization", func(t *testing.T) {
		var buf strings.Builder
		run([]string{"-n", "--", "no-lf"}, nil, &buf)
		if got := buf.String(); got != "no-lf" {
			t.Errorf("output %q, want %q (no trailing LF)", got, "no-lf")
		}
	})

	t.Run("unknown option returns usage error", func(t *testing.T) {
		var buf strings.Builder
		code := run([]string{"--unknown"}, nil, &buf)
		if code != 1 {
			t.Errorf("exit code %d, want 1", code)
		}
		if !strings.Contains(buf.String(), "die:") {
			t.Errorf("expected usage error, got %q", buf.String())
		}
	})

	t.Run("--trim invalid value returns usage error", func(t *testing.T) {
		var buf strings.Builder
		code := run([]string{"--trim", "bad", "--", "x"}, nil, &buf)
		if code != 1 {
			t.Errorf("exit code %d, want 1", code)
		}
		if !strings.Contains(buf.String(), "die:") {
			t.Errorf("expected usage error, got %q", buf.String())
		}
	})
}

func TestRunStdinPath(t *testing.T) {
	t.Run("stdin without trailing LF gets LF appended", func(t *testing.T) {
		var buf strings.Builder
		code := run(nil, strings.NewReader("from stdin"), &buf)
		if code != 1 {
			t.Errorf("exit code %d, want 1", code)
		}
		if got := buf.String(); got != "from stdin\n" {
			t.Errorf("output %q, want %q", got, "from stdin\n")
		}
	})

	t.Run("stdin with trailing LF unchanged", func(t *testing.T) {
		var buf strings.Builder
		run(nil, strings.NewReader("from stdin\n"), &buf)
		if got := buf.String(); got != "from stdin\n" {
			t.Errorf("output %q, want %q", got, "from stdin\n")
		}
	})

	t.Run("-n skips LF append on stdin", func(t *testing.T) {
		var buf strings.Builder
		run([]string{"-n"}, strings.NewReader("no lf"), &buf)
		if got := buf.String(); got != "no lf" {
			t.Errorf("output %q, want %q", got, "no lf")
		}
	})
}
