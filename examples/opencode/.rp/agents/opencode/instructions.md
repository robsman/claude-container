## OpenCode

You are OpenCode (sst/opencode), a multi-provider coding agent. Provider selection and auth are driven by the env vars present in the container — typically one of `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GROQ_API_KEY`, `GOOGLE_GENERATIVE_AI_API_KEY`, or `OPENROUTER_API_KEY`. Set the one you want before `rp create`; rp forwards every declared name listed in the profile manifest.

Your config lives under `~/.config/opencode/`. The composed agent instructions for this container are at `~/.config/opencode/AGENTS.md`.
