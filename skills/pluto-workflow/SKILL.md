---
name: pluto-workflow
description: How to drive a Pluto notebook through the pluto MCP server — the edit/status loop, throwaway probe cells, what the one result record means, how a human's own edits reach you, and how to look at data you cannot see. Use when authoring, editing, debugging or inspecting a Julia Pluto notebook via the pluto tools.
---

# Working in a Pluto notebook

The notebook is shared, live, in both directions: a human is watching it in a browser and can type into it themselves at any moment. Your `edit` calls and their typing are two different channels into the same notebook. You are the only *programmatic* writer — nothing here runs a cell on its own, and cells are pure computation that never control the notebook they live in — but you are not the only one changing it. A human edit is not an interruption to route around; it is a message, and it reaches you as `old_code` in the next `read` (see "How to read what a human changed," below).

The notebook is also the deliverable: what a person sees at the end is what you leave behind, so it should read as a finished piece of work, not a transcript of how you got there.

## Give them the link, early

`open` returns a URL. Write the first cell — a title and a sentence on what you are about to do — then hand the URL over immediately, as a clickable link or button if your tools have one. Someone watching from the second cell can stop you at the third; someone shown the link at the end can only review.

## The loop, in short

```
open  →  edit  →  check status  →  edit  →  …
```

Every tool that runs or waits returns the same record, and `edit`'s and `read`'s own descriptions already cover the status enum and how `wait_seconds` behaves — that is not repeated here. Two things worth adding: `running_seconds`/`running_progress` (from `@progress`) say how far into a running cell you are, and a queued cell's `ran_seconds` is what it took *last* time, which is what tells you whether waiting for it now is worth it. None of this waits for the cell to finish — `read` reports whatever logs and progress have accumulated *so far* on a still-running cell, the same live state the browser shows, not a final snapshot.

A first `using Plots` takes minutes to install and compile — blocking on it buys nothing. Write the cells that come next; the result arrives in the next record, or in `read(since=...)` when you want it.

## How to free yourself from a long run

`read(wait_seconds=N)` blocks your own turn for up to `N` seconds, with no MCP-level way around that — which is why the default is small and `0` exists for fire-and-forget. If you want to fire a batch of edits and then genuinely do something else — another tool, another notebook, plain reasoning — while a long cell runs, don't raise `N` to sit through it instead. Run `bin/pluto_wait.sh <notebook-id> [timeout-seconds]` in the background (POSIX only — macOS, Linux; on Windows, fall back to the short-`wait_seconds` loop). `<notebook-id>` is the `id=` query parameter in the URL `open` returned.

```
Bash(command="bin/pluto_wait.sh <notebook-id> 300", run_in_background=true)
```

It shows up in your background task list and notifies you when it returns, the same as any other long `Bash` job — keep working in the meantime. Exit 0 means something changed; anything else (timeout, or a real problem) means no signal arrived, so decide for yourself whether to wait again or move on. Either way it's a **nudge, not an answer**: always follow it with a real `read(since=<your last timestamp>)` — a wake can fire immediately if changes piled up while nobody was listening, which is harmless, just re-issue the wait if `read` shows nothing new yet. If you give up on it, just kill the background job: the script holds no lock and needs no cleanup.

## How to interrupt a running cell

Two different situations look similar but call for different tools:

- **You already know what should run instead.** Just `edit` the cell with the new code. This is always safe, even while the old run is still going — Pluto interrupts the stale run on its own and the record you get back reflects only the new code, never a leftover value from the run you abandoned. The same is true for deleting a busy cell (`code=""`). Neither needs a `stop` first.
- **You want to abandon a run and have no replacement ready yet** — it's taking too long, or you need to think before deciding what goes there instead. That's `stop(notebook=..., cell=...)`: the same thing the browser's stop button does, for a cell that cannot interrupt itself.

Interrupting is not instant or free. Julia has to reach a safepoint to notice it, which can take several seconds, and if the running code never yields (rare, but possible), Pluto escalates to killing the worker process outright — every value in the notebook is gone, the interrupted cell reports the failure as an `error`, and the very next `edit` transparently starts a fresh worker and reruns the whole notebook. You don't have to do anything special to trigger that recovery; it happens as part of the ordinary loop.

## How Pluto's reactivity changes the way you edit

Pluto runs cells in **dependency order**, not top to bottom, and allows **one definition of a global per cell**.

