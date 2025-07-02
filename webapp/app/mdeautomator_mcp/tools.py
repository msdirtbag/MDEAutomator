"""
MCP tool definitions for MDEAutomator operations.

This module defines all the tools available through the MCP server, providing
a comprehensive interface to Microsoft Defender for Endpoint operations.
"""

from typing import List
from mcp.types import Tool


def get_all_tools() -> List[Tool]:
    """Get all available MCP tools for MDEAutomator operations."""
    tools = []
    
    # Device Management Tools
    tools.extend(get_device_management_tools())
    
    # Live Response Tools
    tools.extend(get_live_response_tools())
    
    # Action Management Tools
    tools.extend(get_action_management_tools())
    
    # Threat Intelligence Tools
    tools.extend(get_threat_intelligence_tools())
    
    # Hunting Tools
    tools.extend(get_hunting_tools())
    
    # Incident Management Tools
    tools.extend(get_incident_management_tools())
    
    # Custom Detection Tools
    tools.extend(get_custom_detection_tools())
    
    # Information Gathering Tools
    tools.extend(get_information_tools())
    
    # AI Integration Tools
    tools.extend(get_ai_integration_tools())
    
    return tools


def get_device_management_tools() -> List[Tool]:
    """Get device management tools."""
    return [
        Tool(
            name="mde_get_machines",
            description="Retrieve devices from Microsoft Defender for Endpoint. Supports OData filtering to find specific devices by properties like OS platform, risk score, tags, etc.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation (optional for default tenant)"
                    },
                    "filter": {
                        "type": "string", 
                        "description": "OData filter expression (e.g., \"contains(osPlatform, 'Windows')\" or \"riskScore eq 'High'\")"
                    }
                },
                "required": []
            }
        ),
        Tool(
            name="mde_isolate_device",
            description="Isolate devices from the network to prevent lateral movement. Uses selective isolation by default, allowing only Defender for Endpoint communication.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "device_ids": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of device IDs to isolate"
                    },
                    "all_devices": {
                        "type": "boolean",
                        "description": "Isolate all devices in the tenant",
                        "default": False
                    }
                },
                "required": ["tenant_id"]
            }
        ),
        Tool(
            name="mde_unisolate_device",
            description="Remove isolation from devices, restoring normal network connectivity.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "device_ids": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of device IDs to unisolate"
                    }
                },
                "required": ["tenant_id", "device_ids"]
            }
        ),
        Tool(
            name="mde_contain_device",
            description="Contain unmanaged devices to restrict network connectivity and prevent lateral movement.",
            inputSchema={
                "type": "object", 
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "device_ids": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of device IDs to contain"
                    }
                },
                "required": ["tenant_id", "device_ids"]
            }
        ),
        Tool(
            name="mde_restrict_app_execution",
            description="Restrict application execution on devices, allowing only Microsoft-signed binaries to run.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "device_ids": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of device IDs to restrict"
                    }
                },
                "required": ["tenant_id", "device_ids"]
            }
        ),
        Tool(
            name="mde_collect_investigation_package",
            description="Collect forensic investigation packages from devices containing artifacts for analysis.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "device_ids": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of device IDs to collect packages from"
                    }
                },
                "required": ["tenant_id", "device_ids"]
            }
        ),
        Tool(
            name="mde_run_antivirus_scan",
            description="Run a full disk antivirus scan on specified devices.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "device_ids": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of device IDs to scan"
                    }
                },
                "required": ["tenant_id", "device_ids"]
            }
        ),
        Tool(
            name="mde_stop_and_quarantine_file",
            description="Stop and quarantine a file on devices by SHA1 hash. Prevents file execution and moves it to quarantine.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "sha1_hash": {
                        "type": "string",
                        "description": "SHA1 hash of the file to stop and quarantine"
                    },
                    "all_devices": {
                        "type": "boolean",
                        "description": "Apply to all devices",
                        "default": True
                    }
                },
                "required": ["tenant_id", "sha1_hash"]
            }
        ),
        Tool(
            name="mde_offboard_device",
            description="Permanently offboard devices from Microsoft Defender for Endpoint. This removes devices from management and monitoring.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "device_ids": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of device IDs to offboard"
                    }
                },
                "required": ["tenant_id", "device_ids"]
            }
        )
    ]


