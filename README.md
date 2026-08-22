# PlutoMCP

An MCP server that lets an AI assistant co-author a running [Pluto.jl](https://plutojl.org) notebook — live, in the same browser tab you already have open — instead of pasting code back and forth.

## Why

Pluto is close to the ideal environment for exploratory scientific and technical work: reactive re-execution, no hidden state, code that's just... code. But today, getting an AI's help inside a live Pluto session means copy-pasting cells by hand. PlutoMCP closes that gap: the assistant reads your notebook's actual dependency graph, edits and runs cells directly, and gets plots back as real images — while you watch it happen in your own browser.

The intended use is a **scientific collaboration loop**: you're exploring some data or a model, you ask your assistant to add a diagnostic plot, tweak a parameter, or explain what a cell depends on — and it just does it, in the notebook, instead of handing you a code snippet to paste in yourself.

## How it works

Pluto has no public API for this. PlutoMCP speaks Pluto's own internal WebSocket protocol — the one its browser frontend uses — reverse-engineered from Pluto's source rather than any official interface. No fork, no changes to Pluto itself; it works against any already-running `Pluto.run()` session.

One deliberate design choice: Pluto tracks a full reactive dependency graph internally (which cell defines which variable, what each cell depends on) and pushes it to every connected client. PlutoMCP uses that instead of guessing from source text — `pluto_find_definition("S64")` finds the cell that defines `S64` exactly, not by grepping for the string.

## Setup

```julia
julia> import Pkg; Pkg.instantiate()  # from this package's directory
```

Point your MCP client at `bin/pluto_mcp_server.jl` (stdio transport):

```bash
claude mcp add pluto -- julia --project=/path/to/PlutoMCP /path/to/PlutoMCP/bin/pluto_mcp_server.jl
```

(Or wire it into whatever config your MCP client uses for a stdio server — the command is just `julia --project=<this dir> -e 'using PlutoMCP; PlutoMCP.run_server()'`.)

## Two modes, one server

**Attach** — drive a Pluto session you already have running. This is the default; it needs nothing beyond PlutoMCP itself. You'll need the server's `secret`, from the URL Pluto printed on startup.

**Managed** — have the assistant start its own Pluto server and notebook from scratch, with no existing session required. This needs the `Pluto` package itself installed alongside PlutoMCP (`Pkg.add("Pluto")` in the same environment) — it's a heavy dependency, so it's wired up as a [package extension](https://pkgdocs.julialang.org/v1/creating-packages/#Conditional-loading-of-code-in-packages-(Extensions)): its two extra tools (`pluto_start`, `pluto_create_notebook`) simply don't exist if `Pluto` isn't there. Same server, same tool list either way — not two separate MCPs.

## Tools

| Tool | Purpose |
|---|---|
| `pluto_connect` | Attach to a notebook on an already-running Pluto server. |
| `pluto_new_notebook` | Create an empty notebook on an already-running server and attach to it. |
| `pluto_list_notebooks` | See what's open on a server. |
| `pluto_read_notebook` | List cells + their current outputs, without running anything. |
| `pluto_notebook_edit` | Replace / insert / delete a cell — same shape as editing a `.ipynb`. |
| `pluto_run_cells` | Run (or re-run) cells. |
| `pluto_get_output` | Wait for a cell and get its result — text, or a viewable image. |
| `pluto_search_cells` | Find cells by source text. |
| `pluto_find_definition` | Find the cell that defines a variable, via Pluto's real dependency graph. |
| `pluto_list_dependencies` | What a cell depends on, and where each dependency is defined. |
| `pluto_find_dependents` | What depends on a given variable. |
| `pluto_render_png` | Guaranteed-PNG plot output, whatever the cell's native format. |
| `pluto_start` *(managed mode)* | Start a fresh, PlutoMCP-managed Pluto server. |
| `pluto_create_notebook` *(managed mode)* | Author a whole notebook's cells in one shot and open it — faster than building one cell-by-cell for an initial structure (title, sections, functions, a chart). |

## Known limitations

- **No auth beyond Pluto's own `secret`.** Anyone who can reach the tool can reach the notebook.
- **`pluto_render_png` recomputes** the cell rather than rasterizing existing output — fine for a cheap plot, wasteful for an expensive one.
- **Managed mode reuses the WebSocket bridge**, not a from-scratch direct-call path. A self-started session *could*, in principle, be driven by calling Pluto's internal functions directly in-process, with no protocol involved — that's future work, not done yet.
- **`Pluto.run!`'s auto-picked port isn't queryable after the fact**, so managed mode picks a free port itself first, then hands it to Pluto explicitly. A small race is possible (something else could grab the port in between).
- **No output persistence.** Unlike Jupyter, Pluto keeps no results in the `.jl` file itself — only in the running process's memory. If the notebook's Julia process restarts, results are gone regardless of whether PlutoMCP was involved.
- **Sequential edits are paced**, not confirmed. Firing several edits faster than a human would type was found to race against Pluto's own server-side handling; a short delay between them sidesteps it, but a proper fix would wait for server acknowledgment instead.
- **`pluto_get_output`'s default 30s timeout can be too short for a cell run on a freshly-started managed-mode workspace** — the underlying worker *process* still spinning up looks identical to "not running yet" from a cell's `queued`/`running` flags alone, which is what `get_output` actually polls; it doesn't check Pluto's separate `process_status`. Pass a longer `timeout` for a notebook's first cell run after `pluto_start`, or just retry.

## Status

Working prototype, tested against a real multi-notebook Pluto session. Not yet published to Julia's General registry.
