// Global variables for device management
let selectedDeviceIds = [];
let machinesGrid = null;

document.addEventListener('DOMContentLoaded', () => {
    console.log('Index page JavaScript loaded');
    
    // Check if critical elements exist immediately
    setTimeout(() => {
        console.log('=== Initial DOM check after 100ms ===');
        checkElementsReady();
    }, 100);
    
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
                        // Auto-load machines table if tenant is saved
                        loadMachines();
                        break;
                    }
                }
            }
        }, 500); // Wait for tenants to load
    }
});

function getTenantId() {
    const tenantDropdown = document.getElementById('tenantDropdown');
    return tenantDropdown ? tenantDropdown.value.trim() : '';
}

async function loadMachines() {
    if (!window.FUNCURL || !window.FUNCKEY) {
        alert('FUNCURL and FUNCKEY are not set. Please contact your administrator.');
        return;
    }
    
    const tenantId = getTenantId();
    if (!tenantId) {
        console.log('No tenant ID available for auto-loading machines');
        return;
    }
    
    console.log('Loading machines for tenant:', tenantId);
    
    try {
        const url = `https://${window.FUNCURL}/api/MDEAutomator?code=${window.FUNCKEY}`;
        const payload = {
            TenantId: tenantId,
            Function: 'GetMachines'
        };
        
        const res = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
        
        const data = await res.json();
        let machinesRaw = data.machines || data.value;
        
        if (!Array.isArray(machinesRaw)) {
            if (Array.isArray(data)) {
                machinesRaw = data;
            } else {
                for (const key in data) {
                    if (Array.isArray(data[key])) {
                        machinesRaw = data[key];
                        break;
                    }
                }
            }
        }
        
        renderMachinesTable(machinesRaw || []);
        
    } catch (error) {
        console.error('Error loading machines:', error);
        alert('Error loading machines. Please check console for details.');
    }
}

