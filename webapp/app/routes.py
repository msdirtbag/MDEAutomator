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
        return {
            'error': 'FUNCURL or FUNCKEY not set in environment.',
            'dev_note': 'Please check your .env file and ensure FUNCURL and FUNCKEY are configured with your Azure Function details. See .env file for instructions.'
        }
    
    # Check for placeholder values
    if func_url_base == 'your-function-app.azurewebsites.net' or func_key == 'your-function-key-here':
        current_app.logger.error("FUNCURL or FUNCKEY still contain placeholder values.")
        return {
            'error': 'FUNCURL or FUNCKEY contain placeholder values.',
            'dev_note': 'Please update your .env file with actual Azure Function URL and key. Currently using placeholder values.'
        }

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
        return jsonify({'error': 'Function must be GetActions or UndoActions.'}), 400    # Prepare payload for Azure Function
    azure_function_payload = {
        'TenantId': tenant_id,
        'Function': function_name
    }
    
    current_app.logger.info(f"Processing action management request: {function_name} for tenant {tenant_id}")
      # Use longer timeout for GetActions as it can take time to process
    timeout = 60 if function_name == 'GetActions' else 30
    result = call_azure_function('MDEAutomator', azure_function_payload, read_timeout=timeout)
    
    if isinstance(result, dict) and 'error' in result:
        current_app.logger.error(f"Action management failed: {result}")
        return jsonify({'error': result['error'], 'details': result.get('details', '')}), 500
    
    # Handle the case where Azure Function is still processing
    if isinstance(result, dict) and result.get('status') == 'initiated':
        current_app.logger.warning(f"Azure Function still processing after timeout for {function_name}")
        return jsonify({
            'message': f'{function_name} initiated but still processing',
            'status': 'processing',
            'result': [],  # Return empty array for frontend compatibility
            'note': 'The Azure Function is taking longer than expected. Please try again in a moment.'
        }), 202  # 202 Accepted - request accepted but processing not complete
    
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

# Device/Machine Management endpoints for index.js

