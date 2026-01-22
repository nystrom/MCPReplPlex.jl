#!/usr/bin/env python3
"""
MCP Julia REPL Adapter

This adapter implements an MCP server that forwards REPL commands to Unix socket-based
Julia REPL servers. Each tool call specifies a project directory to locate the correct
Julia server socket.

Usage:
    python julia-repl-mcp.py [options]

Options:
    --transport stdio|http    Transport mode (default: stdio)
    --port PORT               Port for HTTP mode (default: 3000)

The Julia MCP server must be running in each project directory:
    julia --project -e "using MCPRepl; MCPRepl.start!()"
"""

import argparse
import json
import os
import socket
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Optional, Dict, Any

SOCKET_NAME = ".mcp-repl.sock"
PID_NAME = ".mcp-repl.pid"


def find_socket_path(start_dir: str) -> Optional[str]:
    """
    Walk up the directory tree from start_dir looking for .mcp-repl.sock.
    Returns the socket path if found, None otherwise.
    """
    current = os.path.abspath(start_dir)
    while True:
        socket_path = os.path.join(current, SOCKET_NAME)
        if os.path.exists(socket_path):
            return socket_path
        parent = os.path.dirname(current)
        if parent == current:
            return None
        current = parent


def check_server_running(socket_path: str) -> bool:
    """
    Check if the MCP server is running by verifying the PID file.
    Returns True if server appears to be running, False otherwise.
    """
    pid_path = os.path.join(os.path.dirname(socket_path), PID_NAME)

    if not os.path.exists(pid_path):
        return False

    try:
        with open(pid_path, 'r') as f:
            pid = int(f.read().strip())
        os.kill(pid, 0)
        return True
    except (ValueError, ProcessLookupError, PermissionError, FileNotFoundError):
        return False


def send_to_julia_server(socket_path: str, request: Dict[str, Any]) -> Dict[str, Any]:
    """
    Send a JSON-RPC request to the Julia server and return the response.
    """
    try:
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.connect(socket_path)
        sock_file = sock.makefile('rwb')

        # Send request
        sock_file.write((json.dumps(request) + '\n').encode('utf-8'))
        sock_file.flush()

        # Read response
        response_line = sock_file.readline()
        if not response_line:
            raise ConnectionError("Server closed connection")

        response = json.loads(response_line.decode('utf-8'))

        sock_file.close()
        sock.close()

        return response

    except socket.error as e:
        raise Exception(f"Socket error: {e}. Is the Julia MCP server running?")


def create_error_response(request_id, code: int, message: str) -> Dict[str, Any]:
    """Create a JSON-RPC error response."""
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "error": {
            "code": code,
            "message": message
        }
    }


def create_success_response(request_id, result: Any) -> Dict[str, Any]:
    """Create a JSON-RPC success response."""
    return {
        "jsonrpc": "2.0",
        "id": request_id,
        "result": result
    }


def handle_exec_repl(args: Dict[str, Any]) -> str:
    """
    Handle exec_repl tool call.
    Takes project_dir and expression, forwards to Julia server.
    """
    project_dir = args.get("project_dir", "")
    expression = args.get("expression", "")

    if not project_dir:
        return "Error: project_dir parameter is required"

    if not expression:
        return "Error: expression parameter is required"

    # Find socket
    socket_path = find_socket_path(project_dir)
    if socket_path is None:
        return f"Error: MCP REPL server not found in {project_dir}. Start the server with:\n  julia --project -e 'using MCPRepl; MCPRepl.start!()'"

    if not check_server_running(socket_path):
        return f"Error: MCP REPL server not running (socket exists but process dead). Start the server with:\n  julia --project -e 'using MCPRepl; MCPRepl.start!()'"

    # Forward to Julia server's exec_repl tool
    julia_request = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": "exec_repl",
            "arguments": {
                "expression": expression
            }
        }
    }

    try:
        response = send_to_julia_server(socket_path, julia_request)
        if "error" in response:
            return f"Error from Julia server: {response['error']['message']}"
        if "result" in response and "content" in response["result"]:
            # Extract text from MCP response
            content = response["result"]["content"]
            if isinstance(content, list) and len(content) > 0:
                return content[0].get("text", "")
        return str(response.get("result", ""))
    except Exception as e:
        return f"Error communicating with Julia server: {e}"


