package main

// ProjectConfig models the per-workspace .ccr/config.yaml file. Field names
// mirror docker-compose service-level keys (image, build, user) but the file
// is NOT a docker-compose.yml — there is no services: wrapper and only the
// subset documented in ADR-0006 is honored. Unknown / not-yet-supported keys
// raise a parse error from yaml.v3's KnownFields(true) mode.

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// ProjectConfig is the parsed contents of `.ccr/config.yaml`. All fields are
// optional; a fully empty config is valid and means "use the default base
// image with the coder user".
type ProjectConfig struct {
	Image     string        `yaml:"image,omitempty"`
	Build     *BuildSpec    `yaml:"build,omitempty"`
	User      string        `yaml:"user,omitempty"`
	Resources *ResourceSpec `yaml:"resources,omitempty"`
	Fuse      *FuseSpec     `yaml:"fuse,omitempty"`
}

// BuildSpec holds the parameters for locally building a project image.
// Context is a path relative to the directory containing config.yaml
// (i.e. .ccr/) and is resolved + validated to stay inside the workspace.
type BuildSpec struct {
	Context    string            `yaml:"context,omitempty"`
	Dockerfile string            `yaml:"dockerfile,omitempty"`
	Args       map[string]string `yaml:"args,omitempty"`
}

// ResourceSpec maps onto `container create` resource flags.
type ResourceSpec struct {
	// Memory is the RAM ceiling. Apple Container size string ("4G", "512M").
	Memory string `yaml:"memory,omitempty"`
	// CPUs is the CPU count. Positive integer.
	CPUs int `yaml:"cpus,omitempty"`
}

// FuseSpec maps onto ccr-fuse runtime flags.
type FuseSpec struct {
	// Cache is the attr/entry/negative cache TTL in seconds (ccr-fuse --cache).
	// Pointer so we can distinguish "unset" (use default 1.0s) from "0.0".
	Cache *float64 `yaml:"cache,omitempty"`
}

// ParseProjectConfig reads and validates .ccr/config.yaml. A missing file
// yields an empty *ProjectConfig and no error.
func ParseProjectConfig(path string) (*ProjectConfig, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return &ProjectConfig{}, nil
		}
		return nil, err
	}
	return parseProjectConfigBytes(data)
}

func parseProjectConfigBytes(data []byte) (*ProjectConfig, error) {
	cfg := &ProjectConfig{}
	if len(bytes.TrimSpace(data)) == 0 {
		return cfg, nil
	}
	d := yaml.NewDecoder(bytes.NewReader(data))
	d.KnownFields(true)
	if err := d.Decode(cfg); err != nil {
		if errors.Is(err, io.EOF) {
			return cfg, nil
		}
		return nil, fmt.Errorf("parse: %w", err)
	}
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return cfg, nil
}

// Validate rejects configs that violate ccr's invariants. Does not touch the
// filesystem — use ResolveContext separately for path checks.
func (c *ProjectConfig) Validate() error {
	if c.Image != "" && c.Build != nil {
		return errors.New("config: cannot specify both `image:` and `build:` — choose one")
	}
	if c.User != "" {
		if err := validateUserName(c.User); err != nil {
			return fmt.Errorf("config: user: %w", err)
		}
	}
	if c.Build != nil {
		if c.Build.Dockerfile == "" {
			return errors.New("config: build: dockerfile is required")
		}
	}
	if c.Resources != nil {
		if c.Resources.Memory != "" {
			if err := validateMemorySize(c.Resources.Memory); err != nil {
				return fmt.Errorf("config: resources.memory: %w", err)
			}
		}
		if c.Resources.CPUs < 0 {
			return fmt.Errorf("config: resources.cpus: must be a positive integer, got %d", c.Resources.CPUs)
		}
	}
	if c.Fuse != nil && c.Fuse.Cache != nil {
		if *c.Fuse.Cache < 0 {
			return fmt.Errorf("config: fuse.cache: must be ≥ 0, got %g", *c.Fuse.Cache)
		}
	}
	return nil
}

