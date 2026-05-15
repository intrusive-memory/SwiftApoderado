# SwiftApoderado — Requirements

Initial product requirements for the `apoderado` agentic coder. This list
is intentionally narrow: it captures the non-negotiables that shape every
subsequent design decision.

## R1. Command-line-only interaction

The agent's user interface is the terminal. There is no GUI, no editor
plugin, and no web frontend in scope for this project.

- The `apoderado` executable is the sole entry point.
- All input (prompts, file selection, confirmations) and all output
  (responses, diffs, tool traces) flow through stdin / stdout / stderr.
- Interactive flows (prompt loops, approval prompts) must work in a
  standard TTY without requiring a windowing system.
- Non-interactive invocation must also be supported so the CLI is usable
  from scripts, `make` targets, and CI.

## R2. Advice comes from local MLX models via SwiftAcervo

When the agent needs an LLM to reason about a problem, it queries an
on-device model served through
[SwiftAcervo](https://github.com/intrusive-memory/SwiftAcervo). No remote
inference API is contacted.

- Inference runs locally using MLX-format models resolved and loaded via
  SwiftAcervo.
- Model identity (slug + revision) is configurable; defaults are
  selected from SwiftAcervo's catalog.
- The CLI must operate without network connectivity once the required
  model is cached locally.

## R3. MLXSession is a SwiftAgent session implementation

`MLXSession` is a class shipped in the `SwiftApoderado` library target.
It plays the same role for local MLX models that `OpenAISession` and
`AnthropicSession` play for their respective remote providers — it is
the SwiftAgent session backend the CLI talks to.

- Lives in `Sources/SwiftApoderado/` alongside the rest of the library;
  not a separate package, not an upstream contribution to SwiftAgent.
- Conforms to whatever session protocol/shape SwiftAgent expects from
  `OpenAISession` / `AnthropicSession` so the rest of the agent code is
  provider-agnostic.
- Backed by an MLX runtime obtained through SwiftAcervo for model
  resolution and loading.
- The `apoderado` CLI consumes `MLXSession` only.

## R4. No remote inference providers

`OpenAISession`, `AnthropicSession`, and any other remote-API SwiftAgent
provider are removed from `Package.swift` and from `SwiftApoderado`'s
target dependencies. The product surface is local-only.

## R5. Hybrid tool-call strategy

`MLXSession` supports SwiftAgent tool calls via two paths and picks per
model at runtime:

- **Native:** if the loaded model advertises (or is configured to use)
  structured tool-call output, the session decodes those tokens
  directly into SwiftAgent tool-call values.
- **Prompted fallback:** otherwise, the session injects a tool schema
  into the system prompt, parses JSON tool-call payloads from the
  model's text output, and reports them through the same SwiftAgent
  interface.

The strategy is determined by per-model configuration (declared
alongside the model entry, not auto-detected at runtime) so behaviour
is reproducible.

## R6. Agent capabilities and approval model

The agent can read files, write files, and execute shell commands in
the user's working directory.

- All filesystem writes and all shell executions are gated by an
  approval prompt in the TTY before the action runs.
- Approval modes: per-action prompt (default), session-wide
  auto-approve (explicit opt-in flag), and a destructive-only prompt
  mode for power users — exact set TBD during design.
- Non-interactive invocations must either run with `--yes` /
  auto-approve explicitly set, or fail closed when an action would
  require approval. The agent never silently performs unapproved
  side-effects.
- Read operations (file reads, directory listing) do not require
  approval.

## R7. Model selection via SwiftAcervo slug

There is no baked-in default model. The user must declare which model
to run, and that identity is always a SwiftAcervo catalog slug —
SwiftAcervo owns model resolution end-to-end.

- Precedence: `--model <slug>` CLI flag overrides `APODERADO_MODEL`
  environment variable.
- If neither is set, the CLI fails closed with a clear error pointing
  at SwiftAcervo's catalog. It does not pick a model on the user's
  behalf.
- The slug is handed to SwiftAcervo, which resolves it to a concrete
  on-disk MLX model (downloading via the CDN if needed). `MLXSession`
  never accepts raw paths or non-SwiftAcervo identifiers — staying in
  the SwiftAcervo "cinematic universe" is the contract.

## R8. Named sessions with auto-generated names

Every conversation is a persisted, named session.

- If the user does not pass `--session <name>`, the CLI generates a
  name automatically (scheme TBD — likely timestamp plus a short slug)
  and reports it so the user can resume later.
- Passing `--session <name>` resumes that session if it exists, or
  creates it under that name if it does not.
- Sessions persist to disk between invocations. Exact location and
  storage format are design details, not requirements.
- Listing, deleting, and exporting sessions are expected CLI
  subcommands; their exact shape is a design detail.

## R9. Approval modes

The CLI ships with four approval modes. Per-action prompting is the
default; the others are opt-in.

- **Per-action (default):** every filesystem write and every shell
  execution prompts the user with the proposed action and a y/N
  response. Reads never prompt.
- **Auto-approve session (`--yes` / `--auto`):** all actions for the
  remainder of the run are approved automatically. Intended for
  trusted local work and non-interactive/scripted invocations.
- **Edits auto, shell prompts:** filesystem writes pass without
  prompting; shell executions still require approval. Rationale:
  filesystem changes are recoverable via git, shell side-effects are
  often not.
- **Command allowlist:** user can pre-declare shell command patterns
  that should be auto-approved (e.g. `git status`, `make test`).
  Anything outside the allowlist still prompts. Pattern syntax and
  config location are design details.

Non-interactive invocations must select one of the auto-approve modes
explicitly or fail closed when an action would otherwise prompt.

## R10. v1 tool primitives

`MLXSession` exposes the following SwiftAgent tools in v1:

- `read_file` / `list_dir` — read a file by path, enumerate directory
  contents. Never gated by approval.
- `write_file` / `edit_file` — create or overwrite a file, or apply a
  targeted old→new string replacement. Gated by R9 approval modes.
- `run_shell` — execute a shell command in the working directory and
  return stdout, stderr, and exit code. Gated by R9 approval modes.
- `search` — text/pattern search across the working tree (grep/find
  semantics). Never gated by approval.

Additional tools (web fetch, structured AST edits, etc.) are out of
scope for v1.

## R11. Session naming scheme

Auto-generated session names take the form `<verb>-<noun>`, where each
component is drawn from a curated list of common English words —
e.g. `swim-elephant`, `whisper-mountain`, `compile-otter`.

- Word lists are bundled with the binary; no network call needed.
- Names are memorable and easy to type from a `list` output.
- The pool must be large enough that random pairs collide rarely; on
  collision the generator retries, and after a small bounded number of
  retries falls back to appending a numeric suffix (`swim-elephant-2`).

## R12. Per-repo session storage

Sessions persist on disk at `<cwd>/.apoderado/sessions/` — one
directory per repository (or whatever working directory the CLI is
invoked from).

- Sessions are scoped to the project they were created in. Running
  `apoderado` in a different directory sees a different session pool.
- Storage format is a design detail (likely one file per session,
  JSON or JSONL transcript); not a requirement.
- The `.apoderado/` directory should be added to `.gitignore` by
  default — transcripts may contain prompts, file contents, or shell
  output that is not intended for version control. Sharing a session
  goes through R13's `export` subcommand, not `git add`.

## R13. Session-management subcommands

The `apoderado` CLI ships these session subcommands in v1:

- `apoderado sessions list` — enumerate known sessions in the current
  repo with name, timestamp, and message count.
- `apoderado sessions show <name>` (alias `cat`) — print the session
  transcript to stdout.
- `apoderado sessions delete <name>` (alias `rm`) — remove a session.
  Prompts for confirmation unless `--yes` is passed.
- `apoderado sessions export <name>` — write a session out as
  markdown or JSON for sharing or archival. Format selection via
  `--format`.

## R14. CLI manages `.gitignore` for session storage

The first time `apoderado` writes a session to `<cwd>/.apoderado/`,
the CLI ensures `.apoderado/` is present in the repository's
`.gitignore`. This is a hard requirement, not a default.

- If a `.gitignore` exists and does not already ignore `.apoderado/`,
  the CLI appends the entry.
- If no `.gitignore` exists, the CLI creates one containing the entry.
- The CLI must not silently commit transcripts. If it cannot write the
  ignore entry (e.g. read-only filesystem), it must surface the
  problem and fail closed rather than persist the session.
- This applies even when the working directory is not a git
  repository — the file is still written so the directory remains
  ignore-ready if `git init` is run later.

## R15. Output sanitization (env-var obfuscation)

The agent must not echo environment-variable values to the terminal.
A sanitization layer sits between every output source (tool results,
shell output, model text) and the TTY render, replacing matching
substrings with a redaction marker (e.g. `[REDACTED:VAR_NAME]`).

- Enabled by default. Disabling requires an explicit flag
  (`--no-redact` or similar) so users opt in to the risk consciously.
- Applies to: stdout/stderr from `run_shell` tool calls, file
  contents returned to the model that flow back into rendered output,
  and any model-generated text that happens to contain an env-var
  value.
- **Which values are redacted:** any env var whose name matches a
  curated sensitive-name pattern list (TOKEN, KEY, SECRET, PASSWORD,
  CREDENTIAL, AUTH, and similar — exact list is a design detail),
  plus any other value in the output that scores above an entropy
  threshold consistent with a random secret. This catches
  oddly-named secrets without redacting common values like `$HOME`.
- **Where redaction runs:** at *both* the render boundary and the
  persistence boundary. Transcripts written to
  `<cwd>/.apoderado/sessions/` (R12) are sanitized *before* hitting
  disk. The raw, unredacted output is never persisted. Consequence:
  a leaked transcript file cannot expose secrets, but the original
  output also cannot be reconstructed later.
- The entropy threshold and the sensitive-name pattern list are
  tuning details, not requirements.

## R16. Bidirectional content-transform pipeline

`SwiftApoderado` exposes an internal transform pipeline that runs on
content moving in *both* directions through the agent. R15's redaction
is the first concrete transform; the pipeline is the general mechanism
that future transforms (input sanitization, context trimming, tool
result reshaping, etc.) plug into.

- **Inbound transforms** run on everything before the model sees it:
  user prompts, tool results being fed back, file contents injected
  as context, and system-prompt fragments.
- **Outbound transforms** run on everything before it reaches the
  user or disk: model-generated text, tool-call summaries, and any
  output rendered to the TTY or persisted to the session transcript.
- Each transform is a small, composable unit with a single
  responsibility. The pipeline applies them in a defined, declarative
  order so behaviour is reproducible and testable in isolation.
- Inbound and outbound stacks are configured independently —
  symmetry is allowed but not required. R15's secret-redaction logic,
  for example, should run on *both* sides so secrets emitted by
  `run_shell` never enter the model's context in the first place.
- The pipeline is the *only* path content takes between the world
  and the model. Nothing bypasses it; nothing renders or persists
  without flowing through the outbound stack.

## R17. Allowlist configuration

The R9 command-allowlist is stored per project at
`.apoderado/allowlist`, one pattern per line.

- Pattern syntax is shell-glob (`*`, `?`, character classes), matched
  against the full command string. No regex.
- Blank lines and lines beginning with `#` are ignored (comments).
- Patterns are anchored to the full command; partial matches do not
  count. Example: `git status` matches `git status` exactly;
  `git status*` matches `git status -sb`; `make *` matches any
  single-argument `make` invocation.
- The file lives inside `.apoderado/` so it is covered by R14's
  `.gitignore` policy by default. Sharing an allowlist across a team
  is intentional and explicit (commit it manually or use R13 export).
- No user-global allowlist in v1.

## R18. Session storage format

Each session is stored as a single JSONL file at
`.apoderado/sessions/<name>.jsonl`. One JSON object per line, one line
per session event (user message, assistant turn, tool call, tool
result, system note).

- Append-only writes. New events are appended to the end of the file;
  prior lines are never rewritten.
- Crash-safe by construction — a `fsync` after each append leaves the
  file in a recoverable state even on abrupt termination.
- R15 redaction is applied *before* the event is serialized, so the
  on-disk bytes are already sanitized. There is no retrofit pass.
- The exact event schema (field names, type tags) is a design detail.

## R19. Transform pipeline shape

The R16 transform pipeline uses a single Swift protocol and static,
build-time composition.

- All transforms conform to a `ContentTransform` (or similarly named)
  protocol exposing a transform function and a fixed direction
  (`.inbound` or `.outbound`).
- Pipeline composition — which transforms run, and in what order —
  is declared in Swift source as part of `SwiftApoderado`'s setup.
  There is no runtime enable/disable, no config-file ordering, and no
  plugin mechanism in v1.
- Trade-off: users cannot turn off individual transforms without
  recompiling. R15 keeps its `--no-redact` escape hatch as a
  hand-wired flag on the redaction transform; other transforms get
  flags only as explicit features.

## R20. v1 transform set

The following transforms ship in v1, in addition to R15's redaction:

- **Prompt-template assembly (inbound).** Builds the system prompt
  from the working directory, tool schema (R5/R10), and any project
  metadata before the model's first turn.
- **Context-window trimming (inbound).** Drops or summarizes older
  turns as the conversation approaches the model's context limit so
  long sessions remain usable.
- **Large-file truncation (inbound).** When a `read_file` (or
  search) tool result exceeds a size threshold, truncates the
  payload with a clear marker before it enters the model's context.
- **Tool-result reshaping (inbound).** Normalizes `run_shell` output
  into a structured block (exit code, stdout, stderr, duration) so
  the model parses results reliably across shells and tools.

R15 redaction runs on the outbound side (model → TTY/disk) *and*
also on the inbound side over tool results, so a secret emitted by
`run_shell` never enters the model's context window in the first
place.

## R21. Distribution via central Homebrew tap

The `apoderado` CLI is distributed through the shared
`intrusive-memory/homebrew-tap` repository, alongside the other
intrusive-memory CLIs (`secuencia`, `hablare`, `bruja`, …). The formula
does **not** live in this repository.

- The formula file `apoderado.rb` is maintained in the sibling repo at
  `../homebrew-tap/Formula/apoderado.rb`, not in `SwiftApoderado/`.
- This repository ships no `Formula/` directory. CI, release tooling,
  and contributor docs must not assume one exists locally.
- The formula follows the tap's established pattern: it points at a
  prebuilt release tarball published to this repo's GitHub Releases
  (`apoderado-<version>-arm64-macos.tar.gz`) and pins by `sha256`,
  rather than building from source on the user's machine.
- Cutting a release therefore involves two repos: tag and publish the
  tarball here, then bump `url`, `version`, and `sha256` in
  `homebrew-tap/Formula/apoderado.rb`. Automation for this is a design
  detail, not a requirement.
- `depends_on` constraints (Apple Silicon, macOS Tahoe, etc.) live in
  the tap formula; this repo's Makefile remains the source of truth
  for how the binary is built, but the formula does not invoke it.

## R22. Tuning defaults

These are concrete starting values for parameters that earlier
requirements left abstract. They are defaults — chosen so the system
behaves sensibly out of the box — and may be tuned without amending
the requirement that introduced them.

- **R11 word-list size:** ~200 verbs × ~200 nouns ≈ 40,000 unique
  pairs. At per-repo scope (R12), collision probability stays low
  well past typical real-world session counts; the numeric-suffix
  fallback in R11 handles the rare overlap.
- **R15 entropy threshold:** Shannon entropy ≥ 3.5 bits/char on
  candidate substrings of length ≥ 20 characters, similar to common
  secret-scanner defaults. Below those thresholds, only the
  sensitive-name match path applies.
- **R15 sensitive-name patterns (starting list):** case-insensitive
  match against env-var names containing any of `TOKEN`, `KEY`,
  `SECRET`, `PASSWORD`, `PASSWD`, `CREDENTIAL`, `AUTH`, `SESSION`,
  `COOKIE`, `PRIVATE`. Refined as false-positive and false-negative
  reports come in.

## R23. Defer tap formula creation until v1 ships

R21 describes the *target* distribution surface. The actual
`apoderado.rb` in `../homebrew-tap/Formula/` is **not** to be created
yet — only once `apoderado` has a shippable v1 that produces a real
release tarball.

- "Shippable" means: the binary builds cleanly via the documented
  release path, the v1 tool primitives (R10) and approval modes (R9)
  work end-to-end against a real SwiftAcervo-resolved MLX model, and a
  versioned `apoderado-<version>-arm64-macos.tar.gz` has been
  published to this repo's GitHub Releases with a verifiable
  `sha256`.
- Until that bar is met, the tap stays untouched. No placeholder
  formula, no broken `url`, no `version "0.0.0"` stub — adding the
  formula early would let users `brew install apoderado` and get a
  failing or non-existent download, which poisons trust in the tap
  for every other CLI it hosts.
- When the bar is met, the rollout is: cut the GitHub release, write
  `homebrew-tap/Formula/apoderado.rb` against that release's tarball
  and sha256, open the PR in `homebrew-tap`, and only then announce
  installability.
- This requirement is intentionally last: it is a *gating milestone*,
  not a behavioural requirement of the CLI itself.

## Open Questions

None at this point. New questions will land here as implementation
surfaces them.
