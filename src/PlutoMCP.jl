module PlutoMCP

using HTTP
using MsgPack
using UUIDs
using JSON3
using ModelContextProtocol

include("client.jl")
include("server.jl")

export connect_pluto, new_notebook, notebook_source, list_notebooks, close_pluto, resync!,
    notebook_edit, run_cells, run_all, restart_process,
    read_notebook, get_code, search_cells,
    find_definition, list_dependencies, find_dependents,
    get_output, cell_status, save_png,
    build_server, run_server

# Managed mode ("start Pluto myself" rather than "attach" to an existing
# session) lives in ext/PlutoMCPPlutoExt.jl, only loaded when the `Pluto`
# package itself is present — it's a heavy dependency that attach-only
# users shouldn't have to install. `extra_tools()` is how that extension
# adds its own MCPTools to the *same* server/tool list (one MCP, not two)
# without this module needing to know the extension exists.
#
# Declared with no method (not `extra_tools() = []`): a package extension
# can only *add* a method to a function, not overwrite one that already
# exists — for a zero-argument function like this, any body here would
# collide with the extension's. `build_server()` checks `hasmethod`
# before calling, since without the extension loaded there's no method
# at all.
function extra_tools end

end # module PlutoMCP