- Editing one cell re-runs whatever depends on it. The record lists the whole cascade, including cells that re-ran cleanly — that is the interesting part.
- Prefer `x = let ... end` over `begin ... end` for a multi-step computation: `let` defines exactly one name, so it creates one dependency edge instead of several.
- A cell is Julia, always. Prose is a cell whose expression is `md"""…"""` — there are no cell types. Watch the `$`: it interpolates inside `md"""…"""` as in any Julia string, so a literal dollar is `\$`.
- Dependencies install themselves — Pluto resolves `using X` into an environment scoped to the notebook and records the versions in the file. No `Pkg.add`, no restart.
- `edit` saves and runs, and that is the only way anything runs. To recompute a cell whose *non-reactive* input changed — a file on disk that has been rewritten, an RNG, an environment variable — send its text again, unchanged; Pluto runs whatever cell it is handed.
- If a notebook comes back from `open` with `awaiting_permission`, Pluto considers the file risky and will run nothing until someone has looked at it. You are the someone: `read` it, then edit any cell — rewriting it to exactly what it already says is enough — and the whole notebook runs. The same happens after a worker dies: one cell cannot run against an empty workspace, so an edit re-runs everything.
- For anything a person is meant to vary, do not re-run: use `@bind`. A bound variable makes the dependency reactive, so the value has a widget in the browser and `bond` sets it from here. `x = rand()` re-run by hand is a parameter you have hidden from the human reading the notebook.

## How to position cells for a human reader

Pluto runs cells by dependency, so nothing stops a cell using a name a LATER cell defines — the reactive engine does not care which one sits higher on the page, and Pluto's own docs put it plainly: "you can place cells in the order that makes the most sense for your story, which is not always the order that makes the most sense for the computer." That is not license to hoist everything important to the top, though: Pluto's own UI lets a reader jump straight from a name to its defining cell, the way an IDE jumps to a definition, so a helper sitting below the logic that calls it is not the readability tax it would be without that feature. A typical good notebook still zig-zags — title, then imports and helpers, then a chapter of logic, plots as the payoff at the end — because that is the order the argument was actually built in. Pluto's own worked example of reordering for narrative reasons is exactly this shape: pushing an "Appendix" to the end, not hoisting a headline to the top.

`edit`'s `after`/`before` (see its own description for the exact rules) place a cell where a human reads it; `cell` is still which cell you are writing to. Reach for them for LOCAL adjacency — fixing a cell that landed in the wrong spot — not for imposing importance-order on the whole notebook:

- **A `@bind` widget goes immediately before what it drives.** Unlike a function, there is no jump-to-definition from a widget's effect back to the widget — a slider forty cells from its plot is something the reader has to hunt for, where one directly above the plot is self-explanatory.
- **A markdown cell reads as the header of the code it introduces**, so put it immediately before that cell — `edit(code="md\"\"\"## Fit quality\"\"\"", after="load_data")`, then the code cell `after` that markdown cell. Pluto renders it like a section heading, and it moves with the code it belongs to if you ever reposition that code later.

Pluto's own presentation mode (Share → Slideshow) reads its structure the same way, from nothing but markdown headers in display order — no separate slide metadata, so `after`/`before` genuinely shape it, not just how the notebook reads in a browser. `#` starts a title slide, `##` starts a regular slide, `###` and deeper stay inside whichever slide is already open. Use `#`/`##` for a heading that should also work as a slide break; keep `###`+ for finer structure within one slide. Moving a cell across a `#`/`##` boundary moves it to a different slide, not just a different scroll position — worth knowing before repositioning a notebook that might get presented.

## How to run a throwaway probe

**Every capability question has the same answer: write a cell.** Probing a value, reading a docstring, computing a statistic, expanding a container — all cells. (Looking at a plot is the one exception: `output(cell=..., mime="image/png")` renders the figure and returns the picture.) There is no second evaluation path, and that is deliberate: a probe that runs somewhere invisible is a probe the human reviewing your work cannot see.

Use `delete_on_success=true` on an insert — see `edit`'s own description for exactly when the delete fires:

```
edit(code="@doc bootstrap_ci", delete_on_success=true, wait_seconds=15)
edit(code="quantile(residuals, [0.01, 0.5, 0.99])", delete_on_success=true, wait_seconds=15)
edit(code="describe(df)", delete_on_success=true, wait_seconds=15)
```

A probe that errors stays put for you to read, and cleaning it up afterwards is your job, not the server's. With `wait_seconds=0` the flag can never fire, so give a throwaway probe a real one.

## How to log from a cell

Prefer `@info` with key-value pairs over `println`:

```julia
@info "fit converged" iterations=n residual=r
```

Log entries are captured individually and the last 20 survive in the record, each one whole. `println` output is one blob that gets truncated in the middle, so a long print loop loses exactly the part you wanted.

## How to look at data you cannot see

