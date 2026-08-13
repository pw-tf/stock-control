// Sidebar Component - Reusable navigation sidebar
// Include this file after auth.js on all protected pages

/**
 * Initialize the sidebar component.
 * Call after initAuth() resolves with the current user.
 */
function initSidebar(user) {
    injectSidebarHTML(user);
    setActivePage();
    setupSidebarEvents(user);

    // Role-based section visibility
    if (user) {
        const isAdmin = user.role === 'manager' || user.role === 'super_admin';
        const isSuperAdmin = user.role === 'super_admin';

        if (!isAdmin) {
            document.querySelectorAll('#sidebar [data-section="admin"]').forEach(el => {
                el.style.display = 'none';
            });
        }
        if (!isSuperAdmin) {
            document.querySelectorAll('#sidebar [data-role="super_admin"]').forEach(el => {
                el.style.display = 'none';
            });
        }
    }

    // Async: fetch depot name and populate brand sub-label
    _loadDepotName(user);
}

async function _loadDepotName(user) {
    if (!user || !user.depot_id) return;
    try {
        const { data } = await db
            .from('depots')
            .select('depot_name')
            .eq('depot_id', user.depot_id)
            .single();
        if (data && data.depot_name) {
            const sub = document.getElementById('sbDepotSub');
            if (sub) sub.textContent = data.depot_name;
        }
    } catch (_) {}
}

function injectSidebarHTML(user) {
    // Overlay
    let overlay = document.getElementById('sidebarOverlay');
    if (!overlay) {
        overlay = document.createElement('div');
        overlay.className = 'sidebar-overlay';
        overlay.id = 'sidebarOverlay';
        document.body.insertBefore(overlay, document.body.firstChild);
    }

    // Inject a floating hamburger only for pages without the new topbar
    if (!document.querySelector('.topbar-burger')) {
        let hamburger = document.getElementById('hamburgerBtn');
        if (!hamburger) {
            hamburger = document.createElement('button');
            hamburger.id = 'hamburgerBtn';
            hamburger.className = 'hamburger-btn visible';
            hamburger.setAttribute('aria-label', 'Menu');
            hamburger.innerHTML = '<span></span><span></span><span></span>';
            hamburger.addEventListener('click', toggleSidebar);
            document.body.appendChild(hamburger);
        }
    }

    // Sidebar element
    let sidebar = document.getElementById('sidebar');
    if (!sidebar) {
        sidebar = document.createElement('aside');
        sidebar.className = 'sidebar';
        sidebar.id = 'sidebar';
        document.body.insertBefore(sidebar, document.body.firstChild);
    }

    // User display info
    let initials = '??';
    let displayName = 'Account';
    let roleLabel = '';
    if (user) {
        const meta = user.user_metadata || {};
        const fullName = meta.full_name || meta.name || '';
        if (fullName) {
            const parts = fullName.trim().split(/\s+/);
            initials = parts.map(p => p[0]).join('').toUpperCase().slice(0, 2);
            displayName = fullName.trim();
        } else if (user.email) {
            const local = user.email.split('@')[0];
            initials = local.slice(0, 2).toUpperCase();
            displayName = user.email;
        }
        const roleName = user.role ? (user.role.charAt(0).toUpperCase() + user.role.slice(1).replace('_', ' ')) : '';
        const agentPart = user.agent_id ? ` · Agent ${user.agent_id}` : '';
        roleLabel = roleName + agentPart;
    }

    sidebar.innerHTML = `
        <div class="sb-head">
            <span class="sb-logo-mark">
                <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/><path d="M3.27 6.96 12 12.01l8.73-5.05M12 22.08V12"/></svg>
            </span>
            <div class="sb-brand">
                <span class="sb-name">Stock Control</span>
                <span class="sb-sub" id="sbDepotSub">Loading…</span>
            </div>
            <button class="sb-close" id="sidebarClose" aria-label="Close sidebar">
                <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M18 6 6 18M6 6l12 12"/></svg>
            </button>
        </div>

        <form class="sb-search" id="sbSearchForm" onsubmit="return _sbSearch(event)">
            <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><circle cx="11" cy="11" r="7"/><path d="m21 21-4.3-4.3"/></svg>
            <input type="search" id="sbSearchInput" placeholder="Search inventory…" autocomplete="off" />
            <span class="kbd">⌘ K</span>
        </form>

        <nav class="sb-nav">

            <div class="sb-section">
                <div class="sb-section-label">Workspace</div>
                <a class="sb-item" href="home.html" data-page="home">
                    <span class="sb-ico"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="7" height="9" x="3" y="3" rx="1"/><rect width="7" height="5" x="14" y="3" rx="1"/><rect width="7" height="9" x="14" y="12" rx="1"/><rect width="7" height="5" x="3" y="16" rx="1"/></svg></span>
                    <span class="sb-label">Home</span>
                </a>
                <a class="sb-item" href="stock-entry.html" data-page="stock-entry">
                    <span class="sb-ico"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="8" height="4" x="8" y="2" rx="1" ry="1"/><path d="M16 4h2a2 2 0 0 1 2 2v14a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2h2"/><path d="M9 14l2 2 4-4"/></svg></span>
                    <span class="sb-label">Stock Entry</span>
                </a>
                <a class="sb-item" href="inventory.html" data-page="inventory">
                    <span class="sb-ico"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M16.5 9.4 7.55 4.24"/><path d="M21 16V8a2 2 0 0 0-1-1.73l-7-4a2 2 0 0 0-2 0l-7 4A2 2 0 0 0 3 8v8a2 2 0 0 0 1 1.73l7 4a2 2 0 0 0 2 0l7-4A2 2 0 0 0 21 16z"/><path d="M3.27 6.96 12 12.01l8.73-5.05"/><path d="M12 22.08V12"/></svg></span>
                    <span class="sb-label">Inventory</span>
                </a>
                <a class="sb-item" href="planner.html" data-page="planner">
                    <span class="sb-ico"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="18" height="18" x="3" y="4" rx="2"/><path d="M16 2v4M8 2v4M3 10h18M8 14h.01M12 14h.01M16 14h.01M8 18h.01M12 18h.01"/></svg></span>
                    <span class="sb-label">Planner</span>
                </a>
            </div>

            <div class="sb-section" data-section="admin">
                <div class="sb-section-label">Admin</div>
                <a class="sb-item" href="my-depot.html" data-page="my-depot">
                    <span class="sb-ico"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M3 9l9-7 9 7v11a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z"/><polyline points="9 22 9 12 15 12 15 22"/></svg></span>
                    <span class="sb-label">My Depot</span>
                </a>
                <a class="sb-item" href="shifts.html" data-page="shifts">
                    <span class="sb-ico"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="10"/><polyline points="12 6 12 12 16 14"/></svg></span>
                    <span class="sb-label">Shift Reports</span>
                </a>
                <a class="sb-item" href="analytics.html" data-page="analytics">
                    <span class="sb-ico"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><line x1="18" x2="18" y1="20" y2="10"/><line x1="12" x2="12" y1="20" y2="4"/><line x1="6" x2="6" y1="20" y2="14"/></svg></span>
                    <span class="sb-label">Analytics</span>
                </a>
                <a class="sb-item" href="manage-depots.html" data-page="manage-depots" data-role="super_admin">
                    <span class="sb-ico"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><rect width="16" height="20" x="4" y="2" rx="2"/><path d="M9 22v-4h6v4"/><path d="M8 6h.01M16 6h.01M12 6h.01M12 10h.01M12 14h.01M16 10h.01M16 14h.01M8 10h.01M8 14h.01"/></svg></span>
                    <span class="sb-label">Manage Depots</span>
                </a>
            </div>

            <div class="sb-section">
                <div class="sb-section-label">Account</div>
                <a class="sb-item" href="user.html" data-page="user">
                    <span class="sb-ico"><svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="8" r="4"/><path d="M20 21a8 8 0 0 0-16 0"/></svg></span>
                    <span class="sb-label">Profile</span>
                </a>
            </div>

        </nav>

        <div class="sb-foot">
            <div class="sb-user" id="sbUserCard" onclick="location.href='user.html'" title="My Profile">
                <span class="sb-av" id="sbAvatar">${typeof escapeHTML === 'function' ? escapeHTML(initials) : initials}</span>
                <div class="sb-meta">
                    <span class="sb-uname" id="sbDisplayName">${typeof escapeHTML === 'function' ? escapeHTML(displayName) : displayName}</span>
                    <span class="sb-urole" id="sbRoleLabel">${typeof escapeHTML === 'function' ? escapeHTML(roleLabel) : roleLabel}</span>
                </div>
                <button class="sb-signout" id="sbSignout" title="Sign out" onclick="_sbSignout(event)">
                    <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 21H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h4M16 17l5-5-5-5M21 12H9"/></svg>
                </button>
            </div>
        </div>
    `;
}

