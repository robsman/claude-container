# OpenCode example workspace

Copy-pasteable workspace override demonstrating how to run a different agent
(sst/opencode) without patching robo-pen. Validates ADR-0007's Tier-1 plugin
shape.

## Layout

```
.rp/
├── config.yaml                       # agent: opencode
├── shadow                            # gitignore-style filter rules
└── agents/
    └── opencode/                     # workspace profile (overrides any builtin)
        ├── manifest.yaml             # env allow-list + instructions_dst
        ├── install.sh                # curl https://opencode.ai/install | bash
        ├── run.sh                    # exec opencode "$@"
        └── instructions.md           # composed into ~/.config/opencode/AGENTS.md
```

## Use

```bash
# 1. Copy the .rp/ tree into your own workspace.
cp -r ~/repos/robo-pen/examples/opencode/.rp /path/to/your/project/

# 2. Export a provider key. OpenCode supports several; pick one. rp forwards
#    every declared name listed in the profile manifest.
export OPENAI_API_KEY=sk-...
# or
export ANTHROPIC_API_KEY=sk-ant-...

# 3. Create + start the container.
cd /path/to/your/project
rp create               # builds the overlay, runs install.sh, composes AGENTS.md
rp run                  # opens the opencode TUI
```

The resulting container is named `rp-opencode-<basename>`. It coexists with
any `rp-claude-code-<basename>` you may have for the same workspace — same
project, two side-by-side containers, one agent each.

## What the smoke test checks

`test-example.sh` validates the profile bundle without actually building a
container: it runs `rp lint --workspace <example> --repo-dir <repo>` and
asserts that the resolver picks the workspace's opencode profile (not a
non-existent builtin) and that the manifest validates cleanly.
