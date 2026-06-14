package main

// The `config` subcommand lets shell scripts (Justfile recipes, ccr wrapper)
// inspect .ccr/config.yaml without re-implementing the YAML parser.

import (
	"flag"
	"fmt"
	"os"
	"strings"
)

// runConfig is the entrypoint for `ccr-fuse config`.
func runConfig(args []string) {
	fs := flag.NewFlagSet("config", flag.ExitOnError)
	configPath := fs.String("file", ".ccr/config.yaml", "path to .ccr/config.yaml")
	fs.Usage = func() {
		fmt.Fprintln(os.Stderr, "Usage: ccr-fuse config [--file <path>] <subcommand>")
		fmt.Fprintln(os.Stderr, "Subcommands:")
		fmt.Fprintln(os.Stderr, "  show      print resolved fields, one per line")
		fmt.Fprintln(os.Stderr, "  validate  parse + validate; exit 0 on success, 1 on error")
		fmt.Fprintln(os.Stderr, "  field <name>")
		fmt.Fprintln(os.Stderr, "            print one field (image | dockerfile | context | user)")
	}
	_ = fs.Parse(args)
	if fs.NArg() < 1 {
		fs.Usage()
		os.Exit(2)
	}

	cfg, err := ParseProjectConfig(*configPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "ccr-fuse config: %v\n", err)
		os.Exit(1)
	}

	sub := fs.Arg(0)
	switch sub {
	case "validate":
		// Already parsed without error; exit 0.
		return
	case "show":
		showProjectConfig(cfg, *configPath)
		return
	case "field":
		if fs.NArg() < 2 {
			fmt.Fprintln(os.Stderr, "ccr-fuse config field: name required")
			os.Exit(2)
		}
		out, err := projectConfigField(cfg, fs.Arg(1))
		if err != nil {
			fmt.Fprintf(os.Stderr, "ccr-fuse config field: %v\n", err)
			os.Exit(1)
		}
		fmt.Println(out)
	default:
		fmt.Fprintf(os.Stderr, "ccr-fuse config: unknown subcommand %q\n", sub)
		os.Exit(2)
	}
}

func showProjectConfig(c *ProjectConfig, path string) {
	fmt.Printf("file: %s\n", path)
	fmt.Printf("image: %s\n", emptyDash(c.Image))
	fmt.Printf("user: %s\n", emptyDash(c.User))
	if c.Build != nil {
		fmt.Println("build:")
		fmt.Printf("  context: %s\n", emptyDash(c.Build.Context))
		fmt.Printf("  dockerfile: %s\n", c.Build.Dockerfile)
		if len(c.Build.Args) > 0 {
			fmt.Println("  args:")
			for k, v := range c.Build.Args {
				fmt.Printf("    %s: %s\n", k, v)
			}
		}
	} else {
		fmt.Println("build: -")
	}
	if c.Resources != nil {
		fmt.Println("resources:")
		fmt.Printf("  memory: %s\n", emptyDash(c.Resources.Memory))
		cpus := "-"
		if c.Resources.CPUs > 0 {
			cpus = fmt.Sprintf("%d", c.Resources.CPUs)
		}
		fmt.Printf("  cpus: %s\n", cpus)
	} else {
		fmt.Println("resources: -")
	}
	if c.Fuse != nil && c.Fuse.Cache != nil {
		fmt.Printf("fuse.cache: %s\n", strings.TrimRight(strings.TrimRight(fmt.Sprintf("%f", *c.Fuse.Cache), "0"), "."))
	} else {
		fmt.Println("fuse.cache: -")
	}
}

func projectConfigField(c *ProjectConfig, name string) (string, error) {
	switch name {
	case "image":
		return c.Image, nil
	case "user":
		return c.User, nil
	case "dockerfile":
		if c.Build == nil {
			return "", nil
		}
		return c.Build.Dockerfile, nil
	case "context":
		if c.Build == nil {
			return "", nil
		}
		if c.Build.Context == "" {
			return ".", nil
		}
		return c.Build.Context, nil
	case "source":
		if c.Image != "" {
			return "image", nil
		}
		if c.Build != nil {
			return "build", nil
		}
		return "default", nil
	case "resources.memory":
		if c.Resources == nil {
			return "", nil
		}
		return c.Resources.Memory, nil
	case "resources.cpus":
		if c.Resources == nil || c.Resources.CPUs == 0 {
			return "", nil
		}
		return fmt.Sprintf("%d", c.Resources.CPUs), nil
	case "fuse.cache":
		if c.Fuse == nil || c.Fuse.Cache == nil {
			return "", nil
		}
		return strings.TrimRight(strings.TrimRight(fmt.Sprintf("%f", *c.Fuse.Cache), "0"), "."), nil
	}
	return "", fmt.Errorf("unknown field %q", name)
}

func emptyDash(s string) string {
	if s == "" {
		return "-"
	}
	return s
}
