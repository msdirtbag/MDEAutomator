#!/usr/bin/env python3
"""
Comprehensive MCP Server Entry Point

This script provides a robust entry point that works in all environments:
- Local development with trio support
- Container environments without trio
- Graceful fallback between async backends
- Proper error handling and logging
"""

import asyncio
import sys
import os
import signal
import logging
from typing import Optional

# Configure comprehensive logging
logging.basicConfig(
    level=logging.INFO,
    format='%(asctime)s - %(name)s - %(levelname)s - %(message)s',
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.StreamHandler(sys.stderr)
    ]
)
logger = logging.getLogger(__name__)

# Add current directory to Python path
current_dir = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, current_dir)

def signal_handler(signum, frame):
    """Handle shutdown signals gracefully."""
    logger.info(f"Received signal {signum}, shutting down gracefully...")
    sys.exit(0)

# Setup signal handlers for graceful shutdown
signal.signal(signal.SIGINT, signal_handler)
signal.signal(signal.SIGTERM, signal_handler)

def check_dependencies() -> dict:
    """Check which async backends and dependencies are available."""
    availability = {
        'trio': False,
        'anyio': False,
        'asyncio': True,  # Always available in Python 3.7+
        'mcp': False,
        'server_module': False
    }
    
    try:
        import trio
        availability['trio'] = True
        logger.debug(f"trio available: {trio.__version__}")
    except ImportError:
        logger.debug("trio not available")
    
    try:
        import anyio
        availability['anyio'] = True
        logger.debug(f"anyio available: {anyio.__version__}")
    except ImportError:
        logger.debug("anyio not available")
    
    try:
        import mcp
        availability['mcp'] = True
        logger.debug(f"mcp available: {mcp.__version__}")
    except ImportError:
        logger.debug("mcp not available")
    
    try:
        from server import MDEAutomatorMCPServer
        from config import MCPConfig
        availability['server_module'] = True
        logger.debug("server module available")
    except ImportError as e:
        logger.debug(f"server module not available: {e}")
    
    return availability

async def run_server_with_asyncio():
    """Run the MCP server using pure asyncio backend."""
    logger.info("Running server with asyncio backend...")
    
    try:
        from server import MDEAutomatorMCPServer
        from config import MCPConfig
        
        logger.info("Loading configuration...")
        config = MCPConfig.from_environment()
        
        logger.info("Creating MCP server...")
        server = MDEAutomatorMCPServer(config)
        
        logger.info("Starting MCP server with asyncio...")
        await server.run()
        
    except ImportError as e:
        logger.error(f"Import error: {e}")
        logger.error("Make sure all required dependencies are installed")
        raise
    except Exception as e:
        logger.error(f"Failed to start server: {e}", exc_info=True)
        raise

async def run_server_with_trio():
    """Run the MCP server using trio backend via anyio."""
    logger.info("Running server with trio backend...")
    
    try:
        from server import MDEAutomatorMCPServer
        from config import MCPConfig
        
        logger.info("Loading configuration...")
        config = MCPConfig.from_environment()
        
        logger.info("Creating MCP server...")
        server = MDEAutomatorMCPServer(config)
        
        logger.info("Starting MCP server with trio...")
        await server.run()
        
    except ImportError as e:
        logger.error(f"Import error: {e}")
        raise
    except Exception as e:
        logger.error(f"Failed to start server: {e}", exc_info=True)
        raise

def run_with_asyncio():
    """Entry point using asyncio."""
    try:
        logger.info("Starting with asyncio backend...")
        asyncio.run(run_server_with_asyncio())
    except KeyboardInterrupt:
        logger.info("Received interrupt signal, shutting down...")
    except Exception as e:
        logger.error(f"Asyncio backend failed: {e}", exc_info=True)
        raise

def run_with_trio():
    """Entry point using trio via anyio."""
    try:
        logger.info("Starting with trio backend...")
        import anyio
        anyio.run(run_server_with_trio, backend="trio")
    except KeyboardInterrupt:
        logger.info("Received interrupt signal, shutting down...")
    except Exception as e:
        logger.error(f"Trio backend failed: {e}", exc_info=True)
        raise

def main():
    """
    Comprehensive main entry point.
    
    This function determines the best available async backend and runs the server.
    Priority order:
    1. trio (if available and anyio supports it)
    2. asyncio (always available fallback)
    """
    logger.info("=== MDEAutomator MCP Server Starting ===")
    
    # Check what's available in this environment
    deps = check_dependencies()
    logger.info(f"Environment check: {deps}")
    
    # Validate core requirements
    if not deps['server_module']:
        logger.error("Server module not available. Cannot start.")
        sys.exit(1)
    
    # Determine backend strategy
    backends_to_try = []
    
    if deps['trio'] and deps['anyio']:
        # Try trio first if both are available
        backends_to_try.append(('trio', run_with_trio))
        logger.info("Trio and anyio available - will try trio first")
    
    # Always add asyncio as fallback
    backends_to_try.append(('asyncio', run_with_asyncio))
    logger.info("Asyncio available as fallback")
    
    # Try backends in order
    last_error = None
    for backend_name, backend_func in backends_to_try:
        try:
            logger.info(f"Attempting to start with {backend_name} backend...")
            backend_func()
            # If we get here, the server started and stopped normally
            logger.info(f"Server stopped normally with {backend_name} backend")
            return
            
        except ImportError as e:
            logger.warning(f"{backend_name} backend dependencies missing: {e}")
            last_error = e
            continue
            
        except LookupError as e:
            logger.warning(f"{backend_name} backend lookup failed: {e}")
            last_error = e
            continue
            
        except Exception as e:
            logger.error(f"{backend_name} backend failed: {e}")
            last_error = e
            # For non-dependency errors, we should probably stop trying
            break
    
    # If we get here, all backends failed
    logger.error("All async backends failed!")
    if last_error:
        logger.error(f"Last error: {last_error}")
    sys.exit(1)

if __name__ == "__main__":
    main()
