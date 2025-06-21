// Global variables for device management
let selectedDeviceIds = [];
let machinesGrid = null;
let originalMachinesData = []; // New variable to store the complete unfiltered dataset

// Tenant management state
let isLoadingTenants = false;
let tenantCache = null;
let lastTenantRefresh = 0;
const TENANT_CACHE_DURATION = 30000; // 30 seconds

// Device Group state (available for all tenants)
let deviceGroupsCache = null;
let lastDeviceGroupRefresh = 0;
const DEVICE_GROUP_CACHE_DURATION = 60000; // 60 seconds

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
                        
                        // Get device groups for filtering (available for all tenants)
                        getDeviceGroups(savedTenant);
                        
                        // Auto-load machines table if tenant is saved
                        loadMachines();
                        break;
                    }
                }
            }
        }, 500); // Wait for tenants to load
    }
    
    // Wait for tenant dropdown to populate, then auto-load
    waitForTenantDropdownAndAutoLoad();
});

function getTenantId() {
    const tenantDropdown = document.getElementById('tenantDropdown');
    return tenantDropdown ? tenantDropdown.value.trim() : '';
}

// Helper: Wait for tenant dropdown to be populated, then auto-load machines
function waitForTenantDropdownAndAutoLoad() {
    const savedTenant = sessionStorage.getItem('TenantId');
    const dropdown = document.getElementById('tenantDropdown');
    if (!dropdown) {
        setTimeout(waitForTenantDropdownAndAutoLoad, 100);
        return;
    }
    
    // Wait until dropdown has at least one option
    if (dropdown.options.length === 0) {
        setTimeout(waitForTenantDropdownAndAutoLoad, 100);
        return;
    }
    
    // If saved tenant, select it
    if (savedTenant) {
        for (let option of dropdown.options) {
            if (option.value === savedTenant) {
                dropdown.value = savedTenant;
                break;
            }
        }
    }
    
    // Only auto-load if a tenant is selected
    if (dropdown.value && dropdown.value.trim() !== '') {
        console.log('Auto-loading machines for tenant:', dropdown.value);
        
        // Get device groups for filtering (available for all tenants)
        getDeviceGroups(dropdown.value);
        
        // Auto-load machines for selected tenant
        loadMachines().then(() => {
            // Mark auto-load as completed for platform loading system
            if (typeof window.markAutoLoadCompleted === 'function') {
                window.markAutoLoadCompleted();
            }
        }).catch((error) => {
            console.error('Error in auto-load:', error);
            // Mark auto-load as completed even on error to prevent infinite loading
            if (typeof window.markAutoLoadCompleted === 'function') {
                window.markAutoLoadCompleted();
            }
        });
    } else {
        // No tenant selected, mark auto-load as completed immediately
        console.log('No tenant selected, skipping auto-load');
        if (typeof window.markAutoLoadCompleted === 'function') {
            window.markAutoLoadCompleted();
        }
    }
}

// Use centralized loading system from base.js

async function loadMachines() {
    const tenantId = getTenantId();
    if (!tenantId) {
        console.log('No tenant ID available for auto-loading machines');
        return;
    }
    
    console.log('Loading machines for tenant:', tenantId);
    window.showContentLoading('Loading machines...');
    
    try {
        const url = '/api/devices';
        const payload = {
            TenantId: tenantId,
            Function: 'GetMachines'
        };
        
        const res = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
        
        window.hideContentLoading();
        
        const data = await res.json();
        let machinesRaw = data.machines || data.value;
        
        if (!Array.isArray(machinesRaw)) {
            if (Array.isArray(data)) {
                machinesRaw = data;
            } else if (data.value && Array.isArray(data.value)) {
                machinesRaw = data.value;
            } else {
                console.log('No machines data found in response:', data);
                machinesRaw = [];
            }
        }
        
        console.log('Machines loaded:', machinesRaw.length);
        renderMachinesTable(machinesRaw);
        
    } catch (error) {
        window.hideContentLoading();
        console.error('Error loading machines:', error);
        alert('Error loading machines. Please check console for details.');
    }
}

