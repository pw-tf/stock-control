/**
 * Minimal markdown renderer for the technician guides.
 *
 * The app has no build step and no third-party sanitiser, and guide bodies are
 * editable by any manager — so pulling in marked + DOMPurify would mean two new
 * CDN dependencies guarding an XSS surface. Instead this renderer is
 * escape-first: the source is run through escapeHTML() before a single block is
 * parsed, so the only tags that can reach the DOM are ones this file emitted.
 * Author-supplied HTML is inert by construction.
 *
 * Supports exactly what the 2026 guides use: headings, ordered and unordered
 * lists (one level of nesting), bold/italic/code, GFM tables, horizontal rules,
 * links (http/https and internal ?guide= only), and the CRITICAL/NOTE/ADMIN
 * warning tiers as callout blocks.
 */

// Warning tiers from the source document. A paragraph or list item that opens
// with one of these becomes a callout rather than body text.
const MD_CALLOUTS = {
    CRITICAL: 'gd-critical',
    NOTE: 'gd-note',
    ADMIN: 'gd-admin'
};

// Sentinel that parks code spans while the other inline rules run. Escaping has
// already turned every angle bracket into an entity, so a raw "<" cannot appear
// in the text at this stage and the marker can never collide with content.
const MD_CODE_OPEN = '<mdcode';
const MD_CODE_CLOSE = '>';

// Local fallback so this file works even if utils.js hasn't loaded yet.
function mdEscape(str) {
    if (str == null) return '';
    if (typeof escapeHTML === 'function') return escapeHTML(str);
    return String(str)
        .replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}

/**
 * Turn a heading into a stable id so a guide can deep-link to a section.
 */
function mdSlugify(text) {
    return String(text)
        .replace(/<[^>]*>/g, '')
        .replace(/&[a-z]+;|&#\d+;/gi, ' ')
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, '-')
        .replace(/^-+|-+$/g, '')
        .slice(0, 60);
}

/**
 * Inline formatting. `text` is ALREADY html-escaped — this only ever adds tags.
 */
