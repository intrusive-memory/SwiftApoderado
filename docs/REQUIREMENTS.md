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
- **R26 run_shell timeouts:** default 120 seconds per call,
  model-requested override capped at an absolute ceiling of 600
  seconds, 5-second grace between SIGTERM and SIGKILL when a timeout
  trips.
- **R30 run_shell retry budget:** 3 consecutive failed `run_shell`
  invocations before the model is informed the budget is exhausted;
  resets on the next productive tool result (any successful tool
  call, shell or otherwise).

## R23. Agent identity: Swift-first coding assistant

`apoderado`'s primary purpose is agentic coding for Swift projects —
Swift Package Manager libraries, Xcode app/library targets, Apple-
platform tooling — and everything adjacent that producing good Swift
code requires (shell, git, build systems, test runners, plain-text
editing, markdown docs).

- R20's prompt-template assembly transform identifies the agent as a
  Swift coding specialist in the system prompt, orients tool use
  around Swift workflows (SPM, `xcodebuild`, `swift test`/`swift
  testing`, file editing, git), and surfaces project context the
  agent should be aware of (presence of `Package.swift`, `*.xcodeproj`,
  `Makefile`, etc.).
- "Swift-first" is a centre of gravity, not an exclusion. The agent
  is expected to handle YAML, JSON, shell, Markdown, and helper
  scripts in other languages when they appear inside a Swift project's
  working tree.
- Non-Swift codebases are not in scope for v1 tuning. The CLI will
  still run in them; the system prompt and heuristics are not tuned
  for, e.g., a pure Rust monorepo, and that is acceptable.
- This requirement frames every other design choice: tool selection
  (R10), built-in command knowledge, system-prompt examples, and
  default project-metadata extraction.

## R24. Working directory is a hard security boundary

By default the agent's filesystem access — every path-bearing tool
argument — is rooted at the invocation's working directory. Paths
that resolve outside that root are refused before the action runs,
including via symlink traversal and absolute-path arguments. The
sandbox is enforced *in addition to* the R9 approval gates, not
instead of them.

- Resolution rule: every path argument to `read_file`, `list_dir`,
  `write_file`, `edit_file`, and `search` is realpath'd; if the
  resolved path is not a descendant of CWD, the tool returns an error
  to the model and the action does not execute. Approval prompts
  cannot override this check.
- `run_shell` inherits CWD and may `cd` within the subprocess's own
  environment, but the surrounding CLI's notion of CWD never changes
  mid-session. The shell is not a sandbox-escape vector for the
  filesystem tools.
- **Escape hatch:** `--dangerously-skip-permissions` (name matching
  the established agentic-CLI convention) relaxes *both* the
  filesystem sandbox *and* every R9 approval gate for the duration of
  the run. There is no per-tool granularity; the flag is all-in
  dangerous mode by design, so it has exactly one effect to reason
  about.
- The flag must be re-specified on every invocation. There is no
  persistent "trusted forever" mode written to disk.
- The flag name is intentionally hostile. `--help` and documentation
  must spell out the risk in plain language (arbitrary filesystem
  writes, arbitrary shell, no prompts) so it is never invoked by
  reflex.

## R25. `edit_file` matching policy is part of the tool call

The `edit_file` tool (R10) requires the model to declare a *matching
policy* alongside the `old` and `new` strings. The tool's behaviour
on ambiguous matches is determined by that policy, not by hidden
defaults. The R23 system prompt explicitly instructs the model that
it must specify a policy with every `edit_file` call.

- v1 policies:
  - `exact_unique` — fail closed unless `old` matches exactly once in
    the file. Designed for targeted edits where ambiguity is a bug.
    This is the safe path the model should reach for by default.
  - `exact_all` — replace every occurrence of `old`. Designed for
    renames and other intentionally-broad rewrites.
- The tool-call payload includes a `policy` field. Calls without one
  are rejected with an error message that names the available
  policies so the model can retry deliberately.
