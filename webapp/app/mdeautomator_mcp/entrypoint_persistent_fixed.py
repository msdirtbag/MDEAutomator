#!/usr/bin/env python3
"""
Persistent MCP Server Entrypoint for Azure Container Apps

This entrypoint keeps the MCP server alive in Container Apps by implementing
a proper keep-alive mechanism while maintaining MCP protocol compatibility.
"""

import asyncio
import json
import logging
import os
import signal
import sys
import threading
import time
import urllib.request
from http.server import HTTPServer, BaseHTTPRequestHandler
from typing import Optional

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Add current directory to Python path
current_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, current_dir)


class HealthHandler(BaseHTTPRequestHandler):
    """Simple HTTP health check handler for Container Apps"""
    
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            response = {
                "status": "healthy",
                "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "service": "MDEAutomator MCP Server",
                "uptime": round(time.time() - start_time, 2) if 'start_time' in globals() else 0,
                "requests_handled": getattr(self, '_request_count', 0) + 1,
                "last_activity": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
            }
            # Track request count to show activity
            HealthHandler._request_count = getattr(HealthHandler, '_request_count', 0) + 1
            self.wfile.write(json.dumps(response).encode())
        elif self.path == '/status':
            # Additional endpoint to show more activity
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.end_headers()
            response = {
                "service": "MDEAutomator MCP Server",
                "mode": "persistent",
                "container_optimized": True,
                "keep_alive_active": True
            }
            self.wfile.write(json.dumps(response).encode())
        else:
            self.send_response(404)
            self.end_headers()
    
    def log_message(self, format, *args):
        # Suppress HTTP server logs to reduce noise
        pass


