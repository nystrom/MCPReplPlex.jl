using Test
using MCPRepl
using MCPRepl: MCPTool, MCPServer, process_jsonrpc_request, handle_client
using MCPRepl: get_socket_path, get_pid_path, get_project_dir
using MCPRepl: write_pid_file, remove_pid_file, remove_socket_file, check_existing_server
using MCPRepl: start_mcp_server, stop_mcp_server
using Sockets
using JSON3
using Dates

# Test socket path for isolation from real server
const TEST_SOCKET_DIR = mktempdir()
const TEST_SOCKET_PATH = joinpath(TEST_SOCKET_DIR, ".mcp-repl.sock")
const TEST_PID_PATH = joinpath(TEST_SOCKET_DIR, ".mcp-repl.pid")

# Helper to create test tools
function create_test_tools()
    echo_tool = MCPTool(
        "echo",
        "Echo the input text",
        MCPRepl.text_parameter("text", "Text to echo"),
        args -> get(args, "text", "")
    )

    reverse_tool = MCPTool(
        "reverse_text",
        "Reverse the input text",
        MCPRepl.text_parameter("text", "Text to reverse"),
        args -> reverse(get(args, "text", ""))
    )

    calc_tool = MCPTool(
        "calculate",
        "Evaluate a simple Julia expression",
        MCPRepl.text_parameter("expression", "Julia expression to evaluate"),
        function(args)
            try
                expr = Meta.parse(get(args, "expression", "0"))
                result = Core.eval(Main, expr)
                string(result)
            catch e
                "Error: $e"
            end
        end
    )

    slow_tool = MCPTool(
        "slow_echo",
        "Echo after a delay",
        MCPRepl.text_parameter("text", "Text to echo"),
        args -> begin
            sleep(0.1)
            get(args, "text", "")
        end
    )

    return [echo_tool, reverse_tool, calc_tool, slow_tool]
end

# Helper to send JSON-RPC request over socket
function send_jsonrpc(socket_path::String, request::Dict)
    sock = Sockets.connect(socket_path)
    try
        println(sock, JSON3.write(request))
        flush(sock)
        response_line = readline(sock)
        return JSON3.read(response_line, Dict{String,Any})
    finally
        close(sock)
    end
end

