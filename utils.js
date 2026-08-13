// utils.js - Shared utilities
// This file provides common functions used across multiple pages
// Note: Supabase client (db) is initialized in auth.js which must be loaded first

// ============================================
// SECURITY HELPERS
// ============================================

/**
 * Escape a string for safe insertion into HTML
 * @param {*} str - The value to escape
 * @returns {string} HTML-safe string
 */
function escapeHTML(str) {
    if (str == null) return '';
    return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

/**
 * Compute up-to-2-char avatar initials.
 * Accepts a user object (uses user_metadata.full_name, else email)
 * or a plain email/name string. The email local part is split on
 * whitespace and . _ - separators, so:
 *   brett@mbsa.com.au -> "BR", john.doe@x -> "JD", "Brett Robinson" -> "BR"
 * @param {object|string} input - user object or email/name string
 * @returns {string} uppercase initials
 */
function getAvatarInitials(input) {
    if (!input) return '??';
    if (typeof input === 'object') {
        const meta = input.user_metadata || {};
        const fullName = (meta.full_name || meta.name || '').trim();
        return getAvatarInitials(fullName || input.email || '');
    }
    const base = (input.includes('@') ? input.split('@')[0] : input).trim();
    if (!base) return '??';
    const words = base.split(/[\s._-]+/).filter(Boolean);
    if (words.length >= 2) return (words[0][0] + words[1][0]).toUpperCase();
    return (words[0] || base).slice(0, 2).toUpperCase();
}

// ============================================
// THEME MANAGEMENT
// ============================================

function getTheme() {
    return {
        theme: localStorage.getItem('theme') || 'ocean',
        mode: localStorage.getItem('mode') || 'dark'
    };
}

function setTheme(theme, mode) {
    localStorage.setItem('theme', theme);
    localStorage.setItem('mode', mode);
    document.documentElement.setAttribute('data-theme', theme);
    document.documentElement.setAttribute('data-mode', mode);
}

function applyTheme() {
    const { theme, mode } = getTheme();
    document.documentElement.setAttribute('data-theme', theme);
    document.documentElement.setAttribute('data-mode', mode);
}

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
 * Display a toast notification
 * @param {string} message - The message to display
 * @param {string} type - Alert type: 'success', 'error', 'warning', 'info'
 */
function showAlert(message, type = 'info') {
    // Get or create the toast container
    let container = document.getElementById('toastContainer');
    if (!container) {
        container = document.createElement('div');
        container.id = 'toastContainer';
        container.className = 'toast-container';
        document.body.appendChild(container);
    }

    const toast = document.createElement('div');
    toast.className = `toast toast-${type}`;
    const icons = { success: '✓', error: '✕', warning: '⚠', info: 'ℹ' };

    toast.innerHTML = `
        <span class="toast-icon">${icons[type] || 'ℹ'}</span>
        <span class="toast-message">${escapeHTML(message)}</span>
        <button class="toast-close" onclick="this.parentElement.remove()">×</button>
    `;
    container.appendChild(toast);

    // Trigger animation
    requestAnimationFrame(() => toast.classList.add('show'));

    // Auto-remove after 5 seconds
    setTimeout(() => {
        toast.classList.remove('show');
        setTimeout(() => toast.remove(), 300);
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
 * Local-timezone YYYY-MM-DD. Never use toISOString().split('T')[0] for a
 * calendar date — that returns the UTC date, which is off by a day for part
 * of the day in any non-UTC timezone.
 * @param {Date} [date] - Defaults to now
 * @returns {string} YYYY-MM-DD in the browser's timezone
 */
function localDateString(date = new Date()) {
    const y = date.getFullYear();
    const m = String(date.getMonth() + 1).padStart(2, '0');
    const d = String(date.getDate()).padStart(2, '0');
    return `${y}-${m}-${d}`;
}

/**
 * Parse a YYYY-MM-DD date string as local midnight.
 * `new Date('2026-08-13')` parses as UTC midnight, which lands on the previous
 * day west of Greenwich — this keeps calendar maths in the browser's timezone.
 * @param {string} str - YYYY-MM-DD
 * @returns {Date} Local midnight on that date
 */
function parseLocalDate(str) {
    const [y, m, d] = String(str).split('-').map(Number);
    return new Date(y, (m || 1) - 1, d || 1);
}

/**
 * Add days to a date without mutating the input.
 * @param {Date} date - Base date
 * @param {number} days - Days to add (may be negative)
 * @returns {Date} New date
 */
function addDays(date, days) {
    const d = new Date(date);
    d.setDate(d.getDate() + days);
    d.setHours(0, 0, 0, 0);
    return d;
}

/**
 * Monday of the week containing the given date.
 * @param {Date} [date] - Defaults to today
 * @returns {Date} Monday at 00:00:00
 */
function startOfWeek(date = new Date()) {
    const d = new Date(date);
    d.setHours(0, 0, 0, 0);
    const day = d.getDay();
    return addDays(d, day === 0 ? -6 : 1 - day);
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
    let str = String(value);
    // Guard against spreadsheet formula injection (=, +, -, @ at cell start)
    if (/^[=+\-@]/.test(str)) {
        str = "'" + str;
    }
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
// QUERY HELPERS
// ============================================

/**
 * Fetch every row matching a query, paging past Supabase's silent
 * per-request row cap (default 1000). Without this, large result sets
 * are truncated with no error and aggregates come out wrong.
 * @param {function(): object} buildQuery - Returns a fresh Supabase query
 *        (a query builder can't be re-executed, so we rebuild per page)
 * @param {number} pageSize - Rows per request
 * @returns {Promise<object[]>} All matching rows
 */
async function fetchAllRows(buildQuery, pageSize = 1000) {
    const all = [];
    for (let from = 0; ; from += pageSize) {
        const { data, error } = await buildQuery().range(from, from + pageSize - 1);
        if (error) throw error;
        if (data && data.length) all.push(...data);
        if (!data || data.length < pageSize) break;
    }
    return all;
}

// ============================================
// VALIDATION HELPERS
// ============================================

/**
 * Check for duplicate serial numbers in the database
 * @param {string[]} serials - Array of serial numbers to check
 * @param {number|null} excludeJobId - Optional job ID to exclude from check
 * @param {string|null} depotId - Depot ID to scope the check to
 * @returns {Promise<string[]>} Array of duplicate serials found
 * @throws if the query fails — callers must treat a failed check as a
 *         blocked submission rather than "no duplicates" (fail closed)
 */
async function checkDuplicateSerials(serials, excludeJobId = null, depotId = null) {
    let query = db
        .from('serials')
        .select('serial_number')
        .in('serial_number', serials);

    if (excludeJobId) {
        query = query.neq('job_id', excludeJobId);
    }

    if (depotId) {
        query = query.eq('depot_id', depotId);
    }

    const { data, error } = await query;

    if (error) {
        console.error('Error checking duplicates:', error);
        throw error;
    }
    return data ? data.map(s => s.serial_number) : [];
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
