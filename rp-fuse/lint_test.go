package main

import (
	"reflect"
	"strings"
	"testing"
)

func TestLintReader_Classify(t *testing.T) {
	in := `# top comment
node_modules
*.log
/secret
.aws/credentials
build/**/*.o
**/cache
!keep
..
foo/../bar
node_modules
`
	entries, err := lintReader(strings.NewReader(in))
	if err != nil {
		t.Fatal(err)
	}
	type triple struct {
		line   int
		status string
		class  string
	}
	var got []triple
	for _, e := range entries {
		got = append(got, triple{e.Line, e.Status, e.Class})
	}
	want := []triple{
		{2, "ok", "literal-unanchored"},
		{3, "ok", "glob-unanchored"},
		{4, "ok", "literal-anchored"},
		{5, "ok", "literal-anchored"},
		{6, "ok", "glob-anchored"},
		{7, "ok", "glob-unanchored"},
		{8, "warn", ""},  // !keep
		{9, "err", ""},   // ..
		{10, "err", ""},  // foo/../bar
		{11, "warn", ""}, // duplicate node_modules
	}
	if !reflect.DeepEqual(got, want) {
		t.Errorf("lintReader:\n  got:  %v\n  want: %v", got, want)
	}
}

func TestLintReader_DuplicateMessage(t *testing.T) {
	entries, _ := lintReader(strings.NewReader("foo\nfoo\n"))
	if len(entries) != 2 || entries[1].Status != "warn" {
		t.Fatalf("expected 2 entries with second as warn, got %+v", entries)
	}
	if !strings.Contains(entries[1].Message, "duplicate of line 1") {
		t.Errorf("duplicate message wrong: %q", entries[1].Message)
	}
}

func TestMatchAgainst(t *testing.T) {
	entries, _ := lintReader(strings.NewReader("node_modules\n*.log\n/secret\n"))
	tests := []struct {
		path       string
		wantHit    bool
		wantClass  string
	}{
		{"node_modules", true, "literal-unanchored"},
		{"a/node_modules", true, "literal-unanchored"},
		{"app.log", true, "glob-unanchored"},
		{"deep/x.log", true, "glob-unanchored"},
		{"secret", true, "literal-anchored"},
		{"a/secret", false, ""},
		{"src/main.go", false, ""},
	}
	for _, c := range tests {
		matched := matchAgainst(c.path, entries)
		if c.wantHit {
			if len(matched) != 1 {
				t.Errorf("matchAgainst(%q): expected 1 match, got %d", c.path, len(matched))
				continue
			}
			if matched[0].Class != c.wantClass {
				t.Errorf("matchAgainst(%q): class = %q, want %q", c.path, matched[0].Class, c.wantClass)
			}
		} else {
			if len(matched) != 0 {
				t.Errorf("matchAgainst(%q): expected no match, got %v", c.path, matched)
			}
		}
	}
}