def get_live_response_tools() -> List[Tool]:
    """Get live response tools."""
    return [
        Tool(
            name="mde_run_live_response_script",
            description="Execute a PowerShell script from the Live Response library on specified devices. Returns execution results and output.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "device_ids": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of device IDs to run script on"
                    },
                    "script_name": {
                        "type": "string",
                        "description": "Name of the script in the Live Response library (e.g., 'Active.ps1')"
                    }
                },
                "required": ["tenant_id", "device_ids", "script_name"]
            }
        ),
        Tool(
            name="mde_upload_to_library",
            description="Upload a file to the Live Response library for later use. Supports both file path and base64 content upload.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "file_path": {
                        "type": "string",
                        "description": "Local file path to upload"
                    },
                    "file_content": {
                        "type": "string",
                        "description": "Base64 encoded file content (alternative to file_path)"
                    },
                    "target_filename": {
                        "type": "string",
                        "description": "Target filename in the library (required when using file_content)"
                    }
                },
                "required": ["tenant_id"],
                "oneOf": [
                    {"required": ["file_path"]},
                    {"required": ["file_content", "target_filename"]}
                ]
            }
        ),
        Tool(
            name="mde_put_file",
            description="Push a file from the Live Response library to specified devices.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "device_ids": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of device IDs to receive the file"
                    },
                    "file_name": {
                        "type": "string",
                        "description": "Name of the file in the Live Response library"
                    }
                },
                "required": ["tenant_id", "device_ids", "file_name"]
            }
        ),
        Tool(
            name="mde_get_file",
            description="Retrieve a file from specified devices using Live Response. Returns download URLs for the collected files.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "device_ids": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of device IDs to retrieve file from"
                    },
                    "file_path": {
                        "type": "string",
                        "description": "Full path to the file on the device (e.g., 'C:\\Temp\\error.log')"
                    }                },
                "required": ["tenant_id", "device_ids", "file_path"]
            }
        ),
        Tool(
            name="mde_get_live_response_output",
            description="Retrieve the output of live response actions. Use this to get results from previously executed live response commands or scripts.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "action_id": {
                        "type": "string",
                        "description": "Action ID from a previous live response action"
                    },
                    "command_index": {
                        "type": "integer",
                        "description": "Index of the command in the action (optional, defaults to 0)",
                        "default": 0
                    }
                },
                "required": ["tenant_id", "action_id"]
            }
        )
    ]


def get_action_management_tools() -> List[Tool]:
    """Get action management tools."""
    return [
        Tool(
            name="mde_get_actions",
            description="Retrieve recent machine actions from the last 60 days. Shows status, type, and details of all actions performed in MDE.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    }
                },
                "required": []
            }
        ),
        Tool(
            name="mde_cancel_actions",
            description="Cancel all pending machine actions in the tenant. This is a safety switch to stop queued actions that haven't started yet.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    }
                },
                "required": []
            }
        ),
        Tool(
            name="mde_get_action_status",
            description="Get the status and details of a specific machine action by its ID.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "action_id": {
                        "type": "string",
                        "description": "Machine action ID to check status for"
                    }
                },
                "required": ["action_id"]
            }
        )
    ]


def get_threat_intelligence_tools() -> List[Tool]:
    """Get threat intelligence tools."""
    return [
        Tool(
            name="mde_add_file_indicators",
            description="Add file hash-based threat indicators to Microsoft Defender for Endpoint. Supports both SHA1 and SHA256 hashes.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "sha1_hashes": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of SHA1 file hashes"
                    },
                    "sha256_hashes": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of SHA256 file hashes"
                    }
                },
                "required": ["tenant_id"],
                "anyOf": [
                    {"required": ["sha1_hashes"]},
                    {"required": ["sha256_hashes"]}
                ]
            }
        ),
        Tool(
            name="mde_add_ip_indicators",
            description="Add IP address-based threat indicators to Microsoft Defender for Endpoint. Supports both IPv4 and IPv6 addresses.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "ip_addresses": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of IP addresses (IPv4 or IPv6)"
                    }
                },
                "required": ["tenant_id", "ip_addresses"]
            }
        ),
        Tool(
            name="mde_add_url_indicators",
            description="Add URL or domain-based threat indicators to Microsoft Defender for Endpoint.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "urls": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of URLs or domain names"
                    }
                },
                "required": ["tenant_id", "urls"]
            }
        ),
        Tool(
            name="mde_add_cert_indicators",
            description="Add certificate thumbprint-based threat indicators to Microsoft Defender for Endpoint. Only SHA1 thumbprints are supported.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "cert_thumbprints": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of SHA1 certificate thumbprints"
                    }
                },
                "required": ["tenant_id", "cert_thumbprints"]
            }
        ),
        Tool(
            name="mde_remove_indicators",
            description="Remove threat indicators from Microsoft Defender for Endpoint by type and values.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "indicator_type": {
                        "type": "string",
                        "enum": ["file", "ip", "url", "cert"],
                        "description": "Type of indicators to remove"
                    },
                    "sha1_hashes": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of SHA1 hashes (for file/cert indicators)"
                    },
                    "sha256_hashes": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of SHA256 hashes (for file indicators)"
                    },
                    "ip_addresses": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of IP addresses (for IP indicators)"
                    },
                    "urls": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of URLs (for URL indicators)"
                    },
                    "cert_thumbprints": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of certificate thumbprints (for cert indicators)"
                    }
                },
                "required": ["tenant_id", "indicator_type"]
            }
        ),
        Tool(
            name="mde_get_indicators",
            description="Retrieve all custom threat indicators from Microsoft Defender for Endpoint including their types, values, and actions.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    }
                },
                "required": []
            }
        )
    ]


