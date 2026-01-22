module MCPRepl

using REPL
using Sockets
using JSON3

const SOCKET_NAME = ".mcp-repl.sock"
const PID_NAME = ".mcp-repl.pid"

include("MCPServer.jl")

"""
    get_project_dir()

Returns the directory containing the active project (Project.toml), or pwd() as fallback.
"""
function get_project_dir()
    proj = Base.active_project()
    if !isnothing(proj) && isfile(proj)
        return dirname(proj)
    end
    return pwd()
end

"""
    multiplexer_path()

Returns the absolute path to the MCPMultiplexer.jl script.
This is useful for configuring MCP clients that need the multiplexer script path.

Example:
    julia -e 'using MCPRepl; println(MCPRepl.multiplexer_path())'
"""
function multiplexer_path()
    return joinpath(dirname(pathof(@__MODULE__)), "MCPMultiplexer.jl")
end

"""
    get_socket_path(socket_dir::String=get_project_dir())

Returns the path to the Unix socket file in the specified directory.
"""
function get_socket_path(socket_dir::String=get_project_dir())
    return joinpath(socket_dir, SOCKET_NAME)
end

"""
    get_pid_path(socket_dir::String=get_project_dir())

Returns the path to the PID file in the specified directory.
"""
function get_pid_path(socket_dir::String=get_project_dir())
    return joinpath(socket_dir, PID_NAME)
end

"""
    write_pid_file(socket_dir::String=get_project_dir())

Writes the current process PID to the PID file.
"""
function write_pid_file(socket_dir::String=get_project_dir())
    write(get_pid_path(socket_dir), string(getpid()))
    return nothing
end

"""
    remove_pid_file(socket_dir::String=get_project_dir())

Removes the PID file if it exists.
"""
function remove_pid_file(socket_dir::String=get_project_dir())
    pid_path = get_pid_path(socket_dir)
    isfile(pid_path) && rm(pid_path)
    return nothing
end

"""
    remove_socket_file(socket_dir::String=get_project_dir())

Removes the socket file if it exists.
"""
function remove_socket_file(socket_dir::String=get_project_dir())
    socket_path = get_socket_path(socket_dir)
    ispath(socket_path) && rm(socket_path)  # Unix sockets are not regular files
    return nothing
end

"""
    check_existing_server(socket_dir::String=get_project_dir())

Checks if an MCP server is already running. Returns true if a server is running,
false otherwise. Cleans up stale PID/socket files if the process is dead.
"""
function check_existing_server(socket_dir::String=get_project_dir())
    pid_path = get_pid_path(socket_dir)
    socket_path = get_socket_path(socket_dir)

    if !isfile(pid_path)
        # No PID file, clean up any orphaned socket
        remove_socket_file(socket_dir)
        return false
    end

    # Read PID from file
    pid_str = strip(read(pid_path, String))
    pid = tryparse(Int, pid_str)

    if isnothing(pid)
        # Invalid PID file, clean up
        remove_pid_file(socket_dir)
        remove_socket_file(socket_dir)
        return false
    end

    # Check if process is alive (signal 0 tests existence)
    try
        run(pipeline(`kill -0 $pid`, stderr=devnull))
        # Process exists, server is running
        return true
    catch
        # Process is dead, clean up stale files
        remove_pid_file(socket_dir)
        remove_socket_file(socket_dir)
        return false
    end
end

struct IOBufferDisplay <: AbstractDisplay
    io::IOBuffer
    IOBufferDisplay() = new(IOBuffer())
end
Base.displayable(::IOBufferDisplay, _) = true
Base.display(d::IOBufferDisplay, x) = show(d.io, MIME("text/plain"), x)
Base.display(d::IOBufferDisplay, mime, x) = show(d.io, mime, x)

