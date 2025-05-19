import os
import requests
from flask import Blueprint, render_template, request, current_app, flash, redirect, url_for, jsonify

main_bp = Blueprint('main', __name__)

# Utility to call Azure Function

def call_azure_function(function_name, payload):
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
    read_timeout = 3      # seconds to wait for the server to send a response (very short for long-running tasks)

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

    # DeviceIds validation (remains as is, assuming it's generally required for commands via this route)
    # If specific actions like 'InvokeUploadLR' don't need DeviceIds and are sent here, this might need adjustment.
    device_ids = azure_function_payload.get('DeviceIds')
    if not device_ids or not isinstance(device_ids, list) or len(device_ids) == 0:
        if specific_action not in ["InvokeUploadLR"]: # Example: Exempt InvokeUploadLR
             current_app.logger.error(f"Missing or invalid 'DeviceIds' for action '{specific_action}'. Payload: {azure_function_payload}")
             return jsonify({'error': 'DeviceIds are required and must be a non-empty list for this action.'}), 400
    
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