function renderMachinesTable(machinesRaw) {
    const columns = [
        { id: 'checkbox', name: '', width: '3%', minWidth: '30px', sort: false, formatter: (_, row) => gridjs.html(`<input type='checkbox' class='device-checkbox' data-deviceid='${row.cells[1].data}' />`) },
        { id: 'id', name: 'DeviceId', width: '15%', sort: true },
        { id: 'computerDnsName', name: 'DeviceName', width: '18%', sort: true },
        { id: 'osPlatform', name: 'OSPlatform', width: '8%', sort: true },
        { id: 'deviceValue', name: 'Value', width: '8%', sort: true },
        { id: 'riskScore', name: 'Risk', width: '7%', sort: true },
        { id: 'rbacGroupName', name: 'DeviceGroup', width: '16%', sort: true },
        { id: 'lastSeen', name: 'LastSeen', width: '10%', sort: true },
        { id: 'firstSeen', name: 'FirstSeen', width: '10%', sort: true },
        { id: 'lastIpAddress', name: 'IP', width: '9%', sort: true },
        { id: 'machineTags', name: 'DeviceTags', width: '14%', sort: true }
    ];

    const machines = machinesRaw.map(row => {
        const machineId = row['Id'] || row['id'] || ''; 
        const machineTags = row['MachineTags'] || row['machineTags'] || [];
        const tagsDisplay = Array.isArray(machineTags) ? machineTags.join(', ') : (machineTags || '');
        
        return [
            '', // Checkbox placeholder
            machineId, 
            row['ComputerDnsName'] || row['computerDnsName'] || '',
            row['OsPlatform'] || row['osPlatform'] || '',
            row['DeviceValue'] || row['deviceValue'] || '',
            row['RiskScore'] || row['riskScore'] || '',
            row['RbacGroupName'] || row['rbacGroupName'] || '',
            row['LastSeen'] || row['lastSeen'] || '',
            row['FirstSeen'] || row['firstSeen'] || '',
            row['LastIpAddress'] || row['lastIpAddress'] || '',
            tagsDisplay
        ];
    });

    if (machinesGrid) machinesGrid.destroy();
    
    // Add device count display with export button
    const deviceCountDiv = document.getElementById('device-count') || document.createElement('div');
    deviceCountDiv.id = 'device-count';
    deviceCountDiv.style.cssText = 'padding: 0.5rem 2rem; background: #142a17; color: #7fff7f; border-bottom: 1px solid #00ff41; font-family: Consolas, monospace; display: flex; justify-content: space-between; align-items: center;';
    
    deviceCountDiv.innerHTML = `
        <span>Total Devices: ${machines.length}</span>
        <button id="exportDevicesBtn" class="cta-button" style="margin: 0; height: 1.8em; font-size: 0.8em;">Export CSV</button>
    `;
    
    const machinesTableContainer = document.getElementById('machines-table');
    if (!document.getElementById('device-count')) {
        machinesTableContainer.parentNode.insertBefore(deviceCountDiv, machinesTableContainer);
    }
    
    // Add export functionality
    const exportBtn = document.getElementById('exportDevicesBtn');
    if (exportBtn) {
        exportBtn.onclick = () => exportDevicesCSV(machinesRaw);
    }
    
    machinesGrid = new gridjs.Grid({
        columns: columns,
        data: machines,
        search: true,
        sort: true,
        resizable: true,
        pagination: {
            enabled: true,
            limit: 100, // Show 100 devices per page
            summary: true
        },
        autoWidth: true,
        width: '100%',
        style: {
            table: {
                'table-layout': 'auto',
                'width': '100%',
                'max-width': '100%'
            },
            th: {
                'text-align': 'center',
                'white-space': 'nowrap',
                'overflow': 'hidden',
                'text-overflow': 'ellipsis',
                'padding': '8px 4px'
            },
            td: {
                'text-align': 'center',
                'white-space': 'nowrap',
                'overflow': 'hidden',
                'text-overflow': 'ellipsis',
                'padding': '6px 4px'
            }
        }
    }).render(machinesTableContainer);
    
    // Use event delegation for checkbox handling to work with pagination
    const machinesTable = document.getElementById('machines-table');
    
    // Remove any existing event listeners
    machinesTable.removeEventListener('change', window.checkboxHandler);
    
    // Create new event handler
    window.checkboxHandler = function(event) {
        if (event.target.classList.contains('device-checkbox')) {
            const id = event.target.getAttribute('data-deviceid');
            if (event.target.checked) {
                if (!selectedDeviceIds.includes(id)) selectedDeviceIds.push(id);
            } else {
                selectedDeviceIds = selectedDeviceIds.filter(did => did !== id);
            }
            updateSelectedCount();
        }
    };
    
    // Add event listener with delegation
    machinesTable.addEventListener('change', window.checkboxHandler);
    
    // Update selected checkboxes on page change
    setTimeout(() => {
        updateCheckboxStates();
    }, 100);

    // Add pagination event listener to update checkboxes when page changes
    setTimeout(() => {
        const paginationButtons = document.querySelectorAll('.gridjs-pagination button');
        paginationButtons.forEach(button => {
            button.addEventListener('click', () => {
                setTimeout(() => {
                    updateCheckboxStates();
                }, 200);
            });
        });
    }, 1000);
}

// Function to update checkbox states when changing pages
function updateCheckboxStates() {
    document.querySelectorAll('.device-checkbox').forEach(cb => {
        const deviceId = cb.getAttribute('data-deviceid');
        cb.checked = selectedDeviceIds.includes(deviceId);
    });
    updateSelectedCount();
}

// Function to update selected count display
function updateSelectedCount() {
    const countSpan = document.getElementById('selectedCount');
    if (countSpan) {
        countSpan.textContent = `Selected: ${selectedDeviceIds.length}`;
    }
}

