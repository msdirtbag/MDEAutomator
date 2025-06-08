// Incident Manager JavaScript
// Global variables for incident management
let selectedIncidentIds = [];
let incidentsGrid = null;
let allIncidents = [];

window.addEventListener('DOMContentLoaded', () => {
    console.log('Incident Manager page JavaScript loaded');
    
    // Load initial data
    loadTenants();
    
    // Set up event listeners
    setTimeout(() => {
        setupEventListeners();
    }, 100);
    
    // Auto-load incidents when tenant is available
    waitForTenantDropdownAndLoadData();
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
        loadIncidents();
    }
}

function getTenantId() {
    const tenantDropdown = document.getElementById('tenantDropdown');
    return tenantDropdown ? tenantDropdown.value.trim() : '';
}

// Loading indicator functions
function showLoadingIndicator(message = 'Loading...') {
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
        <div>${message}</div>
        <div class="progress-bar"><div class="progress-bar-inner"></div></div>
    </div>`;
    overlay.style.display = 'flex';
}

function hideLoadingIndicator() {
    const overlay = document.getElementById('loadingOverlay');
    if (overlay) {
        overlay.style.display = 'none';
    }
}

// Main function to load incidents
async function loadIncidents() {
    const tenantId = getTenantId();
    if (!tenantId) {
        console.warn('No tenant selected for loading incidents');
        return;
    }

    console.log('Loading incidents...');
    showLoadingIndicator('Loading Incidents');

    try {
        // Create AbortController for timeout handling
        const controller = new AbortController();
        const timeoutId = setTimeout(() => controller.abort(), 90000); // 90 second timeout

        const response = await fetch('/api/incidents', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify({ tenantId: tenantId }),
            signal: controller.signal
        });

        clearTimeout(timeoutId);

        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }

        const data = await response.json();
        const incidents = data.incidents || [];
        renderIncidentsTable(incidents);
        
        console.log(`Loaded ${incidents.length} incidents`);
    } catch (error) {
        console.error('Error loading incidents:', error);
        if (error.name === 'AbortError') {
            alert('Loading incidents timed out. The request is taking longer than expected. Please try again or contact support if the issue persists.');
        } else {
            alert(`Error loading incidents: ${error.message}. Please try again.`);
        }
    } finally {
        hideLoadingIndicator();
    }
}

// Render incidents table using Grid.js
function renderIncidentsTable(incidents) {
    const container = document.getElementById('incidentTableContainer');
    container.innerHTML = '';
    
    if (!window.gridjs) {
        console.error('Grid.js not loaded');
        return;
    }

    if (window.incidentsGrid) {
        window.incidentsGrid.destroy();
    }

    // Filter out incidents with Display Names containing any variation of "email"
    // and also filter out incomplete incidents that only have Summary or missing essential data
    const filteredIncidents = incidents.filter(incident => {
        // Check if incident has essential properties
        const hasId = incident.Id || incident.id;
        const hasDisplayName = incident.DisplayName || incident.displayName;
        
        // Skip incidents without essential data
        if (!hasId || !hasDisplayName) {
            return false;
        }
        
        const displayName = hasDisplayName || '';
        // Case-insensitive check for "email" in display name
        return !displayName.toLowerCase().includes('email');
    });

    // Store filtered incidents globally for export
    allIncidents = filteredIncidents;

    const columns = [
        { 
            id: 'checkbox', 
            name: '', 
            sort: false, 
            formatter: (_, row) => {
                const incidentId = row.cells[1].data; // ID is in second column now
                return gridjs.html(`<input type='checkbox' class='incident-checkbox' data-incidentid='${incidentId}' />`);
            }
        },
        { 
            id: 'id', 
            name: 'Incident ID',
            width: '12%',
            formatter: (cell, row) => {
                const incidentId = row.cells[1].data;
                return gridjs.html(`<span class="incident-link" style="color: #00ff41; cursor: pointer;" data-id="${incidentId}">${incidentId}</span>`);
            }
        },
        { id: 'displayName', name: 'Display Name', width: '18%' },
        { id: 'severity', name: 'Severity', width: '7%' },
        { id: 'status', name: 'Status', width: '9%' },
        { id: 'classification', name: 'Classification', width: '11%' },
        { id: 'assignedTo', name: 'Assigned To', width: '13%' },
        { 
            id: 'incidentWebUrl', 
            name: 'Incident URL', 
            width: '12%',
            formatter: (cell) => {
                if (cell && cell.trim()) {
                    return gridjs.html(`<a href="${cell}" target="_blank" style="color: #00ff41; text-decoration: underline;" title="Open incident in Microsoft 365 Defender">View</a>`);
                }
                return 'N/A';
            }
        },
        { id: 'createdDateTime', name: 'Created', width: '9%' },
        { id: 'lastUpdateTime', name: 'Last Updated', width: '9%' }
    ];

    const data = filteredIncidents.map(incident => [
        '', // Checkbox column placeholder
        incident.Id || incident.id,
        incident.DisplayName || incident.displayName || 'No Display Name',
        incident.Severity || incident.severity || 'Unknown',
        incident.Status || incident.status || 'Unknown',
        incident.Classification || incident.classification || 'Unknown',
        incident.AssignedTo || incident.assignedTo || 'Unassigned',
        incident.IncidentWebUrl || incident.incidentWebUrl || '', // Incident URL
        formatDateTime(incident.CreatedDateTime || incident.createdDateTime),
        formatDateTime(incident.LastUpdateDateTime || incident.lastUpdateDateTime || incident.LastUpdateTime || incident.lastUpdateTime)
    ]);

    window.incidentsGrid = new gridjs.Grid({
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
        height: 'auto',
        className: {
            table: 'table table-striped table-hover'
        }
    }).render(container);

    // Add pagination event listener to update checkbox states
    window.incidentsGrid.on('ready', () => {
        setTimeout(() => {
            setupTableEventListeners();
            updateCheckboxStates();
        }, 100);
    });

    // Add event listener for page changes
    container.addEventListener('click', (e) => {
        if (e.target.classList.contains('gridjs-page') || 
            e.target.closest('.gridjs-pagination')) {
            setTimeout(() => {
                setupTableEventListeners();
                updateCheckboxStates();
            }, 100);
        }
    });

    // Add event listeners after grid renders
    setTimeout(() => {
        setupTableEventListeners();
        updateCheckboxStates();
        updateActionButtons(); // Ensure buttons are in correct state
    }, 500);

    // Update incident counts
    updateIncidentCounts(filteredIncidents);
}

// Setup event listeners for table actions
function setupTableEventListeners() {
    // Incident link clicks
    document.querySelectorAll('.incident-link').forEach(link => {
        link.addEventListener('click', (e) => {
            e.preventDefault();
            const incidentId = e.target.getAttribute('data-id');
            selectIncident(incidentId);
        });
    });

    // Checkbox event listeners
    document.querySelectorAll('.incident-checkbox').forEach(checkbox => {
        checkbox.addEventListener('change', function() {
            const incidentId = this.getAttribute('data-incidentid');
            if (this.checked) {
                if (!selectedIncidentIds.includes(incidentId)) {
                    selectedIncidentIds.push(incidentId);
                }
            } else {
                selectedIncidentIds = selectedIncidentIds.filter(id => id !== incidentId);
            }
            updateSelectedCount();
            updateActionButtons();
        });
    });
}

// Function to update checkbox states when changing pages
function updateCheckboxStates() {
    document.querySelectorAll('.incident-checkbox').forEach(checkbox => {
        const incidentId = checkbox.getAttribute('data-incidentid');
        checkbox.checked = selectedIncidentIds.includes(incidentId);
    });
}

// Function to update selected count display
function updateSelectedCount() {
    const countElement = document.getElementById('selectedCount');
    if (countElement) {
        countElement.textContent = `${selectedIncidentIds.length} incident(s) selected`;
    }
}

// Function to update action buttons based on selection
function updateActionButtons() {
    const updateBtn = document.getElementById('updateIncidentBtn');
    const commentBtn = document.getElementById('addCommentBtn');
    const hasSelection = selectedIncidentIds.length > 0;
    
    if (updateBtn) {
        updateBtn.disabled = !hasSelection;
        // Force re-enable if disabled when it should be enabled
        if (hasSelection && updateBtn.disabled) {
            updateBtn.disabled = false;
        }
        
        // Ensure the button is clickable (remove any CSS that might disable it)
        if (hasSelection) {
            updateBtn.style.pointerEvents = 'auto';
            updateBtn.style.opacity = '1';
        }
    }
    if (commentBtn) {
        commentBtn.disabled = !hasSelection;
        // Force re-enable if disabled when it should be enabled
        if (hasSelection && commentBtn.disabled) {
            commentBtn.disabled = false;
        }
        
        // Ensure the button is clickable (remove any CSS that might disable it)
        if (hasSelection) {
            commentBtn.style.pointerEvents = 'auto';
            commentBtn.style.opacity = '1';
        }
    }
    
    console.log(`Action buttons updated: hasSelection=${hasSelection}, selectedIds=${selectedIncidentIds.length}`);
}

// Function to select all incidents on current page
function selectAllOnPage() {
    document.querySelectorAll('.incident-checkbox').forEach(checkbox => {
        checkbox.checked = true;
        const incidentId = checkbox.getAttribute('data-incidentid');
        if (!selectedIncidentIds.includes(incidentId)) {
            selectedIncidentIds.push(incidentId);
        }
    });
    updateSelectedCount();
    updateActionButtons();
}

// Function to clear all selections
function clearAllSelections() {
    selectedIncidentIds = [];
    document.querySelectorAll('.incident-checkbox').forEach(checkbox => {
        checkbox.checked = false;
    });
    updateSelectedCount();
    updateActionButtons();
    
    // Also clear legacy single selection
    window.selectedIncidentId = null;
    document.querySelectorAll('.incident-link').forEach(link => {
        link.style.fontWeight = 'normal';
    });
}

// Select an incident and enable action buttons
function selectIncident(incidentId) {
    // Clear previous selections and select this one
    selectedIncidentIds = [incidentId];
    
    // Update checkbox states
    document.querySelectorAll('.incident-checkbox').forEach(checkbox => {
        const id = checkbox.getAttribute('data-incidentid');
        checkbox.checked = (id === incidentId);
    });
    
    // Update legacy single selection for backward compatibility
    window.selectedIncidentId = incidentId;
    
    console.log('Selected incident:', incidentId);
    
    // Update UI
    updateActionButtons();
    updateSelectedCount();
    
    // Highlight selected row (optional visual feedback)
    document.querySelectorAll('.incident-link').forEach(link => {
        link.style.fontWeight = link.getAttribute('data-id') === incidentId ? 'bold' : 'normal';
    });
}

// Show update incident modal
function showUpdateIncidentModal() {
    if (selectedIncidentIds.length === 0) {
        alert('Please select at least one incident first.');
        return;
    }
    
    const modal = document.getElementById('updateIncidentModal');
    if (modal) {
        // Clear form first
        clearUpdateForm();
        
        // Update modal title to show selected count
        const modalTitle = modal.querySelector('h2');
        if (modalTitle) {
            modalTitle.textContent = selectedIncidentIds.length === 1 
                ? `Update Incident (${selectedIncidentIds[0]})` 
                : `Update ${selectedIncidentIds.length} Incidents`;
        }
        
        // Show modal
        modal.style.display = 'block';
    }
}

// Show add comment modal  
function showAddCommentModal() {
    if (selectedIncidentIds.length === 0) {
        alert('Please select at least one incident first.');
        return;
    }
    
    const modal = document.getElementById('addCommentModal');
    if (modal) {
        // Clear form first
        clearCommentForm();
        
        // Update modal title to show selected count
        const modalTitle = modal.querySelector('h2');
        if (modalTitle) {
            modalTitle.textContent = selectedIncidentIds.length === 1 
                ? `Add Comment to Incident (${selectedIncidentIds[0]})` 
                : `Add Comment to ${selectedIncidentIds.length} Incidents`;
        }
        
        // Show modal
        modal.style.display = 'block';
    }
}

// Handle update incident form submission
async function updateIncident() {
    const tenantId = getTenantId();
    
    if (!tenantId) {
        alert('Please select a tenant first.');
        return;
    }
    
    if (selectedIncidentIds.length === 0) {
        alert('Please select at least one incident first.');
        return;
    }

    const updateData = {
        status: document.getElementById('incidentStatus').value || null,
        assignedTo: document.getElementById('incidentAssignedTo').value || null,
        classification: document.getElementById('incidentClassification').value || null,
        determination: document.getElementById('incidentDetermination').value || null,
        severity: document.getElementById('incidentSeverity').value || null,
        displayName: document.getElementById('incidentDisplayName').value || null,
        description: document.getElementById('incidentDescription').value || null
    };

    try {
        showLoadingIndicator(`Updating ${selectedIncidentIds.length} incident(s)...`);
        
        // Send all incident IDs in a single request
        const payload = {
            tenantId: tenantId,
            incidentIds: selectedIncidentIds,
            ...updateData
        };

        const response = await fetch('/api/incidents/update', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify(payload)
        });

        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }

        const result = await response.json();
        
        if (result.success || result.Status === 'Success') {
            // Close modal immediately
            closeModal('updateIncidentModal');
            
            // Show success message
            alert(result.message || `Successfully updated ${selectedIncidentIds.length} incident(s)!`);
            
            // Keep selected incidents for continued operations
            const previouslySelected = [...selectedIncidentIds];
            
            // Reload incidents to get updated data
            await loadIncidents();
            
            // Restore selection after reload if incidents still exist
            setTimeout(() => {
                selectedIncidentIds = previouslySelected;
                updateCheckboxStates();
                updateActionButtons();
                updateSelectedCount();
                console.log('Restored selection after update:', selectedIncidentIds.length);
            }, 600);
        } else {
            throw new Error(result.error || result.Message || 'Update failed');
        }
        
    } catch (error) {
        console.error('Error updating incidents:', error);
        alert('Error updating incidents: ' + error.message);
    } finally {
        hideLoadingIndicator();
        
        // Ensure buttons are re-enabled
        updateActionButtons();
    }
}

// Handle add comment form submission
async function addComment() {
    const tenantId = getTenantId();
    const comment = document.getElementById('incidentComment').value;
    
    if (!tenantId) {
        alert('Please select a tenant first.');
        return;
    }
    
    if (selectedIncidentIds.length === 0) {
        alert('Please select at least one incident first.');
        return;
    }

    if (!comment.trim()) {
        alert('Please enter a comment.');
        return;
    }

    try {
        showLoadingIndicator(`Adding comment to ${selectedIncidentIds.length} incident(s)...`);
        
        // Send all incident IDs in a single request
        const commentData = {
            tenantId: tenantId,
            incidentIds: selectedIncidentIds,
            comment: comment.trim()
        };

        const response = await fetch('/api/incidents/comment', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json',
            },
            body: JSON.stringify(commentData)
        });

        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }

        const result = await response.json();
        
        if (result.success || result.Status === 'Success') {
            // Close modal immediately
            closeModal('addCommentModal');
            
            // Show success message
            alert(result.message || `Successfully added comment to ${selectedIncidentIds.length} incident(s)!`);
            
            // Keep selected incidents for continued operations
            const previouslySelected = [...selectedIncidentIds];
            
            // Reload incidents to get updated data
            await loadIncidents();
            
            // Restore selection after reload if incidents still exist
            setTimeout(() => {
                selectedIncidentIds = previouslySelected;
                updateCheckboxStates();
                updateActionButtons();
                updateSelectedCount();
                console.log('Restored selection after comment:', selectedIncidentIds.length);
            }, 600);
        } else {
            throw new Error(result.error || result.Message || 'Comment addition failed');
        }
        
    } catch (error) {
        console.error('Error adding comment:', error);
        alert('Error adding comment: ' + error.message);
    } finally {
        hideLoadingIndicator();
        
        // Ensure buttons are re-enabled
        updateActionButtons();
    }
}

// Function to update incident counts by severity
function updateIncidentCounts(incidents) {
    const counts = {
        total: incidents.length,
        high: 0,
        medium: 0,
        low: 0
    };

    incidents.forEach(incident => {
        const severity = (incident.Severity || incident.severity || '').toLowerCase();
        switch (severity) {
            case 'high':
                counts.high++;
                break;
            case 'medium':
                counts.medium++;
                break;
            case 'low':
                counts.low++;
                break;
        }
    });

    // Update the display elements
    const totalElement = document.getElementById('totalIncidentCount');
    const highElement = document.getElementById('highSeverityCount');
    const mediumElement = document.getElementById('mediumSeverityCount');
    const lowElement = document.getElementById('lowSeverityCount');

    if (totalElement) totalElement.textContent = `Total: ${counts.total}`;
    if (highElement) highElement.textContent = `High: ${counts.high}`;
    if (mediumElement) mediumElement.textContent = `Medium: ${counts.medium}`;
    if (lowElement) lowElement.textContent = `Low: ${counts.low}`;
}

// Track event listeners to prevent duplicates
let eventListenersSetup = false;

// Setup all event listeners (only once)
function setupEventListeners() {
    if (eventListenersSetup) {
        console.log('Event listeners already set up, skipping...');
        return;
    }
    
    console.log('Setting up event listeners...');
    
    // Tenant dropdown change event
    const tenantDropdown = document.getElementById('tenantDropdown');
    if (tenantDropdown) {
        tenantDropdown.addEventListener('change', function() {
            const selectedTenant = this.value;
            if (selectedTenant) {
                sessionStorage.setItem('TenantId', selectedTenant);
                console.log('Selected tenant:', selectedTenant);
                loadIncidents();
            } else {
                sessionStorage.removeItem('TenantId');
            }
        });
    }

    // Refresh incidents button
    const refreshBtn = document.getElementById('refreshIncidentsBtn');
    if (refreshBtn) {
        refreshBtn.addEventListener('click', loadIncidents);
    }

    // Update incident button
    const updateBtn = document.getElementById('updateIncidentBtn');
    if (updateBtn) {
        updateBtn.addEventListener('click', function(e) {
            e.preventDefault();
            e.stopPropagation();
            console.log('Update button clicked, selected incidents:', selectedIncidentIds.length);
            showUpdateIncidentModal();
        });
    }

    // Add comment button
    const commentBtn = document.getElementById('addCommentBtn');
    if (commentBtn) {
        commentBtn.addEventListener('click', function(e) {
            e.preventDefault();
            e.stopPropagation();
            console.log('Comment button clicked, selected incidents:', selectedIncidentIds.length);
            showAddCommentModal();
        });
    }

    // Select All on Page button
    const selectAllPageBtn = document.getElementById('selectAllPageBtn');
    if (selectAllPageBtn) {
        selectAllPageBtn.addEventListener('click', selectAllOnPage);
    }

    // Clear All Selections button
    const clearSelectionsBtn = document.getElementById('clearSelectionsBtn');
    if (clearSelectionsBtn) {
        clearSelectionsBtn.addEventListener('click', clearAllSelections);
    }

    // Export CSV button
    const exportIncidentsBtn = document.getElementById('exportIncidentsBtn');
    if (exportIncidentsBtn) {
        exportIncidentsBtn.addEventListener('click', () => exportIncidentsCSV(allIncidents));
    }

    // Modal close buttons
    const closeUpdate = document.querySelector('.close-update');
    if (closeUpdate) {
        closeUpdate.addEventListener('click', () => {
            closeModal('updateIncidentModal');
        });
    }

    const closeComment = document.querySelector('.close-comment');
    if (closeComment) {
        closeComment.addEventListener('click', () => {
            closeModal('addCommentModal');
        });
    }

    // Modal cancel buttons
    const cancelUpdateBtn = document.getElementById('cancelUpdateBtn');
    if (cancelUpdateBtn) {
        cancelUpdateBtn.addEventListener('click', () => {
            closeModal('updateIncidentModal');
        });
    }

    const cancelCommentBtn = document.getElementById('cancelCommentBtn');
    if (cancelCommentBtn) {
        cancelCommentBtn.addEventListener('click', () => {
            closeModal('addCommentModal');
        });
    }

    // Modal confirm buttons
    const confirmUpdateBtn = document.getElementById('confirmUpdateBtn');
    if (confirmUpdateBtn) {
        confirmUpdateBtn.addEventListener('click', updateIncident);
    }

    const confirmCommentBtn = document.getElementById('confirmCommentBtn');
    if (confirmCommentBtn) {
        confirmCommentBtn.addEventListener('click', addComment);
    }

    // Close modal when clicking outside
    window.addEventListener('click', (event) => {
        const updateModal = document.getElementById('updateIncidentModal');
        const commentModal = document.getElementById('addCommentModal');
        
        if (event.target === updateModal) {
            closeModal('updateIncidentModal');
        }
        if (event.target === commentModal) {
            closeModal('addCommentModal');
        }
    });
    
    eventListenersSetup = true;
}

// Helper function to properly close modals
function closeModal(modalId) {
    const modal = document.getElementById(modalId);
    if (modal) {
        modal.style.display = 'none';
        
        // Clear form fields when closing
        if (modalId === 'updateIncidentModal') {
            clearUpdateForm();
        } else if (modalId === 'addCommentModal') {
            clearCommentForm();
        }
    }
}

// Helper function to clear update form
function clearUpdateForm() {
    const fields = ['incidentStatus', 'incidentSeverity', 'incidentClassification', 
                   'incidentDetermination', 'incidentAssignedTo', 'incidentDisplayName', 'incidentDescription'];
    fields.forEach(fieldId => {
        const field = document.getElementById(fieldId);
        if (field) {
            if (field.tagName === 'SELECT') {
                field.value = '';
            } else {
                field.value = '';
            }
        }
    });
}

// Helper function to clear comment form
function clearCommentForm() {
    const commentField = document.getElementById('incidentComment');
    if (commentField) {
        commentField.value = '';
    }
}

// Debug function to check button states
function debugButtonStates() {
    const updateBtn = document.getElementById('updateIncidentBtn');
    const commentBtn = document.getElementById('addCommentBtn');
    
    console.log('=== Button Debug Info ===');
    console.log('Selected incidents:', selectedIncidentIds.length);
    console.log('Update button - exists:', !!updateBtn, 'disabled:', updateBtn?.disabled, 'clickable:', updateBtn?.style.pointerEvents !== 'none');
    console.log('Comment button - exists:', !!commentBtn, 'disabled:', commentBtn?.disabled, 'clickable:', commentBtn?.style.pointerEvents !== 'none');
    console.log('=========================');
}

// Make debug function available globally for troubleshooting
window.debugIncidentButtons = debugButtonStates;

// Tenant Management Functions (simplified for dropdown only)
async function loadTenants() {
    try {
        console.log('Loading tenants from backend...');
        
        // Add timeout to handle Azure Function cold starts
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

// Function to export incidents data to CSV
function exportIncidentsCSV(incidentsData) {
    if (!Array.isArray(incidentsData) || incidentsData.length === 0) {
        alert('No incident data available to export.');
        return;
    }
    
    // Define friendly column names mapping
    const columnMapping = {
        'Id': 'Incident ID',
        'id': 'Incident ID',
        'DisplayName': 'Display Name',
        'displayName': 'Display Name',
        'Severity': 'Severity',
        'severity': 'Severity',
        'Status': 'Status',
        'status': 'Status',
        'Classification': 'Classification',
        'classification': 'Classification',
        'AssignedTo': 'Assigned To',
        'assignedTo': 'Assigned To',
        'IncidentWebUrl': 'Incident URL',
        'incidentWebUrl': 'Incident URL',
        'CreatedDateTime': 'Created',
        'createdDateTime': 'Created',
        'LastUpdateDateTime': 'Last Updated',
        'lastUpdateDateTime': 'Last Updated',
        'LastUpdateTime': 'Last Updated',
        'lastUpdateTime': 'Last Updated'
    };
    
    // Get all unique keys from the incidents data
    const allKeys = new Set();
    incidentsData.forEach(incident => {
        Object.keys(incident).forEach(key => allKeys.add(key));
    });
    
    // Create CSV headers using friendly names
    const headers = Array.from(allKeys).map(key => columnMapping[key] || key);
    
    // Create CSV content
    let csvContent = headers.join(',') + '\n';
    
    // Add data rows
    incidentsData.forEach(incident => {
        const row = Array.from(allKeys).map(key => {
            let value = incident[key];
            
            // Handle arrays
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
        const filename = `incidents_export_${timestamp}.csv`;
        
        const url = URL.createObjectURL(blob);
        link.setAttribute('href', url);
        link.setAttribute('download', filename);
        link.style.visibility = 'hidden';
        document.body.appendChild(link);
        link.click();
        document.body.removeChild(link);
        
        console.log(`Exported ${incidentsData.length} incidents to ${filename}`);
    } else {
        alert('Your browser does not support file downloads.');
    }
}

// Utility function to format datetime
function formatDateTime(dateTimeString) {
    if (!dateTimeString) return '';
    const date = new Date(dateTimeString);
    return date.toLocaleString('en-US', {
        year: 'numeric',
        month: '2-digit',
        day: '2-digit',
        hour: '2-digit',
        minute: '2-digit',
        second: '2-digit'
    });
}

