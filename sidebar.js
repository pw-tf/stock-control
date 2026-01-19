// Sidebar Component - Reusable navigation sidebar
// Include this file after auth.js on all protected pages

/**
 * Initialize the sidebar component
 * Call this function in your DOMContentLoaded event after initAuth()
 * 
 * @param {Object} user - The current user object from initAuth()
 */
function initSidebar(user) {
    // Generate and inject sidebar HTML
    injectSidebarHTML();
    
    // Set active page based on current URL
    setActivePage();
    
    // Apply role-based visibility
    if (user && user.role !== 'manager') {
        hideAdminMenu();
    }
    
    // Setup event listeners
    setupSidebarEvents();
}

/**
 * Generate the sidebar HTML structure
 */
function injectSidebarHTML() {
    // Create sidebar overlay
    let overlay = document.getElementById('sidebarOverlay');
    if (!overlay) {
        overlay = document.createElement('div');
        overlay.className = 'sidebar-overlay';
        overlay.id = 'sidebarOverlay';
        document.body.insertBefore(overlay, document.body.firstChild);
    }
    
    // Create hamburger button
    let hamburger = document.getElementById('hamburgerBtn');
    if (!hamburger) {
        hamburger = document.createElement('button');
        hamburger.className = 'hamburger-btn visible';
        hamburger.id = 'hamburgerBtn';
        hamburger.innerHTML = '<span></span><span></span><span></span>';
        document.body.insertBefore(hamburger, document.body.firstChild);
    } else {
        hamburger.classList.add('visible');
    }
    
    // Create sidebar
    let sidebar = document.getElementById('sidebar');
    if (!sidebar) {
        sidebar = document.createElement('div');
        sidebar.className = 'sidebar';
        sidebar.id = 'sidebar';
        document.body.insertBefore(sidebar, document.body.firstChild);
    }
    
    // Set sidebar content
    sidebar.innerHTML = `
        <div class="sidebar-header">
            <h2>Navigation</h2>
            <button class="sidebar-close" id="sidebarClose">×</button>
        </div>
        <div class="sidebar-menu">
            <a href="dashboard.html" class="sidebar-menu-item" data-page="dashboard">
                <span>📋</span>
                <span>Stock Entry</span>
            </a>
            <a href="boxes.html" class="sidebar-menu-item" data-page="boxes">
                <span>📦</span>
                <span>View Boxes</span>
            </a>
            <a href="user.html" class="sidebar-menu-item" data-page="user">
                <span>👤</span>
                <span>User</span>
            </a>
            
            <!-- Admin Panel Dropdown (Manager only) -->
            <div class="sidebar-dropdown" data-role="manager" id="adminDropdown">
                <div class="sidebar-menu-item dropdown-toggle" id="adminToggle" data-page="admin">
                    <span>⚙️</span>
                    <span>Admin Panel</span>
                    <span class="dropdown-arrow">▼</span>
                </div>
                <div class="dropdown-content" id="adminSubmenu">
                    <a href="admin-depot.html" class="sidebar-menu-item sub-item" data-page="admin-depot">
                        <span>🏢</span>
                        <span>Depot Config</span>
                    </a>
                    <a href="admin-shifts.html" class="sidebar-menu-item sub-item" data-page="admin-shifts">
                        <span>📊</span>
                        <span>Shift Reports</span>
                    </a>
                </div>
            </div>
            
            <div class="sidebar-menu-item" id="logoutBtn">
                <span>🚪</span>
                <span>Sign Out</span>
            </div>
        </div>
    `;
}

/**
 * Determine and set the active page based on current URL
 */
