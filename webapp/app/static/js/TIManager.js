window.addEventListener('DOMContentLoaded', () => {
    console.log('TIManager page JavaScript loaded');
    
    // Initialize device groups dropdown
    clearDeviceGroupsDropdown();
    
    // Load tenants dropdown on page load
    loadTenants();

    // Set up event listeners after a short delay to ensure DOM is fully loaded
    setTimeout(() => {
        console.log('Setting up event listeners...');
        setupEventListeners();
    }, 100);

    // Auto-load threat intelligence data when tenant is available
    waitForTenantDropdownAndLoadData();

    // Set up other event listeners
    const refreshIndicatorsBtn = document.getElementById('refreshIndicatorsBtn');
    const tiManualForm = document.getElementById('tiManualForm');
    const tiCsvImportBtn = document.getElementById('tiCsvImportBtn');
    const tiCsvExportBtn = document.getElementById('tiCsvExportBtn');
    const refreshDetectionsBtn = document.getElementById('refreshDetectionsBtn');
    const deleteSelectedBtn = document.getElementById('deleteSelectedBtn');
    const syncDetectionsBtn = document.getElementById('syncDetectionsBtn');

    // Detection Manager buttons
    const addDetectionBtn = document.getElementById('addDetectionBtn');
    const updateDetectionBtn = document.getElementById('updateSelectedDetectionBtn');
    const deleteDetectionBtn = document.getElementById('deleteSelectedDetectionBtn');
    const libraryDetectionBtn = document.getElementById('libraryDetectionBtn');

    refreshIndicatorsBtn.addEventListener('click', loadAllThreatIntelligenceData);
    tiManualForm.addEventListener('submit', tiManualFormSubmit);
    tiCsvImportBtn.addEventListener('click', tiCsvImportBtnClick);
    tiCsvExportBtn.addEventListener('click', tiCsvExportBtnClick);
    refreshDetectionsBtn.addEventListener('click', loadAllThreatIntelligenceData);
    deleteSelectedBtn.addEventListener('click', deleteSelectedIOCs);
    if (syncDetectionsBtn) {
        syncDetectionsBtn.addEventListener('click', syncDetections);
    }

    // Detection Manager button event listeners
    if (addDetectionBtn) {
        addDetectionBtn.addEventListener('click', () => {
            openDetectionEditorModal('add');
        });
    }

    if (updateDetectionBtn) {
        updateDetectionBtn.addEventListener('click', async () => {
            const selected = getSelectedDetections();
            if (selected.length !== 1) {
                alert('Please select exactly one detection rule to update.');
                return;
            }
            
            const detectionId = selected[0];
            const tenantId = getTenantId();
            
            try {
                // Fetch current detection rule details from backend
                const url = '/api/ti/detections';
                const payload = { 
                    TenantId: tenantId, 
                    Function: 'GetDetectionRule',
                    RuleId: detectionId
                };
                
                console.log('Fetching detection rule details for update:', payload);
                
                const response = await fetch(url, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(payload)
                });
                
                if (!response.ok) {
                    throw new Error(`HTTP error! status: ${response.status}`);
                }
                
                const result = await response.json();
                console.log('GetDetectionRule response:', result);
                
                // Pass the current detection data to the modal for pre-filling
                const jsonContent = JSON.stringify(result, null, 2);
                openDetectionEditorModal('update', detectionId, jsonContent);
                
            } catch (error) {
                console.error('Error fetching detection rule for update:', error);
                alert('Failed to fetch detection rule details. Please try again.');
            }
        });
    }

    if (deleteDetectionBtn) {
        deleteDetectionBtn.addEventListener('click', async () => {
            const selected = getSelectedDetections();
            if (selected.length === 0) return;
            if (!confirm(`Are you sure you want to delete ${selected.length} detection rule(s)?`)) return;
            const tenantId = getTenantId();
            const url = '/api/ti/detections';
            let deletedCount = 0;
            for (const ruleId of selected) {
                const payload = { TenantId: tenantId, Function: 'UndoDetectionRule', RuleId: ruleId };
                try {
                    await fetch(url, {
                        method: 'POST',
                        headers: { 'Content-Type': 'application/json' },
                        body: JSON.stringify(payload)
                    });
                    deletedCount++;
                } catch (err) {
                    console.error('Error deleting detection rule:', err);
                }
            }
            if (deletedCount > 0) {
                alert(`Successfully deleted ${deletedCount} detection rule(s).`);
                loadAllThreatIntelligenceData();
            }
        });
    }

    // Library button event listener
    if (libraryDetectionBtn) {
        libraryDetectionBtn.addEventListener('click', async () => {
            const libraryModal = document.getElementById('detectionLibraryModal');
            const libraryList = document.getElementById('detectionLibraryList');
            if (!libraryModal || !libraryList) return;
            
            libraryModal.style.display = 'flex';
            libraryList.innerHTML = '<div style="color:#7fff7f;">Loading...</div>';
            const tenantId = getTenantId();
            const url = '/api/ti/detections';
            const payload = { TenantId: tenantId, Function: 'GetDetectionRulesfromStorage' };
            try {
                const res = await fetch(url, {
                    method: 'POST',
                    headers: { 'Content-Type': 'application/json' },
                    body: JSON.stringify(payload)
                });
                const result = await res.json();
                const rules = Array.isArray(result) ? result : (result.value || result.rules || []);
                if (!rules.length) {
                    libraryList.innerHTML = '<div style="color:#ff8888;">No rules found in storage.</div>';
                    return;
                }
                libraryList.innerHTML = '';
                rules.forEach(rule => {
                    const title = rule.RuleTitle || rule.DisplayName || rule.displayName || rule.Title || rule.title || rule.RuleName || 'Untitled';
                    let desc = '';
                    try {
                        if (rule.Query) {
                            const parsed = JSON.parse(rule.Query);
                            desc = parsed.Description || parsed.description || parsed.AlertDescription || parsed.alertDescription || parsed.alertTemplate?.description || '';
                        }
                    } catch (e) { /* ignore */ }
                    const row = document.createElement('div');
                    row.style.display = 'flex';
                    row.style.justifyContent = 'space-between';
                    row.style.alignItems = 'center';
                    row.style.padding = '10px';
                    row.style.borderBottom = '1px solid #333';
                    row.style.color = '#7fff7f';
                    const info = document.createElement('div');
                    info.innerHTML = `<strong>${title}</strong><br><span style="font-size:0.85em;color:#aaa;">${desc || 'No description'}</span>`;
                    const btn = document.createElement('button');
                    btn.textContent = 'Use';
                    btn.className = 'cta-button';
                    btn.style.padding = '5px 10px';
                    btn.style.fontSize = '0.85em';
                    btn.onclick = () => {
                        // Handle different data structures from library
                        let ruleData = rule;
                        
                        // If rule.Query exists and looks like JSON, try to parse it as the main rule data
                        if (rule.Query && typeof rule.Query === 'string') {
                            try {
                                const parsedQuery = JSON.parse(rule.Query);
                                // If the parsed query has detection rule properties, use it
                                if (parsedQuery.displayName || parsedQuery.DisplayName || parsedQuery.query || parsedQuery.Query) {
                                    ruleData = parsedQuery;
                                    // Keep the original rule title if the parsed data doesn't have one
                                    if (!ruleData.displayName && !ruleData.DisplayName && (rule.RuleTitle || rule.Title)) {
                                        ruleData.displayName = rule.RuleTitle || rule.Title;
                                    }
                                } else {
                                    ruleData = {
                                        ...rule,
                                        query: rule.Query,
                                        displayName: rule.RuleTitle || rule.DisplayName || rule.Title || rule.RuleName
                                    };
                                }
                            } catch (e) {
                                // If parsing fails, treat rule.Query as just the KQL query text
                                ruleData = {
                                    ...rule,
                                    query: rule.Query,
                                    displayName: rule.RuleTitle || rule.DisplayName || rule.Title || rule.RuleName
                                };
                            }
                        }
                        
                        openDetectionEditorModal('add', '', JSON.stringify(ruleData, null, 2));
                        libraryModal.style.display = 'none';
                    };
                    row.appendChild(info);
                    row.appendChild(btn);
                    libraryList.appendChild(row);
                });
            } catch (err) {
                console.error('Error loading library rules:', err);
                libraryList.innerHTML = '<div style="color:#ff8888;">Error loading rules.</div>';
            }
        });
    }

    // Set up modal close handlers
    const libraryModal = document.getElementById('detectionLibraryModal');
    if (libraryModal) {
        const closeLibraryBtn = libraryModal.querySelector('.close-detection-library');
        if (closeLibraryBtn) {
            closeLibraryBtn.onclick = function() {
                libraryModal.style.display = 'none';
            };
        }

        // Set up library install handler (event delegation)
        const libraryList = document.getElementById('detectionLibraryList');
        if (libraryList) {
            libraryList.addEventListener('click', async (e) => {
                if (e.target && e.target.classList.contains('install-library-rule')) {
                    const title = decodeURIComponent(e.target.getAttribute('data-title'));
                    if (!title) return;
                    if (!confirm(`Install detection rule: ${title}?`)) return;
                    const tenantId = getTenantId();
                    const url = '/api/ti/detections';
                    const payload = { TenantId: tenantId, Function: 'InstallDetectionRulefromStorage', RuleTitle: title };
                    try {
                        e.target.disabled = true;
                        e.target.textContent = 'Installing...';
                        await fetch(url, {
                            method: 'POST',
                            headers: { 'Content-Type': 'application/json' },
                            body: JSON.stringify(payload)
                        });
                        e.target.textContent = 'Installed!';
                        setTimeout(() => { libraryModal.style.display = 'none'; loadAllThreatIntelligenceData(); }, 1200);
                    } catch (err) {
                        console.error('Error installing library rule:', err);
                        e.target.textContent = 'Error';
                        setTimeout(() => { e.target.textContent = 'Install'; e.target.disabled = false; }, 2000);
                    }
                }
            });
        }
    }
});

// Helper: Wait for tenant dropdown to be populated, then auto-load data
function waitForTenantDropdownAndLoadData() {
    const dropdown = document.getElementById('tenantDropdown');
    if (!dropdown) {
        setTimeout(waitForTenantDropdownAndLoadData, 100);
        return;
    }
    
    if (dropdown.options.length === 0) {
        setTimeout(waitForTenantDropdownAndLoadData, 100);
        return;
    }
    
    if (dropdown.value && dropdown.value.trim() !== '') {
        console.log('Auto-loading threat intelligence data for tenant:', dropdown.value);
        loadAllThreatIntelligenceData().then(() => {
            // Mark auto-load as completed
            if (typeof window.markAutoLoadCompleted === 'function') {
                window.markAutoLoadCompleted();
            }
        }).catch((error) => {
            console.error('Error in threat intelligence auto-load:', error);
            // Mark auto-load as completed even on error
            if (typeof window.markAutoLoadCompleted === 'function') {
                window.markAutoLoadCompleted();
            }
        });
    } else {
        // No tenant selected, mark auto-load as completed immediately
        if (typeof window.markAutoLoadCompleted === 'function') {
            window.markAutoLoadCompleted();
        }
    }
}

function getTenantId() {
    const tenantDropdown = document.getElementById('tenantDropdown');
    return tenantDropdown ? tenantDropdown.value.trim() : '';
}

// Main function to systematically load all threat intelligence data
async function loadAllThreatIntelligenceData() {
    const tenantId = getTenantId();
    if (!tenantId) {
        console.warn('No tenant selected for loading threat intelligence');
        return;
    }

    console.log(`Starting systematic threat intelligence loading for tenant: ${tenantId}`);
    window.showContentLoading('Loading Threat Intelligence Data');

    try {
        // Step 1: Load Device Groups first
        console.log('Step 1: Loading Device Groups...');
        await loadDeviceGroupsForTenant(tenantId);
        
        // Step 2: Load Indicators
        console.log('Step 2: Loading Indicators...');
        await loadIndicatorsForTenant(tenantId);
        
        // Step 3: Load Detection Rules
        console.log('Step 3: Loading Detection Rules...');
        await loadDetectionRulesForTenant(tenantId);
        
        console.log('All threat intelligence data loaded successfully');
    } catch (error) {
        console.error('Error loading threat intelligence data:', error);
        alert(`Error loading data: ${error.message}`);
    } finally {
        window.hideContentLoading();
    }
}

