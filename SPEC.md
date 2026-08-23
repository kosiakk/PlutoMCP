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
Probing a value, reading a docstring, computing statistics, rendering a plot, expanding a table: all of these are cells, usually ephemeral ones.
Tools exist only where cells cannot reach: lifecycle, the result record, raw bytes, and human-edit history.

Corollary: no scratchpad or second eval path (probes are visible ephemeral cells), no transactional layer (errored cells with messages ARE the validation, Pluto's reactive engine IS the validator), no in-cell notebook API (cells run in the worker process, control lives in the host, and one writer means clean provenance).

## Tools

Ten: `start, open, list, edit, run, read, output, bond, export, stop`.

- `start` / `stop`: server lifecycle. `stop` sweeps spill files.
- `open(path=nothing, create=false)`: get a notebook. Pathless create gives an anonymous scratch notebook. New notebooks get the wide-layout cell and the `AsPNG` helper injected.
- `list`: open notebooks and their paths.
- `edit`: insert, replace, delete cells. `ephemeral=true` inserts, runs unsaved, deletes on clean finish; on error or timeout the cell stays visible for the agent to remove.
- `run`: run cells. Overlaps `edit` deliberately, mirroring NotebookEdit habits.
- `read(cells, tree, wait_seconds, since)`: snapshot, dependency tree, wait-for-idle-or-new-error, and changes-since including human edits. The one status/wait/diff tool.
- `output(cell)`: one cell, complete. Full text, or PNG bytes for binary output. The only tool whose response is not the record.
- `bond`: set a `@bind` variable.
- `export`: standalone HTML.

New tools must pass two gates: cells cannot do it, and usage logs show the need.
Never a discriminator-parameter mega-tool (`action=...`): the schema must express what each operation requires.

## One record

Every tool response except `output` bytes, `start` host/secret, and `list` paths parses as the same record:
`finished, waited_seconds, errored, timestamp, cells`.
`cells` lists every cell the reactive cascade touched, including clean downstream re-runs.

Each cell entry carries: identity, `code`, rendered output, structured log entries (last 20, overflow counted and spilled), error message if any.

Output rendering:
- Text: inline up to 2 KB; larger becomes head 1 KB + tail 1 KB + spill file path.
- Homogeneous containers: Pluto's one-line sketch (length, eltype, head … tail). No expansion protocol; the agent's expand is a probe cell.
- Structs and heterogeneous tuples: one level of fields, no recursion.
- Binary: MIME and size, bytes via `output`.

## One vocabulary

- `wait_seconds` on every running tool; `waited_seconds` its receipt in the record. One semantics: return when finished or when time expires, expired means `finished=false`.
- `code` for cell text, everywhere. Human edits report `old_code` / `new_code`.
- `cell` / `cells` for addressing: name, UUID, or unique prefix, resolved by one shared function.
- `timestamp` from the record round-trips into `since`. The agent copies, never computes time.

## One loop

Stated once in the server description, elaborated in the plugin skill:
edit or run, check `finished`; if false, `read(wait_seconds=N, since=<timestamp>)`, same record.
Ephemeral cells for anything not worth keeping.
Prefer `@info` with key-value pairs over `println`: structured entries survive truncation individually, print spam loses its middle.

## Seeing hierarchy

How the agent looks at data, cheapest first:
1. The tree sketch in the record, for structure.
2. Ephemeral statistics cells, for numbers: exact answers cost less than reading raw values.
3. UnicodePlots in an ephemeral cell, for shape: 1-2 KB of text, no image tokens. `histogram` or `BlockCanvas` over the Braille default.
4. `AsPNG(fig)` last, when raster truth matters: fine detail, color, verifying what the human sees.

`AsPNG` exists because Pluto's MIME ordering prefers SVG and MCP images are PNG.
Format conversions are probe cells calling the plotting library directly.

## Safety and transport

- One truncation function guards every text path into a payload: cell output, stdout blobs, logs, `output` text. Oversize spills to a per-notebook directory, swept on `stop`. The spill path is the paging API: client and server share a machine (stdio), and Claude Code greps files better than any MCP payload.
- Host logging goes to stderr (`ConsoleLogger(stderr)`): the MCP framework prints JSON-RPC on stdout, so stdout must stay untouched. Worker output is isolated by Malt's private pipes.
- All notebook mutations go through Pluto's session actions under `executetoken`, never by direct struct mutation.

## Packaging and positioning

- Julia package, MIT licensed, registry-eligible, client-agnostic MCP server underneath.
- Claude Code plugin on top: auto-configured server plus two skills, `pluto-workflow` (the loop, ephemeral pattern, record semantics) and `pluto-seeing` (the hierarchy with a worked UnicodePlots example serving as readability fixture). No hooks.
- Niche: existing Julia MCP servers are REPL-shaped scratchpads (AgentREPL, MCPRepl, Kaimon). PlutoMCP is notebook-as-reviewable-artifact. The human-review channel and reproducible file are the point, not interactive evaluation.

## Design discipline

Simplicity is enforced, not preferred.
Accepted imperfections stay accepted: an errored ephemeral cell may transiently reach the file until the next save; no exclusion logic hides it, because it is visible and the agent cleans it up.
Every future addition needs evidence from usage logs, not symmetry, completeness, or anticipation.
When a capability seems missing, the first question is always: is it a cell?
