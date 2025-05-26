window.addEventListener('DOMContentLoaded', () => {
    const tenantInput = document.getElementById('tenantInput');
    const saveBtn = document.getElementById('saveTenantBtn');
    const refreshIndicatorsBtn = document.getElementById('refreshIndicatorsBtn');
    const tiManualForm = document.getElementById('tiManualForm');
    const tiCsvImportBtn = document.getElementById('tiCsvImportBtn');
    const refreshDetectionsBtn = document.getElementById('refreshDetectionsBtn');
    const syncDetectionsBtn = document.getElementById('syncDetectionsBtn');
    const savedTenant = sessionStorage.getItem('TenantId');
    if (savedTenant) tenantInput.value = savedTenant;
    saveBtn.onclick = function() {
        const val = tenantInput.value.trim();
        if (!val) {
            alert('Please enter a Tenant ID.');
            return;
        }
        sessionStorage.setItem('TenantId', val);
        alert('Tenant ID saved for this session.');
    };
    refreshIndicatorsBtn.addEventListener('click', loadIndicators);
    tiManualForm.addEventListener('submit', tiManualFormSubmit);
    tiCsvImportBtn.addEventListener('click', tiCsvImportBtnClick);
    refreshDetectionsBtn.addEventListener('click', loadDetections);
    syncDetectionsBtn.addEventListener('click', syncDetections);
    loadIndicators();
    loadDetections();
});

function getTenantId() {
    const tenantInput = document.getElementById('tenantInput');
    return tenantInput ? tenantInput.value.trim() : '';
}

async function loadIndicators() {
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
    renderIndicatorsTable(Array.isArray(indicators) ? indicators : []);
}

function renderIndicatorsTable(indicators) {
    const container = document.getElementById('iocTableContainer');
    container.innerHTML = '';
    if (!window.gridjs) return;
    if (window.iocGrid) window.iocGrid.destroy();
    const columns = [
        { id: 'Id', name: 'Id' },
        { id: 'IndicatorValue', name: 'Value' },
        { id: 'IndicatorType', name: 'Type' },
        { id: 'Action', name: 'Action' },
        { id: 'Severity', name: 'Severity' },
        { id: 'Title', name: 'Title' },
        { id: 'CreationTimeDateTimeUtc', name: 'Created' },
    ];
    const data = indicators.map(i => [i.Id, i.IndicatorValue, i.IndicatorType, i.Action, i.Severity, i.Title, i.CreationTimeDateTimeUtc, i.Description]);
    window.iocGrid = new gridjs.Grid({ columns, data, search: true, sort: true, pagination: true, autoWidth: true, width: '100%', height: 'auto' }).render(container);
}

