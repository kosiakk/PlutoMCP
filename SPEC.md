# PlutoMCP

MCP server that lets an AI agent author and run Julia Pluto notebooks, with a human reviewing live in the browser.

## Purpose

Research code rots into orphaned scripts and unexplained CSVs and PNGs.
PlutoMCP makes the unit of work a Pluto notebook: reactive, reproducible from scratch, self-contained with its package environment.
The agent writes the notebook, the human reviews it.
A finished experiment is an artifact anyone can re-run, not a pile of provenance-free outputs.

## Interaction model

The AI owns the notebook and invites the human in, not the reverse.
The human's browser edits are a first-class communication channel: every human change is tracked and reported back to the agent with old and new code.
The agent is the only programmatic writer.
Cells are pure computation and never control the notebook they live in.

## Core principle

**Every capability question has the same answer: the agent writes a cell.**
Probing a value, reading a docstring, computing statistics, rendering a plot, expanding a table: all of these are cells, usually deleted on success.
Tools exist only where cells cannot reach: lifecycle, the result record, raw bytes, and human-edit history.

Corollary: no scratchpad or second eval path (probes are visible cells), no transactional layer (errored cells with messages ARE the validation, Pluto's reactive engine IS the validator), no in-cell notebook API (cells run in the worker process, control lives in the host, and one writer means clean provenance).

## Tools

Ten. Signatures are the contract; defaults shown.

```
start()
open(path=nothing, create=false, wait_seconds=0.1)
list()
edit(notebook, cell=nothing, code=nothing, mode="replace", wait_seconds=0.1, delete_on_success=false)
run(notebook, cells=nothing, wait_seconds=0.1)
read(notebook, cells=nothing, tree=false, wait_seconds=0.1, since=nothing)
output(notebook, cell)
bond(notebook, name, value, wait_seconds=0.1)
export(notebook, path=nothing)
stop(notebook=nothing, cell=nothing)
```

- `start` / `stop`: lifecycle, scope narrowing with each argument. `stop()` stops everything, `stop(notebook)` shuts one notebook down and sweeps its spill files, `stop(notebook, cell)` interrupts that cell's evaluation (the UI stop button).
- `open`: get a notebook, running it. Pathless create gives an anonymous scratch notebook (Pluto cutename in tempdir); the description tells the agent to name kept work after the experiment. New notebooks get the wide-layout cell; every workspace gets the `AsPNG` helper.
- `list`: open notebooks and their paths.
- `edit`: `mode` is `replace`, `insert` (after `cell`, or append when `cell=nothing`), or `delete`. Modes share every other argument, which is why one tool holds them. `delete_on_success=true`: the cell runs normally in the workspace, visible in the browser, and is deleted iff `status` is `success` at return time; otherwise it stays and the agent removes it by the returned id. With `wait_seconds=0` the server returns before witnessing success, so the flag never fires. That return-time deletion is its entire contract.
- `run`: recompute cells (`cells=nothing` means all). Backup path only: `edit` saves and runs, human browser edits run through Pluto's UI, so `run` exists for cells whose non-reactive inputs changed (files on disk, RNG, env). The from-scratch reproducibility check is `stop` + `open`, not `run`.
- `read`: snapshot, dependency tree (`tree=true`), wait until nothing is `pending`/`calculating` or a new error appears, changes since a timestamp including human edits. The one status/wait/diff tool.
- `output`: one cell, complete. Full text, or PNG bytes for binary output. The only tool whose response is not the record.
- `bond`: set a `@bind` variable and report the cascade.
- `export`: standalone HTML.

New tools must pass two gates: cells cannot do it, and usage logs show the need.
Never a discriminator parameter over unrelated operations (`action=...`): `edit`'s modes qualify as one tool only because they share their argument list.

## One record

Every tool response except `output` bytes, `start` host/secret, and `list` paths parses as the same record:
`status, waited_seconds, timestamp, cells`.
`cells` lists every cell the reactive cascade touched, including clean downstream re-runs.

Cells this session already saw, unchanged, compress to `name, status, unchanged_since=<timestamp>`: at record build the server hashes each cell's full pre-truncation entry (code, status, rendered body, error, logs) and compares against the last hash reported to this session. Lazy, never on events: unreported intermediate states leave no trace, because the reference point is the agent's context, not notebook history.
Unchanged certifies the rendered output; for sketched containers that is the summary, not the underlying data — value-level certainty is a probe cell (`hash(x)`).
The cascade stays fully visible either way.

`status` is one enum at both levels: `pending | calculating | success | error`.
Cells carry their own; the record aggregates by one rule: any cell `error` means `error`, else any `pending` or `calculating` means `calculating`, else `success`.
`wait_seconds=0` returns immediately with `status=calculating` and cell ids; completion is observed by the next `read`.
Polling through the loop is the notification mechanism: no server push.

Each cell entry carries: identity, `status`, `code`, rendered output, structured log entries (last 20, overflow counted and spilled), error message if any.

Output rendering:
- Text: inline up to 2 KB; larger becomes head 1 KB + tail 1 KB + spill file path.
- Homogeneous containers: Pluto's one-line sketch (length, eltype, head … tail). No expansion protocol; the agent's expand is a probe cell.
- Structs and heterogeneous tuples: one level of fields, no recursion.
- Binary: MIME and size, bytes via `output`.

## One vocabulary

- `wait_seconds` on every running tool, default 0.1; `waited_seconds` its receipt in the record. One semantics: return on completion, on new error, or on expiry, whichever comes first. Expiry shows as `status=calculating`. Fast cells converge within the default; `0` is fire-and-forget for batch authoring.
- `status`: `pending | calculating | success | error`, the only progress vocabulary. No `finished`, no `errored` booleans anywhere.
- `code` for cell text, everywhere. Human edits report `old_code` / `new_code`.
- `cell` / `cells` for addressing cells, `notebook` for addressing notebooks: name/path, UUID, or unique prefix, resolved by one shared function.
- `timestamp` from the record round-trips into `since`. The agent copies, never computes time. The stamp is snapshot acquisition time, taken before cell state is read, assembly under the notebook lock: concurrent changes land at or after the stamp and reappear next `read`. Delivery is at-least-once; dedup makes duplicates cost one compact line. `since` is a view over the same reported-hash comparison: omit unchanged cells instead of compacting them. Never Pluto run timestamps: re-ran is not changed.

## One loop

Stated once in the server description, elaborated in the plugin skill:
edit, then check `status`: `success` proceed, `error` read the cells and fix, `calculating` call `read(wait_seconds=N, since=<timestamp>)`, same record.
`delete_on_success` cells for anything not worth keeping.
Prefer `@info` with key-value pairs over `println`: structured entries survive truncation individually, print spam loses its middle.

## Seeing hierarchy

How the agent looks at data, cheapest first:
1. The tree sketch in the record, for structure.
2. Throwaway statistics cells, for numbers: exact answers cost less than reading raw values.
3. UnicodePlots in a `delete_on_success` cell, for shape: 1-2 KB of text, no image tokens. `histogram` or `BlockCanvas` over the Braille default.
4. `AsPNG(fig)` last, when raster truth matters: fine detail, color, verifying what the human sees.

`AsPNG(fig)` is a wrapper whose only `show` method is `image/png`. It must exist: Pluto stores one rendered MIME per cell by its own preference (SVG for Plots, HTML for some backends), `output` never re-executes, so PNG bytes exist only if a cell renders them.
Format conversions are probe cells calling the plotting library directly.

## Safety and transport

- One truncation function guards every text path into a payload: cell output, stdout blobs, logs, `output` text. Oversize spills to a per-notebook directory, swept on `stop`. The spill path is the paging API: client and server share a machine (stdio), and Claude Code greps files better than any MCP payload.
- Host logging goes to stderr (`ConsoleLogger(stderr)`): the MCP framework prints JSON-RPC on stdout, so stdout must stay untouched. Worker output is isolated by Malt's private pipes.
- All notebook mutations go through Pluto's session actions under `executetoken`, never by direct struct mutation.

## Packaging and positioning

- Julia package, MIT licensed, registry-eligible, client-agnostic MCP server underneath.
- Claude Code plugin on top: auto-configured server plus two skills, `pluto-workflow` (the loop, the delete_on_success pattern, record semantics) and `pluto-seeing` (the hierarchy with a worked UnicodePlots example serving as readability fixture). No hooks.
- Niche: existing Julia MCP servers are REPL-shaped scratchpads (AgentREPL, MCPRepl, Kaimon). PlutoMCP is notebook-as-reviewable-artifact. The human-review channel and reproducible file are the point, not interactive evaluation.

## Design discipline

Simplicity is enforced, not preferred.
Accepted imperfections stay accepted: a failed `delete_on_success` cell reaches the file until the agent removes it; no hiding logic, because it is visible and the agent cleans it up.
Every future addition needs evidence from usage logs, not symmetry, completeness, or anticipation.
When a capability seems missing, the first question is always: is it a cell?