function execute_repllike(str)
    # Check for Pkg.activate usage
    if contains(str, "activate(") && !contains(str, r"#.*overwrite no-activate-rule")
        return """
            ERROR: Using Pkg.activate to change environments is not allowed.
            You should assume you are in the correct environment for your tasks.
            You may use Pkg.status() to see the current environment and available packages.
            If you need to use a third-party 'activate' function, add '# overwrite no-activate-rule' at the end of your command.
        """
    end
    if contains(str, "Pkg.add(")
        return """
            ERROR: Using Pkg.add to install packages is not allowed.
            You should assume all necessary packages are already installed in the environment.
            If you need another package, prompt the user!
        """
    end
    # Check for varinfo() usage which is slow and problematic
    if contains(str, "varinfo(")
        return """
            ERROR: Using varinfo() is not allowed because it takes too long to execute.
            Use the investigate_environment tool instead to get information about the Julia environment.
            If unclear, ask the user.
        """
    end
    # eval using/import to suppress interactive ask for instllation
    if contains(str, r"(^|\n)using\s") || contains(str, r"(^|\n)import\s")
        # Replace each import/using statement with @eval prefix
        str = replace(str, r"(^|\n)(using\s[^\n]*)" => s"\1@eval \2")
        str = replace(str, r"(^|\n)(import\s[^\n]*)" => s"\1@eval \2")
    end

    repl = Base.active_repl
    expr = Base.parse_input_line(str)
    backend = repl.backendref

    REPL.prepare_next(repl)
    printstyled("\nagent> ", color=:red, bold=:true)
    print(str, "\n")

    # Capture stdout/stderr during execution
    captured_output = Pipe()
    response = redirect_stdout(captured_output) do
        redirect_stderr(captured_output) do
            r = if VERSION >= v"1.12"
                REPL.eval_on_backend(expr, backend)
            else
                REPL.eval_with_backend(expr, backend)
            end
            close(Base.pipe_writer(captured_output))
            r
        end
    end
    captured_content = read(captured_output, String)
    # reshow the stuff which was printed to stdout/stderr before
    print(captured_content)

    disp = IOBufferDisplay()

    # generate printout, err goes to disp.err, val goes to "specialdisplay" disp
    if VERSION >= v"1.11"
        REPL.print_response(disp.io, response, backend, !REPL.ends_with_semicolon(str), false, disp)
    else
        REPL.print_response(disp.io, response, !REPL.ends_with_semicolon(str), false, disp)
    end

    # generate the printout again for the "normal" repl
    REPL.print_response(repl, response, !REPL.ends_with_semicolon(str), repl.hascolor)

    REPL.prepare_next(repl)
    REPL.LineEdit.refresh_line(repl.mistate)

    # Combine captured output with display output
    display_content = String(take!(disp.io))

    return captured_content * display_content
end

SERVER = Ref{Union{Nothing,MCPServer}}(nothing)

