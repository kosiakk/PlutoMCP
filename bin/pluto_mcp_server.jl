#!/usr/bin/env julia
# Entry point for MCP clients: `julia --project=<PlutoMCP dir> bin/pluto_mcp_server.jl`
using PlutoMCP

# Package extensions only activate once their trigger package is actually
# loaded into the session — merely having `Pluto` resolvable in this
# environment's Manifest isn't enough. Load it here (if present) so
# PlutoMCPPlutoExt's managed-mode tools (pluto_start, pluto_create_notebook)
# register with build_server(); skipped silently for attach-only setups
# that never added the (heavy) Pluto dependency.
if Base.identify_package("Pluto") !== nothing
    @eval using Pluto
end

PlutoMCP.run_server()
