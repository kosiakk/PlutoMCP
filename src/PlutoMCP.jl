"""
PlutoMCP — a thin wrapper that makes Pluto.jl available to Claude over MCP.

Pluto runs inside this process and is called directly, so:

  - the `Notebook` object here IS the server's, and reading it is always current;
  - edits appear instantly in an open browser tab;
  - a human editing in the browser needs no notification — their patches land on
    the same object, and `StateChangeEvent` reports them if you want to react.

Everything of substance lives in Pluto. This package contributes a cell-naming
convention, a short-block-then-async run policy, and the MCP surface.
"""
module PlutoMCP

using Pluto
using Sockets
using UUIDs
using JSON3
using ModelContextProtocol

include("embedded.jl")
include("tools.jl")

export start_session, stop_session, notebook_source, cell_labels, resolve_cell,
    cell_info, cells_info, run_cells!, run_with_deadline, busy_cells,
    build_server, run_server

end # module PlutoMCP
