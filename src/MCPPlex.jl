"""
MCP Julia REPL Multiplexer

This multiplexer implements an MCP server that forwards REPL commands to Unix socket-based
Julia REPL servers. Each tool call specifies a project directory to locate the correct
Julia server socket.

Usage:
    julia -e 'using MCPRepl; MCPRepl.run_multiplexer(ARGS)' -- [--transport stdio|http] [--port PORT]

Options:
    --transport stdio|http    Transport mode (default: stdio)
    --port PORT               Port for HTTP mode (default: 3000)

The Julia MCP server must be running in each project directory:
    julia --project -e "using MCPRepl; MCPRepl.start!()"
"""
module MCPPlex

using JSON3
using Sockets
using HTTP

const SOCKET_NAME = ".mcp-repl.sock"
const PID_NAME = ".mcp-repl.pid"

"""
    find_socket_path(start_dir::String) -> Union{String,Nothing}

Walk up the directory tree from start_dir looking for .mcp-repl.sock.
Returns the socket path if found, nothing otherwise.
"""
function find_socket_path(start_dir::String)
    current = abspath(start_dir)
    while true
        socket_path = joinpath(current, SOCKET_NAME)
        if ispath(socket_path)
            return socket_path
        end
        parent = dirname(current)
        if parent == current
            return nothing
        end
        current = parent
    end
end

"""
    check_server_running(socket_path::String) -> Bool

Check if the MCP server is running by verifying the PID file.
Returns true if server appears to be running, false otherwise.
"""
function check_server_running(socket_path::String)
    pid_path = joinpath(dirname(socket_path), PID_NAME)

    if !ispath(pid_path)
        return false
    end

    try
        pid = parse(Int, strip(read(pid_path, String)))
        # Check if process exists (Unix systems)
        run(pipeline(`kill -0 $pid`, stderr=devnull), wait=false)
        return true
    catch
        return false
    end
end

"""
    send_to_julia_server(socket_path::String, request::Dict) -> Dict

Send a JSON-RPC request to the Julia server and return the response.
"""
function send_to_julia_server(socket_path::String, request::Dict)
    try
        sock = connect(socket_path)

        # Send request
        println(sock, JSON3.write(request))

        # Read response
        response_line = readline(sock)
        if isempty(response_line)
            close(sock)
            error("Server closed connection")
        end

        response = JSON3.read(response_line, Dict{String,Any})
        close(sock)

        return response
    catch e
        if e isa Base.IOError || e isa SystemError
            error("Socket error: $e. Is the Julia MCP server running?")
        else
            rethrow(e)
        end
    end
end

"""
    create_error_response(request_id, code::Int, message::String) -> Dict

Create a JSON-RPC error response.
"""
function create_error_response(request_id, code::Int, message::String)
    return Dict(
        "jsonrpc" => "2.0",
        "id" => request_id,
        "error" => Dict(
            "code" => code,
            "message" => message
        )
    )
end

"""
    create_success_response(request_id, result) -> Dict

Create a JSON-RPC success response.
"""
function create_success_response(request_id, result)
    return Dict(
        "jsonrpc" => "2.0",
        "id" => request_id,
        "result" => result
    )
end

"""
    handle_exec_repl(args::Dict) -> String

Handle exec_repl tool call.
Takes project_dir and expression, forwards to Julia server.
"""
function handle_exec_repl(args::Dict)
    project_dir = get(args, "project_dir", "")
    expression = get(args, "expression", "")

    if isempty(project_dir)
        return "Error: project_dir parameter is required"
    end

    if isempty(expression)
        return "Error: expression parameter is required"
    end

    # Find socket
    socket_path = find_socket_path(project_dir)
    if isnothing(socket_path)
        return "Error: MCP REPL server not found in $project_dir. Start the server with:\n  julia --project -e 'using MCPRepl; MCPRepl.start!()'"
    end

    if !check_server_running(socket_path)
        return "Error: MCP REPL server not running (socket exists but process dead). Start the server with:\n  julia --project -e 'using MCPRepl; MCPRepl.start!()'"
    end

    # Forward to Julia server's exec_repl tool
    julia_request = Dict(
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => Dict(
            "name" => "exec_repl",
            "arguments" => Dict(
                "expression" => expression
            )
        )
    )

    try
        response = send_to_julia_server(socket_path, julia_request)
        if haskey(response, "error")
            return "Error from Julia server: $(response["error"]["message"])"
        end
        if haskey(response, "result") && haskey(response["result"], "content")
            # Extract text from MCP response
            content = response["result"]["content"]
            if content isa Vector && length(content) > 0
                return get(content[1], "text", "")
            end
        end
        return string(get(response, "result", ""))
    catch e
        return "Error communicating with Julia server: $e"
    end
