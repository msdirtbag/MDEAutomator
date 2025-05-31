import os
import requests
from flask import Blueprint, render_template, request, current_app, flash, redirect, url_for, jsonify, render_template_string

main_bp = Blueprint('main', __name__)

# Utility to call Azure Function

def call_azure_function(function_name, payload, read_timeout=3):
    func_url_base = current_app.config.get('FUNCURL') # Expects format like "myfunctionapp.azurewebsites.net"
    func_key = current_app.config.get('FUNCKEY')

    if not func_url_base or not func_key:
        current_app.logger.error("FUNCURL or FUNCKEY not configured in environment.")
        return {'error': 'FUNCURL or FUNCKEY not set in environment.'}

    url = f"https://{func_url_base}/api/{function_name}?code={func_key}"
    log_url = url.split('?code=')[0] + '?code=REDACTED_KEY'
    current_app.logger.info(f"Calling Azure Function at URL: {log_url}")
    current_app.logger.debug(f"Payload for {function_name}: {payload}")

    connect_timeout = 10  # seconds to establish connection
    # Use custom read_timeout (default 3 seconds for long-running tasks, higher for quick operations)

    try:
        resp = requests.post(url, json=payload, timeout=(connect_timeout, read_timeout)) 
        resp.raise_for_status()
        
        try:
            response_json = resp.json()
            current_app.logger.debug(f"Response from {function_name} (status {resp.status_code}): {response_json}")
            return response_json
        except requests.exceptions.JSONDecodeError:
            current_app.logger.error(f"Failed to decode JSON response from {function_name}. Status: {resp.status_code}. Response text (first 500 chars): {resp.text[:500]}")
            return {'error': 'Invalid JSON response from Azure Function.', 'status_code': resp.status_code, 'response_text': resp.text}

    except requests.exceptions.ReadTimeout:
        current_app.logger.info(f"Read timeout occurred for {function_name} as expected for long-running task. Assuming task initiated.")
        return {'status': 'initiated', 'message': f'Request for {function_name} sent, Azure Function is processing.'}
    except requests.exceptions.Timeout as e: # Catches ConnectTimeout or other generic Timeouts
        current_app.logger.error(f"Timeout (not ReadTimeout) occurred while calling {function_name} at {log_url}: {e}")
        return {'error': 'Request to Azure Function timed out (e.g., connection timeout).'}
    except requests.exceptions.HTTPError as http_err:
        error_text = http_err.response.text[:500] if http_err.response else 'No response body'
        status_code = http_err.response.status_code if http_err.response else 'Unknown'
        current_app.logger.error(f"HTTP error occurred while calling {function_name}: {http_err}. Status: {status_code}. Response: {error_text}")
        return {'error': f"HTTP error: {status_code}", 'details': error_text}
    except requests.exceptions.RequestException as req_err: 
        current_app.logger.error(f"Request exception occurred while calling {function_name}: {req_err}")
        return {'error': f"Request failed: {str(req_err)}"}
    except Exception as e: 
        current_app.logger.error(f"An unexpected error occurred in call_azure_function for {function_name}: {e}", exc_info=True)
        return {'error': f"An unexpected error occurred: {str(e)}"}

@main_bp.route('/', methods=['GET', 'POST'])
def index():
    result = None
    if request.method == 'POST':
        # Example: Call Core function with user input
        core_input = request.form.get('core_input')
        payload = {'input': core_input}
        result = call_azure_function('MDEAutomatorapp-Core', payload)
    return render_template(
        'index.html',
        result=result,
        FUNCURL=current_app.config.get('FUNCURL'),
        FUNCKEY=current_app.config.get('FUNCKEY')
    )

@main_bp.route('/api/get_machines')
def get_machines():
    # For demo: load sample data from file instead of Azure Function
    import json
    with open('untitled:Untitled-1', 'r', encoding='utf-8') as f:
        machines = json.load(f)
    if not machines:
        return jsonify({'columns': [], 'machines': []})
    # Use the keys of the first machine as columns, but flatten nested fields for table display
    def flatten_machine(machine):
        flat = machine.copy()
        # Flatten VmMetadata
        if 'VmMetadata' in flat and isinstance(flat['VmMetadata'], dict):
            for k, v in flat['VmMetadata'].items():
                flat[f'VmMetadata.{k}'] = v
            del flat['VmMetadata']
        # Flatten first IP address for display
        if 'IpAddresses' in flat and isinstance(flat['IpAddresses'], list) and flat['IpAddresses']:
            for k, v in flat['IpAddresses'][0].items():
                flat[f'IpAddresses.0.{k}'] = v
            del flat['IpAddresses']
        return flat
    flat_machines = [flatten_machine(m) for m in machines]
    # Ensure MachineTags is the 6th column
    columns = list(flat_machines[0].keys())
    if 'MachineTags' in columns:
        columns.insert(5, columns.pop(columns.index('MachineTags')))
    data = [[m.get(col, '') for col in columns] for m in flat_machines]
    return jsonify({'columns': columns, 'machines': data})