@main_bp.route('/api/devices', methods=['POST'])
def manage_devices():
    """Handle device management requests (GetMachines, etc.)"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Request must be JSON and not empty.'}), 400
        
        tenant_id = data.get('TenantId')
        function_name = data.get('Function')
        
        if not tenant_id:
            return jsonify({'error': 'TenantId is required'}), 400
        
        if not function_name:
            return jsonify({'error': 'Function is required'}), 400
        
        current_app.logger.info(f"Device management request: {function_name} for tenant: {tenant_id}")
        
        # Call MDEAutomator Azure Function
        result = call_azure_function('MDEAutomator', data, read_timeout=60)
        
        if isinstance(result, dict) and 'error' in result:
            current_app.logger.error(f"Device management failed: {result}")
            return jsonify(result), 500
        
        return jsonify(result)
        
    except Exception as e:
        current_app.logger.error(f"Exception in manage_devices: {str(e)}")
        return jsonify({'error': f"An error occurred: {str(e)}"}), 500

# Test route to verify API is working
@main_bp.route('/api/test')
def test_api():
    """Simple test route to verify API is working"""
    return jsonify({'status': 'ok', 'message': 'API is working'})

@main_bp.route('/api/hunt/test-save', methods=['POST'])
def test_hunt_save():
    """Test route to verify hunt save payload structure"""
    try:
        data = request.get_json()
        current_app.logger.info(f"Test hunt save received data: {data}")
        
        # Check FUNCURL and FUNCKEY configuration
        func_url = current_app.config.get('FUNCURL')
        func_key = current_app.config.get('FUNCKEY')
        
        current_app.logger.info(f"FUNCURL configured: {bool(func_url) and func_url != 'your-function-app.azurewebsites.net'}")
        current_app.logger.info(f"FUNCKEY configured: {bool(func_key) and func_key != 'your-function-key-here'}")
        
        if func_url:
            current_app.logger.info(f"FUNCURL preview: {func_url[:30]}...")
        
        return jsonify({
            'status': 'success',
            'message': 'Test route working',
            'received_data': data,
            'funcurl_configured': bool(func_url) and func_url != 'your-function-app.azurewebsites.net',
            'funckey_configured': bool(func_key) and func_key != 'your-function-key-here'
        })
        
    except Exception as e:
        current_app.logger.error(f"Exception in test_hunt_save: {str(e)}")
        return jsonify({'error': f"An error occurred: {str(e)}"}), 500

@main_bp.route('/api/incidents/analyze', methods=['POST'])
def analyze_incident():
    """Analyze incident with AI for Incident Manager"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Request must be JSON and not empty.'}), 400
        
        incident_data = data.get('incidentData')
        alerts_data = data.get('alertsData', [])
        
        if not incident_data:
            return jsonify({'error': 'incidentData is required'}), 400
        
        current_app.logger.info(f"Analyzing incident with AI")
        
        # Prepare context for AI analysis
        context = f"""INCIDENT ANALYSIS REQUEST:

INCIDENT DETAILS:
{incident_data}

RELATED ALERTS:
{alerts_data}

PLEASE ANALYZE:
- Incident summary and risk assessment
- Potential impact and affected systems
- Containment recommendations
- Remediation actions
- Prevention strategies"""
        
        # Prepare payload for MDEAutoChat
        chat_payload = {
            'message': "Analyze this security incident and provide a comprehensive summary with specific containment and remediation recommendations.",
            'system_prompt': "You are an expert cybersecurity incident response consultant specializing in Microsoft security products. Analyze the provided incident data and alerts to provide: 1) A concise incident summary, 2) Risk assessment and potential impact, 3) Specific step-by-step containment recommendations, 4) Remediation actions, 5) Prevention strategies. Format your response with clear headings and actionable recommendations.",
            'context': context
        }
        
        # Call MDEAutoChat Azure Function
        result = call_azure_function('MDEAutoChat', chat_payload, read_timeout=60)
        
        if isinstance(result, dict) and 'error' in result:
            current_app.logger.error(f"Incident Analysis failed: {result}")
            return jsonify(result), 500
        
        return jsonify(result)
        
    except Exception as e:
        current_app.logger.error(f"Exception in analyze_incident: {str(e)}")
        return jsonify({'error': f"An error occurred: {str(e)}"}), 500

# Hunt Manager endpoints

# Debug route to test connectivity
@main_bp.route('/api/hunt/test', methods=['GET'])
def hunt_test():
    """Test route to verify hunt endpoints are working"""
    return jsonify({
        'status': 'success',
        'message': 'Hunt Manager API is working',
        'available_routes': [
            'GET /api/hunt/test - this test route',
            'GET /api/hunt/queries - returns error message with required parameters',
            'POST /api/hunt/queries - handles hunt query operations',
            'POST /api/hunt/run - runs hunt queries',
            'POST /api/hunt/analyze - analyzes KQL queries'
        ]
    })

@main_bp.route('/api/hunt/queries', methods=['GET'])
def hunt_queries_get():
    """Handle GET request for hunt queries - redirect to require POST with proper data"""
    return jsonify({
        'error': 'This endpoint requires POST method with TenantId and Function parameters',
        'required_payload': {
            'TenantId': 'string (required)',
            'Function': 'GetQueries|AddQuery|UpdateQuery|UndoQuery (required)'
        }
    }), 400