def get_hunting_tools() -> List[Tool]:
    """Get hunting tools."""
    return [
        Tool(
            name="mde_run_hunting_query",
            description="Execute KQL (Kusto Query Language) hunting queries against Microsoft Defender for Endpoint advanced hunting tables. Returns raw query results.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "queries": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of KQL queries to execute"
                    }
                },
                "required": ["queries"]
            }
        ),
        Tool(
            name="mde_schedule_hunt",
            description="Schedule a hunting operation to run periodically with specified queries and schedule.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "hunt_name": {
                        "type": "string",
                        "description": "Name for the scheduled hunt"
                    },
                    "query": {
                        "type": "string",
                        "description": "KQL query to execute"
                    },
                    "schedule": {
                        "type": "string",
                        "description": "Schedule expression (e.g., cron format)"
                    }
                },
                "required": ["hunt_name", "query", "schedule"]
            }
        ),
        Tool(
            name="mde_get_hunt_results",
            description="Retrieve results from a specific hunt operation by hunt ID.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "hunt_id": {
                        "type": "string",
                        "description": "Hunt ID to retrieve results for"
                    }
                },
                "required": ["hunt_id"]
            }
        )
    ]


def get_incident_management_tools() -> List[Tool]:
    """Get incident management tools."""
    return [
        Tool(
            name="mde_get_incidents",
            description="Retrieve security incidents from Microsoft Defender XDR. Returns up to 500 recent incidents with filtering for non-informational severity.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    }
                },
                "required": []
            }
        ),
        Tool(
            name="mde_get_incident",
            description="Get detailed information about a specific security incident including all associated alerts and evidence.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "incident_id": {
                        "type": "string",
                        "description": "Incident ID to retrieve details for"
                    }
                },
                "required": ["incident_id"]
            }
        ),
        Tool(
            name="mde_update_incident",
            description="Update incident properties including status, assignment, classification, determination, severity, and custom tags.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "incident_id": {
                        "type": "string",
                        "description": "Incident ID to update"
                    },
                    "status": {
                        "type": "string",
                        "enum": ["active", "resolved", "redirected"],
                        "description": "Incident status"
                    },
                    "assigned_to": {
                        "type": "string",
                        "description": "User to assign the incident to"
                    },
                    "classification": {
                        "type": "string",
                        "enum": ["unknown", "falsePositive", "truePositive", "informationalExpectedActivity"],
                        "description": "Incident classification"
                    },
                    "determination": {
                        "type": "string",
                        "enum": ["unknown", "apt", "malware", "securityPersonnel", "securityTesting", "unwantedSoftware", "other", "multiStagedAttack", "compromisedAccount", "phishing", "maliciousUserActivity", "notMalicious", "notEnoughDataToValidate", "confirmedUserActivity", "lineOfBusinessApplication"],
                        "description": "Incident determination"
                    },
                    "custom_tags": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Custom tags for the incident"
                    },
                    "description": {
                        "type": "string",
                        "description": "Incident description"
                    },
                    "display_name": {
                        "type": "string",
                        "description": "Incident display name"
                    },
                    "severity": {
                        "type": "string",
                        "enum": ["unknown", "informational", "low", "medium", "high"],
                        "description": "Incident severity"
                    },
                    "resolving_comment": {
                        "type": "string",
                        "description": "Comment explaining the resolution"
                    },
                    "summary": {
                        "type": "string",
                        "description": "Incident summary"
                    }
                },
                "required": ["incident_id"]
            }
        ),
        Tool(
            name="mde_add_incident_comment",
            description="Add a comment to a security incident for documentation and collaboration.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "incident_id": {
                        "type": "string",
                        "description": "Incident ID to add comment to"
                    },
                    "comment": {
                        "type": "string",
                        "description": "Comment text to add"
                    }
                },
                "required": ["incident_id", "comment"]
            }
        )
    ]


