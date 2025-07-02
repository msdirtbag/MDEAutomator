#!/usr/bin/env python3
"""
Fixed Hybrid MCP server that properly handles initialization timing
"""

import asyncio
import json
import logging
import os
import sys
import threading
import time
import traceback
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Any, Dict, Optional

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Add current directory to Python path
current_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, current_dir)

# Global server state
server_state = {
    "mcp_server": None,
    "initialized": False,
    "initialization_error": None
}

class FixedMCPHttpBridge(BaseHTTPRequestHandler):
    """Fixed HTTP bridge that waits for proper MCP initialization"""
    
    def do_GET(self):
        """Handle GET requests"""
        if self.path == '/health':
            self._handle_health()
        elif self.path == '/mcp/discover':
            self._handle_discover()
        elif self.path == '/debug':
            self._handle_debug()
        else:
            self.send_response(404)
            self.end_headers()
    
    def do_POST(self):
        """Handle POST requests"""
        if self.path == '/mcp/execute':
            self._handle_execute()
        elif self.path == '/mcp':
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
            "mcp_initialized": server_state["initialized"],
            "initialization_error": server_state["initialization_error"]
        }
        self.wfile.write(json.dumps(response).encode())
    
    def _handle_debug(self):
        """Debug endpoint"""
        debug_info = {
            "server_state": {
                "initialized": server_state["initialized"],
                "mcp_server_exists": server_state["mcp_server"] is not None,
                "initialization_error": server_state["initialization_error"]
            },
            "environment": {
                "FUNCTION_APP_BASE_URL": os.getenv("FUNCTION_APP_BASE_URL", "NOT SET"),
                "FUNCTION_KEY": "SET" if os.getenv("FUNCTION_KEY") else "NOT SET"
            }
        }
        
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(debug_info, indent=2).encode())
    
    def _handle_discover(self):
        """MCP discovery endpoint"""
        if not server_state["initialized"]:
            self._send_error(503, f"MCP server not ready: {server_state['initialization_error']}")
            return
            
        try:
            from tools import get_all_tools
            tools = get_all_tools()
            
            discovery_response = {
                "protocol": "mcp",
                "version": "2024-11-05",
                "capabilities": {
                    "tools": {"listChanged": True},
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
            
            logger.info(f"Discovery served - {len(tools)} tools available")
            
        except Exception as e:
            logger.error(f"Discovery failed: {e}", exc_info=True)
            self._send_error(500, f"Discovery failed: {str(e)}")
    
    def _handle_execute(self):
        """MCP execute endpoint"""
        if not server_state["initialized"]:
            self._send_error(503, f"MCP server not ready: {server_state['initialization_error']}")
            return
            
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            if content_length == 0:
                self._send_error(400, "Missing request body")
                return
                
            body = self.rfile.read(content_length)
            request_data = json.loads(body.decode('utf-8'))
            
            tool_name = request_data.get('tool')
            arguments = request_data.get('arguments', {})
            
            if not tool_name:
                self._send_error(400, "Missing 'tool' parameter")
                return
            
            logger.info(f"Executing tool: {tool_name} with args: {arguments}")
            
            # Execute via MCP server
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            try:
                result = loop.run_until_complete(
                    server_state["mcp_server"]._route_tool_call(tool_name, arguments)
                )
                
                response = {
                    "success": True,
                    "result": result,
                    "tool": tool_name,
                    "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
                }
                
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                self.wfile.write(json.dumps(response, indent=2, default=str).encode())
                
            finally:
                loop.close()
            
        except Exception as e:
            logger.error(f"Execute failed: {e}", exc_info=True)
            self._send_error(500, f"Execution failed: {str(e)}")
    
    def _handle_mcp_request(self):
        """Handle standard MCP JSON-RPC requests"""
        if not server_state["initialized"]:
            self._send_error(503, f"MCP server not ready: {server_state['initialization_error']}")
            return
            
        try:
            content_length = int(self.headers.get('Content-Length', 0))
            if content_length == 0:
                self._send_error(400, "Missing request body")
                return
                
            body = self.rfile.read(content_length)
            request_data = json.loads(body.decode('utf-8'))
            
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
                
                loop = asyncio.new_event_loop()
                asyncio.set_event_loop(loop)
                try:
                    tool_result = loop.run_until_complete(
                        server_state["mcp_server"]._route_tool_call(tool_name, arguments)
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
            "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "code": code
        }
        self.wfile.write(json.dumps(error_response).encode())
    
    def log_message(self, format, *args):
        pass  # Reduce HTTP server log noise


async def initialize_mcp_server():
    """Initialize the MCP server asynchronously"""
    try:
        logger.info("🔧 Initializing MCP server...")
        
        from config import MCPConfig
        from server import MDEAutomatorMCPServer
        
        config = MCPConfig.from_environment()
        mcp_server = MDEAutomatorMCPServer(config)
        
        # Initialize Function App client
        await mcp_server.function_client.initialize()
        
        # Update global state
        server_state["mcp_server"] = mcp_server
        server_state["initialized"] = True
        server_state["initialization_error"] = None
        
        logger.info("✅ MCP server initialized successfully")
        return True
        
    except Exception as e:
        error_msg = f"MCP initialization failed: {str(e)}"
        logger.error(error_msg, exc_info=True)
        server_state["initialization_error"] = error_msg
        return False


def start_http_server():
    """Start HTTP server in a separate thread"""
    server = HTTPServer(('0.0.0.0', 8080), FixedMCPHttpBridge)
    logger.info("🌐 HTTP server started on port 8080")
    server.serve_forever()


async def main():
    """Main entry point"""
    logger.info("🚀 Starting Fixed Hybrid MCP Server...")
    
    # Start HTTP server in background thread
    http_thread = threading.Thread(target=start_http_server, daemon=True)
    http_thread.start()
    
    # Initialize MCP server
    success = await initialize_mcp_server()
    
    if success:
        logger.info("🎉 Server ready!")
        logger.info("📡 Available endpoints:")
        logger.info("  - GET  /health - Health check")
        logger.info("  - GET  /debug - Debug information")
        logger.info("  - GET  /mcp/discover - MCP discovery")
        logger.info("  - POST /mcp/execute - MCP execution")
        logger.info("  - POST /mcp - Standard MCP JSON-RPC")
    else:
        logger.error("❌ Server initialization failed")
        logger.error("🔧 Use /debug endpoint for details")
    
    # Keep alive
    try:
        while True:
            await asyncio.sleep(60)
            if server_state["initialized"]:
                logger.debug("💓 Server heartbeat - MCP ready")
            else:
                logger.warning("⚠️ Server heartbeat - MCP not ready")
    except KeyboardInterrupt:
        logger.info("⌨️ Shutdown requested")
    except Exception as e:
        logger.error(f"❌ Server error: {e}", exc_info=True)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        logger.info("🛑 Server stopped")
    except Exception as e:
        logger.error(f"💥 Fatal error: {e}", exc_info=True)
        sys.exit(1)
