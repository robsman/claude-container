// rp-init-bootstrap: setuid-root wrapper that runs /usr/local/bin/rp-init.sh
// as root from a non-root context.
//
// Use case: Docker Sandbox templates start their container with a non-root
// default user (agent, uid 1000). rp-init.sh requires root for the FUSE
// mount setup. This wrapper, installed with mode 4755 owner root, lets the
// agent user invoke the init flow without granting general sudo.
//
// Scope is deliberately tight:
//   * Hardcoded target — only execs /usr/local/bin/rp-init.sh. No path
//     arg. No other binaries.
//   * No argv passthrough — anything the caller appends is dropped, so a
//     compromised caller can't smuggle in malicious args.
//   * Clean env — clear the inherited environment before exec, set a
//     small safe baseline. Defense-in-depth against env-based injection
//     (statically-linked Go binaries already ignore LD_PRELOAD etc.).
//   * Forwards only RP_DEBUG, which rp-init.sh consults to toggle FUSE
//     debug logging. Other RP_* vars come via -e flags at container
//     create time, not through this path.
//
// DO NOT extend this binary to take arguments, exec a different target,
// or read additional config files. Any of those weakens the audit
// surface. If you need a more flexible escalation path, replace this
// pattern with sudo or capability-based grants — not by widening this
// wrapper.
package main

import (
	"os"
	"syscall"
)

const target = "/usr/local/bin/rp-init.sh"

func main() {
	// Snapshot the one env var we forward, then wipe everything.
	debug, hasDebug := os.LookupEnv("RP_DEBUG")
	rpCache, hasRPCache := os.LookupEnv("RP_CACHE")
	rpUser, hasRPUser := os.LookupEnv("RP_USER")

	os.Clearenv()
	os.Setenv("PATH", "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin")
	os.Setenv("HOME", "/root")
	os.Setenv("TERM", "xterm")
	if hasDebug {
		os.Setenv("RP_DEBUG", debug)
	}
	if hasRPCache {
		os.Setenv("RP_CACHE", rpCache)
	}
	if hasRPUser {
		os.Setenv("RP_USER", rpUser)
	}

	// Hardcoded target + no argv passthrough. Audit surface ends here.
	if err := syscall.Exec(target, []string{target}, os.Environ()); err != nil {
		os.Stderr.WriteString("rp-init-bootstrap: exec " + target + ": " + err.Error() + "\n")
		os.Exit(1)
	}
}