class PersistentMCPServer:
    """
    Persistent MCP server wrapper for Azure Container Apps.
    
    This class ensures the MCP server stays alive and doesn't exit with code 1
    by implementing a proper keep-alive mechanism.
    """
    
    def __init__(self):
        self.shutdown_event = threading.Event()
        self.http_server: Optional[HTTPServer] = None
        self.mcp_server = None
        self.startup_complete = False
        
    def signal_handler(self, signum, frame):
        """Handle shutdown signals gracefully"""
        logger.info(f"Received signal {signum}, initiating graceful shutdown...")
        self.shutdown_event.set()
        
        # Shutdown HTTP server
        if self.http_server:
            try:
                self.http_server.shutdown()
                logger.info("HTTP health server shutdown complete")
            except Exception as e:
                logger.error(f"Error shutting down HTTP server: {e}")
                
    def start_health_server(self):
        """Start HTTP health check server in background thread"""
        try:
            self.http_server = HTTPServer(('0.0.0.0', 8080), HealthHandler)
            logger.info("Health check server started on port 8080")
            self.http_server.serve_forever()
        except Exception as e:
            logger.error(f"Health server error: {e}")
            # Don't exit on health server failure - MCP server can still work
    
    def keep_alive_http_requests(self):
        """Send periodic HTTP requests to self to prevent Container Apps from scaling down"""
        while not self.shutdown_event.is_set():
            try:
                # Wait 2 minutes between keep-alive requests
                if self.shutdown_event.wait(timeout=120):
                    break
                
                # Send keep-alive request to our own health endpoint
                try:
                    req = urllib.request.Request('http://localhost:8080/health')
                    with urllib.request.urlopen(req, timeout=5) as response:
                        if response.status == 200:
                            logger.debug("💓 Keep-alive HTTP request successful")
                        else:
                            logger.warning(f"Keep-alive request returned status: {response.status}")
                except Exception as e:
                    logger.warning(f"Keep-alive request failed: {e}")
                    # Continue anyway - this is just keep-alive traffic
                    
            except Exception as e:
                logger.error(f"Error in keep-alive thread: {e}")
                # Sleep a bit and continue
                time.sleep(30)
    
    async def initialize_mcp_server(self):
        """Initialize the MCP server and Function App client"""
        try:
            from config import MCPConfig
            from server import MDEAutomatorMCPServer
            
            logger.info("Loading configuration...")
            config = MCPConfig.from_environment()
            
            logger.info("Creating MCP server...")
            self.mcp_server = MDEAutomatorMCPServer(config)
            
            logger.info("Initializing Function App client...")
            await self.mcp_server.function_client.initialize()
            
            logger.info("✓ MCP server initialized successfully")
            self.startup_complete = True
            return True
            
        except Exception as e:
            logger.error(f"Failed to initialize MCP server: {e}", exc_info=True)
            return False
    
    async def run_persistent_server(self):
        """
        Run the server in persistent mode for Container Apps.
        
        This is the key method that prevents exit code 1 by keeping the
        server alive indefinitely until a shutdown signal is received.
        """
        try:
            # Initialize MCP server components
            if not await self.initialize_mcp_server():
                logger.error("MCP server initialization failed, exiting")
                sys.exit(1)
            
            logger.info("🚀 Server is ready and waiting for connections...")
            logger.info("📡 Container will remain alive for MCP connections")
            logger.info("🔗 Connect via: docker exec -i <container> python server.py")
            
            # This is the critical keep-alive loop that prevents exit code 1
            heartbeat_count = 0
            while not self.shutdown_event.is_set():
                try:
                    # Wait for 30 seconds or until shutdown signal
                    if self.shutdown_event.wait(timeout=30):
                        logger.info("Shutdown signal received, breaking keep-alive loop")
                        break
                    
                    # Heartbeat logging every 10 minutes to show we're alive
                    heartbeat_count += 1
                    if heartbeat_count % 20 == 0:  # Every 20 * 30s = 10 minutes
                        logger.info(f"💓 Server heartbeat - uptime: {heartbeat_count * 30} seconds")
                    
                    # Generate HTTP traffic every 2 minutes to prevent Container Apps from shutting down
                    if heartbeat_count % 4 == 0:  # Every 4 * 30s = 2 minutes
                        try:
                            import urllib.request
                            with urllib.request.urlopen('http://localhost:8080/health', timeout=5) as response:
                                if response.status == 200:
                                    logger.debug("✓ Self-health check successful")
                        except Exception as e:
                            logger.warning(f"Self-health check failed: {e}")
                        
                    # Optional: Perform health check on Function Apps
                    if heartbeat_count % 120 == 0:  # Every hour
                        try:
                            if self.mcp_server and self.mcp_server.function_client:
                                health_ok = await self.mcp_server.function_client.health_check()
                                logger.info(f"🩺 Function Apps health check: {'✓ OK' if health_ok else '⚠ Warning'}")
                        except Exception as e:
                            logger.warning(f"Health check failed: {e}")
                            
                except Exception as e:
                    logger.error(f"Error in keep-alive loop: {e}")
                    # Don't exit on errors - keep trying
                    await asyncio.sleep(5)
                    
            logger.info("Keep-alive loop ended, proceeding to cleanup...")
                    
        except Exception as e:
            logger.error(f"Critical server error: {e}", exc_info=True)
            sys.exit(1)
        finally:
            # Cleanup resources
            await self.cleanup()
    
    async def cleanup(self):
        """Clean up resources during shutdown"""
        logger.info("Starting cleanup...")
        
        try:
            if self.mcp_server and hasattr(self.mcp_server, 'function_client'):
                await self.mcp_server.function_client.close()
                logger.info("✓ Function App client closed")
        except Exception as e:
            logger.error(f"Error closing Function App client: {e}")
        
        logger.info("✓ Cleanup complete")

    def run(self):
        """Main entry point for the persistent server"""
        global start_time
        start_time = time.time()
        
        logger.info("🏁 Starting MDEAutomator MCP Server (Persistent Mode)...")
        logger.info("🐳 Optimized for Azure Container Apps")
        
        # Set up signal handlers for graceful shutdown
        signal.signal(signal.SIGTERM, self.signal_handler)
        signal.signal(signal.SIGINT, self.signal_handler)
        
        # Start health check server in background thread
        logger.info("🏥 Starting health check server...")
        health_thread = threading.Thread(target=self.start_health_server, daemon=True)
        health_thread.start()
        
        # Start keep-alive HTTP traffic to prevent Container Apps scaling down
        logger.info("💓 Starting keep-alive HTTP traffic...")
        keepalive_thread = threading.Thread(target=self.keep_alive_http_requests, daemon=True)
        keepalive_thread.start()
        
        # Run the persistent server with asyncio
        try:
            asyncio.run(self.run_persistent_server())
        except KeyboardInterrupt:
            logger.info("⌨️ Received keyboard interrupt")
        except Exception as e:
            logger.error(f"❌ Failed to start server: {e}", exc_info=True)
            sys.exit(1)
        
        logger.info("🛑 Server shutdown complete")


if __name__ == "__main__":
    server = PersistentMCPServer()
    server.run()
