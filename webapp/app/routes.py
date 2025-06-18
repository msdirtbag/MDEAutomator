import os
import json
import base64
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
            # Log detailed error information for debugging
            current_app.logger.error(f"Failed to decode JSON response from {function_name}. Status: {resp.status_code}. Response text (first 1000 chars): {resp.text[:1000]}")
              # Check what type of response we got
            response_preview = resp.text[:200] if resp.text else "Empty response"
            
            if resp.text.strip().startswith('<!DOCTYPE') or resp.text.strip().startswith('<html'):
                current_app.logger.error(f"Azure Function {function_name} returned HTML error page instead of JSON")
                return {'error': 'Azure Function returned HTML error page instead of JSON response.', 'status_code': resp.status_code, 'response_preview': response_preview}
            elif not resp.text.strip():
                current_app.logger.error(f"Azure Function {function_name} returned empty response")
                return {'error': 'Azure Function returned empty response.', 'status_code': resp.status_code}
            else:
                return {'error': 'Invalid JSON response from Azure Function.', 'status_code': resp.status_code, 'response_text': resp.text[:500]}

    except requests.exceptions.ReadTimeout:
        current_app.logger.info(f"Read timeout occurred for {function_name} as expected for long-running task. Assuming task initiated.")
        return {'status': 'initiated', 'message': f'Request for {function_name} sent, Azure Function is processing.'}
    except requests.exceptions.Timeout as e: # Catches ConnectTimeout or other generic Timeouts
        current_app.logger.error(f"Timeout (not ReadTimeout) occurred while calling {function_name} at {log_url}: {e}")
        return {'error': 'Request to Azure Function timed out (e.g., connection timeout).'}
    except requests.exceptions.HTTPError as http_err:
        error_text = http_err.response.text[:500] if http_err.response else 'No response body'
        status_code = http_err.response.status_code if http_err.response else 'Unknown'
        
        if http_err.response:
            current_app.logger.error(f"HTTP error - Response headers: {dict(http_err.response.headers)}")
            current_app.logger.error(f"HTTP error - Response status code: {http_err.response.status_code}")
            current_app.logger.error(f"HTTP error - Response text length: {len(http_err.response.text) if http_err.response.text else 0}")
        
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
        # Flatten first IP address for display        if 'IpAddresses' in flat and isinstance(flat['IpAddresses'], list) and flat['IpAddresses']:
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
        # Build payload for PowerShell backend (fileContent as base64 encoded string, TargetFileName as string)
        azure_function_payload = {
            'Function': specific_action,
            'TenantId': tenant_id,
            'fileContent': base64.b64encode(file_content).decode('utf-8'),  # Convert bytes to base64 string for JSON serialization
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

    # Handle device group targeting for master tenants
    device_group = azure_function_payload.get('DeviceGroup')
    if device_group:
        current_app.logger.info(f"Device group targeting enabled for action '{specific_action}': {device_group}")
        azure_function_payload['DeviceGroup'] = device_group

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
    
    if isinstance(result, dict) and 'error' in result:
        current_app.logger.error(f"Action management failed: {result}")
        return jsonify({'error': result['error'], 'details': result.get('details', '')}), 500
    
    return jsonify({'message': f'{function_name} completed successfully!', 'result': result})

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
                        'IsMasterTenant': True,
                        'Enabled': True,
                        'AddedDate': '2025-01-01T00:00:00.000Z',
                        'AddedBy': 'MockData'
                    },
                    {
                        'TenantId': 'test-tenant-2', 
                        'ClientName': 'Test Client 2',
                        'IsMasterTenant': False,
                        'Enabled': True,
                        'AddedDate': '2025-01-02T00:00:00.000Z',
                        'AddedBy': 'MockData'
                    }
                ],                'Count': 2,
                'Timestamp': '2025-05-31T00:00:00.000Z'
            }
            return jsonify(mock_response)
            
        # Call the MDEAutoDB function to get tenant IDs
        response = call_azure_function('MDEAutoDB', {
            'Function': 'GetTenantIds'
        }, read_timeout=60)  # Increased timeout for tenant operations to handle cold starts
        
        current_app.logger.info(f"Azure Function response: {response}")
          # Handle timeout/initiated status
        if response.get('status') == 'initiated':
            current_app.logger.warning("Azure Function timed out but may still be processing")
            return jsonify({'error': 'Azure Function request timed out. Please try again.'}), 408
        
        if 'error' in response:
            current_app.logger.error(f"Error getting tenants: {response['error']}")
            return jsonify({'error': response['error']}), 500
            
        current_app.logger.info(f"Successfully retrieved {response.get('Count', 0)} tenants")
        
        # Convert MasterTenant field to IsMasterTenant for frontend compatibility
        if 'TenantIds' in response and isinstance(response['TenantIds'], list):
            for tenant in response['TenantIds']:
                if 'MasterTenant' in tenant:
                    tenant['IsMasterTenant'] = tenant.pop('MasterTenant')
        
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
        is_master_tenant = data.get('IsMasterTenant', False)
        
        if not tenant_id:
            return jsonify({'error': 'TenantId is required'}), 400
            
        if not client_name:
            return jsonify({'error': 'ClientName is required'}), 400
            
        current_app.logger.info(f"Saving tenant: {tenant_id} for client: {client_name}, master: {is_master_tenant}")
        
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
                'IsMasterTenant': is_master_tenant,
                'Timestamp': '2025-05-31T00:00:00.000Z'
            }
            return jsonify(mock_response)        # Call the MDEAutoDB function to save tenant ID
        response = call_azure_function('MDEAutoDB', {
            'Function': 'SaveTenantId',
            'TenantId': tenant_id,
            'ClientName': client_name,
            'MasterTenant': 'true' if is_master_tenant else 'false'
        }, read_timeout=60)  # Increased timeout for tenant operations to handle cold starts
        
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
        
        if not func_url_base or not func_key:            # Return mock success response when Azure Function is not available
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
        }, read_timeout=60)  # Increased timeout for tenant operations to handle cold starts
        
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