end

"""
    handle_investigate_environment(args::Dict) -> String

Handle investigate_environment tool call.
Takes project_dir, forwards to Julia server.
"""
function handle_investigate_environment(args::Dict)
    project_dir = get(args, "project_dir", "")

    if isempty(project_dir)
        return "Error: project_dir parameter is required"
    end

    socket_path = find_socket_path(project_dir)
    if isnothing(socket_path)
        return "Error: MCP REPL server not found in $project_dir"
    end

    if !check_server_running(socket_path)
        return "Error: MCP REPL server not running"
    end

    julia_request = Dict(
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => Dict(
            "name" => "investigate_environment",
            "arguments" => Dict()
        )
    )

    try
        response = send_to_julia_server(socket_path, julia_request)
        if haskey(response, "error")
            return "Error from Julia server: $(response["error"]["message"])"
        end
        if haskey(response, "result") && haskey(response["result"], "content")
            content = response["result"]["content"]
            if content isa Vector && length(content) > 0
                return get(content[1], "text", "")
            end
        end
        return string(get(response, "result", ""))
    catch e
        return "Error communicating with Julia server: $e"
    end
end

"""
    handle_usage_instructions(args::Dict) -> String

Handle usage_instructions tool call.
Takes project_dir, forwards to Julia server.
"""
function handle_usage_instructions(args::Dict)
    project_dir = get(args, "project_dir", "")

    if isempty(project_dir)
        return "Error: project_dir parameter is required"
    end

    socket_path = find_socket_path(project_dir)
    if isnothing(socket_path)
        return "Error: MCP REPL server not found in $project_dir"
    end

    if !check_server_running(socket_path)
        return "Error: MCP REPL server not running"
    end

    julia_request = Dict(
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => Dict(
            "name" => "usage_instructions",
            "arguments" => Dict()
        )
    )

    try
        response = send_to_julia_server(socket_path, julia_request)
        if haskey(response, "error")
            return "Error from Julia server: $(response["error"]["message"])"
        end
        if haskey(response, "result") && haskey(response["result"], "content")
            content = response["result"]["content"]
            if content isa Vector && length(content) > 0
                return get(content[1], "text", "")
            end
        end
        return string(get(response, "result", ""))
    catch e
        return "Error communicating with Julia server: $e"
    end
end

