// Icon utility using Lucide Icons
// This provides a centralized way to use icons across all pages

const Icons = {
    // Icon name mappings to Lucide icon names
    map: {
        // Dashboard & Navigation
        'package': 'package',
        'box': 'box',
        'boxes': 'boxes',
        'home': 'home',
        'dashboard': 'layout-dashboard',
        'search': 'search',
        'menu': 'menu',
        'x': 'x',

        // Job Types
        'swap-upgrade': 'refresh-cw',
        'install': 'plus-circle',
        'deinstall': 'minus-circle',

        // Actions
        'add': 'plus',
        'edit': 'edit',
        'delete': 'trash-2',
        'save': 'save',
        'copy': 'copy',
        'download': 'download',
        'upload': 'upload',
        'check': 'check',
        'close': 'x',

        // Status & Feedback
        'success': 'check-circle',
        'error': 'x-circle',
        'warning': 'alert-triangle',
        'info': 'info',
        'alert': 'alert-circle',

        // Shift Management
        'shift': 'clock',
        'car': 'car',
        'start-shift': 'play-circle',
        'end-shift': 'square',
        'report': 'file-text',

        // User & Auth
        'user': 'user',
        'users': 'users',
        'logout': 'log-out',
        'login': 'log-in',
        'settings': 'settings',

        // Data & Reports
        'chart': 'bar-chart-2',
        'calendar': 'calendar',
        'clipboard': 'clipboard',
        'file': 'file',

        // Misc
        'help': 'help-circle',
        'external-link': 'external-link',
        'chevron-down': 'chevron-down',
        'chevron-up': 'chevron-up',
        'chevron-right': 'chevron-right',
        'chevron-left': 'chevron-left',
    },

    /**
     * Get an icon by name
     * @param {string} name - Icon name from the map
     * @param {object} options - Optional settings (size, className, style)
     * @returns {string} HTML string for the icon
     */
    get(name, options = {}) {
        const iconName = this.map[name] || name;
        const size = options.size || 20;
        const className = options.className || '';
        const style = options.style || '';

        return `<i data-lucide="${iconName}" ${className ? `class="${className}"` : ''} ${style ? `style="${style}"` : ''} width="${size}" height="${size}"></i>`;
    },

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
    },

    /**
     * Replace an element's content with an icon
     * @param {string|HTMLElement} element - CSS selector or element
     * @param {string} iconName - Icon name from the map
     * @param {object} options - Optional settings
     */
    replaceElement(element, iconName, options = {}) {
        const el = typeof element === 'string' ? document.querySelector(element) : element;
        if (el) {
            el.innerHTML = this.get(iconName, options);
            this.init();
        }
    },

    /**
     * Helper function to create an icon element
     * @param {string} iconName - Icon name from the map
     * @param {object} options - Optional settings
     * @returns {HTMLElement} Icon element
     */
    createElement(iconName, options = {}) {
        const iconName2 = this.map[iconName] || iconName;
        const size = options.size || 20;
        const className = options.className || '';

        const i = document.createElement('i');
        i.setAttribute('data-lucide', iconName2);
        if (className) i.className = className;
        i.setAttribute('width', size);
        i.setAttribute('height', size);

        return i;
    }
};

// Auto-initialize when DOM is ready
if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => Icons.init());
} else {
    Icons.init();
}