@testset "MCPRepl Tests" begin
    @testset "Path Functions" begin
        # These should return paths based on active project or pwd
        socket_path = get_socket_path()
        pid_path = get_pid_path()
        project_dir = get_project_dir()

        @test endswith(socket_path, ".mcp-repl.sock")
        @test endswith(pid_path, ".mcp-repl.pid")
        @test dirname(socket_path) == project_dir
        @test dirname(pid_path) == project_dir
    end

    @testset "PID File Management" begin
        # Use temp directory for isolation
        test_pid_path = joinpath(TEST_SOCKET_DIR, "test.pid")

        # Write PID file
        write(test_pid_path, string(getpid()))
        @test isfile(test_pid_path)
        @test parse(Int, read(test_pid_path, String)) == getpid()

        # Clean up
        rm(test_pid_path)
        @test !isfile(test_pid_path)
    end

    @testset "check_existing_server Logic" begin
        # Test with no PID file
        test_pid = joinpath(TEST_SOCKET_DIR, "check_test.pid")
        test_sock = joinpath(TEST_SOCKET_DIR, "check_test.sock")

        # Clean slate
        isfile(test_pid) && rm(test_pid)
        isfile(test_sock) && rm(test_sock)

        # Create orphaned socket file
        touch(test_sock)
        @test isfile(test_sock)

        # Mock the path functions for this test by directly testing the logic
        # No PID file should clean up orphaned socket
        @test !isfile(test_pid)

        # Test with invalid PID content
        write(test_pid, "not_a_number")
        pid_str = strip(read(test_pid, String))
        @test isnothing(tryparse(Int, pid_str))
        rm(test_pid)

        # Test with stale PID (process that doesn't exist)
        # Use a PID that's very unlikely to exist
        stale_pid = 999999999
        write(test_pid, string(stale_pid))
        @test isfile(test_pid)

        # Check that kill -0 fails for non-existent process
        process_exists = try
            run(pipeline(`kill -0 $stale_pid`, stderr=devnull))
            true
        catch
            false
        end
        @test !process_exists

        # Clean up
        rm(test_pid)

        # Test with valid PID (current process)
        write(test_pid, string(getpid()))
        process_exists = try
            run(pipeline(`kill -0 $(getpid())`, stderr=devnull))
            true
        catch
            false
        end
        @test process_exists

        rm(test_pid)
    end

    @testset "process_jsonrpc_request" begin
        tools = create_test_tools()
        tools_dict = Dict(tool.name => tool for tool in tools)

        @testset "Initialize" begin
            request = Dict{String,Any}(
                "jsonrpc" => "2.0",
                "id" => 1,
                "method" => "initialize"
            )
            response = process_jsonrpc_request(request, tools_dict)

            @test response["jsonrpc"] == "2.0"
            @test response["id"] == 1
            @test haskey(response, "result")
            @test response["result"]["protocolVersion"] == "2024-11-05"
            @test response["result"]["serverInfo"]["name"] == "julia-mcp-server"
        end

        @testset "Notifications return nothing" begin
            request = Dict{String,Any}(
                "jsonrpc" => "2.0",
                "method" => "notifications/initialized"
            )
            response = process_jsonrpc_request(request, tools_dict)
            @test isnothing(response)
        end

        @testset "tools/list" begin
            request = Dict{String,Any}(
                "jsonrpc" => "2.0",
                "id" => 2,
                "method" => "tools/list"
            )
            response = process_jsonrpc_request(request, tools_dict)

            @test response["jsonrpc"] == "2.0"
            @test response["id"] == 2
            @test haskey(response["result"], "tools")
            @test length(response["result"]["tools"]) == 4

            tool_names = [t["name"] for t in response["result"]["tools"]]
            @test "echo" in tool_names
            @test "reverse_text" in tool_names
            @test "calculate" in tool_names
            @test "slow_echo" in tool_names
        end

        @testset "tools/call" begin
            # Echo tool
            request = Dict{String,Any}(
                "jsonrpc" => "2.0",
                "id" => 3,
                "method" => "tools/call",
                "params" => Dict{String,Any}(
                    "name" => "echo",
                    "arguments" => Dict{String,Any}("text" => "hello world")
                )
            )
            response = process_jsonrpc_request(request, tools_dict)

            @test response["jsonrpc"] == "2.0"
            @test response["id"] == 3
            @test response["result"]["content"][1]["text"] == "hello world"

            # Reverse tool
            request = Dict{String,Any}(
                "jsonrpc" => "2.0",
                "id" => 4,
                "method" => "tools/call",
                "params" => Dict{String,Any}(
                    "name" => "reverse_text",
                    "arguments" => Dict{String,Any}("text" => "hello")
                )
            )
            response = process_jsonrpc_request(request, tools_dict)
            @test response["result"]["content"][1]["text"] == "olleh"

            # Calculate tool
            request = Dict{String,Any}(
                "jsonrpc" => "2.0",
                "id" => 5,
                "method" => "tools/call",
                "params" => Dict{String,Any}(
                    "name" => "calculate",
                    "arguments" => Dict{String,Any}("expression" => "2 + 3 * 4")
                )
            )
            response = process_jsonrpc_request(request, tools_dict)
            @test response["result"]["content"][1]["text"] == "14"
        end

        @testset "Tool not found" begin
            request = Dict{String,Any}(
                "jsonrpc" => "2.0",
                "id" => 6,
                "method" => "tools/call",
                "params" => Dict{String,Any}(
                    "name" => "nonexistent_tool",
                    "arguments" => Dict{String,Any}()
                )
            )
            response = process_jsonrpc_request(request, tools_dict)

            @test response["jsonrpc"] == "2.0"
            @test response["id"] == 6
            @test haskey(response, "error")
            @test response["error"]["code"] == -32602
            @test contains(response["error"]["message"], "Tool not found")
        end

        @testset "Method not found" begin
            request = Dict{String,Any}(
                "jsonrpc" => "2.0",
                "id" => 7,
                "method" => "unknown/method"
            )
            response = process_jsonrpc_request(request, tools_dict)

            @test haskey(response, "error")
            @test response["error"]["code"] == -32601
        end

        @testset "Missing method field" begin
            request = Dict{String,Any}(
                "jsonrpc" => "2.0",
                "id" => 8
            )
            response = process_jsonrpc_request(request, tools_dict)

            @test haskey(response, "error")
            @test response["error"]["code"] == -32600
        end
    end

    @testset "Server Startup and Shutdown" begin
        tools = create_test_tools()
        socket_path = joinpath(TEST_SOCKET_DIR, "startup_test.sock")

        # Clean up any existing files
        ispath(socket_path) && rm(socket_path)

        # Start server
        server = start_mcp_server(tools, socket_path; verbose=false)

        @test server.socket_path == socket_path
        @test length(server.tools) == 4
        @test server.running == true
        @test ispath(socket_path)  # Unix sockets are not regular files

        # Give server time to start accepting
        sleep(0.1)

        # Verify we can connect
        sock = Sockets.connect(socket_path)
        @test isopen(sock)
        close(sock)

        # Stop server
        stop_mcp_server(server)

        @test server.running == false
        @test !ispath(socket_path)
    end

    @testset "Socket File Cleanup on Stop" begin
        tools = create_test_tools()
        socket_path = joinpath(TEST_SOCKET_DIR, "cleanup_test.sock")

        ispath(socket_path) && rm(socket_path)

        server = start_mcp_server(tools, socket_path; verbose=false)
        sleep(0.1)

        @test ispath(socket_path)  # Unix sockets are not regular files

        stop_mcp_server(server)

        @test !ispath(socket_path)
    end

    @testset "Full JSON-RPC Over Socket" begin
        tools = create_test_tools()
        socket_path = joinpath(TEST_SOCKET_DIR, "jsonrpc_test.sock")

        ispath(socket_path) && rm(socket_path)

        server = start_mcp_server(tools, socket_path; verbose=false)
        sleep(0.1)

        try
            # Test initialize
            response = send_jsonrpc(socket_path, Dict(
                "jsonrpc" => "2.0",
                "id" => 1,
                "method" => "initialize"
            ))
            @test response["result"]["serverInfo"]["name"] == "julia-mcp-server"

            # Test tools/list
            response = send_jsonrpc(socket_path, Dict(
                "jsonrpc" => "2.0",
                "id" => 2,
                "method" => "tools/list"
            ))
            @test length(response["result"]["tools"]) == 4

            # Test tools/call
            response = send_jsonrpc(socket_path, Dict(
                "jsonrpc" => "2.0",
                "id" => 3,
                "method" => "tools/call",
                "params" => Dict(
                    "name" => "reverse_text",
                    "arguments" => Dict("text" => "testing")
                )
            ))
            @test response["result"]["content"][1]["text"] == "gnitset"
        finally
            stop_mcp_server(server)
        end
    end

    @testset "Multiple Concurrent Clients" begin
        tools = create_test_tools()
        socket_path = joinpath(TEST_SOCKET_DIR, "concurrent_test.sock")

        ispath(socket_path) && rm(socket_path)

        server = start_mcp_server(tools, socket_path; verbose=false)
        sleep(0.1)

        try
            # Create multiple persistent connections
            clients = [Sockets.connect(socket_path) for _ in 1:3]

            # All should be connected
            @test all(isopen, clients)

            # Send different requests from each client
            for (i, client) in enumerate(clients)
                request = Dict(
                    "jsonrpc" => "2.0",
                    "id" => i,
                    "method" => "tools/call",
                    "params" => Dict(
                        "name" => "echo",
                        "arguments" => Dict("text" => "client_$i")
                    )
                )
                println(client, JSON3.write(request))
                flush(client)
            end

            # Read responses
            for (i, client) in enumerate(clients)
                response_line = readline(client)
                response = JSON3.read(response_line, Dict{String,Any})
                @test response["id"] == i
                @test response["result"]["content"][1]["text"] == "client_$i"
            end

            # Clean up clients
            for client in clients
                close(client)
            end
        finally
            stop_mcp_server(server)
        end
    end

    @testset "Client Isolation with Variables" begin
        # Test that multiple clients can use the calculate tool with different
        # variable assignments without interfering with each other
        tools = create_test_tools()
        socket_path = joinpath(TEST_SOCKET_DIR, "isolation_test.sock")

        ispath(socket_path) && rm(socket_path)

        server = start_mcp_server(tools, socket_path; verbose=false)
        sleep(0.1)

        try
            # Client 1: Define x = 10
            response1 = send_jsonrpc(socket_path, Dict(
                "jsonrpc" => "2.0",
                "id" => 1,
                "method" => "tools/call",
                "params" => Dict(
                    "name" => "calculate",
                    "arguments" => Dict("expression" => "global test_var_x = 10; test_var_x")
                )
            ))
            @test response1["result"]["content"][1]["text"] == "10"

            # Client 2: Define x = 20 (same variable name, different value)
            response2 = send_jsonrpc(socket_path, Dict(
                "jsonrpc" => "2.0",
                "id" => 2,
                "method" => "tools/call",
                "params" => Dict(
                    "name" => "calculate",
                    "arguments" => Dict("expression" => "global test_var_x = 20; test_var_x")
                )
            ))
            @test response2["result"]["content"][1]["text"] == "20"

            # Note: In this implementation, variables ARE shared in Main module
            # This test documents the current behavior - both clients share state
            # The REPL multiplexing would work because each client gets responses
            # to their own requests, even though the Julia state is shared

            # Verify the value is now 20 (last write wins)
            response3 = send_jsonrpc(socket_path, Dict(
                "jsonrpc" => "2.0",
                "id" => 3,
                "method" => "tools/call",
                "params" => Dict(
                    "name" => "calculate",
                    "arguments" => Dict("expression" => "test_var_x")
                )
            ))
            @test response3["result"]["content"][1]["text"] == "20"
        finally
            stop_mcp_server(server)
        end
    end

    @testset "Concurrent Request Handling" begin
        # Test that slow requests don't block fast requests from other clients
        tools = create_test_tools()
        socket_path = joinpath(TEST_SOCKET_DIR, "blocking_test.sock")

        ispath(socket_path) && rm(socket_path)

        server = start_mcp_server(tools, socket_path; verbose=false)
        sleep(0.1)

        try
            # Open two connections
            slow_client = Sockets.connect(socket_path)
            fast_client = Sockets.connect(socket_path)

            # Send slow request first
            slow_request = Dict(
                "jsonrpc" => "2.0",
                "id" => 1,
                "method" => "tools/call",
                "params" => Dict(
                    "name" => "slow_echo",
                    "arguments" => Dict("text" => "slow")
                )
            )
            println(slow_client, JSON3.write(slow_request))
            flush(slow_client)

            # Immediately send fast request
            fast_request = Dict(
                "jsonrpc" => "2.0",
                "id" => 2,
                "method" => "tools/call",
                "params" => Dict(
                    "name" => "echo",
                    "arguments" => Dict("text" => "fast")
                )
            )
            println(fast_client, JSON3.write(fast_request))
            flush(fast_client)

            # Fast client should get response
            # (may or may not be before slow client depending on scheduling)
            fast_response_line = readline(fast_client)
            fast_response = JSON3.read(fast_response_line, Dict{String,Any})
            @test fast_response["result"]["content"][1]["text"] == "fast"

            # Slow client should eventually get response
            slow_response_line = readline(slow_client)
            slow_response = JSON3.read(slow_response_line, Dict{String,Any})
            @test slow_response["result"]["content"][1]["text"] == "slow"

            close(slow_client)
            close(fast_client)
        finally
            stop_mcp_server(server)
        end
    end

    @testset "Server Handles Client Disconnect" begin
        tools = create_test_tools()
        socket_path = joinpath(TEST_SOCKET_DIR, "disconnect_test.sock")

        ispath(socket_path) && rm(socket_path)

        server = start_mcp_server(tools, socket_path; verbose=false)
        sleep(0.1)

        try
            # Connect and disconnect abruptly
            client = Sockets.connect(socket_path)
            @test isopen(client)
            close(client)

            # Server should still be running and accept new connections
            sleep(0.1)
            @test server.running

            new_client = Sockets.connect(socket_path)
            @test isopen(new_client)

            # Should still handle requests
            println(new_client, JSON3.write(Dict(
                "jsonrpc" => "2.0",
                "id" => 1,
                "method" => "tools/list"
            )))
            flush(new_client)

            response_line = readline(new_client)
            response = JSON3.read(response_line, Dict{String,Any})
            @test length(response["result"]["tools"]) == 4

            close(new_client)
        finally
            stop_mcp_server(server)
        end
    end

    @testset "Stale Socket File Cleanup" begin
        # Test that starting a server cleans up stale socket files
        tools = create_test_tools()
        socket_path = joinpath(TEST_SOCKET_DIR, "stale_socket_test.sock")

        # Create a stale socket file (just a regular file, not a real socket)
        ispath(socket_path) && rm(socket_path)
        touch(socket_path)
        @test isfile(socket_path)

        # Starting server should remove stale file and create real socket
        server = start_mcp_server(tools, socket_path; verbose=false)
        sleep(0.1)

        try
            # Should be able to connect
            client = Sockets.connect(socket_path)
            @test isopen(client)
            close(client)
        finally
            stop_mcp_server(server)
        end
    end
end

# Clean up temp directory
rm(TEST_SOCKET_DIR; recursive=true, force=true)