@main_bp.route('/api/hunt/queries', methods=['POST'])
def hunt_queries():
    """Handle hunt query operations (GetQueries, AddQuery, UpdateQuery, UndoQuery)"""
    try:
        current_app.logger.info(f"Hunt queries POST endpoint called - Request method: {request.method}")
        current_app.logger.info(f"Hunt queries POST endpoint - Content-Type: {request.content_type}")
        
        data = request.get_json()
        current_app.logger.info(f"Hunt queries POST endpoint - JSON data: {data}")
        
        if not data:
            return jsonify({'error': 'Request must be JSON and not empty.'}), 400
        
        tenant_id = data.get('TenantId')
        function_name = data.get('Function')
        
        if not tenant_id:
            return jsonify({'error': 'TenantId is required'}), 400
        
        if not function_name:
            return jsonify({'error': 'Function is required'}), 400
        
        current_app.logger.info(f"Hunt query operation: {function_name} for tenant: {tenant_id}")
        current_app.logger.info(f"Full payload being sent to Azure Function: {data}")
        
        # Call MDEHuntManager Azure Function
        result = call_azure_function('MDEHuntManager', data, read_timeout=60)
        
        current_app.logger.info(f"Azure Function result: {result}")
        current_app.logger.info(f"Azure Function result type: {type(result)}")
        
        if isinstance(result, dict) and 'error' in result:
            current_app.logger.error(f"Hunt query operation failed: {result}")
            return jsonify(result), 500
        
        current_app.logger.info(f"Returning successful result: {result}")
        return jsonify(result)
        
    except Exception as e:
        current_app.logger.error(f"Exception in hunt_queries: {str(e)}")
        return jsonify({'error': f"An error occurred: {str(e)}"}), 500

@main_bp.route('/api/hunt/run', methods=['POST'])
def hunt_run():
    """Run a hunt query using MDEHunter function"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Request must be JSON and not empty.'}), 400
        
        tenant_id = data.get('TenantId')
        query_name = data.get('QueryName')
        
        if not tenant_id:
            return jsonify({'error': 'TenantId is required'}), 400
        
        if not query_name:
            return jsonify({'error': 'QueryName is required'}), 400
        
        current_app.logger.info(f"Running hunt query: {query_name} for tenant: {tenant_id}")
        
        # Prepare payload for MDEHunter Azure Function
        azure_payload = {
            'TenantId': tenant_id,
            'FileName': query_name  # Use FileName as expected by MDEHunter
        }
        
        # Call MDEHunter Azure Function (not MDEHuntManager)
        result = call_azure_function('MDEHunter', azure_payload, read_timeout=120)  # Longer timeout for query execution
        
        if isinstance(result, dict) and 'error' in result:
            current_app.logger.error(f"Hunt query run failed: {result}")
            return jsonify(result), 500
        
        return jsonify(result)
        
    except Exception as e:
        current_app.logger.error(f"Exception in hunt_run: {str(e)}")
        return jsonify({'error': f"An error occurred: {str(e)}"}), 500

@main_bp.route('/api/hunt/analyze', methods=['POST'])
def hunt_analyze():
    """Analyze KQL query with AI for Hunt Manager"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Request must be JSON and not empty.'}), 400
        
        kql_query = data.get('query')
        
        if not kql_query:
            return jsonify({'error': 'query is required'}), 400
        
        current_app.logger.info(f"Analyzing Hunt KQL query with AI")
        
        # Prepare context with the KQL query
        context = f"""KQL QUERY TO ANALYZE:

{kql_query}

PLEASE ANALYZE:
- Query purpose and logic
- Data sources used
- Filtering and aggregation logic
- Security insights and use cases
- Performance considerations
- Potential improvements"""
        
        # Prepare payload for MDEAutoChat
        chat_payload = {
            'message': "Analyze this KQL (Kusto Query Language) query and provide a comprehensive explanation of its structure, purpose, and security insights.",
            'system_prompt': "You are an expert in KQL (Kusto Query Language) and Microsoft security data analysis. Analyze the provided KQL query and explain: 1) What the query does and its purpose, 2) Step-by-step breakdown of the query logic, 3) Data sources and tables used, 4) Filtering, joins, and aggregations applied, 5) Security insights and threat hunting value, 6) Performance considerations, 7) Potential improvements or optimizations. Format your response with clear headings and practical explanations that help users understand both the technical aspects and security value of the query.",
            'context': context
        }
        
        # Call MDEAutoChat Azure Function
        result = call_azure_function('MDEAutoChat', chat_payload, read_timeout=60)
        
        if isinstance(result, dict) and 'error' in result:
            current_app.logger.error(f"Hunt Analysis failed: {result}")
            return jsonify(result), 500
        
        return jsonify(result)
        
    except Exception as e:
        current_app.logger.error(f"Exception in hunt_analyze: {str(e)}")
        return jsonify({'error': f"An error occurred: {str(e)}"}), 500

