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

Eight. Signatures are the contract; defaults shown.

```
start(port=nothing)
open(path=nothing, create=false, wait_seconds=0.1)
edit(notebook, cell=nothing, code=nothing, mode="replace", wait_seconds=0.1, delete_on_success=false)
run(notebook, cells=nothing, wait_seconds=0.1)
read(notebook, cells=nothing, tree=false, wait_seconds=0.1, since=nothing)
output(notebook, cell=nothing, mime, path=nothing)
bond(notebook, name, value, wait_seconds=0.1)
stop(notebook=nothing, cell=nothing)
```

- `start` / `stop`: lifecycle, scope narrowing with each argument. One server per process — no session parameter, since a stdio server has one client. `stop()` stops everything, `stop(notebook)` shuts one notebook down and sweeps its spill files, `stop(notebook, cell)` interrupts that cell's evaluation (the UI stop button).
- `open`: get a notebook, running it. Pathless create gives an anonymous scratch notebook (Pluto cutename in tempdir); the description tells the agent to name kept work after the experiment. A created notebook is EMPTY — content in it is the agent's, never this package's. Every worker gets the render helper.
- `edit`: `mode` is `replace`, `insert` (after `cell`, or append when `cell=nothing`), or `delete`. A cell whose expression is `md"…"` or `html"…"` is created folded — Pluto's own `code_folded`, persisted in the file as a `# ╟─` line. A display default made where a person would make the same one; it takes no parameter, appears in no record, and one click undoes it. Modes share every other argument, which is why one tool holds them. `delete_on_success=true`: the cell runs normally in the workspace, visible in the browser, and is deleted iff `status` is `success` at return time; otherwise it stays and the agent removes it by the returned id. With `wait_seconds=0` the server returns before witnessing success, so the flag never fires. That return-time deletion is its entire contract.
- `run`: recompute cells (`cells=nothing` means all). Backup path only: `edit` saves and runs, human browser edits run through Pluto's UI, so `run` exists for cells whose non-reactive inputs changed (files on disk, RNG, env).
- `read`: snapshot, dependencies (`dependencies=true`: `uses` and `used_by`, flat lists of cell names, one hop each way), wait until nothing is `running`/`queued` or a new error appears, changes since a timestamp including human edits. The one status/wait/diff tool.
- `output`: one cell — or, with no `cell`, the notebook itself (`text/html` is Pluto's export: state embedded, frontend from a CDN, so not an offline file; `text/plain` is the `.jl` source) — in the representation the caller names. `mime` is required — `image/png` (a figure, SVG rasterised on the way out), `text/plain` (the full value, past the record's one-level rule), `text/html` (a markup cell's raw markup). The record already said what the cell stored, so a tool that guesses is a tool that returns markup nobody can read. The only tool whose response is not the record.
- `bond`: set a `@bind` variable and report the cascade.

New tools must pass two gates: cells cannot do it, and usage logs show the need.
Never a discriminator parameter over unrelated operations (`action=...`): `edit`'s modes qualify as one tool only because they share their argument list.

## One record

Every tool response except `output` and `start` host/secret parses as the same record:
`status, waited_seconds, timestamp, cells`. `timestamp` is ISO 8601 UTC with milliseconds (`"2026-08-23T18:42:23.788Z"`) — fixed width, so lexicographic order is chronological order; `since` takes it back, and still accepts a float unix time.
`cells` lists every cell the reactive cascade touched, including clean downstream re-runs.

`code` is sent only to a session that does not already hold it. One ledger per (session, notebook) records the hash of every cell's code as delivered — by a record that carried it, or by the `edit` that supplied it — and a cell whose hash matches omits the field. That covers an edit's own cell (the caller wrote the text) and the whole execution cascade (a re-run never rewrites code). No content comparison: the stored text is the caller's own text, unaltered.

`read(cells=[...])` is the way back: naming cells asks to be told about them, so they come back whole — uncompacted, code included, ledger or not. The reference point is the agent's context, and after a compact it no longer holds what the ledger claims. A bare `read` stays compact, so polling pays nothing for code it already has.

Cells this session already saw, unchanged, compress to `name, status, unchanged_since=<timestamp>`: at record build the server hashes each cell's full pre-truncation entry (code, status, rendered body, error, logs) and compares against the last hash reported to this session. Lazy, never on events: unreported intermediate states leave no trace, because the reference point is the agent's context, not notebook history.
Unchanged certifies the rendered output; for sketched containers that is the summary, not the underlying data — value-level certainty is a probe cell (`hash(x)`).
The cascade stays fully visible either way.

`status` is one enum at both levels: `running | queued | success | error | disabled | unrun`.

| | |
|---|---|
| `running` | executing now — one cell at a time, since Pluto runs a notebook's cells in sequence in one worker |
| `queued` | in this run, waiting its turn |
| `success` / `error` | it ran; `error` also covers a graph the reactivity engine rejects (two cells defining `a`, a cycle), which never ran at all |
| `disabled` | a person switched it off, or it is downstream of one that is off — Pluto's own metadata, reported and never set |
| `unrun` | no result and no run coming: a notebook held for review, a dead worker, a cell that never ran |

`running` and `queued` are apart because "which one is this waiting on" is worth answering — Pluto's UI shows them alike and leaves you hunting for the ticking counter. Precedence at both levels, most urgent first: `error`, `running`, `queued`, `unrun`, `disabled`, `success`. Two orderings are deliberate: `queued` outranks `error`, because a cell about to re-run still carries the error from a world that no longer exists, and `disabled` outranks it for the mirror reason — nothing will revisit it.
`wait_seconds=0` returns immediately with `status=running` and cell ids; completion is observed by the next `read`.
Polling through the loop is the notification mechanism: no server push.

Each cell entry carries: identity, `status`, `code`, runtime, rendered output, structured log entries (last 20, overflow counted and spilled), error message if any.
A cell the human deleted is synthesised into the record — `change="deleted"`, `old_code` — since there is no live cell left to render it from. It is deduped like any other entry, so a deletion is news exactly once; it never lands on a targeted read, which answers only for the cells it was asked about.

## Two renderers, and one exception each

**The record is Pluto's rendering. `output` is Julia's.** Neither is this package's.

Pluto already decided how a value should be summarised for someone who cannot hold it all at once — length and eltype, a head and a tail, a table's schema and row count, a struct's fields one level down. Those are good decisions made by people who watched humans read notebooks for years, and the record piggybacks on them rather than competing. What this package adds is a line's worth of formatting and one truncation door; there is no second display protocol, and there is no "but complete" mode on a summary. A summary that grows until it is complete is not a summary.

`output` is the other question — *what is this value, exactly* — and Julia already answers it: `show(io, MIME"text/plain"(), x)` is the `display` form, and `IOContext(:limit => false)` turns off the elision the REPL adds for its own comfort. So `output` fetches the value from the worker by `cell_id` (`PlutoRunner.cell_results`, so a cell that defines no name is as readable as a global) and prints it exactly as Julia would. Not our formatting of Pluto's summary of Julia's value — Julia's own.

**The plot is the exception on both sides, and only because MIME preference is not the agent's.** Pluto stores one rendered MIME per cell and prefers SVG whenever a backend offers both; SVG is markup no MCP client can show. So the record says `mime` and stops — a picture is not describable in words, and a byte count is a number nobody can look at — and the agent asks `output` for the form it wants.

That ask is not a plot feature: `output(mime=…)` is `show(io, MIME(mime), value)`, the same dispatch a file writer gets, so a figure answers `image/png` with the picture and `image/svg+xml` with the XML. A value that cannot do the asked-for MIME answers with `shows_as`, the list of ones it can — data, not advice. There is nothing underneath that: no conversion, no fallback, no helper. `show` is the whole mechanism.

Everything else follows:
- Text: inline up to 2 KB; larger spills to a file and the payload names the path. One door, every path.
- Containers, structs, tables: Pluto's summary, one line, one level deep. Expanding is `output`, or a probe cell (`x[4090:4110]`).
- HTML — a markdown or `html"…"` cell — is `mime` alone in the record. Its rendering IS the code the agent wrote, re-encoded, and its extracted text is that same prose with the formatting removed. `output` needs no case for it either: the cell's *value* is a `Markdown.MD`, which Julia prints as text on its own.
- A cell that errored has no value to fetch, so its message comes from the structure Pluto stored. That is the only place `output` reads a rendering rather than a value.
- A value lives in the worker, so it does not outlive it. After a restart (a package install, `stop`+`open`) the record still carries Pluto's renderings, but `output` has nothing to reach until the notebook re-runs, and says so.

One rule underneath the record: **text the agent supplied never comes back**. `code` is dropped when the session already holds it, and an `output` whose text hashes into that same set of held code is dropped with it. Static markup is the case where a cell's output and its input are the same thing by construction.

## One vocabulary

- `wait_seconds` on every running tool, default 0.1; `waited_seconds` its receipt in the record. One semantics: return on completion, on new error, or on expiry, whichever comes first. Expiry shows as `status=running`. Fast cells converge within the default; `0` is fire-and-forget for batch authoring.
- `status`: `running | queued | success | error | disabled | unrun`, the only progress vocabulary. No `finished`, no `errored` booleans anywhere.
- Durations are seconds, like `wait_seconds`, and marked by tense like `wait`/`waited`: `ran_seconds` is how long a cell's last completed run took, `running_seconds` how long the one executing now has been going, `running_progress` how far along it says it is through `@progress`.
- `code` for cell text, everywhere, and always the cell's text as it is now. A human edit adds `old_code`; the change log is a snapshot and never overrides the live code.
- `cell` / `cells` for addressing cells, `notebook` for addressing notebooks: name/path, UUID, or unique prefix, resolved by one shared function.
- `timestamp` from the record round-trips into `since`. The agent copies, never computes time. The stamp is snapshot acquisition time, taken before cell state is read, assembly under the notebook lock: concurrent changes land at or after the stamp and reappear next `read`. Delivery is at-least-once; dedup makes duplicates cost one compact line. `since` is a view over the same reported-hash comparison: omit unchanged cells instead of compacting them. Never Pluto run timestamps: re-ran is not changed.

## One loop

Stated once in the server description, elaborated in the plugin skill:
edit, then check `status`: `success` proceed, `error` read the cells and fix, `running`/`queued` carry on or call `read(wait_seconds=N, since=<timestamp>)` for the same record, `unrun` means an `edit` is what starts it.
`delete_on_success` cells for anything not worth keeping.
Prefer `@info` with key-value pairs over `println`: structured entries survive truncation individually, print spam loses its middle.

## Seeing hierarchy

How the agent looks at data, cheapest first: the record's sketch, for structure; throwaway statistics cells, for numbers (an exact answer costs less than the raw data it came from); the picture, when shape is the question — `output(mime="image/png")`, billed by pixel area (~`w*h/750`), so a 600x400 plot is ~320 tokens against ~2000 for the same plot as a braille canvas; and `fit(Histogram, x, edges).weights` for a distribution, which needs no plotting package at all.

A plot is also the only way to catch what the record cannot say: a clipped axis label, or a curve that is not the shape the prose claims.

## Safety and transport

- One truncation function guards every text path into a payload: cell output, stdout blobs, logs, `output` text. Oversize spills to a per-notebook directory, swept on `stop`. The spill path is the paging API: client and server share a machine (stdio), and Claude Code greps files better than any MCP payload.
- Host logging goes to stderr (`ConsoleLogger(stderr)`): the MCP framework prints JSON-RPC on stdout, so stdout must stay untouched. Worker output is isolated by Malt's private pipes.
- All notebook mutations go through Pluto's session actions under `executetoken`, never by direct struct mutation.

## Packaging and positioning

- Julia package, MIT licensed, registry-eligible, client-agnostic MCP server underneath.
- Claude Code plugin on top: auto-configured server plus ONE skill, `pluto-workflow` — the loop, the delete_on_success pattern, record semantics, and the seeing hierarchy. One skill because a live run loaded the workflow skill and never the second one, on a task that was entirely about inspecting data it could not see: a skill nobody loads is documentation. No hooks.
- Niche: existing Julia MCP servers are REPL-shaped scratchpads (AgentREPL, MCPRepl, Kaimon). PlutoMCP is notebook-as-reviewable-artifact. The human-review channel and reproducible file are the point, not interactive evaluation.

## Design discipline

Simplicity is enforced, not preferred.
Accepted imperfections stay accepted: a failed `delete_on_success` cell reaches the file until the agent removes it; no hiding logic, because it is visible and the agent cleans it up.
Every future addition needs evidence from usage logs, not symmetry, completeness, or anticipation.
When a capability seems missing, the first question is always: is it a cell?

## Explored and rejected

A post-mortem, so these are not reopened without new evidence. Each entry names what would count as new evidence.

**Redirecting stdout to protect the transport.** `ModelContextProtocol.jl`'s `run_server_loop` writes every response with a bare `println(response)`, using the `stdout` global, so redirecting that global redirects the JSON-RPC itself and the server goes silent. Fixed at the logger instead. Reopen only if the transport stops using the global.

**A second evaluation path** (`execute`, a scratchpad, a hidden REPL). A probe that runs where the human cannot see it breaks the review model, and everything it could do a cell already does. Reopen if usage logs show probes that genuinely cannot be cells.

**A `png` tool that inserts, runs and deletes a probe cell.** It reimplemented `edit` in order to render a plot. `output(mime=…)` is the capability, and it costs no cell either.

**`AsPNG`, a wrapper that rasterised a figure via `savefig` when it could not `show` a PNG.** Measured, the case does not exist: `gr` shows PNG (so the wrapper never fired) and `plotly` — the backend the code named as its motivating example — can neither show nor `savefig` one, so the wrapper did not rescue it either. What plotly CAN do is `text/html`, which plain `showable` finds and `shows_as` reports. Reopen only for a named backend where `showable(MIME"image/png", x)` is false and its own `save`/`savefig` demonstrably produces a PNG.

**Defining helpers in the current workspace module.** Pluto builds a fresh `Main.workspace#N` on every reactive run, so anything defined in the old module is gone by the next call; the worker's `Main` is durable. Nothing is added to `workspace_preamble` any more either: cells never call into this package, so nothing needs to be visible to them.

**Detecting completion from `running`/`queued`/timestamps.** A cell that fails to PARSE never reaches either flag, so the heuristic reports it as settled when it never ran. A `Task` and `istaskdone` are the literal answer.

**Coercing bond values by type-guessing.** Parsing numeric-looking strings into numbers corrupts a text field whose content really is `7`, to fix a caller who should have sent a JSON number. The value's type is the caller's to get right, and the parameter description says so.

**Fingerprinting the truncated payload rather than the raw entry.** Two different 40 MB outputs share a head and a tail, so they would fingerprint the same and the second would never be reported.

**Including Pluto's `:objectid` in the fingerprint.** Re-running `v = ones(5)` allocates a new array and therefore a new objectid, with byte-identical output. Including it would mark every container changed on every run, defeating dedup exactly where it pays.

**Assembling a record under `nb.executetoken`.** That is Pluto's RUN lock, held for a whole reactive run, so waiting for it would make every `wait_seconds=0` call block on the run it was trying not to wait for. Stamping the timestamp first gives the ordering guarantee without the lock.

**A parse-error autofix hook.** The agent is the only writer and the server never mutates cell content on its own. A parse error is an errored cell with a message; the agent reads it and rewrites the cell. Autofix-with-diff-and-revert is a human UI feature and belongs in Pluto upstream.

**An in-notebook "ask AI" inbox, behind a fork of Pluto.** A feature that needs a fork is a feature nobody has. The terminal already carries text, and browser edits already carry code.

**An in-cell notebook-control API (`@notebook` macro or similar).** Cells run in the worker, the session API lives in the host, so this would be a second RPC control path and would make cells writers of their own notebook.

**Replicating Pluto's expand-rows protocol for containers.** The agent's expand is a cell: `x[4090:4110]`, `describe(df)`, `quantile(x, [0.01, 0.5, 0.99])`.

**A `full` parameter on `read`.** Full text for one cell is `output`'s job, and two ways to ask the same question is one too many.

**`wait_seconds` defaulting to 0.** An ordinary cell finishes in milliseconds, so every edit came back `running` and needed a second call to learn it had already succeeded. 0.1 keeps the fire-and-forget available without making it the default.

**A `cell_type` parameter, wrapping the agent's text in `md"""…"""` for it.** An `.ipynb` reflex: that format has typed cells, and Pluto does not. A Pluto cell is a Julia expression, and prose is the expression `md"""…"""` like any other. The parameter bought one convenience and cost a double-wrap guard, an exception in the code ledger, and a `$`-interpolation surprise in text the agent believed was literal. The agent writes Julia; this package does not edit it.

**A wide-layout cell written into every new notebook.** `html"""<style>main { max-width: 95vw; }</style>"""` is a guess about how a human likes to read, put into their artifact by a package that was not asked. An agent that wants a wide column writes that cell.

**A `list` tool.** It reported which notebooks were open and which was current. The agent lists files itself, `open` says which notebook it just made current, and a `notebook` ref that matches nothing answers with what IS open — the same information, at the moment it is wanted, without a tool to remember.

**An `export` tool.** A notebook rendered as `text/html` is Pluto's export and as `text/plain` is its `.jl` source, so `output` with no `cell` covers it. A separate tool was a second way to ask one question.

**Staging (`run=false`), so several edits can be made before any of them runs.** It needs a state Pluto does not have — code written but not run — and therefore a fifth status word, invalidation of every result downstream, and a way to say "no result, and none coming". Pluto's own server has no such state because the unsent text lives in the browser.

**A batch `edits` parameter, applying several edits in one reactive run.** The case is real and structural: with `A → C ← B`, both parents changing, whichever edit goes first re-runs C against a half-updated world, and no ordering avoids it. It is still a corner: one wasted run of C, against a nested parameter on the 95% of calls that edit one cell. A live run made 56 edits, every one of them single. Reopen if a usage log shows the wasted runs actually costing something.

**Cell names as identity.** Names are addressing convenience, taken from Pluto's reactivity graph; the UUID is the identity and is always accepted. A cell that stops parsing loses its name, and an identity that disappears when the code breaks is not an identity.

**`uuid1` for new cells,** which is `Pluto.Cell`'s own default. It is time-based, so cells created in one tick share a long leading run of digits and a short prefix identifies nothing. `uuid4` keeps prefixes discriminating.
