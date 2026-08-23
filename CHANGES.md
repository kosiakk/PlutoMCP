# PlutoMCP change requests, round 2

## Principle

Every capability question in the design review had the same answer: the agent writes a cell.
Tools exist only where cells cannot reach: lifecycle, the result record, raw bytes, and human-edit history.

Acceptance test for every change below: every tool response except `output` bytes, `start` host/secret, and `list` paths must parse as the same record.
If the agent needs a second parser, the change is wrong.

End state: 10 tools (`start, open, list, edit, run, read, output, bond, export, stop`), one record, one loop, one vocabulary.
The `run` vs `edit` overlap is deliberate (NotebookEdit familiarity). Do not merge them.
Do not add tools, parameters, or state beyond what is written here.

## 0. One vocabulary

These words appear in schemas, records, and docs. No synonyms, no abbreviations, no second spelling anywhere.

- `wait_seconds`: parameter on every tool that runs or waits (`run`, `edit`, `read`, `bond`, `open`). Default 0.1, so fast cells converge in-call; explicit `0` is fire-and-forget. Semantics, stated once in the server description: return the record on completion, on new error, or on expiry, whichever comes first. Replaces `block`, the `run_with_deadline` deadline, and any per-tool timeout. It is the same value flowing to the same internal function.
- `status`: one enum, `pending | calculating | success | error`, at both cell and record level. Replaces the `finished` and `errored` booleans everywhere. Record aggregation rule: any cell `error` means `error`, else any `pending`/`calculating` means `calculating`, else `success`. `wait_seconds=0` returns `status=calculating` with cell ids; no server push notifications, the next `read` observes completion.
- `waited_seconds`: record field, the receipt for `wait_seconds`. Renames `waited_s`.
- `code`: the text of a cell. Matches Pluto internals. Never `source`. CHANGES entries use `old_code`/`new_code`.
- `cell` / `cells`: the only parameter names for addressing cells. Accepted forms, defined once: cell name, UUID, or unique prefix of either. Identical resolution logic in every tool.
- `timestamp`: record field, server clock at record creation. `since` accepts exactly this value. The agent copies it back, never computes time.
- Unification rule for future changes: unify words and semantics. Never unify by hiding distinct operations behind a discriminator parameter (the `pkg(action=...)` anti-pattern): a schema cannot express which arguments each action needs, and the agent loses exactly the structure that makes tools better than a bare REPL.

## 1. One result record

`_run_result` becomes the universal response shape: `status, waited_seconds, timestamp, cells`.
`cells` entries are `cell_info` records.
Emitted by `run`, `edit`, `open`, `read`, `bond`.

## 2. Cascade, not targets

`cells` covers everything the reactive run touched, including cells that re-ran cleanly.
Currently `ran = length(targets)` misses clean downstream re-runs.

## 3. `cell_info` output rendering

Text bodies pass through the truncation function (item 8).
Binary output: MIME and size only, fetchable via `output`.
Tree/table MIMEs (`application/vnd.pluto.tree+object` and friends) are Dicts today and get `astext()`-dumped. Render Pluto's own sketch instead:

- Homogeneous containers (arrays, tables): one line. Length, eltype, head elements, ellipsis, tail elements. Example: `Vector{Float64}, 100000 elements: [0.12, 3.4, …, 9.8]`. Depth 0, no expansion.
- Structs and heterogeneous tuples: one level of fields. Field name, type, scalar values inline, nested containers as their one-line sketch. No recursion.

Do not replicate Pluto's WS expand-rows protocol.
The agent's "expand" is a throwaway cell: `x[4090:4110]`, `describe(df)`, `quantile(x, [0.01, 0.5, 0.99])`.

## 4. Merge `create` into `open`

`open(path=nothing, create=false)`.
Both operations mean "get me this notebook" and both return the record.
`path=nothing` with `create=true`: anonymous scratch notebook via Pluto's own new-notebook flow (tempdir, cutename).
Tool description tells the agent: name the file after the experiment when the work is meant to be kept.
The create branch keeps the current `create` behavior: new notebook file, `WIDE_LAYOUT_CELL` prepended, `AsPNG` helper injected (item 9).
The open branch injects `AsPNG` too.
Delete the `create` tool.

## 5. `read` absorbs `status`

Signature: `read(cells=nothing, tree=false, wait_seconds=0, since=nothing)`.