function renderMachinesTable(machinesRaw) {
    // Store machines data globally for filtering and export
    window.currentMachinesData = machinesRaw;
    originalMachinesData = machinesRaw; // Store the original complete dataset
    
    // Populate DeviceGroup dropdown
    populateDeviceGroupDropdownFromMachines(machinesRaw);

    const columns = [
        { id: 'checkbox', name: '', sort: false, formatter: (_, row) => gridjs.html(`<input type='checkbox' class='device-checkbox' data-deviceid='${row.cells[1].data}' />`) },
        { id: 'id', name: 'DeviceId', width: '15%', sort: true },
        { id: 'computerDnsName', name: 'DeviceName', width: '18%', sort: true },
        { id: 'osPlatform', name: 'OSPlatform', width: '8%', sort: true },
        { id: 'deviceValue', name: 'Value', width: '8%', sort: true },
        { id: 'riskScore', name: 'Risk', width: '7%', sort: true },
        { id: 'rbacGroupName', name: 'DeviceGroup', width: '16%', sort: true },
        { id: 'lastSeen', name: 'LastSeen', width: '10%', sort: true },
        { id: 'firstSeen', name: 'FirstSeen', width: '10%', sort: true },
        { id: 'lastIpAddress', name: 'IP', width: '9%', sort: true },
        { id: 'lastExternalIpAddress', name: 'External IP', width: '11%', sort: true },
        { id: 'machineTags', name: 'DeviceTags', width: '14%', sort: true }
    ];

    // Map LastExternalIpAddress to the new column
    const machines = machinesRaw.map(row => [
        '',
        row.Id || row.id || '',
        row.ComputerDnsName || row.computerDnsName || '',
        row.OsPlatform || row.osPlatform || '',
        row.DeviceValue || row.deviceValue || '',
        row.RiskScore || row.riskScore || '',
        row.RbacGroupName || row.rbacGroupName || '',
        row.LastSeen || row.lastSeen || '',
        row.FirstSeen || row.firstSeen || '',
        row.LastIpAddress || row.lastIpAddress || '',
        row.LastExternalIpAddress || row.lastExternalIpAddress || '',
        row.MachineTags || row.machineTags || ''
    ]);

    if (machinesGrid) machinesGrid.destroy();
    
    // Add device count display with export button
    const deviceCountDiv = document.getElementById('device-count') || document.createElement('div');
    deviceCountDiv.id = 'device-count';
    deviceCountDiv.style.cssText = 'padding: 0.5rem 2rem; background: #142a17; color: #7fff7f; border-bottom: 1px solid #00ff41; font-family: Consolas, monospace; display: flex; justify-content: space-between; align-items: center;';
    
    // Update device count based on current filter
    function updateDeviceCount() {
        const filteredData = getFilteredDevicesData();
        const selectedGroup = getSelectedDeviceGroup();
        let countText = `Total Devices: ${filteredData.length}`;
        if (selectedGroup) {
            countText += ` (filtered by: ${selectedGroup})`;
        }
        deviceCountDiv.querySelector('span').textContent = countText;
    }
    
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
        exportBtn.onclick = () => {
            const filteredData = getFilteredDevicesData();
            exportDevicesCSV(filteredData);
        };
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

function renderMachinesTableWithoutDropdownUpdate(machinesRaw) {
    // Store machines data globally for filtering and export, but don't overwrite original data
    window.currentMachinesData = machinesRaw;
    
    // Skip populating DeviceGroup dropdown - this is the key difference from renderMachinesTable
    
    const columns = [
        { id: 'checkbox', name: '', sort: false, formatter: (_, row) => gridjs.html(`<input type='checkbox' class='device-checkbox' data-deviceid='${row.cells[1].data}' />`) },
        { id: 'id', name: 'DeviceId', width: '15%', sort: true },
        { id: 'computerDnsName', name: 'DeviceName', width: '18%', sort: true },
        { id: 'osPlatform', name: 'OSPlatform', width: '8%', sort: true },
        { id: 'deviceValue', name: 'Value', width: '8%', sort: true },
        { id: 'riskScore', name: 'Risk', width: '7%', sort: true },
        { id: 'rbacGroupName', name: 'DeviceGroup', width: '16%', sort: true },
        { id: 'lastSeen', name: 'LastSeen', width: '10%', sort: true },
        { id: 'firstSeen', name: 'FirstSeen', width: '10%', sort: true },
        { id: 'lastIpAddress', name: 'IP', width: '9%', sort: true },
        { id: 'lastExternalIpAddress', name: 'External IP', width: '11%', sort: true },
        { id: 'machineTags', name: 'DeviceTags', width: '14%', sort: true }
    ];

    // Map LastExternalIpAddress to the new column
    const machines = machinesRaw.map(row => [
        '',
        row.Id || row.id || '',
        row.ComputerDnsName || row.computerDnsName || '',
        row.OsPlatform || row.osPlatform || '',
        row.DeviceValue || row.deviceValue || '',
        row.RiskScore || row.riskScore || '',
        row.RbacGroupName || row.rbacGroupName || '',
        row.LastSeen || row.lastSeen || '',
        row.FirstSeen || row.firstSeen || '',
        row.LastIpAddress || row.lastIpAddress || '',
        row.LastExternalIpAddress || row.lastExternalIpAddress || '',
        row.MachineTags || row.machineTags || ''
    ]);

    if (machinesGrid) machinesGrid.destroy();
    
    // Add device count display with export button
    const deviceCountDiv = document.getElementById('device-count') || document.createElement('div');
    deviceCountDiv.id = 'device-count';
    deviceCountDiv.style.cssText = 'padding: 0.5rem 2rem; background: #142a17; color: #7fff7f; border-bottom: 1px solid #00ff41; font-family: Consolas, monospace; display: flex; justify-content: space-between; align-items: center;';
    
    // Update device count display with current filter info
    const selectedGroup = getSelectedDeviceGroup();
    let countText = `Total Devices: ${machines.length}`;
    if (selectedGroup) {
        countText += ` (filtered by: ${selectedGroup})`;
    }
    
    deviceCountDiv.innerHTML = `
        <span>${countText}</span>
        <button id="exportDevicesBtn" class="cta-button" style="margin: 0; height: 1.8em; font-size: 0.8em;">Export CSV</button>
    `;
    
    const machinesTableContainer = document.getElementById('machines-table');
    if (!document.getElementById('device-count')) {
        machinesTableContainer.parentNode.insertBefore(deviceCountDiv, machinesTableContainer);
    } else {
        document.querySelector('#device-count span').textContent = countText;
    }
    
    // Add export functionality
    const exportBtn = document.getElementById('exportDevicesBtn');
    if (exportBtn) {
        exportBtn.onclick = () => {
            const filteredData = getFilteredDevicesData();
            exportDevicesCSV(filteredData);
        };
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
                
                // Get device groups for filtering (available for all tenants)
                getDeviceGroups(selectedTenant);
                
                // Auto-load machines when tenant is selected
                loadMachines();
            } else {
                sessionStorage.removeItem('TenantId');
                clearDeviceGroups();
            }
        });
    } else {
        console.log('Tenant dropdown not found');
    }
    
    // Device group dropdown change event
    const deviceGroupDropdown = document.getElementById('deviceGroupDropdown');
    if (deviceGroupDropdown) {
        deviceGroupDropdown.addEventListener('change', function() {
            const selectedGroup = this.value;
            console.log('DeviceGroup filter changed to:', selectedGroup || 'All Device Groups');

            // Clear previous selections
            selectedDeviceIds = [];
            updateSelectedCount();

            // Filter machines by selected DeviceGroup
            filterMachinesByDeviceGroup(selectedGroup);
        });
    } else {
        console.error('DeviceGroup dropdown not found');
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

// Device Group Functions

function clearDeviceGroups() {
    const dropdown = document.getElementById('deviceGroupDropdown');
    if (dropdown) {
        dropdown.innerHTML = '<option value="">All Device Groups</option>';
    }
    deviceGroupsCache = null;
}

async function getDeviceGroups(tenantId, force = false) {
    if (!tenantId) {
        console.log('No tenant selected, clearing device groups');
        clearDeviceGroups();
        return;
    }
    
    // Check cache first
    const now = Date.now();
    if (!force && deviceGroupsCache && (now - lastDeviceGroupRefresh) < DEVICE_GROUP_CACHE_DURATION) {
        console.log('Using cached device groups data');
        populateDeviceGroupDropdown(deviceGroupsCache);
        return;
    }
    
    console.log('Loading device groups for tenant:', tenantId);
    
    try {
        const response = await fetch(`/api/device-groups/${encodeURIComponent(tenantId)}`);
        
        if (!response.ok) {
            console.error('HTTP error response:', response.status, response.statusText);
            updateDeviceGroupInfo(`Error loading device groups: ${response.status}`);
            return;
        }
        
        const data = await response.json();
        
        if (data.Status === 'Success') {
            deviceGroupsCache = data.DeviceGroups || [];
            lastDeviceGroupRefresh = now;
            populateDeviceGroupDropdown(deviceGroupsCache);
            console.log(`Loaded ${deviceGroupsCache.length} device groups for filtering`);
        } else {
            const errorMessage = data.Message || data.error || 'Unknown error occurred';
            console.error('Error loading device groups:', errorMessage);
        }
    } catch (error) {
        console.error('Error fetching device groups:', error);
    }
}

function populateDeviceGroupDropdown(deviceGroups) {
    const dropdown = document.getElementById('deviceGroupDropdown');
    if (!dropdown) return;
    
    // Clear existing options except "All Device Groups"
    dropdown.innerHTML = '<option value="">All Device Groups</option>';
    
    // Add device group options with device counts
    deviceGroups.forEach(group => {
        const option = document.createElement('option');
        option.value = group.Name;
        option.textContent = `${group.Name} (${group.DeviceCount} devices)`;
        dropdown.appendChild(option);
    });
}

function populateDeviceGroupDropdownFromMachines(machines) {
    const deviceGroupDropdown = document.getElementById('deviceGroupDropdown');
    if (!deviceGroupDropdown) {
        console.error('DeviceGroup dropdown not found');
        return;
    }

    // Extract unique DeviceGroup values from machines
    const uniqueDeviceGroups = [...new Set(machines.map(machine => machine.RbacGroupName || machine.rbacGroupName || ''))].filter(group => group);

    // Clear existing options
    deviceGroupDropdown.innerHTML = '';

    // Add default option
    const defaultOption = document.createElement('option');
    defaultOption.value = '';
    defaultOption.textContent = 'All Device Groups';
    deviceGroupDropdown.appendChild(defaultOption);

    // Add unique DeviceGroup options
    uniqueDeviceGroups.forEach(group => {
        const option = document.createElement('option');
        option.value = group;
        option.textContent = group;
        deviceGroupDropdown.appendChild(option);
    });

    console.log('DeviceGroup dropdown populated with:', uniqueDeviceGroups);
}

function filterMachinesByDeviceGroup(selectedGroup) {
    console.log('Filtering by group:', selectedGroup);
    console.log('Original data count:', originalMachinesData.length);
    
    // Always filter from the original dataset, not the already filtered data
    const filteredMachines = selectedGroup
        ? originalMachinesData.filter(machine => {
            const groupName = machine.RbacGroupName || machine.rbacGroupName || '';
            return groupName === selectedGroup;
        })
        : originalMachinesData; // Show all machines when "All Device Groups" is selected
    
    console.log('Filtered machines count:', filteredMachines.length);

    // Clear all checkboxes when switching groups
    selectedDeviceIds = [];
    updateSelectedCount();

    // Store current selection to restore after table is rendered
    const currentSelection = selectedGroup || '';

    // Update the current machines data with the filtered results
    window.currentMachinesData = filteredMachines;

    // Render the filtered machines without updating the dropdown
    renderMachinesTableWithoutDropdownUpdate(filteredMachines);
    
    // Restore dropdown selection
    const deviceGroupDropdown = document.getElementById('deviceGroupDropdown');
    if (deviceGroupDropdown) {
        deviceGroupDropdown.value = currentSelection;
    }

    // Log the current state for debugging
    console.log(`Filtered view showing ${filteredMachines.length} machines`);
    console.log(`Selected group: ${selectedGroup || 'All Device Groups'}`);
}

function getSelectedDeviceGroup() {
    const dropdown = document.getElementById('deviceGroupDropdown');
    return dropdown ? dropdown.value : '';
}

function getFilteredDevicesData() {
    // This function returns data that's already filtered in the UI
    // If no group is selected or no data is available, return all data
    const selectedGroup = getSelectedDeviceGroup();
    if (!selectedGroup || !window.currentMachinesData) {
        return window.currentMachinesData || [];
    }
    
    // Filter devices by selected device group
    return window.currentMachinesData.filter(device => {
        const deviceGroup = device.RbacGroupName || device.rbacGroupName || '';
        return deviceGroup === selectedGroup;
    });
}

async function loadTenants(force = false) {
    // Check cache first
    const now = Date.now();
    if (!force && tenantCache && (now - lastTenantRefresh) < TENANT_CACHE_DURATION) {
        console.log('Using cached tenant data');
        populateTenantDropdown(tenantCache);
        // Mark tenants as loaded for platform loading system
        if (typeof window.markTenantsLoaded === 'function') {
            window.markTenantsLoaded();
        }
        return;
    }
    
    if (isLoadingTenants) {
        console.log('Tenant loading already in progress');
        return;
    }
    
    try {
        isLoadingTenants = true;
        console.log('Loading tenants from backend...');
        
        // Update platform loading progress
        if (typeof window.updatePlatformLoadingProgress === 'function') {
            window.updatePlatformLoadingProgress('Connecting to tenant service...', 30);
        }
        
        // Increased timeout to handle Azure Function cold starts
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 45000); // 45 second timeout
        
        const response = await fetch('/api/tenants', {
            signal: controller.signal
        });
        
        clearTimeout(timeoutId);
        
        if (!response.ok) {
            console.error('HTTP error response:', response.status, response.statusText);
            // Mark tenants as loaded even on error to prevent infinite loading
            if (typeof window.markTenantsLoaded === 'function') {
                window.markTenantsLoaded();
            }
            return;
        }
        
        // Update platform loading progress
        if (typeof window.updatePlatformLoadingProgress === 'function') {
            window.updatePlatformLoadingProgress('Processing tenant data...', 50);
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
            // Mark tenants as loaded even on error to prevent infinite loading
            if (typeof window.markTenantsLoaded === 'function') {
                window.markTenantsLoaded();
            }
            return;
        }
        
        // Update cache
        tenantCache = tenants;
        lastTenantRefresh = now;
        
        populateTenantDropdown(tenants);
        
        // Mark tenants as loaded for platform loading system
        if (typeof window.markTenantsLoaded === 'function') {
            window.markTenantsLoaded();
        }
        
    } catch (error) {
        if (error.name === 'AbortError') {
            console.error('Load tenants request timed out');
        } else {
            console.error('Error fetching tenants:', error);
        }
        
        // Mark tenants as loaded even on error to prevent infinite loading
        if (typeof window.markTenantsLoaded === 'function') {
            window.markTenantsLoaded();
        }
    } finally {
        isLoadingTenants = false;
    }
}