function repl_status_report()
    if !isdefined(Main, :Pkg)
        error("Expect Main.Pkg to be defined.")
    end
    Pkg = Main.Pkg

    try
        # Basic environment info
        println("🔍 Julia Environment Investigation")
        println("=" ^ 50)
        println()

        # Current directory
        println("📁 Current Directory:")
        println("   $(pwd())")
        println()

        # Active project
        active_proj = Base.active_project()
        println("📦 Active Project:")
        if active_proj !== nothing
            println("   Path: $active_proj")
            try
                project_data = Pkg.TOML.parsefile(active_proj)
                if haskey(project_data, "name")
                    println("   Name: $(project_data["name"])")
                else
                    println("   Name: $(basename(dirname(active_proj)))")
                end
                if haskey(project_data, "version")
                    println("   Version: $(project_data["version"])")
                end
            catch e
                println("   Error reading project info: $e")
            end
        else
            println("   No active project")
        end
        println()

        # Package status
        println("📚 Package Environment:")
        try
            # Get package status (suppress output)
            pkg_status = redirect_stdout(devnull) do
                Pkg.status(; mode = Pkg.PKGMODE_MANIFEST)
            end

            # Parse dependencies for development packages
            deps = Pkg.dependencies()
            dev_packages = Dict{String,String}()

            for (uuid, pkg_info) in deps
                if pkg_info.is_direct_dep && pkg_info.is_tracking_path
                    dev_packages[pkg_info.name] = pkg_info.source
                end
            end

            # Add current environment package if it's a development package
            if active_proj !== nothing
                try
                    project_data = Pkg.TOML.parsefile(active_proj)
                    if haskey(project_data, "uuid")
                        pkg_name = get(project_data, "name", basename(dirname(active_proj)))
                        pkg_dir = dirname(active_proj)
                        # This is a development package since we're in its source
                        dev_packages[pkg_name] = pkg_dir
                    end
                catch
                    # Not a package, that's fine
                end
            end

            # Check if current environment is itself a package and collect its info
            current_env_package = nothing
            if active_proj !== nothing
                try
                    project_data = Pkg.TOML.parsefile(active_proj)
                    if haskey(project_data, "uuid")
                        pkg_name = get(project_data, "name", basename(dirname(active_proj)))
                        pkg_version = get(project_data, "version", "dev")
                        pkg_uuid = project_data["uuid"]
                        current_env_package = (name = pkg_name, version = pkg_version, uuid = pkg_uuid, path = dirname(active_proj))
                    end
                catch
                    # Not a package environment, that's fine
                end
            end

            # Separate development packages from regular packages
            dev_deps = []
            regular_deps = []

            for (uuid, pkg_info) in deps
                if pkg_info.is_direct_dep
                    if haskey(dev_packages, pkg_info.name)
                        push!(dev_deps, pkg_info)
                    else
                        push!(regular_deps, pkg_info)
                    end
                end
            end

            # List development packages first (with current environment package at the top if applicable)
            has_dev_packages = !isempty(dev_deps) || current_env_package !== nothing
            if has_dev_packages
                println("   🔧 Development packages (tracked by Revise):")

                # Show current environment package first if it exists
                if current_env_package !== nothing
                    println("      $(current_env_package.name) v$(current_env_package.version) [CURRENT ENV] => $(current_env_package.path)")
                    try
                        # Try to get canonical path using pkgdir
                        pkg_dir = pkgdir(current_env_package.name)
                        if pkg_dir !== nothing && pkg_dir != current_env_package.path
                            println("         pkgdir(): $pkg_dir")
                        end
                    catch
                        # pkgdir might fail, that's okay
                    end
                end

                # Then show other development packages
                for pkg_info in dev_deps
                    # Skip if this is the same as the current environment package
                    if current_env_package !== nothing && pkg_info.name == current_env_package.name
                        continue
                    end
                    println("      $(pkg_info.name) v$(pkg_info.version) => $(dev_packages[pkg_info.name])")
                    try
                        # Try to get canonical path using pkgdir
                        pkg_dir = pkgdir(pkg_info.name)
                        if pkg_dir !== nothing && pkg_dir != dev_packages[pkg_info.name]
                            println("         pkgdir(): $pkg_dir")
                        end
                    catch
                        # pkgdir might fail, that's okay
                    end
                end
                println()
            end

            # List regular packages second
            if !isempty(regular_deps)
                println("   📦 Other packages in environment:")
                for pkg_info in regular_deps
                    println("      $(pkg_info.name) v$(pkg_info.version)")
                end
            end

            # Handle empty environment
            if isempty(deps) && current_env_package === nothing
                println("   No packages in environment")
            end

        catch e
            println("   Error getting package status: $e")
        end

        println()
        println("🔄 Revise.jl Status:")
        try
            if isdefined(Main, :Revise)
                println("   ✅ Revise.jl is loaded and active")
                println("   📝 Development packages will auto-reload on changes")
            else
                println("   ⚠️  Revise.jl is not loaded")
            end
        catch
            println("   ❓ Could not determine Revise.jl status")
        end

        return nothing

    catch e
        println("Error generating environment report: $e")
        return nothing
    end
end

