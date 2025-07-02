#!/usr/bin/env python3
"""
HTTP-to-MCP Bridge for MDEAutomator

This bridge provides HTTP endpoints (/mcp/discover, /mcp/execute) that Claude Desktop
can use, while maintaining full stdio MCP compatibility for direct connections.
"""

import asyncio
import json
import logging
import os
import sys
import threading
import time
from contextlib import asynccontextmanager
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Any, Dict, Optional
from urllib.parse import parse_qs, urlparse

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Add current directory to Python path
current_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, current_dir)


class MCPHttpBridge(BaseHTTPRequestHandler):
    """HTTP bridge that provides MCP endpoints for Claude Desktop"""
    
    def do_GET(self):
        """Handle GET requests"""
        parsed_path = urlparse(self.path)
        
        if parsed_path.path == '/health':
            self._handle_health()
        elif parsed_path.path == '/mcp/discover':
            self._handle_discover()
        else:
            self.send_response(404)
            self.end_headers()
    
    def do_POST(self):
        """Handle POST requests"""
        parsed_path = urlparse(self.path)
        
        if parsed_path.path == '/mcp/execute':
            self._handle_execute()
        elif parsed_path.path == '/mcp':
            self._handle_mcp_request()
        else:
            self.send_response(404)
            self.end_headers()
    
    def _handle_health(self):
        """Health check endpoint"""
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        
        response = {
            "status": "healthy",
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "service": "MDEAutomator MCP Bridge",
            "endpoints": {
                "health": "/health",
                "discover": "/mcp/discover", 
                "execute": "/mcp/execute",
                "mcp": "/mcp"
            }
        }
        self.wfile.write(json.dumps(response).encode())
    
    def _handle_discover(self):
        """MCP discovery endpoint for Claude Desktop"""
        try:
            # Get MCP server instance
            mcp_server = getattr(self.server, 'mcp_server_instance', None)
            if not mcp_server:
                raise Exception("MCP server not initialized")
            
            # Import tools to get available tools
            from tools import get_all_tools
            tools = get_all_tools()
            
            discovery_response = {
                "protocol": "mcp",
                "version": "2024-11-05",
                "capabilities": {
                    "tools": {
                        "listChanged": True
                    },
                    "logging": {}
                },
                "serverInfo": {
                    "name": "MDEAutomator MCP Server",
                    "version": "1.0.0",
                    "description": "Microsoft Defender for Endpoint operations via MCP"
                },
                "tools": [
                    {
                        "name": tool.name,
                        "description": tool.description,
                        "inputSchema": tool.inputSchema
                    }
                    for tool in tools
                ]
            }
            
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(discovery_response, indent=2).encode())
            
            logger.info(f"Discovery request served - {len(tools)} tools available")
            
        except Exception as e:
            logger.error(f"Discovery failed: {e}", exc_info=True)
            self._send_error(500, f"Discovery failed: {str(e)}")
    
    def _handle_execute(self):
        """MCP execute endpoint for Claude Desktop"""
        try:
            # Read request body
            content_length = int(self.headers.get('Content-Length', 0))
            if content_length == 0:
                self._send_error(400, "Missing request body")
                return
                
            body = self.rfile.read(content_length)
            request_data = json.loads(body.decode('utf-8'))
            
            # Get MCP server instance
            mcp_server = getattr(self.server, 'mcp_server_instance', None)
            if not mcp_server:
                raise Exception("MCP server not initialized")
            
            # Extract tool call information
            tool_name = request_data.get('tool')
            arguments = request_data.get('arguments', {})
            
            if not tool_name:
                self._send_error(400, "Missing 'tool' parameter")
                return
            
            logger.info(f"Executing tool: {tool_name} with args: {arguments}")
            
            # Execute the tool via MCP server
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            try:
                result = loop.run_until_complete(
                    mcp_server._route_tool_call(tool_name, arguments)
                )
                
                execute_response = {
                    "success": True,
                    "result": result,
                    "tool": tool_name,
                    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                }
                
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(json.dumps(execute_response, indent=2, default=str).encode())
                
                logger.info(f"Tool {tool_name} executed successfully")
                
            finally:
                loop.close()
            
        except Exception as e:
            logger.error(f"Execute failed: {e}", exc_info=True)
            self._send_error(500, f"Execution failed: {str(e)}")
    
    def _handle_mcp_request(self):
        """Handle standard MCP JSON-RPC requests"""
        try:
            # Read request body
            content_length = int(self.headers.get('Content-Length', 0))
            if content_length == 0:
                self._send_error(400, "Missing request body")
                return
                
            body = self.rfile.read(content_length)
            request_data = json.loads(body.decode('utf-8'))
            
            # Get MCP server instance
            mcp_server = getattr(self.server, 'mcp_server_instance', None)
            if not mcp_server:
                raise Exception("MCP server not initialized")
            
            # Handle different MCP methods
            method = request_data.get('method')
            params = request_data.get('params', {})
            request_id = request_data.get('id')
            
            if method == "initialize":
                result = {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {
                        "tools": {"listChanged": True},
                        "logging": {}
                    },
                    "serverInfo": {
                        "name": "MDEAutomator MCP Server",
                        "version": "1.0.0"
                    }
                }
                
            elif method == "tools/list":
                from tools import get_all_tools
                tools = get_all_tools()
                result = {
                    "tools": [
                        {
                            "name": tool.name,
                            "description": tool.description,
                            "inputSchema": tool.inputSchema
                        }
                        for tool in tools
                    ]
                }
                
            elif method == "tools/call":
                tool_name = params.get("name")
                arguments = params.get("arguments", {})
                
                # Execute the tool
                loop = asyncio.new_event_loop()
                asyncio.set_event_loop(loop)
                try:
                    tool_result = loop.run_until_complete(
                        mcp_server._route_tool_call(tool_name, arguments)
                    )
                    
                    result = {
                        "content": [
                            {
                                "type": "text",
                                "text": json.dumps(tool_result, indent=2, default=str)
                            }
                        ]
                    }
                finally:
                    loop.close()
                    
            else:
                self._send_error(400, f"Unknown method: {method}")
                return
            
            # Send JSON-RPC response
            response = {
                "jsonrpc": "2.0",
                "id": request_id,
                "result": result
            }
            
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            self.wfile.write(json.dumps(response, indent=2, default=str).encode())
            
        except Exception as e:
            logger.error(f"MCP request failed: {e}", exc_info=True)
            # Send JSON-RPC error response
            error_response = {
                "jsonrpc": "2.0",
                "id": request_data.get('id') if 'request_data' in locals() else None,
                "error": {
                    "code": -32603,
                    "message": "Internal error",
                    "data": str(e)
                }
            }
            
            self.send_response(500)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            self.wfile.write(json.dumps(error_response).encode())
    
    def _send_error(self, code: int, message: str):
        """Send HTTP error response"""
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        
        error_response = {
            "error": message,
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        }
        self.wfile.write(json.dumps(error_response).encode())
    
    def log_message(self, format, *args):
        # Reduce HTTP server log noise
        pass


