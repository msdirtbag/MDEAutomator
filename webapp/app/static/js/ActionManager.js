// Global variables for action management
let actionsGrid = null;
let allActions = [];

// Test function to debug API responses
window.testActionAPI = async function() {
    const tenantInput = document.getElementById('tenantInput');
    const tenantId = tenantInput ? tenantInput.value.trim() : '';
    
    if (!tenantId) {
        console.log('Please enter a tenant ID first');
        return;
    }
    
    console.log('Testing API with tenant ID:', tenantId);
    
    try {
        const res = await fetch('/api/actions', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                TenantId: tenantId,
                Function: 'GetActions'
            })
        });
        
        console.log('Response status:', res.status);
        console.log('Response headers:', [...res.headers.entries()]);
        
        const responseText = await res.text();
        console.log('Raw response text:', responseText);
        
        try {
            const responseJson = JSON.parse(responseText);
            console.log('Parsed response JSON:', responseJson);
            console.log('Response type:', typeof responseJson);
            if (responseJson && typeof responseJson === 'object') {
                console.log('Response keys:', Object.keys(responseJson));
            }
        } catch (e) {
            console.error('Failed to parse response as JSON:', e);
        }
        
    } catch (error) {
        console.error('Error in test:', error);
    }
};

document.addEventListener('DOMContentLoaded', () => {
    console.log('ActionManager page JavaScript loaded');

    // Load tenants dropdown on page load
    loadTenants();

    // Set up event listeners after a short delay to ensure DOM is fully loaded
    setTimeout(() => {
        console.log('Setting up event listeners...');
        setupEventListeners();
    }, 100);

    // Wait for tenant dropdown to be populated, then auto-load actions
    waitForTenantDropdownAndLoadActions();    // Attach event handlers to action buttons
    const refreshActionsBtn = document.getElementById('refreshActionsBtn');
    const addActionBtn = document.getElementById('addActionBtn');
    const undoActionsBtn = document.getElementById('undoActionsBtn');
    if (refreshActionsBtn) refreshActionsBtn.onclick = loadActions;
    if (addActionBtn) addActionBtn.onclick = showAddActionModal;
    if (undoActionsBtn) undoActionsBtn.onclick = undoAllPendingActions;

    // Modal buttons
    const saveActionBtn = document.getElementById('saveActionBtn');
    const cancelActionBtn = document.getElementById('cancelActionBtn');
    if (saveActionBtn) saveActionBtn.onclick = saveNewAction;
    if (cancelActionBtn) cancelActionBtn.onclick = hideAddActionModal;
});

