package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
)

// LintEntry is one diagnosed line from a .ccr/shadow file.
type LintEntry struct {
	Line    int    // 1-based source line number
	Raw     string // raw pattern as written, trimmed of whitespace
	Status  string // "ok" | "warn" | "err"
	Class   string // "literal-unanchored" | "literal-anchored" | "glob-anchored" | "glob-unanchored" | "" if not applicable
	Key     string // lookup key for fast-path buckets; raw pattern for globs
	Message string // human-readable note when status != ok
}

// runLint is the entrypoint for `ccr-fuse lint`.
//
// Default behavior: lints `.ccr/shadow` (the rules file) AND validates
// `.ccr/config.yaml` if it exists. Either file is optional; an empty
// workspace is a no-op success. An explicit shadow path argument turns
// off the config.yaml side and lints only the named file.
//
// Exit codes: 1 if any error-status line in shadow or invalid config; 2
// on argument / IO errors.
func runLint(args []string) {
	fs := flag.NewFlagSet("lint", flag.ExitOnError)
	matchPath := fs.String("match", "", "report whether this workspace-relative path would be shadowed")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: ccr-fuse lint [--match <path>] [<.ccr/shadow file>]")
		fmt.Fprintln(os.Stderr, "  Default: lints .ccr/shadow and validates .ccr/config.yaml (if present)")
		fs.PrintDefaults()
	}
	_ = fs.Parse(args)

	exitCode := 0

	shadowPath := ".ccr/shadow"
	explicit := fs.NArg() > 0
	if explicit {
		shadowPath = fs.Arg(0)
	}

	hadShadow := lintShadow(shadowPath, *matchPath, explicit, &exitCode)

	if !explicit {
		if _, err := os.Stat(".ccr/config.yaml"); err == nil {
			if hadShadow {
				fmt.Println()
			}
			lintConfig(".ccr/config.yaml", &exitCode)
		}
	}

	if exitCode != 0 {
		os.Exit(exitCode)
	}
}

// lintShadow lints a single .ccr/shadow file. Returns true if the file
// existed and was processed. `explicit` distinguishes "user passed a path"
// from "default-discover at .ccr/shadow" — the former errors on missing
// file, the latter falls through silently.
func lintShadow(path, matchPath string, explicit bool, exitCode *int) bool {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) && !explicit {
			return false
		}
		fmt.Fprintf(os.Stderr, "ccr-fuse lint: %v\n", err)
		*exitCode = 2
		return false
	}
	defer f.Close()

	entries, err := lintReader(f)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ccr-fuse lint: read %s: %v\n", path, err)
		*exitCode = 2
		return false
	}

	var active, warns, errs int
	maxRaw := 0
	for _, e := range entries {
		if l := len(e.Raw); l > maxRaw {
			maxRaw = l
		}
		switch e.Status {
		case "ok":
			active++
		case "warn":
			warns++
		case "err":
			errs++
		}
	}
	if maxRaw < 8 {
		maxRaw = 8
	}
	for _, e := range entries {
		fmt.Printf("%s:%d: %-*s  %-4s  %s\n",
			path, e.Line, maxRaw, e.Raw, strings.ToUpper(e.Status), describe(e))
	}
	fmt.Printf("\nSummary: %d active, %d warning, %d error\n", active, warns, errs)

	if matchPath != "" {
		fmt.Printf("\nMatch report for path %q:\n", matchPath)
		matches := matchAgainst(matchPath, entries)
		if len(matches) == 0 {
			fmt.Println("  not matched by any active rule")
		} else {
			for _, m := range matches {
				fmt.Printf("  matched by line %d: %s (%s)\n", m.Line, m.Raw, m.Class)
			}
		}
	}

	if errs > 0 && *exitCode < 1 {
		*exitCode = 1
	}
	return true
}

// lintConfig parses .ccr/config.yaml and prints a short summary line.
func lintConfig(path string, exitCode *int) {
	cfg, err := ParseProjectConfig(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "%s: %v\n", path, err)
		if *exitCode < 1 {
			*exitCode = 1
		}
		return
	}

	source := "default (claude-container)"
	switch {
	case cfg.Image != "":
		source = "image: " + cfg.Image
	case cfg.Build != nil:
		source = "build: " + cfg.Build.Dockerfile
	}
	user := cfg.User
	if user == "" {
		user = "coder (default)"
	}
	fmt.Printf("%s: OK\n", path)
	fmt.Printf("  image source: %s\n", source)
	fmt.Printf("  container user: %s\n", user)
	if cfg.Resources != nil {
		if cfg.Resources.Memory != "" {
			fmt.Printf("  resources.memory: %s\n", cfg.Resources.Memory)
		}
		if cfg.Resources.CPUs > 0 {
			fmt.Printf("  resources.cpus: %d\n", cfg.Resources.CPUs)
		}
	}
	if cfg.Fuse != nil && cfg.Fuse.Cache != nil {
		fmt.Printf("  fuse.cache: %g\n", *cfg.Fuse.Cache)
	}
}

func describe(e LintEntry) string {
	if e.Message != "" {
		return e.Message
	}
	return e.Class
}

// lintReader walks the .ccr/shadow content and classifies each non-empty
// line. Errors and warnings do not abort — they show up as entries with
// their own Status. Returns I/O errors from the scanner.
func lintReader(r io.Reader) ([]LintEntry, error) {
	var out []LintEntry
	seen := map[string]int{}
	sc := bufio.NewScanner(r)
	for lineNo := 0; sc.Scan(); {
		lineNo++
		raw := strings.TrimRight(sc.Text(), "\r")
		trim := strings.TrimSpace(raw)
		if trim == "" || strings.HasPrefix(trim, "#") {
			continue
		}
		if strings.HasPrefix(trim, "!") {
			out = append(out, LintEntry{
				Line: lineNo, Raw: trim, Status: "warn",
				Message: "negation not supported; skipped",
			})
			continue
		}
		if err := validatePattern(trim); err != nil {
			out = append(out, LintEntry{
				Line: lineNo, Raw: trim, Status: "err",
				Message: err.Error() + "; skipped",
			})
			continue
		}
		if dup, ok := seen[trim]; ok {
			out = append(out, LintEntry{
				Line: lineNo, Raw: trim, Status: "warn",
				Message: fmt.Sprintf("duplicate of line %d", dup),
			})
			continue
		}
		seen[trim] = lineNo
		kind, key := classify(trim)
		out = append(out, LintEntry{
			Line:   lineNo,
			Raw:    trim,
			Status: "ok",
			Class:  className(kind, trim),
			Key:    key,
		})
	}
	return out, sc.Err()
}

func className(kind patKind, raw string) string {
	switch kind {
	case patUnanchored:
		return "literal-unanchored"
	case patAnchored:
		return "literal-anchored"
	case patGlob:
		if strings.HasPrefix(raw, "/") || strings.Contains(strings.TrimSuffix(raw, "/"), "/") {
			if strings.HasPrefix(raw, "**/") {
				return "glob-unanchored"
			}
			return "glob-anchored"
		}
		return "glob-unanchored"
	}
	return "unknown"
}

// matchAgainst runs each active lint entry against a candidate path and
// returns the entries that match. Reuses the same engine the FUSE driver
// uses, so lint output matches actual runtime behavior.
func matchAgainst(path string, entries []LintEntry) []LintEntry {
	var matched []LintEntry
	for _, e := range entries {
		if e.Status != "ok" {
			continue
		}
		r, _ := parseRulesReader(strings.NewReader(e.Raw + "\n"))
		if r.Match(path) {
			matched = append(matched, e)
		}
	}
	return matched
}
