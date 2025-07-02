"""
MDEAutomator MCP Server

A Model Context Protocol (MCP) server that provides access to Microsoft Defender for Endpoint
operations through Azure Function Apps. This server enables AI assistants to perform security
operations including device management, threat hunting, incident response, and threat intelligence
management.

Key Features:
- Device isolation and containment
- Live response automation
- Threat indicator management
- Advanced hunting queries
- Incident management
- Custom detection management
- Security action orchestration

Security Features:
- Azure Managed Identity authentication
- Function key-based authorization
- Request/response validation
- Comprehensive audit logging
- Rate limiting and throttling
"""

import asyncio
import json
import logging
import os
import re
import sys
import time
from contextlib import asynccontextmanager
from datetime import datetime
from typing import Any, Dict, List, Optional, Sequence

import httpx
import structlog
import openai
from azure.identity import DefaultAzureCredential
from mcp import stdio_server
from mcp.server import InitializationOptions, NotificationOptions, Server as MCPServer
from mcp.types import (
    CallToolRequest,
    CallToolResult,
    ListToolsRequest,
    ListToolsResult,
    TextContent,
    Tool,
)
from pydantic import BaseModel, Field
from tenacity import retry, stop_after_attempt, wait_exponential

try:
    from .config import MCPConfig
    from .function_client import FunctionAppClient
    from .models import (
        DeviceActionRequest,
        DeviceIsolationRequest,
        HuntingRequest,
        IncidentRequest,
        ThreatIndicatorRequest,
    )
    from .tools import get_all_tools
except ImportError:
    from config import MCPConfig
    from function_client import FunctionAppClient
    from models import (
        DeviceActionRequest,
        DeviceIsolationRequest,
        HuntingRequest,
        IncidentRequest,
        ThreatIndicatorRequest,
    )
    from tools import get_all_tools

# Configure structured logging
structlog.configure(
    processors=[
        structlog.stdlib.filter_by_level,
        structlog.stdlib.add_logger_name,
        structlog.stdlib.add_log_level,
        structlog.stdlib.PositionalArgumentsFormatter(),
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.StackInfoRenderer(),
        structlog.processors.format_exc_info,
        structlog.processors.UnicodeDecoder(),
        structlog.processors.JSONRenderer(),
    ],
    context_class=dict,
    logger_factory=structlog.stdlib.LoggerFactory(),
    cache_logger_on_first_use=True,
)

logger = structlog.get_logger(__name__)