class HybridMCPServer:
    """
    Hybrid MCP server that supports both stdio and HTTP endpoints
    """
    
    def __init__(self):
        self.mcp_server_instance = None
        self.http_server = None
        self.shutdown_event = threading.Event()
    
    async def initialize_mcp_server(self):
        """Initialize the core MCP server"""
        try:
            from config import MCPConfig
            from server import MDEAutomatorMCPServer
            
            logger.info("Initializing MCP server...")
            config = MCPConfig.from_environment()
            self.mcp_server_instance = MDEAutomatorMCPServer(config)
            
            # Initialize Function App client
            await self.mcp_server_instance.function_client.initialize()
            
            logger.info("✓ MCP server initialized successfully")
            return True
            
        except Exception as e:
            logger.error(f"Failed to initialize MCP server: {e}", exc_info=True)
            return False
    
    def start_http_bridge(self):
        """Start HTTP bridge server"""
        try:
            self.http_server = HTTPServer(('0.0.0.0', 8080), MCPHttpBridge)
            
            # Attach MCP server instance to HTTP server for access in handlers
            self.http_server.mcp_server_instance = self.mcp_server_instance
            
            logger.info("🌐 HTTP bridge started on port 8080")
            logger.info("📡 Available endpoints:")
            logger.info("  - GET  /health - Health check")
            logger.info("  - GET  /mcp/discover - MCP discovery (Claude Desktop)")
            logger.info("  - POST /mcp/execute - MCP execution (Claude Desktop)")
            logger.info("  - POST /mcp - Standard MCP JSON-RPC")
            
            self.http_server.serve_forever()
            
        except Exception as e:
            logger.error(f"HTTP bridge error: {e}")
    
    def signal_handler(self, signum, frame):
        """Handle shutdown signals"""
        logger.info(f"Received signal {signum}, shutting down...")
        self.shutdown_event.set()
        
        if self.http_server:
            self.http_server.shutdown()
    
    async def run_hybrid_server(self):
        """Run the hybrid MCP server with both stdio and HTTP support"""
        try:
            # Initialize MCP server
            if not await self.initialize_mcp_server():
                sys.exit(1)
            
            logger.info("🚀 Hybrid MCP Server ready!")
            logger.info("📞 stdio MCP: docker exec -i <container> python server.py")
            logger.info("🌐 HTTP MCP: https://your-app.azurewebsites.net/mcp/discover")
            
            # Keep alive loop
            while not self.shutdown_event.is_set():
                if self.shutdown_event.wait(timeout=60):
                    break
                logger.debug("💓 Server heartbeat")
            
        except Exception as e:
            logger.error(f"Server error: {e}", exc_info=True)
            sys.exit(1)
        finally:
            if self.mcp_server_instance and hasattr(self.mcp_server_instance, 'function_client'):
                await self.mcp_server_instance.function_client.close()
    
    def run(self):
        """Main entry point"""
        import signal
        
        logger.info("🏁 Starting Hybrid MDEAutomator MCP Server...")
        
        # Set up signal handlers
        signal.signal(signal.SIGTERM, self.signal_handler)
        signal.signal(signal.SIGINT, self.signal_handler)
        
        # Start HTTP bridge in background thread
        http_thread = threading.Thread(target=self.start_http_bridge, daemon=True)
        http_thread.start()
        
        # Run the main server
        try:
            asyncio.run(self.run_hybrid_server())
        except KeyboardInterrupt:
            logger.info("⌨️ Keyboard interrupt received")
        except Exception as e:
            logger.error(f"❌ Server failed: {e}", exc_info=True)
            sys.exit(1)
        
        logger.info("🛑 Server shutdown complete")


if __name__ == "__main__":
    server = HybridMCPServer()
    server.run()
