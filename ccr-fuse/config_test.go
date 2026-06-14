package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestParseProjectConfig_Empty(t *testing.T) {
	cfg, err := parseProjectConfigBytes([]byte(""))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Image != "" || cfg.Build != nil || cfg.User != "" {
		t.Errorf("expected empty config, got %+v", cfg)
	}
	if cfg.HasImageSource() {
		t.Errorf("empty config should not have image source")
	}
}

func TestParseProjectConfig_Image(t *testing.T) {
	cfg, err := parseProjectConfigBytes([]byte("image: ghcr.io/example/foo:v1\n"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Image != "ghcr.io/example/foo:v1" {
		t.Errorf("image = %q", cfg.Image)
	}
	if !cfg.HasImageSource() {
		t.Errorf("expected HasImageSource")
	}
}

func TestParseProjectConfig_Build(t *testing.T) {
	src := `build:
  context: .
  dockerfile: Dockerfile
  args:
    NODE_VERSION: "22"
`
	cfg, err := parseProjectConfigBytes([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Build == nil {
		t.Fatal("build is nil")
	}
	if cfg.Build.Context != "." {
		t.Errorf("context = %q", cfg.Build.Context)
	}
	if cfg.Build.Dockerfile != "Dockerfile" {
		t.Errorf("dockerfile = %q", cfg.Build.Dockerfile)
	}
	if cfg.Build.Args["NODE_VERSION"] != "22" {
		t.Errorf("args[NODE_VERSION] = %q", cfg.Build.Args["NODE_VERSION"])
	}
}

func TestParseProjectConfig_User(t *testing.T) {
	cfg, err := parseProjectConfigBytes([]byte("image: node:22-bookworm\nuser: node\n"))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.User != "node" {
		t.Errorf("user = %q", cfg.User)
	}
}

func TestParseProjectConfig_RejectImageAndBuild(t *testing.T) {
	src := `image: foo
build:
  dockerfile: Dockerfile
`
	_, err := parseProjectConfigBytes([]byte(src))
	if err == nil || !strings.Contains(err.Error(), "both `image:` and `build:`") {
		t.Errorf("expected ambiguity error, got %v", err)
	}
}

func TestParseProjectConfig_RejectUnknownKey(t *testing.T) {
	src := `image: foo
depends_on:
  - bar
`
	_, err := parseProjectConfigBytes([]byte(src))
	if err == nil || !strings.Contains(err.Error(), "depends_on") {
		t.Errorf("expected error mentioning depends_on, got %v", err)
	}
}

func TestParseProjectConfig_RejectRootUser(t *testing.T) {
	_, err := parseProjectConfigBytes([]byte("image: foo\nuser: root\n"))
	if err == nil || !strings.Contains(err.Error(), "root") {
		t.Errorf("expected root rejection, got %v", err)
	}
}

func TestParseProjectConfig_RejectInvalidUser(t *testing.T) {
	_, err := parseProjectConfigBytes([]byte("image: foo\nuser: \"bad user\"\n"))
	if err == nil || !strings.Contains(err.Error(), "invalid character") {
		t.Errorf("expected invalid-char error, got %v", err)
	}
}

func TestParseProjectConfig_BuildRequiresDockerfile(t *testing.T) {
	_, err := parseProjectConfigBytes([]byte("build:\n  context: .\n"))
	if err == nil || !strings.Contains(err.Error(), "dockerfile") {
		t.Errorf("expected dockerfile-required error, got %v", err)
	}
}

func TestResolveContext_Default(t *testing.T) {
	ws := t.TempDir()
	cfg := &ProjectConfig{Build: &BuildSpec{Dockerfile: "Dockerfile"}}
	got, err := cfg.ResolveContext(ws)
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(ws, ".ccr")
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestResolveContext_DotDotToWorkspaceRoot(t *testing.T) {
	ws := t.TempDir()
	cfg := &ProjectConfig{Build: &BuildSpec{Context: "..", Dockerfile: "Dockerfile"}}
	got, err := cfg.ResolveContext(ws)
	if err != nil {
		t.Fatal(err)
	}
	if got != filepath.Clean(ws) {
		t.Errorf("got %q, want %q", got, ws)
	}
}

func TestResolveContext_EscapeRejected(t *testing.T) {
	ws := t.TempDir()
	cfg := &ProjectConfig{Build: &BuildSpec{Context: "../..", Dockerfile: "Dockerfile"}}
	_, err := cfg.ResolveContext(ws)
	if err == nil || !strings.Contains(err.Error(), "outside workspace") {
		t.Errorf("expected escape rejection, got %v", err)
	}
}

func TestResolveContext_AbsoluteRejected(t *testing.T) {
	ws := t.TempDir()
	cfg := &ProjectConfig{Build: &BuildSpec{Context: "/etc", Dockerfile: "Dockerfile"}}
	_, err := cfg.ResolveContext(ws)
	if err == nil || !strings.Contains(err.Error(), "absolute") {
		t.Errorf("expected absolute rejection, got %v", err)
	}
}

func TestResolveDockerfile_InContext(t *testing.T) {
	ws := t.TempDir()
	cfg := &ProjectConfig{Build: &BuildSpec{Context: ".", Dockerfile: "Dockerfile.dev"}}
	got, err := cfg.ResolveDockerfile(ws)
	if err != nil {
		t.Fatal(err)
	}
	want := filepath.Join(ws, ".ccr", "Dockerfile.dev")
	if got != want {
		t.Errorf("got %q, want %q", got, want)
	}
}

func TestResolveDockerfile_EscapeRejected(t *testing.T) {
	ws := t.TempDir()
	cfg := &ProjectConfig{Build: &BuildSpec{Context: ".", Dockerfile: "../Dockerfile"}}
	_, err := cfg.ResolveDockerfile(ws)
	if err == nil || !strings.Contains(err.Error(), "escapes") {
		t.Errorf("expected escape rejection, got %v", err)
	}
}

func TestParseProjectConfig_MissingFile(t *testing.T) {
	cfg, err := ParseProjectConfig("/nonexistent/.ccr/config.yaml")
	if err != nil {
		t.Fatalf("missing file should not error: %v", err)
	}
	if cfg.HasImageSource() {
		t.Errorf("missing file should yield empty config")
	}
}

func TestParseProjectConfig_Resources(t *testing.T) {
	src := `image: debian:bookworm-slim
resources:
  memory: 4G
  cpus: 2
`
	cfg, err := parseProjectConfigBytes([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Resources == nil {
		t.Fatal("Resources is nil")
	}
	if cfg.Resources.Memory != "4G" {
		t.Errorf("memory = %q", cfg.Resources.Memory)
	}
	if cfg.Resources.CPUs != 2 {
		t.Errorf("cpus = %d", cfg.Resources.CPUs)
	}
}

func TestParseProjectConfig_FuseCache(t *testing.T) {
	src := `image: debian:bookworm-slim
fuse:
  cache: 0.5
`
	cfg, err := parseProjectConfigBytes([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Fuse == nil || cfg.Fuse.Cache == nil {
		t.Fatal("Fuse.Cache is nil")
	}
	if *cfg.Fuse.Cache != 0.5 {
		t.Errorf("cache = %f", *cfg.Fuse.Cache)
	}
}

func TestParseProjectConfig_FuseCacheZero(t *testing.T) {
	// Zero is valid (=disable caching). Tests that the *float64 pointer
	// correctly distinguishes "unset" from "explicit zero".
	src := "fuse:\n  cache: 0\n"
	cfg, err := parseProjectConfigBytes([]byte(src))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Fuse == nil || cfg.Fuse.Cache == nil {
		t.Fatal("Cache is nil; zero should still set it")
	}
	if *cfg.Fuse.Cache != 0.0 {
		t.Errorf("cache = %f, want 0.0", *cfg.Fuse.Cache)
	}
}

func TestParseProjectConfig_RejectBadMemory(t *testing.T) {
	cases := []string{
		"resources:\n  memory: abc\n",
		"resources:\n  memory: 0G\n",
		"resources:\n  memory: 4XB\n",
	}
	for _, src := range cases {
		_, err := parseProjectConfigBytes([]byte(src))
		if err == nil || !strings.Contains(err.Error(), "resources.memory") {
			t.Errorf("expected memory rejection for %q, got %v", src, err)
		}
	}
}

func TestParseProjectConfig_RejectNegativeCPUs(t *testing.T) {
	_, err := parseProjectConfigBytes([]byte("resources:\n  cpus: -1\n"))
	if err == nil || !strings.Contains(err.Error(), "resources.cpus") {
		t.Errorf("expected cpus rejection, got %v", err)
	}
}

func TestParseProjectConfig_RejectNegativeCache(t *testing.T) {
	_, err := parseProjectConfigBytes([]byte("fuse:\n  cache: -0.5\n"))
	if err == nil || !strings.Contains(err.Error(), "fuse.cache") {
		t.Errorf("expected cache rejection, got %v", err)
	}
}

func TestValidateMemorySize(t *testing.T) {
	good := []string{"1", "100", "512M", "4G", "16g", "2T", "1024K"}
	for _, s := range good {
		if err := validateMemorySize(s); err != nil {
			t.Errorf("expected %q to be valid, got %v", s, err)
		}
	}
	bad := []string{"", "abc", "0", "0G", "4XB", "4.5G", " 4G", "G"}
	for _, s := range bad {
		if err := validateMemorySize(s); err == nil {
			t.Errorf("expected %q to be invalid", s)
		}
	}
}

func TestParseProjectConfig_FromFile(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "config.yaml")
	if err := os.WriteFile(path, []byte("image: alpine\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	cfg, err := ParseProjectConfig(path)
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Image != "alpine" {
		t.Errorf("image = %q", cfg.Image)
	}
}
