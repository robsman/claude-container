package main

// ProjectConfig models the per-workspace .rp/config.yaml file. Field names
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

// ProjectConfig is the parsed contents of `.rp/config.yaml`. All fields are
// optional; a fully empty config is valid and means "use the default base
// image with the coder user and the claude-code agent profile".
type ProjectConfig struct {
	Agent string     `yaml:"agent,omitempty"`
	Image string     `yaml:"image,omitempty"`
	Build *BuildSpec `yaml:"build,omitempty"`
	User  string     `yaml:"user,omitempty"`
	// StripSudo opts the workspace into the rp overlay actively stripping
	// sudoers entries from the configured user during the overlay build (see
	// ADR-0009). Default is false: rp refuses to use a user with sudo. Set
	// this true to keep an image's conventional user (e.g. `node` on the
	// devcontainer javascript-node:22 image) while removing its sudo grant.
	StripSudo bool          `yaml:"strip_sudo,omitempty"`
	Resources *ResourceSpec `yaml:"resources,omitempty"`
	Fuse      *FuseSpec     `yaml:"fuse,omitempty"`
	// HostAliases declares host-resolvable names inside the container.
	// Each entry is either:
	//   - "name"             → resolves to the runtime's host-gateway
	//   - {name: x, ip: y}   → resolves to a fixed IP (host-gateway shortcut
	//                          for the host itself if y == "host-gateway").
	// `host.containers.internal` is always injected automatically (see
	// HostAliasesEffective); the user can opt out by listing it with a
	// negation (`!host.containers.internal`) — TBD.
	HostAliases []HostAlias `yaml:"host_aliases,omitempty"`
}

// HostAlias is one entry under host_aliases. Accepts both the short
// scalar form ("name") and the mapping form ({name, ip}). yaml.v3 calls
// UnmarshalYAML which we override to handle both shapes.
type HostAlias struct {
	Name string `yaml:"name"`
	IP   string `yaml:"ip,omitempty"` // defaults to "host-gateway" when empty
}

func (h *HostAlias) UnmarshalYAML(node *yaml.Node) error {
	switch node.Kind {
	case yaml.ScalarNode:
		h.Name = node.Value
		h.IP = ""
		return nil
	case yaml.MappingNode:
		// Use a sidecar type so we don't recurse into UnmarshalYAML.
		type aliasMap struct {
			Name string `yaml:"name"`
			IP   string `yaml:"ip,omitempty"`
		}
		var m aliasMap
		if err := node.Decode(&m); err != nil {
			return err
		}
		h.Name = m.Name
		h.IP = m.IP
		return nil
	}
	return fmt.Errorf("host_aliases entry: expected scalar or mapping, got %v", node.Kind)
}

// HostAliasesEffective returns the configured aliases plus the always-on
// `host.containers.internal` (unless already present in the config).
// Effective IP defaults to "host-gateway" — the magic value the container
// runtime resolves to the host's gateway IP.
func (c *ProjectConfig) HostAliasesEffective() []HostAlias {
	out := make([]HostAlias, 0, len(c.HostAliases)+1)
	seen := map[string]bool{}
	for _, a := range c.HostAliases {
		ip := a.IP
		if ip == "" {
			ip = "host-gateway"
		}
		out = append(out, HostAlias{Name: a.Name, IP: ip})
		seen[a.Name] = true
	}
	if !seen["host.containers.internal"] {
		out = append(out, HostAlias{Name: "host.containers.internal", IP: "host-gateway"})
	}
	return out
}

// DefaultAgent is the profile used when .rp/config.yaml does not set `agent:`.
const DefaultAgent = "claude-code"

// AgentName returns the configured agent, falling back to DefaultAgent.
func (c *ProjectConfig) AgentName() string {
	if c.Agent == "" {
		return DefaultAgent
	}
	return c.Agent
}

// BuildSpec holds the parameters for locally building a project image.
// Context is a path relative to the directory containing config.yaml
// (i.e. .rp/) and is resolved + validated to stay inside the workspace.
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