@main_bp.route('/api/send_command', methods=['POST'])
def send_command():
    # Special handling for InvokeUploadLR (file upload)
    if request.content_type and request.content_type.startswith('multipart/form-data'):
        # Only for file upload
        function_name_for_url = request.form.get('function_name')
        specific_action = request.form.get('Function') or request.form.get('command')
        tenant_id = request.form.get('TenantId')
        file = request.files.get('file')
        target_filename = request.form.get('TargetFileName') or (file.filename if file else None)
        if not function_name_for_url or not specific_action or not tenant_id or not file or not target_filename:
            return jsonify({'error': 'Missing required fields for file upload.'}), 400
        file_content = file.read()  # bytes
        # Build payload for PowerShell backend (fileContent as bytes, TargetFileName as string)
        azure_function_payload = {
            'Function': specific_action,
            'TenantId': tenant_id,
            'fileContent': list(file_content),  # Convert bytes to list of ints for JSON serialization
            'TargetFileName': target_filename
        }
        result = call_azure_function(function_name_for_url, azure_function_payload)
        if result is None:
            return jsonify({'message': 'Error calling Azure Function: Configuration error or no response received.'}), 500
        if result.get('status') == 'initiated':
            return jsonify({'message': f"Command '{specific_action}' sent.{result.get('message', '')}"}), 202
        if 'error' in result:
            az_func_error = result.get('details', result['error'])
            return jsonify({'message': f"Error from Azure Function: {az_func_error}"}), result.get('status_code', 500)
        if isinstance(result, dict) and result.get('status') == 'failed':
            failure_reason = result.get('reason', 'Unknown reason from function execution')
            return jsonify({'message': f"Command execution reported as failed: {failure_reason}", 'result': result}), 400
        return jsonify({'message': 'File uploaded successfully!', 'result': result})
    # Handle JSON payload
    data = request.get_json()
    if not data:
        current_app.logger.error("Received empty or non-JSON payload in /api/send_command")
        return jsonify({'error': 'Request must be JSON and not empty.'}), 400

    current_app.logger.debug(f"Received data in /api/send_command: {data}")

    function_name_for_url = data.get('function_name')
    if not function_name_for_url:
        current_app.logger.error("Missing 'function_name' in request to /api/send_command")
        return jsonify({'error': "Missing 'function_name' in request."}), 400

    specific_action = data.get('command')
    if not specific_action:
        specific_action = data.get('Function')
    
    if not specific_action:
        current_app.logger.error("Missing 'command' or 'Function' in request to /api/send_command to specify the action.")
        return jsonify({'error': "Missing 'command' or 'Function' in request to specify the action."}), 400

    azure_function_payload = data.copy()

    if 'function_name' in azure_function_payload:
        del azure_function_payload['function_name']
    
    if 'command' in azure_function_payload:
        del azure_function_payload['command'] 
    
    azure_function_payload['Function'] = specific_action

    # Validate TenantId for all actions
    tenant_id_from_payload = azure_function_payload.get('TenantId')
    if not tenant_id_from_payload: # Checks for None or empty string
        current_app.logger.error(f"Missing or empty 'TenantId' for action '{specific_action}'. Payload: {azure_function_payload}")
        return jsonify({'error': f"TenantId is required and cannot be empty for action: {specific_action}."}), 400

    # DeviceIds validation (exempt when allDevices=true or for specific actions)
    device_ids = azure_function_payload.get('DeviceIds')
    all_devices = azure_function_payload.get('allDevices', False)
    
    # Only validate DeviceIds if allDevices is false
    if not all_devices:
        if not device_ids or not isinstance(device_ids, list) or len(device_ids) == 0:
            # Allow requests for specific exempted actions that don't need DeviceIds
            if specific_action not in ["InvokeUploadLR"]:
                current_app.logger.error(f"Missing or invalid 'DeviceIds' for action '{specific_action}'. Payload: {azure_function_payload}")
                return jsonify({'error': 'DeviceIds are required and must be a non-empty list for this action.'}), 400
    else:
        current_app.logger.info(f"Proceeding with 'allDevices=true' for action '{specific_action}' - DeviceIds validation bypassed.")
    
    current_app.logger.info(f"Calling Azure Function '{function_name_for_url}' with action '{specific_action}'.")
    current_app.logger.debug(f"Payload for Azure Function '{function_name_for_url}': {azure_function_payload}")
    result = call_azure_function(function_name_for_url, azure_function_payload)
    
    if result is None: 
        current_app.logger.error(f"call_azure_function returned None for '{function_name_for_url}', action '{specific_action}'.")
        return jsonify({'message': "Error calling Azure Function: Configuration error or no response received."}), 500

    if result.get('status') == 'initiated':
        current_app.logger.info(f"Azure Function '{function_name_for_url}' (action '{specific_action}') initiated. Client informed.")
        # Return 202 Accepted
        return jsonify({'message': f"Command '{specific_action}' sent. {result.get('message', '')}"}), 202

    if 'error' in result:
        az_func_error = result.get('details', result['error']) 
        current_app.logger.error(f"Azure Function '{function_name_for_url}' (action '{specific_action}') returned an error: {az_func_error}. Original client payload: {data}, Sent Azure Function payload: {azure_function_payload}")
        return jsonify({'message': f"Error from Azure Function: {az_func_error}"}), result.get('status_code', 500)
    
    if isinstance(result, dict) and result.get('status') == 'failed':
        failure_reason = result.get('reason', 'Unknown reason from function execution')
        current_app.logger.warning(f"Azure Function '{function_name_for_url}' (action '{specific_action}') reported command failure: {failure_reason}. Full result: {result}")
        return jsonify({'message': f"Command execution reported as failed: {failure_reason}", 'result': result}), 400 

    current_app.logger.info(f"Command '{specific_action}' for Azure Function '{function_name_for_url}' processed. Result: {result}")
    return jsonify({'message': 'Command sent successfully!', 'result': result})