// Step 1: Load Device Groups using MDETIManager
async function loadDeviceGroupsForTenant(tenantId) {
    const url = '/api/ti/device-groups';
    const payload = { 
        TenantId: tenantId, 
        Function: 'GetDeviceGroups' 
    };
    
    console.log('Calling TI device groups API with payload:', payload);
    
    // Add timeout to handle cold starts
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 60000); // 60 second timeout
    
    try {
        const response = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload),
            signal: controller.signal
        });
        
        clearTimeout(timeoutId);
        
        if (!response.ok) {
            const errorText = await response.text();
            console.error('HTTP error response text:', errorText);
            throw new Error(`HTTP ${response.status}: ${response.statusText}`);
        }
        
        const responseText = await response.text();
        console.log('Raw response text:', responseText);
        
        let result;
        try {
            result = JSON.parse(responseText);
        } catch (parseError) {
            console.error('JSON parse error:', parseError);
            console.error('Response text that failed to parse:', responseText);
            
            // Try to extract JSON from the response if it's mixed with other text
            const jsonMatch = responseText.match(/\[.*\]|\{.*\}/s);
            if (jsonMatch) {
                console.log('Found potential JSON in response:', jsonMatch[0]);
                try {
                    result = JSON.parse(jsonMatch[0]);
                    console.log('Successfully parsed extracted JSON:', result);
                } catch (extractParseError) {
                    console.error('Failed to parse extracted JSON:', extractParseError);
                    throw new Error(`Failed to parse JSON response: ${parseError.message}`);
                }
            } else {
                throw new Error(`No valid JSON found in response: ${parseError.message}`);
            }
        }
        
        console.log('Device Groups API response:', result);
        console.log('Device Groups API response type:', typeof result);
        console.log('Device Groups API response keys:', Object.keys(result || {}));
        
        // Handle different response formats with comprehensive parsing
        let deviceGroups = [];
        
        // First, check if it's a direct array
        if (Array.isArray(result)) {
            deviceGroups = result;
            console.log('Device groups found as direct array');
        } 
        // Check for common property names that might contain the device groups
        else if (result && typeof result === 'object') {
            // Try various possible property names
            const possibleKeys = ['value', 'DeviceGroups', 'deviceGroups', 'groups', 'data', 'result', 'Value'];
            
            for (const key of possibleKeys) {
                if (result[key] && Array.isArray(result[key])) {
                    deviceGroups = result[key];
                    console.log(`Device groups found in property: ${key}`);
                    break;
                }
            }
            
            // If still no device groups found, log the full response for debugging
            if (deviceGroups.length === 0) {
                console.log('No device groups found in expected properties. Full response:', JSON.stringify(result, null, 2));
                
                // Try to extract any string arrays from the response
                for (const [key, value] of Object.entries(result)) {
                    if (Array.isArray(value) && value.length > 0 && typeof value[0] === 'string') {
                        console.log(`Found potential device groups array in property: ${key}`, value);
                        deviceGroups = value;
                        break;
                    }
                }
            }
        }
        
        console.log('Final device groups array:', deviceGroups);
        console.log('Device groups count:', deviceGroups.length);
        
        // Populate the device groups dropdown
        populateDeviceGroupsDropdown(deviceGroups);
        
        console.log(`Successfully loaded ${deviceGroups.length} device groups`);
        
    } catch (error) {
        clearTimeout(timeoutId);
        console.error('Error loading device groups:', error);
        console.error('Device groups error stack:', error.stack);
        
        // Populate dropdown with error message but don't throw - allow other data to load
        const dropdown = document.getElementById('tiDeviceGroups');
        if (dropdown) {
            dropdown.innerHTML = '<option value="">Error loading device groups - check console</option>';
            dropdown.disabled = true;
        }
        
        // Log warning but don't throw to allow other steps to continue
        console.warn(`Failed to load device groups: ${error.message}, continuing with other data...`);
    }
}

// Step 2: Load Indicators using MDETIManager
async function loadIndicatorsForTenant(tenantId) {
    const url = '/api/ti/indicators';
    const payload = { 
        TenantId: tenantId, 
        Function: 'GetIndicators' 
    };
    
    console.log('Calling TI indicators API with payload:', payload);
    
    // Add timeout to handle Azure Function cold starts
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 60000); // 60 second timeout
    
    try {
        const response = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload),
            signal: controller.signal
        });
        
        clearTimeout(timeoutId);
        
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}: ${response.statusText}`);
        }
        
        const result = await response.json();
        console.log('Indicators API response:', result);
        
        // Handle different response formats
        let indicators = [];
        if (Array.isArray(result)) {
            indicators = result;
        } else if (result.value && Array.isArray(result.value)) {
            indicators = result.value;
        }
        
        // Filter out webcategory indicators
        const filteredIndicators = indicators.filter(indicator => {
            const indicatorType = (indicator.IndicatorType || '').toLowerCase();
            return indicatorType !== 'webcategory';
        });
        
        // Render the indicators table
        renderIndicatorsTable(filteredIndicators);
        
        console.log(`Successfully loaded ${filteredIndicators.length} indicators (${indicators.length - filteredIndicators.length} webcategory indicators filtered out)`);
        
    } catch (error) {
        clearTimeout(timeoutId);
        console.error('Error loading indicators:', error);
        // Clear the table on error
        const container = document.getElementById('iocTableContainer');
        if (container) container.innerHTML = '<p style="color: #ff6666;">Error loading indicators</p>';
        throw new Error(`Failed to load indicators: ${error.message}`);
    }
}

// Step 3: Load Detection Rules using MDETIManager  
async function loadDetectionRulesForTenant(tenantId) {
    const url = '/api/ti/detections';
    const payload = { 
        TenantId: tenantId, 
        Function: 'GetDetectionRules' 
    };
    
    console.log('Calling TI detections API with payload:', payload);
    
    // Add timeout to handle Azure Function cold starts
    const controller = new AbortController();
    const timeoutId = setTimeout(() => controller.abort(), 60000); // 60 second timeout
    
    try {
        const response = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload),
            signal: controller.signal
        });
        
        clearTimeout(timeoutId);
        
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}: ${response.statusText}`);
        }
        
        const result = await response.json();
        console.log('Detection Rules API response:', result);
        
        // Handle different response formats
        let detectionRules = [];
        if (Array.isArray(result)) {
            detectionRules = result;
        } else if (result.value && Array.isArray(result.value)) {
            detectionRules = result.value;
        }
        
        // Render the detection rules table
        renderDetectionsTable(detectionRules);
        
        console.log(`Successfully loaded ${detectionRules.length} detection rules`);
        
    } catch (error) {
        clearTimeout(timeoutId);
        console.error('Error loading detection rules:', error);
        // Clear the table on error
        const container = document.getElementById('detectionsTableContainer');
        if (container) container.innerHTML = '<p style="color: #ff6666;">Error loading detection rules</p>';
        throw new Error(`Failed to load detection rules: ${error.message}`);
    }
}

// Helper function to populate device groups dropdown
function populateDeviceGroupsDropdown(deviceGroups) {
    const dropdown = document.getElementById('tiDeviceGroups');
    if (!dropdown) return;
    
    dropdown.innerHTML = '';
    dropdown.disabled = false;
    
    if (!Array.isArray(deviceGroups) || deviceGroups.length === 0) {
        dropdown.innerHTML = '<option value="">No device groups found</option>';
        console.log('No device groups found');
        return;
    }
    
    // Add "All Device Groups" option first
    const allOption = document.createElement('option');
    allOption.value = '';
    allOption.textContent = 'All Device Groups';
    dropdown.appendChild(allOption);
    
    // Add individual device group options
    deviceGroups.forEach(group => {
        if (group && group.trim()) { // Only add non-empty groups
            const opt = document.createElement('option');
            opt.value = group;
            opt.textContent = group;
            dropdown.appendChild(opt);
        }
    });
    
    console.log(`Device groups dropdown populated with ${deviceGroups.length} groups`);
}

function renderIndicatorsTable(indicators) {
    const container = document.getElementById('iocTableContainer');
    container.innerHTML = '';
    if (!window.gridjs) return;
    if (window.iocGrid) window.iocGrid.destroy();
    const columns = [
        { id: 'checkbox', name: '', width: '30px', formatter: (_, row) => gridjs.html(`<input type='checkbox' class='ioc-checkbox' data-id='${row.cells[1].data}' data-value='${row.cells[2].data}' data-type='${row.cells[3].data}' />`) },
        { id: 'Id', name: 'Id' },
        { id: 'IndicatorValue', name: 'Value' },
        { id: 'IndicatorType', name: 'Type' },
        { id: 'Action', name: 'Action' },
        { id: 'Severity', name: 'Severity' },
        { id: 'Title', name: 'Title' },
        { id: 'RbacGroupNames', name: 'Device Groups', formatter: cell => Array.isArray(cell) ? cell.join(', ') : (cell || '') },
        { id: 'CreationTimeDateTimeUtc', name: 'Created' },
    ];
    const data = indicators.map(i => [
        '', // Checkbox column (handled by formatter)
        i.Id, 
        i.IndicatorValue, 
        i.IndicatorType, 
        i.Action, 
        i.Severity, 
        i.Title, 
        i.RbacGroupNames, // Device Groups column
        i.CreationTimeDateTimeUtc
    ]);
    window.iocGrid = new gridjs.Grid({ columns, data, search: true, sort: true, pagination: true, autoWidth: true, width: '100%', height: 'auto' }).render(container);
    
    // Add event listeners for checkboxes after grid renders
    setTimeout(() => {
        document.querySelectorAll('.ioc-checkbox').forEach(cb => {
            cb.addEventListener('change', updateDeleteButtonState);
        });
    }, 500);
}

function getTypeAndFunctionForAdd(type) {
    switch (type) {
        case 'Certificate (SHA1)':
            return { func: 'InvokeTiCert', param: 'Sha1s' };
        case 'File (SHA1)':
            return { func: 'InvokeTiFile', param: 'Sha1s' };
        case 'File (SHA256)':
            return { func: 'InvokeTiFile', param: 'Sha256s' };
        case 'IP (v6/v4)':
            return { func: 'InvokeTiIP', param: 'IPs' };
        case 'URL':
            return { func: 'InvokeTiURL', param: 'URLs' };
        default:
            return null;
    }
}

async function tiManualFormSubmit(e) {
    e.preventDefault();
    const typeSelect = document.getElementById('tiType');
    const typeText = typeSelect.options[typeSelect.selectedIndex].text;
    const value = document.getElementById('tiValue').value.trim();
    const indicatorName = document.getElementById('tiIndicatorName').value.trim();
    // DeviceGroups dropdown (multi-select) - TEMPORARILY DISABLED due to MDE API issue
    const deviceGroupsInput = document.getElementById('tiDeviceGroups');
    let deviceGroups = [];
    if (deviceGroupsInput) {
        deviceGroups = Array.from(deviceGroupsInput.selectedOptions).map(opt => opt.value).filter(Boolean);
    }
    const tenantId = getTenantId();
    if (!tenantId) { alert('Tenant ID is required.'); return; }
    if (!value) { alert('Please enter a value.'); return; }
    const mapping = getTypeAndFunctionForAdd(typeText);
    if (!mapping) { 
        alert(`Invalid type selected. Type text: "${typeText}"`); 
        return; 
    }
    const url = '/api/ti/indicators';
    const payload = { TenantId: tenantId, Function: mapping.func };
    payload[mapping.param] = [value];
    if (indicatorName) {
        payload.IndicatorName = indicatorName; // Send as string, not array
    }
    // Add DeviceGroups if present
    if (deviceGroups.length > 0) { 
        payload.DeviceGroups = deviceGroups; 
        console.log('Adding device groups to payload:', deviceGroups);
        console.log('Device groups type:', typeof deviceGroups, 'isArray:', Array.isArray(deviceGroups));
        console.log('Device groups individual values:', deviceGroups.map((dg, i) => `[${i}]: "${dg}" (${typeof dg})`));
    } else {
        console.log('No device groups selected - indicator will apply to all devices');
    }
    
    console.log('TI Manual Form - Final payload being sent:', JSON.stringify(payload, null, 2));
    console.log('DeviceGroups in payload:', payload.DeviceGroups);
    
    try {
        const response = await fetch(url, { 
            method: 'POST', 
            headers: { 'Content-Type': 'application/json' }, 
            body: JSON.stringify(payload)
        });
        
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        
        const result = await response.json();
        console.log('TI Manual Form - Backend response:', result);
        console.log('Backend response type:', typeof result);
        console.log('Backend response keys:', Object.keys(result));
        
        if (result.error) {
            alert(`Error adding indicator: ${result.error}`);
            return;
        }
        
        // Check if result contains any device group information
        if (result.DeviceGroups) {
            console.log('Backend confirmed device groups:', result.DeviceGroups);
        }
        
        alert('Threat indicator added successfully!');
    } catch (error) {
        console.error('Error submitting TI form:', error);
        alert(`Error adding indicator: ${error.message}`);
        return;
    }
    
    loadAllThreatIntelligenceData();
}

