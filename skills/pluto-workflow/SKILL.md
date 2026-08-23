---
name: pluto-workflow
description: How to drive a Pluto notebook through the pluto MCP server — the edit/status loop, throwaway probe cells, what the one result record means, and how to look at data you cannot see. Use when authoring, editing, debugging or inspecting a Julia Pluto notebook via the pluto tools.
---

# Working in a Pluto notebook

The notebook is the deliverable. A human is watching it in a browser, and what
they see at the end is what you leave behind — so the notebook should read as a
finished piece of work, not as a transcript of how you got there.

You are the only programmatic writer. Cells are pure computation: they never
control the notebook they live in.

## The loop

```
open  →  edit  →  check status  →  edit  →  …
```

Every tool that runs or waits returns the same record:

```
status, waited_seconds, timestamp, cells
```

`status` is one of `pending | calculating | success | error`

- **`calculating`** — the run is still going. Call
  `read(wait_seconds=N, since=<the record's timestamp>)` and you get the same
  record back, narrowed to what changed. It's safe to request using timestamps from previously returned results.

`wait_seconds` defaults to 0.1 so the common case comes back complete in one
call. **Do not raise it to sit through slow work.** A first `using Plots` takes
minutes to install and compile; blocking on it buys nothing. `calculating` is
not an error and nothing was cancelled — the cell runs on, the human's browser
shows it running, and you are free to write the cells that come next. The
result arrives in the next record, or in `read(since=…)` when you want it.
Pass `0` to fire and forget, which is how you author a run of cells before
reading any of them.

## Reactivity changes how you edit

Pluto runs cells in **dependency order**, not top to bottom, and allows **one definition of a global per cell**.

- Editing one cell re-runs other cells which depend on it. The record lists the whole
  cascade, including cells that re-ran cleanly — that is the interesting part.
- Prefer `x = let ... end` over `begin ... end` for a multi-step computation:
  `let` defines exactly one name, so it creates one dependency edge instead of
  several.
- A cell is Julia, always. Prose is a cell whose expression is
  `md"""…"""` — there are no cell types. Watch the `$`: it interpolates inside
  `md"""…"""` as in any Julia string, so a literal dollar is `\$`.
- Dependencies install themselves. Write `using DataFrames` in a cell; Pluto
  resolves it into an environment scoped to this notebook and records the
  versions inside the notebook file. No `Pkg.add`, no restart.
- `edit` saves and runs. `run` is the backup path, for cells whose *non-reactive*
  inputs changed — a file on disk, an RNG, an environment variable.

## Throwaway cells

**Every capability question has the same answer: write a cell.** Probing a
value, reading a docstring, computing a statistic, expanding a container — all
cells. (Looking at a plot is the one exception: `output(cell=..., mime="image/png")`
renders the figure and returns the picture.) There is no second evaluation path, and
that is deliberate: a probe that runs somewhere invisible is a probe the human
reviewing your work cannot see.

Use `delete_on_success=true` on an insert:

```
edit(mode="insert", code="@doc bootstrap_ci", delete_on_success=true, wait_seconds=15)
edit(mode="insert", code="quantile(residuals, [0.01, 0.5, 0.99])", delete_on_success=true, wait_seconds=15)
edit(mode="insert", code="describe(df)", delete_on_success=true, wait_seconds=15)
```

Deleted only if `status` is `success` when the call returns — so a probe that
errors stays put for you to read, and cleaning it up afterwards is your job,
not the server's. With `wait_seconds=0` the flag can never fire, so give a
throwaway probe a real one.

## Logging from a cell

Prefer `@info` with key-value pairs over `println`:

```julia
@info "fit converged" iterations=n residual=r
```

Log entries are captured individually and the last 20 survive in the record,
each one whole. `println` output is one blob that gets truncated in the middle,
so a long print loop loses exactly the part you wanted.

## Looking at data you cannot see

Everything you learn about a value arrives as text you paid for. Cheapest
first, and stop as soon as the question is answered.

1. **The sketch you already have.** `Vector{Float64}, ≥30 elements: [0.12, …]`
   answers what shape, what type, what magnitude, for free. `≥` means Pluto
   truncated.
