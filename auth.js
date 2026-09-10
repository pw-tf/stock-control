// Shared Authentication Utilities
// Include this file in all protected pages

const SUPABASE_URL = "https://lfydtctndrzzdyavmlva.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxmeWR0Y3RuZHJ6emR5YXZtbHZhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njc0Nzc5MTksImV4cCI6MjA4MzA1MzkxOX0.O7dL6Gl-Re1yKEixO_BRa-goj67os6riy15hRIE4nqY";

// Initialize Supabase client
const db = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// Make db available globally for storage operations
window.db = db;

// Canonical theme ids — the CSS blocks in styles.css are the source of truth.
// Lives here rather than utils.js because auth.js loads first on every page and is
// the only shared script on guides.html. The inline <head> bootstrap on each page
// carries its own copy; it has to run before any script file loads.
const THEME_IDS = ['ocean', 'forest', 'sunset', 'slate', 'cherry', 'lavender', 'teal', 'sand', 'midnight', 'nord', 'indigo'];
const THEME_MODES = ['dark', 'light'];
const DEFAULT_THEME = 'ocean';
const DEFAULT_MODE = 'dark';

// Check if user is authenticated
async function checkAuth() {
    const { data: { session } } = await db.auth.getSession();
    if (!session) {
        window.location.href = 'index.html';
        return null;
    }
    return session;
}

// Get current user's role and agent.
// Returns null when there is no session or no user_roles row (partial signup —
// signed out to prevent a redirect loop). Throws on transient query failures
// (e.g. network drop) so callers don't destroy a valid session over a blip.
async function getCurrentUser() {
    const session = await checkAuth();
    if (!session) return null;

    const { data, error } = await db
        .from('user_roles')
        .select('role, agent_id, email, depot_id, shifts_enabled')
        .eq('user_id', session.user.id)
        .maybeSingle();

    if (error) {
        console.error('Error getting user role:', error);
        throw error;
    }

    if (!data) {
        // User exists in auth but not in user_roles (partial signup)
        console.error('User role not found');
        // Sign them out to prevent loop
        await db.auth.signOut();
        return null;
    }

    return {
        id: session.user.id,
        email: session.user.email,
        role: data.role,
        agent_id: data.agent_id,
        depot_id: data.depot_id,
        shifts_enabled: data.shifts_enabled
    };
}

// Check if user has required role
function hasRole(userRole, requiredRoles) {
    if (!Array.isArray(requiredRoles)) {
        requiredRoles = [requiredRoles];
    }
    return requiredRoles.includes(userRole);
}

// Logout function
async function logout() {
    try {
        const { error } = await db.auth.signOut();
        if (error) throw error;
        
        // Clear session storage
        sessionStorage.clear();
        
        // Redirect to login
        window.location.href = 'index.html';
    } catch (error) {
        console.error('Logout error:', error);
        alert('Error logging out. Please try again.');
    }
}

// Show/hide elements based on role
function restrictByRole(userRole) {
    // Hide manager-only elements from non-managers/non-super_admins
    if (userRole !== 'manager' && userRole !== 'super_admin') {
        document.querySelectorAll('[data-role="manager"]').forEach(el => {
            el.style.display = 'none';
        });
    }
    
    // Hide super_admin-only elements from non-super_admins
    if (userRole !== 'super_admin') {
        document.querySelectorAll('[data-role="super_admin"]').forEach(el => {
            el.style.display = 'none';
        });
    }

    // Hide technician+ elements from merchants
    if (userRole === 'merchant') {
        document.querySelectorAll('[data-role="technician"]').forEach(el => {
            el.style.display = 'none';
        });
    }
}

// Initialize auth on page load
async function initAuth(requiredRoles = null) {
    let user;
    try {
        user = await getCurrentUser();
    } catch (error) {
        // Transient failure — keep the session and surface it instead of
        // bouncing the user to the login page (which would loop while offline)
        if (typeof showLoading === 'function') showLoading(false);
        if (typeof showAlert === 'function') showAlert('Connection problem. Please refresh the page.', 'error');
        return null;
    }

    if (!user) {
        window.location.href = 'index.html';
        return null;
    }
    
    // Check if user has been assigned to an agent (super_admin may not have one)
    if (!user.agent_id && user.role !== 'super_admin') {
        window.location.href = 'pending.html';
        return null;
    }
    
    // Check if user has required role
    if (requiredRoles && !hasRole(user.role, requiredRoles)) {
        alert('You do not have permission to access this page.');
        // Merchants have no workspace page to fall back to — home.html rejects
        // them too, so sending them there would bounce them between the two
        // forever. pending.html is the one page that accepts any signed-in user.
        window.location.href = user.role === 'merchant' ? 'pending.html' : 'home.html';
        return null;
    }
    
    // Apply role-based restrictions
    restrictByRole(user.role);

    // Sync theme from Supabase (non-blocking — localStorage already applied the cached value)
    db.from('user_widget_config')
        .select('theme, theme_mode')
        .eq('user_id', user.id)
        .maybeSingle()
        .then(({ data }) => {
            if (!data) return;
            // Ignore a retired or unknown id rather than letting it overwrite the
            // working local value on every page load — it is corrected in the DB the
            // next time the user picks a theme.
            if (THEME_IDS.includes(data.theme)) {
                localStorage.setItem('theme', data.theme);
                document.documentElement.setAttribute('data-theme', data.theme);
            }
            if (THEME_MODES.includes(data.theme_mode)) {
                localStorage.setItem('mode', data.theme_mode);
                document.documentElement.setAttribute('data-mode', data.theme_mode);
            }
        })
        .catch(err => console.error('Theme sync failed:', err));

    return user;
}
/**
 * Register the service worker.
 *
 * Lives here because auth.js is the one script every page loads. Its only job
 * is to make the app installable on Android — see the header of sw.js for why
 * it caches nothing but the offline page.
 *
 * Deliberately after 'load': registration competes with the page's own requests
 * for connection slots, and nothing on screen depends on it.
 */
if ('serviceWorker' in navigator) {
    window.addEventListener('load', () => {
        // Root-scoped so it covers every page. The app is served from the domain
        // root (see .htaccess), so an absolute path is correct here.
        navigator.serviceWorker.register('/sw.js').catch(err => {
            // Never fatal: the app works perfectly well without it, so log and
            // carry on rather than surfacing anything to the technician.
            console.error('Service worker registration failed:', err);
        });
    });
}
