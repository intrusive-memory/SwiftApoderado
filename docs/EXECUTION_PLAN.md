# SwiftApoderado — Execution Plan

This plan sequences implementation of the requirements in
[REQUIREMENTS.md](REQUIREMENTS.md) (R1–R35) into phases that each
produce a runnable artifact and end at a concrete acceptance gate.
Phases are ordered by dependency; tracks *inside* a phase can run in
parallel.

The plan is a working document. When implementation surfaces an
unknown not captured in REQUIREMENTS.md, the unknown is added to
that file's *Open Questions* section rather than silently improvised
in code. When a phase's acceptance changes, this file is updated and
re-committed in the same PR as the work that motivated the change.

---

## Phase 0 — Scaffold (complete)

**Status:** done. Commits `fa16263`, `2063ade`.

- `SwiftApoderado` library + `apoderado` executable Swift package.
- Makefile, CI smoke test, integration-test harness, `.gitignore`.
- No agent logic yet — every later phase builds on this skeleton.

## Phase 1 — Local inference foundation

**Requirements satisfied:** R2, R3, R4, R5, R7.

**Goal.** `apoderado` resolves a model slug through SwiftAcervo,
loads it through MLX, drives a single non-tool turn through
`MLXSession`, and prints the assistant text to stdout. No tools, no
sandbox, no approval, no sessions yet.

**Work units.**

- Wire `SwiftAcervo` as a `Package.swift` dependency; remove
  `OpenAISession` / `AnthropicSession` and their providers from the
  product surface (R4).
- Implement `MLXSession` conforming to the SwiftAgent session
  protocol (R3); load MLX weights via the SwiftAcervo-resolved
  artifact (R2).
- Resolve model identity via `--model` flag with `APODERADO_MODEL`
  env-var fallback; fail closed with a SwiftAcervo-catalog-pointing
  error when neither is set (R7).
- Plumb R5's hybrid tool-call strategy *interfaces* — native and
  prompted-fallback paths both compile but the prompted path is a
  no-op stub; tool dispatch lands in Phase 2.

**Development model.** Development and integration tests target
`mlx-community/Qwen3-Coder-Next-4bit` (Qwen3-Coder-Next, 4-bit MLX
quantization, ~45GB, 262K context). The slug is already published
to the intrusive-memory CDN; SwiftAcervo resolves it without an
`acervo ship` step. This is the *development* model only — R7 still
forbids a baked-in runtime default, and the CLI continues to fail
closed when invoked without `--model` or `APODERADO_MODEL`. Phase 1
acceptance tests pass this slug explicitly.

Memory note: Qwen3-Coder-Next-4bit needs roughly 64 GB unified
memory to run comfortably at non-trivial context lengths (model
weights + KV cache + macOS headroom). Contributors on 32 GB
machines should expect to cap effective context length at runtime
or substitute a smaller catalog model for local iteration.

**Acceptance.** An integration test loads
`mlx-community/Qwen3-Coder-Next-4bit` via SwiftAcervo and asserts
the model returns non-empty assistant text against a deterministic
prompt. Test runs on a macOS arm64 runner with the model cached.

## Phase 2 — Parallel tracks (three independent work streams)

Phases 2A, 2B, 2C can be assigned to separate agents (up to 4 per
mission-supervisor convention) and merged in any order once their
acceptance gates pass.

### Phase 2A — Tool primitives and CWD sandbox

**Requirements satisfied:** R10 (all six v1 tools), R24 sandbox
mechanism (escape hatch wiring in Phase 3), R25 edit policy, R26
timeout.

**Goal.** Every v1 tool from R10 executes correctly inside CWD;
sandbox refuses path-escape attempts; `edit_file` enforces matching
policy; `run_shell` enforces wall-clock timeout. Approval is a stub
(always-approve) until Phase 3.

**Work units.**

- Implement `read_file`, `list_dir`, `search` with realpath-based
  sandbox check (R24): refuse arguments resolving outside CWD,
  including symlink traversal and absolute paths.