@main_bp.route('/huntmanager', methods=['GET'])
def huntmanager():
    return render_template(
        'HuntManager.html',
        FUNCURL=current_app.config.get('FUNCURL'),
        FUNCKEY=current_app.config.get('FUNCKEY')
    )

# Incident Management endpoints for IncidentManager

@main_bp.route('/api/incidents', methods=['POST'])
def get_incidents():
    """Get incidents from Microsoft Defender"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Request must be JSON and not empty.'}), 400
        
        tenant_id = data.get('tenantId')
        if not tenant_id:
            return jsonify({'error': 'tenantId is required'}), 400
            
        current_app.logger.info(f"Getting incidents for tenant: {tenant_id}")        # Call Azure Function for getting incidents
        response = call_azure_function('MDEIncidentManager', {
            'TenantId': tenant_id,
            'Function': 'GetIncidents'
        }, read_timeout=60)  # Extended timeout for loading large incident datasets
        
        # Handle errors from new MDEIncidentManager function format
        if 'error' in response:
            current_app.logger.error(f"Error getting incidents: {response['error']}")
            return jsonify({'error': response['error']}), 500
        elif isinstance(response, dict) and response.get('Status') == 'Error':
            error_msg = response.get('Message', 'Unknown error from Azure Function')
            current_app.logger.error(f"Error getting incidents: {error_msg}")
            return jsonify({'error': error_msg}), 500
              # Handle response format from new MDEIncidentManager function
        if isinstance(response, list):
            incidents = response
        elif isinstance(response, dict):
            # New format: {"Status": "Success", "Result": [...]}
            if response.get('Status') == 'Success' and 'Result' in response:
                incidents = response.get('Result', [])
            else:
                # Fallback to old format
                incidents = response.get('incidents', response.get('Incidents', []))
        else:
            current_app.logger.error(f"Unexpected response format: {type(response)}")
            return jsonify({'error': 'Unexpected response format from Azure Function'}), 500
            
        return jsonify({
            'success': True,
            'incidents': incidents
        })
        
    except Exception as e:
        current_app.logger.error(f"Exception in get_incidents: {str(e)}")
        return jsonify({'error': str(e)}), 500

@main_bp.route('/api/incidents/update', methods=['POST'])
def update_incident():
    """Update multiple incidents"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Request must be JSON and not empty.'}), 400
        
        tenant_id = data.get('tenantId')
        incident_ids = data.get('incidentIds')
        
        if not tenant_id:
            return jsonify({'error': 'tenantId is required'}), 400
            
        if not incident_ids or not isinstance(incident_ids, list) or len(incident_ids) == 0:
            return jsonify({'error': 'incidentIds array is required and must not be empty'}), 400
            
        current_app.logger.info(f"Updating {len(incident_ids)} incidents for tenant: {tenant_id}")
        
        # Build update parameters, filtering out null values
        update_params = {
            'TenantId': tenant_id,
            'Function': 'UpdateIncident',
            'IncidentIds': incident_ids
        }
          # Add optional parameters only if they are provided
        if data.get('status'):
            update_params['Status'] = data.get('status')
        if data.get('assignedTo'):
            update_params['AssignedTo'] = data.get('assignedTo')
        if data.get('classification'):
            update_params['Classification'] = data.get('classification')
        if data.get('determination'):
            update_params['Determination'] = data.get('determination')
        if data.get('severity'):
            update_params['Severity'] = data.get('severity')
        if data.get('displayName'):
            update_params['DisplayName'] = data.get('displayName')
        if data.get('description'):
            update_params['Description'] = data.get('description')
          # Call Azure Function for updating incidents
        response = call_azure_function('MDEIncidentManager', update_params)
        
        # Handle errors from new MDEIncidentManager function format
        if 'error' in response:
            current_app.logger.error(f"Error updating incident: {response['error']}")
            return jsonify({'error': response['error']}), 500
        elif isinstance(response, dict) and response.get('Status') == 'Error':
            error_msg = response.get('Message', 'Unknown error from Azure Function')
            current_app.logger.error(f"Error updating incident: {error_msg}")
            return jsonify({'error': error_msg}), 500
            
        return jsonify({
            'success': True,
            'message': f'Successfully updated {len(incident_ids)} incident(s)',
            'result': response
        })
        
    except Exception as e:
        current_app.logger.error(f"Exception in update_incident: {str(e)}")
        return jsonify({'error': str(e)}), 500

