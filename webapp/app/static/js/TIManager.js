
window.addEventListener('DOMContentLoaded', () => {
    console.log('TIManager page JavaScript loaded');
    
    // Load tenants dropdown on page load
    loadTenants();
    
    // Set up event listeners after a short delay to ensure DOM is fully loaded
    setTimeout(() => {
        console.log('Setting up event listeners...');
        setupEventListeners();
    }, 100);
    
    // Load saved tenant ID from session storage
    const savedTenant = sessionStorage.getItem('TenantId');
    if (savedTenant) {
        // Select the saved tenant in dropdown if available
        setTimeout(() => {
            const tenantDropdown = document.getElementById('tenantDropdown');
            if (tenantDropdown) {
                for (let option of tenantDropdown.options) {
                    if (option.value === savedTenant) {
                        tenantDropdown.value = savedTenant;
                        // Auto-load data if tenant is saved
                        loadThreatIntelligence();
                        break;
                    }
                }
            }
        }, 500); // Wait for tenants to load
    }
    
    // Set up other event listeners
    const refreshIndicatorsBtn = document.getElementById('refreshIndicatorsBtn');
    const tiManualForm = document.getElementById('tiManualForm');
    const tiCsvImportBtn = document.getElementById('tiCsvImportBtn');
    const tiCsvExportBtn = document.getElementById('tiCsvExportBtn');
    const refreshDetectionsBtn = document.getElementById('refreshDetectionsBtn');
    const syncDetectionsBtn = document.getElementById('syncDetectionsBtn');
    const deleteSelectedBtn = document.getElementById('deleteSelectedBtn');
    
    refreshIndicatorsBtn.addEventListener('click', loadThreatIntelligence);
    tiManualForm.addEventListener('submit', tiManualFormSubmit);
    tiCsvImportBtn.addEventListener('click', tiCsvImportBtnClick);
    tiCsvExportBtn.addEventListener('click', tiCsvExportBtnClick);
    refreshDetectionsBtn.addEventListener('click', loadThreatIntelligence);
    syncDetectionsBtn.addEventListener('click', syncDetections);
    deleteSelectedBtn.addEventListener('click', deleteSelectedIOCs);
    
    // Load data on page load if no saved tenant
    if (!savedTenant) {
        loadThreatIntelligence();
    }
});

function getTenantId() {
    const tenantDropdown = document.getElementById('tenantDropdown');
    return tenantDropdown ? tenantDropdown.value.trim() : '';
}

// Loading indicator functions
function showLoadingIndicator(message = 'Loading...') {
    // Create or update loading overlay
    let overlay = document.getElementById('loadingOverlay');
    if (!overlay) {
        overlay = document.createElement('div');
        overlay.id = 'loadingOverlay';
        overlay.style.cssText = `
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            background-color: rgba(0, 0, 0, 0.8);
            display: flex;
            justify-content: center;
            align-items: center;
            z-index: 9999;
            color: #00ff41;
            font-family: Consolas, monospace;
            font-size: 18px;
        `;
        document.body.appendChild(overlay);
    }
    overlay.innerHTML = `<div style="text-align: center;">
        <div style="border: 2px solid #00ff41; border-radius: 50%; width: 40px; height: 40px; border-top: 2px solid transparent; animation: spin 1s linear infinite; margin: 0 auto 20px;"></div>
        ${message}
    </div>`;
    overlay.style.display = 'flex';
    
    // Add CSS animation if not already present
    if (!document.getElementById('loadingStyles')) {
        const style = document.createElement('style');
        style.id = 'loadingStyles';
        style.textContent = '@keyframes spin { 0% { transform: rotate(0deg); } 100% { transform: rotate(360deg); } }';
        document.head.appendChild(style);
    }
}

function hideLoadingIndicator() {
    const overlay = document.getElementById('loadingOverlay');
    if (overlay) {
        overlay.style.display = 'none';
    }
}

// Combined function to load all threat intelligence data
async function loadThreatIntelligence() {
    const tenantId = getTenantId();
    if (!tenantId) {
        console.warn('No tenant selected for loading threat intelligence');
        return;
    }

    console.log('Starting threat intelligence loading...');
    showLoadingIndicator('Loading Threat Intelligence...');

    try {
        // Load both indicators and detections concurrently
        await Promise.all([
            loadIndicatorsInternal(),
            loadDetectionsInternal()
        ]);
        console.log('Threat intelligence loading completed');
    } catch (error) {
        console.error('Error loading threat intelligence:', error);
    } finally {
        hideLoadingIndicator();
    }
}

async function loadIndicatorsInternal() {
    const tenantId = getTenantId();
    if (!tenantId) return;

    const url = `https://${window.FUNCURL}/api/MDETIManager?code=${window.FUNCKEY}`;
    const payload = { TenantId: tenantId, Function: 'GetIndicators' };
    const res = await fetch(url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload)
    });
    const result = await res.json();
    let indicators = result.value || result.machines || result || [];
    if (!Array.isArray(indicators) && indicators.value) indicators = indicators.value;
    
    // Filter out webcategory indicators
    const filteredIndicators = Array.isArray(indicators) ? indicators.filter(indicator => {
        const indicatorType = (indicator.IndicatorType || '').toLowerCase();
        return indicatorType !== 'webcategory';
    }) : [];
    
    renderIndicatorsTable(filteredIndicators);
}