@main_bp.route('/timanager', methods=['GET'])
def timanager():
    return render_template(
        'TIManager.html',
        FUNCURL=current_app.config.get('FUNCURL'),
        FUNCKEY=current_app.config.get('FUNCKEY')
    )

@main_bp.route('/actionmanager', methods=['GET'])
def actionmanager():
    return render_template(
        'ActionManager.html',
        FUNCURL=current_app.config.get('FUNCURL'),
        FUNCKEY=current_app.config.get('FUNCKEY')
    )



@main_bp.route('/actionmanager-test')
def actionmanager_test():
    """Test version of ActionManager using mock data"""
    return render_template('ActionManagerTest.html', 
                         FUNCURL=current_app.config.get('FUNCURL'), 
                         FUNCKEY=current_app.config.get('FUNCKEY'))

@main_bp.route('/api/actions', methods=['POST'])
def manage_actions():
    """Handle action management requests (GetActions, UndoActions)"""
    data = request.get_json()
    if not data:
        current_app.logger.error("Received empty or non-JSON payload in /api/actions")
        return jsonify({'error': 'Request must be JSON and not empty.'}), 400

    tenant_id = data.get('TenantId')
    function_name = data.get('Function')
    
    if not tenant_id:
        return jsonify({'error': 'TenantId is required.'}), 400
    
    if not function_name:
        return jsonify({'error': 'Function is required.'}), 400
    
    if function_name not in ['GetActions', 'UndoActions']:
        return jsonify({'error': 'Function must be GetActions or UndoActions.'}), 400

    # Prepare payload for Azure Function
    azure_function_payload = {
        'TenantId': tenant_id,
        'Function': function_name
    }
    
    current_app.logger.info(f"Processing action management request: {function_name} for tenant {tenant_id}")
    
    result = call_azure_function('MDEAutomator', azure_function_payload)
    
    # Debug: Log the result structure
    current_app.logger.info(f"Azure Function result type: {type(result)}")
    current_app.logger.info(f"Azure Function result content: {result}")
    
    if isinstance(result, dict) and 'error' in result:
        current_app.logger.error(f"Action management failed: {result}")
        return jsonify({'error': result['error'], 'details': result.get('details', '')}), 500
    
    return jsonify({'message': f'{function_name} completed successfully!', 'result': result})

