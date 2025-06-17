// Global variables for query management
let queriesGrid = null;
let allQueries = [];

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
    console.log('HuntManager page JavaScript loaded');

    // Load tenants dropdown on page load
    loadTenants();

    // Set up event listeners after a short delay to ensure DOM is fully loaded
    setTimeout(() => {
        console.log('Setting up event listeners...');
        setupEventListeners();
    }, 100);

    // Wait for tenant dropdown to be populated, then auto-load queries
    waitForTenantDropdownAndLoadQueries();

    // Attach event handlers to query buttons
    const refreshQueriesBtn = document.getElementById('refreshQueriesBtn');
    const addQueryBtn = document.getElementById('addQueryBtn');
    if (refreshQueriesBtn) refreshQueriesBtn.onclick = loadQueries;
    if (addQueryBtn) addQueryBtn.onclick = showAddQueryModal;

    // Modal buttons
    const saveQueryBtn = document.getElementById('saveQueryBtn');
    const cancelQueryBtn = document.getElementById('cancelQueryBtn');
    if (saveQueryBtn) saveQueryBtn.onclick = saveNewQuery;
    if (cancelQueryBtn) cancelQueryBtn.onclick = hideAddQueryModal;

    // Always load queries on page load
    loadQueries();
});

// Helper: Wait for tenant dropdown to be populated, then auto-load queries
function waitForTenantDropdownAndLoadQueries() {
    const savedTenant = sessionStorage.getItem('TenantId');
    const dropdown = document.getElementById('tenantDropdown');
    if (!dropdown) {
        setTimeout(waitForTenantDropdownAndLoadQueries, 100);
        return;
    }
    // Wait until dropdown has at least one option
    if (dropdown.options.length === 0) {
        setTimeout(waitForTenantDropdownAndLoadQueries, 100);
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
    // Auto-load queries for selected tenant
    if (dropdown.value && dropdown.value.trim() !== '') {
        loadQueries().then(() => {
            // Mark auto-load as completed
            if (typeof window.markAutoLoadCompleted === 'function') {
                window.markAutoLoadCompleted();
            }
        }).catch((error) => {
            console.error('Error in queries auto-load:', error);
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

async function loadQueries() {
    const tenantId = getTenantId();
    if (!tenantId) return;
    window.showContentLoading('Loading Queries...');
    try {
        const url = `https://${window.FUNCURL}/api/MDEHuntManager?code=${window.FUNCKEY}`;
        const payload = { TenantId: tenantId, Function: 'GetQueries' };
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 60000);
        const res = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload),
            signal: controller.signal
        });
        clearTimeout(timeoutId);
        const result = await res.json();
        // Accept both { Queries: [...] } and { value: [...] } and fallback to []
        let queries = [];
        if (Array.isArray(result.Queries)) {
            queries = result.Queries;
        } else if (Array.isArray(result.value)) {
            queries = result.value;
        } else if (Array.isArray(result.queries)) {
            queries = result.queries;
        }        allQueries = queries;
        renderQueriesTable(allQueries);
    } catch (error) {
        allQueries = [];
        renderQueriesTable(allQueries);
    } finally {
        window.hideContentLoading();
    }
}

function renderQueriesTable(queriesRaw) {
    // If backend response is an object with a 'Queries' array, use that
    if (queriesRaw && !Array.isArray(queriesRaw) && queriesRaw.Queries) {
        queriesRaw = queriesRaw.Queries;
    }
    // Only show FileName, LastModified, and Size columns
    const columns = [
        { id: 'FileName', name: 'File Name', width: '40%', sort: true },
        { id: 'LastModified', name: 'Last Modified', width: '35%', sort: true },
        { id: 'Size', name: 'Size (bytes)', width: '15%', sort: true },
        { name: 'Actions', width: '10%',
          formatter: (_, row) => {
            const fileName = row.cells[0].data;
            return gridjs.html(`
                <button class='cta-button' onclick='window.runQueryNow("${fileName}")'>Run Now</button>
                <button class='cta-button undo-button' style='margin-left:0.5rem;' onclick='window.removeQuery("${fileName}")'>Remove</button>
            `);
          }
        }
    ];
    const queries = (queriesRaw || []).map(row => [row.FileName || '', row.LastModified || '', row.Size || '']);
    if (queriesGrid) queriesGrid.destroy();
    const queriesTableContainer = document.getElementById('queries-table');
    queriesGrid = new gridjs.Grid({
        columns: columns,
        data: queries,
        search: true,
        sort: true,
        resizable: true,
        pagination: { enabled: true, limit: 20, summary: true },
        autoWidth: true,
        width: '100%'
    }).render(queriesTableContainer);
}

// Modal functions are now handled in the HTML template with CodeMirror integration
// These are kept as fallbacks in case the HTML overrides don't work
function showAddQueryModal() {
    const modal = document.getElementById('addQueryModal');
    if (modal) {
        modal.style.display = 'flex';
    }
}

function hideAddQueryModal() {
    const modal = document.getElementById('addQueryModal');
    if (modal) {
        modal.style.display = 'none';
    }
    
    const queryNameInput = document.getElementById('newQueryName');
    if (queryNameInput) {
        queryNameInput.value = '';
    }
}
async function saveNewQuery() {
    const saveBtn = document.getElementById('saveQueryBtn');
    const saveText = document.getElementById('saveQueryBtnText');
    const spinner = document.getElementById('saveQuerySpinner');
    if (saveBtn && spinner && saveText) {
        saveBtn.disabled = true;
        spinner.style.display = 'inline-block';
        saveText.textContent = 'Saving...';
    }
    try {
        const tenantId = getTenantId();
        const queryName = document.getElementById('newQueryName').value.trim();
        let queryText = '';
        
        // Wait for CodeMirror to be ready
        let codeMirrorIsReady = false;
        if (typeof window.isCodeMirrorReady === 'function') {
            codeMirrorIsReady = window.isCodeMirrorReady();
        } else {
            // Fallback check if isCodeMirrorReady function is not available yet
            codeMirrorIsReady = window.codeMirrorKqlEditor && 
                               typeof window.codeMirrorKqlEditor.getValue === 'function';
        }
        
        if (codeMirrorIsReady) {
            try {
                queryText = window.codeMirrorKqlEditor.getValue().trim();
            } catch (error) {
                console.error('Error getting CodeMirror Editor value:', error);
                alert('Query editor error. Please refresh and try again.');
                return;
            }
        } else {
            // Helpful error message for troubleshooting
            console.warn('CodeMirror Editor not ready. State:', {
                exists: !!window.codeMirrorKqlEditor,
                hasGetValue: window.codeMirrorKqlEditor && typeof window.codeMirrorKqlEditor.getValue === 'function',
                isReadyFuncExists: typeof window.isCodeMirrorReady === 'function'
            });
            alert('Query editor is not ready. Please wait a moment and try again.');
            return;
        }
        
        // Debug logging
        console.log('saveNewQuery:', { tenantId, queryName, queryText });
        if (!tenantId || !queryName || !queryText) {
            alert('Please fill in all fields.');
            return;
        }
        showLoadingIndicator('Saving Query...');        try {
            const url = `https://${window.FUNCURL}/api/MDEHuntManager?code=${window.FUNCKEY}`;
            const payload = { TenantId: tenantId, Function: 'AddQuery', QueryName: queryName, Query: queryText };
            const controller = new AbortController();
            const timeoutId = setTimeout(() => controller.abort(), 60000);
            const res = await fetch(url, {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify(payload),
                signal: controller.signal
            });
            clearTimeout(timeoutId);
            await res.json();
            // Only hide modal and reload queries if successful
            hideAddQueryModal();
            loadQueries();
        } catch (error) {
            alert('Error saving query: ' + error.message);
        } finally {
            window.hideContentLoading();
        }
    } finally {
        if (saveBtn && spinner && saveText) {
            saveBtn.disabled = false;
            spinner.style.display = 'none';
            saveText.textContent = 'Save';
        }
    }
}

window.removeQuery = async function(queryName) {
    const tenantId = getTenantId();
    if (!tenantId || !queryName) return;
    if (!confirm(`Remove query "${queryName}"?`)) return;
    window.showContentLoading('Removing Query...');
    try {
        const url = `https://${window.FUNCURL}/api/MDEHuntManager?code=${window.FUNCKEY}`;
        const payload = { TenantId: tenantId, Function: 'UndoQuery', QueryName: queryName };
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 60000);
        const res = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload),
            signal: controller.signal
        });
        clearTimeout(timeoutId);
        await res.json();
        loadQueries();
    } catch (error) {
        alert('Error removing query: ' + error.message);
    } finally {
        window.hideContentLoading();
    }
}

