#!/usr/bin/env python3
"""
Alternative MCP server entry point that handles backend selection gracefully.
"""

import asyncio
import sys
import os

# Add current directory to path for imports
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

async def main():
    """Main entry point with backend fallback."""
    try:
        # Import our server
        from server import MDEAutomatorMCPServer
        from config import MCPConfig
        
        # Load configuration
        config = MCPConfig.from_environment()
        
        # Create and run server
        server = MDEAutomatorMCPServer(config)
        await server.run()
        
    except Exception as e:
        print(f"Failed to start server: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    # Try trio first, then fall back to asyncio
    try:
        import anyio
        anyio.run(main, backend="trio")
    except (ImportError, LookupError) as e:
        print(f"Trio backend not available ({e}), falling back to asyncio", file=sys.stderr)
        asyncio.run(main())
    except Exception as e:
        print(f"Failed to start with any backend: {e}", file=sys.stderr)
        sys.exit(1)