def handle_investigate_environment(args: Dict[str, Any]) -> str:
    """
    Handle investigate_environment tool call.
    Takes project_dir, forwards to Julia server.
    """
    project_dir = args.get("project_dir", "")

    if not project_dir:
        return "Error: project_dir parameter is required"

    socket_path = find_socket_path(project_dir)
    if socket_path is None:
        return f"Error: MCP REPL server not found in {project_dir}"

    if not check_server_running(socket_path):
        return f"Error: MCP REPL server not running"

    julia_request = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": "investigate_environment",
            "arguments": {}
        }
    }

    try:
        response = send_to_julia_server(socket_path, julia_request)
        if "error" in response:
            return f"Error from Julia server: {response['error']['message']}"
        if "result" in response and "content" in response["result"]:
            content = response["result"]["content"]
            if isinstance(content, list) and len(content) > 0:
                return content[0].get("text", "")
        return str(response.get("result", ""))
    except Exception as e:
        return f"Error communicating with Julia server: {e}"


def handle_usage_instructions(args: Dict[str, Any]) -> str:
    """
    Handle usage_instructions tool call.
    Takes project_dir, forwards to Julia server.
    """
    project_dir = args.get("project_dir", "")

    if not project_dir:
        return "Error: project_dir parameter is required"

    socket_path = find_socket_path(project_dir)
    if socket_path is None:
        return f"Error: MCP REPL server not found in {project_dir}"

    if not check_server_running(socket_path):
        return f"Error: MCP REPL server not running"

    julia_request = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/call",
        "params": {
            "name": "usage_instructions",
            "arguments": {}
        }
    }

    try:
        response = send_to_julia_server(socket_path, julia_request)
        if "error" in response:
            return f"Error from Julia server: {response['error']['message']}"
        if "result" in response and "content" in response["result"]:
            content = response["result"]["content"]
            if isinstance(content, list) and len(content) > 0:
                return content[0].get("text", "")
        return str(response.get("result", ""))
    except Exception as e:
        return f"Error communicating with Julia server: {e}"


# MCP Tool definitions
TOOLS = [
    {
        "name": "exec_repl",
        "description": """Execute Julia code in a shared, persistent REPL session.

**PREREQUISITE**: Before using this tool, you MUST first call the `usage_instructions` tool.

The tool returns raw text output containing: all printed content from stdout and stderr streams, plus the mime text/plain representation of the expression's return value (unless the expression ends with a semicolon).

You may use this REPL to execute julia code, run test sets, get function documentation, etc.""",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {
                    "type": "string",
                    "description": "Directory where the Julia project is located (used to find the REPL socket)"
                },
                "expression": {
                    "type": "string",
                    "description": "Julia expression to evaluate (e.g., '2 + 3 * 4' or `import Pkg; Pkg.status()`)"
                }
            },
            "required": ["project_dir", "expression"]
        },
        "handler": handle_exec_repl
    },
    {
        "name": "investigate_environment",
        "description": """Investigate the current Julia environment including pwd, active project, packages, and development packages with their paths.

This tool provides comprehensive information about:
- Current working directory
- Active project and its details
- All packages in the environment with development status
- Development packages with their file system paths
- Current environment package status
- Revise.jl status for hot reloading""",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {
                    "type": "string",
                    "description": "Directory where the Julia project is located"
                }
            },
            "required": ["project_dir"]
        },
        "handler": handle_investigate_environment
    },
    {
        "name": "usage_instructions",
        "description": "Get detailed instructions for proper Julia REPL usage, best practices, and workflow guidelines.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "project_dir": {
                    "type": "string",
                    "description": "Directory where the Julia project is located"
                }
            },
            "required": ["project_dir"]
        },
        "handler": handle_usage_instructions
    }
]


