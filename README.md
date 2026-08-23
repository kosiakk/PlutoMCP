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
- **Runs report honestly.** A run waits a short deadline, then says whether it
  finished. No polling for a fast cell, nothing blocked on a slow one.

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

```sh
git clone https://github.com/kosiakk/PlutoMCP.git ~/Documents/PlutoMCP
cd ~/Documents/PlutoMCP && julia --project=. -e 'import Pkg; Pkg.instantiate()'
```

Register it with Claude Code:

```sh
claude mcp add pluto -- julia --project=$HOME/Documents/PlutoMCP \
    $HOME/Documents/PlutoMCP/bin/pluto_mcp_server.jl
```

## Tools

| tool | what it does |
|---|---|
| `start` | start a Pluto server in-process |
| `open` | open an existing `.jl` notebook |
| `create` | author a whole notebook in one call |
| `list` | every notebook this session has open, and which is current |
| `read` | list cells as they are now; runs nothing |
| `edit` | replace / insert / delete a cell, then run it |
| `run` | run cells |
| `status` | what is still running, and which cells a human changed since you last looked |
| `execute` | evaluate an expression in the workspace, no cell created |
| `output` | one cell's output, plus its logs |
| `png` | render a plotting cell as an image |
| `export` | self-contained HTML with code and outputs embedded |
| `stop` | shut the server down |

`edit` follows `NotebookEdit`'s vocabulary: `cell_id`, `new_source`,
`cell_type`, `edit_mode`.

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

`run`, `edit` and `create` take a `block` (default 1 second). They start the
work, wait that long, and return either the finished result or:

```json
{"finished": false, "still_running": ["fit_model"]}
```

That is neither an error nor a timeout. The cell is still going, the browser
already shows it running, and `status` waits for it and says when it
is done.

## The two channels

There are exactly two channels between you and the human: terminal text, and
notebook edits in either direction. `status` is the second channel's read
side — it reports which cells a human changed since you last looked, with old
and new source, so you can answer by editing back.

A prior version of this tool added a third channel — an in-notebook "ask AI"
inbox — behind a fork of Pluto. That fork is not something anyone can install,
so it was dropped: the terminal already carries text, and a feature that needs
a fork is a feature nobody has.

## Concurrent editing is the point

The notebook is open in a browser and may be open to other sessions. A person
can rewrite, reorder or delete any cell at any moment, including between two
tool calls.

So a cell that is missing, renamed, or different from what you last wrote is the
normal outcome of someone else working — not damage. Re-read before acting, and
never restore a notebook to what a tool remembers. `status` reports human edits
too, through Pluto's `StateChangeEvent` hook, so noticing them costs no polling.