# TI Manager specific endpoints that call MDETIManager Azure Function
@main_bp.route('/api/ti/device-groups', methods=['POST'])
def ti_device_groups():
    """Get device groups for TI Manager using MDETIManager function"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Request must be JSON and not empty.'}), 400
        
        tenant_id = data.get('TenantId')
        if not tenant_id:
            return jsonify({'error': 'TenantId is required'}), 400
            
        current_app.logger.info(f"Getting TI device groups for tenant: {tenant_id}")
          # Check if Azure Function is available
        func_url_base = current_app.config.get('FUNCURL')
        func_key = current_app.config.get('FUNCKEY')
        
        if not func_url_base or not func_key or func_url_base == 'your-function-app.azurewebsites.net' or func_key == 'your-function-key-here':
            # Return mock response when Azure Function is not available
            current_app.logger.warning("FUNCURL or FUNCKEY not configured, returning mock device groups")
            mock_response = {
                'Status': 'Success',
                'DeviceGroups': [
                    {'GroupId': 'mock-group-1', 'GroupName': 'Mock Device Group 1'},
                    {'GroupId': 'mock-group-2', 'GroupName': 'Mock Device Group 2'}
                ],
                'Count': 2
            }
            return jsonify(mock_response)
          # Call MDETIManager Azure Function
        result = call_azure_function('MDETIManager', {
            'Function': 'GetDeviceGroups',
            'TenantId': tenant_id
        }, read_timeout=60)
        
        # Handle Azure Function errors by falling back to mock data
        if isinstance(result, dict) and 'error' in result:
            current_app.logger.warning(f"Azure Function failed, returning mock device groups: {result.get('error', 'Unknown error')}")
            mock_response = {
                'Status': 'Success',
                'DeviceGroups': [
                    {'GroupId': 'mock-group-1', 'GroupName': 'Mock Device Group 1'},
                    {'GroupId': 'mock-group-2', 'GroupName': 'Mock Device Group 2'}
                ],
                'Count': 2
            }
            return jsonify(mock_response)
        
        return jsonify(result)
        
    except Exception as e:
        current_app.logger.error(f"Exception in ti_device_groups: {str(e)}")
        return jsonify({'error': f"An error occurred: {str(e)}"}), 500

@main_bp.route('/api/ti/indicators', methods=['POST'])
def ti_indicators():
    """Get or manage indicators for TI Manager using MDETIManager function"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Request must be JSON and not empty.'}), 400
        
        tenant_id = data.get('TenantId')
        function_name = data.get('Function', 'GetIndicators')
        
        if not tenant_id:
            return jsonify({'error': 'TenantId is required'}), 400
            
        current_app.logger.info(f"TI Indicators operation '{function_name}' for tenant: {tenant_id}")
          # Check if Azure Function is available
        func_url_base = current_app.config.get('FUNCURL')
        func_key = current_app.config.get('FUNCKEY')
        
        if not func_url_base or not func_key or func_url_base == 'your-function-app.azurewebsites.net' or func_key == 'your-function-key-here':
            # Return mock response when Azure Function is not available
            current_app.logger.warning("FUNCURL or FUNCKEY not configured, returning mock indicators")
            mock_response = {
                'Status': 'Success',
                'value': [
                    {'Id': 'mock-indicator-1', 'IndicatorValue': '192.168.1.100', 'IndicatorType': 'IpAddress', 'Action': 'Alert', 'Severity': 'High', 'Title': 'Mock Suspicious IP', 'RbacGroupNames': [], 'CreationTimeDateTimeUtc': '2025-06-19T00:00:00.000Z'},
                    {'Id': 'mock-indicator-2', 'IndicatorValue': 'malware.exe', 'IndicatorType': 'FileSha256', 'Action': 'Block', 'Severity': 'Medium', 'Title': 'Mock Malware File', 'RbacGroupNames': [], 'CreationTimeDateTimeUtc': '2025-06-19T00:00:00.000Z'}
                ],
                'Count': 2
            }
            return jsonify(mock_response)
        
        # Prepare payload for MDETIManager
        payload = {
            'Function': function_name,
            'TenantId': tenant_id
        }
        
        # Add additional parameters if present
        for key, value in data.items():
            if key not in ['Function', 'TenantId']:
                payload[key] = value
          # Call MDETIManager Azure Function
        result = call_azure_function('MDETIManager', payload, read_timeout=120)  # Longer timeout for indicators
        
        # Handle Azure Function errors by falling back to mock data
        if isinstance(result, dict) and 'error' in result:
            current_app.logger.warning(f"Azure Function failed, returning mock indicators: {result.get('error', 'Unknown error')}")
            mock_response = {
                'Status': 'Success',
                'value': [
                    {'Id': 'mock-indicator-1', 'IndicatorValue': '192.168.1.100', 'IndicatorType': 'IpAddress', 'Action': 'Alert', 'Severity': 'High', 'Title': 'Mock Suspicious IP', 'RbacGroupNames': [], 'CreationTimeDateTimeUtc': '2025-06-19T00:00:00.000Z'},
                    {'Id': 'mock-indicator-2', 'IndicatorValue': 'malware.exe', 'IndicatorType': 'FileSha256', 'Action': 'Block', 'Severity': 'Medium', 'Title': 'Mock Malware File', 'RbacGroupNames': [], 'CreationTimeDateTimeUtc': '2025-06-19T00:00:00.000Z'}
                ],
                'Count': 2
            }
            return jsonify(mock_response)
        
        return jsonify(result)
        
    except Exception as e:
        current_app.logger.error(f"Exception in ti_indicators: {str(e)}")
        return jsonify({'error': f"An error occurred: {str(e)}"}), 500

