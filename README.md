# PlutoMCP

A thin wrapper that makes [Pluto.jl](https://plutojl.org) available to Claude
over MCP — so an assistant can author, edit and run a notebook you are watching
in your own browser, instead of handing you code to paste in.

## How it works

Pluto runs **inside** the MCP server process and is called directly. No
websocket, no protocol, no mirrored copy of the notebook: the `Notebook` object
these tools read is the one the Pluto server mutates.

Three consequences, and they are the whole design:

- **Reads are always current** — including edits a human just made in the
  browser, because their patches land on the same object.
- **Edits appear instantly in an open tab.** `Pluto.update_save_run!` calls
  Pluto's own `send_notebook_changes!`, which diffs against each client's
  snapshot and pushes patches. Pluto is already an MVC; this adds no second one.
- **Runs report honestly.** Every call says `status: pending | calculating |
  success | error`, and `calculating` means exactly that — not a timeout, not a
  failure. Nothing blocks on a slow cell unless you ask it to.

Pluto's reactive dependency graph is used rather than guessed at: cells are
named for what they define, and nothing here parses Julia source.

## Why Pluto rather than `.ipynb`

Most of what makes Pluto pleasant for a person turns out to matter *more* for an
assistant, because an assistant cannot see the screen.

**There is no hidden state to reason about.** A Jupyter kernel's state is the
history of every cell anyone ran, in whatever order they ran it. A variable can
outlive the cell that defined it; running top to bottom may not reproduce what
you are looking at. An agent editing such a notebook is guessing about state it
cannot observe. In Pluto the notebook *is* the state: edit a cell and everything
depending on it re-runs. There is no execution order to remember, so `edit` is
the whole operation — you never have to work out what else to re-run.

**The dependency graph is queryable, not inferred.** Pluto computes which cell
defines which global and what each cell depends on, and exposes it. "What breaks
if I change this?" has an exact answer instead of a grep. That graph is also
where cell *names* come from — `abl = read_curve(...)` is the cell named `abl`.
An `.ipynb` cell has no comparable identity: nbformat 4.5 ids are opaque, and
position changes as soon as anyone inserts a cell.

**One definition per cell is enforced**, which is what makes those names unique
and stable. It is a real constraint, not free.

**The file is code.** A Pluto notebook is a valid `.jl` file — it parses as
Julia and runs as a script. An `.ipynb` is JSON with outputs embedded, so diffs
are noisy, merges are painful, and re-running a notebook rewrites the file even
when nothing changed.

**Dependencies install themselves, and the notebook carries them.** Write
`using Plots` in a cell and Pluto installs it, into an environment scoped to
that notebook, and records the resolved versions *inside the notebook file*
(`PLUTO_PROJECT_TOML_CONTENTS` / `PLUTO_MANIFEST_TOML_CONTENTS`). One `.jl` file
is the code, the outputs' provenance, and a pinned, reproducible environment.

For an assistant this deletes an entire category of work and of failure. There
is no `Pkg.add` step, no environment to activate, no kernel to restart after
installing something, and no way to leave the notebook working on this machine
because of a package the next person does not have. You write the `using` line
and it is true. Compare the `.ipynb` equivalent: shell out to a package manager,
hope it targeted the same environment the kernel is using, restart, re-run —
each step something an agent can get subtly wrong and not notice.

**A person can watch.** The server pushes state to every connected client, so an
assistant's edits appear in a browser tab as they happen, and the human's edits
come straight back. That two-way loop is the point of this package, and it is
the default in Pluto rather than something to configure.

**When `.ipynb` is still the right answer:** the work is already in one; it is
not Julia; you need GitHub to render it, or the wider ecosystem of viewers and
converters; or the workflow genuinely wants to redefine a global in several
places, which Pluto forbids by design.

## Setup

Julia 1.10 or newer, and the package's own dependencies:

```sh
git clone https://github.com/kosiakk/PlutoMCP.git ~/Documents/PlutoMCP
cd ~/Documents/PlutoMCP && julia --project=. -e 'import Pkg; Pkg.instantiate()'
```

Then, as a Claude Code plugin — the repo is its own single-plugin marketplace,
so it is two commands:

```sh
claude plugin marketplace add kosiakk/PlutoMCP
```

```sh
claude plugin install pluto@plutomcp
```

Point the marketplace at your clone instead (`claude plugin marketplace add
~/Documents/PlutoMCP`) if you want the installed plugin to track your working
copy. Restart Claude Code afterwards; `claude plugin details pluto@plutomcp`
should list two skills and one MCP server.

Or register just the server, with no plugin:

```sh
claude mcp add pluto -- julia --project=$HOME/Documents/PlutoMCP $HOME/Documents/PlutoMCP/bin/pluto_mcp_server.jl
```

The plugin adds two skills — `pluto-workflow` (the loop, throwaway probe cells,
what the record means) and `pluto-seeing` (how to look at data without wasting
context). The MCP server itself stays standalone and client-agnostic; the
plugin is packaging, not a dependency.

## Tools

Ten. Every capability question has the same answer — *the agent writes a cell* —
so tools exist only where cells cannot reach: lifecycle, the result record, raw
bytes, and human-edit history.

| tool | what it does |
|---|---|
| `start` | start a Pluto server in-process |
| `open` | get a notebook: open a `.jl` file, or `create=true` for a new one |
| `list` | every notebook this session has open, and which is current |
| `edit` | insert / replace / delete a cell, save, and run it |
| `run` | recompute cells whose non-reactive inputs changed |
| `read` | cells as they are now: snapshot, dependency tree, wait, changes-since |
| `output` | one cell's output, complete |
| `bond` | set an `@bind`-ed variable's value, like moving its widget |
| `export` | self-contained HTML with code and outputs embedded |
| `stop` | stop the session, one notebook, or one running cell |

Probing a value and reading a docstring are cells (`edit` with
`delete_on_success=true`); dependencies are `read(tree=true)`; waiting is
`read(wait_seconds=N)`; a picture is `PlutoMCP.AsPNG(fig)` in a cell, using a
helper injected into every workspace. None of those is a tool, and SPEC.md
records why.

## One record

Every response except `output`'s bytes, `start`'s host/secret and `list`'s
paths parses as the same record:

```json
{"status": "success", "waited_seconds": 0.4, "timestamp": "2026-08-23T18:42:23.788Z",
 "cells": [{"name": "total", "cell_id": "…", "status": "success",
            "code": "total = a * b", "mime": "text/plain", "output": "42"}]}
```

`status` is one enum — `pending | calculating | success | error` — on cells and
on the record alike. `cells` covers everything the reactive cascade touched,
including cells that re-ran cleanly.

A cell this session has already been shown, unchanged, comes back as
`{"name": "total", "status": "success", "unchanged_since": "2026-08-23T18:42:23.788Z"}` —
compressed, not hidden, so the cascade stays countable while a long re-run
costs a few bytes instead of a few kilobytes. `read(since=<timestamp>)` drops
those cells entirely and gives a pure delta.

`unchanged_since` certifies the *rendered* output. For a container that is the
one-line sketch, not the underlying values — a probe cell (`hash(x)`) is how
you get value-level certainty, and that is deliberate rather than missing.

## Cells have names

A cell is addressed by a **name**, a UUID, or an unambiguous UUID prefix.

The name is whatever the cell defines, taken from Pluto's reactivity graph — so
`abl = read_curve(...)` is the cell named `abl`, and Pluto's
one-definition-per-cell rule keeps names unique. Cells that define nothing
(markdown, plots, bare `let` blocks) are addressed by UUID.

Two rules hold this together:

- **Every cell is always addressable by its UUID.** A name is a convenience for
  the cells that have one, never a replacement.
- **Ask Pluto; never parse cell source.** Pluto owns the reactivity graph and
  exposes every declaration and dependency. A wrong name is worse than an honest
  UUID.

## Long-running cells

Everything that runs takes `wait_seconds` (default 0.1, and `0` to fire and
forget). The call returns on
completion, on a new error, or on expiry — whichever comes first. Expiry shows
as `status: "calculating"`, which is neither an error nor a timeout: the cell is
still going, the browser already shows it running, and

```
read(wait_seconds=30, since=<the timestamp from the record>)
```

is the follow-up — one call, not a poll loop, returning the same record.

## The two channels

There are exactly two channels between you and the human: terminal text, and
notebook edits in either direction. `read(since=…)` is the second channel's read
side — it reports which cells a human changed since you last looked, with
`old_code` and `new_code`, so you can answer by editing back.

There is deliberately no third channel. An in-notebook "ask AI" inbox would
need a fork of Pluto, and a feature that needs a fork is a feature nobody has —
see SPEC.md's rejected list.

## Concurrent editing is the point

The notebook is open in a browser and may be open to other sessions. A person
can rewrite, reorder or delete any cell at any moment, including between two
tool calls.

So a cell that is missing, renamed, or different from what you last wrote is the
normal outcome of someone else working — not damage. Re-read before acting, and
never restore a notebook to what a tool remembers. `read(since=…)` reports human
edits too, through Pluto's `StateChangeEvent` hook, so noticing them costs no
polling.

## Not a REPL

Julia already has REPL-shaped MCP servers — AgentREPL, MCPRepl, Kaimon — and
they are good at what they do: evaluate an expression, get a value back.

PlutoMCP is a different niche. The unit of work is a **notebook**, not an
expression: reactive, reproducible from scratch, self-contained with its own
package environment, and reviewable by a human while it is being written. The
human-review channel and the file that reruns from nothing are the point, not
interactive evaluation. If you want a scratchpad, use a REPL server. If you want
the finished experiment to still make sense next month, use this.