async function loadDetectionsInternal() {
    const tenantId = getTenantId();
    if (!tenantId) return;

    const url = `https://${window.FUNCURL}/api/MDETIManager?code=${window.FUNCKEY}`;
    const payload = { TenantId: tenantId, Function: 'GetDetectionRules' };
    const res = await fetch(url, { 
        method: 'POST', 
        headers: { 'Content-Type': 'application/json' }, 
        body: JSON.stringify(payload) 
    });
    const result = await res.json();
    let detections = result.value || result.machines || result || [];
    if (!Array.isArray(detections) && detections.value) detections = detections.value;
    renderDetectionsTable(Array.isArray(detections) ? detections : []);
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
    const tenantId = getTenantId();
    
    if (!tenantId) { alert('Tenant ID is required.'); return; }
    if (!value) { alert('Please enter a value.'); return; }
    const mapping = getTypeAndFunctionForAdd(typeText);
    
    if (!mapping) { 
        alert(`Invalid type selected. Type text: "${typeText}"`); 
        return; 
    }
    const url = `https://${window.FUNCURL}/api/MDETIManager?code=${window.FUNCKEY}`;
    const payload = { TenantId: tenantId, Function: mapping.func };
    payload[mapping.param] = [value];
    await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    loadThreatIntelligence();
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

    const url = `https://${window.FUNCURL}/api/MDETIManager?code=${window.FUNCKEY}`;
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
        loadThreatIntelligence(); // Refresh the table
    }
}

async function tiCsvImportBtnClick() {
    const fileInput = document.getElementById('tiCsvInput');
    const tenantId = getTenantId();
    if (!tenantId) { alert('Tenant ID is required.'); return; }
    if (!fileInput.files.length) { alert('Please select a CSV file.'); return; }
    const url = `https://${window.FUNCURL}/api/MDETIManager?code=${window.FUNCKEY}`;
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
        
        // Fallback to legacy format
        if (typeIdx === -1) typeIdx = header.indexOf('type');
        if (valueIdx === -1) valueIdx = header.indexOf('value');
        
        if (typeIdx === -1 || valueIdx === -1) { 
            console.error('CSV Import: CSV must have columns: "Indicator Type,Indicator Value" or "Type,Value"'); 
            return; 
        }
        const tiData = { CertSha1s: [], Sha1s: [], Sha256s: [], IPs: [], URLs: [] };
        for (let i = 1; i < lines.length; i++) {
            const row = lines[i].split(',');
            const type = (row[typeIdx] || '').trim();
            const value = (row[valueIdx] || '').trim();
            if (!type || !value) continue;
            
            const lowerType = type.toLowerCase();
            if (lowerType === 'certificatethumbprint' || lowerType === 'certsha1' || lowerType === 'cert-sha1') {
                tiData.CertSha1s.push(value);
            } else if (lowerType === 'filesha1' || lowerType === 'sha1') {
                tiData.Sha1s.push(value);
            } else if (lowerType === 'filesha256' || lowerType === 'sha256') {
                tiData.Sha256s.push(value);
            } else if (lowerType === 'ipaddress' || lowerType === 'ip') {
                tiData.IPs.push(value);
            } else if (lowerType === 'domainname' || lowerType === 'url') {
                tiData.URLs.push(value);
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
                
                const payload = { TenantId: tenantId, Function: functionName };
                payload[paramName] = arr;
                
                try {
                    const response = await fetch(url, { 
                        method: 'POST', 
                        headers: { 'Content-Type': 'application/json' }, 
                        body: JSON.stringify(payload) 
                    });
                    
                    if (!response.ok) {
                        console.error(`Failed to process ${type}:`, response.statusText);
                    }
                } catch (error) {
                    console.error(`Error processing ${type}:`, error);
                }
            }
        }
        
        if (!anySent) {
            console.log('CSV Import: No valid entries found in CSV.');
        } else {
            console.log(`CSV Import complete. Processed: ${processingSummary.join(', ')}`);
        }
        loadThreatIntelligence();
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
        const apiUrl = `https://${window.FUNCURL}/api/MDETIManager?code=${window.FUNCKEY}`;
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
        { id: 'id', name: 'Id' },
        { id: 'displayName', name: 'Title' },
        { id: 'createdBy', name: 'Created By' },
        { id: 'lastModifiedBy', name: 'Last Modified By' },
        { id: 'lastModifiedDateTime', name: 'Last Modified Time' },
        { id: 'period', name: 'Schedule' },
        { id: 'isEnabled', name: 'Active', formatter: cell => cell === true ? 'Yes' : cell === false ? 'No' : '' }
    ];
    const data = detections.map(d => [
        d.id, 
        d.displayName, 
        d.createdBy, 
        d.lastModifiedBy, 
        d.lastModifiedDateTime, 
        d.schedule?.period || '',
        d.isEnabled
    ]);
    window.detectionsGrid = new gridjs.Grid({ columns, data, search: true, sort: true, pagination: true, autoWidth: true, width: '100%', height: 'auto' }).render(container);
}

async function syncDetections() {
    const tenantId = getTenantId();
    if (!tenantId) return;
    const url = `https://${window.FUNCURL}/api/MDECDManager?code=${window.FUNCKEY}`;
    const payload = { TenantId: tenantId, Function: 'Sync' };
    await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    loadThreatIntelligence();
};

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
                // Auto-load all threat intelligence data when tenant is selected
                loadThreatIntelligence();
            } else {
                sessionStorage.removeItem('TenantId');
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
        const response = await fetch('/api/tenants');
        
        if (!response.ok) {
            console.error('HTTP error response:', response.status, response.statusText);
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
            return;
        }
        
        populateTenantDropdown(tenants);
    } catch (error) {
        console.error('Error fetching tenants:', error);
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
    
    // Add tenant options - Client Name first, then Tenant ID in parentheses
    tenants.forEach(tenant => {
        const option = document.createElement('option');
        option.value = tenant.TenantId;
        option.textContent = `${tenant.ClientName} (${tenant.TenantId})`;
        tenantDropdown.appendChild(option);
    });
}

