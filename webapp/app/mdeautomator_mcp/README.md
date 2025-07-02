# Python MCP Server for MDEAutomator

## Overview

This directory contains a Python-based Model Context Protocol (MCP) server that provides AI assistants with secure access to Microsoft Defender for Endpoint operations through your MDEAutomator Azure Function Apps.

## Features

### 🔐 Security-First Design
- **Azure Managed Identity Authentication**: Passwordless authentication using Azure workload identity
- **Function Key Authentication**: Fallback authentication method with secure key management
- **Request Validation**: Comprehensive input validation and sanitization
- **Rate Limiting**: Configurable rate limiting to prevent abuse
- **Audit Logging**: Complete audit trail of all operations

### 🛡️ Microsoft Defender for Endpoint Operations
- **Device Management**: Isolate, contain, restrict, and offboard devices
- **Live Response**: Execute scripts, upload/download files, remote investigation
- **Threat Intelligence**: Manage IOCs for files, IPs, URLs, and certificates
- **Advanced Hunting**: Execute KQL queries and scheduled hunts
- **Incident Management**: Manage XDR incidents with full CRUD operations
- **Custom Detections**: Create, update, and manage custom detection rules
- **Action Management**: Monitor and control all security actions

### 🚀 Production-Ready
- **Container-First**: Optimized Docker containers for Azure Container Instance
- **Health Checks**: Built-in health monitoring and diagnostics
- **Error Handling**: Comprehensive error handling with retry logic
- **Performance**: Async operations with connection pooling and throttling
- **Monitoring**: Structured logging with Azure Application Insights integration

## Quick Start

### 1. Prerequisites
- Python 3.11+
- Docker (for containerization)
- Azure CLI (for deployment)
- Access to MDEAutomator Function Apps

### 2. Configuration
```bash
# Copy the environment template
cp .env.template .env

# Edit .env with your configuration
vim .env
```

Key configuration values:
- `FUNCTION_APP_BASE_URL`: Your MDEAutomator Function App URL
- `AZURE_CLIENT_ID`: Managed Identity Client ID
- `FUNCTION_KEY`: Function App authentication key (if not using Key Vault)
- `KEY_VAULT_URL`: Azure Key Vault URL for secrets

### 3. Development Setup
```bash
# Install dependencies
pip install -r requirements.txt

# Run the server
python -m mcp.server
```

### 4. Docker Development
```bash
# Build and run development container
docker-compose --profile dev up --build

# Run tests
docker-compose exec mcp-server-dev pytest

# View logs
docker-compose logs -f mcp-server-dev
```

### 5. Production Deployment
```bash
# Build production container
docker-compose build mcp-server

# Run production container
docker-compose up -d mcp-server

# Check health
docker-compose exec mcp-server python -c "import asyncio; from mcp.function_client import FunctionAppClient; from mcp.config import MCPConfig; asyncio.run(FunctionAppClient(MCPConfig.from_environment()).health_check())"
```

## Configuration Reference

### Environment Variables

| Variable | Description | Default | Required |
|----------|-------------|---------|----------|
| `FUNCTION_APP_BASE_URL` | Base URL for Function Apps | - | Yes |
| `AZURE_CLIENT_ID` | Managed Identity Client ID | - | Optional |
| `FUNCTION_KEY` | Function authentication key | - | Optional |
| `KEY_VAULT_URL` | Key Vault URL for secrets | - | Optional |
| `REQUEST_TIMEOUT` | HTTP timeout in seconds | 300 | No |
| `MAX_RETRIES` | Maximum retry attempts | 3 | No |
| `LOG_LEVEL` | Logging level | INFO | No |
| `ENABLE_AUDIT_LOGGING` | Enable audit logs | true | No |

### Authentication Methods

1. **Azure Managed Identity** (Recommended for production)
   - Set `AZURE_CLIENT_ID` to your User Managed Identity Client ID
   - Ensure the identity has appropriate Function App permissions

2. **Function Key**
   - Set `FUNCTION_KEY` directly or store in Key Vault
   - Use `KEY_VAULT_URL` for secure key retrieval

## Available MCP Tools

### Device Management
- `mde_get_machines` - List and filter devices
- `mde_isolate_device` - Isolate devices from network
- `mde_unisolate_device` - Remove device isolation
- `mde_contain_device` - Contain unmanaged devices
- `mde_restrict_app_execution` - Restrict app execution
- `mde_collect_investigation_package` - Collect forensic packages
- `mde_run_antivirus_scan` - Run antivirus scans
- `mde_stop_and_quarantine_file` - Stop and quarantine files
- `mde_offboard_device` - Offboard devices

### Live Response
- `mde_run_live_response_script` - Execute PowerShell scripts
- `mde_upload_to_library` - Upload files to library
- `mde_put_file` - Push files to devices
- `mde_get_file` - Retrieve files from devices

