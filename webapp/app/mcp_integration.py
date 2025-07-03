"""
MCP Integration Module for MDEAutomator

This module integrates all MCP components into the Flask web application,
ensuring no functionality is lost while providing a clean interface.
"""

import asyncio
import json
import logging
import os
from typing import Any, Dict, List, Optional, Union

# Import MCP components
from .mdeautomator_mcp.config import MCPConfig
from .mdeautomator_mcp.server import MDEAutomatorMCPServer
from .mdeautomator_mcp.function_client import FunctionAppClient
from .mdeautomator_mcp.tools import get_all_tools
from .mdeautomator_mcp.models import (
    DeviceActionRequest,
    DeviceIsolationRequest, ## This should be removed because its the same as DeviceActionRequest
    HuntingRequest,
    IncidentRequest,
    ThreatIndicatorRequest,
    CustomDetectionRequest, # This needs to be added to the imports everywhere
)

# Configure logging
logger = logging.getLogger(__name__)


class FlaskMCPBridge:
    """
    Bridge class that provides synchronous interface to MCP components
    for use in Flask routes while preserving all MCP functionality.
    """
    
    def __init__(self):
        self.config = None
        self.mcp_server = None
        self.function_client = None
        self.tools = []
        self._initialized = False
        
    def initialize(self):
        """Initialize MCP components"""
        if self._initialized:
            return True
            
        try:
            # Load MCP configuration
            self.config = MCPConfig.from_environment()
            
            # Initialize function client
            self.function_client = FunctionAppClient(self.config)
            
            # Get all available tools
            self.tools = get_all_tools()
            
            # Initialize MCP server instance
            self.mcp_server = MDEAutomatorMCPServer(self.config)
            
            self._initialized = True
            logger.info(f"MCP Bridge initialized with {len(self.tools)} tools")
            return True
            
        except Exception as e:
            logger.error(f"Failed to initialize MCP Bridge: {e}")
            return False
    
    def get_tools(self) -> List[Dict[str, Any]]:
        """Get all available MCP tools"""
        if not self._initialized:
            self.initialize()
            
        return [
            {
                "name": tool.name,
                "description": tool.description,
                "inputSchema": tool.inputSchema
            }
            for tool in self.tools
        ]
    
    def call_tool_sync(self, tool_name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """
        Synchronous wrapper for MCP tool calls - converts async calls to sync
        for use in Flask routes
        """
        if not self._initialized:
            if not self.initialize():
                return {"error": "MCP Bridge not initialized"}
        
        try:
            # Create new event loop for this call
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            
            try:
                # Initialize function client if needed
                if not self.function_client._initialized:
                    loop.run_until_complete(self.function_client.initialize())
                
                # Route the tool call through MCP server
                result = loop.run_until_complete(
                    self.mcp_server._route_tool_call(tool_name, arguments)
                )
                
                return result
                
            finally:
                loop.close()
                
        except Exception as e:
            logger.error(f"Tool call failed: {tool_name} - {e}")
            return {"error": str(e)}
    
    async def call_tool_async(self, tool_name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Async wrapper for MCP tool calls"""
        if not self._initialized:
            if not self.initialize():
                return {"error": "MCP Bridge not initialized"}
        
        try:
            # Initialize function client if needed
            if not self.function_client._initialized:
                await self.function_client.initialize()
            
            # Route the tool call through MCP server
            result = await self.mcp_server._route_tool_call(tool_name, arguments)
            return result
            
        except Exception as e:
            logger.error(f"Async tool call failed: {tool_name} - {e}")
            return {"error": str(e)}
    
    def handle_mcp_discover(self) -> Dict[str, Any]:
        """Handle MCP discovery requests (for external MCP clients)"""
        if not self._initialized:
            self.initialize()
            
        return {
            "serverInfo": {
                "name": "MDEAutomator MCP Server",
                "version": "1.0.0",
                "description": "Microsoft Defender for Endpoint operations via MCP"
            },
            "capabilities": {
                "tools": True,
                "resources": False,
                "prompts": False
            },
            "tools": self.get_tools()
        }
    
    def handle_mcp_execute(self, request_data: Dict[str, Any]) -> Dict[str, Any]:
        """Handle MCP execution requests (for external MCP clients)"""
        try:
            tool_name = request_data.get('tool') or request_data.get('name')
            arguments = request_data.get('arguments', {})
            
            if not tool_name:
                return {"error": "Missing tool name"}
            
            result = self.call_tool_sync(tool_name, arguments)
            
            return {
                "content": [
                    {
                        "type": "text",
                        "text": json.dumps(result, indent=2, default=str)
                    }
                ]
            }
            
        except Exception as e:
            logger.error(f"MCP execute failed: {e}")
            return {"error": str(e)}
    
    def get_device_management_tools(self) -> List[str]:
        """Get list of device management tool names"""
        device_tools = [
            "mde_get_machines",
            "mde_isolate_device", 
            "mde_unisolate_device",
            "mde_restrict_app_execution",
            "mde_unrestrict_app_execution",
            "mde_collect_investigation_package",
            "mde_run_antivirus_scan",
            "mde_stop_and_quarantine_file",
            "mde_run_live_response_script",
            "mde_run_live_response_putfile",
            "mde_run_live_response_getfile",
            "mde_upload_live_response_file",
        ]
        return device_tools
    
    def get_threat_intelligence_tools(self) -> List[str]:
        """Get list of threat intelligence tool names"""
        ti_tools = [
            "mde_add_file_indicators",
            "mde_add_ip_indicators", 
            "mde_add_url_indicators",
            "mde_add_cert_indicators",
            "mde_remove_indicators",
            "mde_get_indicators"
        ]
        return ti_tools
    
    def get_custom_detections(self) -> List[str]:
        """Get list of custom detection tool names"""
        custom_detections = [
            "mde_create_custom_detection",
            "mde_update_custom_detection",
            "mde_delete_custom_detection",
            "mde_sync_custom_detections",
            "mde_get_custom_detections",
            "mde_get_custom_detection_by_id"
        ]
        return custom_detections
    
    
    def get_hunting_tools(self) -> List[str]:
        """Get list of hunting tool names"""
        hunting_tools = [
            "mde_run_hunting_query",
            "mde_create_scheduled_hunt",
            "mde_enable_scheduled_hunt",
            "mde_disable_scheduled_hunt",
            "mde_delete_scheduled_hunt",
            "mde_get_hunt_results"
        ]
        return hunting_tools
    
    def get_incident_tools(self) -> List[str]:
        """Get list of incident management tool names"""
        incident_tools = [
            "mde_get_incidents",
            "mde_get_incident", 
            "mde_update_incident",
            "mde_add_incident_comment"
        ]
        return incident_tools


# Global MCP bridge instance
mcp_bridge = FlaskMCPBridge()