- No arguments: instant snapshot of all cells.
- `cells`: subset by the standard selector (item 0).
- `tree=true`: add `references` (PlutoRunner internals filtered) plus `upstream`/`downstream` by cell name from `nb.topology`.
- `wait_seconds>0`: wait until no cell is `pending` or `calculating`, or until a new error, whichever comes first. "New error" means: a cell in `status=error` that was not at call time, or whose error message changed. Reuse the existing early-return logic from `run_with_deadline`. Do not reimplement.
- `since`: only cells changed after that timestamp. Human edits included with `old_code`/`new_code`, from the existing CHANGES log.

Delete the `status` tool.
There is no `full` parameter. Full text for one cell is `output`'s job (item 7).

## 6. `edit` gains `delete_on_success` (default false, insert only)

The cell is given to Pluto normally: it runs in the workspace and is visible in the browser.
If `status` is `success` at return time: capture the record, delete the cell, return. That return-time deletion is the entire contract, hence the name. With `wait_seconds=0` the flag never fires and the agent deletes by the returned id.
Errored or timed out: the cell stays, record says so, agent deletes it later with an ordinary `edit` delete.
Skipping the intermediate file write (`save=false`) is an implementation detail for code comments, not part of the contract.

Known and accepted: a failed cell reaches the file until the agent removes it.
Do NOT add exclusion logic to `save_notebook`.
The cell is visible, the agent cleans it up.

No stored state, no sweeper, no new lifecycle.

## 7. Delete `execute`, `docs`, `deps`, `png`, `status`

Replacements, for the tool descriptions and skill doc:

- Probing and docstrings: throwaway cells (`delete_on_success`). `@doc special_func` for exactly the names the agent is unsure of. The agent's own uncertainty selects them, which no tool schema can know.
- Dependencies: `read(tree=true)`.
- Waiting: `read(wait_seconds=N)`.
- PNG: item 9.

## 8. `output` = one cell, complete

Signature: `output(cell)`. No MIME parameter, no paging parameters.
The cell's output dict decides:

- Text available: full text, through the truncation function (item 9). Over the limit means head + tail + spill file path.
- Binary only: `image/png` as ImageContent. Over ~1 MB: spill to file, return the path.

Format conversion (SVG, WebP, PDF) is a probe cell with the plotting library's own save call, never a tool feature.
The spill file path is the paging API. Claude Code reads and greps local files better than any MCP payload.

## 9. One truncation function, applied everywhere

Single function, applied at every point text enters a payload: cell output bodies, stdout capture, log blobs, `output` text.

Rule: 2 KB or less goes inline unchanged.
Larger: first 1 KB + last 1 KB + marker line `… (<total size>, full output: <path>)`.
Head AND tail. Tails hold errors and final results.

Spill directory: per notebook, e.g. `/tmp/plutomcp/<notebook-id>/<cell>-output.txt`.
Swept on `stop`.

## 10. PNG via injected helper, not tool

Inject `PlutoMCP.AsPNG(fig)` into each workspace on `open`.
Wrapper type whose only `show` method is `image/png`: Plots via savefig-to-buffer, Makie native.
Reason it must exist: Pluto's MIME ordering prefers SVG when a backend offers both, and MCP images are PNG.
Rendering is then a throwaway cell `AsPNG(myplot)` and bytes flow through the existing image branch and item 8.
Delete the old `png` tool's insert-run-delete machinery.

## 11. Structured logs, capped

Pluto captures `@info`/`@warn`/`@error` per cell as discrete entries. Put them in the cell record as entries.
Keep the last 20 entries per cell, count the dropped: `+312 earlier entries → <path>`.
Full log spills to the same per-notebook directory.
`println` output is one stdout blob and hits the truncation function like any text.

## 12. Host logging off stdout

`ModelContextProtocol.jl`'s `run_server_loop` writes JSON-RPC responses with bare `println` to stdout.
Therefore stdout redirect is impossible (already tried, already reverted).
Fix at the logger instead: `global_logger(ConsoleLogger(stderr))` in server startup, so host-side Pluto logging can never corrupt the transport.
Worker (cell) output is already safe: Malt keeps worker streams on private pipes.

## 13. Server description: one loop, short

The server-level description states the loop once, not per tool:

> Edit, then check `status`: `success` proceed, `error` read the cells and fix, `calculating` call `read(wait_seconds=N, since=<timestamp from the record>)`, same record. Use `delete_on_success` for anything not worth keeping. Prefer `@info` with key-value pairs over `println`: structured entries survive truncation individually.

