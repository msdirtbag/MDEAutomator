"""
MCP package initialization.
"""

from .config import MCPConfig
from .function_client import FunctionAppClient
from .server import MDEAutomatorMCPServer

__version__ = "1.0.0"
__all__ = ["MCPConfig", "FunctionAppClient", "MDEAutomatorMCPServer"]