Everything you learn about a value arrives as text you paid for. Cheapest first, and stop as soon as the question is answered.

1. **The sketch you already have.** `Vector{Float64}, ≥30 elements: [0.12, …]` answers what shape, what type, what magnitude, for free. `≥` means Pluto truncated.
2. **Statistics, not values.** An exact answer costs less than the data it came from: `extrema`, `quantile`, `count(isnan, x)`, `describe(df)`, `combine(groupby(df, :region), nrow)`. Never dump an array to find its maximum.
3. **The picture, when shape is the question.** `output(cell=…, mime="image/png")`. Vision is billed by pixel area (~`w*h/750`): a 600×400 plot is ~320 tokens, where the same plot as a braille canvas is ~2000. A picture is cheaper than a text plot, and it is the only way to catch a clipped label or a curve that is not the shape you claimed in your prose.
4. **Counts, for a distribution.** `fit(Histogram, x, edges).weights` needs no plotting package, and the counts are where the finding is: a trough between two humps is a second population, not a tail — a tail decays monotonically.

Do not print an array to inspect it, do not ask for a plot when a number answers the question, and do not install a plotting package to look at a shape: the dependency outlives the probe cell, in somebody else's notebook file.

## How to read the record

Each cell entry carries `name` (the global it defines — that is also how you address it), `cell_id`, `status`, the rendered output, log entries, and an `error` message if it failed. Address a cell by that name, by its `cell_id`, or by any unambiguous prefix of one — `"0dfbd0b6"` is normally plenty, since ids are random. Cells that define nothing (prose, a plot, a bare `let`) have no name and the id is how you reach them.

**`code` is left out on purpose, and it is not missing.** `read`'s own description covers when it comes back; in practice, naming a cell is how you ask to be told about it — `read(cells=["total", "abl"])` answers whole, code included, which is the way back after a compact or for a cell you never wrote.

A cell you have already been shown, unchanged, comes back compacted instead of omitted:

```
{"name": "total", "status": "success", "unchanged_since": "2026-08-23T18:42:23.788Z"}
```

Same cell, not a different one — nothing is hidden, every cell the cascade touched is still listed, so an edit's blast radius is visible at a glance. `since` drops them entirely if you want only what changed. `unchanged_since` certifies the *rendered* output, not the underlying data: for a container that is the one-line sketch, and two arrays with the same sketch can differ deeper in. A probe cell settles it — `hash(x)`, `extrema(x)`.

**The record is Pluto's rendering; `output` is Julia's.** The record summarises a value the way Pluto does in the browser: one line, one level deep. Nested fields show as `…`, and a plot or a markdown cell is `mime` and nothing else — a picture is not describable in words, and your own prose is not news to you. `output` gives you the thing itself, as Julia prints it — see its own description for the full contract, but as a cheat sheet:

```
output(cell="robust", mime="text/plain")        the value, complete, nothing elided
output(cell="fig", mime="image/png")            the picture
output(cell="fig", mime="image/svg+xml")        the XML instead
output(mime="text/html", path="report.html")    the whole notebook, to a file
output(mime="text/plain")                       the notebook's .jl source
```

A cell that defines no name — a `let` block, a plot — works the same way: `output` addresses it by `cell_id`.

## How to read what a human changed

- `read(since=<timestamp>)` reports what a **human** edited in the browser, with `old_code` beside the current `code` — that is the review channel, and your own edits never appear there.
- **Reactivity is syntactic, so mutation is invisible to it.** Pluto builds the graph from what a cell *assigns*, not from what it changes: `push!(v, x)` reads `v`, so nothing downstream of `v` re-runs and nothing in `dependencies` shows the link. A notebook that mutates looks reactive and is not. Build the new value instead — `v2 = [v; x]` — and let the graph carry it.
- `read(dependencies=true)` gives each cell's `uses` and `used_by` — the cells it reads from and the cells that read it, one hop each way. Every name in them is a reference you can send back as `cell=`.
- Text over 2 KB spills to a file and the payload names the path — read or grep it if you have filesystem tools, or narrow the value in a probe cell.

## Finishing

Name the file after the experiment when the work is meant to be kept — `open(path="throughput-vs-batch-size.jl", create=true)`. A pathless `create` is a scratch notebook in a temp directory.

`output(mime="text/html", path="…")` writes the notebook as HTML — code, outputs and state embedded, opening in any browser with no Pluto server running. The Pluto frontend loads from a CDN, so it is not an offline file. Commit the `.jl` and the `.html` together: that pair is the provenance record, and every figure in it traces back to a cell.

`stop` when you are done, so the server and its worker processes go away.