2. **Statistics, not values.** An exact answer costs less than the data it came
   from: `extrema`, `quantile`, `count(isnan, x)`, `describe(df)`,
   `combine(groupby(df, :region), nrow)`. Never dump an array to find its
   maximum.
3. **The picture, when shape is the question.** `output(cell=…,
   mime="image/png")`. Vision is billed by pixel area (~`w*h/750`): a 600×400
   plot is ~320 tokens, where the same plot as a braille canvas is ~2000. A
   picture is cheaper than a text plot, and it is the only way to catch a
   clipped label or a curve that is not the shape you claimed in your prose.
4. **Counts, for a distribution.** `fit(Histogram, x, edges).weights` needs no
   plotting package, and the counts are where the finding is: a trough between
   two humps is a second population, not a tail — a tail decays monotonically.

Do not print an array to inspect it, do not ask for a plot when a number
answers the question, and do not install a plotting package to look at a shape:
the dependency outlives the probe cell, in somebody else's notebook file.

## Reading the record

Each cell entry carries `name` (the global it defines — that is also how you
address it), `cell_id`, `status`, the rendered output, log entries, and an
`error` message if it failed.

Address a cell by that name, by its `cell_id`, or by any unambiguous prefix of
one — `"0dfbd0b6"` is normally plenty, since ids are random. Cells that define
nothing (prose, a plot, a bare `let`) have no name and the id is how you reach
them.

**Two things are left out on purpose, and neither is missing.**

`code` you already hold. The cell you just wrote comes back without it, and so
does one that merely re-ran — a cascade never rewrites code. When you need
source back, after a compact or for a cell you never wrote, name it:
`read(cells=["total", "abl"])` answers whole. Naming a cell IS asking to be
told about it; a bare `read` stays compact.

A cell you have already been shown, unchanged, comes back as three fields:

```
{"name": "total", "status": "success", "unchanged_since": "2026-08-23T18:42:23.788Z"}
```

Same cell, not a different one. Nothing is hidden — every cell the cascade
touched is still listed, so an edit's blast radius is visible at a glance.
`since` drops them entirely if you want only what changed.

`unchanged_since` certifies the *rendered* output. For a container that is the
one-line sketch, not the underlying values: two arrays with the same sketch can
differ deeper in. A probe cell settles it — `hash(x)`, `extrema(x)`.

## The record is Pluto's rendering; `output` is Julia's

The record summarises a value the way Pluto does in the browser: one line, one
level deep, `Vector{Float64}, ≥30 elements: [0.12, …]`. Nested fields show as
`…`, and a plot or a markdown cell is `mime` and nothing else — a picture is
not describable in words, and your own prose is not news to you.

`output` gives you the thing itself, as Julia prints it, and `mime` says which
form you want:

```
output(cell="robust", mime="text/plain")        the value, complete, nothing elided
output(cell="fig", mime="image/png")            the picture
output(cell="fig", mime="image/svg+xml")        the XML instead
output(mime="text/html", path="report.html")    the whole notebook, to a file
output(mime="text/plain")                       the notebook's .jl source
```

Ask for a MIME the value cannot do and the answer lists what it can. `path`
writes to that file at any size; without it, anything too big to carry spills
to a temp file and you get the path. A cell that defines no name — a `let`
block, a plot — works the same way: `output` addresses by `cell_id`.

## Also in the record

- `read(tree=true)` gives each cell's `references` and its `upstream` /
  `downstream` cells: what breaks if this changes.
- `read(since=<timestamp>)` reports what a **human** edited in the browser,
  with `old_code` beside the current `code`. That is the review channel; your
  own edits never appear there.
- Text over 2 KB spills to a file and the payload names the path — read or grep
  it if you have filesystem tools, or narrow the value in a probe cell.

## Finishing

Name the file after the experiment when the work is meant to be kept —
`open(path="throughput-vs-batch-size.jl", create=true)`. A pathless
`create` is a scratch notebook in a temp directory.

`output(mime="text/html", path="…")` writes the notebook as HTML — code,
outputs and state embedded, opening in any browser with no Pluto server running.
The Pluto frontend loads from a CDN, so it is not an offline file. Commit the
`.jl` and the `.html` together: that pair is the provenance record, and every
figure in it traces back to a cell.

`stop` when you are done, so the server and its worker processes go away.
