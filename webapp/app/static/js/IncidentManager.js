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
        loadIncidents().then(() => {
            // Mark auto-load as completed
            if (typeof window.markAutoLoadCompleted === 'function') {
                window.markAutoLoadCompleted();
            }
        }).catch((error) => {
            console.error('Error in incidents auto-load:', error);
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

// Main function to load incidents
async function loadIncidents() {
    const tenantId = getTenantId();
    if (!tenantId) {
        console.warn('No tenant selected for loading incidents');
        return;
    }

    console.log('Loading incidents...');
    window.showContentLoading('Loading Incidents');

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
        window.hideContentLoading();
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

    // Filter out incidents with Display Names containing any variation of "email" or "dlp"
    // and also filter out incomplete incidents that only have Summary or missing essential data
    const filteredIncidents = incidents.filter(incident => {
        // Check if incident has essential properties
        const hasId = incident.Id || incident.id;
        const hasDisplayName = incident.DisplayName || incident.displayName;
        
        // Skip incidents without essential data
        if (!hasId || !hasDisplayName) {
            return false;
        }
        
        const displayName = hasDisplayName.toLowerCase() || '';
        // Case-insensitive check for "email" or "dlp" in display name
        return !displayName.includes('email') && !displayName.includes('dlp');
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
            width: '11%',
            formatter: (cell) => {
                if (cell && cell.trim()) {
                    return gridjs.html(`<a href="${cell}" target="_blank" style="color: #00ff41; text-decoration: underline;" title="Open incident in Microsoft 365 Defender">View</a>`);
                }
                return 'N/A';
            }
        },
        { 
            id: 'relatedAlerts', 
            name: 'Related Alerts', 
            width: '10%',
            sort: false,
            formatter: (_, row) => {
                const incidentId = row.cells[1].data; // ID is in second column
                return gridjs.html(`<button class="view-alerts-btn cta-button" data-incidentid="${incidentId}" style="padding: 0.2em 0.6em; font-size: 0.8em; background: #142a17; border: 1px solid #00ff41; color: #00ff41; cursor: pointer;">View</button>`);
            }
        },
        { id: 'createdDateTime', name: 'Created', width: '8%' },
        { id: 'lastUpdateTime', name: 'Last Updated', width: '8%' }
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
        '', // Related Alerts column placeholder - will be populated by formatter
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
    console.log('=== Setting up table event listeners ===');
    
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

    // View Alerts button event listeners - Use event delegation for dynamically created buttons
    console.log('Setting up View Alerts event delegation...');
    const tableContainer = document.getElementById('incidentTableContainer');
    console.log('Table container found:', !!tableContainer);
    if (tableContainer) {
        // Remove any existing event listeners to prevent duplicates
        tableContainer.removeEventListener('click', handleViewAlertsClick);
        // Add event delegation for View Alerts buttons
        tableContainer.addEventListener('click', handleViewAlertsClick);
        console.log('View Alerts event delegation set up on table container');
    } else {
        console.error('Table container not found for View Alerts event delegation');
    }
}

// Event delegation handler for View Alerts buttons
function handleViewAlertsClick(e) {
    console.log('Click detected in table container:', e.target);
    console.log('Target classes:', e.target.className);
    console.log('Target tag:', e.target.tagName);
    
    // Check if the clicked element is a View Alerts button
    if (e.target && e.target.classList.contains('view-alerts-btn')) {
        console.log('View Alerts button clicked via event delegation!');
        e.preventDefault();
        e.stopPropagation();
        
        const incidentId = e.target.getAttribute('data-incidentid');
        console.log('View Alerts button clicked! Incident ID:', incidentId);
        
        if (incidentId) {
            viewIncidentAlerts(incidentId, e.target);
        } else {
            console.error('No incident ID found on View Alerts button');
        }
    }
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
        window.showContentLoading(`Updating ${selectedIncidentIds.length} incident(s)...`);
        
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
        window.hideContentLoading();
        
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
        window.showContentLoading(`Adding comment to ${selectedIncidentIds.length} incident(s)...`);
        
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
        window.hideContentLoading();
        
        // Ensure buttons are re-enabled
        updateActionButtons();
    }
}

// Function to view incident alerts
async function viewIncidentAlerts(incidentId, button) {
    console.log('=== viewIncidentAlerts called ===');
    console.log('Incident ID:', incidentId);
    console.log('Button:', button);
    console.log('Viewing alerts for incident:', incidentId);
    
    const tenantId = getTenantId();
    console.log('Tenant ID:', tenantId);
    if (!tenantId) {
        alert('Please select a tenant first');
        return;
    }

    // Show loading state on button
    const originalText = button.textContent;
    button.textContent = 'Loading...';  
    button.disabled = true;
    button.style.opacity = '0.6';

    try {
        // Show modal immediately with loading state
        console.log('Showing alerts modal...');
        showAlertsModal(incidentId);
        
        // Make API call to get alerts
        console.log('Making API call to /api/incidents/alerts');
        const response = await fetch('/api/incidents/alerts', {
            method: 'POST',
            headers: {
                'Content-Type': 'application/json'
            },
            body: JSON.stringify({
                tenantId: tenantId,
                incidentId: incidentId
            })
        });

        console.log('API response status:', response.status);
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }

        const result = await response.json();
        console.log('API response data:', result);
        console.log('result.success:', result.success);
        console.log('result.alerts:', result.alerts);
        console.log('result.alerts type:', typeof result.alerts);
        console.log('result.alerts isArray:', Array.isArray(result.alerts));
        
        if (result.success) {
            const alertsData = result.alerts || [];
            console.log('Calling displayAlertsData with:', alertsData);
            displayAlertsData(alertsData, incidentId);
        } else {
            throw new Error(result.error || 'Failed to retrieve alerts');
        }
        
    } catch (error) {
        console.error('Error fetching incident alerts:', error);
        displayAlertsError(error.message);
    } finally {
        // Restore button state
        button.textContent = originalText;
        button.disabled = false;
        button.style.opacity = '1';
        console.log('=== viewIncidentAlerts completed ===');
    }
}

// Function to show the alerts modal
function showAlertsModal(incidentId) {
    const modal = document.getElementById('relatedAlertsModal');
    if (modal) {
        // Update modal title
        const modalTitle = modal.querySelector('h2');
        if (modalTitle) {
            modalTitle.textContent = `Related Alerts - Incident ${incidentId}`;
        }
        
        // Reset modal content to loading state
        const loadingDiv = document.getElementById('alertsLoading');
        const dataDiv = document.getElementById('alertsData');
        const errorDiv = document.getElementById('alertsError');
        
        if (loadingDiv) loadingDiv.style.display = 'block';
        if (dataDiv) dataDiv.style.display = 'none';
        if (errorDiv) errorDiv.style.display = 'none';
        
        // Show modal
        modal.style.display = 'block';
    }
}

// Function to display alerts data
function displayAlertsData(alerts, incidentId) {
    console.log('displayAlertsData called with:', { alerts, incidentId, alertsType: typeof alerts, isArray: Array.isArray(alerts) });
    
    const loadingDiv = document.getElementById('alertsLoading');
    const dataDiv = document.getElementById('alertsData');
    const errorDiv = document.getElementById('alertsError');
    
    if (loadingDiv) loadingDiv.style.display = 'none';
    if (errorDiv) errorDiv.style.display = 'none';
    
    if (!dataDiv) return;
    
    // Ensure alerts is an array
    if (!Array.isArray(alerts)) {
        console.error('displayAlertsData: alerts is not an array:', alerts);
        displayAlertsError(`Invalid alerts data format. Expected array, got ${typeof alerts}`);
        return;
    }
    
    if (!alerts || alerts.length === 0) {
        dataDiv.innerHTML = `
            <div style="text-align: center; color: #7fff7f; padding: 40px;">
                <div style="font-size: 1.2em; margin-bottom: 15px;">No alerts found</div>
                <div>Incident ${incidentId} has no related alerts.</div>
            </div>
        `;
    } else {
        let html = `
            <div style="margin-bottom: 20px; color: #7fff7f;">
                <strong>Found ${alerts.length} alert(s) for incident ${incidentId}</strong>
            </div>
        `;
        
        alerts.forEach((alert, index) => {
            html += formatAlertCard(alert, index);
        });
        
        dataDiv.innerHTML = html;
    }
    
    dataDiv.style.display = 'block';
}

// Function to format an individual alert card
function formatAlertCard(alert, index) {
    const alertId = alert.Id || alert.id || 'Unknown';
    const title = alert.Title || alert.title || alert.DisplayName || alert.displayName || 'Untitled Alert';
    const severity = (alert.Severity || alert.severity || 'Unknown').toLowerCase();
    const status = alert.Status || alert.status || 'Unknown';
    const createdDateTime = alert.CreatedDateTime || alert.createdDateTime || alert.AlertCreationTime || alert.alertCreationTime;
    const description = alert.Description || alert.description || '';
    const category = alert.Category || alert.category || '';
    
    // Format severity class for styling
    const severityClass = `severity-${severity}`;
    
    let html = `
        <div class="alert-card">
            <div class="alert-header">
                <div class="alert-title">${escapeHtml(title)}</div>
                <div class="alert-severity ${severityClass}">${severity.toUpperCase()}</div>
            </div>
            <div class="alert-details">
                <div class="alert-field">
                    <span class="alert-field-label">Alert ID:</span>
                    <span class="alert-field-value">${escapeHtml(alertId)}</span>
                </div>
                <div class="alert-field">
                    <span class="alert-field-label">Status:</span>
                    <span class="alert-field-value">${escapeHtml(status)}</span>
                </div>
    `;
    
    if (category) {
        html += `
                <div class="alert-field">
                    <span class="alert-field-label">Category:</span>
                    <span class="alert-field-value">${escapeHtml(category)}</span>
                </div>
        `;
    }
    
    if (createdDateTime) {
        html += `
                <div class="alert-field">
                    <span class="alert-field-label">Created:</span>
                    <span class="alert-field-value">${formatDateTime(createdDateTime)}</span>
                </div>
        `;
    }
    
    if (description) {
        html += `
                <div class="alert-field">
                    <span class="alert-field-label">Description:</span>
                    <span class="alert-field-value">${escapeHtml(description)}</span>
                </div>
        `;
    }
    
    // Add evidence if available
    const evidence = alert.Evidence || alert.evidence || [];
    if (evidence && evidence.length > 0) {
        html += `
                <div class="evidence-container">
                    <div class="evidence-header">Evidence (${evidence.length} items):</div>
        `;
        
        evidence.forEach((evidenceItem, evidenceIndex) => {
            html += formatEvidenceItem(evidenceItem, evidenceIndex);
        });
        
        html += `
                </div>
        `;
    }
    
    html += `
            </div>
        </div>
    `;
    
    return html;
}

// Function to format evidence items
function formatEvidenceItem(evidence, index) {
    const entityType = evidence.EntityType || evidence.entityType || 'Unknown';
    const sha1 = evidence.Sha1 || evidence.sha1 || '';
    const fileName = evidence.FileName || evidence.fileName || '';
    const filePath = evidence.FilePath || evidence.filePath || '';
    const processId = evidence.ProcessId || evidence.processId || '';
    const commandLine = evidence.ProcessCommandLine || evidence.processCommandLine || '';
    const accountName = evidence.AccountName || evidence.accountName || '';
    const domainName = evidence.DomainName || evidence.domainName || '';
    const ipAddress = evidence.IpAddress || evidence.ipAddress || '';
    const url = evidence.Url || evidence.url || '';
    
    let html = `
        <div class="evidence-item">
            <div class="alert-field">
                <span class="alert-field-label">Type:</span>
                <span class="alert-field-value">${escapeHtml(entityType)}</span>
            </div>
    `;
    
    // Add relevant fields based on evidence type
    if (fileName) {
        html += `
            <div class="alert-field">
                <span class="alert-field-label">File Name:</span>
                <span class="alert-field-value">${escapeHtml(fileName)}</span>
            </div>
        `;
    }
    
    if (filePath) {
        html += `
            <div class="alert-field">
                <span class="alert-field-label">File Path:</span>
                <span class="alert-field-value">${escapeHtml(filePath)}</span>
            </div>
        `;
    }
    
    if (sha1) {
        html += `
            <div class="alert-field">
                <span class="alert-field-label">SHA1:</span>
                <span class="alert-field-value" style="font-family: monospace; font-size: 0.9em;">${escapeHtml(sha1)}</span>
            </div>
        `;
    }
    
    if (processId) {
        html += `
            <div class="alert-field">
                <span class="alert-field-label">Process ID:</span>
                <span class="alert-field-value">${escapeHtml(processId)}</span>
            </div>
        `;
    }
    
    if (commandLine) {
        html += `
            <div class="alert-field">
                <span class="alert-field-label">Command Line:</span>
                <span class="alert-field-value" style="font-family: monospace; font-size: 0.9em;">${escapeHtml(commandLine)}</span>
            </div>
        `;
    }
    
    if (accountName) {
        html += `
            <div class="alert-field">
                <span class="alert-field-label">Account:</span>
                <span class="alert-field-value">${escapeHtml(domainName ? `${domainName}\\${accountName}` : accountName)}</span>
            </div>
        `;
    }
    
    if (ipAddress) {
        html += `
            <div class="alert-field">
                <span class="alert-field-label">IP Address:</span>
                <span class="alert-field-value">${escapeHtml(ipAddress)}</span>
            </div>
        `;
    }
    
    if (url) {
        html += `
            <div class="alert-field">
                <span class="alert-field-label">URL:</span>
                <span class="alert-field-value" style="word-break: break-all;">${escapeHtml(url)}</span>
            </div>
        `;
    }
    
    html += `
        </div>
    `;
    
    return html;
}

// Function to display error in alerts modal
function displayAlertsError(errorMessage) {
    const loadingDiv = document.getElementById('alertsLoading');
    const dataDiv = document.getElementById('alertsData');
    const errorDiv = document.getElementById('alertsError');
    
    if (loadingDiv) loadingDiv.style.display = 'none';
    if (dataDiv) dataDiv.style.display = 'none';
    
    if (errorDiv) {
        errorDiv.innerHTML = `
            <div style="text-align: center; color: #ff4444; padding: 40px;">
                <div style="font-size: 1.2em; margin-bottom: 15px;">Error Loading Alerts</div>
                <div>${escapeHtml(errorMessage)}</div>
            </div>
        `;
        errorDiv.style.display = 'block';
    }
}

// Utility function to escape HTML
function escapeHtml(text) {
    if (!text) return '';
    const div = document.createElement('div');
    div.textContent = text;
    return div.innerHTML;
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

    const closeAlerts = document.querySelector('.close-alerts');
    if (closeAlerts) {
        closeAlerts.addEventListener('click', () => {
            closeModal('relatedAlertsModal');
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

    const closeAlertsBtn = document.getElementById('closeAlertsBtn');
    if (closeAlertsBtn) {
        closeAlertsBtn.addEventListener('click', () => {
            closeModal('relatedAlertsModal');
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
        const alertsModal = document.getElementById('relatedAlertsModal');
        
        if (event.target === updateModal) {
            closeModal('updateIncidentModal');
        }
        if (event.target === commentModal) {
            closeModal('addCommentModal');
        }
        if (event.target === alertsModal) {
            closeModal('relatedAlertsModal');
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
        
        // Update platform loading progress
        if (typeof window.updatePlatformLoadingProgress === 'function') {
            window.updatePlatformLoadingProgress('Loading tenants for Incident Manager...', 30);
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