// Function to select all devices on current page
function selectAllOnPage() {
    document.querySelectorAll('.device-checkbox').forEach(cb => {
        const deviceId = cb.getAttribute('data-deviceid');
        cb.checked = true;
        if (!selectedDeviceIds.includes(deviceId)) {
            selectedDeviceIds.push(deviceId);
        }
    });
    updateSelectedCount();
}

// Function to clear all selections
function clearAllSelections() {
    selectedDeviceIds = [];
    document.querySelectorAll('.device-checkbox').forEach(cb => {
        cb.checked = false;
    });
    updateSelectedCount();
}

// Function to export devices data to CSV
function exportDevicesCSV(devicesData) {
    if (!Array.isArray(devicesData) || devicesData.length === 0) {
        alert('No device data available to export.');
        return;
    }
    
    // Define friendly column names mapping
    const columnMapping = {
        'Id': 'DeviceId',
        'id': 'DeviceId',
        'ComputerDnsName': 'DeviceName',
        'computerDnsName': 'DeviceName',
        'OsPlatform': 'OSPlatform',
        'osPlatform': 'OSPlatform',
        'DeviceValue': 'Value',
        'deviceValue': 'Value',
        'RiskScore': 'Risk',
        'riskScore': 'Risk',
        'RbacGroupName': 'DeviceGroup',
        'rbacGroupName': 'DeviceGroup',
        'LastSeen': 'LastSeen',
        'lastSeen': 'LastSeen',
        'FirstSeen': 'FirstSeen',
        'firstSeen': 'FirstSeen',
        'LastIpAddress': 'IP',
        'lastIpAddress': 'IP',
        'MachineTags': 'DeviceTags',
        'machineTags': 'DeviceTags'
    };
    
    // Get all unique keys from the devices data
    const allKeys = new Set();
    devicesData.forEach(device => {
        Object.keys(device).forEach(key => allKeys.add(key));
    });
    
    // Create CSV headers using friendly names
    const headers = Array.from(allKeys).map(key => columnMapping[key] || key);
    
    // Create CSV content
    let csvContent = headers.join(',') + '\n';
    
    // Add data rows
    devicesData.forEach(device => {
        const row = Array.from(allKeys).map(key => {
            let value = device[key];
            
            // Handle arrays (like MachineTags)
            if (Array.isArray(value)) {
                value = value.join('; ');
            }
            
            // Handle null/undefined values
            if (value === null || value === undefined) {
                value = '';
            }
            
            // Convert to string and escape commas/quotes
            value = String(value);
            if (value.includes(',') || value.includes('"') || value.includes('\n')) {
                value = '"' + value.replace(/"/g, '""') + '"';
            }
            
            return value;
        });
        
        csvContent += row.join(',') + '\n';
    });
    
    // Create and download the file
    const blob = new Blob([csvContent], { type: 'text/csv;charset=utf-8;' });
    const link = document.createElement('a');
    
    if (link.download !== undefined) {
        // Create filename with timestamp
        const now = new Date();
        const timestamp = now.getFullYear() + 
                         ('0' + (now.getMonth() + 1)).slice(-2) + 
                         ('0' + now.getDate()).slice(-2) + '_' +
                         ('0' + now.getHours()).slice(-2) + 
                         ('0' + now.getMinutes()).slice(-2);
        const filename = `devices_export_${timestamp}.csv`;
        
        const url = URL.createObjectURL(blob);
        link.setAttribute('href', url);
        link.setAttribute('download', filename);
        link.style.visibility = 'hidden';
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
        
        console.log(`Exported ${devicesData.length} devices to ${filename}`);
    } else {
        alert('Your browser does not support file downloads.');
    }
}

// Tenant Management Functions

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
                // Auto-load machines when tenant is selected
                loadMachines();
            } else {
                sessionStorage.removeItem('TenantId');
            }
        });
    } else {
        console.log('Tenant dropdown not found');
    }
    
    // Manage tenants button
    const manageTenantBtn = document.getElementById('manageTenantBtn');
    console.log('Looking for manageTenantBtn element...');
    console.log('manageTenantBtn found:', manageTenantBtn);
    
    if (manageTenantBtn) {
        console.log('Found manage tenant button, adding click listener');
        manageTenantBtn.addEventListener('click', function(e) {
            console.log('Manage tenant button clicked');
            e.preventDefault(); // Prevent any default behavior
            try {
                openTenantModal();
            } catch (error) {
                console.error('Error in button click handler:', error);
                alert('Error: ' + error.message);
            }
        });
    } else {
        console.log('Manage tenant button not found');
        console.error('ERROR: manageTenantBtn element not found in DOM!');
        // Let's try to find all buttons to debug
        const allButtons = document.querySelectorAll('button');
        console.log('All buttons found in DOM:', Array.from(allButtons).map(btn => ({id: btn.id, text: btn.textContent})));
    }
    
    // Modal close events
    const closeModal = document.querySelector('#tenantModal .close');
    const closeTenantModalBtn = document.getElementById('closeTenantModal');
    if (closeModal) closeModal.addEventListener('click', closeTenantModal);
    if (closeTenantModalBtn) closeTenantModalBtn.addEventListener('click', closeTenantModal);
    
    // Add tenant button
    const addTenantBtn = document.getElementById('addTenantBtn');
    if (addTenantBtn) {
        addTenantBtn.addEventListener('click', addTenant);
    }
    
    // Close modal when clicking outside
    const tenantModal = document.getElementById('tenantModal');
    if (tenantModal) {
        tenantModal.addEventListener('click', function(event) {
            if (event.target === tenantModal) {
                closeTenantModal();
            }
        });
    }
    
    // Enter key support for add tenant form
    const newTenantId = document.getElementById('newTenantId');
    const newClientName = document.getElementById('newClientName');
    if (newTenantId && newClientName) {
        [newTenantId, newClientName].forEach(input => {
            input.addEventListener('keypress', function(event) {
                if (event.key === 'Enter') {
                    addTenant();
                }
            });
        });
    }
}

