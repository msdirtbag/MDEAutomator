// Initialize CodeMirror function - must be defined at the very top before any use
if (typeof window.initializeCodeMirror !== 'function') {
    window.initializeCodeMirror = function() {
        // Robust CodeMirror initialization for Add/Edit Query modal
        // Requires CodeMirror library to be loaded globally
        const modal = document.getElementById('addQueryModal');
        if (!modal) {
            console.warn('initializeCodeMirror: addQueryModal not found');
            return;
        }
        // Try to find the editor container (div or textarea)
        let editorContainer = modal.querySelector('#kqlEditor, #codeMirrorKqlEditor, .kql-editor');
        if (!editorContainer) {
            // Create a div for CodeMirror if not present
            editorContainer = document.createElement('div');
            editorContainer.id = 'kqlEditor';
            editorContainer.className = 'kql-editor';
            editorContainer.style = 'height: 200px; border: 1px solid #444; background: #181818; margin: 10px 0;';
            // Insert after the query name input if possible
            const queryNameInput = modal.querySelector('#newQueryName');
            if (queryNameInput && queryNameInput.parentNode) {
                queryNameInput.parentNode.insertBefore(editorContainer, queryNameInput.nextSibling);
            } else {
                modal.appendChild(editorContainer);
            }
        }
        // If CodeMirror is already initialized, do nothing
        if (window.codeMirrorKqlEditor && typeof window.codeMirrorKqlEditor.setValue === 'function') {
            window.codeMirrorKqlEditor.refresh();
            return;
        }
        // Check if CodeMirror is available
        if (typeof window.CodeMirror !== 'function') {
            console.error('CodeMirror library is not loaded.');
            return;
        }
        // Remove any previous instance
        if (editorContainer.CodeMirrorInstance) {
            try { editorContainer.CodeMirrorInstance.toTextArea && editorContainer.CodeMirrorInstance.toTextArea(); } catch (e) {}
        }
        // Create a new CodeMirror instance
        window.codeMirrorKqlEditor = window.CodeMirror(editorContainer, {
            value: '',
            mode: 'kusto', // or 'text/x-sql' or 'text/plain' if kusto not available
            theme: 'material-darker',
            lineNumbers: true,
            autofocus: true,
            indentUnit: 4,
            tabSize: 4,
            lineWrapping: true,
            extraKeys: { 'Ctrl-Space': 'autocomplete' }
        });
        editorContainer.CodeMirrorInstance = window.codeMirrorKqlEditor;
        setTimeout(() => window.codeMirrorKqlEditor.refresh(), 100);
    };
}

// Ensure the global editQuery function is defined at the very top of the file
window.editQuery = async function(queryName) {
    if (!queryName) return;

    // Fetch the query object from the Flask backend
    let queryObj = null;
    try {
        const tenantId = getTenantId();
        if (!tenantId) {
            alert('Please select a tenant first.');
            return;
        }

        const res = await fetch('/api/hunt/queries', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ Function: 'GetQuery', QueryName: queryName, TenantId: tenantId })
        });

        if (!res.ok) {
            throw new Error(`Failed to fetch query: ${res.statusText}`);
        }

        queryObj = await res.json();
        console.log('Fetched query object from Flask backend:', queryObj);
    } catch (error) {
        console.error('Error fetching query from Flask backend:', error);
        alert('Failed to fetch query details. Please try again.');
        return;
    }    // Show the modal FIRST
    const modal = document.getElementById('addQueryModal');
    if (modal) {
        modal.style.display = 'flex';
        modal.classList.add('edit-mode');
    }

    // Set modal title to Edit mode
    const title = modal ? modal.querySelector('h3') : null;
    if (title) {
        title.textContent = 'Edit Query';
        title.classList.add('edit-mode');
    }

    // Set query name input (readonly in edit mode)
    const queryNameInput = document.getElementById('newQueryName');
    if (queryNameInput) {
        queryNameInput.value = queryName;
        queryNameInput.readOnly = true;
        queryNameInput.style.backgroundColor = '#333';
        queryNameInput.style.color = '#ccc';
    }

    // Set save button text
    const saveText = document.getElementById('saveQueryBtnText');
    if (saveText) {
        saveText.textContent = 'Update Query';
    }

    // Set edit mode flags
    window.isEditMode = true;
    window.editingQueryName = queryName;

    // Wait for modal to be fully rendered before initializing CodeMirror
    await new Promise(resolve => setTimeout(resolve, 100));// Ensure CodeMirror editor is initialized before setting its value
    function ensureCodeMirrorInitialized(callback) {
        let retryCount = 0;
        const maxRetries = 10;
        
        function checkAndRetry() {
            if (window.codeMirrorKqlEditor && typeof window.codeMirrorKqlEditor.setValue === 'function') {
                console.log('CodeMirror editor is ready.');
                callback();
            } else if (retryCount < maxRetries) {
                retryCount++;
                console.warn(`CodeMirror editor is not ready. Retry ${retryCount}/${maxRetries} in 300ms...`);
                setTimeout(checkAndRetry, 300);
            } else {
                console.error('CodeMirror editor failed to initialize after maximum retries.');
                // Try to force initialization one more time
                try {
                    initializeCodeMirror();
                    if (window.codeMirrorKqlEditor && typeof window.codeMirrorKqlEditor.setValue === 'function') {
                        console.log('CodeMirror editor initialized on final attempt.');
                        callback();
                    } else {
                        console.error('CodeMirror editor could not be initialized.');
                    }
                } catch (error) {
                    console.error('Error in final CodeMirror initialization attempt:', error);
                }
            }
        }
        
        checkAndRetry();
    }    // Debug CodeMirror initialization
    if (!window.codeMirrorKqlEditor) {
        console.warn('CodeMirror editor is not initialized, will initialize now...');
    } else {
        console.log('CodeMirror editor is already initialized.');
    }

    // Force initialization now that modal is visible
    console.log('Forcing CodeMirror initialization for edit mode...');
    initializeCodeMirror();

    // Use a more robust approach to set the editor value
    ensureCodeMirrorInitialized(() => {
        if (queryObj && queryObj.Content) {
            console.log('Setting CodeMirror value to:', queryObj.Content.substring(0, 100) + '...');
            try {
                window.codeMirrorKqlEditor.setValue(queryObj.Content);
                window.codeMirrorKqlEditor.refresh();
                console.log('CodeMirror value set successfully');
            } catch (error) {
                console.error('Error setting CodeMirror value:', error);
            }
        } else {
            console.log('Setting CodeMirror value to empty string');
            try {
                window.codeMirrorKqlEditor.setValue('');
                window.codeMirrorKqlEditor.refresh();
            } catch (error) {
                console.error('Error setting CodeMirror to empty:', error);
            }
        }
    });
};