window.runQueryNow = async function(queryName) {
    const tenantId = getTenantId();
    if (!tenantId || !queryName) {
        console.warn('Missing required parameters:', { tenantId, queryName });
        return;
    }
      console.log('Running query:', { queryName, tenantId });
    window.showContentLoading('Running Query...');
    
    try {
        const url = `https://${window.FUNCURL}/api/MDEHunter?code=${window.FUNCKEY}`;
        // Only send FileName and TenantId as per requirement
        const payload = { TenantId: tenantId, FileName: queryName };
        
        console.log('Sending request to:', url);
        console.log('Payload:', payload);
        
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 60000);
        
        const res = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload),
            signal: controller.signal
        });
        
        clearTimeout(timeoutId);
        
        console.log('Response status:', res.status);
        console.log('Response headers:', [...res.headers.entries()]);
        
        if (!res.ok) {
            throw new Error(`HTTP error! status: ${res.status}`);
        }
        
        const responseText = await res.text();
        console.log('Raw response text:', responseText);
        
        let result;
        try {
            result = JSON.parse(responseText);
            console.log('Parsed result:', result);
            console.log('Result type:', typeof result);
            console.log('Result keys:', result ? Object.keys(result) : 'null/undefined');
        } catch (parseError) {
            console.error('JSON parse error:', parseError);
            throw new Error(`Invalid JSON response: ${parseError.message}`);
        }
        
        // Show results in the dynamic table
        if (typeof window.showQueryResults === 'function') {
            console.log('Calling showQueryResults...');
            window.showQueryResults(result, queryName);
        } else {
            console.error('showQueryResults function not available');
            // Fallback to alert if function not available
            alert('Query completed. Check console for results.');
            console.log('Query results:', JSON.stringify(result, null, 2));
        }
        
    } catch (error) {
        console.error('Error running query:', error);
        console.error('Error details:', {
            name: error.name,
            message: error.message,
            stack: error.stack
        });
        
        // Show error in the results container
        const resultsContainer = document.getElementById('results-container');
        const resultsInfo = document.getElementById('results-info');
        const resultsTableContainer = document.getElementById('results-table');
        
        if (resultsContainer && resultsInfo && resultsTableContainer) {
            // Clear any existing grid first
            if (window.resultsGrid) {
                try {
                    window.resultsGrid.destroy();
                } catch (e) {
                    console.warn('Error destroying grid during error handling:', e);
                }
                window.resultsGrid = null;
            }
            
            resultsInfo.textContent = `Query: ${queryName} | Error occurred`;
            resultsTableContainer.innerHTML = `
                <div style="padding: 20px; text-align: center; color: #ff6b6b;">
                    <strong>Error running query:</strong><br>
                    ${error.message}<br>
                    <small style="color: #999;">Check browser console for detailed logs</small>
                </div>
            `;
            resultsContainer.style.display = 'block';
            
            try {
                resultsContainer.scrollIntoView({ behavior: 'smooth', block: 'start' });
            } catch (scrollError) {
                console.warn('Error scrolling to results:', scrollError);
            }
        } else {
            // Fallback to alert            alert('Error running query: ' + error.message + '\nCheck browser console for details.');
        }
    } finally {
        window.hideContentLoading();
    }
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
            window.updatePlatformLoadingProgress('Loading tenants for Hunt Manager...', 30);
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