@main_bp.route('/api/actions-mock', methods=['POST'])
def manage_actions_mock():
    """Mock endpoint for testing ActionManager functionality"""
    data = request.get_json()
    if not data:
        return jsonify({'error': 'Request must be JSON and not empty.'}), 400

    function_name = data.get('Function')
    
    if function_name == 'GetActions':
        # Mock response simulating Azure Function GetActions response
        mock_actions = [
            {
                "Id": "12345678-1234-1234-1234-123456789012",
                "Type": "Isolate",
                "Title": "Isolate machine for investigation",
                "Status": "Pending",
                "ComputerDnsName": "WORKSTATION-01.contoso.com",
                "Requestor": "admin@contoso.com",
                "RequestorComment": "Suspicious activity detected",
                "CreationDateTimeUtc": "2024-01-15T14:30:00Z",
                "LastUpdateDateTimeUtc": "2024-01-15T14:35:00Z",
                "RequestSource": "API"
            },
            {
                "Id": "87654321-4321-4321-4321-210987654321",
                "Type": "RunAntivirusScan",
                "Title": "Run full antivirus scan",
                "Status": "Succeeded",
                "ComputerDnsName": "SERVER-02.contoso.com",
                "Requestor": "security@contoso.com",
                "RequestorComment": "Scheduled security scan",
                "CreationDateTimeUtc": "2024-01-15T10:00:00Z",
                "LastUpdateDateTimeUtc": "2024-01-15T12:45:00Z",
                "RequestSource": "Portal"
            },
            {
                "Id": "11111111-2222-3333-4444-555555555555",
                "Type": "CollectInvestigationPackage",
                "Title": "Collect investigation package",
                "Status": "Failed",
                "ComputerDnsName": "LAPTOP-03.contoso.com",
                "Requestor": "analyst@contoso.com",
                "RequestorComment": "Investigation required",
                "CreationDateTimeUtc": "2024-01-15T08:15:00Z",
                "LastUpdateDateTimeUtc": "2024-01-15T08:20:00Z",
                "RequestSource": "API"
            }
        ]
        
        return jsonify({
            'message': 'GetActions completed successfully!',
            'result': mock_actions
        })
    
    elif function_name == 'UndoActions':
        return jsonify({
            'message': 'UndoActions completed successfully!',
            'result': {'message': 'All pending actions have been cancelled', 'count': 1}
        })
    
    return jsonify({'error': 'Function must be GetActions or UndoActions.'}), 400

# Tenant Management API Endpoints

@main_bp.route('/api/tenants', methods=['GET'])
def get_tenants():
    """Get all saved tenant IDs from Azure storage table"""
    try:
        current_app.logger.info("Getting tenant IDs from storage table")
        
        # Check if Azure Function is available
        func_url_base = current_app.config.get('FUNCURL')
        func_key = current_app.config.get('FUNCKEY')
        
        if not func_url_base or not func_key:
            # Return mock data for testing when Azure Function is not available
            current_app.logger.warning("FUNCURL or FUNCKEY not configured, returning mock data")
            mock_response = {
                'Status': 'Success',
                'Message': 'Retrieved mock tenant data (Azure Function not configured)',
                'TenantIds': [
                    {
                        'TenantId': 'test-tenant-1',
                        'ClientName': 'Test Client 1',
                        'Enabled': True,
                        'AddedDate': '2025-01-01T00:00:00.000Z',
                        'AddedBy': 'MockData'
                    },
                    {
                        'TenantId': 'test-tenant-2', 
                        'ClientName': 'Test Client 2',
                        'Enabled': True,
                        'AddedDate': '2025-01-02T00:00:00.000Z',
                        'AddedBy': 'MockData'
                    }
                ],
                'Count': 2,
                'Timestamp': '2025-05-31T00:00:00.000Z'
            }
            return jsonify(mock_response)
        
        # Call the MDEAutoDB function to get tenant IDs
        response = call_azure_function('MDEAutoDB', {
            'Function': 'GetTenantIds'
        }, read_timeout=30)  # Use longer timeout for tenant operations
        
        current_app.logger.info(f"Azure Function response: {response}")
        
        # Handle timeout/initiated status
        if response.get('status') == 'initiated':
            current_app.logger.warning("Azure Function timed out but may still be processing")
            return jsonify({'error': 'Azure Function request timed out. Please try again.'}), 408
        
        if 'error' in response:
            current_app.logger.error(f"Error getting tenants: {response['error']}")
            return jsonify({'error': response['error']}), 500
            
        current_app.logger.info(f"Successfully retrieved {response.get('Count', 0)} tenants")
        return jsonify(response)
        
    except Exception as e:
        current_app.logger.error(f"Exception in get_tenants: {str(e)}")
        return jsonify({'error': str(e)}), 500