@main_bp.route('/api/incidents/comment', methods=['POST'])
def add_incident_comment():
    """Add a comment to multiple incidents"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Request must be JSON and not empty.'}), 400
        
        tenant_id = data.get('tenantId')
        incident_ids = data.get('incidentIds')
        comment = data.get('comment')
        
        if not tenant_id:
            return jsonify({'error': 'tenantId is required'}), 400
            
        if not incident_ids or not isinstance(incident_ids, list) or len(incident_ids) == 0:
            return jsonify({'error': 'incidentIds array is required and must not be empty'}), 400
            
        if not comment:
            return jsonify({'error': 'comment is required'}), 400
            
        current_app.logger.info(f"Adding comment to {len(incident_ids)} incidents for tenant: {tenant_id}")
          # Call Azure Function for adding comment to multiple incidents
        response = call_azure_function('MDEIncidentManager', {
            'TenantId': tenant_id,
            'Function': 'UpdateIncidentComment',
            'IncidentIds': incident_ids,
            'Comment': comment
        })
        
        # Handle errors from new MDEIncidentManager function format
        if 'error' in response:
            current_app.logger.error(f"Error adding comment: {response['error']}")
            return jsonify({'error': response['error']}), 500
        elif isinstance(response, dict) and response.get('Status') == 'Error':
            error_msg = response.get('Message', 'Unknown error from Azure Function')
            current_app.logger.error(f"Error adding comment: {error_msg}")
            return jsonify({'error': error_msg}), 500
            
        return jsonify({
            'success': True,
            'message': f'Comment added to {len(incident_ids)} incident(s) successfully',
            'result': response
        })
        
    except Exception as e:
        current_app.logger.error(f"Exception in add_incident_comment: {str(e)}")
        return jsonify({'error': str(e)}), 500

@main_bp.route('/api/incidents/alerts', methods=['POST'])
def get_incident_alerts():
    """Get alerts for a specific incident"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Request must be JSON and not empty.'}), 400
        
        tenant_id = data.get('tenantId')
        incident_id = data.get('incidentId')
        
        if not tenant_id:
            return jsonify({'error': 'tenantId is required'}), 400
            
        if not incident_id:
            return jsonify({'error': 'incidentId is required'}), 400
        
        current_app.logger.info(f"Getting alerts for incident {incident_id} in tenant: {tenant_id}")
        
        # Call Azure Function for getting incident alerts with extended timeout
        response = call_azure_function('MDEIncidentManager', {
            'TenantId': tenant_id,
            'Function': 'GetIncidentAlerts',
            'IncidentIds': [incident_id]
        }, read_timeout=30)  # Extended timeout for alerts processing
        
        current_app.logger.info(f"Azure Function response: {response}")
        
        # Handle errors from Azure Function
        if 'error' in response:
            current_app.logger.error(f"Error getting incident alerts: {response['error']}")
            return jsonify({'error': response['error']}), 500
        elif isinstance(response, dict) and response.get('Status') == 'Error':
            error_msg = response.get('Message', 'Unknown error from Azure Function')
            current_app.logger.error(f"Error getting incident alerts: {error_msg}")
            return jsonify({'error': error_msg}), 500
              # Handle response format from GetIncidentAlerts function
        alerts = []
        if isinstance(response, list):
            alerts = response
        elif isinstance(response, dict):
            # Handle the specific response format from Azure Function
            if response.get('Status') == 'Success' and 'Result' in response:
                result = response.get('Result', {})
                # Extract alerts from the Result object
                alerts = result.get('Alerts', [])
            else:
                # Fallback to other possible formats
                alerts = response.get('alerts', response.get('Alerts', response.get('value', [])))
        
        current_app.logger.info(f"Extracted alerts count: {len(alerts) if isinstance(alerts, list) else 'Not a list'}")
        current_app.logger.debug(f"Alerts data: {alerts}")
        
        return jsonify({
            'success': True,
            'alerts': alerts,
            'incidentId': incident_id
        })
        
    except Exception as e:
        current_app.logger.error(f"Exception in get_incident_alerts: {str(e)}")
        return jsonify({'error': str(e)}), 500