// validateMemorySize accepts Apple-Container-style size strings: a positive
// integer optionally followed by a single K / M / G / T suffix. We do not
// translate the value; Apple Container parses it.
func validateMemorySize(s string) error {
	if s == "" {
		return errors.New("empty")
	}
	digits := s
	suffix := ""
	last := s[len(s)-1]
	switch last {
	case 'K', 'M', 'G', 'T', 'k', 'm', 'g', 't':
		digits = s[:len(s)-1]
		suffix = string(last)
	}
	if digits == "" {
		return fmt.Errorf("missing digits before suffix %q", suffix)
	}
	for _, r := range digits {
		if r < '0' || r > '9' {
			return fmt.Errorf("non-digit %q in size value %q", r, s)
		}
	}
	if digits == "0" {
		return errors.New("zero is not a valid size")
	}
	return nil
}

// validateUserName checks that a user: value is a syntactically plausible
// POSIX username. The deeper invariants (user exists in image, uid != 0, no
// sudoers entry) are checked at image-build time and again at container init,
// per ADR-0006.
func validateUserName(u string) error {
	if u == "" {
		return errors.New("empty user name")
	}
	if u == "root" {
		return errors.New("user `root` is not allowed; ccr requires an unprivileged identity")
	}
	for i, r := range u {
		if r == '_' || r == '-' || r == '.' {
			continue
		}
		if r >= 'a' && r <= 'z' {
			continue
		}
		if r >= 'A' && r <= 'Z' {
			continue
		}
		if r >= '0' && r <= '9' && i > 0 {
			continue
		}
		return fmt.Errorf("invalid character %q in user name %q", r, u)
	}
	return nil
}

// HasImageSource reports whether the config explicitly specifies an image
// source (either a pulled image or a local build).
func (c *ProjectConfig) HasImageSource() bool {
	return c.Image != "" || c.Build != nil
}

// ResolveContext converts a config-relative `build.context` path into an
// absolute path on disk. The workspaceRoot argument is the absolute path of
// the workspace directory (the parent of .ccr/). The resolved path must stay
// inside workspaceRoot; absolute paths and `..`-escapes return an error.
func (c *ProjectConfig) ResolveContext(workspaceRoot string) (string, error) {
	if c.Build == nil {
		return "", errors.New("no build: section")
	}
	rel := c.Build.Context
	if rel == "" {
		rel = "."
	}
	if filepath.IsAbs(rel) {
		return "", fmt.Errorf("build.context %q: absolute paths not allowed", rel)
	}
	// Config lives at .ccr/config.yaml; context paths are relative to .ccr/.
	configDir := filepath.Join(workspaceRoot, ".ccr")
	candidate := filepath.Clean(filepath.Join(configDir, rel))
	wsClean := filepath.Clean(workspaceRoot)
	if candidate != wsClean && !strings.HasPrefix(candidate, wsClean+string(filepath.Separator)) {
		return "", fmt.Errorf("build.context %q resolves to %q, outside workspace %q", rel, candidate, wsClean)
	}
	return candidate, nil
}

// ResolveDockerfile returns the absolute path of the Dockerfile relative to
// the resolved build context.
func (c *ProjectConfig) ResolveDockerfile(workspaceRoot string) (string, error) {
	if c.Build == nil {
		return "", errors.New("no build: section")
	}
	ctxPath, err := c.ResolveContext(workspaceRoot)
	if err != nil {
		return "", err
	}
	df := c.Build.Dockerfile
	if filepath.IsAbs(df) {
		return "", fmt.Errorf("build.dockerfile %q: absolute paths not allowed", df)
	}
	candidate := filepath.Clean(filepath.Join(ctxPath, df))
	if !strings.HasPrefix(candidate, ctxPath+string(filepath.Separator)) && candidate != ctxPath {
		return "", fmt.Errorf("build.dockerfile %q escapes the build context", df)
	}
	return candidate, nil
}