@main_bp.route('/api/tenants', methods=['POST'])
def save_tenant():
    """Save a new tenant ID to Azure storage table"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'No JSON data provided'}), 400
            
        tenant_id = data.get('TenantId', '').strip()
        client_name = data.get('ClientName', '').strip()
        
        if not tenant_id:
            return jsonify({'error': 'TenantId is required'}), 400
            
        if not client_name:
            return jsonify({'error': 'ClientName is required'}), 400
            
        current_app.logger.info(f"Saving tenant: {tenant_id} for client: {client_name}")
        
        # Check if Azure Function is available
        func_url_base = current_app.config.get('FUNCURL')
        func_key = current_app.config.get('FUNCKEY')
        
        if not func_url_base or not func_key:
            # Return mock success response when Azure Function is not available
            current_app.logger.warning("FUNCURL or FUNCKEY not configured, returning mock success")
            mock_response = {
                'Status': 'Success',
                'Message': f"Mock: Tenant ID '{tenant_id}' saved to storage table (Azure Function not configured)",
                'TenantId': tenant_id,
                'Timestamp': '2025-05-31T00:00:00.000Z'
            }
            return jsonify(mock_response)
        
        # Call the MDEAutoDB function to save tenant ID
        response = call_azure_function('MDEAutoDB', {
            'Function': 'SaveTenantId',
            'TenantId': tenant_id,
            'ClientName': client_name
        }, read_timeout=30)  # Use longer timeout for tenant operations
        
        if 'error' in response:
            current_app.logger.error(f"Error saving tenant: {response['error']}")
            return jsonify({'error': response['error']}), 500
            
        current_app.logger.info(f"Successfully saved tenant: {tenant_id}")
        return jsonify(response)
        
    except Exception as e:
        current_app.logger.error(f"Exception in save_tenant: {str(e)}")
        return jsonify({'error': str(e)}), 500

@main_bp.route('/api/tenants/<tenant_id>', methods=['DELETE'])
def delete_tenant(tenant_id):
    """Delete a tenant ID from Azure storage table"""
    try:
        if not tenant_id or not tenant_id.strip():
            return jsonify({'error': 'TenantId is required'}), 400
            
        current_app.logger.info(f"Deleting tenant: {tenant_id}")
        
        # Check if Azure Function is available
        func_url_base = current_app.config.get('FUNCURL')
        func_key = current_app.config.get('FUNCKEY')
        
        if not func_url_base or not func_key:
            # Return mock success response when Azure Function is not available
            current_app.logger.warning("FUNCURL or FUNCKEY not configured, returning mock success")
            mock_response = {
                'Status': 'Success',
                'Message': f"Mock: Tenant ID '{tenant_id}' removed from storage table (Azure Function not configured)",
                'TenantId': tenant_id,
                'Timestamp': '2025-05-31T00:00:00.000Z'
            }
            return jsonify(mock_response)
        
        # Call the MDEAutoDB function to remove tenant ID
        response = call_azure_function('MDEAutoDB', {
            'Function': 'RemoveTenantId',
            'TenantId': tenant_id.strip()
        }, read_timeout=30)  # Use longer timeout for tenant operations
        
        if 'error' in response:
            current_app.logger.error(f"Error deleting tenant: {response['error']}")
            return jsonify({'error': response['error']}), 500
            
        current_app.logger.info(f"Successfully deleted tenant: {tenant_id}")
        return jsonify(response)
        
    except Exception as e:
        current_app.logger.error(f"Exception in delete_tenant: {str(e)}")
        return jsonify({'error': str(e)}), 500

# Threat Intelligence endpoints for TIManager

@main_bp.route('/api/threat-intelligence', methods=['POST'])
def submit_threat_intelligence():
    """Submit a threat intelligence entry"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Request must be JSON and not empty.'}), 400
        
        tenant_id = data.get('TenantId')
        if not tenant_id:
            return jsonify({'error': 'TenantId is required'}), 400
            
        current_app.logger.info(f"Submitting threat intelligence for tenant: {tenant_id}")
        
        # Call Azure Function for threat intelligence submission
        # Using MDEAutomator function with ThreatIntelligence function type
        response = call_azure_function('MDEAutomator', {
            'TenantId': tenant_id,
            'Function': 'SubmitThreatIntelligence',
            'Type': data.get('Type'),
            'Value': data.get('Value'),
            'Description': data.get('Description'),
            'Action': data.get('Action'),
            'Severity': data.get('Severity')
        })
        
        if 'error' in response:
            current_app.logger.error(f"Error submitting threat intelligence: {response['error']}")
            return jsonify({'error': response['error']}), 500
            
        return jsonify(response)
        
    except Exception as e:
        current_app.logger.error(f"Exception in submit_threat_intelligence: {str(e)}")
        return jsonify({'error': str(e)}), 500

