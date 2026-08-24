"""
PlutoMCP — a thin wrapper that makes Pluto.jl available to Claude over MCP.

Pluto runs inside this process and is called directly, so:

  - the `Notebook` object here IS the server's, and reading it is always current;
  - edits appear instantly in an open browser tab;
  - a human editing in the browser needs no notification — their patches land on
    the same object, and `StateChangeEvent` reports them if you want to react.

Everything of substance lives in Pluto. This package contributes a cell-naming
convention, one result record, and the MCP surface.
"""
module PlutoMCP

using Pluto
using Sockets
using UUIDs
using Dates
using JSON3
using Logging
using ModelContextProtocol

include("render.jl")
include("embedded.jl")
include("tools.jl")

export start_session, stop_session, session, notebook_source, new_cell, cell_labels, resolve_cell,
    cell_info, cells_info, declarations, resolve_cells, record, run_cells!, run_with_deadline, wait_for_idle,
    await_run, cascade, busy_cells, sketch, truncate_payload, spill_dir, wake_path,
    build_server, run_server

end # module PlutoMCP