def process_mcp_request(request: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Process an MCP request and return a response."""
    method = request.get("method")
    request_id = request.get("id")

    # Handle initialization
    if method == "initialize":
        return create_success_response(request_id, {
            "protocolVersion": "2024-11-05",
            "capabilities": {
                "tools": {}
            },
            "serverInfo": {
                "name": "julia-mcp-adapter",
                "version": "1.0.0"
            }
        })

    # Handle initialized notification
    if method == "notifications/initialized":
        return None  # No response for notifications

    # Handle tool listing
    if method == "tools/list":
        tool_list = [
            {
                "name": tool["name"],
                "description": tool["description"],
                "inputSchema": tool["inputSchema"]
            } for tool in TOOLS
        ]
        return create_success_response(request_id, {"tools": tool_list})

    # Handle tool calls
    if method == "tools/call":
        params = request.get("params", {})
        tool_name = params.get("name", "")
        args = params.get("arguments", {})

        # Find tool
        tool = next((t for t in TOOLS if t["name"] == tool_name), None)
        if tool is None:
            return create_error_response(request_id, -32602, f"Tool not found: {tool_name}")

        # Call tool handler
        try:
            result_text = tool["handler"](args)
            return create_success_response(request_id, {
                "content": [
                    {
                        "type": "text",
                        "text": result_text
                    }
                ]
            })
        except Exception as e:
            return create_error_response(request_id, -32603, f"Tool execution error: {e}")

    # Method not found
    return create_error_response(request_id, -32601, f"Method not found: {method}")


def run_stdio_mode():
    """Run in stdio mode - read from stdin, write to stdout."""
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue

        try:
            request = json.loads(line)
            response = process_mcp_request(request)

            # Only send response if not a notification
            if response is not None:
                print(json.dumps(response), flush=True)

        except json.JSONDecodeError as e:
            error_response = create_error_response(None, -32700, f"Parse error: {e}")
            print(json.dumps(error_response), flush=True)

        except Exception as e:
            error_response = create_error_response(None, -32603, f"Internal error: {e}")
            print(json.dumps(error_response), flush=True)


class MCPHTTPHandler(BaseHTTPRequestHandler):
    """HTTP handler for MCP requests."""

    def log_message(self, format, *args):
        """Suppress HTTP server logging."""
        pass

    def send_json_response(self, response: dict, status: int = 200):
        """Send a JSON response."""
        response_body = json.dumps(response).encode('utf-8')
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(response_body)))
        self.send_header('Access-Control-Allow-Origin', '*')
        self.end_headers()
        self.wfile.write(response_body)

    def do_OPTIONS(self):
        """Handle CORS preflight requests."""
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'POST, GET, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def do_GET(self):
        """Handle GET requests (for health checks)."""
        if self.path == '/health':
            self.send_json_response({"status": "ok"})
        else:
            self.send_json_response(
                create_error_response(None, -32600, "Use POST for JSON-RPC requests"),
                400
            )

    def do_POST(self):
        """Handle POST requests with JSON-RPC."""
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            if content_length == 0:
                self.send_json_response(
                    create_error_response(None, -32600, "Empty request body"),
                    400
                )
                return

            body = self.rfile.read(content_length).decode('utf-8')
            request = json.loads(body)

            response = process_mcp_request(request)
            if response is not None:
                self.send_json_response(response)

        except json.JSONDecodeError as e:
            self.send_json_response(
                create_error_response(None, -32700, f"Parse error: {e}"),
                400
            )
        except Exception as e:
            self.send_json_response(
                create_error_response(None, -32603, f"Internal error: {e}"),
                500
            )


def run_http_mode(port: int):
    """Run in HTTP mode - serve HTTP requests."""
    server = HTTPServer(('localhost', port), MCPHTTPHandler)
    print(f"MCP Julia REPL Adapter running on http://localhost:{port}", file=sys.stderr)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down HTTP server", file=sys.stderr)
    finally:
        server.shutdown()


def main():
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description='MCP Julia REPL Adapter - MCP server that forwards to Julia REPL servers'
    )
    parser.add_argument(
        '--transport',
        choices=['stdio', 'http'],
        default='stdio',
        help='Transport mode (default: stdio)'
    )
    parser.add_argument(
        '--port',
        type=int,
        default=3000,
        help='Port for HTTP mode (default: 3000)'
    )

    args = parser.parse_args()

    # Run in appropriate mode
    if args.transport == 'stdio':
        run_stdio_mode()
    else:
        run_http_mode(args.port)


if __name__ == "__main__":
    main()