function getTypeAndFunctionForDelete(type) {
    switch (type) {
        case 'Certificate (SHA1)':
            return { func: 'UndoTiCert', param: 'Sha1s' };
        case 'File (SHA1)':
            return { func: 'UndoTiFile', param: 'Sha1s' };
        case 'File (SHA256)':
            return { func: 'UndoTiFile', param: 'Sha256s' };
        case 'IP (v6/v4)':
            return { func: 'UndoTiIP', param: 'IPs' };
        case 'URL':
            return { func: 'UndoTiURL', param: 'URLs' };
        default:
            return null;
    }
}

function updateDeleteButtonState() {
    const deleteBtn = document.getElementById('deleteSelectedBtn');
    const checkedBoxes = document.querySelectorAll('.ioc-checkbox:checked');
    if (deleteBtn) {
        deleteBtn.disabled = checkedBoxes.length === 0;
        deleteBtn.textContent = checkedBoxes.length > 0 
            ? `Delete Selected (${checkedBoxes.length})` 
            : 'Delete Selected';
    }
}

function getSelectedIOCs() {
    const checkedBoxes = document.querySelectorAll('.ioc-checkbox:checked');
    return Array.from(checkedBoxes).map(cb => ({
        id: cb.getAttribute('data-id'),
        value: cb.getAttribute('data-value'),
        type: cb.getAttribute('data-type')
    }));
}

async function deleteSelectedIOCs() {
    const selectedIOCs = getSelectedIOCs();
    if (selectedIOCs.length === 0) {
        alert('Please select IOCs to delete.');
        return;
    }

    const tenantId = getTenantId();
    if (!tenantId) {
        alert('Tenant ID is required.');
        return;
    }

    if (!confirm(`Are you sure you want to delete ${selectedIOCs.length} selected IOC(s)?`)) {
        return;
    }

    // Group IOCs by type for batch deletion
    const groupedByType = {};
    selectedIOCs.forEach(ioc => {
        // Map the API type to the dropdown type for the delete function
        let mappedType;
        switch(ioc.type.toLowerCase()) {
            case 'certificatethumbprint':
                mappedType = 'Certificate (SHA1)';
                break;
            case 'filesha1':
                mappedType = 'File (SHA1)';
                break;
            case 'filesha256':
                mappedType = 'File (SHA256)';
                break;
            case 'ipaddress':
                mappedType = 'IP (v6/v4)';
                break;
            case 'domainname':
            case 'url':
                mappedType = 'URL';
                break;
            default:
                console.warn(`Unknown IOC type: ${ioc.type}`);
                return;
        }

        if (!groupedByType[mappedType]) {
            groupedByType[mappedType] = [];
        }
        groupedByType[mappedType].push(ioc.value);
    });

    const url = '/api/ti/indicators';
    let deletedCount = 0;

    // Process each type group
    for (const [type, values] of Object.entries(groupedByType)) {
        const mapping = getTypeAndFunctionForDelete(type);
        if (!mapping) {
            console.error(`No delete mapping found for type: ${type}`);
            continue;
        }

        const payload = { TenantId: tenantId, Function: mapping.func };
        payload[mapping.param] = values;

        try {
            await fetch(url, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            });
            deletedCount += values.length;
        } catch (error) {
            console.error(`Error deleting ${type} IOCs:`, error);
            alert(`Error deleting some ${type} IOCs. Check console for details.`);
        }
    }

    if (deletedCount > 0) {
        alert(`Successfully deleted ${deletedCount} IOC(s).`);
        loadAllThreatIntelligenceData(); // Refresh the table
    }
}

async function tiCsvImportBtnClick() {
    const fileInput = document.getElementById('tiCsvInput');
    const tenantId = getTenantId();
    if (!tenantId) { alert('Tenant ID is required.'); return; }
    if (!fileInput.files.length) { alert('Please select a CSV file.'); return; }
    
    // Get device groups from dropdown for CSV import
    const deviceGroupsInput = document.getElementById('tiDeviceGroups');
    let deviceGroups = [];
    if (deviceGroupsInput) {
        deviceGroups = Array.from(deviceGroupsInput.selectedOptions).map(opt => opt.value).filter(Boolean);
    }
    
    console.log('CSV Import - Selected device groups:', deviceGroups);
    
    const url = '/api/ti/indicators';
    const file = fileInput.files[0];
    const reader = new FileReader();
    reader.onload = async function(e) {
        const text = e.target.result;
        const lines = text.split(/\r?\n/).filter(l => l.trim());
        if (lines.length < 2) { console.error('CSV Import: CSV must have a header and at least one row.'); return; }
        const header = lines[0].split(',').map(h => h.trim().toLowerCase());
        
        // Support both Microsoft format and our legacy format
        let typeIdx = header.indexOf('indicator type');
        let valueIdx = header.indexOf('indicator value');
        let nameIdx = header.indexOf('indicator name'); // new: support optional indicator name
        
        // Fallback to legacy format
        if (typeIdx === -1) typeIdx = header.indexOf('type');
        if (valueIdx === -1) valueIdx = header.indexOf('value');
        if (nameIdx === -1) nameIdx = header.indexOf('name'); // legacy/optional
        
        if (typeIdx === -1 || valueIdx === -1) { 
            console.error('CSV Import: CSV must have columns: "Indicator Type,Indicator Value" or "Type,Value"'); 
            return; 
        }
        // Group by type, but also keep indicator names if present
        const tiData = { CertSha1s: [], Sha1s: [], Sha256s: [], IPs: [], URLs: [] };
        const tiNames = { CertSha1s: [], Sha1s: [], Sha256s: [], IPs: [], URLs: [] };
        for (let i = 1; i < lines.length; i++) {
            const row = lines[i].split(',');
            const type = (row[typeIdx] || '').trim();
            const value = (row[valueIdx] || '').trim();
            const name = nameIdx !== -1 ? (row[nameIdx] || '').trim() : '';
            if (!type || !value) continue;
            
            const lowerType = type.toLowerCase();
            if (lowerType === 'certificatethumbprint' || lowerType === 'certsha1' || lowerType === 'cert-sha1') {
                tiData.CertSha1s.push(value);
                tiNames.CertSha1s.push(name);
            } else if (lowerType === 'filesha1' || lowerType === 'sha1') {
                tiData.Sha1s.push(value);
                tiNames.Sha1s.push(name);
            } else if (lowerType === 'filesha256' || lowerType === 'sha256') {
                tiData.Sha256s.push(value);
                tiNames.Sha256s.push(name);
            } else if (lowerType === 'ipaddress' || lowerType === 'ip') {
                tiData.IPs.push(value);
                tiNames.IPs.push(name);
            } else if (lowerType === 'domainname' || lowerType === 'url') {
                tiData.URLs.push(value);
                tiNames.URLs.push(name);
            }
        }
        let anySent = false;
        const processingSummary = [];
        for (const [type, arr] of Object.entries(tiData)) {
            if (arr.length > 0) {
                anySent = true;
                let functionName = 'InvokeTi' + type.replace(/s$/, '');
                let paramName = type;
                // Special handling for certificate SHA1
                if (type === 'CertSha1s') {
                    functionName = 'InvokeTiCert';
                    paramName = 'Sha1s'; // Backend expects Sha1s parameter for certificates
                }
                // Special handling for file SHA1 and SHA256 - both use InvokeTiFile
                else if (type === 'Sha1s' || type === 'Sha256s') {
                    functionName = 'InvokeTiFile';
                    // paramName stays as 'Sha1s' or 'Sha256s'
                }
                processingSummary.push(`${type}: ${arr.length} items`);
                for (let i = 0; i < arr.length; i++) {
                    const payload = { TenantId: tenantId, Function: functionName };
                    payload[paramName] = [arr[i]];
                    const indicatorName = tiNames[type][i];
                    if (indicatorName) {
                        payload.IndicatorName = indicatorName; // Send as string, not array
                    }
                    try {
                        // Add timeout to handle Azure Function cold starts
                        const controller = new AbortController();
                        const timeoutId = setTimeout(() => controller.abort(), 30000); // 30 second timeout
                        await fetch(url, { 
                            method: 'POST', 
                            headers: { 'Content-Type': 'application/json' }, 
                            body: JSON.stringify(payload),
                            signal: controller.signal
                        });
                        clearTimeout(timeoutId);
                    } catch (error) {
                        console.error(`Error processing ${type}:`, error);
                    }
                }
            }
        }
        if (!anySent) {
            console.log('CSV Import: No valid entries found in CSV.');
        } else {
            console.log(`CSV Import complete. Processed: ${processingSummary.join(', ')}`);
        }
        loadAllThreatIntelligenceData();
    };
    reader.readAsText(file);
};