async function loadTenants() {
    try {
        console.log('Loading tenants from backend...');
        
        // Add timeout controller for longer operations
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 45000); // 45 second timeout
        
        const response = await fetch('/api/tenants', {
            signal: controller.signal
        });
        
        clearTimeout(timeoutId);
        
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
        if (error.name === 'AbortError') {
            console.error('Load tenants request timed out');
            alert('Loading tenants timed out. Please try again.');
        } else {
            console.error('Error fetching tenants:', error);
        }
    }
}

function populateTenantDropdown(tenants) {
    const dropdown = document.getElementById('tenantDropdown');
    if (!dropdown) return;
    
    // Clear existing options except the first one
    dropdown.innerHTML = '<option value="">Select Tenant...</option>';
    
    // Add tenant options - Client Name first, then Tenant ID in parentheses
    tenants.forEach(tenant => {
        const option = document.createElement('option');
        option.value = tenant.TenantId;
        option.textContent = `${tenant.ClientName} (${tenant.TenantId})`;
        dropdown.appendChild(option);
    });
}

function openTenantModal() {
    console.log('openTenantModal function called');
    
    try {
        const modal = document.getElementById('tenantModal');
        console.log('Looking for tenantModal element...');
        console.log('tenantModal found:', modal);
        
        if (modal) {
            console.log('Found tenant modal, showing it');
            modal.style.display = 'block';
            loadTenantsForModal();
            
            // Clear the add form
            const newTenantId = document.getElementById('newTenantId');
            const newClientName = document.getElementById('newClientName');
            if (newTenantId) newTenantId.value = '';
            if (newClientName) newClientName.value = '';
            
            console.log('Modal should now be visible');
        } else {
            console.log('Tenant modal not found!');
            console.error('ERROR: tenantModal element not found in DOM!');
            
            // Let's debug what modal elements exist
            const allModals = document.querySelectorAll('[id*="modal"], [class*="modal"]');
            console.log('All modal-related elements found:', Array.from(allModals).map(el => ({id: el.id, class: el.className})));
            
            alert('Error: Tenant modal element not found!');
        }
    } catch (error) {
        console.error('Error in openTenantModal:', error);
        alert('Error opening tenant modal: ' + error.message);
    }
}

