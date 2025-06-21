// Global variables for query management
// Last updated: 2025-06-20 17:30 - Cache busting update - no showLoadingIndicator references should exist
console.log('=== HuntManager.js loaded ===', new Date().toISOString());
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
    if (addQueryBtn) addQueryBtn.onclick = showAddQueryModal;    // Modal buttons - with defensive event handler setup
    const saveQueryBtn = document.getElementById('saveQueryBtn');
    const cancelQueryBtn = document.getElementById('cancelQueryBtn');
    
    // Remove any existing event listeners to prevent conflicts
    if (saveQueryBtn) {
        saveQueryBtn.onclick = null;
        saveQueryBtn.removeEventListener('click', saveNewQuery);
        saveQueryBtn.addEventListener('click', function(e) {
            e.preventDefault();
            e.stopPropagation();
            console.log('Save button clicked via addEventListener');
            saveNewQuery();
        });
        console.log('Save button event listener attached');
    }
    
    if (cancelQueryBtn) {
        cancelQueryBtn.onclick = hideAddQueryModal;
    }

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
        const url = '/api/hunt/queries';
        const payload = { TenantId: tenantId, Function: 'GetQueries' };
        const res = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
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
    }    // Only show FileName, LastModified, and Size columns
    const columns = [
        { id: 'FileName', name: 'File Name', width: '35%', sort: true },
        { id: 'LastModified', name: 'Last Modified', width: '30%', sort: true },
        { id: 'Size', name: 'Size (bytes)', width: '15%', sort: true },
        { name: 'Actions', width: '20%',
          formatter: (_, row) => {
            const fileName = row.cells[0].data;            return gridjs.html(`
                <button class='cta-button' onclick='window.runQueryNow("${fileName}")' style='margin-right: 0.5rem;'>Run Now</button>
                <button class='cta-button edit-button' onclick='window.editQuery("${fileName}")' style='margin-right: 0.5rem;'>Edit</button>
                <button class='cta-button undo-button' onclick='window.removeQuery("${fileName}")'>Remove</button>
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
    console.log('=== saveNewQuery called ===');
    
    // Add debug info about the environment
    console.log('Window functions available:', {
        showContentLoading: typeof window.showContentLoading,
        hideContentLoading: typeof window.hideContentLoading,
        showLoadingIndicator: typeof window.showLoadingIndicator // This should be undefined
    });
    
    // Check for any global pollution
    if (typeof showLoadingIndicator !== 'undefined') {
        console.error('WARNING: showLoadingIndicator is still defined globally!', showLoadingIndicator);
    }
    
    // Defensive function availability checks
    const showContentLoading = window.showContentLoading || function(msg) { console.log('Loading:', msg); };
    const hideContentLoading = window.hideContentLoading || function() { console.log('Loading complete'); };
    
    const saveBtn = document.getElementById('saveQueryBtn');
    const saveText = document.getElementById('saveQueryBtnText');
    const spinner = document.getElementById('saveQuerySpinner');

    if (saveBtn && spinner && saveText) {
        saveBtn.disabled = true;
        spinner.style.display = 'inline-block';
        saveText.textContent = isEditMode ? 'Updating...' : 'Saving...';
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
        }        // Debug logging
        const actionVerb = isEditMode ? 'updating' : 'saving';
        console.log(`${actionVerb} query:`, { tenantId, queryName, queryText });
        
        if (!tenantId || !queryName || !queryText) {
            alert('Please fill in all fields.');
            return;
        }        
        showContentLoading(isEditMode ? 'Updating Query...' : 'Saving Query...');
        
        const url = '/api/hunt/queries';
        const functionName = isEditMode ? 'UpdateQuery' : 'AddQuery';
        const payload = { TenantId: tenantId, Function: functionName, QueryName: queryName, Query: queryText };
        
        console.log('Save payload:', payload);
        
        const res = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
        
        if (!res.ok) {
            throw new Error(`HTTP error! status: ${res.status}`);
        }
          const result = await res.json();
        console.log('Save result:', result);
        
        // Check if the save operation was successful
        let isSuccess = false;
        if (result && result.Status === 'Success') {
            isSuccess = true;
        } else if (result && result.Message && result.Message.includes('successfully')) {
            isSuccess = true;
        } else if (result && result.FileName) {
            // If we got a FileName back, it's likely successful
            isSuccess = true;
        }
        
        if (isSuccess) {
            // Only hide modal and reload queries if successful
            hideAddQueryModal();
            loadQueries();
            
            // Show success message
            const action = isEditMode ? 'updated' : 'saved';
            console.log(`Query "${queryName}" ${action} successfully`);
            
            // Show user-friendly success notification
            if (result.Message) {
                alert(`Success: ${result.Message}`);
            } else {
                alert(`Query "${queryName}" ${action} successfully!`);
            }
        } else {
            // Handle error case
            const errorMsg = result.Message || result.error || 'Unknown error occurred';
            throw new Error(errorMsg);
        }
        
    } catch (error) {
        console.error('Error saving query:', error);
        const actionVerb = isEditMode ? 'updating' : 'saving';
        alert(`Error ${actionVerb} query: ${error.message}`);    } finally {
        hideContentLoading();
        
        if (saveBtn && spinner && saveText) {
            saveBtn.disabled = false;
            spinner.style.display = 'none';
            saveText.textContent = isEditMode ? 'Update Query' : 'Save';
        }
    }
}

window.removeQuery = async function(queryName) {
    const tenantId = getTenantId();
    if (!tenantId || !queryName) return;    if (!confirm(`Remove query "${queryName}"?`)) return;
    window.showContentLoading('Removing Query...');
    
    try {
        const url = '/api/hunt/queries';
        const payload = { TenantId: tenantId, Function: 'UndoQuery', QueryName: queryName };        const res = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
        
        if (!res.ok) {
            throw new Error(`HTTP error! status: ${res.status}`);
        }
        
        const result = await res.json();
        console.log('Remove query result:', result);
        
        // Check if the remove operation was successful
        let isSuccess = false;
        if (result && result.Status === 'Success') {
            isSuccess = true;
        } else if (result && result.Message && result.Message.includes('successfully')) {
            isSuccess = true;
        }
        
        if (isSuccess) {
            loadQueries();
            
            // Show success message
            if (result.Message) {
                alert(`Success: ${result.Message}`);
            } else {
                alert(`Query "${queryName}" removed successfully!`);
            }
        } else {
            // Handle error case
            const errorMsg = result.Message || result.error || 'Unknown error occurred';
            throw new Error(errorMsg);
        }
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
    window.showContentLoading('Running Query...');    try {
        const url = '/api/hunt/run';
        // Send QueryName and TenantId as expected by Flask route
        const payload = { TenantId: tenantId, QueryName: queryName };
        
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

// ==================== KQL AI ANALYSIS FUNCTIONALITY ====================

// Global variable to store current analysis data
let currentHuntKqlAnalysisData = null;

// Function to analyze KQL query with AI - HuntManager version
window.analyzeHuntKqlQuery = async function() {
    console.log('=== analyzeHuntKqlQuery called ===');
      // Clear any existing analysis data first
    currentHuntKqlAnalysisData = null;
    console.log('Cleared existing hunt analysis data');
    
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
    
    console.log('Analyzing Hunt KQL query:', kqlQuery.substring(0, 100) + '...');
    
    // Show KQL analysis modal
    console.log('About to call showHuntKqlAnalysisModal()...');
    try {
        showHuntKqlAnalysisModal();
        console.log('showHuntKqlAnalysisModal() call completed successfully');
    } catch (modalError) {
        console.error('Error calling showHuntKqlAnalysisModal():', modalError);
    }
      try {
        // Call the new Flask route for AI analysis
        const chatUrl = '/api/hunt/analyze';
        
        // Prepare context with the KQL query - specific for threat hunting
        const context = `KQL HUNT QUERY TO ANALYZE:\n\n${kqlQuery}\n\nPLEASE ANALYZE:\n- Query purpose and hunting logic\n- Data sources and tables used\n- Filtering, joins, and aggregation techniques\n- Threat hunting value and detection capabilities\n- Security insights and IOCs\n- Performance considerations for large datasets\n- Potential improvements and optimizations\n- Similar threat hunting scenarios`;
        
        // Simplified payload for Flask route
        const chatPayload = {
            query: kqlQuery,
            message: "Analyze this KQL (Kusto Query Language) threat hunting query and provide a comprehensive explanation of its hunting methodology, detection capabilities, and security value.",
            system_prompt: "You are an expert in KQL (Kusto Query Language) and cybersecurity threat hunting. Analyze the provided KQL hunt query and explain: 1) What threats or behaviors the query hunts for, 2) Step-by-step breakdown of the hunting logic, 3) Data sources and security tables used, 4) Filtering criteria and detection techniques, 5) Security insights and threat indicators, 6) Hunting effectiveness and coverage, 7) Performance considerations for enterprise environments, 8) Potential improvements or variants for better detection. Focus on the security and threat hunting aspects, providing practical insights for SOC analysts and threat hunters.",
            context: context
        };

        console.log('Calling MDEAutoChat API for Hunt KQL analysis...');
        const chatResponse = await fetch(chatUrl, {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify(chatPayload)
        });

        if (!chatResponse.ok) {
            throw new Error(`HTTP error! status: ${chatResponse.status}`);
        }

        const chatResult = await chatResponse.json();
        console.log('Hunt KQL analysis completed');
        console.log('Chat result:', chatResult);

        // Extract analysis text - focus on "Response" field only
        let analysisText = '';
        
        console.log('Processing chatResult for Hunt KQL:', typeof chatResult, chatResult);
        
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
                console.log('Extracted Response field from Hunt KQL chatResult');
            } else if (chatResult.response && typeof chatResult.response === 'string') {
                analysisText = chatResult.response;
                console.log('Extracted response field from Hunt KQL chatResult');
            } else if (chatResult.message && typeof chatResult.message === 'string') {
                analysisText = chatResult.message;
                console.log('Extracted message field from Hunt KQL chatResult');
            } else if (chatResult.analysis && typeof chatResult.analysis === 'string') {
                analysisText = chatResult.analysis;
                console.log('Extracted analysis field from Hunt KQL chatResult');
            } else {
                console.warn('No recognizable response field found in Hunt KQL chatResult:', chatResult);
                console.warn('Available fields:', Object.keys(chatResult || {}));
                analysisText = 'Analysis completed but no readable response field was found. Please check the console for details.';
            }
        } else if (typeof chatResult === 'string' && analysisText === '') {
            analysisText = chatResult;
            console.log('Using Hunt KQL chatResult as string directly');
        } else {
            console.warn('Unexpected Hunt KQL chatResult type:', typeof chatResult, chatResult);
            analysisText = 'Analysis completed but response format was unexpected. Please check the console for details.';
        }

        // Store the analysis data
        currentHuntKqlAnalysisData = {
            query: kqlQuery,
            analysis: analysisText,
            timestamp: new Date().toISOString()
        };

        // Display the results
        displayHuntKqlAnalysisResults(currentHuntKqlAnalysisData);

    } catch (error) {
        console.error('Error performing Hunt KQL analysis:', error);
        displayHuntKqlAnalysisError(error.message);
    }
}

// Function to show Hunt KQL analysis modal - DYNAMIC APPROACH
function showHuntKqlAnalysisModal() {
    console.log('=== showHuntKqlAnalysisModal called - DYNAMIC APPROACH ===');
    
    // Remove any existing modal
    const existingModal = document.getElementById('dynamicHuntKqlModal');
    if (existingModal) {
        existingModal.remove();
    }
    
    // Create modal dynamically
    const modal = document.createElement('div');
    modal.id = 'dynamicHuntKqlModal';
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
            <h3 style="margin: 0; color: #00ff41; font-size: 1.3rem;">🤖 Hunt KQL Query Analysis</h3>
            <div style="display: flex; align-items: center; gap: 10px;">
                <button id="dynamicHuntDownloadBtn" style="display: none; background: #00ff41; color: #101c11; border: none; padding: 8px 16px; border-radius: 4px; cursor: pointer;">📥 Download</button>
                <span id="dynamicHuntCloseBtn" style="color: #00ff41; font-size: 28px; font-weight: bold; cursor: pointer; padding: 0 5px;">&times;</span>
            </div>
        </div>
        <div style="flex: 1; overflow-y: auto; padding: 20px 25px;">
            <div id="dynamicHuntLoadingDiv" style="display: flex; flex-direction: column; align-items: center; justify-content: center; padding: 40px;">
                <div style="border: 3px solid #00ff41; border-radius: 50%; border-top: 3px solid transparent; width: 40px; height: 40px; animation: spin 1s linear infinite;"></div>
                <p style="margin-top: 20px; color: #7fff7f;">Analyzing hunt query...</p>
            </div>
            <div id="dynamicHuntDataDiv" style="display: none; line-height: 1.6;"></div>
            <div id="dynamicHuntErrorDiv" style="display: none; color: #ff6b6b; padding: 20px; background: rgba(255, 0, 0, 0.1); border-radius: 4px;"></div>
        </div>
        <div style="padding: 15px 25px; border-top: 1px solid #00ff41; text-align: right;">
            <button id="dynamicHuntCloseBtn2" style="background: #666; color: #fff; border: none; padding: 10px 20px; border-radius: 4px; cursor: pointer;">Close</button>
        </div>
    `;
    
    // Add spinner animation if not already present
    if (!document.querySelector('style[data-hunt-spinner]')) {
        const style = document.createElement('style');
        style.setAttribute('data-hunt-spinner', 'true');
        style.textContent = `
            @keyframes spin {
                0% { transform: rotate(0deg); }
                100% { transform: rotate(360deg); }
            }
        `;
        document.head.appendChild(style);
    }
    
    modal.appendChild(container);
    document.body.appendChild(modal);
    
    // Add event listeners
    const closeModal = () => {
        modal.remove();
        document.body.style.overflow = '';
    };
    
    document.getElementById('dynamicHuntCloseBtn').onclick = closeModal;
    document.getElementById('dynamicHuntCloseBtn2').onclick = closeModal;
    modal.onclick = (e) => {
        if (e.target === modal) closeModal();
    };
    
    // Prevent body scroll
    document.body.style.overflow = 'hidden';
    
    console.log('Dynamic Hunt modal created and displayed');
    return modal;
}

// Function to display Hunt KQL analysis results
function displayHuntKqlAnalysisResults(analysisData) {
    console.log('=== displayHuntKqlAnalysisResults called ===');
    console.log('Hunt Analysis data:', analysisData);
    
    const loadingDiv = document.getElementById('dynamicHuntLoadingDiv');
    const dataDiv = document.getElementById('dynamicHuntDataDiv');
    const errorDiv = document.getElementById('dynamicHuntErrorDiv');
    const downloadBtn = document.getElementById('dynamicHuntDownloadBtn');
    
    console.log('Dynamic Hunt modal elements found:', {
        loadingDiv: !!loadingDiv,
        dataDiv: !!dataDiv,
        errorDiv: !!errorDiv,
        downloadBtn: !!downloadBtn
    });
    
    if (loadingDiv) {
        loadingDiv.style.display = 'none';
        console.log('Hidden hunt loading div');
    }
    if (errorDiv) {
        errorDiv.style.display = 'none';
        console.log('Hidden hunt error div');
    }
    
    if (dataDiv) {
        console.log('Formatting hunt analysis text...');
        // Format the analysis text with better structure
        const formattedAnalysis = formatHuntKqlAnalysisText(analysisData.analysis, analysisData.query);
        console.log('Formatted hunt analysis length:', formattedAnalysis.length);
        dataDiv.innerHTML = formattedAnalysis;
        dataDiv.style.display = 'block';
        console.log('Displayed hunt analysis in data div');
    } else {
        console.error('Hunt data div not found!');
    }
    
    if (downloadBtn) {
        downloadBtn.style.display = 'inline-block';
        downloadBtn.onclick = () => downloadHuntKqlAnalysis();
        console.log('Showed hunt download button');
    }
    
    console.log('=== displayHuntKqlAnalysisResults completed ===');
}

// Function to display Hunt KQL analysis error
function displayHuntKqlAnalysisError(errorMessage) {
    console.log('=== displayHuntKqlAnalysisError called ===');
    console.log('Hunt Error message:', errorMessage);
    
    const loadingDiv = document.getElementById('dynamicHuntLoadingDiv');
    const dataDiv = document.getElementById('dynamicHuntDataDiv');
    const errorDiv = document.getElementById('dynamicHuntErrorDiv');
    
    if (loadingDiv) {
        loadingDiv.style.display = 'none';
        console.log('Hidden hunt loading div');
    }
    if (dataDiv) {
        dataDiv.style.display = 'none';
        console.log('Hidden hunt data div');
    }
    if (errorDiv) {
        errorDiv.innerHTML = `<strong>Error analyzing hunt query:</strong><br>${errorMessage}`;
        errorDiv.style.display = 'block';
        console.log('Displayed hunt error message');
    }
}

// Function to format Hunt KQL analysis text with better HTML structure
function formatHuntKqlAnalysisText(analysisText, originalQuery) {
    // Ensure analysisText is a string
    if (typeof analysisText !== 'string') {
        analysisText = String(analysisText || '');
    }

    // Convert markdown-style formatting to HTML
    let formattedText = analysisText
        .replace(/\*\*(.*?)\*\*/g, '<strong>$1</strong>')
        .replace(/\*(.*?)\*/g, '<em>$1</em>')
        .replace(/`([^`]+)`/g, '<code style="background: #2a4a2a; padding: 2px 4px; border-radius: 3px; color: #7fff7f;">$1</code>')
        .replace(/```([\s\S]*?)```/g, '<pre style="background: #2a4a2a; padding: 15px; border-radius: 5px; border-left: 4px solid #00ff41; margin: 10px 0; overflow-x: auto; color: #7fff7f;"><code>$1</code></pre>')
        .replace(/^#{1,3}\s+(.+)$/gm, '<h3 style="color: #00ff41; margin: 20px 0 10px 0; border-bottom: 1px solid #00ff41; padding-bottom: 5px;">$1</h3>')
        .replace(/^-\s+(.+)$/gm, '<li style="margin: 5px 0; color: #7fff7f;">$1</li>')
        .replace(/(\n|^)(\d+\.)\s+(.+)/g, '$1<div style="margin: 8px 0;"><strong style="color: #00ff41;">$2</strong> $3</div>')
        .replace(/\n/g, '<br>');

    // Wrap consecutive <li> elements in <ul>
    formattedText = formattedText.replace(/(<li[^>]*>.*?<\/li>(?:\s*<br>\s*<li[^>]*>.*?<\/li>)*)/g, '<ul style="margin: 10px 0; padding-left: 20px;">$1</ul>');
    
    // Remove <br> tags inside <ul> elements
    formattedText = formattedText.replace(/(<ul[^>]*>)(.*?)(<\/ul>)/g, function(match, openTag, content, closeTag) {
        return openTag + content.replace(/<br>/g, '') + closeTag;
    });

    return `
        <div style="font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif; line-height: 1.6; color: #7fff7f;">
            <div style="background: #2a4a2a; padding: 15px; border-radius: 5px; margin-bottom: 20px; border-left: 4px solid #00ff41;">
                <h4 style="color: #00ff41; margin: 0 0 10px 0;">🎯 Hunt Query Analyzed</h4>
                <pre style="background: #1a3a1a; padding: 10px; border-radius: 3px; margin: 0; overflow-x: auto; white-space: pre-wrap; color: #7fff7f;"><code>${originalQuery}</code></pre>
                <span style="margin-left: 0.5rem; color: #00ff41;">${new Date(currentHuntKqlAnalysisData.timestamp).toLocaleString()}</span>
            </div>
            <div style="max-height: 400px; overflow-y: auto; padding-right: 10px;">
                ${formattedText}
            </div>
        </div>
    `;
}

// Function to download Hunt KQL analysis
function downloadHuntKqlAnalysis() {
    if (!currentHuntKqlAnalysisData) {
        alert('No hunt analysis data available to download.');
        return;
    }

    const content = `HUNT KQL QUERY ANALYSIS REPORT
Generated: ${new Date(currentHuntKqlAnalysisData.timestamp).toLocaleString()}

=== HUNT QUERY ===
${currentHuntKqlAnalysisData.query}

=== AI ANALYSIS ===
${currentHuntKqlAnalysisData.analysis}

=== METADATA ===
Analysis Type: Threat Hunting KQL Query Analysis
Timestamp: ${currentHuntKqlAnalysisData.timestamp}
Generated by: MDEAutoApp Hunt Manager`;

    const blob = new Blob([content], { type: 'text/plain' });
    const url = window.URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.style.display = 'none';
    a.href = url;
    a.download = `hunt-kql-analysis-${new Date().getTime()}.txt`;
    document.body.appendChild(a);
    a.click();
    window.URL.revokeObjectURL(url);
    document.body.removeChild(a);
}

// Global variable to track edit mode
let isEditMode = false;
let editingQueryName = null;

window.editQuery = async function(queryName) {
    const tenantId = getTenantId();
    if (!tenantId || !queryName) {
        console.error('Missing required parameters for editQuery:', { tenantId, queryName });
        return;
    }
    
    console.log('Editing query:', { queryName, tenantId });
    window.showContentLoading('Loading Query...');
    
    try {        // Fetch the query content using GetQuery subfunction
        const url = '/api/hunt/queries';
        const payload = { TenantId: tenantId, Function: 'GetQuery', QueryName: queryName };
        
        console.log('Fetching query content with payload:', payload);
        
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 60000);
        
        const res = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload),
            signal: controller.signal
        });
        
        clearTimeout(timeoutId);
        
        if (!res.ok) {
            throw new Error(`HTTP error! status: ${res.status}`);
        }
        
        const result = await res.json();
        console.log('Query content result:', result);
        
        // Extract query content from the response
        let queryContent = '';
        if (result && typeof result.content === 'string') {
            queryContent = result.content;
        } else if (result && typeof result.Content === 'string') {
            queryContent = result.Content;
        } else if (result && typeof result.query === 'string') {
            queryContent = result.query;
        } else if (result && typeof result.Query === 'string') {
            queryContent = result.Query;
        } else if (typeof result === 'string') {
            queryContent = result;
        } else {
            console.warn('Unknown query content format:', result);
            queryContent = JSON.stringify(result, null, 2);
        }
        
        // Set edit mode variables
        isEditMode = true;
        editingQueryName = queryName;
        
        // Show the modal in edit mode
        showEditQueryModal(queryName, queryContent);
        
    } catch (error) {
        console.error('Error fetching query for edit:', error);
        alert('Error loading query for editing: ' + error.message);
    } finally {
        window.hideContentLoading();
    }
}

function showEditQueryModal(queryName, queryContent) {
    console.log('showEditQueryModal called with:', { queryName, queryContent: queryContent.substring(0, 100) + '...' });
    
    // Show the modal
    const modal = document.getElementById('addQueryModal');
    if (modal) {
        modal.style.display = 'flex';
        modal.classList.add('edit-mode'); // Add edit mode class
        console.log('Modal displayed for editing');
    } else {
        console.error('Modal element not found');
        return;
    }
    
    // Update modal title for edit mode
    const modalTitle = modal.querySelector('h3');
    if (modalTitle) {
        modalTitle.textContent = 'Edit Query';
        modalTitle.style.color = '#ffa500'; // Orange color for edit mode
    }
    
    // Populate the query name input and make it read-only
    const queryNameInput = document.getElementById('newQueryName');
    if (queryNameInput) {
        queryNameInput.value = queryName;
        queryNameInput.readOnly = true;
        queryNameInput.style.backgroundColor = '#333';
        queryNameInput.style.color = '#ccc';
    }
    
    // Update save button text
    const saveBtn = document.getElementById('saveQueryBtn');
    const saveText = document.getElementById('saveQueryBtnText');
    if (saveBtn && saveText) {
        saveBtn.disabled = true;
        saveText.textContent = 'Loading Editor...';
    }
      // Wait for modal to be visible before initializing CodeMirror
    setTimeout(() => {
        console.log('Initializing CodeMirror for edit mode...');
        const editor = initCodeMirrorKqlEditor();
        if (editor) {
            // Set the query content in the editor
            editor.setValue(queryContent);
            console.log('Query content loaded in editor');
            
            // Update save button
            if (saveBtn && saveText) {
                saveBtn.disabled = false;
                saveText.textContent = 'Update Query';
            }
              // Set up AI robot button event listener for edit mode
            const robotBtn = document.getElementById('analyzeHuntKqlBtn');
            if (robotBtn) {
                // Remove any existing event listeners first
                robotBtn.onclick = null;
                
                robotBtn.onclick = function(e) {
                    console.log('Robot button clicked in edit mode!');
                    e.preventDefault();
                    e.stopPropagation();
                    window.analyzeHuntKqlQuery();
                };
                console.log('Hunt AI robot button event listener attached for edit mode');
            } else {
                console.warn('Hunt AI robot button not found in edit mode');
            }
        } else {
            console.error('Failed to initialize CodeMirror editor');
            if (saveText) saveText.textContent = 'Editor Error';
        }
    }, 100);
}

// Debug function to test robot button functionality
window.testRobotButton = function() {
    console.log('=== Testing Robot Button ===');
    
    // Check if button exists
    const robotBtn = document.getElementById('analyzeHuntKqlBtn');
    console.log('Robot button found:', !!robotBtn);
    if (robotBtn) {
        console.log('Robot button onclick:', robotBtn.onclick);
        console.log('Robot button style.display:', robotBtn.style.display);
        console.log('Robot button visible:', robotBtn.offsetWidth > 0 && robotBtn.offsetHeight > 0);
    }
    
    // Check if function exists
    console.log('analyzeHuntKqlQuery function exists:', typeof window.analyzeHuntKqlQuery);
    
    // Check CodeMirror
    console.log('CodeMirror editor exists:', !!window.codeMirrorKqlEditor);
    if (window.codeMirrorKqlEditor) {
        try {
            const content = window.codeMirrorKqlEditor.getValue();
            console.log('CodeMirror content length:', content.length);
            console.log('CodeMirror content preview:', content.substring(0, 50));
        } catch (e) {
            console.error('Error getting CodeMirror content:', e);
        }
    }
    
    // Check modal
    const modal = document.getElementById('addQueryModal');
    console.log('Modal found:', !!modal);
    if (modal) {
        console.log('Modal display:', modal.style.display);
        console.log('Modal visible:', modal.offsetWidth > 0 && modal.offsetHeight > 0);
    }
    
    // Try calling the function directly
    if (typeof window.analyzeHuntKqlQuery === 'function') {
        console.log('Attempting to call analyzeHuntKqlQuery directly...');
        try {
            window.analyzeHuntKqlQuery();
        } catch (e) {
            console.error('Error calling analyzeHuntKqlQuery:', e);
        }
    }
}

// Add event delegation for robot button as backup
document.addEventListener('click', function(e) {
    if (e.target && e.target.id === 'analyzeHuntKqlBtn') {
        console.log('Robot button clicked via event delegation!');
        e.preventDefault();
        e.stopPropagation();
        
        if (typeof window.analyzeHuntKqlQuery === 'function') {
            console.log('Calling analyzeHuntKqlQuery via event delegation...');
            window.analyzeHuntKqlQuery();
        } else {
            console.error('analyzeHuntKqlQuery function not available via event delegation');
            alert('Robot button clicked but analysis function not available. Check console.');
        }
    }
});

// Update the hideAddQueryModal function to handle edit mode cleanup
const originalHideAddQueryModal = window.hideAddQueryModal;
window.hideAddQueryModal = function() {
    // Call the original function
    if (originalHideAddQueryModal) {
        originalHideAddQueryModal();
    } else {
        // Fallback implementation
        const modal = document.getElementById('addQueryModal');
        if (modal) {
            modal.style.display = 'none';
        }
        
        const queryNameInput = document.getElementById('newQueryName');
        if (queryNameInput) {
            queryNameInput.value = '';
        }
        
        if (window.codeMirrorKqlEditor && typeof window.codeMirrorKqlEditor.setValue === 'function') {
            try {
                window.codeMirrorKqlEditor.setValue('');
            } catch (error) {
                console.error('Error clearing CodeMirror:', error);
            }
        }
    }
    
    // Reset edit mode state
    isEditMode = false;
    editingQueryName = null;
    
    // Reset modal appearance
    const modal = document.getElementById('addQueryModal');
    if (modal) {
        modal.classList.remove('edit-mode'); // Remove edit mode class
    }
    
    // Reset modal title
    const modalTitle = modal ? modal.querySelector('h3') : null;
    if (modalTitle) {
        modalTitle.textContent = 'Add New Query';
        modalTitle.style.color = '#7fff7f'; // Reset to default color
    }
    
    // Reset query name input
    const queryNameInput = document.getElementById('newQueryName');
    if (queryNameInput) {
        queryNameInput.readOnly = false;
        queryNameInput.style.backgroundColor = '#101c11';
        queryNameInput.style.color = '#7fff7f';
    }
    
    // Reset save button text
    const saveText = document.getElementById('saveQueryBtnText');
    if (saveText) {
        saveText.textContent = 'Save';
    }
};

// Test function to verify hunt query save functionality
window.testHuntSave = async function(tenantId = 'test-tenant-123', queryName = 'BrowserTestQuery', queryText = 'DeviceInfo | take 5') {
    console.log('=== Testing Hunt Query Save Functionality ===');
    
    try {
        const url = '/api/hunt/queries';
        const payload = { 
            TenantId: tenantId, 
            Function: 'AddQuery', 
            QueryName: queryName, 
            Query: queryText 
        };
        
        console.log('Test payload:', payload);
        
        const res = await fetch(url, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(payload)
        });
        
        console.log('Response status:', res.status);
        console.log('Response headers:', [...res.headers.entries()]);
        
        if (!res.ok) {
            throw new Error(`HTTP error! status: ${res.status}`);
        }
        
        const result = await res.json();
        console.log('Save result:', result);
        console.log('Result type:', typeof result);
        console.log('Result keys:', result ? Object.keys(result) : 'null/undefined');
        
        // Check success
        if (result && result.Status === 'Success') {
            console.log('✅ SUCCESS: Query saved successfully!');
            console.log('File name:', result.FileName);
            console.log('Message:', result.Message);
            return true;
        } else {
            console.log('❌ FAILED: Unexpected response format');
            return false;
        }
        
    } catch (error) {
        console.error('❌ ERROR:', error);
        return false;
    }
};

// Fallback save function for button onclick (in case of event handler conflicts)
window.saveNewQuery = saveNewQuery;

// Debug function to test save button functionality
window.testSaveButton = function() {
    console.log('=== Testing Save Button ===');
    
    const saveBtn = document.getElementById('saveQueryBtn');
    console.log('Save button found:', !!saveBtn);
    if (saveBtn) {
        console.log('Save button onclick:', saveBtn.onclick);
        console.log('Save button addEventListener count:', saveBtn.getEventListeners ? saveBtn.getEventListeners().length : 'unknown');
    }
    
    console.log('saveNewQuery function exists:', typeof saveNewQuery);
    console.log('window.saveNewQuery exists:', typeof window.saveNewQuery);
    
    console.log('showContentLoading exists:', typeof window.showContentLoading);
    console.log('hideContentLoading exists:', typeof window.hideContentLoading);
    
    // Try calling the function directly
    if (typeof saveNewQuery === 'function') {
        console.log('Attempting to call saveNewQuery directly...');
        try {
            saveNewQuery();
        } catch (e) {
            console.error('Error calling saveNewQuery:', e);
        }
    }
};