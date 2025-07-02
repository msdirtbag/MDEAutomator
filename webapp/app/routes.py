import os
import sys
import json
import base64
import time
import requests
import asyncio
import concurrent.futures
import threading
from flask import Blueprint, render_template, request, current_app, flash, redirect, url_for, jsonify, render_template_string
from .mcp_client import get_mcp_client

main_bp = Blueprint('main', __name__)

# Utility to call Azure Function

def call_azure_function(function_name, payload, read_timeout=3):
    func_url_base = current_app.config.get('FUNCTION_APP_BASE_URL')
    func_key = current_app.config.get('FUNCTION_KEY')

    if not func_url_base or not func_key:
        current_app.logger.error("FUNCTION_APP_BASE_URL or FUNCTION_KEY not configured in environment.")
        return {
            'error': 'FUNCTION_APP_BASE_URL or FUNCTION_KEY not set in environment.',
            'dev_note': 'Please check your .env file and ensure FUNCTION_APP_BASE_URL and FUNCTION_KEY are configured with your Azure Function details. FUNCTION_APP_BASE_URL must be the full URL (e.g., https://yourapp.azurewebsites.net).'
        }
    
    # Check for placeholder values
    if func_url_base == 'your-function-app.azurewebsites.net' or func_key == 'your-function-key-here':
        current_app.logger.error("FUNCTION_APP_BASE_URL or FUNCTION_KEY still contain placeholder values.")
        return {
            'error': 'FUNCTION_APP_BASE_URL or FUNCTION_KEY contain placeholder values.',
            'dev_note': 'Please update your .env file with actual Azure Function URL and key. FUNCTION_APP_BASE_URL must be the full URL (e.g., https://yourapp.azurewebsites.net).'
        }

    # Validate URL format - must be a full URL with protocol
    if not func_url_base.startswith('https://') and not func_url_base.startswith('http://'):
        current_app.logger.error(f"FUNCTION_APP_BASE_URL must include protocol (https://). Got: {func_url_base}")
        return {
            'error': 'FUNCTION_APP_BASE_URL must include protocol (https://).',
            'dev_note': f'Please update FUNCTION_APP_BASE_URL to include https:// protocol. Current value: {func_url_base}'
        }
    
    # Use the URL as-is (remove trailing slash if present)
    base_url = func_url_base.rstrip('/')
    url = f"{base_url}/api/{function_name}?code={func_key}"
    log_url = url.split('?code=')[0] + '?code=REDACTED_KEY'
    current_app.logger.info(f"Calling Azure Function at URL: {log_url}")
    current_app.logger.debug(f"Payload for {function_name}: {payload}")

    connect_timeout = 10  # seconds to establish connection
    # Use custom read_timeout (default 3 seconds for long-running tasks, higher for quick operations)

    try:
        resp = requests.post(url, json=payload, timeout=(connect_timeout, read_timeout))
        resp.raise_for_status()
          # Handle 204 No Content responses as success
        if resp.status_code == 204:
            current_app.logger.info(f"Azure Function {function_name} returned 204 No Content - operation successful")
            return {
                'status': 'success',
                'message': f'{function_name} operation completed successfully',
                'status_code': 204
            }
        
        # Handle 200 OK with empty content as success (common for write operations)
        if resp.status_code == 200 and not resp.text.strip():
            current_app.logger.info(f"Azure Function {function_name} returned 200 OK with empty content - operation successful")
            return {
                'status': 'success',
                'message': f'{function_name} operation completed successfully',
                'status_code': 200
            }
        
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
        FUNCTION_APP_BASE_URL=current_app.config.get('FUNCTION_APP_BASE_URL'),
        FUNCTION_KEY=current_app.config.get('FUNCTION_KEY')
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
        FUNCTION_APP_BASE_URL=current_app.config.get('FUNCTION_APP_BASE_URL'),
        FUNCTION_KEY=current_app.config.get('FUNCTION_KEY')
    )