function closeTenantModal() {
    const modal = document.getElementById('tenantModal');
    if (modal) {
        modal.style.display = 'none';
    }
}

async function loadTenantsForModal() {
    try {
        // Add timeout controller for longer operations
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 45000); // 45 second timeout
        
        const response = await fetch('/api/tenants', {
            signal: controller.signal
        });
        
        clearTimeout(timeoutId);
        
        if (!response.ok) {
            console.error('HTTP error response:', response.status, response.statusText);
            return;
        }
        
        const data = await response.json();
        
        if (data.Status === 'Success') {
            populateTenantsListForModal(data.TenantIds || []);
        } else {
            // Handle different error response formats
            const errorMessage = data.Message || data.error || 'Unknown error occurred';
            console.error('Error loading tenants for modal:', errorMessage);
        }
    } catch (error) {
        if (error.name === 'AbortError') {
            console.error('Load tenants for modal request timed out');
            // Don't show alert here as this is background loading
        } else {
            console.error('Error fetching tenants for modal:', error);
        }
    }
}

function populateTenantsListForModal(tenants) {
    const tenantsList = document.getElementById('tenantsList');
    if (!tenantsList) return;
    
    if (tenants.length === 0) {
        tenantsList.innerHTML = '<p style="color: #666; font-style: italic;">No tenants found.</p>';
        return;
    }
    
    let html = '';
    tenants.forEach(tenant => {
        html += `
            <div class="tenant-item" style="display: flex; justify-content: space-between; align-items: center; padding: 10px; margin: 5px 0; background: #0a1a0a; border: 1px solid #00ff41; border-radius: 4px;">
                <div>
                    <strong style="color: #00ff41;">${tenant.TenantId}</strong>
                    <br>
                    <span style="color: #7fff7f;">${tenant.ClientName}</span>
                    <br>
                    <small style="color: #666;">Added: ${tenant.AddedDate || 'Unknown'}</small>
                </div>
                <button onclick="deleteTenant('${tenant.TenantId}')" class="delete-btn" style="background: #ff4400; border: 1px solid #ff4400; color: white; padding: 5px 10px; border-radius: 3px; cursor: pointer; font-size: 12px;">Delete</button>
            </div>
        `;
    });
    
    tenantsList.innerHTML = html;
}

async function addTenant() {
    const newTenantId = document.getElementById('newTenantId');
    const newClientName = document.getElementById('newClientName');
    
    if (!newTenantId || !newClientName) return;
    
    const tenantId = newTenantId.value.trim();
    const clientName = newClientName.value.trim();
    
    if (!tenantId || !clientName) {
        alert('Please enter both Tenant ID and Client Name');
        return;
    }
    
    try {
        console.log('Adding tenant:', tenantId, clientName);
        
        // Add timeout controller for longer operations
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 45000); // 45 second timeout
        
        const response = await fetch('/api/tenants', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                TenantId: tenantId,
                ClientName: clientName
            }),
            signal: controller.signal
        });
        
        clearTimeout(timeoutId);
        
        if (!response.ok) {
            console.error('HTTP error response:', response.status, response.statusText);
            alert(`HTTP error: ${response.status} ${response.statusText}`);
            return;
        }
        
        const data = await response.json();
        
        if (data.Status === 'Success') {
            console.log('Tenant added successfully');
            
            // Clear the form
            newTenantId.value = '';
            newClientName.value = '';
            
            // Reload the tenants list in modal and dropdown
            loadTenantsForModal();
            loadTenants();
            
            alert('Tenant added successfully!');
        } else if (data.Status === 'Warning') {
            const warningMessage = data.Message || 'Warning occurred';
            alert(`Warning: ${warningMessage}`);
        } else {
            // Handle different error response formats
            const errorMessage = data.Message || data.error || 'Unknown error occurred';
            console.error('Error adding tenant:', errorMessage);
            alert(`Error adding tenant: ${errorMessage}`);
        }
    } catch (error) {
        if (error.name === 'AbortError') {
            console.error('Add tenant request timed out');
            alert('Adding tenant timed out. Please try again.');
        } else {
            console.error('Error adding tenant:', error);
            alert('Error adding tenant. Please check console for details.');
        }
    }
}

