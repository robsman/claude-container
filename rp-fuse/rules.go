package main

import (
	"bufio"
	"errors"
	"io"
	"log"
	"os"
	"path/filepath"
	"strings"

	ignore "github.com/sabhiram/go-gitignore"
)

// Rules matches paths against a .gitignore-style pattern set.
//
// Supported syntax (subset of gitignore):
//   - * matches any sequence of chars except '/'
//   - ** matches any number of path components
//   - ? matches a single char except '/'
//   - [abc] character class
//   - Leading '/'  anchors the pattern to the workspace root
//   - Trailing '/' restricts the pattern to directories
//   - Unanchored patterns match at any depth (gitignore default)
//   - Leading '!' negates the rule (re-exposes a previously-shadowed path);
//     last matching rule wins per gitignore semantics. See ADR-0011.
//
// Match is two-tier:
//  1. Literal fast-path: O(1) hash lookup against unanchored basenames and
//     anchored paths. Most real-world .rp/shadow patterns are literals
//     (node_modules, .env.local, …). Skipped entirely when ANY negation
//     rule is present — a positive literal match can be overridden by a
//     later '!' rule, so we have to walk the full ordered rule set in
//     that case.
//  2. Glob / ordered fallback: go-gitignore regex match for patterns
//     containing *, ?, [, or when any negation is present (positive +
//     negative rules together compile to one ordered matcher whose
//     MatchesPath returns the last-match-wins result).
//
// HostNode never calls Match on paths whose ancestors already matched a rule (those
// route to the shadow store immediately on Lookup), so checking basename is sufficient
// for unanchored literals — no ancestor walk needed.
type Rules struct {
	matcher       *ignore.GitIgnore // glob matcher; non-nil if any glob OR any negation rule present
	unanchored    map[string]bool   // basename match at any depth (only consulted when no negation)
	anchored      map[string]bool   // exact rel-path match (only consulted when no negation)
	hasNegation   bool              // any '!' rule present → fast-path disabled, all matches go through matcher
	patterns      []string          // raw rule strings; for logging only
}

// ParseRulesFile reads a .rp/shadow file. Missing file = empty rules.
func ParseRulesFile(path string) (*Rules, error) {
	f, err := os.Open(path)
	if err != nil {
		if os.IsNotExist(err) {
			return emptyRules(), nil
		}
		return nil, err
	}
	defer f.Close()
	return parseRulesReader(f)
}

func emptyRules() *Rules {
	return &Rules{
		unanchored: map[string]bool{},
		anchored:   map[string]bool{},
	}
}

func parseRulesReader(r io.Reader) (*Rules, error) {
	out := emptyRules()
	// orderedForMatcher collects positives + negations in order so we can
	// compile a single ordered matcher when negation is present (last-match
	// wins). globs is the fast-path-companion list when no negation exists
	// (positive literals live in the hash maps; only glob-containing
	// positives need the regex matcher).
	var orderedForMatcher []string
	var globs []string

	sc := bufio.NewScanner(r)
	for sc.Scan() {
		line := strings.TrimRight(sc.Text(), "\r")
		trim := strings.TrimSpace(line)
		if trim == "" || strings.HasPrefix(trim, "#") {
			continue
		}
		negated := strings.HasPrefix(trim, "!")
		body := trim
		if negated {
			body = strings.TrimPrefix(trim, "!")
		}
		if err := validatePattern(body); err != nil {
			log.Printf("rp-fuse: skipping invalid pattern %q: %v", trim, err)
			continue
		}
		out.patterns = append(out.patterns, trim)

		if negated {
			out.hasNegation = true
		}

		// Always feed go-gitignore in order — needed if hasNegation, harmless
		// to build otherwise (we'll only consult it for glob patterns).
		orderedForMatcher = append(orderedForMatcher, anchorGlobIfMidSlash(trim))

		// Fast-path classification only applies to POSITIVE rules and is
		// only consulted when hasNegation is false.
		if !negated {
			kind, key := classify(body)
			switch kind {
			case patUnanchored:
				out.unanchored[key] = true
			case patAnchored:
				out.anchored[key] = true
			case patGlob:
				globs = append(globs, anchorGlobIfMidSlash(body))
			}
		}
	}
	if err := sc.Err(); err != nil {
		return nil, err
	}

	if out.hasNegation {
		// One ordered matcher handles everything; the hash maps are unused.
		// We rebuild them empty to keep the struct invariant ("Match consults
		// matcher only").
		out.unanchored = map[string]bool{}
		out.anchored = map[string]bool{}
		out.matcher = ignore.CompileIgnoreLines(orderedForMatcher...)
	} else if len(globs) > 0 {
		out.matcher = ignore.CompileIgnoreLines(globs...)
	}
	return out, nil
}