class MDEAutomatorMCPServer:
    """
    MCP Server for Microsoft Defender for Endpoint operations.
    
    This server provides a secure, authenticated interface to MDEAutomator Function Apps,
    enabling AI assistants to perform comprehensive security operations through the
    Model Context Protocol.
    """

    def __init__(self, config: MCPConfig):
        """Initialize the MCP server with configuration."""
        # Perform startup environment diagnostics FIRST
        self._perform_startup_diagnostics()
        
        self.config = config
        self.function_client = FunctionAppClient(config)
        self.server = MCPServer("mdeautomator-mcp")
        self._setup_handlers()
    
    def _perform_startup_diagnostics(self):
        """Perform comprehensive startup diagnostics for Azure environment."""
        logger.info("🚀 === MDEAutomator MCP SERVER STARTUP DIAGNOSTICS ===")
        
        # Check if running in Azure App Service
        website_site_name = os.getenv('WEBSITE_SITE_NAME')
        website_resource_group = os.getenv('WEBSITE_RESOURCE_GROUP')
        
        if website_site_name:
            logger.info(f"🔍 Running in Azure App Service: {website_site_name}")
            logger.info(f"🔍 Resource Group: {website_resource_group}")
        else:
            logger.info("🔍 Running in local development environment")
        
        # Check critical Azure AI environment variables
        ai_vars_to_check = [
            'AZURE_AI_ENDPOINT',
            'AZURE_AI_KEY', 
            'AZURE_AI_DEPLOYMENT',
            'AZURE_OPENAI_ENDPOINT',
            'AZURE_OPENAI_KEY',
            'OPENAI_API_KEY',
            'OPENAI_API_BASE'
        ]
        
        logger.info("🔍 Checking critical Azure AI environment variables:")
        found_vars = {}
        for var_name in ai_vars_to_check:
            value = os.getenv(var_name)
            if value:
                found_vars[var_name] = len(value)
                logger.info(f"✅ {var_name}: Present ({len(value)} characters)")
            else:
                logger.warning(f"❌ {var_name}: Missing")
        
        # Overall environment variable summary
        total_env_vars = len(os.environ)
        azure_ai_vars = {k: v for k, v in os.environ.items() 
                        if any(keyword in k.upper() for keyword in ['AZURE', 'AI', 'OPENAI'])}
        
        logger.info(f"🔍 Total environment variables: {total_env_vars}")
        logger.info(f"🔍 Azure/AI related variables found: {len(azure_ai_vars)}")
        
        if azure_ai_vars:
            logger.info("🔍 All Azure/AI environment variables:")
            for key, value in azure_ai_vars.items():
                safe_value = f"[{len(value)} chars] {value[:20]}{'...' if len(value) > 20 else ''}"
                logger.info(f"🔍   {key}: {safe_value}")
        
        # Check for common App Service issues
        if website_site_name:
            logger.info("🔍 Azure App Service specific checks:")
            
            # Check for slot-specific variables
            slot_name = os.getenv('WEBSITE_SLOT_NAME')
            if slot_name:
                logger.info(f"🔍 Deployment slot: {slot_name}")
            
            # Check restart reason
            restart_reason = os.getenv('WEBSITE_LAST_RESTART_REASON')
            if restart_reason:
                logger.info(f"🔍 Last restart reason: {restart_reason}")
            
            # Check if variables might be slot-specific
            logger.info("🔍 Checking for slot-specific variable prefixes...")
            slot_vars = {k: v for k, v in os.environ.items() if k.startswith('APPSETTING_')}
            if slot_vars:
                logger.info(f"🔍 Found {len(slot_vars)} APPSETTING_ prefixed variables")
                for key in slot_vars.keys():
                    if any(keyword in key.upper() for keyword in ['AZURE', 'AI', 'OPENAI']):
                        logger.info(f"🔍   Slot-specific AI var: {key}")
        
        # Summary
        ai_endpoint_available = any(os.getenv(var) for var in ['AZURE_AI_ENDPOINT', 'AZURE_OPENAI_ENDPOINT', 'OPENAI_API_BASE'])
        ai_key_available = any(os.getenv(var) for var in ['AZURE_AI_KEY', 'AZURE_OPENAI_KEY', 'OPENAI_API_KEY'])
        
        if ai_endpoint_available and ai_key_available:
            logger.info("✅ Azure AI configuration appears to be available")
        else:
            logger.error("❌ Azure AI configuration is incomplete or missing")
            if not ai_endpoint_available:
                logger.error("❌ No AI endpoint found in environment")
            if not ai_key_available:
                logger.error("❌ No AI key found in environment")
        
        logger.info("🚀 === STARTUP DIAGNOSTICS COMPLETE ===")
        logger.info("")

    def _setup_handlers(self) -> None:
        """Set up MCP server handlers for tools and resources."""
        
        @self.server.list_tools()
        async def handle_list_tools() -> ListToolsResult:
            """List all available MDEAutomator tools."""
            try:
                tools = get_all_tools()
                logger.info("Listed tools", tool_count=len(tools))
                return ListToolsResult(tools=tools)
            except Exception as e:
                logger.error("Failed to list tools", error=str(e))
                raise

        @self.server.call_tool()
        async def handle_call_tool(request: CallToolRequest) -> CallToolResult:
            """Handle tool execution requests."""
            try:
                logger.info(
                    "Tool call requested",
                    tool_name=request.name,
                    arguments=request.arguments,
                )

                # Route the tool call to the appropriate handler
                result = await self._route_tool_call(request.name, request.arguments)
                
                logger.info(
                    "Tool call completed",
                    tool_name=request.name,
                    success=True,
                )

                return CallToolResult(
                    content=[
                        TextContent(
                            type="text",
                            text=json.dumps(result, indent=2, default=str),
                        )
                    ]
                )

            except Exception as e:
                logger.error(
                    "Tool call failed",
                    tool_name=request.name,
                    error=str(e),
                    exc_info=True,
                )
                return CallToolResult(
                    content=[
                        TextContent(
                            type="text",
                            text=f"Error executing tool {request.name}: {str(e)}",
                        )
                    ],
                    isError=True,
                )

    async def _route_tool_call(self, tool_name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Route tool calls to appropriate Function App endpoints."""
          # Device Management Tools
        if tool_name.startswith("mde_get_machines"):
            return await self._handle_get_machines(arguments)
        elif tool_name.startswith("mde_isolate_device"):
            return await self._handle_isolate_device(arguments)
        elif tool_name.startswith("mde_unisolate_device"):
            return await self._handle_unisolate_device(arguments)
        elif tool_name.startswith("mde_contain_device"):
            return await self._handle_contain_device(arguments)
        elif tool_name.startswith("mde_uncontain_device"):
            return await self._handle_uncontain_device(arguments)
        elif tool_name.startswith("mde_restrict_app_execution"):
            return await self._handle_restrict_app_execution(arguments)
        elif tool_name.startswith("mde_unrestrict_app_execution"):
            return await self._handle_unrestrict_app_execution(arguments)
        elif tool_name.startswith("mde_collect_investigation_package"):
            return await self._handle_collect_investigation_package(arguments)
        elif tool_name.startswith("mde_run_antivirus_scan"):
            return await self._handle_run_antivirus_scan(arguments)
        elif tool_name.startswith("mde_stop_and_quarantine_file"):
            return await self._handle_stop_and_quarantine_file(arguments)
        elif tool_name.startswith("mde_offboard_device"):
            return await self._handle_offboard_device(arguments)
            
        # Live Response Tools
        elif tool_name.startswith("mde_run_live_response_script"):
            return await self._handle_run_live_response_script(arguments)
        elif tool_name.startswith("mde_upload_to_library"):
            return await self._handle_upload_to_library(arguments)
        elif tool_name.startswith("mde_put_file"):
            return await self._handle_put_file(arguments)
        elif tool_name.startswith("mde_get_file"):
            return await self._handle_get_file(arguments)
              # Action Management Tools        elif tool_name.startswith("mde_get_actions"):
            return await self._handle_get_actions(arguments)
        elif tool_name.startswith("mde_cancel_actions"):
            return await self._handle_cancel_actions(arguments)
        elif tool_name.startswith("mde_get_action_status"):
            return await self._handle_get_action_status(arguments)
        elif tool_name.startswith("mde_get_live_response_output"):
            return await self._handle_get_live_response_output(arguments)
            
        # Threat Intelligence Tools
        elif tool_name.startswith("mde_add_file_indicators"):
            return await self._handle_add_file_indicators(arguments)
        elif tool_name.startswith("mde_add_ip_indicators"):
            return await self._handle_add_ip_indicators(arguments)
        elif tool_name.startswith("mde_add_url_indicators"):
            return await self._handle_add_url_indicators(arguments)
        elif tool_name.startswith("mde_add_cert_indicators"):
            return await self._handle_add_cert_indicators(arguments)
        elif tool_name.startswith("mde_remove_indicators"):
            return await self._handle_remove_indicators(arguments)
        elif tool_name.startswith("mde_get_indicators"):
            return await self._handle_get_indicators(arguments)
            
        # Hunting Tools
        elif tool_name.startswith("mde_run_hunting_query"):
            return await self._handle_run_hunting_query(arguments)
        elif tool_name.startswith("mde_schedule_hunt"):
            return await self._handle_schedule_hunt(arguments)
        elif tool_name.startswith("mde_get_hunt_results"):
            return await self._handle_get_hunt_results(arguments)
            
        # Incident Management Tools
        elif tool_name.startswith("mde_get_incidents"):
            return await self._handle_get_incidents(arguments)
        elif tool_name.startswith("mde_get_incident"):
            return await self._handle_get_incident(arguments)
        elif tool_name.startswith("mde_update_incident"):
            return await self._handle_update_incident(arguments)
        elif tool_name.startswith("mde_add_incident_comment"):
            return await self._handle_add_incident_comment(arguments)
            
        # Custom Detection Tools
        elif tool_name.startswith("mde_get_detection_rules"):
            return await self._handle_get_detection_rules(arguments)
        elif tool_name.startswith("mde_create_detection_rule"):
            return await self._handle_create_detection_rule(arguments)
        elif tool_name.startswith("mde_update_detection_rule"):
            return await self._handle_update_detection_rule(arguments)
        elif tool_name.startswith("mde_delete_detection_rule"):
            return await self._handle_delete_detection_rule(arguments)
            
        # Information Gathering Tools
        elif tool_name.startswith("mde_get_file_info"):
            return await self._handle_get_file_info(arguments)
        elif tool_name.startswith("mde_get_ip_info"):
            return await self._handle_get_ip_info(arguments)
        elif tool_name.startswith("mde_get_url_info"):
            return await self._handle_get_url_info(arguments)
        elif tool_name.startswith("mde_get_logged_in_users"):
            return await self._handle_get_logged_in_users(arguments)
            
        # AI Chat Integration Tool
        elif tool_name.startswith("mde_ai_chat"):
            return await self._handle_ai_chat(arguments)
            
        else:
            raise ValueError(f"Unknown tool: {tool_name}")

    # Device Management Handlers
    async def _handle_get_machines(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle get machines requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "GetMachines",
            "filter": arguments.get("filter", "")
        }
        return await self.function_client.call_function("MDEAutomator", payload)

    async def _handle_isolate_device(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle device isolation requests."""
        device_ids = arguments.get("device_ids", [])
        all_devices = arguments.get("all_devices", False)
        
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "InvokeMachineIsolation",
            "allDevices": all_devices
        }
        
        if not all_devices and device_ids:
            payload["DeviceIds"] = device_ids
            
        return await self.function_client.call_function("MDEDispatcher", payload)

    async def _handle_unisolate_device(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle device unisolation requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "UndoMachineIsolation",
            "DeviceIds": arguments.get("device_ids", [])
        }
        return await self.function_client.call_function("MDEDispatcher", payload)

    async def _handle_contain_device(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle device containment requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "InvokeContainDevice",
            "DeviceIds": arguments.get("device_ids", [])
        }
        return await self.function_client.call_function("MDEDispatcher", payload)

    async def _handle_uncontain_device(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle device uncontainment requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "UndoContainDevice", 
            "DeviceIds": arguments.get("device_ids", [])
        }
        return await self.function_client.call_function("MDEDispatcher", payload)

    async def _handle_restrict_app_execution(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle app execution restriction requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "InvokeRestrictAppExecution",
            "DeviceIds": arguments.get("device_ids", [])
        }
        return await self.function_client.call_function("MDEDispatcher", payload)

    async def _handle_unrestrict_app_execution(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle app execution unrestriction requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "UndoRestrictAppExecution",
            "DeviceIds": arguments.get("device_ids", [])
        }
        return await self.function_client.call_function("MDEDispatcher", payload)

    async def _handle_collect_investigation_package(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle investigation package collection requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "InvokeCollectInvestigationPackage",
            "DeviceIds": arguments.get("device_ids", [])
        }
        return await self.function_client.call_function("MDEDispatcher", payload)

    async def _handle_run_antivirus_scan(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle antivirus scan requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "InvokeFullDiskScan",
            "DeviceIds": arguments.get("device_ids", [])
        }
        return await self.function_client.call_function("MDEDispatcher", payload)

    async def _handle_stop_and_quarantine_file(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle stop and quarantine file requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "InvokeStopAndQuarantineFile", 
            "Sha1s": [arguments.get("sha1_hash", "")],  # Fixed: Send as array
            "allDevices": arguments.get("all_devices", True)
        }
        return await self.function_client.call_function("MDEDispatcher", payload)

    async def _handle_offboard_device(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle device offboarding requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "InvokeMachineOffboard",
            "DeviceIds": arguments.get("device_ids", [])
        }
        return await self.function_client.call_function("MDEDispatcher", payload)

    # Live Response Handlers
    async def _handle_run_live_response_script(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle live response script execution."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "InvokeLRScript",
            "DeviceIds": arguments.get("device_ids", []),
            "scriptName": arguments.get("script_name", "")
        }
        return await self.function_client.call_function("MDEOrchestrator", payload)

    async def _handle_upload_to_library(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle file upload to Live Response library."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "InvokeUploadLR",
            "filePath": arguments.get("file_path", ""),
            "fileContent": arguments.get("file_content", ""),
            "TargetFileName": arguments.get("target_filename", "")
        }
        return await self.function_client.call_function("MDEOrchestrator", payload)

    async def _handle_put_file(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle putting file to devices."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "InvokePutFile",
            "DeviceIds": arguments.get("device_ids", []),
            "fileName": arguments.get("file_name", "")
        }
        return await self.function_client.call_function("MDEOrchestrator", payload)

    async def _handle_get_file(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle getting file from devices."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "InvokeGetFile",
            "DeviceIds": arguments.get("device_ids", []),
            "filePath": arguments.get("file_path", "")
        }
        return await self.function_client.call_function("MDEOrchestrator", payload)

    # Action Management Handlers
    async def _handle_get_actions(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle get actions requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "GetActions"
        }
        return await self.function_client.call_function("MDEAutomator", payload)

    async def _handle_cancel_actions(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle cancel actions requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "UndoActions"
        }
        return await self.function_client.call_function("MDEAutomator", payload)

    async def _handle_get_action_status(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle get action status requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "GetMachineActionStatus",
            "ActionId": arguments.get("action_id", "")  # Fixed: Use ActionId instead of machineActionId
        }
        return await self.function_client.call_function("MDEAutomator", payload)

    async def _handle_get_live_response_output(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle get live response output requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "GetLiveResponseOutput",
            "ActionId": arguments.get("action_id", "")
        }
        return await self.function_client.call_function("MDEAutomator", payload)

    # Threat Intelligence Handlers
    async def _handle_add_file_indicators(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle adding file threat indicators."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "InvokeTiFile",
            "Sha1s": arguments.get("sha1_hashes", []),
            "Sha256s": arguments.get("sha256_hashes", [])
        }
        return await self.function_client.call_function("MDETIManager", payload)

    async def _handle_add_ip_indicators(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle adding IP threat indicators."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "InvokeTiIP",
            "IPs": arguments.get("ip_addresses", [])
        }
        return await self.function_client.call_function("MDETIManager", payload)

    async def _handle_add_url_indicators(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle adding URL threat indicators."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "InvokeTiURL",
            "URLs": arguments.get("urls", [])
        }
        return await self.function_client.call_function("MDETIManager", payload)

    async def _handle_add_cert_indicators(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle adding certificate threat indicators."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "InvokeTiCert",
            "Sha1s": arguments.get("cert_thumbprints", [])
        }
        return await self.function_client.call_function("MDETIManager", payload)

    async def _handle_remove_indicators(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle removing threat indicators."""
        indicator_type = arguments.get("indicator_type", "")
        if indicator_type == "file":
            function_name = "UndoTiFile"
            payload = {
                "TenantId": arguments.get("tenant_id", ""),
                "Function": function_name,
                "Sha1s": arguments.get("sha1_hashes", []),
                "Sha256s": arguments.get("sha256_hashes", [])
            }
        elif indicator_type == "ip":
            function_name = "UndoTiIP"
            payload = {
                "TenantId": arguments.get("tenant_id", ""),
                "Function": function_name,
                "IPs": arguments.get("ip_addresses", [])
            }
        elif indicator_type == "url":
            function_name = "UndoTiURL"
            payload = {
                "TenantId": arguments.get("tenant_id", ""),
                "Function": function_name,
                "URLs": arguments.get("urls", [])
            }
        elif indicator_type == "cert":
            function_name = "UndoTiCert"
            payload = {
                "TenantId": arguments.get("tenant_id", ""),
                "Function": function_name,
                "Sha1s": arguments.get("cert_thumbprints", [])
            }
        else:
            raise ValueError(f"Unsupported indicator type: {indicator_type}")
            
        return await self.function_client.call_function("MDETIManager", payload)

    async def _handle_get_indicators(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle get indicators requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "GetIndicators"
        }
        return await self.function_client.call_function("MDEAutomator", payload)

    # Hunting Handlers
    async def _handle_run_hunting_query(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle running hunting queries."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "InvokeAdvancedHunting",
            "Queries": arguments.get("queries", [])
        }
        return await self.function_client.call_function("MDEHunter", payload)

    async def _handle_schedule_hunt(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle scheduling hunt operations."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "ScheduleHunt",
            "huntName": arguments.get("hunt_name", ""),
            "query": arguments.get("query", ""),
            "schedule": arguments.get("schedule", "")
        }
        return await self.function_client.call_function("MDEHuntScheduler", payload)

    async def _handle_get_hunt_results(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle getting hunt results."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "GetHuntResults",
            "huntId": arguments.get("hunt_id", "")
        }
        return await self.function_client.call_function("MDEHuntManager", payload)

    # Incident Management Handlers
    async def _handle_get_incidents(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle get incidents requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "GetIncidents"
        }
        return await self.function_client.call_function("MDEIncidentManager", payload)

    async def _handle_get_incident(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle get specific incident requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "GetIncident",
            "IncidentId": arguments.get("incident_id", "")
        }
        return await self.function_client.call_function("MDEIncidentManager", payload)

    async def _handle_update_incident(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle update incident requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "UpdateIncident",
            "IncidentId": arguments.get("incident_id", ""),
            "Status": arguments.get("status", ""),
            "AssignedTo": arguments.get("assigned_to", ""),
            "Classification": arguments.get("classification", ""),
            "Determination": arguments.get("determination", ""),
            "CustomTags": arguments.get("custom_tags", []),
            "Description": arguments.get("description", ""),
            "DisplayName": arguments.get("display_name", ""),
            "Severity": arguments.get("severity", ""),
            "ResolvingComment": arguments.get("resolving_comment", ""),
            "Summary": arguments.get("summary", "")
        }
        return await self.function_client.call_function("MDEIncidentManager", payload)

    async def _handle_add_incident_comment(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle adding incident comments."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "UpdateIncidentComment",
            "IncidentId": arguments.get("incident_id", ""),
            "Comment": arguments.get("comment", "")
        }
        return await self.function_client.call_function("MDEIncidentManager", payload)

    # Custom Detection Handlers
    async def _handle_get_detection_rules(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle get detection rules requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "GetDetectionRules"
        }
        return await self.function_client.call_function("MDECDManager", payload)

    async def _handle_create_detection_rule(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle create detection rule requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "InstallDetectionRule",
            "jsonContent": arguments.get("rule_definition", {})
        }
        return await self.function_client.call_function("MDECDManager", payload)

    async def _handle_update_detection_rule(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle update detection rule requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "UpdateDetectionRule",
            "RuleId": arguments.get("rule_id", ""),
            "jsonContent": arguments.get("rule_definition", {})
        }
        return await self.function_client.call_function("MDECDManager", payload)

    async def _handle_delete_detection_rule(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle delete detection rule requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "UndoDetectionRule",
            "RuleId": arguments.get("rule_id", "")
        }
        return await self.function_client.call_function("MDECDManager", payload)

    # Information Gathering Handlers
    async def _handle_get_file_info(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle get file info requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "GetFileInfo",
            "Sha1s": arguments.get("sha1_hashes", [])
        }
        return await self.function_client.call_function("MDEAutomator", payload)

    async def _handle_get_ip_info(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle get IP info requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "GetIPInfo",
            "IPs": arguments.get("ip_addresses", [])
        }
        return await self.function_client.call_function("MDEAutomator", payload)

    async def _handle_get_url_info(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle get URL info requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "GetURLInfo",
            "URLs": arguments.get("urls", [])
        }
        return await self.function_client.call_function("MDEAutomator", payload)

    async def _handle_get_logged_in_users(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle get logged in users requests."""
        payload = {
            "TenantId": arguments.get("tenant_id", ""),
            "Function": "GetLoggedInUsers",
            "DeviceIds": arguments.get("device_ids", [])
        }
        return await self.function_client.call_function("MDEAutomator", payload)

    async def _get_ai_client(self):
        """Get or create Azure OpenAI client using configuration values."""
        if hasattr(self, '_ai_client') and self._ai_client:
            return self._ai_client
        
        # Use retry logic for Azure App Service environment variable propagation
        max_retries = 3 if os.getenv('WEBSITE_SITE_NAME') else 1
        
        for attempt in range(max_retries):
            try:
                if attempt > 0:
                    logger.info(f"🔄 Retry attempt {attempt + 1}/{max_retries} for AI client initialization")
                    await asyncio.sleep(1)  # Brief delay for env var propagation
                
                # Enhanced environment variable detection for Azure App Service
                logger.info("🔍 === AZURE AI CLIENT INITIALIZATION DEBUG ===")
                
                # Check if running in Azure App Service
                is_azure_app_service = bool(os.getenv('WEBSITE_SITE_NAME'))
                logger.info(f"🔍 Environment: {'Azure App Service' if is_azure_app_service else 'Local'}")
                
                if is_azure_app_service:
                    logger.info(f"🔍 App Service Name: {os.getenv('WEBSITE_SITE_NAME')}")
                    logger.info(f"🔍 Resource Group: {os.getenv('WEBSITE_RESOURCE_GROUP', 'Unknown')}")
                    slot_name = os.getenv('WEBSITE_SLOT_NAME')
                    if slot_name:
                        logger.info(f"🔍 Deployment Slot: {slot_name}")
                
                # Get credentials from configuration first, then fallback to environment
                ai_endpoint = (
                    self.config.azure_ai_endpoint or
                    os.getenv("AZURE_AI_ENDPOINT") or 
                    os.getenv("AZURE_OPENAI_ENDPOINT") or
                    os.getenv("OPENAI_API_BASE") or
                    os.getenv("AZURE_OPENAI_BASE")
                )
                ai_key = (
                    self.config.azure_ai_key or
                    os.getenv("AZURE_AI_KEY") or 
                    os.getenv("AZURE_OPENAI_KEY") or
                    os.getenv("OPENAI_API_KEY") or
                    os.getenv("AZURE_OPENAI_API_KEY")
                )
                
                deployment_name = (
                    self.config.azure_ai_deployment or
                    os.getenv("AZURE_AI_DEPLOYMENT") or 
                    os.getenv("AZURE_OPENAI_DEPLOYMENT") or
                    "gpt-4"
                )
                
                # Enhanced debug logging
                logger.info(f"🔍 Config azure_ai_endpoint: {self.config.azure_ai_endpoint if self.config.azure_ai_endpoint else 'None'}")
                logger.info(f"🔍 Config azure_ai_key: {'Present' if self.config.azure_ai_key else 'None'}")
                logger.info(f"🔍 Config azure_ai_deployment: {self.config.azure_ai_deployment}")
                logger.info(f"🔍 Final ai_endpoint: {ai_endpoint if ai_endpoint else 'None'}")
                logger.info(f"🔍 Final ai_key present: {bool(ai_key)}")
                logger.info(f"🔍 Using deployment: {deployment_name}")
                
                if ai_endpoint:
                    logger.info(f"🔍 AI_ENDPOINT value: {ai_endpoint[:60]}...")
                    logger.info(f"🔍 AI_ENDPOINT length: {len(ai_endpoint)}")
                if ai_key:
                    logger.info(f"🔍 AI_KEY first 15 chars: {ai_key[:15]}...")
                    logger.info(f"🔍 AI_KEY length: {len(ai_key)}")
                
                # Log all Azure/AI related environment variables for comprehensive debugging
                logger.info("🔍 ALL Azure/AI Environment Variables:")
                azure_ai_vars = {}
                for key, value in os.environ.items():
                    if any(keyword in key.upper() for keyword in ['AZURE', 'AI', 'OPENAI']):
                        azure_ai_vars[key] = f"[{len(value) if value else 0} chars] {value[:30]}{'...' if value and len(value) > 30 else ''}"
                        logger.info(f"🔍   {key}: {azure_ai_vars[key]}")
                
                if not azure_ai_vars:
                    logger.warning("🔍 NO Azure/AI environment variables found at all!")
                
                # If variables are missing and we're in Azure App Service, try one more delay
                if not ai_endpoint or not ai_key:
                    if is_azure_app_service and attempt < max_retries - 1:
                        logger.warning(f"🔄 Variables missing on attempt {attempt + 1}, will retry...")
                        continue
                    
                    missing = []
                    if not ai_endpoint:
                        missing.append("AZURE_AI_ENDPOINT")
                    if not ai_key:
                        missing.append("AZURE_AI_KEY")
                    logger.error(f"❌ Missing required Azure AI variables: {', '.join(missing)}")
                    
                    # Log configuration values
                    logger.info("🔍 Configuration values:")
                    logger.info(f"🔍   config.azure_ai_endpoint: {'✅ Present' if self.config.azure_ai_endpoint else '❌ Missing'}")
                    logger.info(f"🔍   config.azure_ai_key: {'✅ Present' if self.config.azure_ai_key else '❌ Missing'}")
                    
                    # Log exact variable names checked
                    endpoint_vars = ["AZURE_AI_ENDPOINT", "AZURE_OPENAI_ENDPOINT", "OPENAI_API_BASE", "AZURE_OPENAI_BASE"]
                    key_vars = ["AZURE_AI_KEY", "AZURE_OPENAI_KEY", "OPENAI_API_KEY", "AZURE_OPENAI_API_KEY"]
                    
                    if is_azure_app_service:
                        endpoint_vars.extend(["APPSETTING_AZURE_AI_ENDPOINT", "APPSETTING_AZURE_OPENAI_ENDPOINT", "APPSETTING_OPENAI_API_BASE"])
                        key_vars.extend(["APPSETTING_AZURE_AI_KEY", "APPSETTING_AZURE_OPENAI_KEY", "APPSETTING_OPENAI_API_KEY"])
                    
                    logger.info("🔍 Checked endpoint variables:")
                    for var in endpoint_vars:
                        val = os.getenv(var)
                        logger.info(f"🔍   {var}: {'✅ Present' if val else '❌ Missing'}")
                    
                    logger.info("🔍 Checked key variables:")
                    for var in key_vars:
                        val = os.getenv(var)
                        logger.info(f"🔍   {var}: {'✅ Present' if val else '❌ Missing'}")
                    
                    # Azure App Service specific troubleshooting
                    if is_azure_app_service:
                        logger.error("🔍 Azure App Service Troubleshooting Tips:")
                        logger.error("🔍 1. Check that App Settings are configured in Azure Portal")
                        logger.error("🔍 2. Verify settings are not slot-specific if using deployment slots")
                        logger.error("🔍 3. Check if a recent deployment might have cleared settings")
                        logger.error("🔍 4. Verify the app has been restarted after setting configuration")
                        logger.error("🔍 5. Check if using Key Vault references that might be failing")
                        logger.error(f"🔍 6. Expected variable names: AZURE_AI_ENDPOINT, AZURE_AI_KEY")
                    
                    return None
                
                # Validate endpoint format
                if not ai_endpoint.startswith(('http://', 'https://')):
                    logger.warning(f"🔍 AI endpoint may be malformed (missing protocol): {ai_endpoint}")
                    # Try to fix common endpoint format issues
                    if not ai_endpoint.startswith('http'):
                        ai_endpoint = f"https://{ai_endpoint}"
                        logger.info(f"🔍 Auto-corrected endpoint to: {ai_endpoint}")
                
                # Create Azure OpenAI client
                logger.info("🔍 Creating Azure OpenAI client...")
                self._ai_client = openai.AzureOpenAI(
                    azure_endpoint=ai_endpoint,
                    api_key=ai_key,
                    api_version="2024-02-01"
                )
                
                # Test the client with a simple request to validate it works
                logger.info("🔍 Testing Azure OpenAI client connection...")
                test_response = await asyncio.to_thread(
                    self._ai_client.chat.completions.create,
                    model=deployment_name,
                    messages=[{"role": "user", "content": "Test connection"}],
                    max_tokens=5
                )
                logger.info("✅ Azure OpenAI client connection test successful")
                
                logger.info("✅ Azure AI client initialized successfully")
                logger.info(f"✅ Client endpoint: {ai_endpoint}")
                logger.info("🔍 === AZURE AI CLIENT INITIALIZATION COMPLETE ===")
                return self._ai_client
                
            except Exception as e:
                logger.error(f"❌ Failed to initialize Azure AI client (attempt {attempt + 1}): {e}")
                logger.error(f"❌ Exception type: {type(e).__name__}")
                logger.error(f"❌ Exception args: {e.args}")
                
                if attempt < max_retries - 1:
                    logger.info(f"🔄 Will retry in 1 second... ({attempt + 1}/{max_retries})")
                    continue
                else:
                    import traceback
                    logger.error(f"❌ Final failure after {max_retries} attempts")
                    logger.error(f"❌ Full traceback: {traceback.format_exc()}")
                    return None
        
        logger.error(f"❌ Failed to initialize Azure AI client after {max_retries} attempts")
        return None

    # AI Chat Integration Handler
    async def _handle_ai_chat(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Handle AI-powered chat requests using local Azure OpenAI client."""
        execute_actions = arguments.get("execute_actions", False)
        tenant_id = arguments.get("tenant_id", "")
        message = arguments.get("message", "")
        context = arguments.get("context", "")
        
        if not message:
            return {
                "error": "Message is required",
                "status": "Error"
            }
        
        try:
            # Use local Azure OpenAI client instead of Function App
            ai_client = await self._get_ai_client()
            if not ai_client:
                return {
                    "error": "Azure AI Foundry not configured",
                    "status": "Error",
                    "suggestion": "Configure AZURE_AI_ENDPOINT and AZURE_AI_KEY environment variables"
                }
            
            # Get all available tools for system prompt
            available_tools = self._get_all_available_tools()
            tools_description = self._format_tools_for_ai(available_tools)
            
            # Build conversation with system prompt
            system_prompt = f"""You are an expert Microsoft Defender for Endpoint (MDE) security operations AI that EXECUTES real security actions.

Context: {context}

🔧 AVAILABLE MDE TOOLS: I have access to these real MDE operations:
{tools_description}

🎯 EXECUTION MODE: execute_actions={execute_actions}, tenant_id={'configured' if tenant_id else 'missing'}

🤖 BEHAVIOR:
When execute_actions=true and tenant_id is provided, I will:
1. Analyze your request and determine which MDE tools to use
2. Execute the appropriate operations using real MDE APIs
3. Return actual results from Microsoft Defender for Endpoint
4. Provide expert security analysis based on live data

When execute_actions=false, I will:
1. Explain what I would do with step-by-step action plans
2. Recommend specific tools and parameters
3. Provide security expertise without executing actions

For your request: "{message}"
I will now {'execute real MDE operations and analyze live data' if execute_actions and tenant_id else 'provide detailed action recommendations'}."""
            
            messages = [
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": message}
            ]
            
            # Get deployment name from environment
            deployment_name = os.getenv("AZURE_AI_DEPLOYMENT", "gpt-4")
            
            # Call Azure OpenAI
            response = ai_client.chat.completions.create(
                model=deployment_name,
                messages=messages,
                max_tokens=arguments.get("max_tokens", 3000),
                temperature=arguments.get("temperature", 0.7)
            )
            
            ai_response = response.choices[0].message.content
            
            # Enhanced result with MCP-specific formatting
            enhanced_result = {
                "ai_response": ai_response,
                "model_used": deployment_name,
                "tokens_used": {
                    "prompt_tokens": response.usage.prompt_tokens,
                    "completion_tokens": response.usage.completion_tokens,
                    "total_tokens": response.usage.total_tokens
                },
                "status": "Success",
                "suggestions": self._extract_action_suggestions(ai_response),
                "executed_actions": []
            }
            
            # Execute actions if requested
            if execute_actions and tenant_id:
                logger.info("AI automation mode enabled - executing MDE operations")
                executed_actions = await self._execute_ai_recommended_actions(
                    message, tenant_id  # Pass original message instead of AI response
                )
                enhanced_result["executed_actions"] = executed_actions
                enhanced_result["automation_enabled"] = True
                
                # Update AI response to include execution results
                if executed_actions:
                    execution_summary = self._create_execution_summary(executed_actions)
                    ai_response = f"{ai_response}\n\n🤖 **EXECUTION RESULTS:**\n{execution_summary}"
                    enhanced_result["ai_response"] = ai_response
            else:
                enhanced_result["automation_enabled"] = False
                if not execute_actions:
                    enhanced_result["note"] = "Enable 'Execute Actions' to allow AI automation"
                elif not tenant_id:
                    enhanced_result["note"] = "Select a tenant to enable AI automation"
            
            return enhanced_result
            
        except Exception as e:
            logger.error(f"AI Chat error: {str(e)}")
            return {
                "error": f"AI Chat failed: {str(e)}",
                "status": "Error",
                "suggestions": [],
                "ai_response": "I apologize, but I encountered an error processing your request. Please ensure Azure AI Foundry is properly configured and try again."
            }
    
    def _extract_action_suggestions(self, ai_response: str) -> List[str]:
        """Extract potential MDE action suggestions from AI response."""
        suggestions = []
        
        # Look for common action patterns in the AI response
        action_patterns = [
            r"isolate.*device",
            r"run.*scan",
            r"quarantine.*file",
            r"hunt.*for",
            r"check.*incident",
            r"investigate.*alert",
            r"collect.*package",
            r"block.*indicator",
            r"add.*threat.*intelligence"
        ]
        
        for pattern in action_patterns:
            import re
            if re.search(pattern, ai_response, re.IGNORECASE):
                suggestions.append(f"Consider using MDE tools to: {pattern.replace('.*', ' ')}")
        
        return suggestions[:3]  # Limit to top 3 suggestions

    async def _execute_ai_recommended_actions(self, user_message: str, tenant_id: str) -> List[Dict[str, Any]]:
        """Execute MDE operations based on user intent using dynamic tool selection."""
        executed_actions = []
        user_intent = user_message.lower()
        
        logger.info(f"🤖 AI automation analyzing intent: {user_intent[:100]}...")
        
        try:
            # Define action patterns and their corresponding tools/parameters
            action_patterns = [
                {
                    "keywords": ["device", "machine", "computer", "endpoint", "list", "get"],
                    "tools": [
                        {
                            "name": "mde_get_machines",
                            "params": {"tenant_id": tenant_id, "filter": ""},
                            "action_name": "get_devices",
                            "description": "Retrieved device inventory"
                        }
                    ]
                },
                {
                    "keywords": ["threat", "indicator", "ioc", "hash", "ip", "url", "intelligence"],
                    "tools": [
                        {
                            "name": "mde_get_indicators", 
                            "params": {"tenant_id": tenant_id},
                            "action_name": "get_threat_indicators",
                            "description": "Retrieved threat intelligence indicators"
                        }
                    ]
                },
                {
                    "keywords": ["incident", "alert", "investigation", "security"],
                    "tools": [
                        {
                            "name": "mde_get_incidents",
                            "params": {"tenant_id": tenant_id},
                            "action_name": "get_incidents", 
                            "description": "Retrieved security incidents"
                        }
                    ]
                },
                {
                    "keywords": ["hunt", "search", "query", "kql", "find", "detect"],
                    "tools": [
                        {
                            "name": "mde_run_hunting_query",
                            "params": {
                                "tenant_id": tenant_id,
                                "query": self._generate_hunting_query_from_intent(user_intent),
                                "comment": f"AI-generated hunting query for: {user_message[:50]}"
                            },
                            "action_name": "run_hunting_query",
                            "description": "Executed advanced hunting query"
                        }
                    ]
                },
                {
                    "keywords": ["custom", "detection", "rule"],
                    "tools": [
                        {
                            "name": "mde_get_custom_detections",
                            "params": {"tenant_id": tenant_id},
                            "action_name": "get_custom_detections",
                            "description": "Retrieved custom detection rules"
                        }
                    ]
                }
            ]
            
            # Execute relevant tools based on user intent
            executed_tools = set()  # Prevent duplicate executions
            
            for pattern in action_patterns:
                if any(keyword in user_intent for keyword in pattern["keywords"]):
                    for tool_config in pattern["tools"]:
                        tool_name = tool_config["name"]
                        
                        # Skip if we already executed this tool
                        if tool_name in executed_tools:
                            continue
                        
                        try:
                            logger.info(f"🔧 Executing MDE tool: {tool_name}")
                            result = await self._route_tool_call(tool_name, tool_config["params"])
                            
                            executed_actions.append({
                                "action": tool_config["action_name"],
                                "operation": tool_name,
                                "result": result,
                                "description": tool_config["description"],
                                "timestamp": self._get_timestamp(),
                                "success": True,
                                "parameters": tool_config["params"]
                            })
                            
                            executed_tools.add(tool_name)
                            
                            # Additional processing based on results
                            if tool_name == "mde_get_machines":
                                await self._process_device_results(user_intent, result, tenant_id, executed_actions)
                            elif tool_name == "mde_get_incidents":
                                await self._process_incident_results(user_intent, result, tenant_id, executed_actions)
                                
                        except Exception as e:
                            logger.error(f"❌ Tool execution failed for {tool_name}: {str(e)}")
                            executed_actions.append({
                                "action": tool_config["action_name"] + "_error",
                                "operation": tool_name,
                                "success": False,
                                "error": str(e),
                                "timestamp": self._get_timestamp()
                            })
            
            # If no specific tools were executed, default to device inventory
            if not executed_actions:
                logger.info("🔍 No specific intent detected, defaulting to device inventory")
                try:
                    devices_result = await self._route_tool_call("mde_get_machines", {"tenant_id": tenant_id})
                    executed_actions.append({
                        "action": "get_devices_default",
                        "operation": "mde_get_machines",
                        "result": devices_result,
                        "description": "Retrieved device inventory (default action)",
                        "timestamp": self._get_timestamp(),
                        "success": True
                    })
                except Exception as e:
                    logger.error(f"❌ Default device inventory failed: {str(e)}")
                    executed_actions.append({
                        "action": "default_error",
                        "success": False,
                        "error": str(e),
                        "timestamp": self._get_timestamp()
                    })
            
            logger.info(f"🎯 AI automation completed: {len(executed_actions)} actions executed")
            return executed_actions
        
        except Exception as e:
            logger.error(f"❌ AI automation failed: {str(e)}")
            executed_actions.append({
                "action": "automation_error",
                "success": False,
                "error": str(e),
                "timestamp": self._get_timestamp()
            })
            return executed_actions
    
    def _generate_hunting_query_from_intent(self, user_intent: str) -> str:
        """Generate appropriate KQL hunting query based on user intent."""
        if any(keyword in user_intent for keyword in ["process", "execution", "command"]):
            return """
            DeviceProcessEvents
            | where Timestamp > ago(24h)
            | where ProcessCommandLine has_any ("powershell", "cmd", "wscript")
            | where ProcessCommandLine has_any ("download", "invoke", "execute")
            | summarize count() by DeviceName, ProcessCommandLine
            | order by count_ desc
            | limit 100
            """
        elif any(keyword in user_intent for keyword in ["network", "connection", "traffic"]):
            return """
            DeviceNetworkEvents
            | where Timestamp > ago(24h)
            | where RemoteIPType == "Public"
            | summarize count() by DeviceName, RemoteIP, RemotePort
            | order by count_ desc
            | limit 100
            """
        elif any(keyword in user_intent for keyword in ["file", "download", "creation"]):
            return """
            DeviceFileEvents
            | where Timestamp > ago(24h)
            | where ActionType in ("FileCreated", "FileModified")
            | where FolderPath has_any ("Downloads", "Temp", "AppData")
            | summarize count() by DeviceName, FileName, FolderPath
            | order by count_ desc
            | limit 100
            """
        else:
            # Default general hunting query
            return """
            DeviceEvents
            | where Timestamp > ago(24h)
            | summarize count() by DeviceName, ActionType
            | order by count_ desc
            | limit 100
            """
    
    async def _process_device_results(self, user_intent: str, devices_result: Dict, tenant_id: str, executed_actions: List) -> None:
        """Process device results and execute additional actions based on intent."""
        try:
            # Check if we need to filter for high-risk devices
            if any(keyword in user_intent for keyword in ["high", "risk", "critical", "vulnerable"]):
                high_risk_devices = self._filter_high_risk_devices(devices_result)
                executed_actions.append({
                    "action": "filter_high_risk",
                    "operation": "mde_filter_devices",
                    "result": {
                        "Status": "Success",
                        "HighRiskDevices": len(high_risk_devices),
                        "Devices": high_risk_devices[:10],
                        "Message": f"Found {len(high_risk_devices)} high-risk devices"
                    },
                    "description": "Filtered high-risk devices",
                    "timestamp": self._get_timestamp(),
                    "success": True
                })
                
                # Additional actions for high-risk devices
                if any(keyword in user_intent for keyword in ["collect", "investigation", "package"]):
                    device_ids = [device.get("Id", "") for device in high_risk_devices[:5]]
                    if device_ids:
                        collection_result = await self._route_tool_call("mde_collect_investigation_package", {
                            "tenant_id": tenant_id,
                            "device_ids": device_ids
                        })
                        executed_actions.append({
                            "action": "collect_investigation_packages",
                            "operation": "mde_collect_investigation_package",
                            "result": collection_result,
                            "description": f"Collected investigation packages from {len(device_ids)} high-risk devices",
                            "timestamp": self._get_timestamp(),
                            "success": True,
                            "device_count": len(device_ids)
                        })
                
                if any(keyword in user_intent for keyword in ["isolate", "contain", "quarantine"]):
                    device_ids = [device.get("Id", "") for device in high_risk_devices[:3]]
                    if device_ids:
                        isolation_result = await self._route_tool_call("mde_isolate_device", {
                            "tenant_id": tenant_id,
                            "device_ids": device_ids
                        })
                        executed_actions.append({
                            "action": "isolate_devices",
                            "operation": "mde_isolate_device",
                            "result": isolation_result,
                            "description": f"Isolated {len(device_ids)} high-risk devices",
                            "timestamp": self._get_timestamp(),
                            "success": True,
                            "device_count": len(device_ids)
                        })
        except Exception as e:
            logger.error(f"Device processing error: {e}")
    
    async def _process_incident_results(self, user_intent: str, incidents_result: Dict, tenant_id: str, executed_actions: List) -> None:
        """Process incident results and execute additional actions based on intent."""
        try:
            if any(keyword in user_intent for keyword in ["update", "resolve", "status"]):
                # This would be enhanced to actually update incidents based on specific criteria
                logger.info("Incident update intent detected - would implement specific updates")
        except Exception as e:
            logger.error(f"Incident processing error: {e}")
            
    def _extract_device_ids(self, machines_result: Dict[str, Any]) -> List[str]:
        """Extract device IDs from a get_machines result."""
        device_ids = []
        
        try:
            # Handle different response formats from MDE API
            if isinstance(machines_result, list):
                # Direct list of machines
                for machine in machines_result:
                    if isinstance(machine, dict) and "Id" in machine:
                        device_ids.append(machine["Id"])
            elif isinstance(machines_result, dict):
                # Various nested formats
                machines_data = machines_result
                
                # Try different possible response structures
                for key in ["value", "Machines", "machines", "data", "result"]:
                    if key in machines_data and isinstance(machines_data[key], list):
                        machines_data = machines_data[key]
                        break
                
                if isinstance(machines_data, list):
                    for machine in machines_data:
                        if isinstance(machine, dict):
                            # Try different ID field names
                            for id_field in ["Id", "id", "machineId", "deviceId", "MachineId"]:
                                if id_field in machine:
                                    device_ids.append(machine[id_field])
                                    break
                        
        except Exception as e:
            logger.error(f"Error extracting device IDs: {str(e)}")
        
        logger.info(f"Extracted {len(device_ids)} device IDs from MDE response")
        return device_ids

    def _filter_high_risk_devices(self, devices_result: Dict[str, Any]) -> List[Dict[str, Any]]:
        """Filter devices to identify high-risk ones based on security criteria."""
        high_risk_devices = []
        
        try:
            # Extract devices from various response formats
            devices = []
            if isinstance(devices_result, list):
                devices = devices_result
            elif isinstance(devices_result, dict):
                # Try different possible response structures
                for key in ["value", "Machines", "machines", "data", "result"]:
                    if key in devices_result and isinstance(devices_result[key], list):
                        devices = devices_result[key]
                        break
            
            for device in devices:
                if not isinstance(device, dict):
                    continue
                    
                risk_score = 0
                risk_factors = []
                
                # Check risk factors
                risk_level = device.get("RiskScore", "").lower()
                if risk_level in ["high", "critical"]:
                    risk_score += 3
                    risk_factors.append(f"Risk Level: {risk_level}")
                elif risk_level == "medium":
                    risk_score += 2
                    risk_factors.append(f"Risk Level: {risk_level}")
                
                # Check health status
                health_status = device.get("HealthStatus", "").lower()
                if health_status in ["inactive", "misconfigured"]:
                    risk_score += 2
                    risk_factors.append(f"Health: {health_status}")
                
                # Check exposure level
                exposure_level = device.get("ExposureLevel", "").lower()
                if exposure_level in ["high", "critical"]:
                    risk_score += 2
                    risk_factors.append(f"Exposure: {exposure_level}")
                
                # Check for missing security features
                if not device.get("IsAadJoined", False):
                    risk_score += 1
                    risk_factors.append("Not AAD Joined")
                
                # Check OS version (simplified check)
                os_version = device.get("OsVersion", "")
                if "Windows 7" in os_version or "Windows 8" in os_version:
                    risk_score += 2
                    risk_factors.append("Legacy OS")
                
                # Add to high-risk list if score is 3 or higher
                if risk_score >= 3:
                    device_with_risk = device.copy()
                    device_with_risk["RiskScore"] = risk_score
                    device_with_risk["RiskFactors"] = risk_factors
                    high_risk_devices.append(device_with_risk)
                    
        except Exception as e:
            logger.error(f"Error filtering high-risk devices: {str(e)}")
        
        logger.info(f"Identified {len(high_risk_devices)} high-risk devices")
        return high_risk_devices
    
    def _get_timestamp(self) -> str:
        """Get current timestamp."""
        from datetime import datetime
        return datetime.now().isoformat()
    
    def _create_execution_summary(self, executed_actions: List[Dict[str, Any]]) -> str:
        """Create a formatted summary of executed actions."""
        if not executed_actions:
            return "No actions were executed."

        summary_lines = []
        successful_actions = 0

        for action in executed_actions:
            if action.get("success", False):
                successful_actions += 1

            action_name = action.get("action", "unknown")
            result = action.get("result", {})

            # Handle device inventory results with detailed device information
            if action_name in ("get_devices", "get_devices_default"):
                devices = []
                if isinstance(result, list):
                    devices = result
                elif isinstance(result, dict):
                    for key in ["value", "Machines", "machines", "data", "result"]:
                        if key in result and isinstance(result[key], list):
                            devices = result[key]
                            break
                if devices:
                    device_names = []
                    device_details = []
                    for device in devices:
                        if isinstance(device, dict):
                            name = (
                                device.get("DeviceName") or
                                device.get("ComputerDnsName") or
                                device.get("name") or
                                device.get("Hostname") or
                                device.get("MachineName") or
                                "Unknown"
                            )
                            if name and name != "Unknown":
                                device_names.append(name)
                                os_platform = device.get("OsPlatform", "Unknown")
                                risk_score = device.get("RiskScore", "Unknown")
                                health_status = device.get("HealthStatus", "Unknown")
                                device_details.append(f"• {name} ({os_platform}, Risk: {risk_score}, Health: {health_status})")
                    if device_names:
                        summary_lines.append(f"✅ **Device Inventory Retrieved**")
                        summary_lines.append(f"Found {len(device_names)} devices in your tenant:")
                        summary_lines.extend(device_details[:15])
                        if len(device_details) > 15:
                            summary_lines.append(f"... and {len(device_details) - 15} more devices")
                    else:
                        summary_lines.append(f"✅ **Device Inventory Retrieved**: {len(devices)} devices found (no names available)")
                else:
                    summary_lines.append(f"✅ **Device Inventory Retrieved**: No devices found or data format unknown")

            # Handle threat intelligence results
            elif action_name == "get_threat_indicators":
                indicators = []
                if isinstance(result, list):
                    indicators = result
                elif isinstance(result, dict):
                    for key in ["value", "indicators", "data", "result"]:
                        if key in result and isinstance(result[key], list):
                            indicators = result[key]
                            break
                if indicators:
                    indicator_types = {}
                    for indicator in indicators:
                        if isinstance(indicator, dict):
                            indicator_type = indicator.get("IndicatorType", "Unknown")
                            indicator_types[indicator_type] = indicator_types.get(indicator_type, 0) + 1
                    summary_lines.append(f"✅ **Threat Intelligence Retrieved**")
                    summary_lines.append(f"Found {len(indicators)} threat indicators:")
                    for ioc_type, count in indicator_types.items():
                        summary_lines.append(f"• {ioc_type}: {count} indicators")
                else:
                    summary_lines.append(f"✅ **Threat Intelligence Retrieved**: No indicators found")

            # Handle incident results
            elif action_name == "get_incidents":
                incidents = []
                if isinstance(result, list):
                    incidents = result
                elif isinstance(result, dict):
                    for key in ["value", "incidents", "data", "result"]:
                        if key in result and isinstance(result[key], list):
                            incidents = result[key]
                            break
                if incidents:
                    severity_counts = {}
                    status_counts = {}
                    for incident in incidents:
                        if isinstance(incident, dict):
                            severity = incident.get("Severity", "Unknown")
                            status = incident.get("Status", "Unknown")
                            severity_counts[severity] = severity_counts.get(severity, 0) + 1
                            status_counts[status] = status_counts.get(status, 0) + 1
                    summary_lines.append(f"✅ **Security Incidents Retrieved**")
                    summary_lines.append(f"Found {len(incidents)} incidents:")
                    summary_lines.append("**By Severity:**")
                    for severity, count in severity_counts.items():
                        summary_lines.append(f"• {severity}: {count} incidents")
                    summary_lines.append("**By Status:**")
                    for status, count in status_counts.items():
                        summary_lines.append(f"• {status}: {count} incidents")
                else:
                    summary_lines.append(f"✅ **Security Incidents Retrieved**: No incidents found")

            # Handle hunting query results
            elif action_name == "run_hunting_query":
                if isinstance(result, dict) and "Results" in result:
                    query_results = result["Results"]
                    summary_lines.append(f"✅ **Advanced Hunting Query Executed**")
                    summary_lines.append(f"Query returned {len(query_results)} results")
                    if query_results and len(query_results) > 0:
                        summary_lines.append("**Sample Results:**")
                        for i, row in enumerate(query_results[:3]):
                            if isinstance(row, dict):
                                key_fields = []
                                for field in ["DeviceName", "FileName", "ProcessCommandLine", "RemoteIP"]:
                                    if field in row:
                                        key_fields.append(f"{field}: {row[field]}")
                                if key_fields:
                                    summary_lines.append(f"• {', '.join(key_fields)}")
                else:
                    summary_lines.append(f"✅ **Advanced Hunting Query Executed**: Results format unknown")

            # Handle errors
            elif not action.get("success", False):
                error_msg = action.get("error", "Unknown error")
                summary_lines.append(f"❌ **{action.get('description', action_name)}**: Failed - {error_msg}")

            # Generic success handler for other actions
            else:
                description = action.get("description", action_name)
                summary_lines.append(f"✅ **{description}**: Completed successfully")
        
        summary_lines.append("")
        summary_lines.append(f"📊 **Summary**: {successful_actions}/{len(executed_actions)} operations completed successfully")
        return "\n".join(summary_lines)

    def _get_all_available_tools(self) -> List[Dict[str, Any]]:
        """Get all available MDE tools with descriptions."""
        try:
            from .tools import get_all_tools
            mcp_tools = get_all_tools()
            
            # Convert MCP Tool objects to dictionaries
            tools = []
            for tool in mcp_tools:
                tool_dict = {
                    "name": tool.name,
                    "description": tool.description,
                    "parameters": []
                }
                
                # Extract parameters from inputSchema if available
                if hasattr(tool, 'inputSchema') and tool.inputSchema:
                    if hasattr(tool.inputSchema, 'properties') and tool.inputSchema.properties:
                        tool_dict["parameters"] = list(tool.inputSchema.properties.keys())
                    elif isinstance(tool.inputSchema, dict) and "properties" in tool.inputSchema:
                        tool_dict["parameters"] = list(tool.inputSchema["properties"].keys())
                
                tools.append(tool_dict)
            
            return tools
            
        except ImportError:
            # Fallback tool list if tools module not available
            return [
                {
                    "name": "mde_get_machines",
                    "description": "Get list of devices/machines in MDE tenant",
                    "parameters": ["tenant_id", "filter"]
                },
                {
                    "name": "mde_isolate_device", 
                    "description": "Isolate devices from network",
                    "parameters": ["tenant_id", "device_ids", "all_devices"]
                },
                {
                    "name": "mde_unisolate_device",
                    "description": "Remove device isolation",
                    "parameters": ["tenant_id", "device_ids"]
                },
                {
                    "name": "mde_collect_investigation_package",
                    "description": "Collect forensic investigation package from devices",
                    "parameters": ["tenant_id", "device_ids"]
                },
                {
                    "name": "mde_run_antivirus_scan",
                    "description": "Run antivirus scan on devices",
                    "parameters": ["tenant_id", "device_ids", "scan_type"]
                },
                {
                    "name": "mde_get_indicators",
                    "description": "Get threat intelligence indicators (IoCs)",
                    "parameters": ["tenant_id", "indicator_type"]
                },
                {
                    "name": "mde_add_indicator",
                    "description": "Add threat intelligence indicator",
                    "parameters": ["tenant_id", "indicator_value", "indicator_type", "action", "title", "description"]
                },
                {
                    "name": "mde_remove_indicator",
                    "description": "Remove threat intelligence indicator",
                    "parameters": ["tenant_id", "indicator_id"]
                },
                {
                    "name": "mde_get_incidents",
                    "description": "Get security incidents",
                    "parameters": ["tenant_id", "status", "severity"]
                },
                {
                    "name": "mde_update_incident",
                    "description": "Update incident status or add comments",
                    "parameters": ["tenant_id", "incident_id", "status", "comment"]
                },
                {
                    "name": "mde_run_hunting_query",
                    "description": "Execute KQL hunting query",
                    "parameters": ["tenant_id", "query", "comment"]
                },
                {
                    "name": "mde_get_hunting_results",
                    "description": "Get results from hunting queries",
                    "parameters": ["tenant_id", "query_id"]
                },
                {
                    "name": "mde_get_custom_detections",
                    "description": "Get custom detection rules",
                    "parameters": ["tenant_id"]
                },
                {
                    "name": "mde_create_custom_detection",
                    "description": "Create new custom detection rule",
                    "parameters": ["tenant_id", "rule_name", "kql_query", "severity", "description"]
                }
            ]
    
    def _format_tools_for_ai(self, tools: List[Dict[str, Any]]) -> str:
        """Format tools list for AI system prompt."""
        formatted_tools = []
        
        # Group tools by category with broader keyword matching
        categories = {
            "Device Management": ["get_machines", "isolate", "unisolate", "contain", "restrict", "collect_investigation", "run_antivirus", "offboard"],
            "Live Response": ["run_live_response", "upload_to_library", "put_file", "get_file", "get_live_response_output"],
            "Action Management": ["get_actions", "cancel_actions", "get_action_status"],
            "Threat Intelligence": ["get_indicators", "add_", "remove_indicators"],
            "Incident Management": ["get_incidents", "get_incident", "update_incident", "add_incident_comment"],
            "Advanced Hunting": ["run_hunting_query", "schedule_hunt", "get_hunt_results"],
            "Custom Detections": ["get_detection_rules", "create_detection_rule", "update_detection_rule", "delete_detection_rule"],
            "Information Gathering": ["get_file_info", "get_ip_info", "get_url_info", "get_logged_in_users"],
            "AI Integration": ["ai_chat"]
        }
        
        # First, organize tools by category
        categorized_tools = {category: [] for category in categories.keys()}
        uncategorized_tools = []
        
        for tool in tools:
            tool_name = tool.get("name", "")
            description = tool.get("description", "No description")
            params = ", ".join(tool.get("parameters", []))
            tool_entry = f"  • {tool_name}: {description}"
            if params:
                tool_entry += f" (params: {params})"
            
            # Find matching category
            categorized = False
            for category, keywords in categories.items():
                if any(keyword in tool_name for keyword in keywords):
                    categorized_tools[category].append(tool_entry)
                    categorized = True
                    break
            
            if not categorized:
                uncategorized_tools.append(tool_entry)
        
        # Format output
        for category, tool_list in categorized_tools.items():
            if tool_list:
                formatted_tools.append(f"\n{category}:")
                formatted_tools.extend(tool_list)
        
        # Add uncategorized tools if any
        if uncategorized_tools:
            formatted_tools.append(f"\nOther Tools:")
            formatted_tools.extend(uncategorized_tools)
        
        # Add summary count
        total_tools = len(tools)
        summary = f"\n\nTOTAL AVAILABLE TOOLS: {total_tools} Microsoft Defender for Endpoint operations"
        
        result = "\n".join(formatted_tools) + summary
        return result if formatted_tools else f"No tools available (expected {total_tools} tools)"
        
async def main():
    """Main entry point for the MCP server."""
    try:
        # Load configuration
        config = MCPConfig.from_environment()
        
        # Create and run server
        server = MDEAutomatorMCPServer(config)
        await server.run()
        
    except Exception as e:
        logger.error("Failed to start server", error=str(e), exc_info=True)
        sys.exit(1)


if __name__ == "__main__":
    # Note: Don't use uvloop when using trio backend in MCP
    # The MCP server will handle async backend selection
    asyncio.run(main())