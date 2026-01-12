// Shared Authentication Utilities
// Include this file in all protected pages

const SUPABASE_URL = "https://lfydtctndrzzdyavmlva.supabase.co";
const SUPABASE_ANON_KEY = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImxmeWR0Y3RuZHJ6emR5YXZtbHZhIiwicm9sZSI6ImFub24iLCJpYXQiOjE3Njc0Nzc5MTksImV4cCI6MjA4MzA1MzkxOX0.O7dL6Gl-Re1yKEixO_BRa-goj67os6riy15hRIE4nqY";

// Initialize Supabase client
const db = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY);

// Check if user is authenticated
async function checkAuth() {
    const { data: { session } } = await db.auth.getSession();
    if (!session) {
        window.location.href = 'index.html';
        return null;
    }
    return session;
}

// Get current user's role and agent
async function getCurrentUser() {
    const session = await checkAuth();
    if (!session) return null;
    
    try {
        const { data, error } = await db
            .from('user_roles')
            .select('role, agent_id, email')
            .eq('user_id', session.user.id)
            .single();
        
        if (error) {
            // User exists in auth but not in user_roles (partial signup)
            console.error('User role not found:', error);
            // Sign them out to prevent loop
            await db.auth.signOut();
            return null;
        }
        
        return {
            id: session.user.id,
            email: session.user.email,
            role: data.role,
            agent_id: data.agent_id
        };
    } catch (error) {
        console.error('Error getting user:', error);
        // Sign them out to prevent loop
        await db.auth.signOut();
        return null;
    }
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
    // Hide manager-only elements from non-managers
    if (userRole !== 'manager') {
        document.querySelectorAll('[data-role="manager"]').forEach(el => {
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
    const user = await getCurrentUser();
    
    if (!user) {
        window.location.href = 'index.html';
        return null;
    }
    
    // Check if user has been assigned to an agent
    if (!user.agent_id) {
        window.location.href = 'pending.html';
        return null;
    }
    
    // Check if user has required role
    if (requiredRoles && !hasRole(user.role, requiredRoles)) {
        alert('You do not have permission to access this page.');
        window.location.href = 'dashboard.html';
        return null;
    }
    
    // Apply role-based restrictions
    restrictByRole(user.role);
    
    return user;
}