# MCP Tool definitions
const TOOLS = [
    Dict(
        "name" => "exec_repl",
        "description" => """Execute Julia code in a shared, persistent REPL session.

**PREREQUISITE**: Before using this tool, you MUST first call the `usage_instructions` tool.

The tool returns raw text output containing: all printed content from stdout and stderr streams, plus the mime text/plain representation of the expression's return value (unless the expression ends with a semicolon).

You may use this REPL to execute julia code, run test sets, get function documentation, etc.""",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "project_dir" => Dict(
                    "type" => "string",
                    "description" => "Directory where the Julia project is located (used to find the REPL socket)"
                ),
                "expression" => Dict(
                    "type" => "string",
                    "description" => "Julia expression to evaluate (e.g., '2 + 3 * 4' or `import Pkg; Pkg.status()`)"
                )
            ),
            "required" => ["project_dir", "expression"]
        ),
        "handler" => handle_exec_repl
    ),
    Dict(
        "name" => "investigate_environment",
        "description" => """Investigate the current Julia environment including pwd, active project, packages, and development packages with their paths.

This tool provides comprehensive information about:
- Current working directory
- Active project and its details
- All packages in the environment with development status
- Development packages with their file system paths
- Current environment package status
- Revise.jl status for hot reloading""",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "project_dir" => Dict(
                    "type" => "string",
                    "description" => "Directory where the Julia project is located"
                )
            ),
            "required" => ["project_dir"]
        ),
        "handler" => handle_investigate_environment
    ),
    Dict(
        "name" => "usage_instructions",
        "description" => "Get detailed instructions for proper Julia REPL usage, best practices, and workflow guidelines.",
        "inputSchema" => Dict(
            "type" => "object",
            "properties" => Dict(
                "project_dir" => Dict(
                    "type" => "string",
                    "description" => "Directory where the Julia project is located"
                )
            ),
            "required" => ["project_dir"]
        ),
        "handler" => handle_usage_instructions
    )
]

"""
    process_mcp_request(request::Dict) -> Union{Dict,Nothing}

Process an MCP request and return a response.
"""
function process_mcp_request(request::Dict)
    method = get(request, "method", nothing)
    request_id = get(request, "id", nothing)

    # Handle initialization
    if method == "initialize"
        return create_success_response(request_id, Dict(
            "protocolVersion" => "2024-11-05",
            "capabilities" => Dict(
                "tools" => Dict()
            ),
            "serverInfo" => Dict(
                "name" => "julia-mcp-adapter",
                "version" => "1.0.0"
            )
        ))
    end

    # Handle initialized notification
    if method == "notifications/initialized"
        return nothing  # No response for notifications
    end

    # Handle tool listing
    if method == "tools/list"
        tool_list = [
            Dict(
                "name" => tool["name"],
                "description" => tool["description"],
                "inputSchema" => tool["inputSchema"]
            ) for tool in TOOLS
        ]
        return create_success_response(request_id, Dict("tools" => tool_list))
    end

    # Handle tool calls
    if method == "tools/call"
        params = get(request, "params", Dict())
        tool_name = get(params, "name", "")
        args = get(params, "arguments", Dict())

        # Find tool
        tool = findfirst(t -> t["name"] == tool_name, TOOLS)
        if isnothing(tool)
            return create_error_response(request_id, -32602, "Tool not found: $tool_name")
        end

        # Call tool handler
        try
            result_text = TOOLS[tool]["handler"](args)
            return create_success_response(request_id, Dict(
                "content" => [
                    Dict(
                        "type" => "text",
                        "text" => result_text
                    )
                ]
            ))
        catch e
            return create_error_response(request_id, -32603, "Tool execution error: $e")
        end
    end

    # Method not found
    return create_error_response(request_id, -32601, "Method not found: $method")
end

"""
    run_stdio_mode()

Run in stdio mode - read from stdin, write to stdout.
"""
function run_stdio_mode()
    while !eof(stdin)
        line = readline(stdin)
        isempty(line) && continue

        try
            request = JSON3.read(line, Dict{String,Any})
            response = process_mcp_request(request)

            # Only send response if not a notification
            if !isnothing(response)
                println(stdout, JSON3.write(response))
                flush(stdout)
            end

        catch e
            if e isa JSON3.Error
                error_response = create_error_response(nothing, -32700, "Parse error: $e")
                println(stdout, JSON3.write(error_response))
                flush(stdout)
            else
                error_response = create_error_response(nothing, -32603, "Internal error: $e")
                println(stdout, JSON3.write(error_response))
                flush(stdout)
            end
        end
    end
end

