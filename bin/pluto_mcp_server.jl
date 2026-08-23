#!/usr/bin/env julia
# Entry point for MCP clients:
#   julia --project=<PlutoMCP dir> bin/pluto_mcp_server.jl
#
# Instantiate before loading: the first launch is typically from a fresh clone
# (the plugin marketplace's own copy), where nothing has been installed yet.
# Satisfied already, instantiate is a fast local check. Pkg's progress goes to
# stderr explicitly -- stdout carries JSON-RPC and nothing else.
import Pkg
Pkg.instantiate(; io=stderr)
using PlutoMCP
PlutoMCP.run_server()
