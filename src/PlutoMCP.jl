module PlutoMCP

using HTTP
using MsgPack
using UUIDs
using JSON3
using ModelContextProtocol

include("client.jl")
include("server.jl")

export connect_pluto, list_notebooks, close_pluto, resync!,
    notebook_edit, run_cells, run_all,
    read_notebook, get_code, search_cells,
    find_definition, list_dependencies, find_dependents,
    get_output, cell_status, save_png,
    build_server, run_server

end # module PlutoMCP
