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

using ArgParse
using JSON3
using Sockets
using HTTP

const SOCKET_NAME = ".mcp-repl.sock"
const PID_NAME = ".mcp-repl.pid"
const MCP_PROTOCOL_VERSION = "2024-11-05"

const SOCKET_CACHE = Dict{String,Tuple{Union{String,Nothing},Float64}}()
const SOCKET_CACHE_TTL = 10.0

"""
    find_socket_path(start_dir::String) -> Union{String,Nothing}

Walk up the directory tree from start_dir looking for .mcp-repl.sock.
Returns the socket path if found, nothing otherwise.

Results are cached with a TTL to avoid repeated directory traversals.
"""
function find_socket_path(start_dir::String)
    current = abspath(start_dir)

    now = time()
    if haskey(SOCKET_CACHE, current)
        cached_path, cached_time = SOCKET_CACHE[current]
        if now - cached_time < SOCKET_CACHE_TTL
            return cached_path
        end
    end

    search_dir = current
    while true
        socket_path = joinpath(search_dir, SOCKET_NAME)
        if ispath(socket_path)
            SOCKET_CACHE[current] = (socket_path, now)
            return socket_path
        end
        parent = dirname(search_dir)
        if parent == search_dir
            SOCKET_CACHE[current] = (nothing, now)
            return nothing
        end
        search_dir = parent
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
        return success(pipeline(`kill -0 $pid`, stderr=devnull))
    catch
        return false
    end
end

const SOCKET_TIMEOUT = 30.0

"""
    with_timeout(f, timeout::Float64)

Execute function f with a timeout. Throws ErrorException if timeout is exceeded.
"""
function with_timeout(f, timeout::Float64)
    task = @async f()
    timer = Timer(timeout)

    try
        while !istaskdone(task)
            if !isopen(timer)
                try
                    Base.throwto(task, ErrorException("Operation timed out after $timeout seconds"))
                catch
                end
                wait(task)
                error("Operation timed out after $timeout seconds")
            end
            sleep(0.01)
        end
        return fetch(task)
    finally
        close(timer)
    end
end

"""
    send_to_julia_server(socket_path::String, request::Dict) -> Dict

Send a JSON-RPC request to the Julia server and return the response.
Includes connection and read timeouts.
"""
function send_to_julia_server(socket_path::String, request::Dict)
    try
        sock = with_timeout(SOCKET_TIMEOUT) do
            connect(socket_path)
        end

        # Send request
        println(sock, JSON3.write(request))

        # Read response
        response_line = with_timeout(SOCKET_TIMEOUT) do
            readline(sock)
        end

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
    forward_to_julia_server(tool_name::String, project_dir::String, tool_args::Dict{String,Any}, include_startup_msg::Bool=false) -> String

Forward a tool call to the Julia server identified by project_dir.
Returns the result text or an error message.
"""
function forward_to_julia_server(tool_name::String, project_dir::String, tool_args::Dict{String,Any}, include_startup_msg::Bool=false)
    socket_path = find_socket_path(project_dir)
    if isnothing(socket_path)
        msg = "Error: MCP REPL server not found in $project_dir"
        if include_startup_msg
            msg *= ". Start the server with:\n  julia --project -e 'using MCPRepl; MCPRepl.start!()'"
        end
        return msg
    end

    if !check_server_running(socket_path)
        msg = "Error: MCP REPL server not running"
        if include_startup_msg
            msg *= " (socket exists but process dead). Start the server with:\n  julia --project -e 'using MCPRepl; MCPRepl.start!()'"
        end
        return msg
    end

    julia_request = Dict(
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "tools/call",
        "params" => Dict(
            "name" => tool_name,
            "arguments" => tool_args
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
    handle_exec_repl(args::Dict{String,Any}) -> String

Handle exec_repl tool call.
Takes project_dir and expression, forwards to Julia server.
"""
function handle_exec_repl(args::Dict{String,Any})
    project_dir = get(args, "project_dir", "")
    expression = get(args, "expression", "")

    if isempty(project_dir)
        return "Error: project_dir parameter is required"
    end

    if isempty(expression)
        return "Error: expression parameter is required"
    end

    return forward_to_julia_server("exec_repl", project_dir, Dict("expression" => expression), true)
end

"""
    handle_investigate_environment(args::Dict{String,Any}) -> String

Handle investigate_environment tool call.
Takes project_dir, forwards to Julia server.
"""
function handle_investigate_environment(args::Dict{String,Any})
    project_dir = get(args, "project_dir", "")

    if isempty(project_dir)
        return "Error: project_dir parameter is required"
    end

    return forward_to_julia_server("investigate_environment", project_dir, Dict(), false)
end

"""
    handle_usage_instructions(args::Dict{String,Any}) -> String

Handle usage_instructions tool call.
Takes project_dir, forwards to Julia server.
"""
function handle_usage_instructions(args::Dict{String,Any})
    project_dir = get(args, "project_dir", "")

    if isempty(project_dir)
        return "Error: project_dir parameter is required"
    end

    return forward_to_julia_server("usage_instructions", project_dir, Dict(), false)
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
            "protocolVersion" => MCP_PROTOCOL_VERSION,
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
    parse_arguments(args::Vector{String}) -> Dict{String,Any}

Parse command line arguments using ArgParse.
"""
function parse_arguments(args::Vector{String})
    s = ArgParseSettings(
        prog = "julia -e 'using MCPRepl; MCPRepl.run_multiplexer(ARGS)' --",
        description = "MCP Julia REPL Multiplexer - MCP server that forwards to Julia REPL servers",
        epilog = "The Julia MCP server must be running in each project directory:\n  julia --project -e \"using MCPRepl; MCPRepl.start!()\"",
        exit_after_help = false
    )

    @add_arg_table! s begin
        "--transport"
            help = "Transport mode"
            arg_type = String
            default = "stdio"
            range_tester = x -> x in ["stdio", "http"]
        "--port"
            help = "Port for HTTP mode"
            arg_type = Int
            default = 3000
    end

    return parse_args(args, s)
end

"""
    main(args::Vector{String}=ARGS)

Main entry point for the MCP Julia REPL Multiplexer.
"""
function main(args::Vector{String}=ARGS)
    parsed_args = parse_arguments(args)
    transport = parsed_args["transport"]
    port = parsed_args["port"]

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
