// Icon utility using Lucide Icons
// Pages mark up icons as <i data-lucide="..."> and call Icons.init() after
// dynamic DOM updates to render them.

const Icons = {
    /**
     * Initialize Lucide icons on the page
     * Call this after DOM content is loaded or after dynamically adding icons
     */
    init() {
        if (typeof lucide !== 'undefined') {
            lucide.createIcons();
        } else {
            console.warn('Lucide library not loaded');
        }
    }
};

// Auto-initialize when DOM is ready
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => Icons.init());
} else {
    Icons.init();
}