function getTypeAndFunctionForAdd(type) {
    switch (type) {
        case 'Certificate (SHA1)':
            return { func: 'InvokeTiCert', param: 'Sha1s' };
        case 'SHA1':
            return { func: 'InvokeTiFile', param: 'Sha1s' };
        case 'SHA256':
            return { func: 'InvokeTiFile', param: 'Sha256s' };
        case 'IP':
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
    if (!mapping) { alert('Invalid type selected.'); return; }
    const url = `https://${window.FUNCURL}/api/MDETIManager?code=${window.FUNCKEY}`;
    const payload = { TenantId: tenantId, Function: mapping.func };
    payload[mapping.param] = [value];
    await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    loadIndicators();
}

function getTypeAndFunctionForDelete(type) {
    switch (type) {
        case 'Certificate (SHA1)':
            return { func: 'UndoTiCert', param: 'Sha1s' };
        case 'SHA1':
            return { func: 'UndoTiFile', param: 'Sha1s' };
        case 'SHA256':
            return { func: 'UndoTiFile', param: 'Sha256s' };
        case 'IP':
            return { func: 'UndoTiIP', param: 'IPs' };
        case 'URL':
            return { func: 'UndoTiURL', param: 'URLs' };
        default:
            return null;
    }
}

async function tiCsvImportBtnClick() {
    const fileInput = document.getElementById('tiCsvInput');
    const status = document.getElementById('tiCsvStatus');
    const tenantId = getTenantId();
    if (!tenantId) { alert('Tenant ID is required.'); return; }
    if (!fileInput.files.length) { alert('Please select a CSV file.'); return; }
    const url = `https://${window.FUNCURL}/api/MDETIManager?code=${window.FUNCKEY}`;
    const file = fileInput.files[0];
    const reader = new FileReader();
    reader.onload = async function(e) {
        const text = e.target.result;
        const lines = text.split(/\r?\n/).filter(l => l.trim());
        if (lines.length < 2) { status.textContent = 'CSV must have a header and at least one row.'; return; }
        const header = lines[0].split(',').map(h => h.trim().toLowerCase());
        const typeIdx = header.indexOf('type');
        const valueIdx = header.indexOf('value');
        if (typeIdx === -1 || valueIdx === -1) { status.textContent = 'CSV must have columns: Type,Value'; return; }
        const tiData = { Sha1s: [], Sha256s: [], IPs: [], URLs: [] };
        for (let i = 1; i < lines.length; i++) {
            const row = lines[i].split(',');
            const type = (row[typeIdx] || '').trim();
            const value = (row[valueIdx] || '').trim();
            if (!type || !value) continue;
            if (type.toLowerCase() === 'sha1') tiData.Sha1s.push(value);
            else if (type.toLowerCase() === 'sha256') tiData.Sha256s.push(value);
            else if (type.toLowerCase() === 'ip') tiData.IPs.push(value);
            else if (type.toLowerCase() === 'url') tiData.URLs.push(value);
        }
        let anySent = false;
        for (const [type, arr] of Object.entries(tiData)) {
            if (arr.length > 0) {
                anySent = true;
                const payload = { TenantId: tenantId, Function: 'InvokeTi' + type.replace(/s$/, '') };
                payload[type] = arr;
                await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
            }
        }
        if (!anySent) status.textContent = 'No valid entries found in CSV.';
        else status.textContent = 'Import complete.';
        loadIndicators();
    };
    reader.readAsText(file);
};

async function loadDetections() {
    const tenantId = getTenantId();
    if (!tenantId) return;
    const url = `https://${window.FUNCURL}/api/MDETIManager?code=${window.FUNCKEY}`;
    const payload = { TenantId: tenantId, Function: 'GetDetectionRules' };
    const res = await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    const result = await res.json();
    let detections = result.value || result.machines || result || [];
    if (!Array.isArray(detections) && detections.value) detections = detections.value;
    renderDetectionsTable(Array.isArray(detections) ? detections : []);
}

function renderDetectionsTable(detections) {
    const container = document.getElementById('detectionsTableContainer');
    container.innerHTML = '';
    if (!window.gridjs) return;
    if (window.detectionsGrid) window.detectionsGrid.destroy();
    const columns = [
        { id: 'id', name: 'CD Id' },
        { id: 'displayName', name: 'Title' },
        { id: 'createdBy', name: 'Created By' },
        { id: 'lastModifiedBy', name: 'Last Modified By' },
        { id: 'lastModifiedDateTime', name: 'Last Modified Time' },
        { id: 'isEnabled', name: 'Active', formatter: cell => cell === true ? 'Yes' : cell === false ? 'No' : '' }
    ];
    const data = detections.map(d => [d.id, d.displayName, d.createdBy, d.lastModifiedBy, d.lastModifiedDateTime, d.isEnabled]);
    window.detectionsGrid = new gridjs.Grid({ columns, data, search: true, sort: true, pagination: true, autoWidth: true, width: '100%', height: 'auto' }).render(container);
}

async function syncDetections() {
    const tenantId = getTenantId();
    if (!tenantId) return;
    const url = `https://${window.FUNCURL}/api/MDECDManager?code=${window.FUNCKEY}`;
    const payload = { TenantId: tenantId, Function: 'Sync' };
    await fetch(url, { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    loadDetections();
};