function setActivePage() {
    const currentPath = window.location.pathname;
    const currentHash = window.location.hash;
    const filename = currentPath.split('/').pop().toLowerCase() || 'index';
    
    // Remove active class from all items
    document.querySelectorAll('.sidebar-menu-item').forEach(item => {
        item.classList.remove('active');
    });
    
    // Determine which page is active
    let activePage = '';
    let isAdminPage = false;
    
    if (filename === 'dashboard.html') {
        activePage = 'dashboard';
    } else if (filename === 'boxes.html') {
        activePage = 'boxes';
    } else if (filename === 'user.html') {
        activePage = 'user';
    } else if (filename === 'admin-depot.html') {
        activePage = 'admin-depot';
        isAdminPage = true;
    } else if (filename === 'admin-shifts.html') {
        activePage = 'admin-shifts';
        isAdminPage = true;
    } else if (filename === 'admin.html') {
        // Legacy admin.html - redirect to admin-depot
        activePage = 'admin-depot';
        isAdminPage = true;
    } else if (filename === 'guides.html') {
        activePage = 'guides';
    }
    
    // Set active state
    if (activePage) {
        const activeItem = document.querySelector(`[data-page="${activePage}"]`);
        if (activeItem) {
            activeItem.classList.add('active');
        }
    }
    
    // If on admin page, expand the dropdown and mark toggle as active
    if (isAdminPage) {
        const adminToggle = document.getElementById('adminToggle');
        const adminSubmenu = document.getElementById('adminSubmenu');
        if (adminToggle && adminSubmenu) {
            adminToggle.classList.add('active', 'open');
            adminSubmenu.classList.add('show');
        }
    }
}

/**
 * Hide admin menu for non-manager users
 */
function hideAdminMenu() {
    const adminDropdown = document.getElementById('adminDropdown');
    if (adminDropdown) {
        adminDropdown.style.display = 'none';
    }
}

/**
 * Setup all sidebar event listeners
 */
function setupSidebarEvents() {
    // Hamburger button
    const hamburgerBtn = document.getElementById('hamburgerBtn');
    if (hamburgerBtn) {
        hamburgerBtn.addEventListener('click', toggleSidebar);
    }
    
    // Sidebar overlay
    const overlay = document.getElementById('sidebarOverlay');
    if (overlay) {
        overlay.addEventListener('click', closeSidebar);
    }
    
    // Sidebar close button
    const closeBtn = document.getElementById('sidebarClose');
    if (closeBtn) {
        closeBtn.addEventListener('click', closeSidebar);
    }
    
    // Admin dropdown toggle
    const adminToggle = document.getElementById('adminToggle');
    if (adminToggle) {
        adminToggle.addEventListener('click', function(e) {
            e.preventDefault();
            toggleAdminDropdown();
        });
    }
    
    // Logout button
    const logoutBtn = document.getElementById('logoutBtn');
    if (logoutBtn) {
        logoutBtn.addEventListener('click', function() {
            if (typeof logout === 'function') {
                logout();
            } else {
                console.error('logout function not found. Make sure auth.js is loaded.');
            }
        });
    }
}

/**
 * Toggle sidebar open/closed
 */
function toggleSidebar() {
    const sidebar = document.getElementById('sidebar');
    const overlay = document.getElementById('sidebarOverlay');
    const hamburger = document.getElementById('hamburgerBtn');
    
    if (sidebar) sidebar.classList.toggle('active');
    if (overlay) overlay.classList.toggle('active');
    if (hamburger) hamburger.classList.toggle('active');
}

/**
 * Close the sidebar
 */
function closeSidebar() {
    const sidebar = document.getElementById('sidebar');
    const overlay = document.getElementById('sidebarOverlay');
    const hamburger = document.getElementById('hamburgerBtn');
    
    if (sidebar) sidebar.classList.remove('active');
    if (overlay) overlay.classList.remove('active');
    if (hamburger) hamburger.classList.remove('active');
}

/**
 * Toggle the admin dropdown menu
 */
function toggleAdminDropdown() {
    const toggle = document.getElementById('adminToggle');
    const submenu = document.getElementById('adminSubmenu');
    
    if (toggle && submenu) {
        toggle.classList.toggle('open');
        submenu.classList.toggle('show');
    }
}

// Export functions for global use
window.initSidebar = initSidebar;
window.toggleSidebar = toggleSidebar;
window.closeSidebar = closeSidebar;
window.toggleAdminDropdown = toggleAdminDropdown;