function mdInline(text) {
    let out = text;

    // Pull code spans out first so nothing else rewrites their contents.
    const codes = [];
    out = out.replace(/`([^`]+)`/g, (m, c) => {
        codes.push(c);
        return MD_CODE_OPEN + (codes.length - 1) + MD_CODE_CLOSE;
    });

    // Links. The href is already escaped, so it cannot break out of the
    // attribute; the allowlist is what keeps javascript:/data: out entirely.
    out = out.replace(/\[([^\]\n]+)\]\(([^)\s]+)\)/g, (m, label, href) => {
        // Escaping ran first, so a hostile quote arrives as &quot; / &#39;. It
        // cannot break out of the attribute, but reject it anyway rather than
        // emit a link to a URL nobody meant to write.
        // &amp; stays allowed — that is just how a query string survives
        // escaping, and it is the correct encoding inside an href.
        if (/&(quot|#39|lt|gt);/.test(href)) return label;
        if (/^https?:\/\/[^"'<>\s]+$/i.test(href)) {
            return '<a href="' + href + '" target="_blank" rel="noopener noreferrer">' + label + '</a>';
        }
        if (/^\?guide=[a-z0-9-]+$/.test(href)) {
            return '<a href="' + href + '" class="gd-xref">' + label + '</a>';
        }
        // Anything else (javascript:, data:, relative paths) renders as plain
        // text rather than a link.
        return label;
    });

    out = out.replace(/\*\*([^*\n]+)\*\*/g, '<strong>$1</strong>');
    out = out.replace(/(^|[^*\w])\*([^*\n]+)\*/g, '$1<em>$2</em>');

    out = out.replace(/<mdcode(\d+)>/g, (m, i) => '<code>' + codes[Number(i)] + '</code>');
    return out;
}

/**
 * If `html` opens with a warning tier, return its callout class and the text
 * with the label stripped. Otherwise null.
 */
function mdCallout(html) {
    const m = html.match(/^<strong>(CRITICAL|NOTE|ADMIN):<\/strong>\s*/);
    if (!m) return null;
    return { cls: MD_CALLOUTS[m[1]], label: m[1], body: html.slice(m[0].length) };
}

function mdTableRow(line) {
    return line.trim().replace(/^\|/, '').replace(/\|$/, '').split('|').map(c => c.trim());
}

function mdIsTableDivider(line) {
    return /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)*\|?\s*$/.test(line);
}

/**
 * Render markdown to an HTML string. Safe to drop straight into innerHTML.
 */
function renderMarkdown(src) {
    if (!src) return '';
    const lines = mdEscape(src).replace(/\r\n?/g, '\n').split('\n');
    const out = [];

    // Open list stack: each entry is { tag, indent }.
    let lists = [];
    let para = [];

    // A nested list belongs INSIDE the <li> above it, not beside it. When one
    // opens we lift the preceding </li> off the output and owe it back when the
    // nested list closes — otherwise the markup is a <ul> parented by an <ol>,
    // which is invalid and indents wrongly.
    function popList() {
        const entry = lists.pop();
        out.push(entry.nested ? '</' + entry.tag + '></li>' : '</' + entry.tag + '>');
    }

    function openList(tag, indent) {
        let nested = false;
        const last = out.length - 1;
        if (lists.length && out[last] && out[last].slice(-5) === '</li>') {
            out[last] = out[last].slice(0, -5);
            nested = true;
        }
        lists.push({ tag: tag, indent: indent, nested: nested });
        out.push('<' + tag + '>');
    }

    function closeLists() {
        while (lists.length) popList();
    }

    function flushPara() {
        if (!para.length) return;
        const html = mdInline(para.join(' '));
        const call = mdCallout(html);
        if (call) {
            out.push('<div class="gd-callout ' + call.cls + '"><span class="gd-callout-label">'
                + call.label + '</span><div class="gd-callout-body">' + call.body + '</div></div>');
        } else {
            out.push('<p>' + html + '</p>');
        }
        para = [];
    }

    function flushAll() {
        flushPara();
        closeLists();
    }

    for (let i = 0; i < lines.length; i++) {
        const line = lines[i].replace(/\s+$/, '');

        // A blank line ends a paragraph but leaves lists open, so a numbered
        // list with prose spacing between items stays one list.
        if (!line.trim()) { flushPara(); continue; }

        // Horizontal rule
        if (/^\s*(---+|\*\*\*+|___+)\s*$/.test(line)) {
            flushAll();
            out.push('<hr>');
            continue;
        }

        // Heading: # -> h2 ... #### -> h5
        const h = line.match(/^(#{1,4})\s+(.*)$/);
        if (h) {
            flushAll();
            const level = h[1].length + 1;
            out.push('<h' + level + ' id="s-' + mdSlugify(h[2]) + '">' + mdInline(h[2].trim())
                + '</h' + level + '>');
            continue;
        }

        // Table: a pipe row immediately followed by a divider row.
        if (line.indexOf('|') !== -1 && i + 1 < lines.length && mdIsTableDivider(lines[i + 1])) {
            flushAll();
            const head = mdTableRow(line);
            const rows = [];
            i += 2;
            while (i < lines.length && lines[i].indexOf('|') !== -1 && lines[i].trim()) {
                rows.push(mdTableRow(lines[i]));
                i++;
            }
            i--;
            let t = '<div class="gd-table-wrap"><table class="gd-table"><thead><tr>';
            head.forEach(c => { t += '<th>' + mdInline(c) + '</th>'; });
            t += '</tr></thead><tbody>';
            rows.forEach(r => {
                t += '<tr>';
                for (let c = 0; c < head.length; c++) t += '<td>' + mdInline(r[c] || '') + '</td>';
                t += '</tr>';
            });
            out.push(t + '</tbody></table></div>');
            continue;
        }

        // List item — ordered or unordered, indent decides nesting.
        const li = line.match(/^(\s*)(?:(\d+)\.|[-*+])\s+(.*)$/);
        if (li) {
            flushPara();
            const indent = li[1].length;
            const tag = li[2] ? 'ol' : 'ul';

            // Drop any deeper lists, then open one if we have stepped in.
            while (lists.length && lists[lists.length - 1].indent > indent) popList();
            const top = lists[lists.length - 1];
            if (!top || top.indent < indent) {
                openList(tag, indent);
            } else if (top.tag !== tag) {
                popList();
                openList(tag, indent);
            }

            const html = mdInline(li[3]);
            const call = mdCallout(html);
            if (call) {
                out.push('<li class="gd-li-callout"><span class="gd-tier ' + call.cls + '">'
                    + call.label + '</span> ' + call.body + '</li>');
            } else {
                out.push('<li>' + html + '</li>');
            }
            continue;
        }

        // An indented continuation line directly under a list item joins it,
        // which is how the source wraps long steps at 80 columns.
        if (lists.length && /^\s{2,}\S/.test(line) && !para.length) {
            const last = out.length - 1;
            if (out[last] && out[last].slice(-5) === '</li>') {
                out[last] = out[last].slice(0, -5) + ' ' + mdInline(line.trim()) + '</li>';
                continue;
            }
        }

        // Ordinary paragraph text.
        if (lists.length && !/^\s/.test(line)) closeLists();
        para.push(line.trim());
    }

    flushAll();
    return out.join('\n');
}

/**
 * Plain-text flattening, for the guides search filter.
 */
function markdownToText(src) {
    if (!src) return '';
    return String(src)
        .replace(/`{1,3}/g, ' ')
        .replace(/\[([^\]\n]+)\]\([^)\s]*\)/g, '$1')
        .replace(/[*#>|]/g, ' ')
        .replace(/\s+/g, ' ')
        .trim();
}