@main_bp.route('/api/threat-intelligence/upload', methods=['POST'])
def upload_threat_intelligence():
    """Upload threat intelligence file"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Request must be JSON and not empty.'}), 400
        
        tenant_id = data.get('TenantId')
        if not tenant_id:
            return jsonify({'error': 'TenantId is required'}), 400
            
        current_app.logger.info(f"Uploading threat intelligence file for tenant: {tenant_id}")
        
        # Call Azure Function for file upload
        response = call_azure_function('MDEAutomator', {
            'TenantId': tenant_id,
            'Function': 'UploadThreatIntelligence',
            'FileContent': data.get('FileContent'),
            'FileName': data.get('FileName'),
            'Action': data.get('Action'),
            'Severity': data.get('Severity')
        })
        
        if 'error' in response:
            current_app.logger.error(f"Error uploading threat intelligence: {response['error']}")
            return jsonify({'error': response['error']}), 500
            
        return jsonify(response)
        
    except Exception as e:
        current_app.logger.error(f"Exception in upload_threat_intelligence: {str(e)}")
        return jsonify({'error': str(e)}), 500

@main_bp.route('/api/threat-intelligence/iocs', methods=['POST'])
def get_threat_intelligence_iocs():
    """Get threat intelligence IOCs for a tenant"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Request must be JSON and not empty.'}), 400
        
        tenant_id = data.get('TenantId')
        if not tenant_id:
            return jsonify({'error': 'TenantId is required'}), 400
            
        current_app.logger.info(f"Getting threat intelligence IOCs for tenant: {tenant_id}")
        
        # Call Azure Function to get IOCs
        response = call_azure_function('MDEAutomator', {
            'TenantId': tenant_id,
            'Function': 'GetThreatIntelligenceIOCs'
        })
        
        if 'error' in response:
            current_app.logger.error(f"Error getting IOCs: {response['error']}")
            return jsonify({'error': response['error']}), 500
            
        return jsonify(response)
        
    except Exception as e:
        current_app.logger.error(f"Exception in get_threat_intelligence_iocs: {str(e)}")
        return jsonify({'error': str(e)}), 500

@main_bp.route('/api/threat-intelligence/detections', methods=['POST'])
def get_threat_intelligence_detections():
    """Get threat intelligence detections for a tenant"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Request must be JSON and not empty.'}), 400
        
        tenant_id = data.get('TenantId')
        if not tenant_id:
            return jsonify({'error': 'TenantId is required'}), 400
            
        current_app.logger.info(f"Getting threat intelligence detections for tenant: {tenant_id}")
        
        # Call Azure Function to get detections
        response = call_azure_function('MDEAutomator', {
            'TenantId': tenant_id,
            'Function': 'GetThreatIntelligenceDetections'
        })
        
        if 'error' in response:
            current_app.logger.error(f"Error getting detections: {response['error']}")
            return jsonify({'error': response['error']}), 500
            
        return jsonify(response)
        
    except Exception as e:
        current_app.logger.error(f"Exception in get_threat_intelligence_detections: {str(e)}")
        return jsonify({'error': str(e)}), 500

@main_bp.route('/api/threat-intelligence/clear', methods=['POST'])
def clear_threat_intelligence():
    """Clear all threat intelligence IOCs for a tenant"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Request must be JSON and not empty.'}), 400
        
        tenant_id = data.get('TenantId')
        if not tenant_id:
            return jsonify({'error': 'TenantId is required'}), 400
            
        current_app.logger.info(f"Clearing threat intelligence IOCs for tenant: {tenant_id}")
        
        # Call Azure Function to clear IOCs
        response = call_azure_function('MDEAutomator', {
            'TenantId': tenant_id,
            'Function': 'ClearThreatIntelligenceIOCs'
        })
        
        if 'error' in response:
            current_app.logger.error(f"Error clearing IOCs: {response['error']}")
            return jsonify({'error': response['error']}), 500
            
        return jsonify(response)
        
    except Exception as e:
        current_app.logger.error(f"Exception in clear_threat_intelligence: {str(e)}")
        return jsonify({'error': str(e)}), 500

@main_bp.route('/test-actions')
def test_actions():
    """Test endpoint to debug the actions API response"""
    return render_template_string('''
<!DOCTYPE html>
<html>
<head>
    <title>Test Actions API</title>
</head>
<body>
    <h1>Test Actions API</h1>
    <input type="text" id="tenantId" placeholder="Tenant ID" style="width: 300px;">
    <button onclick="testAPI()">Test API</button>
    <div id="output" style="margin-top: 20px; padding: 20px; background: #f0f0f0; white-space: pre-wrap; font-family: monospace;"></div>
    
    <script>
    async function testAPI() {
        const tenantId = document.getElementById('tenantId').value.trim();
        const output = document.getElementById('output');
        
        if (!tenantId) {
            output.textContent = 'Please enter a tenant ID';
            return;
        }
        
        output.textContent = 'Testing...';
        
        try {
            const res = await fetch('/api/actions', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    TenantId: tenantId,
                    Function: 'GetActions'
                })
            });
            
            const responseText = await res.text();
            
            output.textContent = `Status: ${res.status}\\n\\nRaw Response:\\n${responseText}\\n\\n`;
            
            try {
                const parsed = JSON.parse(responseText);
                output.textContent += `Parsed JSON:\\n${JSON.stringify(parsed, null, 2)}\\n\\n`;
                output.textContent += `Type of result: ${typeof parsed.result}\\n`;
                output.textContent += `Is result array: ${Array.isArray(parsed.result)}\\n`;
                
                if (parsed.result && typeof parsed.result === 'string') {
                    try {
                        const nestedParsed = JSON.parse(parsed.result);
                        output.textContent += `\\nNested Parsed:\\n${JSON.stringify(nestedParsed, null, 2)}`;
                    } catch (e) {
                        output.textContent += `\\nFailed to parse result as JSON: ${e.message}`;
                    }
                }
            } catch (e) {
                output.textContent += `Failed to parse as JSON: ${e.message}`;
            }
            
        } catch (error) {
            output.textContent = `Error: ${error.message}`;
        }
    }
    </script>
</body>
</html>
    ''')

