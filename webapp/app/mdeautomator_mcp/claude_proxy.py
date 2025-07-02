#!/usr/bin/env python3
"""
Local MCP proxy that connects Claude Desktop to the HTTP-based MCP server
"""

import json
import sys
import requests
import logging

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')
logger = logging.getLogger(__name__)

# MCP server endpoints
BASE_URL = "http://mcpautomator.fhgkcsesc9e2eyfv.eastus.azurecontainer.io:8080"
MCP_ENDPOINT = f"{BASE_URL}/mcp"

def main():
    try:
        # Read JSON-RPC request from stdin
        input_data = sys.stdin.read()
        logger.info(f"Received request: {input_data[:200]}...")
        
        if not input_data.strip():
            logger.error("No input data received")
            sys.exit(1)
        
        # Parse the JSON-RPC request
        request = json.loads(input_data)
        logger.info(f"Parsed request method: {request.get('method', 'unknown')}")
        
        # Forward to HTTP MCP server
        response = requests.post(
            MCP_ENDPOINT,
            json=request,
            headers={'Content-Type': 'application/json'},
            timeout=30
        )
        
        if response.status_code == 200:
            # Return the response
            result = response.json()
            print(json.dumps(result))
            logger.info(f"Success: {result.get('result', {}).get('serverInfo', {}).get('name', 'unknown')}")
        else:
            # Return error response
            error_response = {
                "jsonrpc": "2.0",
                "id": request.get("id"),
                "error": {
                    "code": -32603,
                    "message": f"HTTP error {response.status_code}",
                    "data": response.text
                }
            }
            print(json.dumps(error_response))
            logger.error(f"HTTP error {response.status_code}: {response.text}")
    
    except json.JSONDecodeError as e:
        logger.error(f"JSON decode error: {e}")
        error_response = {
            "jsonrpc": "2.0",
            "id": None,
            "error": {
                "code": -32700,
                "message": "Parse error",
                "data": str(e)
            }
        }
        print(json.dumps(error_response))
        sys.exit(1)
    
    except requests.RequestException as e:
        logger.error(f"Request error: {e}")
        error_response = {
            "jsonrpc": "2.0",
            "id": None,
            "error": {
                "code": -32603,
                "message": "Internal error",
                "data": str(e)
            }
        }
        print(json.dumps(error_response))
        sys.exit(1)
    
    except Exception as e:
        logger.error(f"Unexpected error: {e}")
        error_response = {
            "jsonrpc": "2.0",
            "id": None,
            "error": {
                "code": -32603,
                "message": "Internal error",
                "data": str(e)
            }
        }
        print(json.dumps(error_response))
        sys.exit(1)

if __name__ == "__main__":
    main()