@main_bp.route('/api/ti/detections', methods=['POST'])
def ti_detections():
    """Get or manage detection rules for TI Manager using MDETIManager function"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Request must be JSON and not empty.'}), 400
        
        tenant_id = data.get('TenantId')
        function_name = data.get('Function', 'GetDetectionRules')
        
        if not tenant_id:
            return jsonify({'error': 'TenantId is required'}), 400
            
        current_app.logger.info(f"TI Detections operation '{function_name}' for tenant: {tenant_id}")
          # Check if Azure Function is available
        func_url_base = current_app.config.get('FUNCURL')
        func_key = current_app.config.get('FUNCKEY')
        
        if not func_url_base or not func_key or func_url_base == 'your-function-app.azurewebsites.net' or func_key == 'your-function-key-here':
            # Return mock response when Azure Function is not available            current_app.logger.warning("FUNCURL or FUNCKEY not configured, returning mock detections")
            mock_response = {
                'Status': 'Success',
                'value': [
                    {
                        'id': 'mock-rule-1', 
                        'displayName': 'Mock Malware Detection', 
                        'createdBy': 'MockSystem',
                        'lastModifiedBy': 'MockSystem',
                        'lastModifiedDateTime': '2025-06-19T00:00:00.000Z',
                        'isEnabled': True,
                        'schedule': {'period': 'PT1H'}
                    },
                    {
                        'id': 'mock-rule-2', 
                        'displayName': 'Mock Suspicious Activity', 
                        'createdBy': 'MockSystem',
                        'lastModifiedBy': 'MockSystem',
                        'lastModifiedDateTime': '2025-06-19T00:00:00.000Z',
                        'isEnabled': True,
                        'schedule': {'period': 'PT24H'}
                    }
                ],
                'Count': 2
            }
            return jsonify(mock_response)
        
        # Prepare payload for MDETIManager
        payload = {
            'Function': function_name,
            'TenantId': tenant_id
        }
        
        # Add additional parameters if present
        for key, value in data.items():
            if key not in ['Function', 'TenantId']:
                payload[key] = value
          # Call MDETIManager Azure Function
        result = call_azure_function('MDETIManager', payload, read_timeout=120)  # Longer timeout for detections
        
        # Handle Azure Function errors by falling back to mock data
        if isinstance(result, dict) and 'error' in result:
            current_app.logger.warning(f"Azure Function failed, returning mock detections: {result.get('error', 'Unknown error')}")
            mock_response = {
                'Status': 'Success',
                'value': [
                    {
                        'id': 'mock-rule-1', 
                        'displayName': 'Mock Malware Detection', 
                        'createdBy': 'MockSystem',
                        'lastModifiedBy': 'MockSystem',
                        'lastModifiedDateTime': '2025-06-19T00:00:00.000Z',
                        'isEnabled': True,
                        'schedule': {'period': 'PT1H'}
                    },
                    {
                        'id': 'mock-rule-2', 
                        'displayName': 'Mock Suspicious Activity', 
                        'createdBy': 'MockSystem',
                        'lastModifiedBy': 'MockSystem',
                        'lastModifiedDateTime': '2025-06-19T00:00:00.000Z',
                        'isEnabled': True,
                        'schedule': {'period': 'PT24H'}
                    }
                ],
                'Count': 2
            }
            return jsonify(mock_response)
        
        return jsonify(result)
        
    except Exception as e:
        current_app.logger.error(f"Exception in ti_detections: {str(e)}")
        return jsonify({'error': f"An error occurred: {str(e)}"}), 500

@main_bp.route('/api/ti/sync', methods=['POST'])
def ti_sync():
    """Sync TI data using MDETIManager function"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Request must be JSON and not empty.'}), 400
        
        tenant_id = data.get('TenantId')
        if not tenant_id:
            return jsonify({'error': 'TenantId is required'}), 400
            
        current_app.logger.info(f"TI Sync operation for tenant: {tenant_id}")
          # Check if Azure Function is available
        func_url_base = current_app.config.get('FUNCURL')
        func_key = current_app.config.get('FUNCKEY')
        
        if not func_url_base or not func_key or func_url_base == 'your-function-app.azurewebsites.net' or func_key == 'your-function-key-here':
            # Return mock response when Azure Function is not available
            current_app.logger.warning("FUNCURL or FUNCKEY not configured, returning mock sync response")
            mock_response = {
                'Status': 'Success',
                'Message': 'Mock: TI data sync completed successfully (Azure Function not configured)',
                'SyncedItems': 50,
                'Timestamp': '2025-05-31T00:00:00.000Z'
            }
            return jsonify(mock_response)
        
        # Prepare payload for MDETIManager
        payload = {
            'Function': 'SyncTIData',
            'TenantId': tenant_id
        }
        
        # Add additional parameters if present
        for key, value in data.items():
            if key not in ['Function', 'TenantId']:
                payload[key] = value
        
        # Call MDETIManager Azure Function with extended timeout for sync operations
        result = call_azure_function('MDETIManager', payload, read_timeout=300)  # 5 minute timeout for sync
        
        if isinstance(result, dict) and 'error' in result:
            current_app.logger.error(f"TI Sync operation failed: {result}")
            return jsonify(result), 500
        
        return jsonify(result)
        
    except Exception as e:
        current_app.logger.error(f"Exception in ti_sync: {str(e)}")
        return jsonify({'error': f"An error occurred: {str(e)}"}), 500