@main_bp.route('/test-modal')
def test_modal():
    """Test page for modal functionality"""
    return render_template_string('''
<!DOCTYPE html>
<html>
<head>
    <title>Test Modal</title>
    <style>
        body { font-family: Arial, sans-serif; padding: 20px; background: #1a1a1a; color: #00ff41; }
        button { padding: 10px 20px; margin: 10px; background: #00ff41; color: #000; border: none; cursor: pointer; }
        .modal { display: none; position: fixed; z-index: 1000; left: 0; top: 0; width: 100%; height: 100%; background-color: rgba(0,0,0,0.8); }
        .modal-content { background-color: #1a1a1a; border: 2px solid #00ff41; margin: 5% auto; padding: 20px; width: 60%; max-width: 600px; border-radius: 8px; }
        .close { color: #00ff41; font-size: 28px; font-weight: bold; cursor: pointer; float: right; }
        #output { background: #0a1a0a; border: 1px solid #00ff41; padding: 15px; margin: 10px 0; border-radius: 5px; }
    </style>
</head>
<body>
    <h1>Modal Test</h1>
    
    <button id="openModalBtn">Open Modal</button>
    <button onclick="testTenantAPI()">Test Tenant API</button>
    <button onclick="window.location.href='/'">Back to Main App</button>
    
    <div id="output"></div>

    <!-- Modal -->
    <div id="testModal" class="modal">
        <div class="modal-content">
            <span class="close">&times;</span>
            <h2>Test Modal</h2>
            <p>This is a test modal.</p>
            <button id="closeModalBtn">Close</button>
        </div>
    </div>

    <script>
        function log(message) {
            const output = document.getElementById('output');
            output.innerHTML += '<div>' + new Date().toLocaleTimeString() + ': ' + message + '</div>';
        }

        // Test modal functionality
        const modal = document.getElementById('testModal');
        const openBtn = document.getElementById('openModalBtn');
        const closeBtn = document.getElementById('closeModalBtn');
        const closeSpan = document.querySelector('.close');

        openBtn.addEventListener('click', function() {
            log('Open button clicked');
            modal.style.display = 'block';
            log('Modal displayed');
        });

        closeBtn.addEventListener('click', function() {
            log('Close button clicked');
            modal.style.display = 'none';
            log('Modal hidden');
        });

        closeSpan.addEventListener('click', function() {
            log('Close X clicked');
            modal.style.display = 'none';
            log('Modal hidden');
        });

        // Test tenant API
        async function testTenantAPI() {
            try {
                log('Testing tenant API...');
                const response = await fetch('/api/tenants');
                log('Response status: ' + response.status);
                const data = await response.json();
                log('Response data: ' + JSON.stringify(data, null, 2));
                
                if (data.Status === 'Success' && data.TenantIds) {
                    log('Found ' + data.TenantIds.length + ' tenants');
                    data.TenantIds.forEach((tenant, index) => {
                        log('Tenant ' + (index + 1) + ': ' + tenant.TenantId + ' - ' + tenant.ClientName);
                    });
                }
            } catch (error) {
                log('ERROR: ' + error.message);
            }
        }

        log('Page loaded, event listeners added');
    </script>
</body>
</html>
    ''')

