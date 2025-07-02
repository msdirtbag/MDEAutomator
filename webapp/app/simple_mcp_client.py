"""
Simple MCP client fallback for when full MCP server is not available.
Provides basic AI chat functionality using Azure AI Foundry directly.
"""

import asyncio
import json
import logging
import os
import sys
from typing import Any, Dict, List, Optional

logger = logging.getLogger(__name__)

class SimpleMCPClient:
    """
    Simple MCP client that provides AI chat without full MCP server dependency.
    Used as fallback when MCP server components are not available.
    """
    
    def __init__(self):
        self.ai_client = None
        self.is_initialized = False
        self._initialize_ai_client()
    
    def _initialize_ai_client(self):
        """Initialize Azure AI Foundry client."""
        try:
            # Get credentials from environment
            ai_endpoint = os.getenv("AZURE_AI_ENDPOINT")
            ai_key = os.getenv("AZURE_AI_KEY") 
            
            if not ai_endpoint or not ai_key:
                logger.info("Azure AI Foundry credentials not configured - AI features disabled")
                self.is_initialized = True  # Still initialized, just without AI
                return
            
            # Try to import and initialize OpenAI client
            try:
                import openai
                self.ai_client = openai.AzureOpenAI(
                    azure_endpoint=ai_endpoint,
                    api_key=ai_key,
                    api_version="2024-02-01"
                )
                logger.info("Azure AI Foundry client initialized successfully")
            except ImportError:
                logger.warning("OpenAI package not available - AI features disabled")
            
            self.is_initialized = True
            
        except Exception as e:
            logger.error(f"Failed to initialize AI client: {e}")
            self.is_initialized = True  # Still initialized, just without AI
    
    @property
    def is_ai_available(self) -> bool:
        """Check if AI chat functionality is available."""
        return self.ai_client is not None
    
    def get_available_tools(self) -> List[Dict[str, Any]]:
        """Get available tools (simplified for fallback mode)."""
        return [
            {
                "name": "ai_chat",
                "description": "AI-powered chat for security analysis and guidance",
                "inputSchema": {
                    "type": "object",
                    "properties": {
                        "message": {"type": "string", "description": "User message"},
                        "context": {"type": "string", "description": "Additional context"}
                    },
                    "required": ["message"]
                }
            }
        ]
    
    async def call_mcp_tool(self, tool_name: str, arguments: Dict[str, Any]) -> Dict[str, Any]:
        """Call an MCP tool (simplified implementation)."""
        try:
            if tool_name == "ai_chat":
                return await self.ai_chat(
                    arguments.get("message", ""),
                    arguments.get("context", "")
                )
            else:
                return {
                    "success": False,
                    "error": f"Tool '{tool_name}' not available in fallback mode"
                }
        except Exception as e:
            logger.error(f"Tool call failed: {e}")
            return {
                "success": False,
                "error": str(e)
            }
    
    async def ai_chat(self, message: str, context: str = "", execute_actions: bool = False, tenant_id: str = "") -> Dict[str, Any]:
        """AI chat functionality."""
        try:
            if not self.ai_client:
                return {
                    "success": False,
                    "error": "AI chat not available - Azure AI Foundry not configured",
                    "ai_response": "AI chat functionality requires Azure AI Foundry configuration. Please configure AZURE_AI_ENDPOINT and AZURE_AI_KEY environment variables."
                }
            
            # Prepare system prompt
            system_prompt = """You are an expert AI assistant specializing in Microsoft Defender for Endpoint (MDE) security operations, threat analysis, and incident response.

You help users with:
- Security analysis and threat assessment
- MDE operations guidance
- Incident response recommendations  
- KQL query explanation and optimization
- Best practices for endpoint security

Provide clear, actionable guidance and recommendations."""

            # Prepare messages
            messages = [
                {"role": "system", "content": system_prompt}
            ]
            
            if context:
                messages.append({"role": "user", "content": f"Context: {context}"})
            
            messages.append({"role": "user", "content": message})
            
            # Call Azure AI
            response = self.ai_client.chat.completions.create(
                model=os.getenv("AZURE_AI_MODEL", "gpt-4-1"),
                messages=messages,
                max_tokens=3000,
                temperature=0.7
            )
            
            ai_response = response.choices[0].message.content
            
            return {
                "success": True,
                "ai_response": ai_response,
                "automation_enabled": False,  # No automation in fallback mode
                "executed_actions": [],
                "suggestions": [],
                "source": "Azure AI Foundry (Fallback Mode)"
            }
            
        except Exception as e:
            logger.error(f"AI chat failed: {e}")
            return {
                "success": False,
                "error": str(e),
                "ai_response": "An error occurred while processing your request. Please try again."
            }
    
    async def close(self):
        """Clean up resources."""
        pass  # Nothing to clean up in simple mode


# Global client instance
_simple_client = None

def get_simple_mcp_client() -> SimpleMCPClient:
    """Get or create the simple MCP client instance."""
    global _simple_client
    if _simple_client is None:
        _simple_client = SimpleMCPClient()
    return _simple_client
