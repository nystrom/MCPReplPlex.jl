# MCPRepl.jl

I strongly believe that REPL-driven development is the best thing you can do in Julia, so AI Agents should learn it too!

MCPRepl.jl is a Julia package which exposes your REPL as an MCP server -- so that the agent can connect to it and execute code in your environment.
The code the Agent sends will show up in the REPL as well as your own commands. You're both working in the same state.


Ideally, this enables the Agent to, for example, execute and fix testsets interactively one by one, circumventing any time-to-first-plot issues.

> [!TIP]
> I am not sure how much work I'll put in this package in the future, check out @kahliburke's much more active [fork](https://github.com/kahliburke/MCPRepl.jl).

## Showcase

https://github.com/user-attachments/assets/1c7546c4-23a3-4528-b222-fc8635af810d

## Installation

### Julia Package

This package is not registered in the official Julia General registry due to the security implications of its use. To install it, you must do so directly from the source repository.

You can add the package using the Julia package manager:

```julia
pkg> add https://github.com/hexaeder/MCPRepl.jl
```
or
```julia
pkg> dev https://github.com/hexaeder/MCPRepl.jl
```

### Python Adapter

The MCP adapter (`julia-repl-mcp.py`) has no external dependencies and uses only Python standard library modules. Python 3.8 or later is required.

Run the adapter directly with your system Python:

```bash
python3 julia-repl-mcp.py
```

## Usage

MCPRepl.jl uses a two-part architecture:
1. **Julia REPL Server**: Runs in your Julia session and executes code
2. **MCP Adapter**: Routes MCP client requests to the correct Julia server

### Step 1: Start the Julia REPL Server

In your Julia REPL, start the server:

```julia-repl
julia> using MCPRepl
julia> MCPRepl.start!()
🚀 MCP Server running on /path/to/project/.mcp-repl.sock with 3 tools
```

This creates a Unix socket file (`.mcp-repl.sock`) in your active project directory. The socket allows MCP clients to communicate with your REPL session.

### Step 2: Configure MCP Clients

Configure your MCP client to use the adapter. The adapter takes a `project_dir` parameter in each tool call to locate the correct Julia server socket.

#### Claude Code

```sh
claude mcp add julia-repl python /path/to/MCPRepl.jl/julia-repl-mcp.py
```

Replace `/path/to/MCPRepl.jl` with the actual path to this repository.

#### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json` (macOS) or `%APPDATA%\Claude\claude_desktop_config.json` (Windows):

```json
{
  "mcpServers": {
    "julia-repl": {
      "command": "python",
      "args": ["/path/to/MCPRepl.jl/julia-repl-mcp.py"]
    }
  }
}
```

#### Codeium (Windsurf)

Add to your Windsurf MCP configuration:

```json
{
  "mcpServers": {
    "julia-repl": {
      "command": "python",
      "args": ["/path/to/MCPRepl.jl/julia-repl-mcp.py"]
    }
  }
}
```

#### Gemini CLI

Add to `~/.config/gemini/mcp_config.json`:

```json
{
  "mcpServers": {
    "julia-repl": {
      "command": "python",
      "args": ["/path/to/MCPRepl.jl/julia-repl-mcp.py"]
    }
  }
}
```

### Using the Tools

Once configured, your MCP client can call these tools:

- **`exec_repl(project_dir, expression)`**: Execute Julia code in the REPL
- **`investigate_environment(project_dir)`**: Get information about packages and environment
- **`usage_instructions(project_dir)`**: Get best practices for using the REPL

The `project_dir` parameter tells the adapter where to find the Julia server socket (by walking up from that directory to find `.mcp-repl.sock`).

### Example Workflow

1. Start Julia in your project directory and run `MCPRepl.start!()`
2. Ask your AI assistant to execute Julia code
3. The assistant calls `exec_repl(project_dir="/path/to/your/project", expression="2 + 2")`
4. The adapter finds the socket and forwards the request
5. Your Julia REPL executes the code and returns the result
6. Both you and the AI see the same REPL state

## Disclaimer and Security Warning

The core functionality of MCPRepl.jl involves opening a network port and executing any code that is sent to it. This is inherently dangerous and borderline stupid, but that's how it is in the great new world of coding agents.

By using this software, you acknowledge and accept the following:

*   **Risk of Arbitrary Code Execution:** Anyone who can connect to the open port will be able to execute arbitrary code on the host machine with the same privileges as the Julia process.
*   **No Warranties:** This software is provided "as is" without any warranties of any kind. The developers are not responsible for any damage, data loss, or other security breaches that may result from its use.

It is strongly recommended that you only use this package on isolated systems or networks where you have complete control over who can access the port. **Use at your own risk.**


## Similar Packages
- [ModelContexProtocol.jl](https://github.com/JuliaSMLM/ModelContextProtocol.jl) offers a way of defining your own servers. Since MCPRepl is using a HTTP server I decieded to not go with this package.

- [REPLicant.jl](https://github.com/MichaelHatherly/REPLicant.jl) is very similar, but the focus of MCPRepl.jl is to integrate with the user repl so you can see what your agent is doing.