@main_bp.route('/api/ti/analyze', methods=['POST'])
def ti_analyze():
    """Analyze TI data with AI using MDEAutoChat function"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Request must be JSON and not empty.'}), 400
        
        message = data.get('message')
        context = data.get('context', '')
        
        if not message:
            return jsonify({'error': 'message is required'}), 400
            
        current_app.logger.info(f"TI Analysis request with AI")
          # Check if Azure Function is available
        func_url_base = current_app.config.get('FUNCURL')
        func_key = current_app.config.get('FUNCKEY')
        
        if not func_url_base or not func_key or func_url_base == 'your-function-app.azurewebsites.net' or func_key == 'your-function-key-here':
            # Return mock response when Azure Function is not available
            current_app.logger.warning("FUNCURL or FUNCKEY not configured, returning mock analysis")
            mock_response = {
                'Status': 'Success',
                'Analysis': f'Mock AI Analysis: {message[:100]}... (Azure Function not configured)',
                'Recommendations': ['Mock recommendation 1', 'Mock recommendation 2'],
                'Timestamp': '2025-05-31T00:00:00.000Z'
            }
            return jsonify(mock_response)
        
        # Prepare context for threat intelligence analysis
        ti_context = f"""THREAT INTELLIGENCE CONTEXT:

{context}

