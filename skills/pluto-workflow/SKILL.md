---
name: pluto-workflow
description: How to drive a Pluto notebook through the pluto MCP server — the edit/status loop, throwaway probe cells, and what the one result record means. Use when authoring, editing or debugging a Julia Pluto notebook via the pluto tools.
---

# Working in a Pluto notebook

The notebook is the deliverable. A human is watching it in a browser, and what
they see at the end is what you leave behind — so the notebook should read as a
finished piece of work, not as a transcript of how you got there.

You are the only programmatic writer. Cells are pure computation: they never
control the notebook they live in.

## The loop

```
open  →  edit  →  check status  →  edit  →  …  →  export
```

Every tool that runs or waits returns the same record:

```
status, waited_seconds, timestamp, cells
```

`status` is one of `pending | calculating | success | error`, and it means the
same thing on a cell as on the record:

- **`success`** — go on.
- **`error`** — read the failed cell's `error` message and rewrite the cell.
  Nothing to roll back: an errored cell with a message *is* the validation
  result, and Pluto's reactive engine is the validator.
- **`calculating`** — the run is still going. Call
  `read(wait_seconds=N, since=<the record's timestamp>)` and you get the same
  record back, narrowed to what changed. Timestamps are ISO 8601 UTC strings
  (`"2026-08-23T18:42:23.788Z"`) — never compute one yourself; copy the one you
  were given.

`wait_seconds` defaults to 0.1, which is enough for an ordinary cell, so the
common case comes back complete in one call. Raise it for work you expect to be
slow — `wait_seconds=60` for a first `using SomePackage` (Pluto installs it) or
a long computation. Pass `0` to fire and forget, which is how you author a run
of cells before reading any of them.

## Reactivity changes how you edit

Pluto runs cells in **dependency order**, not top to bottom, and allows **one
definition of a global per cell**.

- Editing one cell re-runs everything downstream. The record lists the whole
  cascade, including cells that re-ran cleanly — that is the interesting part.
- Prefer `x = let ... end` over `begin ... end` for a multi-step computation:
  `let` defines exactly one name, so it creates one dependency edge instead of
  several.
- Dependencies install themselves. Write `using DataFrames` in a cell; Pluto
  resolves it into an environment scoped to this notebook and records the
  versions inside the notebook file. No `Pkg.add`, no restart.
- `edit` saves and runs. `run` is the backup path, for cells whose *non-reactive*
  inputs changed — a file on disk, an RNG, an environment variable. The
  from-scratch reproducibility check is `stop` then `open`, not `run`.

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

The cell runs normally and is visible in the browser while it does. If its
status is `success` when the call returns, it is deleted again and you keep the
answer. If it **errors**, or if `wait_seconds` expired before the result was
in, the cell stays — read it, then remove it yourself:

```
edit(mode="delete", cell="<the cell_id from the record>")
```

That cleanup is your job, not the server's. A cell that vanished mid-error
would be a worse surprise than one you delete on purpose. With
`wait_seconds=0` the flag can never fire, so always give a throwaway probe a
real `wait_seconds`.

## Logging from a cell

Prefer `@info` with key-value pairs over `println`:

```julia
@info "fit converged" iterations=n residual=r
```

Log entries are captured individually and the last 20 survive in the record,
each one whole. `println` output is one blob that gets truncated in the middle,
so a long print loop loses exactly the part you wanted.

## Reading the record

Each cell entry carries `name` (the global it defines — that is also how you
address it), `cell_id`, `status`, `code`, the rendered output, log entries, and
an `error` message if it failed.

`code` is only sent when you do not already have it. The cell you just wrote
comes back without it — you supplied that text — and so does a cell that merely
re-ran, because an execution cascade never rewrites code. Everything else is
there: status, output, logs, errors.

When you need the source back — after a compact, or for a cell you never
wrote — name it: `read(cells=["total", "abl"])` answers with those cells whole,
code included. Naming a cell IS asking to be told about it; a bare `read` stays
compact.

A cell you have already been shown, unchanged, comes back short:

```
{"name": "total", "status": "success", "unchanged_since": "2026-08-23T18:42:23.788Z"}
```

That is the same cell, not a different one — you already have its code and its
output further up. Nothing is hidden: every cell the cascade touched is still
listed, so you can see the blast radius of an edit at a glance. If you want the
full text of one again, call `output(cell=..., mime="text/plain")`; if you want
only what actually changed, pass `since`.

`unchanged_since` certifies the *rendered* output. For a container that is the
one-line sketch, not the underlying values: two arrays with the same sketch can
differ deeper in. When that matters, a probe cell answers it — `hash(x)`,
`extrema(x)`, `sum(x)`.

**The record is Pluto's rendering; `output` is Julia's.** The record summarises
a value the way Pluto summarises it in the browser — one line, one level deep,
`Vector{Float64}, ≥30 elements: [0.12, …]`. `output` gives you the value as
Julia itself prints it, with nothing elided, fetched from the worker:

```
output(cell="robust", mime="text/plain")     the value, complete
output(cell="residual_fit", mime="image/png") the picture
```

`mime` is required, and those are the two. A nested field the record showed as
`…` is there in full; so is every element of a long array. If it is too big to
carry it spills to a file and you get the path.
- **A markdown cell's output never comes back**, and neither does a plot's or a
  widget's: the entry is `mime` and nothing else. Your markdown renders to the
  prose you just wrote, so there is nothing in it you do not have. A `success`
  status is the confirmation that it rendered.
- If a markdown cell interpolates a value — `md"the mean is $(m)"` — it will
  re-report whenever that value changes, because the rendered output changed.
  `output(cell=..., mime="text/plain")` shows you what it says: the cell's value
  is a `Markdown.MD`, and Julia prints that as text.
- A cell that defines no name — a `let` block, a plot — is reachable too:
  `output` works by `cell_id`, which every cell has.
- Text over 2 KB spills to a file and the payload names the path. Read or grep
  that file directly if you have filesystem tools; if you do not, a probe cell
  that narrows the value (`x[1:20]`, `describe(x)`) is the way in.
- `read(tree=true)` gives each cell's `references` and its `upstream` /
  `downstream` cells: what breaks if this changes.
- `read(since=<timestamp>)` reports what a **human** edited in the browser,
  with `old_code` beside the cell's current `code`. That is the review channel. Your own edits
  never appear there.

## Finishing

Name the file after the experiment when the work is meant to be kept —
`open(path="throughput-vs-batch-size.jl", create=true)`. A pathless
`create` is a scratch notebook in a temp directory.

`export` writes a self-contained HTML file with code and outputs embedded.
Commit the `.jl` and the `.html` together: that pair is the provenance record,
and every figure in it traces back to a cell in a notebook that reruns from
scratch.

`stop` when you are done, so the server and its worker processes go away.