// --- TIManager-style Scheduled Hunts Table ---
let scheduledHuntsSelection = new Set();

// Global variables for query management
// Last updated: 2025-06-20 17:30 - Cache busting update - no showLoadingIndicator references should exist
console.log('=== HuntManager.js loaded ===', new Date().toISOString());
let queriesGrid = null;
let allQueries = [];

// Debounce mechanism to prevent rapid successive grid operations
let isGridOperationInProgress = false;
let gridOperationTimeout = null;

function debounceGridOperation(operation, delay = 100) {
    return async function(...args) {
        // Clear any pending operation
        if (gridOperationTimeout) {
            clearTimeout(gridOperationTimeout);
        }
        
        // If an operation is already in progress, wait for it to complete
        if (isGridOperationInProgress) {
            console.log('Grid operation already in progress, queueing...');
            return new Promise((resolve, reject) => {
                gridOperationTimeout = setTimeout(async () => {
                    try {
                        const result = await operation.apply(this, args);
                        resolve(result);
                    } catch (error) {
                        reject(error);
                    }
                }, delay);
            });
        }
        
        // Mark operation as in progress
        isGridOperationInProgress = true;
        
        try {
            const result = await operation.apply(this, args);
            return result;
        } finally {
            // Always clear the flag when done
            isGridOperationInProgress = false;
        }
    };
}

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

// Tenant management functions
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
    
    console.log(`Populated tenant dropdown with ${tenants.length} tenants`);
}

document.addEventListener('DOMContentLoaded', () => {
    console.log('HuntManager page JavaScript loaded');

    // Load tenants dropdown on page load
    loadTenants();

    // Set up event listeners after a short delay to ensure DOM is fully loaded
    setTimeout(() => {
        console.log('Setting up event listeners...');
        setupEventListeners();
    }, 100);

    // Wait for tenant dropdown to be populated, then auto-load all data
    waitForTenantDropdownAndLoadAll();

    // Always load queries on page load
    loadQueries();
    
    // Auto-load scheduled hunts on page load
    loadScheduledHunts();
});

// Set up Scheduled Hunts UI - initialize all components and load data
function setupScheduledHuntsUI() {
    console.log('Setting up Scheduled Hunts UI...');
    // Load scheduled hunts data
    if (typeof window.loadScheduledHunts === 'function') {
        window.loadScheduledHunts();
    }
    // Ensure batch action buttons are set up
    if (typeof setupScheduledHuntsBatchActionButtons === 'function') {
        setupScheduledHuntsBatchActionButtons();
    }
}