// Helper: Wait for tenant dropdown to be populated, then auto-load actions
function waitForTenantDropdownAndLoadActions() {
    const savedTenant = sessionStorage.getItem('TenantId');
    const dropdown = document.getElementById('tenantDropdown');
    if (!dropdown) {
        setTimeout(waitForTenantDropdownAndLoadActions, 100);
        return;
    }
    // Wait until dropdown has at least one option
    if (dropdown.options.length === 0) {
        setTimeout(waitForTenantDropdownAndLoadActions, 100);
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
    // Auto-load actions for selected tenant
    if (dropdown.value && dropdown.value.trim() !== '') {
        loadActions().then(() => {
            // Mark auto-load as completed
            if (typeof window.markAutoLoadCompleted === 'function') {
                window.markAutoLoadCompleted();
            }
        }).catch((error) => {
            console.error('Error in actions auto-load:', error);
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

// Use centralized loading system from base.js

async function loadActions() {
    const tenantId = getTenantId();
    if (!tenantId) return;
    
    console.log('Loading actions for tenant:', tenantId);
    window.showContentLoading('Loading Actions');
    
    try {// Call Azure Function directly like TIManager does
        const url = `https://${window.FUNCURL}/api/MDEAutomator?code=${window.FUNCKEY}`;
        const payload = { TenantId: tenantId, Function: 'GetActions' };
        
        // Add timeout to handle Azure Function cold starts
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 60000); // 60 second timeout
        
        const res = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload),
            signal: controller.signal
        });
        
        clearTimeout(timeoutId);
        const result = await res.json();
        let actions = result.value || result.actions || result || [];
        if (!Array.isArray(actions) && actions.value) {
            actions = actions.value;
        }
        
        // Ensure we have an array for the table rendering
        const actionsRaw = Array.isArray(actions) ? actions : [];
        
        console.log('Final actionsRaw:', actionsRaw);
        console.log('Number of actions:', actionsRaw.length);
        
        allActions = actionsRaw;
        renderActionsTable(allActions);
        console.log('Actions loading completed');
        
    } catch (error) {
        console.error('Error loading actions:', error);
        
        // Show a more user-friendly error message
        const actionCount = document.getElementById('actionCount');
        if (actionCount) {
            actionCount.textContent = `Error: ${error.message}`;
            actionCount.style.color = '#dc3545';
        }
        
        // Clear the table or show empty state
        allActions = [];
        renderActionsTable(allActions);    } finally {
        window.hideContentLoading();
    }
}

function renderActionsTable(actionsRaw) {
    console.log('renderActionsTable called with:', actionsRaw);
    console.log('Type of actionsRaw:', typeof actionsRaw);
    console.log('Is actionsRaw an array?', Array.isArray(actionsRaw));
    
    // Ensure actionsRaw is an array
    if (!Array.isArray(actionsRaw)) {
        console.warn('actionsRaw is not an array, converting to empty array');
        actionsRaw = [];
    }
      const columns = [
        { id: 'id', name: 'Action ID', width: '12%', sort: true },
        { id: 'type', name: 'Type', width: '12%', sort: true, 
          formatter: (cell) => gridjs.html(`<span class="action-type">${cell}</span>`) },
        { id: 'status', name: 'Status', width: '10%', sort: true,
          formatter: (cell) => {
            const statusClass = `status-${cell.toLowerCase()}`;
            return gridjs.html(`<span class="${statusClass}">${cell}</span>`);
          }
        },        { id: 'computerDnsName', name: 'Device Name', width: '14%', sort: true },
        { id: 'requestor', name: 'Requestor', width: '12%', sort: true },
        { id: 'requestorComment', name: 'Comment', width: '14%', sort: true,
          formatter: (cell) => {
            if (!cell || cell.length === 0) return '';
            const fullText = String(cell);
            const truncatedText = fullText.length > 50 ? fullText.substring(0, 50) + '...' : fullText;
            return gridjs.html(`<span title="${fullText.replace(/"/g, '&quot;')}">${truncatedText}</span>`);
          }
        },
        { id: 'creationDateTimeUtc', name: 'Created', width: '13%', sort: true,
          formatter: (cell) => {
            if (!cell) return '';
            const date = new Date(cell);
            return date.toLocaleString();
          }
        },
        { id: 'lastUpdateDateTimeUtc', name: 'Last Updated', width: '13%', sort: true,
          formatter: (cell) => {
            if (!cell) return '';
            const date = new Date(cell);
            return date.toLocaleString();
          }
        },
        { id: 'requestSource', name: 'Source', width: '10%', sort: true }
    ];    const actions = actionsRaw.map(row => {
        return [
            row.Id || row.id || '',
            row.Type || row.type || '',
            row.Status || row.status || '',
            row.ComputerDnsName || row.computerDnsName || '',
            row.Requestor || row.requestor || '',
            row.RequestorComment || row.requestorComment || '',
            row.CreationDateTimeUtc || row.creationDateTimeUtc || '',
            row.LastUpdateDateTimeUtc || row.lastUpdateDateTimeUtc || '',
            row.RequestSource || row.requestSource || ''
        ];
    });

    if (actionsGrid) actionsGrid.destroy();
    
    // Add action count display
    const actionCountDiv = document.getElementById('action-count') || document.createElement('div');
    actionCountDiv.id = 'action-count';
    actionCountDiv.style.cssText = 'padding: 0.5rem 2rem; background: #142a17; color: #7fff7f; border-bottom: 1px solid #00ff41; font-family: Consolas, monospace;';
      // Count actions by status
    const statusCounts = {
        total: actions.length,
        pending: actions.filter(action => action[2].toLowerCase() === 'pending').length,
        succeeded: actions.filter(action => action[2].toLowerCase() === 'succeeded').length,
        failed: actions.filter(action => action[2].toLowerCase() === 'failed').length,
        cancelled: actions.filter(action => action[2].toLowerCase() === 'cancelled').length
    };
    
    actionCountDiv.innerHTML = `
        <span style="margin-right: 2rem;">Total Actions: ${statusCounts.total}</span>
        <span style="margin-right: 1rem; color: #ffaa00;">Pending: ${statusCounts.pending}</span>
        <span style="margin-right: 1rem; color: #00ff41;">Succeeded: ${statusCounts.succeeded}</span>
        <span style="margin-right: 1rem; color: #ff4400;">Failed: ${statusCounts.failed}</span>
        <span style="color: #888;">Cancelled: ${statusCounts.cancelled}</span>
    `;
      // Update the action count in toolbar
    const toolbarCount = document.getElementById('actionCount');
    if (toolbarCount) {
        toolbarCount.textContent = `Total Actions: ${statusCounts.total}`;
        toolbarCount.style.color = '#7fff7f'; // Reset color in case it was red from error
    }
    
    const actionsTableContainer = document.getElementById('actions-table');
    if (!document.getElementById('action-count')) {
        actionsTableContainer.parentNode.insertBefore(actionCountDiv, actionsTableContainer);
    }
    
    actionsGrid = new gridjs.Grid({
        columns: columns,
        data: actions,
        search: true,
        sort: true,
        resizable: true,
        pagination: {
            enabled: true,
            limit: 50, // Show 50 actions per page
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
    }).render(actionsTableContainer);
}

// Utility function to format dates consistently
function formatDateTime(dateString) {
    if (!dateString) return '';
    const date = new Date(dateString);
    return date.toLocaleString('en-US', {
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit',
        second: '2-digit'
    });
}

// Function to get actions by status
function getActionsByStatus(status) {
    return allActions.filter(action => 
        (action.Status || action.status || '').toLowerCase() === status.toLowerCase()
    );
}

// Function to export actions data (future enhancement)
function exportActionsData() {
    if (allActions.length === 0) {
        alert('No actions data to export.');
        return;
    }
      const csvContent = "data:text/csv;charset=utf-8," 
        + "Action ID,Type,Status,Device Name,Requestor,Comment,Created,Last Updated,Source\n"
        + allActions.map(action => [
            action.Id || action.id || '',
            action.Type || action.type || '',
            action.Status || action.status || '',
            action.ComputerDnsName || action.computerDnsName || '',
            action.Requestor || action.requestor || '',
            action.RequestorComment || action.requestorComment || '',
            action.CreationDateTimeUtc || action.creationDateTimeUtc || '',
            action.LastUpdateDateTimeUtc || action.lastUpdateDateTimeUtc || '',
            action.RequestSource || action.requestSource || ''
        ].map(field => `"${field}"`).join(",")).join("\n");

    const encodedUri = encodeURI(csvContent);
    const link = document.createElement("a");
    link.setAttribute("href", encodedUri);
    link.setAttribute("download", `actions_export_${new Date().toISOString().split('T')[0]}.csv`);
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
}

// Function to undo all pending actions
async function undoAllPendingActions() {
    const tenantId = getTenantId();
    if (!tenantId) {
        alert('Please enter and save a Tenant ID first.');
        return;
    }
    
    // Confirm the action since it affects all pending actions
    const confirmMessage = `⚠️ WARNING: This will cancel ALL PENDING ACTIONS in the tenant!\n\nAre you absolutely sure you want to proceed?`;
    if (!confirm(confirmMessage)) {
        return;
    }
      console.log('Undoing all pending actions for tenant:', tenantId);
    
    try {        // Call Azure Function directly like TIManager does
        const url = `https://${window.FUNCURL}/api/MDEAutomator?code=${window.FUNCKEY}`;
        const payload = { TenantId: tenantId, Function: 'UndoActions' };
        
        // Add timeout to handle Azure Function cold starts
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 60000); // 60 second timeout
        
        const res = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload),
            signal: controller.signal
        });
        
        clearTimeout(timeoutId);
        const result = await res.json();
        
        alert(`Undo Actions completed successfully!\n\nResult: ${JSON.stringify(result, null, 2)}`);
        
        // Refresh the actions table after undoing
        loadActions();
        
    } catch (error) {
        console.error('Error undoing actions:', error);
        alert('Error undoing actions: ' + error.message);
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
                // Auto-load actions when tenant is selected
                loadActions();
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
        
        // Update platform loading progress
        if (typeof window.updatePlatformLoadingProgress === 'function') {
            window.updatePlatformLoadingProgress('Loading tenants for Action Manager...', 30);
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
    
    // Add tenant options - Client Name first, then Tenant ID in parentheses
    tenants.forEach(tenant => {
        const option = document.createElement('option');
        option.value = tenant.TenantId;
        option.textContent = `${tenant.ClientName} (${tenant.TenantId})`;
        tenantDropdown.appendChild(option);
    });
}