@main_bp.route('/incidentmanager', methods=['GET'])
def incidentmanager():
    return render_template(
        'IncidentManager.html',
        FUNCURL=current_app.config.get('FUNCURL'),
        FUNCKEY=current_app.config.get('FUNCKEY')
    )

@main_bp.route('/api/device-groups/<tenant_id>')
def fetch_device_groups(tenant_id):
    """Get device groups for a tenant to populate the device group filter dropdown"""
    try:
        current_app.logger.info(f"Getting device groups for tenant: {tenant_id}")
        
        # Validate tenant ID format
        if not tenant_id or not tenant_id.strip():
            current_app.logger.error(f"Invalid tenant ID provided: '{tenant_id}'")
            return jsonify({'error': 'Invalid tenant ID provided'}), 400
        
        # Check if FUNCURL and FUNCKEY are configured
        func_url = current_app.config.get('FUNCURL')
        func_key = current_app.config.get('FUNCKEY')
        
        if not func_url or not func_key:
            current_app.logger.error("FUNCURL or FUNCKEY not configured")
            return jsonify({'error': 'Azure Function configuration missing'}), 500
        
        # Prepare the payload for the Azure Function
        azure_function_payload = {
            'Function': 'GetDeviceGroups',
            'TenantId': tenant_id.strip()
        }
        
        current_app.logger.info(f"Calling MDETIManager function with payload: {azure_function_payload}")
        
        # Call the Azure Function with longer timeout for device group retrieval
        result = call_azure_function('MDETIManager', azure_function_payload, read_timeout=30)
        
        current_app.logger.info(f"Azure Function result type: {type(result)}, content: {result}")
        
        if result is None:
            current_app.logger.error(f"No response from Azure Function for tenant {tenant_id}")
            return jsonify({'error': 'No response from Azure Function'}), 500
        
        # Handle timeout/initiated status
        if result.get('status') == 'initiated':
            current_app.logger.info(f"Azure Function initiated for tenant {tenant_id}")
            return jsonify({'message': 'Request initiated, processing'}), 202
        
        # Handle Azure Function errors
        if 'error' in result:
            error_details = result.get('details', 'No additional details')
            current_app.logger.error(f"Azure Function error for tenant {tenant_id}: {result['error']}, details: {error_details}")
            return jsonify({'error': result['error'], 'details': error_details}), 500
        
        # Handle function execution failures
        if isinstance(result, dict) and result.get('status') == 'failed':
            failure_reason = result.get('reason', 'Unknown reason')
            current_app.logger.error(f"Azure Function execution failed for tenant {tenant_id}: {failure_reason}")
            return jsonify({'error': 'Azure Function execution failed', 'reason': failure_reason}), 500
        
        # Process successful response - handle multiple formats
        try:
            device_groups = []
            
            current_app.logger.debug(f"Processing result for tenant {tenant_id}: {result}")
            
            # Handle different response formats from Azure Function
            if isinstance(result, list):
                # Direct array response (expected format from MDETIManager)
                device_groups = result
                current_app.logger.info(f"Found {len(device_groups)} device groups in direct array response for tenant {tenant_id}")
            elif isinstance(result, dict):
                if result.get('Status') == 'Success':
                    # New format: {"Status": "Success", "DeviceGroups": [...]}
                    device_groups = result.get('DeviceGroups', [])
                    current_app.logger.info(f"Found {len(device_groups)} device groups in Success response for tenant {tenant_id}")
                else:
                    # Legacy format: {"deviceGroups": [...]}
                    device_groups = result.get('deviceGroups', [])
                    current_app.logger.info(f"Found {len(device_groups)} device groups in legacy response for tenant {tenant_id}")
            else:
                current_app.logger.error(f"Unexpected result type for tenant {tenant_id}: {type(result)}")
                return jsonify({'error': f'Unexpected response type: {type(result)}'}), 500
            
            current_app.logger.info(f"Returning {len(device_groups)} device groups for tenant {tenant_id}")
            
            # Return in the format expected by TI Manager
            return jsonify({
                'Status': 'Success',
                'DeviceGroups': device_groups
            })
            
        except Exception as e:
            current_app.logger.error(f"Error processing device groups for tenant {tenant_id}: {e}", exc_info=True)
            return jsonify({'error': 'Failed to process device groups', 'details': str(e)}), 500
    
    except Exception as e:
        current_app.logger.error(f"Unexpected error in fetch_device_groups for tenant {tenant_id}: {e}", exc_info=True)
        return jsonify({'error': 'Internal server error', 'details': str(e)}), 500

# Test route to verify API is working
@main_bp.route('/api/test')
def test_api():
    """Simple test route to verify API is working"""
    return jsonify({'status': 'ok', 'message': 'API is working'})