"""
    run_http_mode(port::Int)

Run in HTTP mode - serve HTTP requests.
Requires HTTP.jl to be loaded.
"""
function run_http_mode(port::Int)
    function handle_request(req::HTTP.Request)
        # Handle CORS preflight
        if req.method == "OPTIONS"
            return HTTP.Response(200, [
                "Access-Control-Allow-Origin" => "*",
                "Access-Control-Allow-Methods" => "POST, GET, OPTIONS",
                "Access-Control-Allow-Headers" => "Content-Type"
            ])
        end

        # Health check
        if req.method == "GET" && req.target == "/health"
            return HTTP.Response(200,
                ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
                JSON3.write(Dict("status" => "ok"))
            )
        end

        # Handle POST requests
        if req.method == "POST"
            try
                body = String(req.body)
                if isempty(body)
                    error_resp = create_error_response(nothing, -32600, "Empty request body")
                    return HTTP.Response(400,
                        ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
                        JSON3.write(error_resp)
                    )
                end

                request = JSON3.read(body, Dict{String,Any})
                response = process_mcp_request(request)

                if !isnothing(response)
                    return HTTP.Response(200,
                        ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
                        JSON3.write(response)
                    )
                end

            catch e
                if e isa JSON3.Error
                    error_resp = create_error_response(nothing, -32700, "Parse error: $e")
                    return HTTP.Response(400,
                        ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
                        JSON3.write(error_resp)
                    )
                else
                    error_resp = create_error_response(nothing, -32603, "Internal error: $e")
                    return HTTP.Response(500,
                        ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
                        JSON3.write(error_resp)
                    )
                end
            end
        end

        # Invalid request
        error_resp = create_error_response(nothing, -32600, "Use POST for JSON-RPC requests")
        return HTTP.Response(400,
            ["Content-Type" => "application/json", "Access-Control-Allow-Origin" => "*"],
            JSON3.write(error_resp)
        )
    end

    println(stderr, "MCP Julia REPL Multiplexer running on http://localhost:$port")

    try
        HTTP.serve(handle_request, "localhost", port)
    catch e
        if e isa InterruptException
            println(stderr, "\nShutting down HTTP server")
        else
            rethrow(e)
        end
    end
end

"""
    print_usage()

Print usage information to stderr.
"""
function print_usage()
    println(stderr, """
    MCP Julia REPL Multiplexer - MCP server that forwards to Julia REPL servers

    Usage:
        julia -e 'using MCPRepl; MCPRepl.run_multiplexer(ARGS)' -- [options]

    Options:
        --transport stdio|http    Transport mode (default: stdio)
        --port PORT               Port for HTTP mode (default: 3000)
        --help, -h                Show this help message

    The Julia MCP server must be running in each project directory:
        julia --project -e "using MCPRepl; MCPRepl.start!()"
    """)
end

"""
    main(args::Vector{String}=ARGS)

Main entry point for the MCP Julia REPL Multiplexer.
"""
function main(args::Vector{String}=ARGS)
    # Parse command line arguments
    transport = "stdio"
    port = 3000

    i = 1
    while i <= length(args)
        arg = args[i]
        if arg == "--transport"
            i += 1
            if i > length(args)
                println(stderr, "Error: --transport requires an argument")
                print_usage()
                exit(1)
            end
            transport = args[i]
            if transport ∉ ["stdio", "http"]
                println(stderr, "Error: --transport must be 'stdio' or 'http'")
                print_usage()
                exit(1)
            end
        elseif arg == "--port"
            i += 1
            if i > length(args)
                println(stderr, "Error: --port requires an argument")
                print_usage()
                exit(1)
            end
            try
                port = parse(Int, args[i])
            catch
                println(stderr, "Error: --port must be an integer")
                print_usage()
                exit(1)
            end
        elseif arg == "--help" || arg == "-h"
            print_usage()
            exit(0)
        else
            println(stderr, "Error: Unknown option: $arg")
            print_usage()
            exit(1)
        end
        i += 1
    end

    # Run in appropriate mode
    if transport == "stdio"
        run_stdio_mode()
    else
        run_http_mode(port)
    end
end

end # module

# Run main if this file is executed as a script
if abspath(PROGRAM_FILE) == @__FILE__
    MCPPlex.main()
end