function start!(; socket_dir::String=get_project_dir(), force::Bool=false, verbose::Bool=true)
    # Check for existing server
    if check_existing_server(socket_dir)
        if force
            # Force cleanup and restart
            remove_pid_file(socket_dir)
            remove_socket_file(socket_dir)
        else
            error("MCP server already running. Check $(get_pid_path(socket_dir)) for the PID. Use force=true to restart.")
        end
    end

    SERVER[] !== nothing && stop!() # Stop existing server if running

    usage_instructions_tool = MCPTool(
        "usage_instructions",
        "Get detailed instructions for proper Julia REPL usage, best practices, and workflow guidelines for AI agents.",
        Dict(
            "type" => "object",
            "properties" => Dict(),
            "required" => []
        ),
        args -> begin
            try
                workflow_path = joinpath(dirname(dirname(@__FILE__)), "prompts", "julia_repl_workflow.md")
                if isfile(workflow_path)
                    return read(workflow_path, String)
                else
                    return "Error: julia_repl_workflow.md not found at $workflow_path"
                end
            catch e
                return "Error reading usage instructions: $e"
            end
        end
    )

    repl_tool = MCPTool(
        "exec_repl",
        """
        Execute Julia code in a shared, persistent REPL session to avoid startup latency.

        **PREREQUISITE**: Before using this tool, you MUST first call the `usage_instructions` tool to understand proper Julia REPL workflow, best practices, and etiquette for shared REPL usage.

        Once this function is available, **never** use `julia` commands in bash, always use the REPL.

        The tool returns raw text output containing: all printed content from stdout and stderr streams, plus the mime text/plain representation of the expression's return value (unless the expression ends with a semicolon).

        You may use this REPL to
        - execute julia code
        - execute test sets
        - get julia function documentation (i.e. send @doc functionname)
        - investigate the environment (use investigate_environment tool for comprehensive setup info)
        """,
        MCPRepl.text_parameter("expression", "Julia expression to evaluate (e.g., '2 + 3 * 4' or `import Pkg; Pkg.status()`"),
        args -> begin
            try
                execute_repllike(get(args, "expression", ""))
            catch e
                println("Error during execute_repllike", e)
                "Apparently there was an **internal** error to the MCP server: $e"
            end
        end
    )

    investigate_tool = MCPTool(
        "investigate_environment",
        """Investigate the current Julia environment including pwd, active project, packages, and development packages with their paths.

        This tool provides comprehensive information about:
        - Current working directory
        - Active project and its details
        - All packages in the environment with development status
        - Development packages with their file system paths
        - Current environment package status
        - Revise.jl status for hot reloading

        This is useful for understanding the development setup and debugging environment issues.""",
        Dict(
            "type" => "object",
            "properties" => Dict(),
            "required" => []
        ),
        args -> begin
            try
                execute_repllike("MCPRepl.repl_status_report()")
            catch e
                "Error investigating environment: $e"
            end
        end
    )

    # Create and start server
    socket_path = get_socket_path(socket_dir)
    SERVER[] = start_mcp_server([usage_instructions_tool, repl_tool, investigate_tool], socket_path; verbose=verbose)

    # Write PID file after server starts
    write_pid_file(socket_dir)

    # Register atexit hook for cleanup
    atexit() do
        if SERVER[] !== nothing
            stop!()
        end
    end

    if isdefined(Base, :active_repl)
        set_prefix!(Base.active_repl)
    else
        atreplinit(set_prefix!)
    end
    return nothing
end

function set_prefix!(repl)
    mode = get_mainmode(repl)
    mode.prompt = REPL.contextual_prompt(repl, "✻ julia> ")
end
function unset_prefix!(repl)
    mode = get_mainmode(repl)
    mode.prompt = REPL.contextual_prompt(repl, REPL.JULIA_PROMPT)
end
function get_mainmode(repl)
    only(filter(repl.interface.modes) do mode
        mode isa REPL.Prompt && mode.prompt isa Function && contains(mode.prompt(), "julia>")
    end)
end

function stop!()
    if SERVER[] !== nothing
        println("Stop existing server...")
        socket_dir = dirname(SERVER[].socket_path)
        stop_mcp_server(SERVER[])
        SERVER[] = nothing
        remove_pid_file(socket_dir)
        if isdefined(Base, :active_repl)
            unset_prefix!(Base.active_repl)
        end
    else
        println("No server running to stop.")
    end
    return nothing
end

end #module
