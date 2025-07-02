"""
Simple test script for MDEAutomator MCP Server.

This script provides basic validation of the MCP server functionality
including configuration loading, tool listing, and basic connectivity tests.
"""

import asyncio
import json
import os
import sys
from typing import Dict, Any
from dotenv import load_dotenv

# Load environment variables from .env file
load_dotenv()

# Add the current directory to the Python path
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from config import MCPConfig
from function_client import FunctionAppClient  
from tools import get_all_tools


async def test_configuration():
    """Test configuration loading."""
    print("Testing configuration loading...")
    
    try:
        config = MCPConfig.from_environment()
        print(f"✓ Configuration loaded successfully")
        print(f"  Function App URL: {config.function_app_base_url}")
        print(f"  Log Level: {config.log_level}")
        print(f"  Request Timeout: {config.request_timeout}s")
        print(f"  Rate Limit: {config.rate_limit_requests} requests/minute")
        return True
    except Exception as e:
        print(f"✗ Configuration loading failed: {e}")
        return False


async def test_tools():
    """Test tool definitions."""
    print("\nTesting tool definitions...")
    
    try:
        tools = get_all_tools()
        print(f"✓ {len(tools)} tools loaded successfully")
        
        # Show a few example tools
        for i, tool in enumerate(tools[:5]):
            print(f"  {i+1}. {tool.name}: {tool.description[:60]}...")
        
        if len(tools) > 5:
            print(f"  ... and {len(tools) - 5} more tools")
        
        return True
    except Exception as e:
        print(f"✗ Tool loading failed: {e}")
        return False


async def test_function_client():
    """Test Function App client initialization."""
    print("\nTesting Function App client...")
    
    try:
        config = MCPConfig.from_environment()
        client = FunctionAppClient(config)
        
        # Initialize client
        await client.initialize()
        print("✓ Function App client initialized successfully")
        
        # Test health check if credentials are available
        if config.function_key or config.azure_client_id:
            try:
                health_ok = await client.health_check()
                if health_ok:
                    print("✓ Health check passed")
                else:
                    print("⚠ Health check failed (may be expected without proper credentials)")
            except Exception as e:
                print(f"⚠ Health check failed: {e} (may be expected without proper credentials)")
        else:
            print("⚠ No credentials configured, skipping health check")
        
        await client.close()
        return True
    except Exception as e:
        print(f"✗ Function App client test failed: {e}")
        return False


async def test_tool_validation():
    """Test tool input validation."""
    print("\nTesting tool input validation...")
    
    try:
        # Test valid inputs
        valid_inputs = {
            "mde_get_machines": {"tenant_id": "test-tenant"},
            "mde_isolate_device": {"tenant_id": "test-tenant", "device_ids": ["device1", "device2"]},
            "mde_add_file_indicators": {"tenant_id": "test-tenant", "sha256_hashes": ["abc123"]}
        }
        
        tools_dict = {tool.name: tool for tool in get_all_tools()}
        
        for tool_name, test_input in valid_inputs.items():
            if tool_name in tools_dict:
                tool = tools_dict[tool_name]
                # Basic validation that required fields are present
                required_fields = tool.inputSchema.get("required", [])
                for field in required_fields:
                    if field not in test_input:
                        print(f"✗ Tool {tool_name} missing required field: {field}")
                        return False
                print(f"✓ Tool {tool_name} validation passed")
        
        return True
    except Exception as e:
        print(f"✗ Tool validation failed: {e}")
        return False


async def main():
    """Run all tests."""
    print("MDEAutomator MCP Server Test Suite")
    print("=" * 50)
    
    tests = [
        test_configuration,
        test_tools,
        test_function_client,
        test_tool_validation,
    ]
    
    results = []
    for test in tests:
        try:
            result = await test()
            results.append(result)
        except Exception as e:
            print(f"✗ Test {test.__name__} failed with exception: {e}")
            results.append(False)
    
    print("\n" + "=" * 50)
    print("Test Summary:")
    
    passed = sum(results)
    total = len(results)
    
    for i, (test, result) in enumerate(zip(tests, results)):
        status = "✓ PASS" if result else "✗ FAIL"
        print(f"  {status} {test.__name__}")
    
    print(f"\nResults: {passed}/{total} tests passed")
    
    if passed == total:
        print("🎉 All tests passed! The MCP server is ready.")
        return 0
    else:
        print("❌ Some tests failed. Please check the configuration and try again.")
        return 1


if __name__ == "__main__":
    # Set some default environment variables for testing
    os.environ.setdefault("FUNCTION_APP_BASE_URL", "https://mdeautomator.azurewebsites.net")
    os.environ.setdefault("LOG_LEVEL", "INFO")
    
    exit_code = asyncio.run(main())
    sys.exit(exit_code)