- Implement `write_file` and `edit_file`. `edit_file` requires a
  `policy` field in the tool payload (R25); v1 policies are
  `exact_unique` (fail on 0 or >1 matches) and `exact_all`. Reject
  calls missing the policy with an error naming the available
  policies.
- Implement `run_shell` with the R26 wall-clock timeout (default
  120s, 600s ceiling, 5s SIGTERM→SIGKILL grace). Stdin and
  stdout/stderr nuances follow the v1 defaults documented in
  REQUIREMENTS Open Questions.

**Acceptance.** Unit tests per tool covering:

- happy path
- sandbox-escape refusal (each path-bearing tool)
- `edit_file` zero-match, multi-match, exact-unique-success, and
  exact-all-success cases
- `run_shell` timeout firing on a `sleep` longer than the budget,
  with partial output captured and timeout marker present

### Phase 2B — Session persistence

**Requirements satisfied:** R8, R11, R12, R14, R18.

**Goal.** Sessions persist to `.apoderado/sessions/<name>.jsonl`
with append-only writes; auto-named sessions work; `.gitignore` is
managed automatically; the verb-noun naming scheme generates and
de-duplicates names.

**Work units.**

- Implement R11 verb-noun name generator with the R22 tunable word
  lists (~200 verbs × ~200 nouns) and the numeric-suffix fallback
  on collision.
- Implement R18 JSONL writer: `fsync` after each event append,
  one event per line, schema captured in a Swift type.
- Implement R12 per-repo storage layout and R14 `.gitignore`
  management — append `/.apoderado/` to an existing `.gitignore`,
  create one if it does not exist, fail closed if neither path is
  writable.

**Acceptance.** Integration tests:

- Auto-named session is created with a verb-noun name, JSONL grows
  with each event, file is valid JSON-Lines when re-read.
- `.gitignore` is created or updated correctly in a fresh temp
  directory.
- Two sessions with different names coexist in the same repo
  without interference.

### Phase 2C — Transform pipeline interface

**Requirements satisfied:** R16, R19.

**Goal.** The `ContentTransform` protocol and the inbound/outbound
pipeline composition compile and run. Empty pipelines pass content
through unchanged. Concrete transforms land in Phase 5.

**Work units.**

- Define the `ContentTransform` protocol with a `direction`
  (`.inbound` / `.outbound`) and a transform function appropriate
  to the streaming model planned for Phase 4 (i.e., consume tokens
  or events, emit tokens or events).
- Implement static, build-time pipeline composition (R19) with no
  runtime enable/disable.
- Provide a pass-through "identity" transform for the v1 tests.

**Acceptance.** A round-trip unit test: synthetic content flows
through an empty pipeline and emerges byte-identical; an identity
transform stack of arbitrary depth produces the same result.

## Phase 3 — Approval and safety

**Requirements satisfied:** R6, R9, R17, R33, R24 escape hatch.

**Depends on:** Phase 2A.

**Goal.** Tools that mutate state are gated by the R9 approval
modes. `--yes` / `--auto` honors the R33 floor.
`--dangerously-skip-permissions` relaxes both the R24 sandbox and
every approval gate, with no other escape hatch needed.

**Work units.**

- Implement the four R9 approval modes (per-action default,
  `--yes`/`--auto`, edits-auto/shell-prompts, command-allowlist).
- Implement the R17 allowlist file format
  (`.apoderado/allowlist`, shell-glob, full-command anchored,
  comments and blank lines ignored).
- Implement the R33 floor pattern list with matching against the
  *resolved* command (post `VAR=` and `sudo` stripping, post
  `bash -c "…"` unwrap).
- Wire `--dangerously-skip-permissions`: relaxes sandbox + every
  approval gate including R33's floor; re-specified per invocation;
  documented in `--help` as a hostile-named nuclear option.

**Acceptance.** Integration tests for each approval mode:

- Per-action prompts on writes and shell; reads never prompt.
- `--yes` runs unattended for ordinary commands but *still prompts*
  for each pattern in R33.