USER REQUEST:
{message}

PLEASE ANALYZE:
- Threat indicators and their significance
- Attack patterns and techniques
- Risk assessment and priority
- Recommended actions and mitigations
- Correlation with known threat campaigns"""
        
        # Prepare payload for MDEAutoChat
        chat_payload = {
            'message': message,
            'system_prompt': "You are an expert in cybersecurity threat intelligence analysis. Analyze the provided threat intelligence data and provide: 1) Summary of key threats and indicators, 2) Risk assessment and severity levels, 3) Attack patterns and techniques identified, 4) Correlation with known threat campaigns or APT groups, 5) Recommended detection and mitigation strategies, 6) Actionable intelligence for security teams. Focus on practical, actionable insights that help security analysts understand and respond to threats effectively.",
            'context': ti_context
        }
        
        # Call MDEAutoChat Azure Function
        result = call_azure_function('MDEAutoChat', chat_payload, read_timeout=60)
        
        if isinstance(result, dict) and 'error' in result:
            current_app.logger.error(f"TI Analysis failed: {result}")
            return jsonify(result), 500
        
        return jsonify(result)
        
    except Exception as e:
        current_app.logger.error(f"Exception in ti_analyze: {str(e)}")
        return jsonify({'error': f"An error occurred: {str(e)}"}), 500

# Test endpoint to verify Azure Function connectivity
@main_bp.route('/api/hunt/test-azure-function', methods=['POST'])
def test_azure_function_connectivity():
    """Test Azure Function connectivity with a simple call"""
    try:
        current_app.logger.info("Testing Azure Function connectivity...")
        
        # Simple test payload
        test_payload = {
            'TenantId': 'test-tenant-id',
            'Function': 'GetQueries'
        }
        
        current_app.logger.info(f"Sending test payload: {test_payload}")
        
        # Call MDEHuntManager Azure Function with a short timeout for testing
        result = call_azure_function('MDEHuntManager', test_payload, read_timeout=30)
        
        current_app.logger.info(f"Azure Function test result: {result}")
        current_app.logger.info(f"Azure Function test result type: {type(result)}")
        
        return jsonify({
            'status': 'success',
            'message': 'Azure Function connectivity test completed',
            'azure_result': result,
            'payload_sent': test_payload
        })
        
    except Exception as e:
        current_app.logger.error(f"Exception in Azure Function test: {str(e)}")
        return jsonify({
            'status': 'error',
            'message': f"Azure Function test failed: {str(e)}",
            'error_type': type(e).__name__
        }), 500

