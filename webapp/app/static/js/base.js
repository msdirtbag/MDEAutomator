// Universal Platform Loading System
let platformLoadingState = {
    isLoading: true,
    tenantsLoaded: false,
    autoLoadCompleted: false,
    overlay: null
};

// Show universal platform loading overlay
function showPlatformLoading() {
    if (platformLoadingState.overlay) return; // Already showing
    
    const overlay = document.createElement('div');
    overlay.id = 'platformLoadingOverlay';
    overlay.style.cssText = `
        position: fixed;
        top: 0;
        left: 0;
        width: 100%;
        height: 100%;
        background: #101c11;
        display: flex;
        flex-direction: column;
        justify-content: center;
        align-items: center;
        z-index: 99999;
        color: #00ff41;
        font-family: 'Consolas', 'Courier New', monospace;
        font-size: 18px;
        text-align: center;
    `;
    
    overlay.innerHTML = `
        <div style="margin-bottom: 2rem;">
            <div style="font-size: 3rem; font-weight: bold; margin-bottom: 1rem; color: #00ff41; letter-spacing: 2px; text-shadow: 0 0 8px #00ff41;">
                MDEAutomator
            </div>
            <div style="font-size: 1.2rem; color: #7fff7f; margin-bottom: 2rem; font-weight: normal;">
                loading platform
            </div>
            <div class="spinner-container" style="width: 50px; height: 50px; margin: 0 auto;">
                <div class="neon-spinner" style="
                    width: 50px;
                    height: 50px;
                    border: 3px solid #142a17;
                    border-top: 3px solid #00ff41;
                    border-radius: 50%;
                    animation: spin 1s linear infinite;
                    box-shadow: 0 0 15px rgba(0, 255, 65, 0.3);
                "></div>
            </div>
            <div style="margin-top: 2rem; font-size: 0.9rem; color: #7fff7f; opacity: 0.7;">
            </div>
        </div>
    `;
    
    document.body.appendChild(overlay);
    platformLoadingState.overlay = overlay;
    
    // Add spinner animation with neon glow effect
    const style = document.createElement('style');
    style.textContent = `
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }
        .neon-spinner {
            animation: spin 1s linear infinite, neon-pulse 2s ease-in-out infinite alternate;
        }
        @keyframes neon-pulse {
            0% { box-shadow: 0 0 10px rgba(0, 255, 65, 0.3); }
            100% { box-shadow: 0 0 20px rgba(0, 255, 65, 0.6), 0 0 30px rgba(0, 255, 65, 0.3); }
        }
    `;
    document.head.appendChild(style);
    
    console.log('Platform loading overlay shown');
}

// Update platform loading progress
function updatePlatformLoadingProgress(status, percentage) {
    // Simplified - no longer shows status updates or progress bars
    // Just keep the loading going silently
    console.log(`Platform loading: ${status} (${percentage}%)`);
}

// Hide platform loading overlay
function hidePlatformLoading() {
    if (platformLoadingState.overlay) {
        platformLoadingState.overlay.style.opacity = '0';
        platformLoadingState.overlay.style.transition = 'opacity 0.5s ease-out';
        
        setTimeout(() => {
            if (platformLoadingState.overlay && platformLoadingState.overlay.parentNode) {
                platformLoadingState.overlay.parentNode.removeChild(platformLoadingState.overlay);
            }
            platformLoadingState.overlay = null;
            platformLoadingState.isLoading = false;
        }, 500);
        
        console.log('Platform loading overlay hidden');
    }
}

// Check if platform loading should be completed
function checkPlatformLoadingComplete() {
    if (platformLoadingState.tenantsLoaded && platformLoadingState.autoLoadCompleted) {
        // Hide immediately when both conditions are met
        hidePlatformLoading();
    }
}

// Mark tenants as loaded
function markTenantsLoaded() {
    platformLoadingState.tenantsLoaded = true;
    checkPlatformLoadingComplete();
}

// Mark auto-load as completed
function markAutoLoadCompleted() {
    platformLoadingState.autoLoadCompleted = true;
    checkPlatformLoadingComplete();
}

// Initialize platform loading on DOM ready
document.addEventListener('DOMContentLoaded', () => {
    console.log('Base JavaScript loaded');
    
    // Show platform loading immediately
    showPlatformLoading();
    
    // Set a maximum timeout to hide loading even if something fails
    setTimeout(() => {
        if (platformLoadingState.isLoading) {
            console.warn('Platform loading timeout reached, forcing completion');
            platformLoadingState.tenantsLoaded = true;
            platformLoadingState.autoLoadCompleted = true;
            checkPlatformLoadingComplete();
        }
    }, 25000); // 25 second maximum timeout
});

// Make functions globally available
window.showPlatformLoading = showPlatformLoading;
window.updatePlatformLoadingProgress = updatePlatformLoadingProgress;
window.hidePlatformLoading = hidePlatformLoading;
window.markTenantsLoaded = markTenantsLoaded;
window.markAutoLoadCompleted = markAutoLoadCompleted;

// Centralized Content Loading System (for specific operations)
function showContentLoading(message = 'Loading...') {
    let overlay = document.getElementById('contentLoadingOverlay');
    if (!overlay) {
        overlay = document.createElement('div');
        overlay.id = 'contentLoadingOverlay';
        overlay.style.cssText = `
            position: fixed;
            top: 0;
            left: 0;
            width: 100%;
            height: 100%;
            background-color: rgba(16, 28, 17, 0.9);
            display: none;
            justify-content: center;
            align-items: center;
            z-index: 9998;
            color: #00ff41;
            font-family: 'Consolas', 'Courier New', monospace;
            font-size: 16px;
        `;
        document.body.appendChild(overlay);
    }
    
    overlay.innerHTML = `
        <div style="text-align: center; background: #142a17; padding: 2rem; border-radius: 8px; border: 1px solid #00ff41; box-shadow: 0 0 20px rgba(0, 255, 65, 0.2);">
            <div style="margin-bottom: 1.5rem; color: #00ff41; font-size: 1.1rem;">> ${message}</div>
            <div style="width: 40px; height: 40px; border: 3px solid #142a17; border-top: 3px solid #00ff41; border-radius: 50%; animation: spin 1s linear infinite; margin: 0 auto; box-shadow: 0 0 10px rgba(0, 255, 65, 0.3);"></div>
        </div>
    `;
    overlay.style.display = 'flex';
    
    // Add CSS animation if not already present
    if (!document.getElementById('contentLoadingStyles')) {
        const style = document.createElement('style');
        style.id = 'contentLoadingStyles';
        style.textContent = `
            @keyframes spin {
                0% { transform: rotate(0deg); }
                100% { transform: rotate(360deg); }
            }
        `;
        document.head.appendChild(style);
    }
}

function hideContentLoading() {
    const overlay = document.getElementById('contentLoadingOverlay');
    if (overlay) {
        overlay.style.display = 'none';
    }
}

// Make content loading functions globally available
window.showContentLoading = showContentLoading;
window.hideContentLoading = hideContentLoading;