def get_custom_detection_tools() -> List[Tool]:
    """Get custom detection tools."""
    return [
        Tool(
            name="mde_get_detection_rules",
            description="Retrieve all custom detection rules from Microsoft Defender for Endpoint.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    }
                },
                "required": []
            }
        ),
        Tool(
            name="mde_create_detection_rule",
            description="Create a new custom detection rule in Microsoft Defender for Endpoint using a rule definition.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "rule_definition": {
                        "type": "object",
                        "description": "Custom detection rule definition JSON containing displayName, description, queryText, and other properties"
                    }
                },
                "required": ["rule_definition"]
            }
        ),
        Tool(
            name="mde_update_detection_rule",
            description="Update an existing custom detection rule in Microsoft Defender for Endpoint.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "rule_id": {
                        "type": "string",
                        "description": "ID of the detection rule to update"
                    },
                    "rule_definition": {
                        "type": "object",
                        "description": "Updated rule definition JSON"
                    }
                },
                "required": ["rule_id", "rule_definition"]
            }
        ),
        Tool(
            name="mde_delete_detection_rule",
            description="Delete a custom detection rule from Microsoft Defender for Endpoint.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "rule_id": {
                        "type": "string",
                        "description": "ID of the detection rule to delete"
                    }
                },
                "required": ["rule_id"]
            }
        )
    ]


def get_information_tools() -> List[Tool]:
    """Get information gathering tools."""
    return [
        Tool(
            name="mde_get_file_info",
            description="Get detailed information about files using SHA1 hashes including metadata, related alerts, machines, and statistics.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "sha1_hashes": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of SHA1 hashes to query"
                    }
                },
                "required": ["sha1_hashes"]
            }
        ),
        Tool(
            name="mde_get_ip_info",
            description="Get information about IP addresses including related alerts, statistics, and advanced hunting results.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "ip_addresses": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of IP addresses to query"
                    }
                },
                "required": ["ip_addresses"]
            }
        ),
        Tool(
            name="mde_get_url_info",
            description="Get information about URLs or domains including related alerts, statistics, machines, and advanced hunting results.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "urls": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of URLs or domains to query"
                    }
                },
                "required": ["urls"]
            }
        ),
        Tool(
            name="mde_get_logged_in_users",
            description="Get the list of users currently or recently logged in to specified devices including account names, logon times, and session information.",
            inputSchema={
                "type": "object",
                "properties": {
                    "tenant_id": {
                        "type": "string",
                        "description": "Tenant ID for the operation"
                    },
                    "device_ids": {
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Array of device IDs to query for logged in users"
                    }
                },
                "required": ["device_ids"]
            }
        )
    ]


def get_ai_integration_tools() -> List[Tool]:
    """Get AI integration tools."""
    return [
        Tool(
            name="mde_ai_chat",
            description="Send messages to Azure OpenAI GPT-4 for intelligent analysis and recommendations about Microsoft Defender for Endpoint operations. The AI can provide security insights, suggest actions, and help interpret data. CRITICAL: Set execute_actions=true to enable AI automation that actually executes MDE commands!",
            inputSchema={
                "type": "object",
                "properties": {
                    "message": {
                        "type": "string",
                        "description": "The message or question to send to the AI assistant"
                    },
                    "context": {
                        "type": "string",
                        "description": "Optional context information to help the AI provide better responses"
                    },
                    "system_prompt": {
                        "type": "string",
                        "description": "Optional system prompt to guide the AI's behavior"
                    },
                    "execute_actions": {
                        "type": "boolean",
                        "description": "CRITICAL: Set to true to enable AI automation that actually executes recommended MDE commands. When false, only provides recommendations.",
                        "default": False
                    },
                    "tenant_id": {
                        "type": "string",
                        "description": "Required when execute_actions=true. The Azure tenant ID for MDE operations."
                    },
                    "max_tokens": {
                        "type": "integer",
                        "description": "Maximum number of tokens in the response (default: 3000)",
                        "default": 3000
                    },
                    "temperature": {
                        "type": "number",
                        "description": "Controls randomness in the response (0.0 to 1.0, default: 0.7)",
                        "default": 0.7
                    }
                },
                "required": ["message"]
            }
        )
    ]