// Event listeners setup function
function setupEventListeners() {
    // Tenant dropdown change handler
    const tenantDropdown = document.getElementById('tenantDropdown');
    if (tenantDropdown) {
        tenantDropdown.addEventListener('change', function() {
            const tenantId = this.value;
            if (tenantId) {
                sessionStorage.setItem('TenantId', tenantId);
                // Auto-reload all data when tenant changes
                loadQueries();
                loadScheduledHunts();
            }
        });
    } else {
        console.warn('setupEventListeners: tenantDropdown not found');
    }    // Updated button event listeners for new layout
    const refreshAllBtn = document.getElementById('refreshAllBtn');
    const refreshQueriesBtn = document.getElementById('refreshQueriesBtn');
    const refreshScheduledHuntsBtn = document.getElementById('refreshScheduledHuntsBtn');
    const addQueryBtn = document.getElementById('addQueryBtn');
    const addQueryBtn2 = document.getElementById('addQueryBtn2');
    const addScheduleBtn = document.getElementById('addScheduleBtn');
    const addScheduleBtn2 = document.getElementById('addScheduleBtn2');
    
    if (refreshAllBtn) {
        refreshAllBtn.onclick = function() {
            loadQueries();
            loadScheduledHunts();
        };
    } else { console.warn('setupEventListeners: refreshAllBtn not found'); }
    if (refreshQueriesBtn) refreshQueriesBtn.onclick = loadQueries; else { console.warn('setupEventListeners: refreshQueriesBtn not found'); }
    if (refreshScheduledHuntsBtn) refreshScheduledHuntsBtn.onclick = window.loadScheduledHunts; else { console.warn('setupEventListeners: refreshScheduledHuntsBtn not found'); }
    if (addQueryBtn) addQueryBtn.onclick = showAddQueryModal; else { console.warn('setupEventListeners: addQueryBtn not found'); }
    if (addQueryBtn2) addQueryBtn2.onclick = showAddQueryModal; else { console.warn('setupEventListeners: addQueryBtn2 not found'); }
    if (addScheduleBtn) addScheduleBtn.onclick = showAddScheduleModal; else { console.warn('setupEventListeners: addScheduleBtn not found'); }
    if (addScheduleBtn2) addScheduleBtn2.onclick = showAddScheduleModal; else { console.warn('setupEventListeners: addScheduleBtn2 not found'); }

    // Modal buttons - with defensive event handler setup
    const saveQueryBtn = document.getElementById('saveQueryBtn');
    const cancelQueryBtn = document.getElementById('cancelQueryBtn');
    
    // Add Schedule Modal buttons
    const saveScheduleBtn = document.getElementById('saveScheduleBtn');
    const cancelScheduleBtn = document.getElementById('cancelScheduleBtn');
    const closeScheduleModalBtn = document.getElementById('closeScheduleModalBtn');
    
    // Query selection helper buttons
    const selectAllQueriesBtn = document.getElementById('selectAllQueriesBtn');
    const clearAllQueriesBtn = document.getElementById('clearAllQueriesBtn');
    
    // Day selection helper buttons
    const selectWeekdaysBtn = document.getElementById('selectWeekdaysBtn');
    const selectWeekendsBtn = document.getElementById('selectWeekendsBtn');
    const selectAllDaysBtn = document.getElementById('selectAllDaysBtn');
    const clearAllDaysBtn = document.getElementById('clearAllDaysBtn');
    
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
    } else { console.warn('setupEventListeners: saveQueryBtn not found'); }
    
    if (cancelQueryBtn) {
        cancelQueryBtn.onclick = hideAddQueryModal;
    } else { console.warn('setupEventListeners: cancelQueryBtn not found'); }

    // Add Schedule Modal event handlers
    if (saveScheduleBtn) {
        saveScheduleBtn.addEventListener('click', function(e) {
            e.preventDefault();
            e.stopPropagation();
            console.log('Save Schedule button clicked');
            saveNewSchedule();
        });
        console.log('Save Schedule button event listener attached');
    } else { console.warn('setupEventListeners: saveScheduleBtn not found'); }
    
    if (cancelScheduleBtn) {
        cancelScheduleBtn.addEventListener('click', hideAddScheduleModal);
        console.log('Cancel Schedule button event listener attached');
    } else { console.warn('setupEventListeners: cancelScheduleBtn not found'); }
    
    if (closeScheduleModalBtn) {
        closeScheduleModalBtn.addEventListener('click', hideAddScheduleModal);
        console.log('Close Schedule modal button event listener attached');
    } else { console.warn('setupEventListeners: closeScheduleModalBtn not found'); }

    // Query selection helper event handlers
    if (selectAllQueriesBtn) {
        selectAllQueriesBtn.addEventListener('click', function() {
            const checkboxes = document.querySelectorAll('#queryList input[type="checkbox"]');
            checkboxes.forEach(checkbox => {
                checkbox.checked = true;
                updateQueryCheckboxStyle(checkbox.closest('.query-checkbox'), true);
            });
        });
    }
    
    if (clearAllQueriesBtn) {
        clearAllQueriesBtn.addEventListener('click', function() {
            const checkboxes = document.querySelectorAll('#queryList input[type="checkbox"]');
            checkboxes.forEach(checkbox => {
                checkbox.checked = false;
                updateQueryCheckboxStyle(checkbox.closest('.query-checkbox'), false);
            });
        });
    }
    
    // Day selection helper event handlers
    if (selectWeekdaysBtn) {
        selectWeekdaysBtn.addEventListener('click', function() {
            const weekdays = ['scheduleMonday', 'scheduleTuesday', 'scheduleWednesday', 'scheduleThursday', 'scheduleFriday'];
            weekdays.forEach(id => {
                const checkbox = document.getElementById(id);
                if (checkbox) {
                    checkbox.checked = true;
                    checkbox.dispatchEvent(new Event('change'));
                }
            });
        });
    }
    
    if (selectWeekendsBtn) {
        selectWeekendsBtn.addEventListener('click', function() {
            const weekends = ['scheduleSaturday', 'scheduleSunday'];
            weekends.forEach(id => {
                const checkbox = document.getElementById(id);
                if (checkbox) {
                    checkbox.checked = true;
                    checkbox.dispatchEvent(new Event('change'));
                }
            });
        });
    }
    
    if (selectAllDaysBtn) {
        selectAllDaysBtn.addEventListener('click', function() {
            const allDays = ['scheduleMonday', 'scheduleTuesday', 'scheduleWednesday', 'scheduleThursday', 'scheduleFriday', 'scheduleSaturday', 'scheduleSunday'];
            allDays.forEach(id => {
                const checkbox = document.getElementById(id);
                if (checkbox) {
                    checkbox.checked = true;
                    checkbox.dispatchEvent(new Event('change'));
                }
            });
        });
    }
    
    if (clearAllDaysBtn) {
        clearAllDaysBtn.addEventListener('click', function() {
            const allDays = ['scheduleMonday', 'scheduleTuesday', 'scheduleWednesday', 'scheduleThursday', 'scheduleFriday', 'scheduleSaturday', 'scheduleSunday'];
            allDays.forEach(id => {
                const checkbox = document.getElementById(id);
                if (checkbox) {
                    checkbox.checked = false;
                    checkbox.dispatchEvent(new Event('change'));
                }
            });
        });
    }
}