### Threat Intelligence
- `mde_add_file_indicators` - Add file hash IOCs
- `mde_add_ip_indicators` - Add IP address IOCs
- `mde_add_url_indicators` - Add URL/domain IOCs
- `mde_add_cert_indicators` - Add certificate IOCs
- `mde_remove_indicators` - Remove threat indicators
- `mde_get_indicators` - List all indicators

### Advanced Hunting
- `mde_run_hunting_query` - Execute KQL queries
- `mde_schedule_hunt` - Schedule hunting operations
- `mde_get_hunt_results` - Retrieve hunt results

### Incident Management
- `mde_get_incidents` - List security incidents
- `mde_get_incident` - Get incident details
- `mde_update_incident` - Update incident properties
- `mde_add_incident_comment` - Add incident comments

### Custom Detections
- `mde_get_detection_rules` - List detection rules
- `mde_create_detection_rule` - Create detection rules
- `mde_update_detection_rule` - Update detection rules
- `mde_delete_detection_rule` - Delete detection rules

## Security Considerations

### Container Security
- Runs as non-root user (uid/gid 1000)
- Read-only filesystem with minimal writable tmpfs
- No new privileges and dropped capabilities
- Minimal attack surface with distroless-style image

### Network Security
- No inbound ports exposed by default
- Outbound connections only to Azure services
- Support for private networking via VNets

### Data Protection
- No persistent storage of sensitive data
- Secrets managed via Azure Key Vault
- Comprehensive audit logging
- Request/response validation

## Troubleshooting

### Common Issues

1. **Authentication Failures**
   ```bash
   # Check Managed Identity configuration
   curl -H "Metadata: true" "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&client_id=$AZURE_CLIENT_ID&resource=https://management.azure.com/"
   ```

2. **Function App Connectivity**
   ```bash
   # Test Function App accessibility
   curl -H "x-functions-key: $FUNCTION_KEY" "$FUNCTION_APP_BASE_URL/api/MDEAutomator" -d '{"TenantId":"","Function":"GetTenantIds"}'
   ```

3. **Container Issues**
   ```bash
   # Check container logs
   docker-compose logs mcp-server
   
   # Exec into container for debugging
   docker-compose exec mcp-server /bin/bash
   ```

### Monitoring

- **Health Checks**: Built-in health endpoints for container orchestration
- **Structured Logging**: JSON-formatted logs for Azure Log Analytics
- **Metrics**: Performance metrics via Application Insights
- **Tracing**: Distributed tracing for request correlation

## Development

### Project Structure
```
mcp/
├── __init__.py              # Package initialization
├── server.py                # Main MCP server implementation
├── config.py                # Configuration management
├── function_client.py       # Azure Function Apps HTTP client
├── models.py                # Pydantic data models
├── tools.py                 # MCP tool definitions
├── Dockerfile              # Production container
├── Dockerfile.dev          # Development container
├── docker-compose.yml      # Container orchestration
├── requirements.txt        # Python dependencies
└── .env.template           # Configuration template
```

### Adding New Tools

1. **Define the tool** in `tools.py`:
   ```python
   Tool(
       name="mde_new_operation",
       description="Description of the new operation",
       inputSchema={...}
   )
   ```

2. **Add handler** in `server.py`:
   ```python
   async def _handle_new_operation(self, arguments: Dict[str, Any]) -> Dict[str, Any]:
       payload = {...}
       return await self.function_client.call_function("FunctionName", payload)
   ```

3. **Route the tool** in `_route_tool_call()`:
   ```python
   elif tool_name.startswith("mde_new_operation"):
       return await self._handle_new_operation(arguments)
   ```

### Testing

```bash
# Run unit tests
pytest tests/

# Run with coverage
pytest --cov=mcp tests/

# Run integration tests
pytest tests/integration/
```

## Deployment to Azure Container Instance

The MCP server is designed for deployment to Azure Container Instance (ACI) with the following benefits:

- **Serverless**: Pay-per-second billing with automatic scaling
- **Managed**: No infrastructure management required
- **Secure**: Private networking and Azure AD integration
- **Monitored**: Built-in Azure monitoring and logging

See the `infra/` directory for Bicep templates to deploy the complete infrastructure including:
- Azure Container Instance
- User Managed Identity
- Key Vault for secrets
- Virtual Network for private networking
- Log Analytics workspace
- Application Insights for monitoring

## Support

For issues and questions:
1. Check the troubleshooting section above
2. Review container logs: `docker-compose logs mcp-server`
3. Validate configuration: Environment variables and Function App connectivity
4. Open an issue in the main MDEAutomator repository

## License

This project is licensed under the same terms as the main MDEAutomator project.