Per-tool descriptions shrink to schema plus one sentence.
Workflow doctrine moves to the skill (item 14).

## 14. Claude Code plugin

Add `.claude-plugin/`: manifest with the MCP server config (auto-setup via `claude /plugin add kosiakk/PlutoMCP`), plus two skills.

- `pluto-workflow`: the loop, the delete_on_success pattern, record semantics, the failed-probe cleanup convention.
- `pluto-seeing`: the seeing hierarchy — tree sketch for structure, throwaway statistics for numbers, UnicodePlots in a throwaway cell for shape, `AsPNG` last when raster truth matters. Include a worked UnicodePlots example: an actual `histogram` output with the correct verbal reading of it. Recommend `histogram` or `canvas=BlockCanvas` over the Braille default. This doubles as the readability test fixture.

The MCP server stays standalone and client-agnostic. The plugin is packaging, not a dependency.
No hooks. Revisit after a month of usage logs.

## 15. `stop` narrows by argument

`stop(notebook=nothing, cell=nothing)`.
No arguments: stop everything.
`notebook`: shut that notebook down, sweep its spill files.
`notebook` and `cell`: interrupt that cell's evaluation, the equivalent of the UI stop button.
Cells cannot interrupt themselves, so this is legitimate tool territory.

## 16. `run` is the backup path

`edit` saves and runs. Human browser edits run through Pluto's own UI.
`run` remains only for recomputing cells whose non-reactive inputs changed: files on disk, RNG, environment.
Its description says so. The from-scratch reproducibility check is `stop` + `open`, not `run`.

## 17. Deduplicate unchanged cells per session

Per-(session, notebook) map, alongside the CHANGES infrastructure: cell id to (reported_hash, reported_at).
Identity hash covers the full pre-truncation cell entry: code, status, rendered output body, error message, log entries.
Hashing is LAZY: computed only while building a record, never on StateChangeEvents. Intermediate states that were never reported leave no trace (ABA is correct here: the reference point is what this session already has in context, not notebook history).
Building a record, under the notebook lock, record `timestamp` stamped BEFORE reading cell state: current hash equal to reported_hash means the compact entry `name, status, unchanged_since=<reported_at>`; different means a full entry, then update the map. Stamp-first turns concurrent changes into at-least-once redelivery, which this dedup makes cheap; stamp-last would lose them.
`since` is a presentation choice over the same comparison: without it, unchanged cells appear compactly (blast radius visible); with it, they are omitted (pure delta). No separate per-cell change timestamps, no run counters. Pluto's `last_run_timestamp`/`runtime` may ride along in full entries as metadata, never as the delta signal.
Document the honesty boundary in the field description: `unchanged_since` certifies the rendered output. For sketched containers that is the summary, not the value. Value identity is a probe cell (`hash(x)`), never a server feature.

## 18. Cleanup

- License: GPL-3 → MIT. Blocks upstreaming and registry eligibility otherwise.
- Remove the `questions` tool and the `attach_assistant!` fork path. The `kosiakk/Pluto.jl` branch is dead code. Remove the README link.
- KEEP the StateChangeEvent human-edit tracking and the CHANGES log. Human browser edits are the review channel. This is a hard requirement.
- README: add a one-row positioning note. REPL-shaped MCP servers exist (AgentREPL, MCPRepl, Kaimon); PlutoMCP is notebook-as-reproducible-artifact. Different niche.

## Out of scope

- MCP resources (notebook list, cell snapshot as @-mentions): file an issue, do not build.
- Any paging, offset, or byte-range parameters anywhere.
- Any transactional/validation layer. Errored cells with messages ARE the validation.
- Any scratchpad or second eval path. Probes are visible cells by design.
- A `move`/save-as tool: file an issue. Live-notebook relocation needs `SessionActions.move`, but the authoring workflow knows paths upfront. Build it when usage logs show anonymous notebooks graduating.
- Wrapping more of Pluto's native session API. Each operation earns a lifecycle tool through usage logs, never through completeness.
- Any in-cell notebook-control mechanism (`@notebook` macro or similar). Cells run in the worker process, the session API lives in the host: this would be a second RPC control path, and it makes cells writers of their own notebook. The agent is the only writer, cells are pure computation.
- A batch/array form of `edit`. Sequential `wait_seconds=0` inserts plus one `read` cover batch authoring; build the array form only if usage logs show cascade churn.
- Further tool deletion or merging. Next round is decided by a month of usage logs, not design.