// anchorGlobIfMidSlash prepends "/" to glob patterns whose slash is not at the
// start or end, to match real-git anchoring semantics. go-gitignore treats such
// patterns as unanchored by default; we force anchoring here so behavior matches
// the .gitignore spec.
//
// Patterns explicitly starting with **/ keep their unanchored deep-match intent.
//
// Negation prefix '!' is preserved: we anchor the body and re-attach '!' at the
// front. (Without this, `!a/b` would become `/!a/b` — a literal pattern with
// '!' as part of the name — and lose its negation semantics.)
func anchorGlobIfMidSlash(p string) string {
	negation := ""
	if strings.HasPrefix(p, "!") {
		negation = "!"
		p = p[1:]
	}
	if strings.HasPrefix(p, "/") {
		return negation + p
	}
	if strings.HasPrefix(p, "**/") {
		return negation + p
	}
	trimmed := strings.TrimSuffix(p, "/")
	if strings.Contains(trimmed, "/") {
		return negation + "/" + p
	}
	return negation + p
}

func validatePattern(p string) error {
	if p == "" {
		return errors.New("empty")
	}
	if p == "." || p == ".." || strings.HasPrefix(p, "../") || strings.Contains(p, "/../") || strings.HasSuffix(p, "/..") {
		return errors.New("path traversal")
	}
	return nil
}

// Pattern classification.
type patKind int

const (
	patUnanchored patKind = iota
	patAnchored
	patGlob
)

// classify decides which fast-path bucket a pattern lives in. Per the real
// .gitignore spec, any pattern containing a non-trailing slash is anchored to
// the root. Three buckets:
//
//   * patGlob       — anything containing *, ?, or [. Compiled into the regex
//                     matcher (with `/` prepended via anchorGlobIfMidSlash if
//                     mid-slash, to override go-gitignore's permissive default).
//   * patAnchored   — leading slash, OR any mid-slash, with no glob chars.
//                     Match the exact rel path via O(1) hash lookup.
//   * patUnanchored — single-component bare name (with optional trailing /);
//                     match against the basename at any depth.
func classify(p string) (patKind, string) {
	if strings.ContainsAny(p, "*?[") {
		return patGlob, p
	}
	if strings.HasPrefix(p, "/") {
		return patAnchored, strings.TrimSuffix(p[1:], "/")
	}
	trimmed := strings.TrimSuffix(p, "/")
	if !strings.Contains(trimmed, "/") {
		return patUnanchored, trimmed
	}
	// Mid-slash literal — anchored to workspace root per gitignore spec.
	return patAnchored, trimmed
}

// Match returns true if rel (slash-separated, no leading slash, relative to workspace
// root) matches any rule. Empty rel never matches. When the rule set contains any '!'
// negation, last-match-wins semantics decide the result (delegated to go-gitignore);
// the literal fast-path is skipped in that mode.
func (r *Rules) Match(rel string) bool {
	if r == nil || rel == "" {
		return false
	}
	if r.hasNegation {
		// Fast-path disabled — a positive literal might be overridden by a
		// later '!' rule. Walk the ordered matcher only.
		if r.matcher != nil {
			return r.matcher.MatchesPath(rel)
		}
		return false
	}
	if r.anchored[rel] {
		return true
	}
	if r.unanchored[filepath.Base(rel)] {
		return true
	}
	if r.matcher != nil {
		return r.matcher.MatchesPath(rel)
	}
	return false
}

// Patterns returns the parsed rule strings (for logging/inspection).
func (r *Rules) Patterns() []string {
	if r == nil {
		return nil
	}
	out := make([]string, len(r.patterns))
	copy(out, r.patterns)
	return out
}