// FuseSpec maps onto rp-fuse runtime flags.
type FuseSpec struct {
	// Cache is the attr/entry/negative cache TTL in seconds (rp-fuse --cache).
	// Pointer so we can distinguish "unset" (use default 1.0s) from "0.0".
	Cache *float64 `yaml:"cache,omitempty"`
}

// ParseProjectConfig reads and validates .rp/config.yaml. A missing file
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

// Validate rejects configs that violate rp's invariants. Does not touch the
// filesystem — use ResolveContext / ResolveProfile separately for path checks.
func (c *ProjectConfig) Validate() error {
	if c.Image != "" && c.Build != nil {
		return errors.New("config: cannot specify both `image:` and `build:` — choose one")
	}
	if c.Agent != "" {
		if err := validateAgentName(c.Agent); err != nil {
			return fmt.Errorf("config: agent: %w", err)
		}
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
	for i, a := range c.HostAliases {
		if err := validateHostName(a.Name); err != nil {
			return fmt.Errorf("config: host_aliases[%d].name: %w", i, err)
		}
		if a.IP != "" && a.IP != "host-gateway" {
			if err := validateIP(a.IP); err != nil {
				return fmt.Errorf("config: host_aliases[%d].ip: %w", i, err)
			}
		}
	}
	return nil
}

// validateHostName accepts hostnames per RFC 952/1123 letters/digits/hyphens,
// dot-separated labels. Length-capped at 253 (DNS max).
func validateHostName(s string) error {
	if s == "" {
		return errors.New("empty hostname")
	}
	if len(s) > 253 {
		return fmt.Errorf("hostname %q exceeds 253 chars", s)
	}
	for _, label := range strings.Split(s, ".") {
		if label == "" {
			return fmt.Errorf("hostname %q has empty label (consecutive dots / leading or trailing dot)", s)
		}
		if len(label) > 63 {
			return fmt.Errorf("hostname label %q exceeds 63 chars", label)
		}
		for i, r := range label {
			switch {
			case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z':
				continue
			case r >= '0' && r <= '9':
				continue
			case r == '-' && i > 0 && i < len(label)-1:
				continue
			}
			return fmt.Errorf("invalid character %q in hostname label %q", r, label)
		}
	}
	return nil
}

// validateIP accepts IPv4 dotted quad. We deliberately don't accept IPv6 yet —
// Apple Container's --add-host arg format for v6 needs verification first.
func validateIP(s string) error {
	parts := strings.Split(s, ".")
	if len(parts) != 4 {
		return fmt.Errorf("expected IPv4 dotted-quad, got %q", s)
	}
	for _, p := range parts {
		if p == "" || len(p) > 3 {
			return fmt.Errorf("invalid octet %q in %q", p, s)
		}
		n := 0
		for _, r := range p {
			if r < '0' || r > '9' {
				return fmt.Errorf("non-digit %q in IP %q", r, s)
			}
			n = n*10 + int(r-'0')
		}
		if n > 255 {
			return fmt.Errorf("octet %d out of range in %q", n, s)
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

// validateAgentName checks that an agent: value is a syntactically plausible
// agent profile identifier. Profile names are lowercase identifiers, used as
// both directory names (agent.profiles/<name>) and config field values.
func validateAgentName(a string) error {
	if a == "" {
		return errors.New("empty agent name")
	}
	for i, r := range a {
		switch {
		case r >= 'a' && r <= 'z':
			continue
		case r >= '0' && r <= '9' && i > 0:
			continue
		case r == '-' && i > 0:
			continue
		}
		return fmt.Errorf("invalid character %q in agent name %q (lowercase, digits, hyphens; cannot start with digit or hyphen)", r, a)
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
		return errors.New("user `root` is not allowed; rp requires an unprivileged identity")
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
// the workspace directory (the parent of .rp/). The resolved path must stay
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
	// Config lives at .rp/config.yaml; context paths are relative to .rp/.
	configDir := filepath.Join(workspaceRoot, ".rp")
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
