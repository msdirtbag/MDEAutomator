"""
MCP Client for integrating MDEAutomator MCP server functionality into Flask webapp.
Provides both AI chat and MDE operations through a unified interface.
"""

import asyncio
import json
import logging
import os
import sys
from typing import Any, Dict, List, Optional

import httpx
import openai
from azure.identity import DefaultAzureCredential

logger = logging.getLogger(__name__)

# Add the MCP module to the path
current_dir = os.path.dirname(os.path.abspath(__file__))
mcp_dir = os.path.join(current_dir, 'mdeautomator_mcp')
if mcp_dir not in sys.path:
    sys.path.insert(0, mcp_dir)

# Also add the parent app directory
app_dir = os.path.dirname(current_dir)
if app_dir not in sys.path:
    sys.path.insert(0, app_dir)

# Try to import the full MCP server components
try:
    # Import from the mdeautomator_mcp package
    from mdeautomator_mcp.server import MDEAutomatorMCPServer
    from mdeautomator_mcp.config import MCPConfig
    from mdeautomator_mcp.tools import get_all_tools
    MCP_AVAILABLE = True
    print("Full MCP server components loaded successfully")
except ImportError as e:
    print(f"Warning: Could not import full MCP server ({e}). Using simple fallback client.")
    # Try alternative import paths
    try:
        import sys
        import os
        
        # Try direct import with absolute path
        mcp_server_path = os.path.join(current_dir, 'mdeautomator_mcp', 'server.py')
        mcp_config_path = os.path.join(current_dir, 'mdeautomator_mcp', 'config.py')
        mcp_tools_path = os.path.join(current_dir, 'mdeautomator_mcp', 'tools.py')
        
        if all(os.path.exists(p) for p in [mcp_server_path, mcp_config_path, mcp_tools_path]):
            import importlib.util
            
            # Load config module
            spec = importlib.util.spec_from_file_location("mcp_config_module", mcp_config_path)
            mcp_config_module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mcp_config_module)
            MCPConfig = mcp_config_module.MCPConfig
            
            # Load server module 
            spec = importlib.util.spec_from_file_location("mcp_server_module", mcp_server_path)
            mcp_server_module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mcp_server_module)
            MDEAutomatorMCPServer = mcp_server_module.MDEAutomatorMCPServer
            
            # Load tools module
            spec = importlib.util.spec_from_file_location("mcp_tools_module", mcp_tools_path)
            mcp_tools_module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(mcp_tools_module)
            get_all_tools = mcp_tools_module.get_all_tools
            
            MCP_AVAILABLE = True
            print("MCP server components loaded via importlib")
        else:
            raise ImportError("MCP server files not found")
            
    except Exception as e2:
        print(f"Alternative import also failed ({e2}). Using simple fallback client.")
        MCP_AVAILABLE = False
        MDEAutomatorMCPServer = None
        MCPConfig = None
        get_all_tools = lambda: []