- `--dangerously-skip-permissions` runs without prompt for R33
  patterns and for absolute-path writes outside CWD.
- The R17 allowlist matches anchored shell-globs and ignores
  comments / blank lines.

## Phase 4 — Streaming and cancellation

**Requirements satisfied:** R27, R29.

**Depends on:** Phase 1 (model loop), Phase 2C (pipeline
interface).

**Goal.** Tokens stream out of the model and flow through chunkers
that frame the raw stream into display chunks, tool-call chunks,
and persistence chunks. Ctrl-C and Escape cancel the innermost
in-flight operation while keeping the transcript coherent.

**Work units.**

- Implement the token-stream consumer between MLX and the outbound
  transform pipeline (R29). Tokens propagate through transforms
  incrementally; no whole-turn buffering.
- Implement the three chunkers: display (punctuation/line bounded),
  tool-call (R5 native + prompted-fallback assembly), persistence
  (event finalization → JSONL append).
- Implement R27 cancellation: SIGINT and Escape both target the
  innermost in-flight op (model stream, `run_shell` subprocess,
  approval prompt, tool call). Partial output to the cancellation
  point lands in the transcript; tokens still in any redaction
  buffer are discarded. Second consecutive cancel exits the CLI.

**Acceptance.** A visual smoke test (operator confirms tokens land
progressively) plus unit tests covering chunker boundaries, the
"cancel mid-stream → partial transcript" path, and the
"cancel-cancel exits" two-keystroke rule.

## Phase 5 — v1 transforms (R15 redaction + R20 set)

**Requirements satisfied:** R15, R20.

