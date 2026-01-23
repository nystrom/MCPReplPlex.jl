# Tool definition structure
struct MCPTool
    name::String
    description::String
    parameters::Dict{String,Any}
    handler::Function
end

# Server with tool registry
mutable struct MCPServer
    socket_path::String
    server::Union{Nothing,Sockets.PipeServer}
    tools::Dict{String,MCPTool}
    running::Bool
    client_tasks::Vector{Task}
end

# Process a JSON-RPC request and return a response Dict
function process_jsonrpc_request(request::Dict{String,Any}, tools::Dict{String,MCPTool})
    # Check if method field exists
    if !haskey(request, "method")
        return Dict(
            "jsonrpc" => "2.0",
            "id" => get(request, "id", 0),
            "error" => Dict(
                "code" => -32600,
                "message" => "Invalid Request - missing method field"
            )
        )
    end

    method = request["method"]
    request_id = get(request, "id", nothing)

    # Handle initialization
    if method == "initialize"
        return Dict(
            "jsonrpc" => "2.0",
            "id" => request_id,
            "result" => Dict(
                "protocolVersion" => MCP_PROTOCOL_VERSION,
                "capabilities" => Dict(
                    "tools" => Dict()
                ),
                "serverInfo" => Dict(
                    "name" => "julia-mcp-server",
                    "version" => "1.0.0"
                )
            )
        )
    end

    # Handle initialized notification
    if method == "notifications/initialized"
        return nothing  # Notifications don't get responses
    end

    # Handle tool listing
    if method == "tools/list"
        tool_list = [
            Dict(
                "name" => tool.name,
                "description" => tool.description,
                "inputSchema" => tool.parameters
            ) for tool in values(tools)
        ]
        return Dict(
            "jsonrpc" => "2.0",
            "id" => request_id,
            "result" => Dict("tools" => tool_list)
        )
    end

    # Handle tool calls
    if method == "tools/call"
        params = get(request, "params", Dict())
        tool_name = get(params, "name", "")
        if haskey(tools, tool_name)
            tool = tools[tool_name]
            args = get(params, "arguments", Dict())

            # Call the tool handler
            result_text = tool.handler(args)

            return Dict(
                "jsonrpc" => "2.0",
                "id" => request_id,
                "result" => Dict(
                    "content" => [
                        Dict(
                            "type" => "text",
                            "text" => result_text
                        )
                    ]
                )
            )
        else
            return Dict(
                "jsonrpc" => "2.0",
                "id" => request_id,
                "error" => Dict(
                    "code" => -32602,
                    "message" => "Tool not found: $tool_name"
                )
            )
        end
    end

    # Method not found
    return Dict(
        "jsonrpc" => "2.0",
        "id" => request_id,
        "error" => Dict(
            "code" => -32601,
            "message" => "Method not found: $method"
        )
    )
end

# Handle a single client connection
function handle_client(client::IO, tools::Dict{String,MCPTool})
    try
        while isopen(client)
            line = readline(client)
            isempty(line) && continue

            request_id = 0
            try
                request = JSON3.read(line, Dict{String,Any})
                request_id = get(request, "id", 0)
                response = process_jsonrpc_request(request, tools)

                # Only send response if not a notification
                if !isnothing(response)
                    println(client, JSON3.write(response))
                end
            catch e
                if e isa EOFError
                    break
                end

                printstyled("\nMCP Server error: $e\n", color=:red)

                error_response = Dict(
                    "jsonrpc" => "2.0",
                    "id" => request_id,
                    "error" => Dict(
                        "code" => -32603,
                        "message" => "Internal error: $e"
                    )
                )
                println(client, JSON3.write(error_response))
            end
        end
    catch e
        if !(e isa EOFError || e isa Base.IOError)
            printstyled("\nMCP client handler error: $e\n", color=:red)
        end
    finally
        try
            close(client)
        catch
        end
    end
end

# Convenience function to create a simple text parameter schema
function text_parameter(name::String, description::String, required::Bool=true)
    schema = Dict(
        "type" => "object",
        "properties" => Dict(
            name => Dict(
                "type" => "string",
                "description" => description
            )
        )
    )
    if required
        schema["required"] = [name]
    end
    return schema
end

const MAX_CLIENTS = 10

function start_mcp_server(tools::Vector{MCPTool}, socket_path::String; verbose::Bool=true)
    tools_dict = Dict(tool.name => tool for tool in tools)

    # Remove existing socket if present (Unix sockets are not regular files)
    ispath(socket_path) && rm(socket_path)

    server = Sockets.listen(socket_path)
    mcp_server = MCPServer(socket_path, server, tools_dict, true, Task[])

    # Start accepting clients in background
    @async begin
        while mcp_server.running
            try
                client = accept(server)

                # Clean up completed tasks before adding new one
                filter!(t -> !istaskdone(t), mcp_server.client_tasks)

                # Check client limit
                if length(mcp_server.client_tasks) >= MAX_CLIENTS
                    printstyled("\nMCP Server: max clients ($MAX_CLIENTS) reached, rejecting connection\n", color=:yellow)
                    close(client)
                    continue
                end

                task = @async handle_client(client, tools_dict)
                push!(mcp_server.client_tasks, task)
            catch e
                if mcp_server.running && !(e isa Base.IOError)
                    printstyled("\nMCP Server accept error: $e\n", color=:red)
                end
            end
        end
    end

    if verbose
        println("🚀 MCP Server running on $socket_path with $(length(tools)) tools")
        println()
    else
        println("MCP Server running on $socket_path with $(length(tools)) tools")
    end

    return mcp_server
end

function stop_mcp_server(server::MCPServer)
    server.running = false

    # Close the server socket
    if !isnothing(server.server)
        try
            close(server.server)
        catch
        end
        server.server = nothing
    end

    # Wait for client tasks to finish
    for task in server.client_tasks
        try
            wait(task)
        catch
        end
    end
    empty!(server.client_tasks)

    # Remove socket (Unix sockets are not regular files)
    ispath(server.socket_path) && rm(server.socket_path)

    println("MCP Server stopped")
end