function _sbSearch(e) {
    e.preventDefault();
    const q = (document.getElementById('sbSearchInput') || {}).value || '';
    if (q.trim().length >= 2) {
        closeSidebar();
        window.location.href = 'inventory.html?search=' + encodeURIComponent(q.trim());
    }
    return false;
}

function _sbSignout(e) {
    e.stopPropagation();
    if (typeof logout === 'function') {
        logout();
    }
}

function setActivePage() {
    const filename = (window.location.pathname.split('/').pop() || 'home.html').toLowerCase();

    const pageMap = {
        'home.html': 'home',
        'planner.html': 'planner',
        'stock-entry.html': 'stock-entry',
        'inventory.html': 'inventory',
        'boxes.html': 'inventory',
        'user.html': 'user',
        'my-depot.html': 'my-depot',
        'shifts.html': 'shifts',
        'analytics.html': 'analytics',
        'manage-depots.html': 'manage-depots',
    };

    const activePage = pageMap[filename] || '';
    if (!activePage) return;

    document.querySelectorAll('#sidebar .sb-item').forEach(item => {
        item.classList.remove('active');
    });

    const activeItem = document.querySelector(`#sidebar .sb-item[data-page="${activePage}"]`);
    if (activeItem) activeItem.classList.add('active');
}

function setupSidebarEvents(user) {
    const overlay = document.getElementById('sidebarOverlay');
    if (overlay) overlay.addEventListener('click', closeSidebar);

    const closeBtn = document.getElementById('sidebarClose');
    if (closeBtn) closeBtn.addEventListener('click', closeSidebar);
}

function toggleSidebar() {
    const sidebar = document.getElementById('sidebar');
    const overlay = document.getElementById('sidebarOverlay');
    if (!sidebar) return;
    const isOpen = sidebar.classList.toggle('active');
    if (overlay) overlay.classList.toggle('active', isOpen);
}

function closeSidebar() {
    const sidebar = document.getElementById('sidebar');
    const overlay = document.getElementById('sidebarOverlay');
    if (sidebar) sidebar.classList.remove('active');
    if (overlay) overlay.classList.remove('active');
}

window.initSidebar = initSidebar;
window.toggleSidebar = toggleSidebar;
window.closeSidebar = closeSidebar;