@main_bp.route('/actionmanager', methods=['GET'])
def actionmanager():
    return render_template(
        'ActionManager.html',
        FUNCTION_APP_BASE_URL=current_app.config.get('FUNCTION_APP_BASE_URL'),
        FUNCTION_KEY=current_app.config.get('FUNCTION_KEY')
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
        current_app.logger.info("Starting get_tenants() function")
        
        # Check if Azure Function is available
        func_url_base = current_app.config.get('FUNCTION_APP_BASE_URL')
        func_key = current_app.config.get('FUNCTION_KEY')
        
        current_app.logger.info(f"Function config - Base URL: {func_url_base}, Key configured: {bool(func_key)}")
        
        if not func_url_base or not func_key:
            current_app.logger.error("FUNCTION_APP_BASE_URL or FUNCTION_KEY not configured")
            return jsonify({
                'error': 'Azure Function configuration missing.',
                'details': 'FUNCTION_APP_BASE_URL or FUNCTION_KEY not set in environment.',
                'suggestions': [
                    'Check your .env file',
                    'Ensure FUNCTION_APP_BASE_URL and FUNCTION_KEY are configured',
                    'FUNCTION_APP_BASE_URL must be the full URL (e.g., https://yourapp.azurewebsites.net)'
                ]
            }), 500
            
        # Call the MDEAutoDB function to get tenant IDs
        current_app.logger.info("About to call Azure Function MDEAutoDB")
        response = call_azure_function('MDEAutoDB', {
            'Function': 'GetTenantIds'
        }, read_timeout=60)  # Increased timeout for tenant operations to handle cold starts
        
        current_app.logger.info(f"Azure Function response type: {type(response)}")
        current_app.logger.info(f"Azure Function response: {response}")
          # Handle timeout/initiated status
        if response.get('status') == 'initiated':
            current_app.logger.warning("Azure Function timed out but may still be processing")
            return jsonify({'error': 'Azure Function request timed out. Please try again.'}), 408
        
        if 'error' in response:
            current_app.logger.error(f"Error getting tenants: {response['error']}")
            
            # Provide specific error messages for common issues
            error_msg = response['error']
            if 'HTTP error: 403' in error_msg or 'HTTP error: Unknown' in error_msg:
                return jsonify({
                    'error': 'Azure Function access denied. This could be due to IP restrictions, incorrect function key, or the function app being stopped.',
                    'details': error_msg,
                    'suggestions': [
                        'Check if the Azure Function App is running',
                        'Verify the FUNCTION_KEY is correct',
                        'Check if there are IP restrictions on the Function App',
                        'Ensure the FUNCTION_APP_BASE_URL is correct'
                    ]
                }), 503
            elif 'timeout' in error_msg.lower():
                return jsonify({
                    'error': 'Azure Function request timed out.',
                    'details': error_msg,
                    'suggestions': ['Try again in a few moments', 'Check if the Azure Function App is experiencing issues']
                }), 408
            else:
                return jsonify({'error': error_msg}), 500
        
        # Check if Azure Function returned Status: Error (e.g., table doesn't exist)
        if isinstance(response, dict) and response.get('Status') == 'Error':
            error_msg = response.get('Message', 'Unknown error from Azure Function')
            current_app.logger.warning(f"Azure Function returned Status: Error - {error_msg}")
            
            # Check if it's a "table not found" error
            if 'table specified does not exist' in error_msg.lower() or 'tablenotfound' in error_msg.lower():
                current_app.logger.info("Storage table doesn't exist yet - returning empty tenant list")
                # Return an empty tenant list as this is expected for new deployments
                return jsonify({
                    'Status': 'Success',
                    'Message': 'No tenants found (storage table not yet created)',
                    'TenantIds': [],
                    'Count': 0,
                    'Timestamp': response.get('Timestamp', '')
                })
            else:
                # Other types of errors should be returned as errors
                return jsonify({'error': error_msg}), 500
            
        current_app.logger.info(f"Successfully retrieved {response.get('Count', 0)} tenants")
        
        # Convert MasterTenant field to IsMasterTenant for frontend compatibility
        if 'TenantIds' in response and isinstance(response['TenantIds'], list):
            for tenant in response['TenantIds']:
                if 'MasterTenant' in tenant:
                    tenant['IsMasterTenant'] = tenant.pop('MasterTenant')
        
        return jsonify(response)
        
    except Exception as e:
        current_app.logger.error(f"Exception in get_tenants: {str(e)}", exc_info=True)
        # Return a more detailed error response for debugging
        return jsonify({
            'error': f"Internal server error: {str(e)}",
            'error_type': type(e).__name__,
            'function': 'get_tenants'
        }), 500

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
        func_url_base = current_app.config.get('FUNCTION_APP_BASE_URL')
        func_key = current_app.config.get('FUNCTION_KEY')
        
        if not func_url_base or not func_key:
            current_app.logger.error("FUNCTION_APP_BASE_URL or FUNCTION_KEY not configured")
            return jsonify({
                'error': 'Azure Function configuration missing.',
                'details': 'FUNCTION_APP_BASE_URL or FUNCTION_KEY not set in environment.',
                'suggestions': [
                    'Check your .env file',
                    'Ensure FUNCTION_APP_BASE_URL and FUNCTION_KEY are configured',
                    'FUNCTION_APP_BASE_URL must be the full URL (e.g., https://yourapp.azurewebsites.net)'
                ]
            }), 500        # Call the MDEAutoDB function to save tenant ID
        response = call_azure_function('MDEAutoDB', {
            'Function': 'SaveTenantId',
            'TenantId': tenant_id,
            'ClientName': client_name,
            'MasterTenant': 'true' if is_master_tenant else 'false'
        }, read_timeout=60)  # Increased timeout for tenant operations to handle cold starts
        
        if 'error' in response:
            current_app.logger.error(f"Error saving tenant: {response['error']}")
            return jsonify({'error': response['error']}), 500
        
        # Handle Azure Function returning "Status": "Error" (e.g., table not found)
        if isinstance(response, dict) and response.get('Status') == 'Error':
            current_app.logger.warning(f"Azure Function returned error status for save tenant: {response}")
            
            # Check if it's a "table not found" error which is expected initially
            error_msg = response.get('Result', '').lower()
            if 'table' in error_msg and ('not found' in error_msg or 'does not exist' in error_msg):
                # This is expected when the table doesn't exist yet
                # In a production environment, you might want to trigger table creation here
                return jsonify({
                    'error': 'Storage table not initialized',
                    'message': 'The tenant storage table does not exist yet. Please contact your administrator to initialize the storage.',
                    'canRetry': True
                }), 400
            else:
                # Other types of errors
                return jsonify({
                    'error': 'Failed to save tenant',
                    'message': response.get('Result', 'Unknown error occurred'),
                    'canRetry': True
                }), 400
            
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
        func_url_base = current_app.config.get('FUNCTION_APP_BASE_URL')
        func_key = current_app.config.get('FUNCTION_KEY')
        
        if not func_url_base or not func_key:
            current_app.logger.error("FUNCTION_APP_BASE_URL or FUNCTION_KEY not configured")
            return jsonify({
                'error': 'Azure Function configuration missing.',
                'details': 'FUNCTION_APP_BASE_URL or FUNCTION_KEY not set in environment.',
                'suggestions': [
                    'Check your .env file',
                    'Ensure FUNCTION_APP_BASE_URL and FUNCTION_KEY are configured',
                    'FUNCTION_APP_BASE_URL must be the full URL (e.g., https://yourapp.azurewebsites.net)'
                ]
            }), 500
            
        # Call the MDEAutoDB function to remove tenant ID
        response = call_azure_function('MDEAutoDB', {
            'Function': 'RemoveTenantId',
            'TenantId': tenant_id.strip()
        }, read_timeout=60)  # Increased timeout for tenant operations to handle cold starts
        
        if 'error' in response:
            current_app.logger.error(f"Error deleting tenant: {response['error']}")
            return jsonify({'error': response['error']}), 500
        
        # Handle Azure Function returning "Status": "Error" (e.g., table not found)
        if isinstance(response, dict) and response.get('Status') == 'Error':
            current_app.logger.warning(f"Azure Function returned error status for delete tenant: {response}")
            
            # Check if it's a "table not found" error
            error_msg = response.get('Result', '').lower()
            if 'table' in error_msg and ('not found' in error_msg or 'does not exist' in error_msg):
                # Table doesn't exist, so tenant is already "deleted" in a sense
                return jsonify({
                    'message': 'Tenant removed (storage table not found)',
                    'success': True
                }), 200
            else:
                # Other types of errors
                return jsonify({
                    'error': 'Failed to delete tenant',
                    'message': response.get('Result', 'Unknown error occurred'),
                    'canRetry': True
                }), 400
            
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

@main_bp.route('/huntmanager', methods=['GET'])
def huntmanager():
    return render_template(
        'HuntManager.html',
        FUNCTION_APP_BASE_URL=current_app.config.get('FUNCTION_APP_BASE_URL'),
        FUNCTION_KEY=current_app.config.get('FUNCTION_KEY')
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
        FUNCTION_APP_BASE_URL=current_app.config.get('FUNCTION_APP_BASE_URL'),
        FUNCTION_KEY=current_app.config.get('FUNCTION_KEY')
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
        
        # Check if FUNCTION_APP_BASE_URL and FUNCTION_KEY are configured
        func_url = current_app.config.get('FUNCTION_APP_BASE_URL')
        func_key = current_app.config.get('FUNCTION_KEY')
        
        if not func_url or not func_key:
            current_app.logger.error("FUNCTION_APP_BASE_URL or FUNCTION_KEY not configured")
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

# Hunt Manager endpoints

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


# SAVE FOR LATER - TI Manager integration with MDETIManager function
# TI Manager specific endpoints that call MDETIManager Azure Function
# @main_bp.route('/api/ti/device-groups', methods=['POST'])
# def ti_device_groups():
#     """Get device groups for TI Manager using MDETIManager function"""
#     try:
#         data = request.get_json()
#         if not data:
#             return jsonify({'error': 'Request must be JSON and not empty.'}), 400
#         
#         tenant_id = data.get('TenantId')
#         if not tenant_id:
#             return jsonify({'error': 'TenantId is required'}), 400
#             
#         current_app.logger.info(f"Getting TI device groups for tenant: {tenant_id}")
#         
#         # Check if Azure Function is available
#         func_url_base = current_app.config.get('FUNCURL')
#         func_key = current_app.config.get('FUNCKEY')
#         
#         if not func_url_base or not func_key:
#             # Return mock response when Azure Function is not available
#             current_app.logger.warning("FUNCURL or FUNCKEY not configured, returning mock device groups")
#             mock_response = {
#                 'Status': 'Success',
#                 'DeviceGroups': [
#                     {'GroupId': 'mock-group-1', 'GroupName': 'Mock Device Group 1'},
#                     {'GroupId': 'mock-group-2', 'GroupName': 'Mock Device Group 2'}
#                 ],
#                 'Count': 2
#             }
#             return jsonify(mock_response)
#           # Call MDETIManager Azure Function
#         result = call_azure_function('MDETIManager', {
#             'Function': 'GetDeviceGroups',
#             'TenantId': tenant_id
#         }, read_timeout=60)
#         
#         # Handle Azure Function errors by falling back to mock data
#         if isinstance(result, dict) and 'error' in result:
#             current_app.logger.warning(f"Azure Function failed, returning mock device groups: {result.get('error', 'Unknown error')}")
#             mock_response = {
#                 'Status': 'Success',
#                 'DeviceGroups': [
#                     {'GroupId': 'mock-group-1', 'GroupName': 'Mock Device Group 1'},
#                     {'GroupId': 'mock-group-2', 'GroupName': 'Mock Device Group 2'}
#                 ],
#                 'Count': 2
#             }
#             return jsonify(mock_response)
#         
#         return jsonify(result)
#         
#     except Exception as e:
#         current_app.logger.error(f"Exception in ti_device_groups: {str(e)}")
#         return jsonify({'error': f"An error occurred: {str(e)}"}), 500

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
        func_url_base = current_app.config.get('FUNCTION_APP_BASE_URL')
        func_key = current_app.config.get('FUNCTION_KEY')
        
        if not func_url_base or not func_key or func_url_base == 'your-function-app.azurewebsites.net' or func_key == 'your-function-key-here':
            # Return error when Azure Function is not available instead of mock data
            error_msg = f"Azure Function not configured properly - FUNCTION_APP_BASE_URL: {func_url_base}, FUNCTION_KEY: {'SET' if func_key else 'NOT SET'}"
            current_app.logger.error(error_msg)
            return jsonify({'error': 'Azure Function configuration missing or invalid', 'details': error_msg}), 500
        
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
        
        # Handle Azure Function errors - return actual error instead of mock data
        if isinstance(result, dict) and 'error' in result:
            error_msg = f"Azure Function failed: {result.get('error', 'Unknown error')}"
            current_app.logger.error(error_msg)
            return jsonify({'error': 'Azure Function call failed', 'details': result}), 500
        
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
          # Allow GetDetectionRulesfromStorage to work without TenantId (central storage)
        if not tenant_id and function_name not in ['GetDetectionRulesfromStorage', 'GetDetectionRulesFromStorage']:
            return jsonify({'error': 'TenantId is required'}), 400
            
        current_app.logger.info(f"TI Detections operation '{function_name}' for tenant: {tenant_id}")
        print(f"[DEBUG] TI Detections called with tenant: {tenant_id}, function: {function_name}")
        
        # Check if Azure Function is available
        func_url_base = current_app.config.get('FUNCTION_APP_BASE_URL')
        func_key = current_app.config.get('FUNCTION_KEY')
        
        current_app.logger.info(f"Azure Function config check - FUNCTION_APP_BASE_URL: {func_url_base}, FUNCTION_KEY: {'*****' if func_key else None}")
        print(f"[DEBUG] Azure Function config - FUNCTION_APP_BASE_URL: {func_url_base}, FUNCTION_KEY: {'SET' if func_key else 'NOT SET'}")
        
        if not func_url_base or not func_key or func_url_base == 'your-function-app.azurewebsites.net' or func_key == 'your-function-key-here':
            # Return error when Azure Function is not available instead of mock data
            error_msg = f"Azure Function not configured properly - FUNCTION_APP_BASE_URL: {func_url_base}, FUNCTION_KEY: {'SET' if func_key else 'NOT SET'}"
            current_app.logger.error(error_msg)
            print(f"[DEBUG] Configuration error: {error_msg}")
            return jsonify({'error': 'Azure Function configuration missing or invalid', 'details': error_msg}), 500
        
        # Prepare payload for MDETIManager
        payload = {
            'Function': function_name
        }
        
        # Only add TenantId if it's provided
        if tenant_id:
            payload['TenantId'] = tenant_id
        
        # Add additional parameters if present
        for key, value in data.items():
            if key not in ['Function', 'TenantId']:
                payload[key] = value
        
        print(f"[DEBUG] About to call MDETIManager with payload: {payload}")
        
        # Call MDETIManager Azure Function
        result = call_azure_function('MDETIManager', payload, read_timeout=120)  # Longer timeout for detections
        
        print(f"[DEBUG] Azure Function result: {result}")
        print(f"[DEBUG] Result type: {type(result)}")
          # Handle Azure Function errors - return actual error instead of mock data
        if isinstance(result, dict) and 'error' in result:
            error_msg = f"Azure Function failed: {result.get('error', 'Unknown error')}"
            current_app.logger.error(error_msg)
            print(f"[DEBUG] Azure Function call failed: {result}")
            return jsonify({'error': 'Azure Function call failed', 'details': result}), 500
        
        return jsonify(result)
        
    except Exception as e:
        current_app.logger.error(f"Exception in ti_detections: {str(e)}")
        return jsonify({'error': f"An error occurred: {str(e)}"}), 500

@main_bp.route('/api/ti/sync', methods=['POST'])
def ti_sync():
    """Sync TI data using MDECDManager function"""
    try:
        current_app.logger.info("ti_sync endpoint called")
        
        data = request.get_json()
        current_app.logger.info(f"Received data: {data}")
        
        if not data:
            current_app.logger.error("No JSON data received")
            return jsonify({'error': 'Request must be JSON and not empty.'}), 400
        
        tenant_id = data.get('TenantId')
        if not tenant_id:
            current_app.logger.error("No TenantId in data")
            return jsonify({'error': 'TenantId is required'}), 400
            
        current_app.logger.info(f"TI Sync operation for tenant: {tenant_id}")
        
        # Check if Azure Function is available
        func_url_base = current_app.config.get('FUNCTION_APP_BASE_URL')
        func_key = current_app.config.get('FUNCTION_KEY')
        
        current_app.logger.info(f"FUNCTION_APP_BASE_URL: {func_url_base[:20] if func_url_base else 'None'}...")
        current_app.logger.info(f"FUNCTION_KEY configured: {bool(func_key)}")        
        if not func_url_base or not func_key or func_url_base == 'your-function-app.azurewebsites.net' or func_key == 'your-function-key-here':
            # Return error when Azure Function is not available instead of mock data
            error_msg = f"Azure Function not configured properly - FUNCTION_APP_BASE_URL: {func_url_base}, FUNCTION_KEY: {'SET' if func_key else 'NOT SET'}"
            current_app.logger.error(error_msg)
            return jsonify({'error': 'Azure Function configuration missing or invalid', 'details': error_msg}), 500
        
        # Prepare payload for MDECDManager
        payload = {
            'Function': 'SyncTIData',
            'TenantId': tenant_id
        }
          # Add additional parameters if present
        for key, value in data.items():
            if key not in ['Function', 'TenantId']:
                payload[key] = value
        
        current_app.logger.info(f"Calling Azure Function with payload: {payload}")
        
        # Call MDECDManager Azure Function with extended timeout for sync operations
        result = call_azure_function('MDECDManager', payload, read_timeout=300)  # 5 minute timeout for sync
        
        current_app.logger.info(f"Azure Function result: {result}")
        
        if isinstance(result, dict) and 'error' in result:
            current_app.logger.error(f"TI Sync operation failed: {result}")
              # Check if it's an Azure Function configuration issue
            if result.get('error') == 'HTTP error: Unknown' and result.get('details') == 'No response body':
                return jsonify({
                    'error': 'Azure Function is not responding correctly',
                    'details': 'The MDECDManager function may not be deployed or configured properly',
                    'suggestion': 'Please check if the MDECDManager Azure Function is deployed and functioning'
                }), 500
            
            return jsonify(result), 500
        
        return jsonify(result)
        
    except Exception as e:
        current_app.logger.error(f"Exception in ti_sync: {str(e)}", exc_info=True)
        return jsonify({'error': f"An error occurred: {str(e)}"}), 500

# Hunt Manager schedule endpoints

@main_bp.route('/api/hunt/schedules', methods=['GET'])
def hunt_schedules_get():
    """Get scheduled hunts for a tenant"""
    try:
        tenant_id = request.args.get('TenantId')
        if not tenant_id:
            return jsonify({'error': 'TenantId parameter is required'}), 400
        
        current_app.logger.info(f"Getting scheduled hunts for tenant: {tenant_id}")
        
        # Call MDEHuntManager Azure Function to get schedules
        result = call_azure_function('MDEHuntManager', {
            'Function': 'GetHuntSchedules',
            'TenantId': tenant_id,
            'EnabledOnly': False
        }, read_timeout=60)
        
        if isinstance(result, dict) and 'error' in result:
            current_app.logger.error(f"Get schedules failed: {result}")
            return jsonify({'success': False, 'error': result.get('error', 'Unknown error')}), 500
        
        # Wrap the successful result in a consistent format
        schedules = []
        if isinstance(result, list):
            schedules = result
        elif isinstance(result, dict):
            schedules = result.get('schedules', result.get('Schedules', result.get('HuntSchedules', [])))
        
        return jsonify({'success': True, 'schedules': schedules})
        
    except Exception as e:
        current_app.logger.error(f"Exception in hunt_schedules_get: {str(e)}")
        return jsonify({'success': False, 'error': f"An error occurred: {str(e)}"}), 500

@main_bp.route('/api/hunt/schedules', methods=['POST'])
def hunt_schedules_create():
    """Create a new scheduled hunt"""
    try:
        data = request.get_json()
        if not data:
            return jsonify({'error': 'Request must be JSON and not empty.'}), 400
        
        tenant_id = data.get('TenantId')
        if not tenant_id:
            return jsonify({'error': 'TenantId is required'}), 400
            
        current_app.logger.info(f"Creating scheduled hunt for tenant: {tenant_id}")
          # Prepare payload for MDEHuntManager
        payload = {
            'Function': 'SaveHuntSchedule',
            'TenantId': tenant_id
        }
        
        # Add all the schedule data
        for key, value in data.items():
            if key not in ['Function']:
                payload[key] = value
        
        # Call MDEHuntManager Azure Function
        result = call_azure_function('MDEHuntManager', payload, read_timeout=120)
        
        if isinstance(result, dict) and 'error' in result:
            current_app.logger.error(f"Create schedule failed: {result}")
            return jsonify(result), 500
        
        return jsonify(result)
        
    except Exception as e:
        current_app.logger.error(f"Exception in hunt_schedules_create: {str(e)}")
        return jsonify({'error': f"An error occurred: {str(e)}"}), 500

@main_bp.route('/api/hunt/schedules/<schedule_id>/enable', methods=['PUT'])
def hunt_schedules_enable(schedule_id):
    """Enable a scheduled hunt"""
    try:
        tenant_id = request.args.get('TenantId')
        if not tenant_id:
            return jsonify({'error': 'TenantId parameter is required'}), 400
            
        current_app.logger.info(f"Enabling schedule {schedule_id} for tenant: {tenant_id}")
          # Call MDEHuntManager Azure Function
        result = call_azure_function('MDEHuntManager', {
            'Function': 'EnableHuntSchedule',
            'TenantId': tenant_id,
            'ScheduleId': schedule_id
        }, read_timeout=60)
        
        if isinstance(result, dict) and 'error' in result:
            current_app.logger.error(f"Enable schedule failed: {result}")
            return jsonify(result), 500
        
        return jsonify(result)
        
    except Exception as e:
        current_app.logger.error(f"Exception in hunt_schedules_enable: {str(e)}")
        return jsonify({'error': f"An error occurred: {str(e)}"}), 500

@main_bp.route('/api/hunt/schedules/<schedule_id>/disable', methods=['PUT'])
def hunt_schedules_disable(schedule_id):
    """Disable a scheduled hunt"""
    try:
        tenant_id = request.args.get('TenantId')
        if not tenant_id:
            return jsonify({'error': 'TenantId parameter is required'}), 400
            
        current_app.logger.info(f"Disabling schedule {schedule_id} for tenant: {tenant_id}")
          # Call MDEHuntManager Azure Function
        result = call_azure_function('MDEHuntManager', {
            'Function': 'DisableHuntSchedule',
            'TenantId': tenant_id,
            'ScheduleId': schedule_id
        }, read_timeout=60)
        
        if isinstance(result, dict) and 'error' in result:
            current_app.logger.error(f"Disable schedule failed: {result}")
            return jsonify(result), 500
        
        return jsonify(result)
        
    except Exception as e:
        current_app.logger.error(f"Exception in hunt_schedules_disable: {str(e)}")
        return jsonify({'error': f"An error occurred: {str(e)}"}), 500

@main_bp.route('/api/hunt/schedules/<schedule_id>', methods=['DELETE'])
def hunt_schedules_delete(schedule_id):
    """Delete a scheduled hunt"""
    try:
        tenant_id = request.args.get('TenantId')
        if not tenant_id:
            return jsonify({'error': 'TenantId parameter is required'}), 400
            
        current_app.logger.info(f"Deleting schedule {schedule_id} for tenant: {tenant_id}")
          # Call MDEHuntManager Azure Function
        result = call_azure_function('MDEHuntManager', {
            'Function': 'RemoveHuntSchedule',
            'TenantId': tenant_id,
            'ScheduleId': schedule_id
        }, read_timeout=60)
        
        if isinstance(result, dict) and 'error' in result:
            current_app.logger.error(f"Delete schedule failed: {result}")
            return jsonify(result), 500
        
        return jsonify(result)
        
    except Exception as e:
        current_app.logger.error(f"Exception in hunt_schedules_delete: {str(e)}")
        return jsonify({'error': f"An error occurred: {str(e)}"}), 500


# MCP Server HTTP Endpoints for external access
@main_bp.route('/.well-known/mcp/capabilities', methods=['GET'])
def mcp_capabilities():
    """MCP discovery endpoint - returns server capabilities."""
    try:
        capabilities = {
            "name": "MDEAutomator MCP Server",
            "version": "1.0.0",
            "description": "Microsoft Defender for Endpoint automation and AI assistance",
            "protocols": ["http"],
            "endpoints": {
                "discover": "/mcp/discover",
                "execute": "/mcp/execute"
            },
            "capabilities": {
                "tools": True,
                "ai_chat": True,
                "automation": True,
                "mde_integration": True
            },
            "tools_count": len(get_mcp_client(flask_config=current_app.config).get_available_tools())
        }
        return jsonify(capabilities)
    except Exception as e:
        current_app.logger.error(f"MCP capabilities error: {e}")
        return jsonify({'error': str(e)}), 500

@main_bp.route('/mcp/discover', methods=['GET', 'POST'])
def mcp_discover():
    """MCP tool discovery endpoint."""
    try:
        mcp_client = get_mcp_client(flask_config=current_app.config)
        tools = mcp_client.get_available_tools()
        
        return jsonify({
            "tools": tools,
            "server_info": {
                "name": "MDEAutomator MCP Server",
                "version": "1.0.0",
                "description": "Microsoft Defender for Endpoint automation and AI assistance"
            }
        })
    except Exception as e:
        current_app.logger.error(f"MCP discover error: {e}")
        return jsonify({'error': str(e)}), 500

@main_bp.route('/mcp/execute', methods=['POST'])
def mcp_execute():
    """MCP tool execution endpoint."""
    try:
        data = request.get_json()
        if not data or 'tool_name' not in data:
            return jsonify({'error': 'tool_name is required'}), 400
        
        tool_name = data['tool_name']
        arguments = data.get('arguments', {})
        
        current_app.logger.info(f"MCP execute request: tool={tool_name}, args={arguments}")
        
        # Create an isolated execution function that doesn't reuse existing clients
        def isolated_mcp_execution():
            """Execute MCP tool in a completely isolated context."""
            import asyncio
            import os
            import sys
            import threading
            
            # Create a separate thread-local event loop
            result_container = {'result': None, 'exception': None}
            
            def thread_worker():
                try:
                    # Create new event loop for this thread
                    loop = asyncio.new_event_loop()
                    asyncio.set_event_loop(loop)
                    
                    # Import MCP components fresh in this context
                    sys.path.insert(0, os.path.join(os.path.dirname(__file__), '.'))
                    
                    from mdeautomator_mcp.config import MCPConfig
                    from mdeautomator_mcp.server import MDEAutomatorMCPServer
                    
                    # Create fresh configuration
                    config = MCPConfig.from_environment()
                    
                    # Create fresh MCP server instance
                    mcp_server = MDEAutomatorMCPServer(config)
                    
                    # Initialize and execute
                    async def run_tool():
                        try:
                            await mcp_server.function_client.initialize()
                            
                            # Route the tool call
                            result = await mcp_server._route_tool_call(tool_name, arguments)
                            return {
                                'success': True,
                                'result': result,
                                'tool': tool_name,
                                'timestamp': time.time()
                            }
                        finally:
                            # Clean up MCP server resources
                            try:
                                if hasattr(mcp_server.function_client, 'cleanup'):
                                    await mcp_server.function_client.cleanup()
                            except:
                                pass
                    
                    # Execute the tool
                    result_container['result'] = loop.run_until_complete(run_tool())
                    
                except Exception as e:
                    current_app.logger.error(f"Isolated MCP execution error: {e}", exc_info=True)
                    result_container['exception'] = e
                finally:
                    # Let the loop clean up naturally
                    try:
                        loop.close()
                    except:
                        pass
            
            # Run in thread and wait for completion
            thread = threading.Thread(target=thread_worker)
            thread.start()
            thread.join(timeout=120)  # 2 minute timeout
            
            if thread.is_alive():
                raise TimeoutError("MCP tool execution timed out")
            
            if result_container['exception']:
                raise result_container['exception']
            
            return result_container['result'] or {
                'success': False,
                'error': 'Unknown execution error',
                'tool': tool_name,
                'timestamp': time.time()
            }
        
        # Execute the isolated MCP tool call
        result = isolated_mcp_execution()
        
        current_app.logger.info(f"MCP execute completed: tool={tool_name}, success={result.get('success', False)}")
        return jsonify(result)
        
    except TimeoutError:
        current_app.logger.error(f"MCP execute timeout: tool={tool_name}")
        return jsonify({'error': 'Tool execution timed out', 'tool': tool_name, 'success': False}), 504
    except Exception as e:
        current_app.logger.error(f"MCP execute error: {e}", exc_info=True)
        return jsonify({
            'error': str(e), 
            'tool': tool_name,
            'success': False,
            'timestamp': time.time()
        }), 500

@main_bp.route('/mcp/status', methods=['GET'])
def mcp_status():
    """MCP server status endpoint."""
    try:
        mcp_client = get_mcp_client(flask_config=current_app.config)
        
        return jsonify({
            "status": "active",
            "initialized": mcp_client.is_initialized,
            "tools_available": len(mcp_client.get_available_tools()),
            "ai_enabled": mcp_client.is_ai_available,
            "ai_foundry_configured": mcp_client.is_ai_available,
            "server_time": time.time(),
            "notes": {
                "ai_features": "Available" if mcp_client.is_ai_available else "Requires Azure AI Foundry configuration",
                "mde_tools": "Available via MCP server"
            }
        })
    except Exception as e:
        current_app.logger.error(f"MCP status error: {e}")
        return jsonify({'error': str(e)}), 500

# Diagnostic endpoint for debugging deployment issues
@main_bp.route('/api/diagnostic', methods=['GET'])
def diagnostic():
    """Diagnostic endpoint to check configuration and environment"""
    try:
        diagnostic_info = {
            'status': 'running',
            'python_version': sys.version,
            'flask_app_name': current_app.name if current_app else 'No current app',
            'environment_variables': {
                'FUNCTION_APP_BASE_URL': current_app.config.get('FUNCTION_APP_BASE_URL', 'NOT SET') if current_app else 'No app context',
                'FUNCTION_KEY': 'SET' if current_app.config.get('FUNCTION_KEY') else 'NOT SET' if current_app else 'No app context',
                'FLASK_ENV': os.environ.get('FLASK_ENV', 'NOT SET'),
                'PYTHONPATH': os.environ.get('PYTHONPATH', 'NOT SET')
            },
            'working_directory': os.getcwd(),
            'sys_path': sys.path[:5],  # First 5 entries only
            'imported_modules': {
                'requests': 'imported' if 'requests' in sys.modules else 'not imported',
                'flask': 'imported' if 'flask' in sys.modules else 'not imported',
                'json': 'imported' if 'json' in sys.modules else 'not imported'
            },
            'timestamp': time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())
        }
        
        return jsonify(diagnostic_info), 200
        
    except Exception as e:
        return jsonify({
            'status': 'error',
            'error': str(e),
            'error_type': type(e).__name__,
            'timestamp': time.strftime('%Y-%m-%d %H:%M:%S UTC', time.gmtime())
        }), 500