async function tiCsvExportBtnClick() {
    const tenantId = getTenantId();
    
    if (!tenantId) { 
        alert('Tenant ID is required.'); 
        return; 
    }
    
    try {
        console.log('CSV Export: Fetching indicators...');
        
        // Get the current indicators data
        const apiUrl = '/api/ti/indicators';
        const payload = { TenantId: tenantId, Function: 'GetIndicators' };
        
        const res = await fetch(apiUrl, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
        const result = await res.json();
        let indicators = result.value || result.machines || result || [];
        if (!Array.isArray(indicators) && indicators.value) indicators = indicators.value;
        
        if (!indicators || indicators.length === 0) {
            console.log('CSV Export: No indicators to export.');
            alert('No indicators to export.');
            return;
        }
        
        // Convert indicators to CSV format using Microsoft standard
        const headers = ['Indicator Type', 'Indicator Value'];
        const csvRows = [headers.join(',')];
        
        indicators.forEach(indicator => {
            // Skip webcategory indicators
            const indicatorType = (indicator.IndicatorType || '').toLowerCase();
            if (indicatorType === 'webcategory') {
                return;
            }
            
            // Map the IndicatorType to Microsoft's standard format
            let exportType = '';
            
            if (indicatorType.includes('cert') && indicatorType.includes('sha1')) {
                exportType = 'CertificateThumbprint';
            } else if (indicatorType.includes('sha1')) {
                exportType = 'FileSha1';
            } else if (indicatorType.includes('sha256')) {
                exportType = 'FileSha256';
            } else if (indicatorType.includes('ip')) {
                exportType = 'IpAddress';
            } else if (indicatorType.includes('url') || indicatorType.includes('domain')) {
                exportType = 'DomainName';
            } else {
                // Default to the original type if we can't map it
                exportType = indicatorType;
            }
            
            // Use simple CSV format without quotes (matching your test file)
            const row = [exportType, indicator.IndicatorValue || ''];
            csvRows.push(row.join(','));
        });
        
        const csvContent = csvRows.join('\n');
        
        // Create and download the file
        const blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' });
        const link = document.createElement('a');
        const downloadUrl = URL.createObjectURL(blob);
        link.setAttribute('href', downloadUrl);
        
        // Generate filename with timestamp
        const now = new Date();
        const timestamp = now.toISOString().slice(0, 19).replace(/[T:]/g, '-');
        link.setAttribute('download', `threat-indicators-${timestamp}.csv`);
        
        link.style.visibility = 'hidden';
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
        
        console.log(`CSV Export: Exported ${indicators.length} indicators successfully.`);
        
    } catch (error) {
        console.error('CSV Export error:', error);
        alert('Export failed. Please try again.');
    }
}

function renderDetectionsTable(detections) {
    const container = document.getElementById('detectionsTableContainer');
    container.innerHTML = '';
    if (!window.gridjs) return;
    if (window.detectionsGrid) window.detectionsGrid.destroy();
    
    const columns = [
        { 
            id: 'checkbox', 
            name: '', 
            width: '40px', 
            sort: false,
            formatter: (_, row) => {
                const detectionId = row.cells[1].data; // ID is in second column
                return gridjs.html(`<input type='checkbox' class='detection-checkbox' data-id='${detectionId}' />`);
            }
        },
        { id: 'id', name: 'Id' },
        { id: 'displayName', name: 'Title' },
        { id: 'createdBy', name: 'Created By' },
        { id: 'lastModifiedBy', name: 'Last Modified By' },
        { id: 'lastModifiedDateTime', name: 'Last Modified Time' },
        { id: 'period', name: 'Schedule' },
        { id: 'isEnabled', name: 'Active', formatter: cell => cell === true ? 'Yes' : cell === false ? 'No' : '' }
    ];
    
    const data = detections.map(d => [
        '', // Checkbox column placeholder
        d.id, 
        d.displayName, 
        d.createdBy, 
        d.lastModifiedBy, 
        d.lastModifiedDateTime, 
        d.schedule?.period || '',
        d.isEnabled
    ]);
    
    window.detectionsGrid = new gridjs.Grid({ 
        columns, 
        data, 
        search: true, 
        sort: true, 
        pagination: {
            limit: 25,
            summary: true
        }, 
        autoWidth: true, 
        width: '100%', 
        height: 'auto' 
    }).render(container);

    // Use event delegation on the container instead of individual checkbox listeners
    // Remove any existing event listeners first
    container.removeEventListener('change', handleDetectionCheckboxChange);
    container.addEventListener('change', handleDetectionCheckboxChange);

    // Initial state update after grid renders
    window.detectionsGrid.on('ready', () => {
        setTimeout(() => {
            updateDetectionButtonsState();
        }, 100);
    });

    // Update state after pagination changes
    container.addEventListener('click', (e) => {
        if (e.target.classList.contains('gridjs-page') || 
            e.target.closest('.gridjs-pagination')) {
            setTimeout(() => {
                updateDetectionButtonsState();
            }, 100);
        }
    });
}

// Event delegation handler for detection checkbox changes
function handleDetectionCheckboxChange(e) {
    if (e.target && e.target.classList.contains('detection-checkbox')) {
        console.log('Detection checkbox changed:', e.target.getAttribute('data-id'), 'checked:', e.target.checked);
        updateDetectionButtonsState();
    }
}

// Separate function to set up detection checkbox listeners
function setupDetectionCheckboxListeners() {
    console.log('Setting up detection checkbox listeners...');
    document.querySelectorAll('.detection-checkbox').forEach(cb => {
        // Remove existing listeners to prevent duplicates
        cb.removeEventListener('change', updateDetectionButtonsState);
        // Add new listener
        cb.addEventListener('change', updateDetectionButtonsState);
    });
    console.log(`Detection checkbox listeners set up for ${document.querySelectorAll('.detection-checkbox').length} checkboxes`);
}

function getSelectedDetections() {
    const checkedBoxes = document.querySelectorAll('.detection-checkbox:checked');
    return Array.from(checkedBoxes).map(cb => cb.getAttribute('data-id'));
}

function updateDetectionButtonsState() {
    const checked = document.querySelectorAll('.detection-checkbox:checked');
    const updateBtn = document.getElementById('updateSelectedDetectionBtn');
    const deleteBtn = document.getElementById('deleteSelectedDetectionBtn');
    
    console.log(`Detection buttons state update: ${checked.length} checkboxes selected`);
    
    if (updateBtn) {
        updateBtn.disabled = checked.length !== 1;
        updateBtn.textContent = checked.length === 1 ? 'Update Selected (1)' : 'Update Selected';
        console.log(`Update button: disabled=${updateBtn.disabled}, text="${updateBtn.textContent}"`);
    } else {
        console.log('Update button not found');
    }
    
    if (deleteBtn) {
        deleteBtn.disabled = checked.length === 0;
        deleteBtn.textContent = checked.length > 0 ? `Delete Selected (${checked.length})` : 'Delete Selected';
        console.log(`Delete button: disabled=${deleteBtn.disabled}, text="${deleteBtn.textContent}"`);
    } else {
        console.log('Delete button not found');
    }
}

// Sync detections function - calls MDECDManager to trigger sync
async function syncDetections() {
    const tenantId = getTenantId();
    if (!tenantId) {
        alert('Please select a tenant first.');
        return;
    }

    if (!confirm('Are you sure you want to sync detections? This will trigger a sync process in MDECDManager.')) {
        return;
    }

    console.log('Starting detection sync for tenant:', tenantId);
    
    try {
        window.showContentLoading('Syncing Detections...');
        
        const url = '/api/ti/sync';
        const payload = { 
            TenantId: tenantId,
            Function: 'Sync'  // Assuming the function parameter for sync
        };
        
        console.log('Calling TI sync API with payload:', payload);
        
        const response = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
        
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        
        const result = await response.json();
        console.log('Sync response:', result);
        
        if (result.error) {
            alert(`Error during sync: ${result.error}`);
        } else {
            alert('Detection sync initiated successfully!');
            // Optionally reload detection data after sync
            setTimeout(() => {
                loadAllThreatIntelligenceData();
            }, 2000);
        }
        
    } catch (error) {
        console.error('Error during sync:', error);
        if (error.name === 'AbortError') {
            alert('Sync request timed out. The sync may still be processing in the background.');
        } else {
            alert(`Error during sync: ${error.message}`);
        }
    } finally {
        window.hideContentLoading();
    }
}

// Tenant Management Functions (copied from index.js)

// Simplified event listeners for tenant dropdown only
function setupEventListeners() {
    console.log('Setting up event listeners...');
    
    // Tenant dropdown change event
    const tenantDropdown = document.getElementById('tenantDropdown');
    if (tenantDropdown) {
        console.log('Found tenant dropdown, adding change listener');
        tenantDropdown.addEventListener('change', function() {
            const selectedTenant = this.value;
            if (selectedTenant) {
                sessionStorage.setItem('TenantId', selectedTenant);
                console.log('Selected tenant:', selectedTenant);
                // Load all threat intelligence data systematically
                loadAllThreatIntelligenceData();
            } else {
                sessionStorage.removeItem('TenantId');
                // Clear device groups when no tenant is selected
                clearDeviceGroupsDropdown();
                // Clear tables
                const iocContainer = document.getElementById('iocTableContainer');
                const detectionsContainer = document.getElementById('detectionsTableContainer');
                if (iocContainer) iocContainer.innerHTML = '';
                if (detectionsContainer) detectionsContainer.innerHTML = '';
            }
        });
    } else {
        console.log('Tenant dropdown not found');
    }
}

// Simplified tenant loading for dropdown only
async function loadTenants() {
    try {
        console.log('Loading tenants from backend...');
        
        // Update platform loading progress
        if (typeof window.updatePlatformLoadingProgress === 'function') {
            window.updatePlatformLoadingProgress('Loading tenants for TI Manager...', 30);
        }
        
        // Add timeout to handle Azure Function cold starts
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 45000); // 45 second timeout
        
        const response = await fetch('/api/tenants', {
            signal: controller.signal
        });
        
        clearTimeout(timeoutId);
        
        if (!response.ok) {
            console.error('HTTP error response:', response.status, response.statusText);
            // Mark tenants as loaded even on error
            if (typeof window.markTenantsLoaded === 'function') {
                window.markTenantsLoaded();
            }
            return;
        }
        
        const data = await response.json();
        console.log('Tenant API response data:', data);
        
        // Handle both response formats for backward compatibility
        let tenants = [];
        if (data.Status === 'Success') {
            tenants = data.TenantIds || [];
            console.log(`Loaded ${data.Count || 0} tenants`);
        } else if (Array.isArray(data)) {
            tenants = data;
            console.log(`Loaded ${data.length} tenants`);
        } else {
            const errorMessage = data.Message || data.error || 'Unknown error occurred';
            console.error('Error loading tenants:', errorMessage);
            // Mark tenants as loaded even on error
            if (typeof window.markTenantsLoaded === 'function') {
                window.markTenantsLoaded();
            }
            return;
        }
        
        populateTenantDropdown(tenants);
        
        // Mark tenants as loaded for platform loading system
        if (typeof window.markTenantsLoaded === 'function') {
            window.markTenantsLoaded();
        }
        
    } catch (error) {
        console.error('Error fetching tenants:', error);
        // Mark tenants as loaded even on error
        if (typeof window.markTenantsLoaded === 'function') {
            window.markTenantsLoaded();
        }
    }
}

function populateTenantDropdown(tenants) {
    const tenantDropdown = document.getElementById('tenantDropdown');
    if (!tenantDropdown) {
        console.error('Tenant dropdown not found');
        return;
    }
    
    // Clear existing options
    tenantDropdown.innerHTML = '';
    
    // Add tenant options - Client Name first, then Tenant ID in parentheses'
    tenants.forEach(tenant => {
        const option = document.createElement('option');
        option.value = tenant.TenantId;
        option.textContent = `${tenant.ClientName} (${tenant.TenantId})`;
        tenantDropdown.appendChild(option);
    });
}

// --- Custom Detection Manager Button Handlers ---
// (Event listeners are now set up in DOMContentLoaded)

// --- Detection Editor Modal Logic (Form-Based) ---

function openDetectionEditorModal(mode, detectionId = '', jsonContent = '') {
    const modal = document.getElementById('detectionEditorModal');
    const title = document.getElementById('detectionEditorTitle');
    const saveBtn = document.getElementById('saveDetectionRuleBtn');
    const cancelBtn = document.getElementById('cancelDetectionEditorBtn');
    if (!modal || !title || !saveBtn || !cancelBtn) return;
    
    // Show modal first
    modal.style.display = 'flex';
    title.textContent = mode === 'add' ? 'Add Custom Detection Rule' : 'Update Custom Detection Rule';
    
    // Initialize or clear form fields
    initializeDetectionForm();
    
    // Parse the detection data early to extract query text
    let detectionData = null;
    let queryTextToSet = '';
    if (jsonContent) {
        try {
            detectionData = JSON.parse(jsonContent);
            // Extract query text now for later use
            if (detectionData.query) {
                queryTextToSet = detectionData.query;
            } else if (detectionData.Query) {
                queryTextToSet = detectionData.Query;
            } else if (detectionData.queryCondition && detectionData.queryCondition.queryText) {
                queryTextToSet = detectionData.queryCondition.queryText;
            } else if (detectionData.KQL) {
                queryTextToSet = detectionData.KQL;
            } else if (detectionData.kql) {
                queryTextToSet = detectionData.kql;
            } else if (detectionData.QueryText) {
                queryTextToSet = detectionData.QueryText;
            }
            console.log('Extracted queryTextToSet:', queryTextToSet);
        } catch (e) {
            console.warn('Failed to parse existing detection JSON:', e);
        }
    }
    
    // Initialize CodeMirror after modal is visible
    setTimeout(() => {
        console.log('Initializing CodeMirror...');
        const editor = initCodeMirrorKqlEditor();
        if (editor) {
            console.log('CodeMirror initialized successfully');
            
            // Set query text if we have it
            if (queryTextToSet) {
                console.log('Setting query text in CodeMirror:', queryTextToSet);
                editor.setValue(queryTextToSet);
            } else {
                // Clear editor and focus
                editor.setValue('');
            }
            editor.focus();
            
            // Add change listener for form validation
            editor.on('change', function() {
                updateFormValidationStatus();
            });
        } else {
            console.error('Failed to initialize CodeMirror');
        }
        
        // Populate form fields after CodeMirror is ready
        if (detectionData) {
            console.log('Populating form with detection data...');
            populateDetectionForm(detectionData);
        }
    }, 100);
    
    // Set up form validation
    setupFormValidation();
    
    // Set up response action checkboxes
    setupResponseActionHandlers();
    
    // Save handler
    saveBtn.onclick = async function() {
        if (!validateDetectionForm()) {
            return;
        }
        
        const tenantId = getTenantId();
        const detectionData = collectDetectionFormData();
        
        console.log('Detection data before JSON.stringify:', detectionData);
        console.log('KQL query in detection data:', detectionData.queryCondition?.QueryText);
        
        // Test JSON serialization before sending to backend
        let jsonContent;
        try {
            jsonContent = JSON.stringify(detectionData, null, 2);
            console.log('JSON serialization successful');
        } catch (jsonError) {
            console.error('Failed to serialize detection data to JSON:', jsonError);
            showFormError(`Failed to serialize detection rule data: ${jsonError.message}`);
            return;
        }
        
        const url = '/api/ti/detections';
        const payload = { 
            TenantId: tenantId, 
            Function: mode === 'add' ? 'InstallDetectionRule' : 'UpdateDetectionRule', 
            jsonContent: jsonContent
        };
        if (mode === 'update' && detectionId) {
            payload.RuleId = detectionId;
        }
        
        console.log('Final payload being sent to backend:', JSON.stringify(payload, null, 2));
        console.log('Specifically, the jsonContent field:', payload.jsonContent);
        
        // Parse the jsonContent back to verify KQL query escaping is correct
        try {
            const parsedContent = JSON.parse(payload.jsonContent);
            console.log('Parsed jsonContent KQL query:', parsedContent.queryCondition?.QueryText);
            console.log('KQL query successfully roundtrip through JSON serialization');
        } catch (parseError) {
            console.error('Failed to parse jsonContent back - JSON escaping issue:', parseError);
            showFormError(`JSON serialization issue detected: ${parseError.message}`);
            return;
        }
        
        try {
            const response = await fetch(url, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload)
            });
            
            if (!response.ok) {
                throw new Error(`HTTP ${response.status}: ${response.statusText}`);
            }
            
            closeDetectionEditorModal();
            loadAllThreatIntelligenceData();
        } catch (err) {
            showFormError(`Error saving detection rule: ${err.message}`);
            console.error(err);
        }
    };
    
    // Cancel handler
    cancelBtn.onclick = function() {
        closeDetectionEditorModal();
    };
    
    // Close (X) handler
    const closeX = modal.querySelector('.close-detection-editor');
    if (closeX) {
        closeX.onclick = function() {
            closeDetectionEditorModal();
        };
    }
}