**Depends on:** Phase 2C interface, Phase 4 streaming (for
redaction's live trailing buffer).

**Goal.** All v1 transforms wired into the pipeline:

- inbound prompt-template assembly (R20),
- inbound context-window trimming (R20),
- inbound large-file truncation for `read_file` / `search` (R20),
- inbound tool-result reshaping (R20),
- outbound redaction (R15) *and* inbound redaction over tool
  results, so secrets never enter the model's context window in the
  first place.

**Work units.**

- Implement R15 redaction with the R22 sensitive-name pattern list
  and the entropy threshold (Shannon ≥ 3.5 bits/char on substrings
  ≥ 20 chars). Wire as the trailing-buffer streaming transform from
  R29.
- Implement each R20 transform as its own `ContentTransform`. Order
  is declarative and lives in source.
- Verify R18 persistence sees only redacted content.

**Acceptance.** Integration test seeds `OPENAI_API_KEY=sk-…` into a
`run_shell` invocation; assertions verify the value is replaced
with `[REDACTED:OPENAI_API_KEY]` on the TTY, in the JSONL
transcript, and never appears in the assistant's next-turn context.

## Phase 6 — `run_shell` extensions

**Requirements satisfied:** R30, R31.

**Depends on:** Phase 2A (`run_shell` base), Phase 5 (tool-result
reshaping for delivery to the model).

**Goal.** `run_shell` tracks consecutive failures with the
3-attempt budget and reset rules (R30); first-use-per-session
preflight extracts usage docs through the R31 probe order and
attaches them to the first tool result.

**Work units.**

- Implement R30 budget bookkeeping in the tool dispatcher.
  Successful tool calls of any kind reset the counter; 4th
  consecutive failed `run_shell` returns a budget-exhausted result
  rather than executing.
- Implement R31 probe order
  (`--help` → `--usage` → `-h` → `man <util> | col -b`), with the
  R26 timeout governing each probe, R24 sandbox respected, no R9
  approval prompt. Cache results in memory keyed by utility
  basename for the session lifetime.
- Wire usage docs into the *first* tool-result reshape for that
  utility; do not re-attach on subsequent invocations.

**Acceptance.** Unit tests:

- Budget counts to 3, resets after a `read_file`, resets after a
  successful `run_shell`.
- Probe order short-circuits on the first non-empty probe; total
  failure records "no usage available" and lets the original
  command execute.
- Cached usage attaches to the first invocation only; a `git` call
  followed by another `git` call shows the help once.

## Phase 7 — CLI surface and primary loop

**Requirements satisfied:** R1, R13, R23, R28, R32.

**Depends on:** Phases 1–6.

**Goal.** The CLI is the actual product:

- bare `apoderado` opens an interactive REPL with a new auto-named
  session,
- `apoderado --session NAME` joins or creates that named session,
- non-interactive invocations follow the same session rules and
  exit when the assistant finishes,
- `apoderado sessions list / show / delete / export` work,
- the R23 Swift-first system prompt is assembled by R20's
  prompt-template transform,
- two `apoderado` invocations against the same session name
  fail-fast on the second via R32's lockfile.

**Work units.**

- Implement the R28 invocation surface; report the auto-generated
  session name on first prompt.
- Implement the R13 subcommands; the `delete` form prompts unless
  `--yes` is passed.
- Author the R23 system prompt covering: Swift-first orientation,
  v1 tool primitives (R10) with their approval implications (R9),
  the R25 `edit_file` policy contract, the R30 retry expectation,
  and the R24 sandbox boundary.
- Implement R32 lockfile acquisition with PID liveness check.

**Acceptance.** Manual smoke tests for the REPL and non-interactive
mode plus integration tests for:

- each session subcommand,
- a second invocation against an active session refusing with the
  R32 error message,
- a stale lockfile (PID not alive) being reclaimed silently.

## Phase 8 — Acceptance and release readiness

**Requirements satisfied:** R22 ratification, R34 confirmation,
R35 unlock.

**Goal.** Verify R1–R34 against the integration suite, ratify R22
tunables against observed behaviour, confirm R34's no-config
posture, then unlock R35 and ship.

**Work units.**

- Run the full integration suite against a SwiftAcervo-resolved
  model and capture results.
- Walk the R22 tunable list; adjust any value that real use has
  shown is wrong. Document changes in this file.
- Confirm no `.apoderado/config.*` reading code has crept in
  (R34).
- Tag a version, build
  `apoderado-<version>-arm64-macos.tar.gz` via the Makefile, upload
  to GitHub Releases, compute and verify `sha256`.
- Open the PR in `intrusive-memory/homebrew-tap` adding
  `Formula/apoderado.rb` against the release tarball and verified
  `sha256` (R35).

**Acceptance.** `brew install intrusive-memory/tap/apoderado`
succeeds against a clean Homebrew install and the installed binary
runs the full smoke test.

---

## Critical path

```
Phase 1 (model load)
  → Phase 2A (tools)
    → Phase 3 (approval)
      → Phase 4 (streaming + cancel)
        → Phase 7 (CLI surface)
          → Phase 8 (release)
```

The path is sequential because each step depends on its predecessor
producing usable output. Off-path work — Phase 2B (sessions), Phase
2C (pipeline skeleton), Phase 5 (transforms), Phase 6 (run_shell
extensions) — runs against the critical path in parallel and merges
in any order once its acceptance passes.

## Out of scope for v1

Explicit non-goals so the plan does not silently absorb scope:

- Remote inference providers (R4 forbids).
- Tap formula in `homebrew-tap` before a real release tarball
  exists (R35).
- Configuration file (R34).
- Multi-process session collaboration (R32).
- Plugin or runtime-loadable transforms (R19).
- Fuzzy or regex `edit_file` policies (R25).
- `run_shell` stdin nuances beyond v1 defaults (R26, Open Question).
- Non-Swift codebase tuning (R23).
- User-global allowlist; v1 is project-scoped only (R17).

## How to use this plan

- Acceptance is the gate. Do not start the next phase until the
  current phase's acceptance passes.
- Parallel tracks inside Phase 2 can be assigned to separate
  agents; merge order is supervisor-controlled.
- If implementation surfaces an unknown not captured in
  REQUIREMENTS.md, add it to that file's Open Questions section
  before improvising in code.
- This file is updated in the same PR as the work that motivates
  the change. Drift between REQUIREMENTS, EXECUTION_PLAN, and code
  is a defect.
