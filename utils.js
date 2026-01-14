// utils.js - Shared utilities
// This file provides common functions used across multiple pages
// Note: Supabase client (db) is initialized in auth.js which must be loaded first

// ============================================
// UI HELPERS
// ============================================

/**
 * Show or hide the loading overlay
 * @param {boolean} show - Whether to show the loading overlay
 */
function showLoading(show) {
    const loading = document.getElementById("loading");
    if (loading) loading.classList.toggle("active", show);
}

/**
 * Display an alert message
 * @param {string} message - The message to display
 * @param {string} type - Alert type: 'success', 'error', 'warning', 'info'
 * @param {string} containerId - ID of the container element (default: 'alertContainer')
 */
function showAlert(message, type = 'info', containerId = 'alertContainer') {
    const container = document.getElementById(containerId);
    if (!container) return;
    
    const alert = document.createElement('div');
    alert.className = `alert alert-${type}`;
    const icons = { success: '✓', error: '✕', warning: '⚠', info: 'ℹ' };
    
    alert.innerHTML = `<span class="alert-icon">${icons[type] || 'ℹ'}</span><span>${message}</span>`;
    container.appendChild(alert);
    
    setTimeout(() => {
        alert.style.opacity = '0';
        setTimeout(() => alert.remove(), 500);
    }, 5000);
}

/**
 * Display a sync status indicator
 * @param {string} message - The status message
 * @param {string} type - Status type: 'syncing', 'synced', 'error'
 */
function showSyncStatus(message, type) {
    const status = document.getElementById('syncStatus');
    if (!status) return;
    
    status.textContent = message;
    status.className = `sync-status active ${type}`;
    setTimeout(() => status.classList.remove('active'), 3000);
}

// ============================================
// DATE FORMATTING
// ============================================

/**
 * Format a date for display
 * @param {Date|string} date - The date to format
 * @returns {string} Formatted date string
 */
function formatDateTime(date) {
    return new Date(date).toLocaleString('en-AU', {
        day: '2-digit', month: '2-digit', year: 'numeric',
        hour: '2-digit', minute: '2-digit', hour12: true
    });
}

/**
 * Format a date for datetime-local input fields
 * @param {Date|string} date - The date to format
 * @returns {string} ISO-style string for datetime-local input
 */
function formatDateTimeLocal(date) {
    const d = new Date(date);
    const offset = d.getTimezoneOffset();
    const localDate = new Date(d.getTime() - (offset * 60 * 1000));
    return localDate.toISOString().slice(0, 16);
}

/**
 * Get today's date at midnight
 * @returns {Date} Today at 00:00:00
 */
function getTodayMidnight() {
    const today = new Date();
    today.setHours(0, 0, 0, 0);
    return today;
}

/**
 * Check if two dates are on the same calendar day
 * @param {Date|string} date1 - First date
 * @param {Date|string} date2 - Second date
 * @returns {boolean} True if same day
 */
function isSameDay(date1, date2) {
    const d1 = new Date(date1);
    const d2 = new Date(date2);
    return d1.getFullYear() === d2.getFullYear() &&
           d1.getMonth() === d2.getMonth() &&
           d1.getDate() === d2.getDate();
}

// ============================================
// CSV HELPERS
// ============================================

/**
 * Escape a value for CSV output
 * @param {*} value - The value to escape
 * @returns {string} CSV-safe string
 */
function escapeCSV(value) {
    if (value === null || value === undefined) return '';
    const str = String(value);
    if (str.includes(',') || str.includes('"') || str.includes('\n')) {
        return `"${str.replace(/"/g, '""')}"`;
    }
    return str;
}

/**
 * Generate a CSV file download
 * @param {string} content - CSV content
 * @param {string} filename - Filename for download
 */
function downloadCSV(content, filename) {
    const blob = new Blob([content], { type: 'text/csv;charset=utf-8;' });
    const link = document.createElement('a');
    const url = URL.createObjectURL(blob);
    
    link.setAttribute('href', url);
    link.setAttribute('download', filename);
    link.style.visibility = 'hidden';
    document.body.appendChild(link);
    link.click();
    document.body.removeChild(link);
}

// ============================================
// VALIDATION HELPERS
// ============================================

/**
 * Check for duplicate serial numbers in the database
 * @param {string[]} serials - Array of serial numbers to check
 * @param {number|null} excludeJobId - Optional job ID to exclude from check
 * @returns {Promise<string[]>} Array of duplicate serials found
 */
async function checkDuplicateSerials(serials, excludeJobId = null) {
    try {
        let query = db
            .from('serials')
            .select('serial_number')
            .in('serial_number', serials);
        
        if (excludeJobId) {
            query = query.neq('job_id', excludeJobId);
        }
        
        const { data, error } = await query;
        
        if (error) throw error;
        return data ? data.map(s => s.serial_number) : [];
    } catch (error) {
        console.error('Error checking duplicates:', error);
        return [];
    }
}

// ============================================
// BOX ID FORMATTING
// ============================================

/**
 * Get a 3-letter code from client name
 * @param {string} client - Client name
 * @returns {string} 3-letter uppercase code
 */
function getClientCode(client) {
    return client ? client.substring(0, 3).toUpperCase() : "OTH";
}

/**
 * Format a box ID string
 * @param {string} agent - Agent ID
 * @param {string} client - Client name
 * @param {string} boxNumber - Box number (padded)
 * @returns {string} Formatted box ID
 */
function formatBoxId(agent, client, boxNumber) {
    return `${agent}-${getClientCode(client)}-${boxNumber}`;
}
