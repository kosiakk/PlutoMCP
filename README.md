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
| `read` | list cells as they are now; runs nothing |
| `edit` | replace / insert / delete a cell, then run it |
| `run` | run cells |
| `status` | what is still running, and what changed since you last looked |
| `output` | one cell's output |
| `png` | render a plotting cell as an image |
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
already shows it running, and `status` — optionally with `wait` — says when it
is done.

## Concurrent editing is the point

The notebook is open in a browser and may be open to other sessions. A person
can rewrite, reorder or delete any cell at any moment, including between two
tool calls.

So a cell that is missing, renamed, or different from what you last wrote is the
normal outcome of someone else working — not damage. Re-read before acting, and
never restore a notebook to what a tool remembers. `status` reports human edits
too, through Pluto's `StateChangeEvent` hook, so noticing them costs no polling.