@main_bp.route('/test-tenant-api')
def test_tenant_api():
    """Test page for tenant API"""
    return render_template_string('''
<!DOCTYPE html>
<html>
<head>
    <title>Test Tenant API</title>
    <style>
        body { font-family: Arial, sans-serif; padding: 20px; background: #1a1a1a; color: #00ff41; }
        button { padding: 10px 20px; margin: 10px; background: #00ff41; color: #000; border: none; cursor: pointer; }
        .response { background: #0a1a0a; border: 1px solid #00ff41; padding: 15px; margin: 10px 0; border-radius: 5px; }
        pre { white-space: pre-wrap; word-wrap: break-word; }
    </style>
</head>
<body>
    <h1>Tenant API Test</h1>
    
    <div>
        <button onclick="testGetTenants()">Test GET /api/tenants</button>
        <button onclick="testAddTenant()">Test POST /api/tenants</button>
        <button onclick="testDeleteTenant()">Test DELETE /api/tenants/test-tenant-1</button>
        <button onclick="window.location.href='/'">Back to Main App</button>
    </div>
    
    <div id="results"></div>

    <script>
        async function testGetTenants() {
            try {
                const response = await fetch('/api/tenants');
                const data = await response.json();
                showResult('GET /api/tenants', response.status, data);
            } catch (error) {
                showResult('GET /api/tenants', 'ERROR', error.message);
            }
        }

        async function testAddTenant() {
            try {
                const payload = {
                    TenantId: 'test-tenant-new',
                    ClientName: 'New Test Client'
                };
                const response = await fetch('/api/tenants', {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(payload)
                });
                const data = await response.json();
                showResult('POST /api/tenants', response.status, data);
            } catch (error) {
                showResult('POST /api/tenants', 'ERROR', error.message);
            }
        }

        async function testDeleteTenant() {
            try {
                const response = await fetch('/api/tenants/test-tenant-1', {
                    method: 'DELETE'
                });
                const data = await response.json();
                showResult('DELETE /api/tenants/test-tenant-1', response.status, data);
            } catch (error) {
                showResult('DELETE /api/tenants/test-tenant-1', 'ERROR', error.message);
            }
        }

        function showResult(endpoint, status, data) {
            const resultsDiv = document.getElementById('results');
            const resultDiv = document.createElement('div');
            resultDiv.className = 'response';
            resultDiv.innerHTML = `
                <h3>${endpoint}</h3>
                <p><strong>Status:</strong> ${status}</p>
                <pre>${JSON.stringify(data, null, 2)}</pre>
            `;
            resultsDiv.appendChild(resultDiv);
        }
    </script>
</body>
</html>
    ''')

@main_bp.route('/debug-actions')
def debug_actions():
    """Debug page to manually test the ActionManager functionality"""
    return render_template_string('''
<!DOCTYPE html>
<html>
<head>
    <title>Debug ActionManager</title>
    <style>
        body { font-family: monospace; margin: 20px; background: #001100; color: #00ff41; }
        button { background: #004400; color: #00ff41; border: 1px solid #00ff41; padding: 10px; margin: 5px; cursor: pointer; }
        button:hover { background: #006600; }
        .output { background: #000; border: 1px solid #00ff41; padding: 10px; margin: 10px 0; white-space: pre-wrap; max-height: 400px; overflow-y: auto; }
        .error { color: #ff4444; }
        .success { color: #44ff44; }
    </style>
</head>
<body>
    <h1>ActionManager Debug Console</h1>
    
    <button onclick="testMockAPI()">Test Mock API</button>
    <button onclick="testUndoAPI()">Test Undo API</button>
    <button onclick="clearOutput()">Clear Output</button>
    
    <div id="output" class="output">Debug output will appear here...</div>
    
    <script>
    function log(message, type = 'info') {
        const output = document.getElementById('output');
        const timestamp = new Date().toLocaleTimeString();
        const className = type === 'error' ? 'error' : (type === 'success' ? 'success' : '');
        output.innerHTML += `<div class="${className}">[${timestamp}] ${message}</div>`;
        output.scrollTop = output.scrollHeight;
    }
    
    function clearOutput() {
        document.getElementById('output').innerHTML = '';
    }
    
    async function testMockAPI() {
        log('Testing mock GetActions API...');
        
        try {
            const response = await fetch('/api/actions-mock', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    TenantId: 'test-tenant',
                    Function: 'GetActions'
                })
            });
            
            log(`Response status: ${response.status}`);
            
            const data = await response.json();
            log(`Response data: ${JSON.stringify(data, null, 2)}`, 'success');
            
            if (data.result && Array.isArray(data.result)) {
                log(`Found ${data.result.length} actions in response`, 'success');
                data.result.forEach((action, index) => {
                    log(`Action ${index + 1}: ${action.Type} - ${action.Status} - ${action.ComputerDnsName}`);
                });
            }
            
        } catch (error) {
            log(`Error: ${error.message}`, 'error');
        }
    }
    
    async function testUndoAPI() {
        log('Testing mock UndoActions API...');
        
        try {
            const response = await fetch('/api/actions-mock', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({
                    TenantId: 'test-tenant',
                    Function: 'UndoActions'
                })
            });
            
            log(`Response status: ${response.status}`);
            
            const data = await response.json();
            log(`Response data: ${JSON.stringify(data, null, 2)}`, 'success');
            
        } catch (error) {
            log(`Error: ${error.message}`, 'error');
        }
    }
    
    // Auto-run initial test
    window.addEventListener('DOMContentLoaded', () => {
        log('Debug page loaded, ready for testing...');
    });
    </script>
</body>
</html>
    ''')