async function deleteTenant(tenantId) {
    if (!confirm(`Are you sure you want to delete tenant "${tenantId}"?`)) {
        return;
    }
    
    try {
        console.log('Deleting tenant:', tenantId);
        
        // Add timeout controller for longer operations
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 45000); // 45 second timeout
        
        const response = await fetch(`/api/tenants/${encodeURIComponent(tenantId)}`, {
            method: 'DELETE',
            signal: controller.signal
        });
        
        clearTimeout(timeoutId);
        
        if (!response.ok) {
            console.error('HTTP error response:', response.status, response.statusText);
            alert(`HTTP error: ${response.status} ${response.statusText}`);
            return;
        }
        
        const data = await response.json();
        
        if (data.Status === 'Success') {
            console.log('Tenant deleted successfully');
            
            // Reload the tenants list in modal and dropdown
            loadTenantsForModal();
            loadTenants();
            
            // Clear selection if the deleted tenant was selected
            const currentTenant = getTenantId();
            if (currentTenant === tenantId) {
                const tenantDropdown = document.getElementById('tenantDropdown');
                if (tenantDropdown) {
                    tenantDropdown.value = '';
                    sessionStorage.removeItem('TenantId');
                }
            }
            
            alert('Tenant deleted successfully!');
        } else {
            // Handle different error response formats
            const errorMessage = data.Message || data.error || 'Unknown error occurred';
            console.error('Error deleting tenant:', errorMessage);
            alert(`Error deleting tenant: ${errorMessage}`);
        }
    } catch (error) {
        if (error.name === 'AbortError') {
            console.error('Delete tenant request timed out');
            alert('Deleting tenant timed out. Please try again.');
        } else {
            console.error('Error deleting tenant:', error);
            alert('Error deleting tenant. Please check console for details.');
        }
    }
}

// Debug function - can be called from browser console
function testTenantModal() {
    console.log('=== Testing tenant modal functionality ===');
    
    const manageTenantBtn = document.getElementById('manageTenantBtn');
    console.log('Manage tenant button:', manageTenantBtn);
    console.log('Button exists:', !!manageTenantBtn);
    
    const tenantModal = document.getElementById('tenantModal');
    console.log('Tenant modal element:', tenantModal);
    console.log('Modal exists:', !!tenantModal);
    
    if (manageTenantBtn && tenantModal) {
        console.log('Both elements found! Testing button click...');
        manageTenantBtn.click();
        console.log('Button click executed');
    } else {
        console.log('Missing elements - cannot test');
    }
    
    // Try opening modal directly
    console.log('Attempting to open modal directly');
    try {
        openTenantModal();
        console.log('Direct modal open executed');
    } catch (error) {
        console.error('Error opening modal directly:', error);
    }
    
    console.log('=== Test complete ===');
}

// Function to check if elements are ready
function checkElementsReady() {
    const manageTenantBtn = document.getElementById('manageTenantBtn');
    const tenantModal = document.getElementById('tenantModal');
    const tenantDropdown = document.getElementById('tenantDropdown');
    
    console.log('=== Element readiness check ===');
    console.log('manageTenantBtn:', !!manageTenantBtn);
    console.log('tenantModal:', !!tenantModal);
    console.log('tenantDropdown:', !!tenantDropdown);
    console.log('=== End check ===');
    
    return manageTenantBtn && tenantModal && tenantDropdown;
}