function populateTenantDropdown(tenants) {
    const dropdown = document.getElementById('tenantDropdown');
    if (!dropdown) return;
    
    // Clear existing options
    dropdown.innerHTML = '';
    
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
        // Show loading state in modal
        const tenantsList = document.getElementById('tenantsList');
        if (tenantsList) {
            tenantsList.innerHTML = '<p style="color: #00ff41; text-align: center;">Loading tenants...</p>';
        }
        
        // Increased timeout for modal loading to handle cold starts
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 30000); // 30 second timeout
        
        const response = await fetch('/api/tenants', {
            signal: controller.signal
        });
        
        clearTimeout(timeoutId);
        
        if (!response.ok) {
            console.error('HTTP error response:', response.status, response.statusText);
            if (tenantsList) {
                tenantsList.innerHTML = '<p style="color: #ff4444; text-align: center;">Error loading tenants</p>';
            }
            return;
        }
        
        const data = await response.json();
        
        if (data.Status === 'Success') {
            populateTenantsListForModal(data.TenantIds || []);
        } else {
            // Handle different error response formats
            const errorMessage = data.Message || data.error || 'Unknown error occurred';
            console.error('Error loading tenants for modal:', errorMessage);
            if (tenantsList) {
                tenantsList.innerHTML = `<p style="color: #ff4444; text-align: center;">Error: ${errorMessage}</p>`;
            }
        }
    } catch (error) {
        const tenantsList = document.getElementById('tenantsList');
        if (error.name === 'AbortError') {
            console.error('Load tenants for modal request timed out');
            if (tenantsList) {
                tenantsList.innerHTML = '<p style="color: #ff4444; text-align: center;">Loading timed out. Please close and reopen the modal.</p>';
            }
        } else {
            console.error('Error fetching tenants for modal:', error);
            if (tenantsList) {
                tenantsList.innerHTML = '<p style="color: #ff4444; text-align: center;">Error loading tenants</p>';
            }
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
    const addTenantBtn = document.getElementById('addTenantBtn');
    
    if (!newTenantId || !newClientName) return;
    
    const tenantId = newTenantId.value.trim();
    const clientName = newClientName.value.trim();
    
    if (!tenantId || !clientName) {
        alert('Please enter both Tenant ID and Client Name');
        return;
    }
    
    // Disable button and show loading state
    const originalButtonText = addTenantBtn.textContent;
    addTenantBtn.disabled = true;
    addTenantBtn.textContent = 'Adding...';
    addTenantBtn.style.background = '#666';
    
    try {
        console.log('Adding tenant:', tenantId, clientName);
        
        // Increased timeout to handle Azure Function cold starts
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 60000); // 60 second timeout
        
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
            
            // Immediately add to cache to provide instant feedback
            if (tenantCache) {
                const newTenant = {
                    TenantId: tenantId,
                    ClientName: clientName,
                    Enabled: true,
                    AddedDate: new Date().toISOString(),
                    AddedBy: 'User'
                };
                tenantCache.push(newTenant);
                populateTenantDropdown(tenantCache);
            }
            
            // Update modal list with immediate feedback
            loadTenantsForModal();
            
            // Background refresh of tenant cache
            setTimeout(() => loadTenants(true), 100);
            
            alert('Tenant added successfully!');
        } else if (data.Status === 'Error') {
            const errorMessage = data.Message || data.error || 'Unknown error occurred';
            console.error('Error adding tenant:', errorMessage);
            alert('Error adding tenant: ' + errorMessage);
        } else {
            console.error('Unexpected response format:', data);
            alert('Unexpected error occurred. Please try again.');
        }
    } catch (error) {
        console.error('Error adding tenant:', error);
        alert('Error adding tenant: ' + error.message);
    } finally {
        // Re-enable button
        addTenantBtn.disabled = false;
        addTenantBtn.textContent = originalButtonText;
        addTenantBtn.style.background = '';
    }
}

async function deleteTenant(tenantId) {
    if (!tenantId) return;
    
    const confirmed = confirm(`Are you sure you want to delete the tenant ${tenantId}? This action cannot be undone.`);
    if (!confirmed) return;
    
    try {
        // Increased timeout to handle Azure Function cold starts
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 60000); // 60 second timeout
        
        const response = await fetch(`/api/tenants/${encodeURIComponent(tenantId)}`, {
            method: 'DELETE',
            headers: {
                'Content-Type': 'application/json'
            },
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
            console.log('Tenant deleted successfully:', tenantId);
            alert('Tenant deleted successfully');
            
            // Update cache and UI
            tenantCache = tenantCache.filter(tenant => tenant.TenantId !== tenantId);
            populateTenantDropdown(tenantCache);
            loadTenantsForModal();
        } else {
            const errorMessage = data.Message || data.error || 'Unknown error occurred';
            console.error('Error deleting tenant:', errorMessage);
            alert('Error deleting tenant: ' + errorMessage);
        }
    } catch (error) {
        console.error('Error deleting tenant:', error);
        alert('Error deleting tenant: ' + error.message);
    }
}