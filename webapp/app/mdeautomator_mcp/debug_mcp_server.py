#!/usr/bin/env python3
"""
Debug version of the hybrid MCP server that provides detailed error information
"""

import asyncio
import json
import logging
import os
import sys
import traceback
from http.server import HTTPServer, BaseHTTPRequestHandler

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

class DebugHttpHandler(BaseHTTPRequestHandler):
    """Debug HTTP handler that shows initialization status"""
    
    def do_GET(self):
        """Handle GET requests"""
        if self.path == '/debug':
            self._handle_debug()
        elif self.path == '/health':
            self._handle_health()
        elif self.path == '/mcp/discover':
            self._handle_debug_discover()
        else:
            self.send_response(404)
            self.end_headers()
    
    def _handle_debug(self):
        """Debug endpoint that shows detailed system status"""
        debug_info = {
            "environment_variables": {
                "FUNCTION_APP_BASE_URL": os.getenv("FUNCTION_APP_BASE_URL", "NOT SET"),
                "FUNCTION_KEY": "SET" if os.getenv("FUNCTION_KEY") else "NOT SET",
                "AZURE_CLIENT_ID": os.getenv("AZURE_CLIENT_ID", "NOT SET"),
                "KEY_VAULT_URL": os.getenv("KEY_VAULT_URL", "NOT SET"),
            },
            "python_path": sys.path,
            "current_directory": os.getcwd(),
            "files_in_directory": os.listdir("."),
        }
        
        # Test MCP server initialization
        try:
            from config import MCPConfig
            config = MCPConfig.from_environment()
            debug_info["config"] = {
                "function_app_base_url": config.function_app_base_url,
                "function_key": "SET" if config.function_key else "NOT SET",
                "azure_client_id": config.azure_client_id,
                "key_vault_url": config.key_vault_url,
            }
            debug_info["config_status"] = "SUCCESS"
        except Exception as e:
            debug_info["config_status"] = f"FAILED: {str(e)}"
            debug_info["config_error"] = traceback.format_exc()
        
        # Test MCP server creation
        try:
            from server import MDEAutomatorMCPServer
            from config import MCPConfig
            config = MCPConfig.from_environment()
            server = MDEAutomatorMCPServer(config)
            debug_info["server_creation"] = "SUCCESS"
        except Exception as e:
            debug_info["server_creation"] = f"FAILED: {str(e)}"
            debug_info["server_error"] = traceback.format_exc()
        
        # Test function client initialization
        try:
            from function_client import FunctionAppClient
            from config import MCPConfig
            config = MCPConfig.from_environment()
            client = FunctionAppClient(config)
            debug_info["function_client_creation"] = "SUCCESS"
            
            # Test async initialization (this is likely where it fails)
            async def test_init():
                try:
                    await client.initialize()
                    return "SUCCESS"
                except Exception as e:
                    return f"FAILED: {str(e)}"
            
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            result = loop.run_until_complete(test_init())
            loop.close()
            debug_info["function_client_init"] = result
            
        except Exception as e:
            debug_info["function_client_creation"] = f"FAILED: {str(e)}"
            debug_info["function_client_error"] = traceback.format_exc()
        
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        self.wfile.write(json.dumps(debug_info, indent=2, default=str).encode())
    
    def _handle_health(self):
        """Health check endpoint"""
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        response = {"status": "healthy", "message": "Debug server running"}
        self.wfile.write(json.dumps(response).encode())
    
    def _handle_debug_discover(self):
        """Debug version of discover endpoint"""
        self.send_response(500)
        self.send_header('Content-Type', 'application/json')
        self.end_headers()
        response = {
            "error": "MCP server not initialized - use /debug endpoint for details",
            "debug_url": "/debug"
        }
        self.wfile.write(json.dumps(response).encode())
    
    def log_message(self, format, *args):
        # Reduce HTTP server log noise
        pass


if __name__ == "__main__":
    logger.info("🐛 Starting Debug MCP Server on port 8080...")
    server = HTTPServer(('0.0.0.0', 8080), DebugHttpHandler)
    logger.info("📡 Debug endpoints available:")
    logger.info("  - GET  /health - Health check")
    logger.info("  - GET  /debug - Detailed debug information")
    logger.info("  - GET  /mcp/discover - Shows why MCP init failed")
    
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("🛑 Debug server stopped")
