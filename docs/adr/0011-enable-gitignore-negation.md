# Enable gitignore negation in `.rp/shadow`

Reverses ADR-0003's "negation not supported" stance. `.rp/shadow` now honours `!`-prefixed rules with standard gitignore last-match-wins semantics, letting users re-expose a subtree under a shadowed parent without having to abandon the shadow boundary on the whole subtree.

## Why now

The original rejection in ADR-0003 cited two reasons: (a) the "shadow this directory but expose this specific file" pattern complicates the resolution layer, and (b) there was no clear demand. Both have softened:

1. The resolution layer turns out NOT to be complicated — `go-gitignore` (the library we already use) handles negation natively via `MatchesPath`. Our `HostNode` call sites all funnel through `Rules.Match(rel)` and use it monotonically (positive = shadow, negative = passthrough). Switching `Match` to negation-aware semantics propagates correctly through every Lookup / Readdir / Create / Mkdir / Rename without per-call-site changes.
2. The demand surfaced naturally once monorepo workspaces became viable: users want to shadow `node_modules/` but selectively expose `node_modules/<internal-pkg>/` that they're actively developing.

## What changed

* `rules.go` — stop dropping `!` lines; build a single ordered `go-gitignore` matcher when any negation is present; disable the literal fast-path in that mode (a positive literal match can be overridden by a later `!` rule).
* `lint.go` — accept `!` as a valid prefix; classify on the body for an accurate class output.
* No changes to `HostNode` — `Rules.Match` keeps its return contract (`true` = "shadow this path"), only the interpretation of what counts as "matched" gets richer.

## Pattern-form caveat

`go-gitignore` (and arguably the gitignore spec itself) treats `dir/**` as matching both the directory AND its descendants. That breaks the "shadow children, expose one subtree" case because the parent directory is itself routed to the shadow store — Lookup can't drill into a re-exposed subtree if the parent never reaches the host bind.

To make negation usable, rules must match CHILDREN of the shadowed parent, not the parent itself. The working pattern is:

```
node_modules/*           # direct children
node_modules/**/*        # descendants at any depth
!node_modules/important
!node_modules/important/**
```

Documenting this in the test (`tests/integration/test-shadow-negation.sh`) and CONTEXT.md so users don't trip over it.

## What about ADR-0003

ADR-0003 stands as the historical decision. Its `.ccrshadow → .rp/shadow` filename rationale ("not gitignore — different semantics") is unchanged; the file still serves a different purpose. What's reversed is just the negation-not-supported clause.

## Risk

Low.

* Backwards compatible: workspaces without `!` rules behave identically (fast-path still active).
* Library-handled: we don't re-implement gitignore matching; `go-gitignore` does the heavy lift.
* Tested: `TestRulesNegation*` covers the parsing + matcher; `test-shadow-negation` exercises end-to-end shadow + passthrough routing inside a real container.

## Out of scope (deferred)

* `@from-gitignore` / `**/.gitignore` import directives — a separate phase (3b/3c). Phase 3a here is just the negation primitive.
* "Stale shadow content under a newly-negated path" hygiene — if a user adds `!path` and the shadow store still contains old writes for that path, the content is orphaned (invisible inside the container, but on disk). `rp destroy` clears it; lint could warn later.