// Helper: Wait for tenant dropdown to be populated, then auto-load all data
function waitForTenantDropdownAndLoadAll() {
    const savedTenant = sessionStorage.getItem('TenantId');
    const dropdown = document.getElementById('tenantDropdown');
    if (!dropdown) {
        setTimeout(waitForTenantDropdownAndLoadAll, 100);
        return;
    }
    // Wait until dropdown has at least one option
    if (dropdown.options.length === 0) {
        setTimeout(waitForTenantDropdownAndLoadAll, 100);
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
    // Auto-load all data for selected tenant
    if (dropdown.value && dropdown.value.trim() !== '') {
        Promise.all([
            loadQueries(),
            loadScheduledHunts()
        ]).then(() => {
            // Mark auto-load as completed
            if (typeof window.markAutoLoadCompleted === 'function') {
                window.markAutoLoadCompleted();
            }
        }).catch((error) => {
            console.error('Error in auto-load:', error);
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
    }

    // Show FileName, LastModified, Size, and Actions columns
    const columns = [
        { id: 'FileName', name: 'File Name', width: '30%', sort: true },
        { id: 'LastModified', name: 'Last Modified', width: '25%', sort: true },
        { id: 'Size', name: 'Size (bytes)', width: '15%', sort: true },
        { 
            id: 'Actions', 
            name: 'Actions', 
            width: '30%', 
            sort: false,
            formatter: (cell, row) => {
                const fileName = row.cells[0].data;
                return gridjs.html(`
                    <div style="display: flex; gap: 0.5rem; justify-content: center; flex-wrap: wrap;">
                        <button class="cta-button" style="font-size: 0.75em; padding: 0.25em 0.5em;" onclick="window.runQueryNow('${fileName}')">Run Now</button>
                        <button class="cta-button edit-button" style="font-size: 0.75em; padding: 0.25em 0.5em;" onclick="window.editQuery('${fileName}')">Edit</button>
                        <button class="cta-button undo-button" style="font-size: 0.75em; padding: 0.25em 0.5em;" onclick="window.removeQuery('${fileName}')">Delete</button>
                    </div>
                `);
            }
        }
    ];

    const queries = (queriesRaw || []).map(row => [
        row.FileName || '', 
        row.LastModified || '', 
        row.Size || '',
        '' // Actions column will be handled by formatter
    ]);

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
        console.log('Opening Add Query Modal. Reinitializing CodeMirror editor if necessary.');
        initializeCodeMirror();
    }
}

function hideAddQueryModal() {
    const modal = document.getElementById('addQueryModal');
    if (modal) {
        modal.style.display = 'none';
    }
    
    // Reset form fields
    const queryNameInput = document.getElementById('newQueryName');
    if (queryNameInput) {
        queryNameInput.value = '';
        queryNameInput.readOnly = false;
        queryNameInput.style.backgroundColor = '#101c11';
        queryNameInput.style.color = '#7fff7f';
    }
    
    // Reset modal title
    const title = modal ? modal.querySelector('h3') : null;
    if (title) {
        title.textContent = 'Add New Query';
        title.classList.remove('edit-mode');
    }
    
    // Reset save button
    const saveText = document.getElementById('saveQueryBtnText');
    if (saveText) {
        saveText.textContent = 'Save';
    }
    
    // Clear edit mode flags
    window.isEditMode = false;
    window.editingQueryName = null;
    
    // Clear CodeMirror editor
    if (window.codeMirrorKqlEditor && typeof window.codeMirrorKqlEditor.setValue === 'function') {
        try {
            window.codeMirrorKqlEditor.setValue('');
        } catch (error) {
            console.error('Error clearing CodeMirror:', error);
        }
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
    const spinner = document.getElementById('saveQuerySpinner');    if (saveBtn && spinner && saveText) {
        saveBtn.disabled = true;
        spinner.style.display = 'inline-block';
        saveText.textContent = window.isEditMode ? 'Updating...' : 'Saving...';
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
            return;        }        // Debug logging
        const actionVerb = window.isEditMode ? 'updating' : 'saving';
        console.log(`${actionVerb} query:`, { tenantId, queryName, queryText });
        
        if (!tenantId || !queryName || !queryText) {
            alert('Please fill in all fields.');
            return;        }        
        showContentLoading(window.isEditMode ? 'Updating Query...' : 'Saving Query...');
        
        const url = '/api/hunt/queries';
        const functionName = window.isEditMode ? 'UpdateQuery' : 'AddQuery';
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
            const action = window.isEditMode ? 'updated' : 'saved';
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
        const actionVerb = window.isEditMode ? 'updating' : 'saving';
        alert(`Error ${actionVerb} query: ${error.message}`);} finally {
        hideContentLoading();
          if (saveBtn && spinner && saveText) {
            saveBtn.disabled = false;
            spinner.style.display = 'none';
            saveText.textContent = window.isEditMode ? 'Update Query' : 'Save';
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

// Global error handler for GridJS issues
window.addEventListener('error', function(event) {
    if (event.error && event.error.message && event.error.message.includes('__k')) {
        console.warn('GridJS internal error detected, attempting to clean up:', event.error);
        
        // Try to clean up the scheduled hunts grid
        try {
            safelyDestroyScheduledHuntsGrid();
        } catch (e) {
            console.warn('Error during emergency grid cleanup:', e);
        }
        
        // Prevent the error from propagating
        event.preventDefault();
        return false;
    }
});

// Wrap grid operations with debounce
const debouncedLoadScheduledHunts = debounceGridOperation(loadScheduledHunts);
const debouncedRefreshScheduledHunts = debounceGridOperation(refreshScheduledHunts);
function safelyDestroyScheduledHuntsGrid() {
    if (scheduledHuntsGrid) {
        try {
            if (typeof scheduledHuntsGrid.destroy === 'function') {
                scheduledHuntsGrid.destroy();
            }
        } catch (e) {
            console.warn('Error destroying scheduled hunts grid:', e);
        }
        scheduledHuntsGrid = null;
    }
    
    // Also clean up any leftover DOM elements
    const tableContainer = document.getElementById('scheduled-hunts-table');
    if (tableContainer) {
        try {
            const gridElements = tableContainer.querySelectorAll('.gridjs-wrapper, .gridjs-container, .gridjs-head, .gridjs-pagination');
            gridElements.forEach(el => {
                try {
                    el.remove();
                } catch (e) {
                    console.warn('Error removing grid element:', e);
                }
            });
        } catch (e) {
            console.warn('Error cleaning up grid DOM elements:', e);
        }
    }
}

// --- TIManager-style Scheduled Hunts Table ---
// let scheduledHuntsSelection = new Set();

// Scheduled Hunts Table Logic
let scheduledHuntsGrid = null;

// Patch: Debug log and force render scheduled hunts table
function renderScheduledHuntsTable(schedules) {
    const tableContainer = document.getElementById('scheduled-hunts-table');
    if (!tableContainer) return;
    tableContainer.innerHTML = '';

    if (!Array.isArray(schedules) || schedules.length === 0) {
        const emptyDiv = document.createElement('div');
        emptyDiv.style.cssText = 'color:#aaa; text-align:center; padding:1rem;';
        emptyDiv.textContent = 'No scheduled hunts found for this tenant.';
        tableContainer.appendChild(emptyDiv);
        return;
    }

    // Table with GridJS-like classes for consistent styling
    const tableWrapper = document.createElement('div');
    tableWrapper.className = 'gridjs-wrapper';
    const table = document.createElement('table');
    table.className = 'gridjs-table';
    table.style.width = '100%';    table.innerHTML = `        <thead class="gridjs-thead">
            <tr class="gridjs-tr">
                <th class="gridjs-th"><input type="checkbox" id="scheduledHuntsSelectAll"></th>
                <th class="gridjs-th">Schedule Name</th>
                <th class="gridjs-th">Time</th>
                <th class="gridjs-th">Days</th>
                <th class="gridjs-th">Queries</th>
                <th class="gridjs-th">Enabled</th>
            </tr>
        </thead>
        <tbody>            ${schedules.map(s => {                const id = s.ScheduleId || s.scheduleId || s.id || '';
                const checked = scheduledHuntsSelection.has(id) ? 'checked' : '';
                  // ScheduleName and ScheduleTime should be top-level fields from the Azure Function response
                const scheduleName = s.ScheduleName || s.scheduleName || 'Unnamed Schedule';
                const scheduleTime = s.ScheduleTime || s.scheduleTime || '';
                const timeDisplay = scheduleTime || 'Not set';
                  // HuntSchedule contains only Days and Queries
                const days = (s.HuntSchedule && s.HuntSchedule.Days) ? s.HuntSchedule.Days.join(', ') : '';
                const queries = (s.HuntSchedule && s.HuntSchedule.QueryNames) ? s.HuntSchedule.QueryNames.slice(0,4).join(', ') + (s.HuntSchedule.QueryNames.length > 4 ? ` +${s.HuntSchedule.QueryNames.length-4} more` : '') : '';
                const enabled = s.Enabled !== undefined ? !!s.Enabled : (s.enabled !== undefined ? !!s.enabled : false);
                
                return `
                <tr class="gridjs-tr" data-id="${id}">
                    <td class="gridjs-td"><input type="checkbox" class="scheduledHuntCheckbox" value="${id}" ${checked}></td>
                    <td class="gridjs-td" style="font-weight: bold; color: #7fff7f;">${scheduleName}</td>
                    <td class="gridjs-td" style="font-family: monospace;">${timeDisplay}</td>
                    <td class="gridjs-td">${days}</td>
                    <td class="gridjs-td">${queries}</td>
                    <td class="gridjs-td" style="color:${enabled ? '#00ff41' : '#ff4400'};font-weight:bold;">${enabled ? 'Yes' : 'No'}</td>
                </tr>`;
            }).join('')}
        </tbody>
    `;
    tableWrapper.appendChild(table);
    tableContainer.appendChild(tableWrapper);

    // Event listeners for checkboxes
    table.querySelectorAll('.scheduledHuntCheckbox').forEach(cb => {
        cb.addEventListener('change', function() {
            if (this.checked) scheduledHuntsSelection.add(this.value);
            else scheduledHuntsSelection.delete(this.value);
            updateScheduledHuntsActionButtons();
        });
    });
    // Select all
    const selectAll = table.querySelector('#scheduledHuntsSelectAll');
    if (selectAll) {
        selectAll.checked = schedules.length > 0 && schedules.every(s => scheduledHuntsSelection.has(s.ScheduleId || s.scheduleId || s.id || ''));
        selectAll.addEventListener('change', function() {
            if (this.checked) {
                schedules.forEach(s => scheduledHuntsSelection.add(s.ScheduleId || s.scheduleId || s.id || ''));
            } else {
                schedules.forEach(s => scheduledHuntsSelection.delete(s.ScheduleId || s.scheduleId || s.id || ''));
            }
            updateScheduledHuntsActionButtons();
            // Re-check all checkboxes
            table.querySelectorAll('.scheduledHuntCheckbox').forEach(cb => { cb.checked = selectAll.checked; });
        });
    }
    updateScheduledHuntsActionButtons();
}

function updateScheduledHuntsActionButtons() {
    const enableBtn = document.getElementById('enableSelectedBtn');
    const disableBtn = document.getElementById('disableSelectedBtn');
    const deleteBtn = document.getElementById('deleteSelectedSchedulesBtn');
    const selectedCount = scheduledHuntsSelection.size;
    if (enableBtn) enableBtn.disabled = selectedCount === 0;
    if (disableBtn) disableBtn.disabled = selectedCount === 0;
    if (deleteBtn) deleteBtn.disabled = selectedCount === 0;
}

// --- BEGIN: Modern Batch Actions for Scheduled Hunts ---

// Utility: Get selected schedule IDs
function getSelectedScheduleIds() {
    return Array.from(scheduledHuntsSelection || new Set());
}

// Utility: Show feedback (can be replaced with a better UI system)
function showBatchActionFeedback(message, isError = false) {
    if (window.showContentLoading) {
        window.showContentLoading(message);
    } else {
        // fallback: alert for errors
        if (isError) alert(message);
    }
}
function hideBatchActionFeedback() {
    if (window.hideContentLoading) window.hideContentLoading();
}

// Batch Enable
window.batchEnableScheduledHunts = async function() {
    const selected = getSelectedScheduleIds();
    if (selected.length === 0) {
        alert('Select at least one schedule to enable.');
        return;
    }
    if (!confirm(`Enable ${selected.length} scheduled hunt(s)?`)) return;
    showBatchActionFeedback('Enabling selected schedules...');
    let errors = [];
    for (const id of selected) {
        try {
            const result = await window.enableDisableSchedule(id, true);
            if (!result || result.error || result.Status === 'Failed') {
                errors.push(`Failed to enable schedule ${id}: ${result && (result.Message || result.error || result.Status)}`);
            }
        } catch (err) {
            errors.push(`Error enabling schedule ${id}: ${err.message}`);
        }
    }
    scheduledHuntsSelection.clear();
    await loadScheduledHunts();
    hideBatchActionFeedback();
    if (errors.length) {
        alert('Some schedules failed to enable:\n' + errors.join('\n'));
    } else {
        alert('Selected schedules enabled successfully!');
    }
};

// Batch Disable
window.batchDisableScheduledHunts = async function() {
    const selected = getSelectedScheduleIds();
    if (selected.length === 0) {
        alert('Select at least one schedule to disable.');
        return;
    }
    if (!confirm(`Disable ${selected.length} scheduled hunt(s)?`)) return;
    showBatchActionFeedback('Disabling selected schedules...');
    let errors = [];
    for (const id of selected) {
        try {
            const result = await window.enableDisableSchedule(id, false);
            if (!result || result.error || result.Status === 'Failed') {
                errors.push(`Failed to disable schedule ${id}: ${result && (result.Message || result.error || result.Status)}`);
            }
        } catch (err) {
            errors.push(`Error disabling schedule ${id}: ${err.message}`);
        }
    }
    scheduledHuntsSelection.clear();
    await loadScheduledHunts();
    hideBatchActionFeedback();
    if (errors.length) {
        alert('Some schedules failed to disable:\n' + errors.join('\n'));
    } else {
        alert('Selected schedules disabled successfully!');
    }
};

// Batch Delete
window.batchDeleteScheduledHunts = async function() {
    const selected = getSelectedScheduleIds();
    if (selected.length === 0) {
        alert('Select at least one schedule to delete.');
        return;
    }
    if (!confirm(`Delete ${selected.length} scheduled hunt(s)? This cannot be undone.`)) return;
    showBatchActionFeedback('Deleting selected schedules...');
    let errors = [];
    for (const id of selected) {
        try {
            const result = await window.deleteSchedule(id);
            if (!result || result.error || result.Status === 'Failed') {
                errors.push(`Failed to delete schedule ${id}: ${result && (result.Message || result.error || result.Status)}`);
            }
        } catch (err) {
            errors.push(`Error deleting schedule ${id}: ${err.message}`);
        }
    }
    scheduledHuntsSelection.clear();
    await loadScheduledHunts();
    hideBatchActionFeedback();
    if (errors.length) {
        alert('Some schedules failed to delete:\n' + errors.join('\n'));
    } else {
        alert('Selected schedules deleted successfully!');
    }
};

// Wire up batch action buttons after DOM is ready
function setupScheduledHuntsBatchActionButtons() {
    const enableBtn = document.getElementById('enableSelectedBtn');
    const disableBtn = document.getElementById('disableSelectedBtn');
    const deleteBtn = document.getElementById('deleteSelectedSchedulesBtn');
    if (enableBtn) enableBtn.onclick = window.batchEnableScheduledHunts;
    if (disableBtn) disableBtn.onclick = window.batchDisableScheduledHunts;
    if (deleteBtn) deleteBtn.onclick = window.batchDeleteScheduledHunts;
}
document.addEventListener('DOMContentLoaded', setupScheduledHuntsBatchActionButtons);

// --- Ensure critical functions are defined and globally available early ---

// Load scheduled hunts data function
async function loadScheduledHunts() {
    const tenantId = getTenantId();
    if (!tenantId) {
        renderScheduledHuntsTable([]);
        return;
    }
    window.showContentLoading && window.showContentLoading('Loading Scheduled Hunts...');
    try {
        // Create an AbortController with a longer timeout since the API might take time to poll for results
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 45000); // 45 second timeout to allow for polling
        
        const res = await fetch(`/api/hunt/schedules?TenantId=${encodeURIComponent(tenantId)}`, {
            method: 'GET',
            headers: { 'Content-Type': 'application/json', 'X-Tenant-ID': tenantId },
            signal: controller.signal
        });
        
        clearTimeout(timeoutId);
        
        if (!res.ok) {
            // Handle HTTP error status codes
            const errorText = await res.text();
            console.error('HTTP error loading scheduled hunts:', res.status, errorText);
            if (res.status === 408) {
                // Request timeout from server
                console.warn('Server timeout loading scheduled hunts, will retry');
                renderScheduledHuntsTable([]);
                return;
            }            throw new Error(`HTTP ${res.status}: ${errorText}`);
        }
        
        const result = await res.json();
        console.log(`Scheduled hunts API response received with ${result.schedules ? result.schedules.length : 0} schedules`);
        
        // Handle success response
        if (result.success) {
            const schedules = result.schedules || [];
            console.log(`Successfully loaded ${schedules.length} scheduled hunts`);
            renderScheduledHuntsTable(schedules);
        } else {
            // Handle error response from API - provide better error details
            const errorMsg = result.error || result.message || result.Message || 'Unknown API error';
            console.error('API error loading scheduled hunts:', errorMsg);
            console.error('Full error response:', result);
            renderScheduledHuntsTable([]);
        }
    } catch (error) {
        if (error.name === 'AbortError') {
            console.warn('Request aborted due to timeout loading scheduled hunts');
        } else {
            console.error('Error loading scheduled hunts:', error);
        }
        renderScheduledHuntsTable([]);
    } finally {
        window.hideContentLoading && window.hideContentLoading();
    }
}
window.loadScheduledHunts = loadScheduledHunts;

// Define refreshScheduledHunts as an alias to loadScheduledHunts for consistency
function refreshScheduledHunts() {
    return window.loadScheduledHunts && window.loadScheduledHunts();
}
window.refreshScheduledHunts = refreshScheduledHunts;

function showAddScheduleModal() {
    console.log('showAddScheduleModal: Opening redesigned modal...');
    const modal = document.getElementById('addScheduleModal');
    if (!modal) {
        console.error('Add Schedule modal not found');
        return;
    }
    
    // Reset form before showing
    if (typeof resetAddScheduleForm === 'function') {
        resetAddScheduleForm();
    }
    
    // Load available queries for selection
    if (typeof window.loadQueriesForSchedule === 'function') {
        window.loadQueriesForSchedule();
    }
    
    // Show modal with animation
    modal.style.display = 'flex';
    modal.style.opacity = '0';
    
    // Trigger animation after DOM update
    setTimeout(() => {
        modal.style.opacity = '1';
    }, 10);
    
    console.log('showAddScheduleModal: Modal opened and queries loading...');
}
window.showAddScheduleModal = showAddScheduleModal;

// Hide the Add Schedule modal with smooth animation
function hideAddScheduleModal() {
    const modal = document.getElementById('addScheduleModal');
    if (modal) {
        // Fade out animation
        modal.style.opacity = '0';
        
        // Hide after animation completes
        setTimeout(() => {
            modal.style.display = 'none';
            modal.style.opacity = '1'; // Reset for next time
            
            // Reset form after hiding
            if (typeof resetAddScheduleForm === 'function') {
                resetAddScheduleForm();
            }
        }, 300);
        
        console.log('Add Schedule modal hidden');
    }
}

// Reset all fields in the Add Schedule modal form
// Reset the redesigned Add Schedule modal form
function resetAddScheduleForm() {
    console.log('resetAddScheduleForm: Resetting modal form...');
    
    // Reset schedule name
    const scheduleName = document.getElementById('scheduleName');
    if (scheduleName) {
        scheduleName.value = '';
        scheduleName.style.borderColor = '#00ff41'; // Reset border color
    }
    
    // Reset all day checkboxes
    const dayCheckboxes = ['scheduleMonday', 'scheduleTuesday', 'scheduleWednesday', 'scheduleThursday', 'scheduleFriday', 'scheduleSaturday', 'scheduleSunday'];
    dayCheckboxes.forEach(id => {
        const checkbox = document.getElementById(id);
        if (checkbox) {
            checkbox.checked = false;
            // Reset parent label styling
            const label = checkbox.closest('.day-checkbox');
            if (label) {
                label.style.background = '';
            }
        }
    });
      // Reset time
    const scheduleTime = document.getElementById('scheduleTime');
    if (scheduleTime) scheduleTime.value = '09:00';
    
    // Reset all query checkboxes
    const queryCheckboxes = document.querySelectorAll('#queryList input[type="checkbox"]');
    queryCheckboxes.forEach(checkbox => {
        checkbox.checked = false;
        // Reset container styling
        const container = checkbox.closest('.query-checkbox');
        if (container) {
            container.classList.remove('selected');
        }
    });
    
    // Reset validation message
    const validationMessage = document.getElementById('scheduleValidationMessage');
    if (validationMessage) {
        validationMessage.style.display = 'none';
        validationMessage.textContent = '';
    }
    
    // Reset save button state
    const saveBtn = document.getElementById('saveScheduleBtn');
    const saveBtnText = document.getElementById('saveScheduleBtnText');
    const saveSpinner = document.getElementById('saveScheduleSpinner');
    if (saveBtn) saveBtn.disabled = false;
    if (saveBtnText) saveBtnText.textContent = 'Create Schedule';
    if (saveSpinner) saveSpinner.style.display = 'none';
    
    console.log('resetAddScheduleForm: Form reset complete');
}

// Validate and save the new schedule
async function saveNewSchedule() {
    const tenantId = getTenantId();
    if (!tenantId) {
        showValidationMessage('Please select a tenant first');
        return;
    }
      // Get form values
    const scheduleName = document.getElementById('scheduleName').value.trim();
    const scheduleTime = document.getElementById('scheduleTime').value;
    
    // Get selected queries
    const selectedQueries = [];
    const queryCheckboxes = document.querySelectorAll('#queryList input[type="checkbox"]:checked');
    queryCheckboxes.forEach(checkbox => {
        selectedQueries.push({
            name: checkbox.value,
            content: decodeURIComponent(checkbox.dataset.queryContent || '')
        });
    });
    
    // Get selected days
    const selectedDays = [];
    const dayCheckboxes = ['scheduleMonday', 'scheduleTuesday', 'scheduleWednesday', 'scheduleThursday', 'scheduleFriday', 'scheduleSaturday', 'scheduleSunday'];
    dayCheckboxes.forEach(id => {
        const checkbox = document.getElementById(id);
        if (checkbox && checkbox.checked) {
            selectedDays.push(checkbox.value);
        }
    });
    
    // Validate form
    if (!scheduleName) {
        showValidationMessage('Please enter a schedule name');
        return;
    }
    
    if (selectedQueries.length === 0) {
        showValidationMessage('Please select at least one query');
        return;
    }
    
    if (selectedDays.length === 0) {
        showValidationMessage('Please select at least one day');
        return;
    }
    
    // Show loading state
    setScheduleSaveLoading(true);
      try {
        // Get client name from tenant dropdown (extract from the display text)
        const tenantDropdown = document.getElementById('tenantDropdown');        const selectedOption = tenantDropdown.options[tenantDropdown.selectedIndex];
        const clientName = selectedOption ? selectedOption.textContent.split(' (')[0] : 'Unknown Client';
        
        // Build the HuntSchedule object (contains only days and queries)
        const huntSchedule = {
            Days: selectedDays,
            QueryNames: selectedQueries.map(q => q.name),
            Queries: selectedQueries
        };
          // Build the complete payload with ScheduleName and ScheduleTime as separate parameters
        const scheduleData = {
            TenantId: tenantId,
            ClientName: clientName,
            ScheduleName: scheduleName,
            ScheduleTime: scheduleTime,
            HuntSchedule: huntSchedule        };
        
        const response = await fetch('/api/hunt/schedules', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify(scheduleData)
        });
        
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}: ${response.statusText}`);
        }
        
        const result = await response.json();
        
        if (result.error) {
            throw new Error(result.error);
        }
        
        // Success
        hideAddScheduleModal();
        
        // Refresh the scheduled hunts table
        if (typeof window.loadScheduledHunts === 'function') {
            window.loadScheduledHunts();
        }
        
    } catch (error) {
        console.error('Error saving schedule:', error);
        showValidationMessage('Error saving schedule: ' + error.message);
    } finally {
        setScheduleSaveLoading(false);
    }
}

// Show validation message
function showValidationMessage(message) {
    const validationMessage = document.getElementById('scheduleValidationMessage');
    if (validationMessage) {
        validationMessage.textContent = message;
        validationMessage.style.display = 'block';
        
        // Auto-hide after 5 seconds
        setTimeout(() => {
            validationMessage.style.display = 'none';
        }, 5000);
    }
}

// Set loading state for save button
function setScheduleSaveLoading(isLoading) {
    const saveBtn = document.getElementById('saveScheduleBtn');
    const saveBtnText = document.getElementById('saveScheduleBtnText');
    const saveSpinner = document.getElementById('saveScheduleSpinner');
    
    if (saveBtn) saveBtn.disabled = isLoading;
    if (saveBtnText) saveBtnText.textContent = isLoading ? 'Saving...' : 'Create Schedule';
    if (saveSpinner) saveSpinner.style.display = isLoading ? 'inline-block' : 'none';
}

// Provide a global enableDisableSchedule function for scheduled hunts
window.enableDisableSchedule = async function(scheduleId, enable) {
    const tenantId = getTenantId();
    if (!tenantId || !scheduleId) {
        return { error: 'Missing tenant or schedule ID' };
    }
    const url = `/api/hunt/schedules/${encodeURIComponent(scheduleId)}/${enable ? 'enable' : 'disable'}?TenantId=${encodeURIComponent(tenantId)}`;
    try {
        const res = await fetch(url, {
            method: 'PUT',
            headers: { 'Content-Type': 'application/json' }
        });
        if (!res.ok) {
            return { error: `HTTP error: ${res.status}` };
        }
        const result = await res.json();
        return result;
    } catch (error) {
        return { error: error.message };
    }
};

// Provide a global deleteSchedule function for scheduled hunts
window.deleteSchedule = async function(scheduleId) {
    const tenantId = getTenantId();
    if (!tenantId || !scheduleId) {
        return { error: 'Missing tenant or schedule ID' };
    }
    const url = `/api/hunt/schedules/${encodeURIComponent(scheduleId)}?TenantId=${encodeURIComponent(tenantId)}`;
    try {
        const res = await fetch(url, {
            method: 'DELETE',
            headers: { 'Content-Type': 'application/json' }
        });
        if (!res.ok) {
            return { error: `HTTP error: ${res.status}` };
        }
        const result = await res.json();
        return result;
    } catch (error) {
        return { error: error.message };
    }
};

// --- BEGIN: Modern loadQueriesForSchedule for Redesigned Add Schedule Modal ---
// Populates the query selection area in the redesigned Add Schedule modal with available queries as checkboxes
window.loadQueriesForSchedule = async function() {
    console.log('loadQueriesForSchedule: Starting to load queries for schedule modal...');
    
    const tenantId = getTenantId();
    if (!tenantId) {
        console.warn('loadQueriesForSchedule: No tenant ID available');
        showQueryEmptyState('No tenant selected');
        return;
    }
    
    // Show loading state
    showQueryLoadingState();
    
    try {
        console.log('loadQueriesForSchedule: Fetching queries for tenant:', tenantId);
        
        const response = await fetch('/api/hunt/queries', {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ TenantId: tenantId, Function: 'GetQueries' })
        });
        
        if (!response.ok) {
            throw new Error(`HTTP ${response.status}: ${response.statusText}`);
        }
        
        const result = await response.json();
        console.log('loadQueriesForSchedule: Received response:', result);
        
        // Extract queries from various possible response formats
        let queries = [];
        if (Array.isArray(result.Queries)) {
            queries = result.Queries;
        } else if (Array.isArray(result.value)) {
            queries = result.value;
        } else if (Array.isArray(result.queries)) {
            queries = result.queries;
        } else if (Array.isArray(result)) {
            queries = result;
        }
        
        console.log('loadQueriesForSchedule: Extracted queries:', queries.length, 'items');
        
        if (!queries || queries.length === 0) {
            showQueryEmptyState();
            return;
        }
        
        // Populate the query list
        populateQueryList(queries);
        
    } catch (error) {
        console.error('loadQueriesForSchedule: Error loading queries:', error);
        showQueryEmptyState('Error loading queries: ' + error.message);
    }
};

// Show loading state for queries
function showQueryLoadingState() {
    const loadingState = document.getElementById('queryLoadingState');
    const emptyState = document.getElementById('queryEmptyState');
    const queryList = document.getElementById('queryList');
    
    if (loadingState) loadingState.style.display = 'flex';
    if (emptyState) emptyState.style.display = 'none';
    if (queryList) queryList.style.display = 'none';
}

// Show empty state for queries
function showQueryEmptyState(message = null) {
    const loadingState = document.getElementById('queryLoadingState');
    const emptyState = document.getElementById('queryEmptyState');
    const queryList = document.getElementById('queryList');
    
    if (loadingState) loadingState.style.display = 'none';
    if (emptyState) {
        emptyState.style.display = 'block';
        if (message) {
            const messageDiv = emptyState.querySelector('div:last-child');
            if (messageDiv) messageDiv.textContent = message;
        }
    }
    if (queryList) queryList.style.display = 'none';
}

// Populate the query list with checkboxes
function populateQueryList(queries) {
    const loadingState = document.getElementById('queryLoadingState');
    const emptyState = document.getElementById('queryEmptyState');
    const queryList = document.getElementById('queryList');
    
    if (loadingState) loadingState.style.display = 'none';
    if (emptyState) emptyState.style.display = 'none';
    if (!queryList) {
        console.error('populateQueryList: Query list container not found');
        return;
    }
    
    // Clear existing content
    queryList.innerHTML = '';
    
    // Create checkboxes for each query
    queries.forEach((query, index) => {
        const queryName = query.FileName || query.QueryName || query.name || `Query ${index + 1}`;
        const queryContent = query.Content || query.content || '';
        const queryPreview = queryContent.length > 60 ? queryContent.substring(0, 60) + '...' : queryContent;
        
        const checkboxContainer = document.createElement('div');
        checkboxContainer.className = 'query-checkbox';
        checkboxContainer.innerHTML = `
            <input type="checkbox" id="query_${index}" value="${queryName}" data-query-content="${encodeURIComponent(queryContent)}">
            <div style="flex: 1;">
                <div class="query-name">${queryName}</div>
                <div class="query-preview">${queryPreview}</div>
            </div>
        `;
        
        // Add click handler for the entire container
        checkboxContainer.addEventListener('click', function(e) {
            if (e.target.type !== 'checkbox') {
                const checkbox = this.querySelector('input[type="checkbox"]');
                checkbox.checked = !checkbox.checked;
                updateQueryCheckboxStyle(checkbox.closest('.query-checkbox'), checkbox.checked);
            } else {
                updateQueryCheckboxStyle(this, e.target.checked);
            }
        });
        
        // Add change handler for checkbox
        const checkbox = checkboxContainer.querySelector('input[type="checkbox"]');
        checkbox.addEventListener('change', function() {
            updateQueryCheckboxStyle(checkboxContainer, this.checked);
        });
        
        queryList.appendChild(checkboxContainer);
    });
    
    queryList.style.display = 'block';
    console.log('populateQueryList: Successfully populated', queries.length, 'queries');
}

// Update query checkbox styling
function updateQueryCheckboxStyle(container, isChecked) {
    if (isChecked) {
        container.classList.add('selected');
    } else {
        container.classList.remove('selected');
    }
}
// --- END: Modern loadQueriesForSchedule for Redesigned Add Schedule Modal ---

// --- Ensure CodeMirror initialization function exists globally ---

