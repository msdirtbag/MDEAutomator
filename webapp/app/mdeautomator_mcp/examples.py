#!/usr/bin/env python3
"""
Example usage script for MDEAutomator MCP Server.

This script demonstrates how to use the MCP server programmatically
for common Microsoft Defender for Endpoint operations.
"""

import asyncio
import json
import os
import sys
from typing import Dict, Any, List

# Add the parent directory to the Python path
sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from mcp.config import MCPConfig
from mcp.function_client import FunctionAppClient


async def example_get_machines(client: FunctionAppClient, tenant_id: str = "") -> Dict[str, Any]:
    """Example: Get all Windows machines."""
    print("Example: Getting all Windows machines...")
    
    payload = {
        "TenantId": tenant_id,
        "Function": "GetMachines",
        "filter": "contains(osPlatform, 'Windows')"
    }
    
    try:
        result = await client.call_function("MDEAutomator", payload)
        print(f"✓ Found {len(result.get('value', []))} Windows machines")
        return result
    except Exception as e:
        print(f"✗ Failed to get machines: {e}")
        return {}


async def example_get_actions(client: FunctionAppClient, tenant_id: str = "") -> Dict[str, Any]:
    """Example: Get recent actions."""
    print("Example: Getting recent machine actions...")
    
    payload = {
        "TenantId": tenant_id,
        "Function": "GetActions"
    }
    
    try:
        result = await client.call_function("MDEAutomator", payload)
        actions = result.get("value", [])
        print(f"✓ Found {len(actions)} recent actions")
        
        # Show action summary
        if actions:
            action_types = {}
            for action in actions:
                action_type = action.get("type", "Unknown")
                action_types[action_type] = action_types.get(action_type, 0) + 1
            
            print("  Action types:")
            for action_type, count in action_types.items():
                print(f"    {action_type}: {count}")
        
        return result
    except Exception as e:
        print(f"✗ Failed to get actions: {e}")
        return {}


async def example_get_indicators(client: FunctionAppClient, tenant_id: str = "") -> Dict[str, Any]:
    """Example: Get threat indicators."""
    print("Example: Getting threat indicators...")
    
    payload = {
        "TenantId": tenant_id,
        "Function": "GetIndicators"
    }
    
    try:
        result = await client.call_function("MDEAutomator", payload)
        indicators = result.get("value", [])
        print(f"✓ Found {len(indicators)} threat indicators")
        
        # Show indicator summary
        if indicators:
            indicator_types = {}
            for indicator in indicators:
                indicator_type = indicator.get("indicatorType", "Unknown")
                indicator_types[indicator_type] = indicator_types.get(indicator_type, 0) + 1
            
            print("  Indicator types:")
            for indicator_type, count in indicator_types.items():
                print(f"    {indicator_type}: {count}")
        
        return result
    except Exception as e:
        print(f"✗ Failed to get indicators: {e}")
        return {}


async def example_add_file_indicators(client: FunctionAppClient, tenant_id: str = "") -> Dict[str, Any]:
    """Example: Add file indicators (dry run with invalid hashes)."""
    print("Example: Adding file indicators (demo with invalid hashes)...")
    
    # Using obviously fake hashes for demonstration
    demo_hashes = [
        "0123456789abcdef0123456789abcdef01234567",  # Fake SHA1
        "89abcdef0123456789abcdef0123456789abcdef"   # Another fake SHA1
    ]
    
    payload = {
        "TenantId": tenant_id,
        "Function": "InvokeTiFile",
        "Sha1s": demo_hashes
    }
    
    print(f"  Would add {len(demo_hashes)} file indicators:")
    for hash_val in demo_hashes:
        print(f"    SHA1: {hash_val}")
    
    # Note: Not actually calling the function with fake hashes
    print("  (Skipping actual API call with demo hashes)")
    return {"message": "Demo completed"}


async def example_hunting_query(client: FunctionAppClient, tenant_id: str = "") -> Dict[str, Any]:
    """Example: Run a hunting query."""
    print("Example: Running hunting query...")
    
    # Simple query to get recent process events
    demo_query = "DeviceProcessEvents | where Timestamp > ago(1h) | take 10"
    
    payload = {
        "TenantId": tenant_id,
        "Function": "InvokeAdvancedHunting",
        "Queries": [demo_query]
    }
    
    try:
        result = await client.call_function("MDEHunter", payload)
        print(f"✓ Hunting query executed successfully")
        
        # Show result summary
        if "Results" in result and result["Results"]:
            query_result = result["Results"][0]
            if "Tables" in query_result and query_result["Tables"]:
                rows = len(query_result["Tables"][0].get("Rows", []))
                print(f"  Query returned {rows} rows")
        
        return result
    except Exception as e:
        print(f"✗ Failed to run hunting query: {e}")
        return {}


async def main():
    """Run example operations."""
    print("MDEAutomator MCP Server Examples")
    print("=" * 50)
    
    # Load configuration
    try:
        config = MCPConfig.from_environment()
        print(f"✓ Configuration loaded")
        print(f"  Function App: {config.function_app_base_url}")
    except Exception as e:
        print(f"✗ Failed to load configuration: {e}")
        return 1
    
    # Initialize client
    client = FunctionAppClient(config)
    
    try:
        await client.initialize()
        print("✓ Function App client initialized")
        
        # Check if we have credentials for actual API calls
        has_credentials = bool(config.function_key or config.azure_client_id)
        
        if not has_credentials:
            print("\n⚠ No authentication credentials found.")
            print("  Set FUNCTION_KEY or AZURE_CLIENT_ID environment variables")
            print("  to run actual API calls. Continuing with demo mode...\n")
        
        # Get tenant ID from user or use empty string for default
        tenant_id = os.getenv("TENANT_ID", "")
        if tenant_id:
            print(f"Using tenant ID: {tenant_id}")
        else:
            print("Using default tenant (empty tenant ID)")
        
        print("\n" + "-" * 50)
        
        # Run examples
        examples = [
            ("Get Machines", example_get_machines),
            ("Get Actions", example_get_actions),
            ("Get Indicators", example_get_indicators),
            ("Add File Indicators", example_add_file_indicators),
            ("Hunting Query", example_hunting_query),
        ]
        
        for name, example_func in examples:
            print(f"\n{name}:")
            try:
                if has_credentials or name == "Add File Indicators":
                    result = await example_func(client, tenant_id)
                else:
                    print(f"  Skipping {name} (no credentials)")
            except Exception as e:
                print(f"  ✗ Example failed: {e}")
        
        print("\n" + "=" * 50)
        print("Examples completed!")
        
        if has_credentials:
            print("✓ All examples with credentials executed")
        else:
            print("⚠ Limited examples run due to missing credentials")
            print("  Configure authentication to run full examples")
        
        return 0
        
    except Exception as e:
        print(f"✗ Failed to initialize client: {e}")
        return 1
    
    finally:
        await client.close()


if __name__ == "__main__":
    # Set default environment variables if not present
    os.environ.setdefault("FUNCTION_APP_BASE_URL", "https://mdeautomator.azurewebsites.net")
    os.environ.setdefault("LOG_LEVEL", "INFO")
    
    print("To run examples with actual API calls, set these environment variables:")
    print("  FUNCTION_KEY=your-function-key")
    print("  AZURE_CLIENT_ID=your-managed-identity-client-id")
    print("  TENANT_ID=your-tenant-id (optional)")
    print("")
    
    exit_code = asyncio.run(main())
    sys.exit(exit_code)