function initializeDetectionForm() {
    // Clear all form fields - safely handle missing elements
    const setValueSafely = (id, value) => {
        const element = document.getElementById(id);
        if (element) element.value = value;
    };
    
    const setCheckedSafely = (id, checked) => {
        const element = document.getElementById(id);
        if (element) element.checked = checked;
    };
    
    const setDisabledSafely = (id, disabled) => {
        const element = document.getElementById(id);
        if (element) element.disabled = disabled;
    };
    
    // Clear basic form fields
    setValueSafely('detectionDisplayName', '');
    setValueSafely('detectionDescription', '');
    setValueSafely('detectionEnabled', 'true');
    setValueSafely('detectionSeverity', '');
    setValueSafely('detectionCategory', '');
    setValueSafely('detectionPeriod', '12H');
    
    // Clear response action checkboxes
    setCheckedSafely('responseActionIsolate', false);
    setCheckedSafely('responseActionInvestigation', false);
    setCheckedSafely('responseActionRestrict', false);
    setDisabledSafely('responseActionIsolateType', true);
    setDisabledSafely('responseActionInvestigationComment', true);
    setDisabledSafely('responseActionRestrictComment', true);
    
    // Clear form validation status
    updateFormValidationStatus();
}

function populateDetectionForm(detectionData) {
    // Helper function for safe value setting
    const setValueSafely = (id, value) => {
        const element = document.getElementById(id);
        if (element) element.value = value;
    };
    
    // Populate basic fields with robust mapping
    const displayName = detectionData.displayName || detectionData.DisplayName || detectionData.RuleTitle || detectionData.Title || detectionData.RuleName || '';
    document.getElementById('detectionDisplayName').value = displayName;

    const description = detectionData.description || detectionData.Description || detectionData.AlertDescription || detectionData.alertDescription || '';
    document.getElementById('detectionDescription').value = description;

    if (detectionData.isEnabled !== undefined) {
        document.getElementById('detectionEnabled').value = detectionData.isEnabled.toString();
    } else if (detectionData.Enabled !== undefined) {
        document.getElementById('detectionEnabled').value = detectionData.Enabled.toString();
    }

    // Query field (KQL) - handled separately in openDetectionEditorModal
    // The query is extracted and set directly in CodeMirror after it's initialized
    console.log('Skipping query setting in populateDetectionForm - handled in modal opener');

    // Alert template and related fields
    let alertTemplate = detectionData.detectionAction?.alertTemplate || detectionData.AlertTemplate || detectionData.alertTemplate || {};
    // Fallback: sometimes alert fields are at the root
    if (!alertTemplate.title && (detectionData.AlertTitle || detectionData.alertTitle)) {
        alertTemplate.title = detectionData.AlertTitle || detectionData.alertTitle;
    }
    if (!alertTemplate.description && (detectionData.AlertDescription || detectionData.alertDescription)) {
        alertTemplate.description = detectionData.AlertDescription || detectionData.alertDescription;
    }
    if (!alertTemplate.severity && (detectionData.Severity || detectionData.severity)) {
        alertTemplate.severity = (detectionData.Severity || detectionData.severity).toLowerCase();
    }
    if (!alertTemplate.category && (detectionData.Category || detectionData.category)) {
        alertTemplate.category = detectionData.Category || detectionData.category;
    }
    if (!alertTemplate.recommendedActions && (detectionData.RecommendedActions || detectionData.recommendedActions)) {
        alertTemplate.recommendedActions = detectionData.RecommendedActions || detectionData.recommendedActions;
    }
    if (!alertTemplate.mitreTechniques && (detectionData.MitreTechniques || detectionData.mitreTechniques)) {
        alertTemplate.mitreTechniques = Array.isArray(detectionData.MitreTechniques) ? detectionData.MitreTechniques : (detectionData.mitreTechniques ? detectionData.mitreTechniques.split(',') : []);
    }

    if (alertTemplate.severity) {
        document.getElementById('detectionSeverity').value = alertTemplate.severity.toLowerCase();
    }
    if (alertTemplate.category) {
        document.getElementById('detectionCategory').value = alertTemplate.category;
    }
    if (alertTemplate.title) {
        setValueSafely('detectionDisplayName', alertTemplate.title);
    }
    if (alertTemplate.description) {
        setValueSafely('detectionDescription', alertTemplate.description);
    }
    // Note: detectionRecommendedActions and detectionMitreTechniques fields have been removed from the form

    // Schedule/Period - check multiple possible locations and normalize format
    let period = '';
    if (detectionData.schedule && detectionData.schedule.period) {
        period = detectionData.schedule.period;
    } else if (detectionData.Period) {
        period = detectionData.Period;
    } else if (detectionData.period) {
        period = detectionData.period;
    } else if (detectionData.runFrequency) {
        period = detectionData.runFrequency;
    } else if (detectionData.RunFrequency) {
        period = detectionData.RunFrequency;
    }
    
    // Normalize period format to match the dropdown options
    if (period) {
        // Convert backend format to form format
        if (period === "0") {
            period = "0H"; // Backend sends "0", form expects "0H" for Near Realtime
        } else if (period === "1" || period === 1) {
            period = "1H"; // Every Hour
        } else if (period === "3" || period === 3) {
            period = "3H"; // Every 3 Hours
        } else if (period === "12" || period === 12) {
            period = "12H"; // Every 12 Hours
        } else if (period === "24" || period === 24) {
            period = "24H"; // Daily
        }
        // If it already has 'H' suffix, keep as is
        else if (typeof period === 'string' && period.endsWith('H')) {
            // Already in correct format
        }
        // Handle other common formats
        else if (period.toLowerCase() === 'realtime' || period.toLowerCase() === 'near realtime') {
            period = "0H";
        } else if (period.toLowerCase() === 'hourly') {
            period = "1H";
        } else if (period.toLowerCase() === 'daily') {
            period = "24H";
        }
        
        console.log('Setting period to:', period);
        document.getElementById('detectionPeriod').value = period;
    }

    // Response actions (optional, add more mappings as needed)
    // ...existing code...

    updateFormValidationStatus();
}

// --- Form Validation and Submission ---

function setupFormValidation() {
    // Add event listeners to required fields for real-time validation
    const requiredFields = [
        'detectionDisplayName',
        'detectionDescription',
        'detectionSeverity', 
        'detectionCategory'
        // Note: Alert Title and Alert Description were unified with Display Name and Description
    ];
    
    requiredFields.forEach(fieldId => {
        const el = document.getElementById(fieldId);
        if (el) {
            el.addEventListener('input', updateFormValidationStatus);
        }
    });
}

function setupResponseActionHandlers() {
    // Isolate device checkbox
    const isolateCheckbox = document.getElementById('responseActionIsolate');
    const isolateType = document.getElementById('responseActionIsolateType');
    isolateCheckbox.addEventListener('change', function() {
        isolateType.disabled = !this.checked;
    });
    
    // Investigation package checkbox
    const investigationCheckbox = document.getElementById('responseActionInvestigation');
    const investigationComment = document.getElementById('responseActionInvestigationComment');
    investigationCheckbox.addEventListener('change', function() {
        investigationComment.disabled = !this.checked;
    });
    
    // Restrict app execution checkbox
    const restrictCheckbox = document.getElementById('responseActionRestrict');
    const restrictComment = document.getElementById('responseActionRestrictComment');
    restrictCheckbox.addEventListener('change', function() {
        restrictComment.disabled = !this.checked;
    });
}

function updateFormValidationStatus() {
    const statusElement = document.getElementById('formValidationStatus');
    const saveBtn = document.getElementById('saveDetectionRuleBtn');
    
    if (!statusElement || !saveBtn) {
        console.error('Required form elements missing');
        return;
    }
    
    const isValid = validateDetectionForm(false); // Don't show errors, just check
    
    if (isValid) {
        statusElement.textContent = '✓ Form is valid and ready to save';
        statusElement.style.color = '#7fff7f';
        saveBtn.disabled = false;
        saveBtn.style.opacity = '1';
    } else {
        statusElement.textContent = 'Fill in required fields (*) to enable save';
        statusElement.style.color = '#aaa';
        saveBtn.disabled = true;
        saveBtn.style.opacity = '0.6';
    }
}

function validateDetectionForm(showErrors = true) {
    const errors = [];
    
    // Helper function to safely get element value
    const getValueSafely = (id) => {
        const element = document.getElementById(id);
        return element ? element.value.trim() : '';
    };
    
    // Required fields validation - only check fields that actually exist
    const displayName = getValueSafely('detectionDisplayName');
    if (!displayName) {
        errors.push('Display Name is required.');
    }
    
    const description = getValueSafely('detectionDescription');
    if (!description) {
        errors.push('Description is required.');
    }
    
    const severity = getValueSafely('detectionSeverity');
    if (!severity) {
        errors.push('Severity is required.');
    }
    
    const category = getValueSafely('detectionCategory');
    if (!category) {
        errors.push('Category is required.');
    }
    
    // Note: Alert Title and Alert Description fields were unified with Display Name and Description
    // So we don't need to check separate detectionAlertTitle and detectionAlertDescription fields
    
    // KQL query validation - DISABLED for now
    // const queryText = window.codeMirrorKqlEditor ? window.codeMirrorKqlEditor.getValue().trim() : '';
    // if (!queryText) {
    //     errors.push('Detection Query (KQL) is required.');
    // }
    
    if (showErrors && errors.length > 0) {
        showFormError(errors.join(' '));
    }
    return errors.length === 0;
}

function collectDetectionFormData() {
    // Helper function to safely get element value
    const getValueSafely = (id, defaultValue = '') => {
        const element = document.getElementById(id);
        return element ? element.value.trim() : defaultValue;
    };
    
    // Helper function to safely get checkbox state
    const getCheckedSafely = (id) => {
        const element = document.getElementById(id);
        return element ? element.checked : false;
    };
    
    const displayName = getValueSafely('detectionDisplayName');
    const description = getValueSafely('detectionDescription');
    const isEnabled = getValueSafely('detectionEnabled') === 'true';
    const severity = getValueSafely('detectionSeverity');
    const category = getValueSafely('detectionCategory');
    const rawPeriod = getValueSafely('detectionPeriod', '12H');
    
    // Convert period format for backend - backend expects "0" for Near Realtime, not "0H"
    let period = rawPeriod;
    if (rawPeriod === '0H') {
        period = '0'; // Backend expects just "0" for Near Realtime
    }
    // For other values (1H, 3H, 12H, 24H), keep as-is since backend expects the "H" suffix
    
    console.log('Period conversion:', rawPeriod, '->', period);
    // Use the unified fields for alert title and description
    const alertTitle = displayName; // Use display name as alert title
    const alertDescription = description; // Use description as alert description
    
    // Set default values to match PowerShell structure exactly
    const recommendedActions = ''; // Empty string as default
    const mitreTechniques = []; // Empty array as default
    const identifier = 'deviceName'; // Default identifier value
    
    const queryText = window.codeMirrorKqlEditor ? window.codeMirrorKqlEditor.getValue().trim() : '';
    
    // Validate and prepare KQL query text for JSON serialization
    const validatedQueryText = validateAndPrepareKqlQuery(queryText);
    console.log('Validated KQL query ready for JSON serialization');
    
    // Collect response actions
    const responseActions = [];
    let actionOrder = 1;
    
    if (getCheckedSafely('responseActionIsolate')) {
        const isolationType = getValueSafely('responseActionIsolateType', 'full');
        responseActions.push({
            "@odata.type": "#microsoft.graph.security.isolateDeviceResponseAction",
            "identifier": "deviceId",
            "isolationType": isolationType
        });
    }
    
    if (getCheckedSafely('responseActionInvestigation')) {
        // Add both mark user as compromised and disable user response actions
        responseActions.push({
            "@odata.type": "#microsoft.graph.security.markUserAsCompromisedResponseAction",
            "identifier": "initiatingProcessAccountObjectId"
        });
        responseActions.push({
            "@odata.type": "#microsoft.graph.security.disableUserResponseAction",
            "identifier": "initiatingProcessAccountSid"
        });
    }
    
    if (getCheckedSafely('responseActionRestrict')) {
        const comment = getValueSafely('responseActionRestrictComment', 'App execution restricted by detection rule');
        responseActions.push({
            "@odata.type": "#microsoft.graph.security.restrictAppExecutionResponseAction",
            "identifier": "deviceId",
            "comment": comment || "App execution restricted by detection rule"
        });
    }
    
    // Build detection rule object to match the PowerShell API body exactly
    const detectionRule = {
        "displayName": displayName,
        "isEnabled": isEnabled,
        "queryCondition": {
            "queryText": validatedQueryText  // Use lowercase 'queryText' to match PowerShell
        },
        "schedule": {
            "period": period
        },
        "detectionAction": {
            "alertTemplate": {
                "title": alertTitle,
                "description": alertDescription,
                "severity": severity.toLowerCase(), // Ensure lowercase to match PowerShell
                "category": category,
                "recommendedActions": recommendedActions,
                "mitreTechniques": mitreTechniques,
                "impactedAssets": [
                    {
                        "@odata.type": "#microsoft.graph.security.impactedDeviceAsset",
                        "identifier": identifier
                    }
                ]
            },
            "organizationalScope": null, // Set to null to match PowerShell structure
            "responseActions": responseActions // This will be empty array by default
        }
    };
    
    console.log('Detection rule payload:', JSON.stringify(detectionRule, null, 2));
    return detectionRule;
}

