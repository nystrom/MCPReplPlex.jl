using JSON3

function check_claude_status()
    # Check if claude command exists
    try
        run(pipeline(`which claude`, devnull))
    catch
        return :claude_not_found
    end

    # Check if MCP server is already configured
    try
        output = read(`claude mcp list`, String)
        if contains(output, "julia-repl")
            # Detect transport method
            if contains(output, ".mcp-repl.sock")
                return :configured_socket
            elseif contains(output, "mcp-julia-adapter")
                return :configured_script
            else
                return :configured_unknown
            end
        else
            return :not_configured
        end
    catch
        return :not_configured
    end
end

function get_gemini_settings_path()
    homedir = expanduser("~")
    gemini_dir = joinpath(homedir, ".gemini")
    settings_path = joinpath(gemini_dir, "settings.json")
    return gemini_dir, settings_path
end

function read_gemini_settings()
    gemini_dir, settings_path = get_gemini_settings_path()

    if !isfile(settings_path)
        return Dict()
    end

    try
        content = read(settings_path, String)
        return JSON3.read(content, Dict)
    catch
        return Dict()
    end
end

function write_gemini_settings(settings::Dict)
    gemini_dir, settings_path = get_gemini_settings_path()

    # Create .gemini directory if it doesn't exist
    if !isdir(gemini_dir)
        mkdir(gemini_dir)
    end

    try
        io = IOBuffer()
        JSON3.pretty(io, settings)
        content = String(take!(io))
        write(settings_path, content)
        return true
    catch
        return false
    end
end

function check_gemini_status()
    # Check if gemini command exists
    try
        run(pipeline(`which gemini`, devnull))
    catch
        return :gemini_not_found
    end

    # Check if MCP server is configured in settings.json
    settings = read_gemini_settings()
    mcp_servers = get(settings, "mcpServers", Dict())

    if haskey(mcp_servers, "julia-repl")
        server_config = mcp_servers["julia-repl"]
        if haskey(server_config, "command")
            cmd = server_config["command"]
            if contains(string(cmd), "mcp-julia-adapter")
                return :configured_script
            end
        end
        return :configured_unknown
    else
        return :not_configured
    end
end

function add_gemini_mcp_server()
    settings = read_gemini_settings()

    if !haskey(settings, "mcpServers")
        settings["mcpServers"] = Dict()
    end

    # Always use script transport (adapter handles socket discovery)
    settings["mcpServers"]["julia-repl"] = Dict(
        "command" => "$(pkgdir(MCPRepl))/mcp-julia-adapter"
    )

    return write_gemini_settings(settings)
end

function remove_gemini_mcp_server()
    settings = read_gemini_settings()

    if haskey(settings, "mcpServers") && haskey(settings["mcpServers"], "julia-repl")
        delete!(settings["mcpServers"], "julia-repl")
        return write_gemini_settings(settings)
    end

    return true  # Already removed
end

function setup()
    claude_status = check_claude_status()
    gemini_status = check_gemini_status()

    # Show current status
    println("🔧 MCPRepl Setup")
    println()

    # Claude status
    if claude_status == :claude_not_found
        println("📊 Claude status: ❌ Claude Code not found in PATH")
    elseif claude_status == :configured_socket
        println("📊 Claude status: ✅ MCP server configured (Unix socket)")
    elseif claude_status == :configured_script
        println("📊 Claude status: ✅ MCP server configured (script transport)")
    elseif claude_status == :configured_unknown
        println("📊 Claude status: ✅ MCP server configured (unknown transport)")
    else
        println("📊 Claude status: ❌ MCP server not configured")
    end

    # Gemini status
    if gemini_status == :gemini_not_found
        println("📊 Gemini status: ❌ Gemini CLI not found in PATH")
    elseif gemini_status == :configured_script
        println("📊 Gemini status: ✅ MCP server configured (script transport)")
    elseif gemini_status == :configured_unknown
        println("📊 Gemini status: ✅ MCP server configured (unknown transport)")
    else
        println("📊 Gemini status: ❌ MCP server not configured")
    end
    println()

    # Show options
    println("Available actions:")

    # Claude options
    if claude_status != :claude_not_found
        println("   Claude Code:")
        if claude_status in [:configured_socket, :configured_script, :configured_unknown]
            println("     [1] Remove Claude MCP configuration")
            println("     [2] Add/Replace Claude configuration")
        else
            println("     [1] Add Claude configuration")
        end
    end

    # Gemini options
    if gemini_status != :gemini_not_found
        println("   Gemini CLI:")
        if gemini_status in [:configured_script, :configured_unknown]
            println("     [3] Remove Gemini MCP configuration")
            println("     [4] Add/Replace Gemini configuration")
        else
            println("     [3] Add Gemini configuration")
        end
    end

    println()
    print("   Enter choice: ")

    choice = readline()

    # Handle choice
    if choice == "1"
        if claude_status in [:configured_socket, :configured_script, :configured_unknown]
            println("\n   Removing Claude MCP configuration...")
            try
                run(`claude mcp remove julia-repl`)
                println("   ✅ Successfully removed Claude MCP configuration")
            catch e
                println("   ❌ Failed to remove Claude MCP configuration: $e")
            end
        elseif claude_status != :claude_not_found
            println("\n   Adding Claude configuration...")
            try
                run(`claude mcp add julia-repl $(pkgdir(MCPRepl))/mcp-julia-adapter`)
                println("   ✅ Successfully configured Claude MCP server")
            catch e
                println("   ❌ Failed to configure Claude: $e")
            end
        end
    elseif choice == "2"
        if claude_status in [:configured_socket, :configured_script, :configured_unknown]
            println("\n   Adding/Replacing Claude configuration...")
            try
                run(`claude mcp add julia-repl $(pkgdir(MCPRepl))/mcp-julia-adapter`)
                println("   ✅ Successfully configured Claude MCP server")
            catch e
                println("   ❌ Failed to configure Claude: $e")
            end
        end
    elseif choice == "3"
        if gemini_status in [:configured_script, :configured_unknown]
            println("\n   Removing Gemini MCP configuration...")
            if remove_gemini_mcp_server()
                println("   ✅ Successfully removed Gemini MCP configuration")
            else
                println("   ❌ Failed to remove Gemini MCP configuration")
            end
        elseif gemini_status != :gemini_not_found
            println("\n   Adding Gemini configuration...")
            if add_gemini_mcp_server()
                println("   ✅ Successfully configured Gemini MCP server")
            else
                println("   ❌ Failed to configure Gemini")
            end
        end
    elseif choice == "4"
        if gemini_status in [:configured_script, :configured_unknown]
            println("\n   Adding/Replacing Gemini configuration...")
            if add_gemini_mcp_server()
                println("   ✅ Successfully configured Gemini MCP server")
            else
                println("   ❌ Failed to configure Gemini")
            end
        end
    else
        println("\n   Invalid choice. Please run MCPRepl.setup() again.")
        return
    end

    println("\n   💡 The adapter will automatically find the socket in your project directory.")
    println("   💡 Start the server with: MCPRepl.start!()")
end