- When `exact_unique` fails on zero or multiple matches, the error
  returned to the model (via R20's tool-result reshaping transform)
  names the failure mode — "not found" vs. "matched N times" — so
  the model is steered toward adding surrounding context to
  disambiguate rather than blindly escalating to `exact_all`.
- Pattern matching, regex, and fuzzy match are not v1 policies.
  Adding a new policy is an explicit feature, not a default.

## R26. `run_shell` has a wall-clock timeout

Every `run_shell` invocation runs under a wall-clock timeout. Hitting
the timeout terminates the subprocess (SIGTERM, then SIGKILL after a
grace period if it has not exited) and returns a structured timeout
result to the model — captured stdout/stderr up to the cutoff, plus
an explicit timeout marker in place of the exit code.

- The model may override the default per call via an optional
  `timeout_seconds` field on the tool payload. The request is clamped
  to an absolute ceiling; the model cannot disable the timeout. All
  three numbers (default, ceiling, kill grace) are R22 tunables.
- The R23 system prompt informs the model that long-running commands
  — full test suites, clean builds, large package fetches — may need
  to be split into smaller invocations or given an explicit
  `timeout_seconds` within the ceiling.
- A timed-out shell call is a normal, recoverable event: the session
  transcript records the partial output and timeout marker, and the
  model is free to retry, narrow scope, or report failure.
- **Deferred to Open Questions:** stdin handling for `run_shell`
  (whether interactive prompts are supported, refused, or fed
  scripted input) and any nuances of stdout/stderr interleaving and
  real-time visibility. v1 picks reasonable defaults during
  implementation; the requirement-level ruling is intentionally
  postponed.

## R27. Cancellation: Ctrl-C or Escape aborts in-flight work

A single SIGINT (Ctrl-C) or Escape keypress cancels whatever the
agent is currently doing and returns control to the user without
exiting the CLI. A second consecutive cancellation, with no
intervening progress, exits the CLI cleanly.

- Cancellation targets the *innermost in-flight operation*: a
  streaming model turn, a running `run_shell` subprocess (SIGTERM
  then SIGKILL on the R26 grace), an approval prompt, or any other
  tool call. The user does not need to know which layer they are
  cancelling — one keystroke addresses whatever is on top.
- Partial output up to the cancellation point is recorded in the
  session transcript so the conversation history remains coherent on
  resume. Cancellation is an explicit event in the JSONL stream
  (R18), not a silent rollback.
- An approval prompt cancelled via Ctrl-C/Escape is treated as an
  explicit "no" — the gated action does not run, and the model is
  informed so it can react in its next turn.
- Non-interactive invocations honour SIGINT the same way: the in-
  flight action terminates and the process exits with a non-zero
  status. Escape is a no-op in non-TTY mode.
- The "second cancellation exits" rule prevents users from getting
  trapped when a model immediately kicks off new work after the
  first cancel; it provides a deterministic two-keystroke exit
  without needing a separate shortcut.

## R28. Primary invocation: new auto-named session by default

Running `apoderado` with no session argument starts a *new* session
with an auto-generated name (R11). An existing session is joined
only when the user explicitly passes `--session <name>`. There is no
implicit "resume the last session" behaviour.

- `apoderado` → interactive REPL, new auto-named session. The
  generated name is reported on the first prompt so the user can
  refer to it later via R13's `sessions` subcommands or `--session`.
- `apoderado --session NAME` → interactive REPL targeting NAME.
  Resumes that session if it exists under `.apoderado/sessions/`,
  creates it under that name if it does not (matches R8).
- Non-interactive invocations (R1) follow the same session rule: a
  new auto-named session by default, `--session NAME` to target an
  existing one.
- The R13 `sessions list`/`show`/`delete`/`export` subcommands
  operate on stored sessions; they do not establish an active
  conversation.
- Rationale: sessions stay cheap and disposable. A stale conversation
  never leaks into the next task by accident, and resuming is always
  an explicit, named act.

## R29. Streaming I/O with framed chunking

All conversation traffic between user, LLM, transforms, and
persistence layers flows as token-level streams in both directions.
There is no whole-turn buffering between the model and the rest of
the system; rendering, transformation, tool-call dispatch, and
persistence happen as tokens arrive.

- **Outbound (LLM → user / transcript).** MLX produces tokens one at
  a time; the runtime consumes them as a stream, runs them through
  R16's outbound transforms incrementally, and emits them to the TTY
  and to the R18 JSONL transcript as soon as each transform stack
  has cleared them. Whole-turn assembly happens nowhere — the same
  token leaves the model, is redacted (R15), is rendered, and is
  appended to disk while still in flight.
- **Inbound (user / tools → LLM).** Conversation context is
  assembled as a stream of typed events (user message, tool result,
  system note) that flow through the inbound transform stack
  (R16, R20). Each event is a discrete frame, never a concatenated
  blob.
- **Chunking is the framing layer.** The runtime exposes a small set
  of chunkers that consume the raw token stream and emit higher-level
  units the rest of apoderado consumes:
  - **Display chunks** — punctuation- or line-bounded segments
    rendered to the TTY progressively so the user sees output as it
    is produced.
  - **Tool-call chunks** — complete structured tool calls (R5 native
    or prompted-fallback) extracted from the stream and dispatched
    exactly once each, regardless of whether the model is still
    emitting subsequent tokens.
  - **Persistence chunks** — completed conversational events
    appended to the R18 transcript as they finalize, not as a
    deferred end-of-turn dump.
- **Redaction interaction.** R15 outbound redaction operates on the
  live stream. To avoid splitting a secret across a chunk boundary
  the redaction transform buffers a small trailing window long
  enough to contain the longest plausible secret marker before
  releasing tokens downstream. Buffered tokens reach the transcript
  and the TTY at the same instant — there is no "raw tail" sitting
  unredacted in memory longer than necessary.
- **Cancellation interaction.** A R27 cancellation aborts the token
  stream immediately. Tokens already cleared by the chunkers are
  preserved (they are part of the transcript and the user's view);
  tokens still in flight inside the redaction buffer are discarded
  rather than flushed unredacted.

## R30. `run_shell` failure retry policy

A non-zero exit from `run_shell` is a recoverable event, not a
terminal one. The model receives the failure (exit code, captured
stdout, stderr, the command it ran) via R20's tool-result reshaping
transform and is expected to retry with an adjusted command. The
runtime caps how many consecutive retries the model can spend on the
same line of investigation so a confused or looping model cannot
burn the session.

- **Budget:** 3 consecutive failed `run_shell` invocations. The
  initial failing call counts as the first attempt; the model has at
  most two further retries before the budget is exhausted. The value
  is an R22 tunable.
- **Reset rule:** any *productive* tool result — a successful
  `run_shell` (exit code 0) or a successful non-shell tool call
  (`read_file`, `list_dir`, `search`, `write_file`, `edit_file`) —
  resets the counter to 0. Stepping back to investigate with read
  tools after a shell failure is correct behaviour and is not
  punished by the budget.
- **Exhaustion:** after the 3rd consecutive failure the next
  `run_shell` call returns a budget-exhausted notice instead of
  executing. The model is instructed (via R23's system prompt) to
  read state, search, ask the user, or report failure rather than
  issuing another shell command. The user's conversation continues
  normally; the counter resets the next time any tool produces a
  result.
- **The model adjusts each retry.** The system prompt instructs the
  model that mechanical retry of the same command is wasted budget —
  each attempt should change something (flags, arguments, working
  directory, prerequisite). The runtime does *not* mechanically
  compare command strings to enforce adjustment; this is a
  behavioural instruction, not a hard check.
- **Approval interaction.** Each retry is independently gated by R9
  approval modes. A user-denied approval prompt is *not* counted as
  a failure for retry-budget purposes — denials are user-driven, not
  command failures.

## R31. `run_shell` pre-flight usage extraction

The first time a given CLI utility is invoked via `run_shell` in a
session, apoderado extracts the utility's usage documentation and
surfaces it to the model alongside the actual command's result.
Subsequent invocations of the same utility within the same session
reuse the cached docs.

- **Probe order:** `<util> --help`, then `<util> --usage`, then
  `<util> -h`, then `man <util>` (output filtered through `col -b`
  to strip control sequences). The first probe to produce non-empty
  output on stdout wins. All four failing is recorded as "no usage
  available" and is not retried within the session.
- **Caching:** extracted docs live in memory for the lifetime of the
  session, keyed by utility basename. They are not persisted to the
  R18 transcript — they are reproducible context, not conversation
  history.
- **Utility identification:** the first token of the command, after
  stripping leading `VAR=value` environment-variable assignments and
  any leading `sudo`. Pipelines (`a | b | c`) are treated as a list
  of utilities, each probed and cached independently.
- **Approval and sandbox interaction.** Usage extraction is *not*
  gated by R9 approval — running `<util> --help` is treated as a
  read-style probe. It still respects R24's CWD sandbox (the probe
  runs in CWD like every other shell action), and it is bounded by
  R26's wall-clock timeout so a misbehaving `--help` cannot hang the
  session.
- **Failure does not block execution.** If probes fail, time out, or
  the utility cannot be located on `PATH`, apoderado proceeds with
  the model's requested command and reports the extraction failure
  in the tool result rather than refusing the call.
- **Delivery to the model.** Usage docs are appended to the *first*
  tool result for that utility via R20's tool-result reshaping
  transform. The model sees them alongside the command's output and
  uses them when revising subsequent invocations. Repeat
  invocations of the same utility do not re-attach the docs — they
  are already in conversation context.

## R32. Defer tap formula creation until v1 ships

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

- **R26 `run_shell` stdin policy.** Should `run_shell` accept piped
  input from the model's tool call, refuse stdin outright (so any
  command needing interactive input fails closed), or feed a scripted
  payload? Currently deferred; v1 implementation picks reasonable
  defaults that this question will ratify or revise.
- **R26 `run_shell` stdout/stderr policy.** Are stdout and stderr
  reported as separate captured streams, interleaved in arrival
  order, or both? Is anything echoed to the user's TTY in real time,
  or only summarized after completion? Same posture: implementation
  picks, this question ratifies.

New questions will land here as implementation surfaces them.