class IntegratedMCPClient:
    """
    Integrated MCP client that provides both AI chat and MDE operations
    through the existing MDEAutomator MCP server components.
    """
    
    def __init__(self, flask_config=None):
        self.mcp_server = None
        self.ai_client = None
        self.is_initialized = False
        self.flask_config = flask_config
        if MCP_AVAILABLE:
            self._initialize()
        else:
            logger.warning("MCP server not available - AI features disabled")
    
    def _initialize(self):
        """Initialize both MCP server and AI client."""
        try:
            # Initialize MCP configuration
            if MCPConfig:
                if self.flask_config:
                    config = MCPConfig.from_flask_config(self.flask_config)
                else:
                    config = MCPConfig.from_environment()
                
                # Initialize MCP server
                self.mcp_server = MDEAutomatorMCPServer(config)
            
            # Initialize AI client
            self._initialize_ai_client()
            
            self.is_initialized = True
            logger.info("Integrated MCP client initialized successfully")
            
        except Exception as e:
            logger.error(f"Failed to initialize MCP client: {e}")
            self.is_initialized = False
    
    def _initialize_ai_client(self):
        """Initialize Azure AI Foundry client using Flask config or environment."""
        try:
            # Get credentials from Flask config first, then fallback to environment
            if self.flask_config:
                ai_endpoint = (
                    self.flask_config.get('AZURE_AI_ENDPOINT') or
                    os.getenv("AZURE_AI_ENDPOINT")
                )
                ai_key = (
                    self.flask_config.get('AZURE_AI_KEY') or
                    os.getenv("AZURE_AI_KEY")
                )
                deployment_name = (
                    self.flask_config.get('AZURE_AI_DEPLOYMENT') or
                    os.getenv("AZURE_AI_DEPLOYMENT", "gpt-4")
                )
            else:
                # Fallback to environment variables
                ai_endpoint = os.getenv("AZURE_AI_ENDPOINT")
                ai_key = os.getenv("AZURE_AI_KEY")
                deployment_name = os.getenv("AZURE_AI_DEPLOYMENT", "gpt-4")
            
            if not ai_endpoint or not ai_key:
                logger.warning(f"Azure AI Foundry credentials not configured - AI features disabled")
                logger.warning(f"ai_endpoint present: {bool(ai_endpoint)}, ai_key present: {bool(ai_key)}")
                if self.flask_config:
                    logger.warning(f"Flask config keys: {list(self.flask_config.keys())}")
                return
                
            # Try to initialize Azure OpenAI client
            self.ai_client = openai.AzureOpenAI(
                azure_endpoint=ai_endpoint,
                api_key=ai_key,
                api_version="2024-02-01"
            )
            
            # Test the connection with a simple call
            try:
                test_response = self.ai_client.chat.completions.create(
                    model=deployment_name,
                    messages=[{"role": "user", "content": "Test"}],
                    max_tokens=5
                )
                logger.info("Azure AI Foundry client initialized and tested successfully")
            except Exception as test_error:
                logger.warning(f"Azure AI Foundry client created but connection test failed: {test_error}")
                # Check if it's a private endpoint issue
                if "Public access is disabled" in str(test_error) or "private endpoint" in str(test_error):
                    logger.warning("Azure OpenAI requires private endpoint access - AI features disabled in current network")
                self.ai_client = None
            
        except Exception as e:
            logger.error(f"Failed to initialize Azure AI Foundry client: {e}")
            self.ai_client = None
    
    async def ensure_initialized(self):
        """Ensure the MCP server is properly initialized."""
        if not self.is_initialized:
            raise Exception("MCP client not initialized")
            
        # Initialize the function client if it exists but hasn't been initialized
        if hasattr(self.mcp_server, 'function_client') and self.mcp_server.function_client:
            # Check if the function client needs initialization
            if not hasattr(self.mcp_server.function_client, 'http_client') or not self.mcp_server.function_client.http_client:
                await self.mcp_server.function_client.initialize()
    
    def get_available_tools(self) -> List[Dict[str, Any]]:
        """Get all available MCP tools."""
        try:
            if not MCP_AVAILABLE or not get_all_tools:
                return []
                
            tools = get_all_tools()
            return [
                {
                    "name": tool.name,
                    "description": tool.description,
                    "inputSchema": tool.inputSchema
                }
                for tool in tools
            ]
        except Exception as e:
            logger.error(f"Failed to get tools: {e}")
            return []
    
    async def call_mcp_tool(self, tool_name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Call an MCP tool directly."""
        try:
            await self.ensure_initialized()
            
            # Route the tool call through the MCP server
            result = await self.mcp_server._route_tool_call(tool_name, arguments)
            
            return {
                "success": True,
                "tool": tool_name,
                "result": result,
                "timestamp": json.dumps({"timestamp": "now"})  # Add timestamp
            }
            
        except Exception as e:
            logger.error(f"MCP tool call failed: {e}")
            return {
                "success": False,
                "tool": tool_name,
                "error": str(e),
                "timestamp": json.dumps({"timestamp": "now"})
            }
    
    async def ai_chat(self, message: str, context: str = "", execute_actions: bool = False, tenant_id: str = "") -> Dict[str, Any]:
        """Enhanced AI chat with optional MDE automation."""
        try:
            await self.ensure_initialized()
            
            # Use the MCP server's AI chat handler
            arguments = {
                "message": message,
                "context": context,
                "execute_actions": execute_actions,
                "tenant_id": tenant_id,
                "max_tokens": 3000,
                "temperature": 0.7
            }
            
            result = await self.call_mcp_tool("mde_ai_chat", arguments)
            
            if result.get("success", False):
                tool_result = result.get("result", {})
                return {
                    "success": True,
                    "ai_response": tool_result.get("ai_response", ""),
                    "executed_actions": tool_result.get("executed_actions", []),
                    "automation_enabled": tool_result.get("automation_enabled", False),
                    "suggestions": tool_result.get("suggestions", []),
                    "metadata": tool_result.get("metadata", {})
                }
            else:
                return {
                    "success": True,
                    "ai_response": "",
                    "executed_actions": [],
                    "automation_enabled": False,
                    "suggestions": [],
                    "metadata": {
                        "error": f"AI Chat failed: {result.get('error', 'Unknown error')}",
                        "status": "Error",
                        "suggestions": []
                    }
                }
            
        except Exception as e:
            logger.error(f"AI chat failed: {e}")
            return {
                "success": False,
                "error": str(e),
                "ai_response": "Sorry, I encountered an error. Please try again.",
                "executed_actions": [],
                "automation_enabled": False
            }
    
    async def close(self):
        """Clean up resources."""
        try:
            if self.mcp_server and hasattr(self.mcp_server, 'function_client'):
                await self.mcp_server.function_client.close()
        except Exception as e:
            logger.error(f"Error closing MCP client: {e}")
    
    @property
    def is_ai_available(self) -> bool:
        """Check if AI functionality is available."""
        return (self.ai_client is not None and 
                hasattr(self, 'ai_client') and 
                self.is_initialized)


# Legacy compatibility classes
class MCPAIClient(IntegratedMCPClient):
    """Legacy compatibility class - use IntegratedMCPClient instead."""
    
    async def chat_completion(self, message: str, context: str = "", system_prompt: str = "") -> Dict[str, Any]:
        """Get AI chat completion with MDE tool awareness."""
        if not self.ai_client:
            return {"error": "Azure AI Foundry client not initialized"}
        
        try:
            # Enhanced system prompt with MDE tool knowledge
            if not system_prompt:
                system_prompt = """You are an expert AI assistant specializing in Microsoft Defender for Endpoint (MDE) security operations, threat analysis, and incident response.

IMPORTANT: The user has access to these MDE capabilities through their system:

DEVICE MANAGEMENT:
- Get device lists with filtering (e.g., high-risk devices)
- Isolate/unisolate devices from network
- Collect investigation packages for forensics
- Run antivirus scans on devices
- Manage device groups and policies

THREAT INTELLIGENCE:
- Add file, IP, URL, and certificate indicators
- Remove threat indicators
- Query existing indicators
- Bulk upload IOCs from files

HUNTING & ANALYSIS:
- Execute KQL hunting queries
- Schedule recurring hunts
- Analyze hunt results
- Advanced threat detection

INCIDENT MANAGEMENT:
- Retrieve and manage security incidents
- Update incident status and assignments
- Add comments and track resolution
- Escalate critical incidents

When users ask for help, provide:
1. **Security Analysis**: Your expert assessment of the situation
2. **Recommended Actions**: Specific steps they should take
3. **Risk Assessment**: Priority and urgency levels
4. **Best Practices**: Industry-standard security guidance

Always prioritize security and provide actionable, specific recommendations."""

            # Prepare messages
            messages = [
                {"role": "system", "content": system_prompt}
            ]
            
            if context:
                messages.append({"role": "user", "content": f"Context: {context}"})
            
            messages.append({"role": "user", "content": message})
            
            # Call Azure AI Foundry
            response = self.ai_client.chat.completions.create(
                model="gpt-4.1",  # Your model name
                messages=messages,
                max_tokens=3000,
                temperature=0.7
            )
            
            # Extract response
            ai_response = response.choices[0].message.content
            usage = response.usage
            
            return {
                "status": "success",
                "ai_response": ai_response,
                "model_used": "gpt-4.1",
                "tokens_used": {
                    "prompt_tokens": usage.prompt_tokens,
                    "completion_tokens": usage.completion_tokens,
                    "total_tokens": usage.total_tokens
                },
                "timestamp": "2025-06-25T20:00:00Z",
                "suggestions": self._extract_action_suggestions(ai_response)
            }
            
        except Exception as e:
            logger.error(f"AI chat completion failed: {e}")
            return {
                "status": "error",
                "error": str(e),
                "timestamp": "2025-06-25T20:00:00Z"
            }
    
    def _extract_action_suggestions(self, ai_response: str) -> List[str]:
        """Extract actionable suggestions from AI response."""
        suggestions = []
        
        # Look for action patterns
        import re
        action_patterns = [
            r"isolate.*device",
            r"run.*scan", 
            r"quarantine.*file",
            r"hunt.*for",
            r"check.*incident",
            r"investigate.*alert",
            r"collect.*package",
            r"block.*indicator"
        ]
        
        for pattern in action_patterns:
            if re.search(pattern, ai_response, re.IGNORECASE):
                suggestions.append(f"Consider: {pattern.replace('.*', ' ')}")
        
        return suggestions[:3]


class MCPDeviceClient:
    """MDE device management operations."""
    
    def __init__(self, function_client):
        self.function_client = function_client
    
    async def get_machines(self, tenant_id: str = "", filter_expr: str = "") -> Dict[str, Any]:
        """Get device list with optional filtering."""
        payload = {
            "TenantId": tenant_id,
            "Function": "GetMachines",
            "filter": filter_expr
        }
        return await self.function_client.call_function("MDEAutomator", payload)
    
    async def isolate_devices(self, tenant_id: str, device_ids: List[str] = None, all_devices: bool = False) -> Dict[str, Any]:
        """Isolate devices from network."""
        payload = {
            "TenantId": tenant_id,
            "Function": "InvokeMachineIsolation",
            "allDevices": all_devices
        }
        
        if not all_devices and device_ids:
            payload["DeviceIds"] = device_ids
            
        return await self.function_client.call_function("MDEDispatcher", payload)
    
    async def collect_investigation_packages(self, tenant_id: str, device_ids: List[str]) -> Dict[str, Any]:
        """Collect forensic investigation packages."""
        payload = {
            "TenantId": tenant_id,
            "Function": "InvokeCollectInvestigationPackage",
            "DeviceIds": device_ids
        }
        return await self.function_client.call_function("MDEDispatcher", payload)
    
    async def run_antivirus_scan(self, tenant_id: str, device_ids: List[str]) -> Dict[str, Any]:
        """Run full antivirus scan on devices."""
        payload = {
            "TenantId": tenant_id,
            "Function": "InvokeFullDiskScan",
            "DeviceIds": device_ids
        }
        return await self.function_client.call_function("MDEDispatcher", payload)


class MCPThreatIntelClient:
    """MDE threat intelligence operations."""
    
    def __init__(self, function_client):
        self.function_client = function_client
    
    async def add_file_indicators(self, tenant_id: str, sha1_hashes: List[str] = None, sha256_hashes: List[str] = None) -> Dict[str, Any]:
        """Add file hash indicators."""
        payload = {
            "TenantId": tenant_id,
            "Function": "InvokeTiFile",
            "Sha1s": sha1_hashes or [],
            "Sha256s": sha256_hashes or []
        }
        return await self.function_client.call_function("MDETIManager", payload)
    
    async def add_ip_indicators(self, tenant_id: str, ip_addresses: List[str]) -> Dict[str, Any]:
        """Add IP address indicators."""
        payload = {
            "TenantId": tenant_id,
            "Function": "InvokeTiIP",
            "IPs": ip_addresses
        }
        return await self.function_client.call_function("MDETIManager", payload)


class MDEAutomatorMCPClient:
    """
    Unified MCP client that provides both AI chat and MDE operations.
    Replaces the need for separate Azure Function calls and MDEAutoChat.
    """
    
    def __init__(self, function_url: str = None, function_key: str = None):
        self.function_url = function_url or os.getenv('FUNCTION_APP_BASE_URL')
        self.function_key = function_key or os.getenv('FUNCTION_KEY')
        
        # Initialize AI client
        self.ai_client = MCPAIClient()
        
        # Initialize MDE operation clients
        self.devices = MCPDeviceClient(self)
        self.threat_intel = MCPThreatIntelClient(self)
        
        logger.info("MDEAutomator MCP Client initialized")
    
    @property
    def is_ai_available(self) -> bool:
        """Check if AI chat functionality is available."""
        return (self.ai_client and 
                hasattr(self.ai_client, 'ai_client') and 
                self.ai_client.ai_client is not None)
    
    @property
    def is_initialized(self) -> bool:
        """Check if the MCP client is properly initialized."""
        return self.ai_client and self.ai_client.is_initialized
    
    async def call_function(self, function_name: str, payload: Dict[str, Any]) -> Dict[str, Any]:
        """Call Azure Function (existing functionality)."""
        if not self.function_url or not self.function_key:
            return {"error": "Azure Function URL or key not configured"}
        
        url = f"https://{self.function_url}/api/{function_name}?code={self.function_key}"
        
        try:
            async with httpx.AsyncClient(timeout=30.0) as client:
                response = await client.post(url, json=payload)
                response.raise_for_status()
                
                if response.status_code == 204:
                    return {"status": "success", "message": f"{function_name} completed"}
                
                return response.json()
                
        except Exception as e:
            logger.error(f"Azure Function call failed: {e}")
            return {"error": str(e)}
    
    async def ai_chat(self, message: str, context: str = "", execute_actions: bool = False, tenant_id: str = "") -> Dict[str, Any]:
        """AI-powered chat with optional automatic action execution."""
        
        # Get AI analysis
        ai_result = await self.ai_client.chat_completion(message, context)
        
        if ai_result.get("status") != "success":
            return ai_result
        
        # If execute_actions is enabled, parse AI response and execute recommended actions
        executed_actions = []
        if execute_actions and tenant_id:
            logger.info("AI automation mode enabled")
            executed_actions = await self._execute_ai_recommendations(
                ai_result["ai_response"], tenant_id
            )
        
        # Enhanced response
        return {
            **ai_result,
            "automation_enabled": execute_actions,
            "executed_actions": executed_actions,
            "note": "Set execute_actions=true and provide tenant_id to enable AI automation"
        }
    
    async def _execute_ai_recommendations(self, ai_response: str, tenant_id: str) -> List[Dict[str, Any]]:
        """Execute actions recommended by AI."""
        executed_actions = []
        
        try:
            import re
            
            # Check for high-risk device isolation recommendation
            if re.search(r"isolate.*high.?risk", ai_response, re.IGNORECASE):
                logger.info("AI recommended isolation of high-risk devices")
                
                # Get high-risk devices
                machines_result = await self.devices.get_machines(
                    tenant_id=tenant_id,
                    filter_expr="riskScore eq 'High'"
                )
                
                executed_actions.append({
                    "action": "get_high_risk_machines",
                    "result": machines_result,
                    "timestamp": "2025-06-25T20:00:00Z"
                })
                
                # Extract device IDs and execute actions
                device_ids = self._extract_device_ids(machines_result)
                
                if device_ids:
                    # Collect investigation packages
                    if re.search(r"collect.*investigation", ai_response, re.IGNORECASE):
                        collect_result = await self.devices.collect_investigation_packages(
                            tenant_id=tenant_id,
                            device_ids=device_ids
                        )
                        executed_actions.append({
                            "action": "collect_investigation_packages",
                            "device_count": len(device_ids),
                            "result": collect_result,
                            "timestamp": "2025-06-25T20:00:00Z"
                        })
                    
                    # Isolate devices
                    isolation_result = await self.devices.isolate_devices(
                        tenant_id=tenant_id,
                        device_ids=device_ids
                    )
                    executed_actions.append({
                        "action": "isolate_high_risk_devices", 
                        "device_count": len(device_ids),
                        "result": isolation_result,
                        "timestamp": "2025-06-25T20:00:00Z"
                    })
            
            logger.info(f"AI automation executed {len(executed_actions)} actions")
            
        except Exception as e:
            logger.error(f"AI automation error: {e}")
            executed_actions.append({
                "action": "automation_error",
                "error": str(e),
                "timestamp": "2025-06-25T20:00:00Z"
            })
        
        return executed_actions
    
    def _extract_device_ids(self, machines_result: Dict[str, Any]) -> List[str]:
        """Extract device IDs from machines API result."""
        device_ids = []
        
        try:
            # Handle different response formats
            machines_data = machines_result.get("Machines", [])
            if not machines_data:
                machines_data = machines_result.get("value", [])
            
            for machine in machines_data:
                if isinstance(machine, dict) and "id" in machine:
                    device_ids.append(machine["id"])
                    
        except Exception as e:
            logger.error(f"Error extracting device IDs: {e}")
        
        return device_ids


# Global MCP client instance
mcp_client = None

def get_mcp_client(flask_config=None):
    """Get or create the global MCP client instance."""
    global mcp_client
    
    # If we already have a client and no specific Flask config is needed, return existing
    if mcp_client is not None and flask_config is None:
        return mcp_client
    
    # If we have Flask config and either no client or need to reinitialize with Flask config
    if flask_config is not None and (mcp_client is None or not hasattr(mcp_client, 'flask_config') or mcp_client.flask_config is None):
        try:
            if MCP_AVAILABLE:
                mcp_client = IntegratedMCPClient(flask_config=flask_config)
            else:
                # Fall back to simple client
                from .simple_mcp_client import get_simple_mcp_client
                mcp_client = get_simple_mcp_client()
                logger.info("Using simple MCP client (fallback mode)")
        except Exception as e:
            logger.error(f"Failed to initialize MCP client with Flask config: {e}")
            # Ultimate fallback to simple client
            from .simple_mcp_client import get_simple_mcp_client
            mcp_client = get_simple_mcp_client()
            logger.info("Using simple MCP client (error fallback)")
    
    # If no client exists at all, create one without Flask config
    elif mcp_client is None:
        try:
            if MCP_AVAILABLE:
                mcp_client = IntegratedMCPClient(flask_config=flask_config)
            else:
                # Fall back to simple client
                from .simple_mcp_client import get_simple_mcp_client
                mcp_client = get_simple_mcp_client()
                logger.info("Using simple MCP client (fallback mode)")
        except Exception as e:
            logger.error(f"Failed to initialize MCP client: {e}")
            # Ultimate fallback to simple client
            from .simple_mcp_client import get_simple_mcp_client
            mcp_client = get_simple_mcp_client()
            logger.info("Using simple MCP client (error fallback)")
    
    return mcp_client
