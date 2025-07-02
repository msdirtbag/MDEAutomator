#!/usr/bin/env python3
"""
Standalone MCP server that doesn't rely on MCP package's trio-dependent entry point.

This server implements the MCP protocol directly using asyncio/stdio,
avoiding the trio dependency issue in containers.
"""

import asyncio
import json
import sys
import os
import logging
from typing import Any, Dict

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s'
)
logger = logging.getLogger(__name__)

# Add current directory to Python path
current_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, current_dir)

async def run_mcp_server():
    """Run the MCP server using asyncio and stdio directly."""
    try:
        from server import MDEAutomatorMCPServer  
        from config import MCPConfig
        
        logger.info("Loading configuration...")
        config = MCPConfig.from_environment()
        
        logger.info("Creating MCP server...")
        server = MDEAutomatorMCPServer(config)
        
        logger.info("Starting MCP server with asyncio backend...")
        await server.run()
        
    except Exception as e:
        logger.error(f"Server failed: {e}", exc_info=True)
        sys.exit(1)

def main():
    """Main entry point using pure asyncio."""
    logger.info("Starting MDEAutomator MCP Server (asyncio-only mode)...")
    
    try:
        # Use asyncio directly - no trio dependency
        asyncio.run(run_mcp_server())
    except KeyboardInterrupt:
        logger.info("Server shutdown requested")
    except Exception as e:
        logger.error(f"Failed to start server: {e}", exc_info=True)
        sys.exit(1)

if __name__ == "__main__":
    main()