function showFormError(message) {
    // Create or update error display
    let errorDisplay = document.getElementById('formErrorDisplay');
    if (!errorDisplay) {
        errorDisplay = document.createElement('div');
        errorDisplay.id = 'formErrorDisplay';
        errorDisplay.style.cssText = `
            margin-top: 10px; 
            padding: 10px; 
            background: #2d1a1a; 
            border: 1px solid #ff4444; 
            border-radius: 4px; 
            color: #ff8888; 
            font-size: 0.9em;
            white-space: pre-line;
        `;
        
        const validationStatus = document.getElementById('formValidationStatus');
        if (validationStatus && validationStatus.parentNode) {
            validationStatus.parentNode.insertBefore(errorDisplay, validationStatus.nextSibling);
        }
    }
    
    errorDisplay.textContent = message;
    errorDisplay.style.display = 'block';
    
    // Auto-hide after 10 seconds
    setTimeout(() => {
        if (errorDisplay) {
            errorDisplay.style.display = 'none';
        }
    }, 10000);
}

function clearFormError() {
    const errorDisplay = document.getElementById('formErrorDisplay');
    if (errorDisplay) {
        errorDisplay.style.display = 'none';
    }
}

// Initialize JSON editor enhancements
function initializeJsonEditor(editor) {
    // Auto-indent and smart tabbing
    editor.addEventListener('keydown', function(e) {
        if (e.key === 'Tab') {
            e.preventDefault();
            const start = this.selectionStart;
            const end = this.selectionEnd;
            
            if (e.shiftKey) {
                // Shift+Tab: Remove indentation
                const lines = this.value.substring(0, start).split('\n');
                const currentLine = lines[lines.length - 1];
                if (currentLine.startsWith('  ')) {
                    const newStart = start - 2;
                    this.value = this.value.substring(0, start - 2) + this.value.substring(start);
                    this.selectionStart = this.selectionEnd = newStart;
                }
            } else {
                // Tab: Add indentation
                this.value = this.value.substring(0, start) + '  ' + this.value.substring(end);
                this.selectionStart = this.selectionEnd = start + 2;
            }
            updateLineNumbers(this);
        } else if (e.key === 'Enter') {
            // Auto-indent on new line
            const start = this.selectionStart;
            const textBeforeCursor = this.value.substring(0, start);
            const lines = textBeforeCursor.split('\n');
            const currentLine = lines[lines.length - 1];
            const indent = currentLine.match(/^(\s*)/)[1];
            
            // Add extra indent if line ends with { or [
            const extraIndent = /[{\[]$/.test(currentLine.trim()) ? '  ' : '';
            
            setTimeout(() => {
                const newPos = this.selectionStart;
                this.value = this.value.substring(0, newPos) + indent + extraIndent + this.value.substring(newPos);
                this.selectionStart = this.selectionEnd = newPos + indent.length + extraIndent.length;
                updateLineNumbers(this);
            }, 0);
        }
    });
    
    // Update line numbers and validation on input
    editor.addEventListener('input', function() {
        updateLineNumbers(this);
        updateCharacterCount(this);
        validateJsonContent(this);
    });
    
    // Sync scroll between line numbers and editor
    editor.addEventListener('scroll', function() {
        const lineNumbers = document.getElementById('lineNumbers');
        if (lineNumbers) {
            lineNumbers.scrollTop = this.scrollTop;
        }
    });
}

// Update line numbers
function updateLineNumbers(editor) {
    const lineNumbers = document.getElementById('lineNumbers');
    if (!lineNumbers) return;
    
    const lines = editor.value.split('\n');
    const lineNumbersText = lines.map((_, index) => index + 1).join('\n');
    lineNumbers.textContent = lineNumbersText;
}

// Update character count
function updateCharacterCount(editor) {
    const charCount = document.getElementById('jsonCharCount');
    if (!charCount) return;
    
    const count = editor.value.length;
    charCount.textContent = `${count.toLocaleString()} characters`;
}

// Validate JSON content and show status
function validateJsonContent(editor) {
    const status = document.getElementById('jsonValidationStatus');
    if (!status) return;
    
    try {
        if (editor.value.trim() === '') {
            status.textContent = '';
            status.style.background = '';
            clearJsonError();
            return;
        }
        
        JSON.parse(editor.value);
        status.textContent = '✓ Valid JSON';
        status.style.background = '#1a4a1a';
        status.style.color = '#7fff7f';
        clearJsonError();
    } catch (e) {
        status.textContent = '✗ Invalid JSON';
        status.style.background = '#4a1a1a';
        status.style.color = '#ff8888';
    }
}

// Set up JSON editor toolbar functionality
function setupJsonEditorToolbar(editor) {
    // Format JSON button
    const formatBtn = document.getElementById('formatJsonBtn');
    if (formatBtn) {
        formatBtn.onclick = function() {
            try {
                const parsed = JSON.parse(editor.value);
                editor.value = JSON.stringify(parsed, null, 2);
                updateLineNumbers(editor);
                updateCharacterCount(editor);
                validateJsonContent(editor);
            } catch (e) {
                showJsonError(`Cannot format invalid JSON: ${e.message}`);
            }
        };
    }
    
    // Validate JSON button
    const validateBtn = document.getElementById('validateJsonBtn');
    if (validateBtn) {
        validateBtn.onclick = function() {
            try {
                const parsed = JSON.parse(editor.value);
                
                // Perform additional validation for custom detection rules
                const errors = [];
                
                // Check required top-level fields
                if (!parsed.DisplayName || parsed.DisplayName.trim() === '') {
                    errors.push('Missing or empty "DisplayName" field');
                }
                
                if (!parsed.QueryCondition || !parsed.QueryCondition.QueryText || parsed.QueryCondition.QueryText.trim() === '') {
                    errors.push('Missing "QueryCondition.QueryText" field (KQL query)');
                }
                
                // Check DetectionAction structure
                if (parsed.DetectionAction) {
                    if (!parsed.DetectionAction.AlertTemplate) {
                        errors.push('DetectionAction must contain "AlertTemplate"');
                    } else {
                        const alertTemplate = parsed.DetectionAction.AlertTemplate;
                        if (!alertTemplate.Title || alertTemplate.Title.trim() === '') {
                            errors.push('AlertTemplate missing "Title" field');
                        }
                        if (!alertTemplate.Severity || alertTemplate.Severity.trim() === '') {
                            errors.push('AlertTemplate missing "Severity" field');
                        }
                        if (alertTemplate.Severity && !['low', 'medium', 'high', 'informational'].includes(alertTemplate.Severity.toLowerCase())) {
                            errors.push('AlertTemplate "Severity" must be: low, medium, high, or informational');
                        }
                    }
                }
                
                // Check Schedule structure
                if (parsed.Schedule && parsed.Schedule.Period !== undefined) {
                    const period = parsed.Schedule.Period;
                    if (typeof period !== 'string' && typeof period !== 'number') {
                        errors.push('Schedule "Period" must be a string or number');
                    }
                }
                
                if (errors.length > 0) {
                    showJsonError(`Validation errors:\n• ${errors.join('\n• ')}`);
                } else {
                    showJsonSuccess('✓ Detection rule JSON is valid and ready to save!');
                }
            } catch (e) {
                showJsonError(`JSON syntax error: ${e.message}`);
            }
        };
    }
    
    // Minify JSON button
    const minifyBtn = document.getElementById('minifyJsonBtn');
    if (minifyBtn) {
        minifyBtn.onclick = function() {
            try {
                const parsed = JSON.parse(editor.value);
                editor.value = JSON.stringify(parsed);
                updateLineNumbers(editor);
                updateCharacterCount(editor);
                validateJsonContent(editor);
            } catch (e) {
                showJsonError(`Cannot minify invalid JSON: ${e.message}`);
            }
        };
    }
    
    // Clear JSON button
    const clearBtn = document.getElementById('clearJsonBtn');
    if (clearBtn) {
        clearBtn.onclick = function() {
            if (confirm('Are you sure you want to clear the JSON content?')) {
                editor.value = '';
                updateLineNumbers(editor);
                updateCharacterCount(editor);
                validateJsonContent(editor);
                clearJsonError();
            }
        };
    }
}

// Show JSON error message
function showJsonError(message) {
    const errorDisplay = document.getElementById('jsonErrorDisplay');
    if (errorDisplay) {
        errorDisplay.textContent = message;
        errorDisplay.style.display = 'block';
        errorDisplay.style.background = '#2d1a1a';
        errorDisplay.style.borderColor = '#ff4444';
        errorDisplay.style.color = '#ff8888';
    }
}

// Show JSON success message
function showJsonSuccess(message) {
    const errorDisplay = document.getElementById('jsonErrorDisplay');
    if (errorDisplay) {
        errorDisplay.textContent = message;
        errorDisplay.style.display = 'block';
        errorDisplay.style.background = '#1a2d1a';
        errorDisplay.style.borderColor = '#44ff44';
        errorDisplay.style.color = '#88ff88';
        
        // Auto-hide success message after 3 seconds
        setTimeout(() => {
            clearJsonError();
        }, 3000);
    }
}

// Clear JSON error/success message
function clearJsonError() {
    const errorDisplay = document.getElementById('jsonErrorDisplay');
    if (errorDisplay) {
        errorDisplay.style.display = 'none';
    }
}

// --- Detection Library Modal Logic ---
// (Event listeners are now set up in DOMContentLoaded)

// --- Device Groups Dropdown Logic ---
function clearDeviceGroupsDropdown() {
    const dropdown = document.getElementById('tiDeviceGroups');
    if (!dropdown) return;
    dropdown.innerHTML = '<option value="">Select a tenant first</option>';
    dropdown.disabled = true;
}

// Call on page load and on tenant change

// Debug function to test API connectivity
async function testApiConnectivity() {
    try {
        console.log('Testing basic API connectivity...');
        const response = await fetch('/api/test');
        const data = await response.json();
        console.log('API test result:', data);
        return data;
    } catch (error) {
        console.error('API test failed:', error);
        return null;
    }
}

// Call this function from browser console to test: testApiConnectivity()
window.testApiConnectivity = testApiConnectivity;

// Debug function to test device groups API with specific tenant
async function testDeviceGroupsApi(tenantId) {
    if (!tenantId) {
        tenantId = getTenantId();
    }
    
    if (!tenantId) {
        console.error('No tenant ID provided for device groups test');
        return null;
    }
    
    try {
        console.log(`Testing device groups API with tenant: ${tenantId}`);
        const encodedTenantId = encodeURIComponent(tenantId.trim());
        const apiUrl = `/api/device-groups/${encodedTenantId}`;
        console.log('Testing URL:', apiUrl);
        
        const response = await fetch(apiUrl);
        console.log('Response status:', response.status, response.statusText);
        console.log('Response headers:', [...response.headers.entries()]);
        
        const data = await response.json();
        console.log('Device groups test result:', data);
        return data;
    } catch (error) {
        console.error('Device groups test failed:', error);
        return null;
    }
}

// Call this function from browser console to test: testDeviceGroupsApi('your-tenant-id')
window.testDeviceGroupsApi = testDeviceGroupsApi;

// Test function to manually populate device groups for debugging
function testDeviceGroupsPopulation() {
    console.log('Testing device groups population...');
    const testGroups = ["UnassignedGroup", "soctraining"];
    populateDeviceGroupsDropdown(testGroups);
    console.log('Test device groups populated');
}

// Make it available globally for console testing
window.testDeviceGroupsPopulation = testDeviceGroupsPopulation;

// Debug function to test what device groups are actually selected
function debugDeviceGroups() {
    const deviceGroupsInput = document.getElementById('tiDeviceGroups');
    if (!deviceGroupsInput) {
        console.log('Device groups dropdown not found');
        return;
    }
    
    console.log('=== Device Groups Debug ===');
    console.log('Dropdown element:', deviceGroupsInput);
    console.log('Selected index:', deviceGroupsInput.selectedIndex);
    console.log('All options:', Array.from(deviceGroupsInput.options).map(opt => ({ value: opt.value, text: opt.textContent, selected: opt.selected })));
    console.log('Selected options:', Array.from(deviceGroupsInput.selectedOptions).map(opt => ({ value: opt.value, text: opt.textContent })));
    
    const deviceGroups = Array.from(deviceGroupsInput.selectedOptions).map(opt => opt.value).filter(Boolean);
    console.log('Final device groups array:', deviceGroups);
    console.log('Device groups types:', deviceGroups.map(dg => typeof dg));
    console.log('========================');
    
    return deviceGroups;
}

// Make it available globally for testing
window.debugDeviceGroups = debugDeviceGroups;

// Debug function to test detection checkbox functionality
function debugDetectionCheckboxes() {
    console.log('=== Detection Checkboxes Debug ===');
    const allCheckboxes = document.querySelectorAll('.detection-checkbox');
    const checkedCheckboxes = document.querySelectorAll('.detection-checkbox:checked');
    
    console.log(`Total checkboxes: ${allCheckboxes.length}`);
    console.log(`Checked checkboxes: ${checkedCheckboxes.length}`);
    
    allCheckboxes.forEach((cb, index) => {
        console.log(`Checkbox ${index}: id="${cb.getAttribute('data-id')}", checked=${cb.checked}`);
    });
    
    const updateBtn = document.getElementById('updateSelectedDetectionBtn');
    const deleteBtn = document.getElementById('deleteSelectedDetectionBtn');
    
    console.log(`Update button: exists=${!!updateBtn}, disabled=${updateBtn?.disabled}`);
    console.log(`Delete button: exists=${!!deleteBtn}, disabled=${deleteBtn?.disabled}`);
    
    console.log('Calling updateDetectionButtonsState...');
    updateDetectionButtonsState();
    console.log('=== End Debug ===');
}

// Make it available globally for testing
window.debugDetectionCheckboxes = debugDetectionCheckboxes;

// Close detection editor modal and clean up
function closeDetectionEditorModal() {
    const modal = document.getElementById('detectionEditorModal');
    if (modal) {
        modal.style.display = 'none';
    }
    
    // Clear CodeMirror editor
    if (window.codeMirrorKqlEditor && typeof window.codeMirrorKqlEditor.setValue === 'function') {
        try {
            window.codeMirrorKqlEditor.setValue('');
        } catch (error) {
            console.warn('Error clearing CodeMirror editor:', error);
        }
    }
    
    // Clear form fields
    clearDetectionForm();
}

// Clear detection form fields
function clearDetectionForm() {
    // Clear all form fields - safely handle missing elements
    const setValueSafely = (id, value) => {
        const element = document.getElementById(id);
        if (element) element.value = value;
    };
    
    const setCheckedSafely = (id, checked) => {
        const element = document.getElementById(id);
        if (element) element.checked = checked;
    };
    
    const setDisabledSafely = (id, disabled) => {
        const element = document.getElementById(id);
        if (element) element.disabled = disabled;
    };
    
    // Clear basic form fields
    setValueSafely('detectionDisplayName', '');
    setValueSafely('detectionDescription', '');
    setValueSafely('detectionEnabled', 'true');
    setValueSafely('detectionSeverity', '');
    setValueSafely('detectionCategory', '');
    setValueSafely('detectionPeriod', '12H');
    
    // Clear response action checkboxes
    setCheckedSafely('responseActionIsolate', false);
    setCheckedSafely('responseActionInvestigation', false);
    setCheckedSafely('responseActionRestrict', false);
    setDisabledSafely('responseActionIsolateType', true);
    setDisabledSafely('responseActionInvestigationComment', true);
    setDisabledSafely('responseActionRestrictComment', true);
    
    // Clear form validation status
    updateFormValidationStatus();
}

// Helper function to validate and prepare KQL query text for JSON serialization
function validateAndPrepareKqlQuery(queryText) {
    if (!queryText || typeof queryText !== 'string') {
        return '';
    }
    
    // Log the original query for debugging
    console.log('Original KQL query length:', queryText.length);
    console.log('Original KQL query preview:', queryText.substring(0, 200) + (queryText.length > 200 ? '...' : ''));
    
    // Check for potentially problematic characters
    const problematicChars = {
        'unescapedQuotes': /(?<!\\)"/g,
        'controlChars': /[\x00-\x1F\x7F]/g,
        'invalidUnicode': /[\uFFFE\uFFFF]/g
    };
    
    let warnings = [];
    for (const [issue, regex] of Object.entries(problematicChars)) {
        const matches = queryText.match(regex);
        if (matches) {
            warnings.push(`${issue}: ${matches.length} occurrences`);
        }
    }
    
    if (warnings.length > 0) {
        console.warn('Potential KQL query issues detected:', warnings);
    }
    
    // Return the original query text - JSON.stringify will handle escaping
    // We're just validating and logging here
    return queryText;
}

// =================
// KQL AI ANALYSIS FUNCTIONS
// =================

// Global variables for KQL analysis
let currentKqlAnalysisData = null;

// Function to analyze KQL query with AI
async function analyzeKqlQuery() {
    console.log('=== analyzeKqlQuery called ===');
    
    // Clear any existing analysis data first
    currentKqlAnalysisData = null;
    console.log('Cleared existing analysis data');
    
    // Get KQL query from CodeMirror editor
    let kqlQuery = '';
    if (window.codeMirrorKqlEditor && typeof window.codeMirrorKqlEditor.getValue === 'function') {
        kqlQuery = window.codeMirrorKqlEditor.getValue().trim();
    } else {
        console.error('CodeMirror KQL editor not available');
        alert('KQL editor not available. Please try again.');
        return;
    }
    
    if (!kqlQuery) {
        alert('Please enter a KQL query to analyze.');
        return;
    }
    
    console.log('Analyzing KQL query:', kqlQuery.substring(0, 100) + '...');
    
    // Show KQL analysis modal
    console.log('About to call showKqlAnalysisModal()...');
    try {
        showKqlAnalysisModal();
        console.log('showKqlAnalysisModal() call completed successfully');
    } catch (modalError) {
        console.error('Error calling showKqlAnalysisModal():', modalError);
    }
    
    try {
        // Use Flask API for KQL analysis
        const chatUrl = '/api/ti/analyze';
        
        // Prepare payload for the Flask API
        const chatPayload = {
            query: kqlQuery
        };

        console.log('Calling TI analyze API for KQL analysis...');
        const chatResponse = await fetch(chatUrl, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify(chatPayload)
        });

        if (!chatResponse.ok) {
            throw new Error(`KQL analysis failed: ${chatResponse.status} ${chatResponse.statusText}`);
        }

        const chatResult = await chatResponse.json();
        console.log('KQL analysis completed');
        console.log('Chat result:', chatResult);

        // Extract analysis text - focus on "Response" field only
        let analysisText = '';
        
        console.log('Processing chatResult for KQL:', typeof chatResult, chatResult);
        
        // If the result is a string that looks like JSON, try to parse it
        if (typeof chatResult === 'string') {
            try {
                const parsedResult = JSON.parse(chatResult);
                console.log('Parsed JSON from string:', parsedResult);
                chatResult = parsedResult;
            } catch (e) {
                console.log('String is not valid JSON, using as-is');
                analysisText = chatResult;
            }
        }
        
        // Now extract the Response field specifically
        if (chatResult && typeof chatResult === 'object') {
            if (chatResult.Response && typeof chatResult.Response === 'string') {
                analysisText = chatResult.Response;
                console.log('Extracted Response field from KQL chatResult');
            } else if (chatResult.response && typeof chatResult.response === 'string') {
                analysisText = chatResult.response;
                console.log('Extracted response field from KQL chatResult');
            } else if (chatResult.message && typeof chatResult.message === 'string') {
                analysisText = chatResult.message;
                console.log('Extracted message field from KQL chatResult');
            } else if (chatResult.analysis && typeof chatResult.analysis === 'string') {
                analysisText = chatResult.analysis;
                console.log('Extracted analysis field from KQL chatResult');
            } else {
                console.warn('No recognizable response field found in KQL chatResult:', chatResult);
                console.warn('Available fields:', Object.keys(chatResult || {}));
                analysisText = 'Analysis completed but no readable response field was found. Please check the console for details.';
            }
        } else if (typeof chatResult === 'string' && analysisText === '') {
            analysisText = chatResult;
            console.log('Using KQL chatResult as string directly');
        } else {
            console.warn('Unexpected KQL chatResult type:', typeof chatResult, chatResult);
            analysisText = 'Analysis completed but response format was unexpected. Please check the console for details.';
        }

        // Store the analysis data
        currentKqlAnalysisData = {
            query: kqlQuery,
            analysis: analysisText,
            timestamp: new Date().toISOString()
        };

        // Display the results
        displayKqlAnalysisResults(currentKqlAnalysisData);

    } catch (error) {
        console.error('Error performing KQL analysis:', error);
        displayKqlAnalysisError(error.message);
    }
}

// Function to show KQL analysis modal - NEW SIMPLE APPROACH
function showKqlAnalysisModal() {
    console.log('=== showKqlAnalysisModal called - SIMPLE APPROACH ===');
    
    // Remove any existing modal
    const existingModal = document.getElementById('dynamicKqlModal');
    if (existingModal) {
        existingModal.remove();
    }
    
    // Create modal dynamically
    const modal = document.createElement('div');
    modal.id = 'dynamicKqlModal';
    modal.style.cssText = `
        position: fixed;
        top: 0;
        left: 0;
        width: 100%;
        height: 100%;
        background-color: rgba(0, 0, 0, 0.8);
        z-index: 999999;
        display: flex;
        align-items: center;
        justify-content: center;
        padding: 20px;
        box-sizing: border-box;
    `;
    
    const container = document.createElement('div');
    container.style.cssText = `
        background: #1a2f1a;
        border: 2px solid #00ff41;
        border-radius: 8px;
        width: 1200px;
        max-width: 95vw;
        max-height: 80vh;
        display: flex;
        flex-direction: column;
        box-shadow: 0 10px 30px rgba(0, 255, 65, 0.3);
        color: #7fff7f;
        font-family: Consolas, monospace;
    `;
    
    container.innerHTML = `
        <div style="padding: 20px 25px 15px 25px; border-bottom: 1px solid #00ff41; display: flex; justify-content: space-between; align-items: center;">
            <h3 style="margin: 0; color: #00ff41; font-size: 1.3rem;">🤖 KQL Query Analysis</h3>
            <div style="display: flex; align-items: center; gap: 10px;">
                <button id="dynamicDownloadBtn" style="display: none; background: #00ff41; color: #101c11; border: none; padding: 8px 16px; border-radius: 4px; cursor: pointer;">📥 Download</button>
                <span id="dynamicCloseBtn" style="color: #00ff41; font-size: 28px; font-weight: bold; cursor: pointer; padding: 0 5px;">&times;</span>
            </div>
        </div>
        <div style="flex: 1; overflow-y: auto; padding: 20px 25px;">
            <div id="dynamicLoadingDiv" style="display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 40px;">
                <div style="border: 3px solid #00ff41; border-radius: 50%; border-top: 3px solid transparent; width: 40px; height: 40px; animation: spin 1s linear infinite;"></div>
                <p style="margin-top: 20px; color: #7fff7f;">Analyzing KQL query...</p>
            </div>
            <div id="dynamicDataDiv" style="display: none; line-height: 1.6;"></div>
            <div id="dynamicErrorDiv" style="display: none; color: #ff6b6b; padding: 20px; background: rgba(255, 0, 0, 0.1); border-radius: 4px;"></div>
        </div>
        <div style="padding: 15px 25px; border-top: 1px solid #00ff41; text-align: right;">
            <button id="dynamicCloseBtn2" style="background: #666; color: #fff; border: none; padding: 10px 20px; border-radius: 4px; cursor: pointer;">Close</button>
        </div>
    `;
    
    // Add spinner animation
    const style = document.createElement('style');
    style.textContent = `
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }
    `;
    document.head.appendChild(style);
    
    modal.appendChild(container);
    document.body.appendChild(modal);
    
    // Add event listeners
    const closeModal = () => {
        modal.remove();
        document.body.style.overflow = '';
    };
    
    document.getElementById('dynamicCloseBtn').onclick = closeModal;
    document.getElementById('dynamicCloseBtn2').onclick = closeModal;
    modal.onclick = (e) => {
        if (e.target === modal) closeModal();
    };
    
    // Prevent body scroll
    document.body.style.overflow = 'hidden';
    
    console.log('Dynamic modal created and displayed');
    return modal;
}

// Function to display KQL analysis results - UPDATED FOR DYNAMIC MODAL
function displayKqlAnalysisResults(analysisData) {
    console.log('=== displayKqlAnalysisResults called - DYNAMIC MODAL ===');
    console.log('Analysis data:', analysisData);
    
    const loadingDiv = document.getElementById('dynamicLoadingDiv');
    const dataDiv = document.getElementById('dynamicDataDiv');
    const errorDiv = document.getElementById('dynamicErrorDiv');
    const downloadBtn = document.getElementById('dynamicDownloadBtn');
    
    console.log('Dynamic modal elements found:', {
        loadingDiv: !!loadingDiv,
        dataDiv: !!dataDiv,
        errorDiv: !!errorDiv,
        downloadBtn: !!downloadBtn
    });
    
    if (loadingDiv) {
        loadingDiv.style.display = 'none';
        console.log('Hidden loading div');
    }
    if (errorDiv) {
        errorDiv.style.display = 'none';
        console.log('Hidden error div');
    }
    
    if (dataDiv) {
        console.log('Formatting analysis text...');
        // Format the analysis text with better structure
        const formattedAnalysis = formatKqlAnalysisText(analysisData.analysis, analysisData.query);
        console.log('Formatted analysis length:', formattedAnalysis.length);
        dataDiv.innerHTML = formattedAnalysis;
        dataDiv.style.display = 'block';
        console.log('Displayed analysis in data div');
    } else {
        console.error('Data div not found!');
    }
    
    if (downloadBtn) {
        downloadBtn.style.display = 'inline-block';
        downloadBtn.onclick = () => downloadKqlAnalysis();
        console.log('Showed download button');
    }
    
    console.log('=== displayKqlAnalysisResults completed ===');
}

// Function to format KQL analysis text with better HTML structure
function formatKqlAnalysisText(analysisText, originalQuery) {
    // Ensure analysisText is a string
    if (typeof analysisText !== 'string') {
        console.warn('formatKqlAnalysisText received non-string input:', typeof analysisText, analysisText);
        analysisText = String(analysisText || 'No analysis content available');
    }
    
    // Clean up any escape characters first
    analysisText = analysisText.replace(/\\n/g, '\n').replace(/\\"/g, '"');
    
    // Enhanced Markdown-style formatting for better readability
    let formatted = analysisText
        // Convert Markdown headers to HTML headers with styling
        .replace(/^# (.*$)/gm, '<h1 style="color: #00ff41; font-size: 1.5rem; margin: 1.5rem 0 1rem 0; padding-bottom: 0.5rem; border-bottom: 2px solid #00ff41;">$1</h1>')
        .replace(/^## (.*$)/gm, '<h2 style="color: #1aff5c; font-size: 1.3rem; margin: 1.5rem 0 1rem 0; padding-bottom: 0.3rem; border-bottom: 1px solid #1aff5c;">$1</h2>')
        .replace(/^### (.*$)/gm, '<h3 style="color: #7fff7f; font-size: 1.2rem; margin: 1.2rem 0 0.8rem 0;">$1</h3>')
        .replace(/^#### (.*$)/gm, '<h4 style="color: #7fff7f; font-size: 1.1rem; margin: 1rem 0 0.6rem 0;">$1</h4>')
        
        // Convert Markdown horizontal rules
        .replace(/^---+$/gm, '<hr style="border: none; border-top: 1px solid #00ff41; margin: 1.5rem 0; opacity: 0.6;">')
        
        // Convert Markdown bold and italic
        .replace(/\*\*(.*?)\*\*/g, '<strong style="color: #00ff41; font-weight: 600;">$1</strong>')
        .replace(/\*(.*?)\*/g, '<em style="color: #1aff5c; font-style: italic;">$1</em>')
        
        // Convert Markdown code blocks
        .replace(/```([\s\S]*?)```/g, '<pre style="background: #142a17; padding: 1rem; border-radius: 5px; border: 1px solid #00ff41; overflow-x: auto; margin: 1rem 0;"><code style="color: #00ff41; font-family: \'Consolas\', \'Courier New\', monospace;">$1</code></pre>')
        
        // Convert inline code
        .replace(/`([^`]+)`/g, '<code style="background: #142a17; padding: 0.2em 0.4em; border-radius: 3px; color: #00ff41; font-family: \'Consolas\', \'Courier New\', monospace;">$1</code>')
        
        // Handle numbered lists with better styling
        .replace(/^(\d+)\.\s+(.*)$/gm, '<div style="margin: 0.5rem 0; padding: 0.5rem 0 0.5rem 2rem; border-left: 3px solid #00ff41; background: rgba(0, 255, 65, 0.05); position: relative;"><span style="position: absolute; left: 0.5rem; color: #00ff41; font-weight: bold;">$1.</span>$2</div>')
        
        // Handle bullet points with better styling
        .replace(/^-\s+(.*)$/gm, '<div style="margin: 0.3rem 0; padding: 0.3rem 0 0.3rem 2rem; color: #e0e0e0; position: relative;"><span style="position: absolute; left: 1rem; color: #00ff41; font-weight: bold;">•</span>$1</div>')
        
        // Convert double line breaks to paragraph breaks
        .replace(/\n\n+/g, '</p><p style="margin-bottom: 1rem; line-height: 1.6; color: #ffffff;">')
        
        // Convert single line breaks to <br>
        .replace(/\n/g, '<br>')
        
        // Clean up any remaining formatting issues
        .replace(/<\/p><p[^>]*><br>/g, '</p><p style="margin-bottom: 1rem; line-height: 1.6; color: #ffffff;">')
        .replace(/<br><\/p>/g, '</p>');
    
    // Wrap content in paragraphs if not already formatted
    if (!formatted.includes('<h1>') && !formatted.includes('<h2>') && !formatted.includes('<div>')) {
        formatted = `<p style="margin-bottom: 1rem; line-height: 1.6; color: #ffffff;">${formatted}</p>`;
    } else {
        // Ensure content starts with a paragraph if it doesn't start with a header
        if (!formatted.startsWith('<h') && !formatted.startsWith('<div>') && !formatted.startsWith('<p>')) {
            formatted = `<p style="margin-bottom: 1rem; line-height: 1.6; color: #ffffff;">${formatted}`;
        }
        // Ensure content ends with a closing paragraph
        if (!formatted.endsWith('</p>') && !formatted.endsWith('</div>')) {
            formatted += '</p>';
        }
    }
    
    // Add KQL query header with enhanced styling
    const header = `
        <div style="background: linear-gradient(135deg, #142a17 0%, #0a1f0e 100%); padding: 1.5rem; border-radius: 8px; margin-bottom: 2rem; border: 2px solid #00ff41; box-shadow: 0 4px 12px rgba(0, 255, 65, 0.1);">
            <h3 style="margin: 0 0 1rem 0; color: #00ff41; font-size: 1.3rem; display: flex; align-items: center;">
                <span style="margin-right: 0.5rem;">📊</span>
                KQL Query Analysis
            </h3>
            <div style="background: rgba(0, 255, 65, 0.1); padding: 1rem; border-radius: 5px; border: 1px solid rgba(0, 255, 65, 0.3); margin-bottom: 1rem;">
                <div style="color: #7fff7f; font-size: 0.9rem; margin-bottom: 0.5rem; font-weight: bold;">Analyzed Query:</div>
                <div style="background: #0a1a0a; padding: 1rem; border-radius: 4px; border: 1px solid #00ff41; overflow-x: auto;">
                    <code style="color: #00ff41; font-family: 'Consolas', 'Courier New', monospace; white-space: pre-wrap; word-break: break-all;">${escapeHtml(originalQuery)}</code>
                </div>
            </div>
            <div style="color: #7fff7f; font-size: 0.9rem; display: flex; align-items: center;">
                <span style="margin-right: 0.5rem;">🤖</span>
                <strong>Analysis Generated:</strong> 
                <span style="margin-left: 0.5rem; color: #00ff41;">${new Date(currentKqlAnalysisData.timestamp).toLocaleString()}</span>
            </div>
        </div>
    `;
    
    // Wrap everything in a container with improved styling
    return `
        <div style="line-height: 1.7; font-size: 1rem;">
            ${header}
            ${formatted}
        </div>
    `;
}

// Function to display KQL analysis error
function displayKqlAnalysisError(errorMessage) {
    const loadingDiv = document.getElementById('kqlAnalysisLoading');
    const dataDiv = document.getElementById('kqlAnalysisData');
    const errorDiv = document.getElementById('kqlAnalysisError');
    const downloadBtn = document.getElementById('downloadKqlAnalysisBtn');
    
    if (loadingDiv) loadingDiv.style.display = 'none';
    if (dataDiv) dataDiv.style.display = 'none';
    if (downloadBtn) downloadBtn.style.display = 'none';
    
    if (errorDiv) {
        errorDiv.innerHTML = `
            <h3 style="color: #ff4444; margin-bottom: 1rem;">⚠️ KQL Analysis Failed</h3>
            <p style="margin-bottom: 1rem;">${escapeHtml(errorMessage)}</p>
            <p style="color: #ff8888; font-size: 0.9em;">
                Please check your KQL query syntax and try again, or contact your administrator if the problem persists.
            </p>
        `;
        errorDiv.style.display = 'block';
    }
}

// Function to close KQL analysis modal
function closeKqlAnalysisModal() {
    const modal = document.getElementById('kqlAnalysisModal');
    if (modal) {
        modal.style.display = 'none';
        // Restore page scrolling
        document.body.style.overflow = '';
    }
}

// Function to download KQL analysis results
function downloadKqlAnalysis() {
    if (!currentKqlAnalysisData) {
        alert('No KQL analysis data available to download.');
        return;
    }
    
    const content = `KQL QUERY ANALYSIS REPORT
================================================================================

ANALYZED QUERY:
${currentKqlAnalysisData.query}

ANALYSIS GENERATED: ${new Date(currentKqlAnalysisData.timestamp).toLocaleString()}

================================================================================

KQL ANALYSIS & EXPLANATION:

${currentKqlAnalysisData.analysis}

================================================================================
Generated by MDEAutomator KQL Analysis
Timestamp: ${currentKqlAnalysisData.timestamp}
`;

    // Create and download the file
    const blob = new Blob([content], { type: 'text/plain;charset=utf-8;' });
    const link = document.createElement('a');
    
    if (link.download !== undefined) {
        const now = new Date();
        const timestamp = now.getFullYear() + 
                         ('0' + (now.getMonth() + 1)).slice(-2) + 
                         ('0' + now.getDate()).slice(-2) + '_' +
                         ('0' + now.getHours()).slice(-2) + 
                         ('0' + now.getMinutes()).slice(-2);
        const filename = `kql_analysis_${timestamp}.txt`;
        
        const url = URL.createObjectURL(blob);
        link.setAttribute('href', url);
        link.setAttribute('download', filename);
        link.style.visibility = 'hidden';
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
        
        console.log(`Downloaded KQL analysis as ${filename}`);
    } else {
        alert('Your browser does not support file downloads.');
    }
}

// Helper function to escape HTML (if not already present)
function escapeHtml(text) {
    if (!text) return '';
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
}

