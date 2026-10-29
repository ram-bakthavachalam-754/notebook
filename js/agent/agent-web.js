/* Shared web-tool protocol and text extraction for Node and iOS JavaScriptCore. */
(function (root) {
    'use strict';
    const tools = ['web_search', 'read_webpage'];
    const limitation = 'DuckDuckGo Instant Answers are topic summaries and related links, not a full web-search index. An empty result does not mean no web pages exist. For current facts, read an authoritative source URL.';
    function publicAddress(address) {
        address = String(address).toLowerCase().replace(/^\[|\]$/g, '');
        if (address.includes(':')) {
            if (!/^[0-9a-f:]+$/.test(address)) return false;
            const parts = address.split(':'), first = parseInt(parts[0], 16), second = parseInt(parts[1] || '0', 16);
            return first >= 0x2000 && first <= 0x3fff && first !== 0x2002 && !(first === 0x2001 && (second === 0 || second === 0xdb8));
        }
        if (!/^\d{1,3}(?:\.\d{1,3}){3}$/.test(address)) return false;
        const [a,b,c,d] = address.split('.').map(Number);
        if ([a,b,c,d].some(n => n > 255)) return false;
        return !(a === 0 || a === 10 || a === 127 || a >= 224 || a === 169 && b === 254 || a === 172 && b >= 16 && b <= 31 || a === 192 && (b === 168 || b === 0 || b === 88 && c === 99) || a === 100 && b >= 64 && b <= 127 || a === 198 && (b === 18 || b === 19 || b === 51 && c === 100) || a === 203 && b === 0 && c === 113);
    }
    function url(value) {
        if (typeof value !== 'string' || value.length > 2048 || /[\s\\\u0000-\u001f]/.test(value)) throw new Error('Enter a public HTTP or HTTPS URL.');
        const match = value.match(/^(https?):\/\/(\[[0-9a-f:]+\]|[a-z0-9.-]+)(?::(\d+))?([/?#][^\s]*)?$/i);
        if (!match) throw new Error('Enter a public URL without embedded credentials.');
        const scheme = match[1].toLowerCase(), host = match[2].toLowerCase().replace(/\.$/, ''), port = match[3];
        if (port && port !== (scheme === 'https' ? '443' : '80')) throw new Error('Web browsing supports standard HTTP and HTTPS ports.');
        if (host.startsWith('[') || /^[\d.]+$/.test(host)) {
            if (!publicAddress(host) || /^0\d/.test(host) || host.split('.').some(part => /^0\d/.test(part))) throw new Error('Web browsing cannot access private or reserved addresses.');
        } else if (!host.includes('.') || /(?:^|\.)(?:localhost|local|internal|lan|home|test|invalid|onion)$/.test(host) || host.split('.').some(label => !label || !/^[a-z0-9](?:[a-z0-9-]*[a-z0-9])?$/.test(label)) || /^0x[0-9a-f.]+$/.test(host)) throw new Error('Web browsing requires a public website.');
        const suffix = (match[4] || '/').split('#')[0];
        return scheme + '://' + host + (suffix.startsWith('?') ? '/' : '') + suffix;
    }
    function relativeURL(value, base) {
        value = decode(value).trim();
        if (/^https?:\/\//i.test(value)) return url(value);
        const origin = base.match(/^(https?):\/\/[^/?#]+/)[0];
        if (value.startsWith('//')) return url(base.split(':')[0] + ':' + value);
        if (/^[a-z][a-z0-9+.-]*:/i.test(value) || value.startsWith('#') || !value) throw new Error('Not a web link.');
        const current = base.split('#')[0].split('?')[0];
        if (value.startsWith('?')) return url(current + value);
        const path = value.startsWith('/') ? value : current.slice(origin.length).replace(/[^/]*$/, '') + value;
        const separator = path.search(/[?#]/), tail = separator < 0 ? '' : path.slice(separator);
        const normalized = [];
        for (const part of (separator < 0 ? path : path.slice(0, separator)).split('/')) { if (part === '..') normalized.pop(); else if (part && part !== '.') normalized.push(part); }
        return url(origin + '/' + normalized.join('/') + tail);
    }
    function decode(value) {
        return String(value || '').replace(/&(#x[0-9a-f]+|#\d+|amp|lt|gt|quot|apos|nbsp);/gi, (full, key) => {
            const entities = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: ' ' };
            if (key[0] !== '#') return entities[key.toLowerCase()] || full;
            const number = key[1].toLowerCase() === 'x' ? parseInt(key.slice(2), 16) : parseInt(key.slice(1), 10);
            return number > 0 && number <= 0x10ffff && !(number >= 0xd800 && number <= 0xdfff) ? String.fromCodePoint(number) : ' ';
        });
    }
    function text(html) {
        return decode(String(html || '').replace(/<!--[\s\S]*?-->/g, ' ').replace(/<(script|style|svg|noscript|template|iframe|object|form)\b[^>]*>[\s\S]*?<\/\1\s*>/gi, ' ').replace(/<br\b[^>]*>|<\/(?:p|div|li|h[1-6]|tr|section|article|blockquote|pre)>/gi, '\n').replace(/<[^>]*>/g, ' ')).replace(/[\t\r ]+/g, ' ').replace(/ *\n */g, '\n').replace(/\n{3,}/g, '\n\n').trim();
    }
    function integer(value, fallback, min, max) {
        if (value == null) return fallback;
        if (!Number.isInteger(value) || value < min || value > max) throw new Error('Invalid result limit or page offset.');
        return value;
    }
    /** `searchWith` is 'parallel' to search with Parallel's Search API; DuckDuckGo otherwise. */
    function prepare(name, args, searchWith) {
        if (!args || typeof args !== 'object' || Array.isArray(args)) throw new Error('Invalid web tool arguments.');
        if (name === 'web_search') {
            if (typeof args.query !== 'string' || !args.query.trim() || args.query.length > 300) throw new Error('Use a search query of 1–300 characters.');
            const query = args.query.trim(), limit = integer(args.limit, 5, 1, 10);
            if (searchWith === 'parallel') return { kind: 'search', provider: 'parallel', query, limit, url: 'https://api.parallel.ai/v1/search', body: { objective: query, search_queries: [query], advanced_settings: { max_results: limit, excerpt_settings: { max_chars_per_result: 1500 } } }, maxBytes: 1024 * 1024 };
            return { kind: 'search', query, limit, url: 'https://api.duckduckgo.com/?q=' + encodeURIComponent(query) + '&format=json&no_html=1&skip_disambig=1&no_redirect=1&t=notebook', maxBytes: 1024 * 1024 };
        }
        if (name === 'read_webpage') return { kind: 'page', url: url(args.url), offset: integer(args.offset, 0, 0, 2000000), maxCharacters: integer(args.maxCharacters, 12000, 1000, 20000), maxBytes: 2 * 1024 * 1024 };
        throw new Error('Unknown web tool.');
    }
    function search(spec, payload, fetchedAt) {
        if (!payload || typeof payload !== 'object' || Array.isArray(payload)) throw new Error('DuckDuckGo returned an invalid answer.');
        const results = [], seen = new Set();
        const add = (address, title, snippet, source) => {
            try { address = url(address); } catch { return; }
            if (seen.has(address)) return;
            seen.add(address); results.push({ url: address, title: text(title).slice(0, 200), snippet: text(snippet).slice(0, 1500), source });
        };
        if (payload.AbstractURL) add(payload.AbstractURL, payload.Heading || spec.query, payload.AbstractText, payload.AbstractSource || 'DuckDuckGo');
        if (payload.DefinitionURL) add(payload.DefinitionURL, payload.Heading || spec.query, payload.Definition, payload.DefinitionSource || 'DuckDuckGo');
        const walk = rows => { for (const row of Array.isArray(rows) ? rows : []) { if (row.Topics) walk(row.Topics); if (row.FirstURL) add(row.FirstURL, row.Text || spec.query, row.Text, 'DuckDuckGo'); } };
        walk(payload.Results); walk(payload.RelatedTopics);
        const selected = results.slice(0, spec.limit), searchURL = 'https://duckduckgo.com/?q=' + encodeURIComponent(spec.query);
        return { kind: 'search', provider: 'DuckDuckGo', query: spec.query, fetchedAt, answer: typeof payload.Answer === 'string' ? text(payload.Answer).slice(0, 4000) : '', abstract: text(payload.AbstractText).slice(0, 6000), results: selected, totalAvailable: results.length, limited: results.length > selected.length, limitation, message: results.length || payload.Answer || payload.AbstractText ? 'Read the source pages to verify details and recency.' : 'No Instant Answer or topic links were returned. Try a specific entity or read a source URL supplied by the user. This does not mean no matching web pages exist.', sources: [{ title: 'Results from DuckDuckGo', url: searchURL }, ...selected.map(r => ({ title: r.source + ' · ' + r.title, url: r.url }))] };
    }
    function parallelSearch(spec, payload, fetchedAt) {
        if (!payload || typeof payload !== 'object' || !Array.isArray(payload.results)) throw new Error('Parallel returned an invalid answer.');
        const results = [], seen = new Set();
        for (const row of payload.results) {
            let address; try { address = url(row?.url); } catch { continue; }
            if (seen.has(address)) continue;
            seen.add(address);
            const excerpts = Array.isArray(row.excerpts) ? row.excerpts.filter(e => typeof e === 'string') : [];
            results.push({ url: address, title: text(row.title || address).slice(0, 200), snippet: excerpts.join('\n\n').slice(0, 1500), published: typeof row.publish_date === 'string' ? row.publish_date.slice(0, 10) : null, source: 'Parallel' });
        }
        const selected = results.slice(0, spec.limit);
        return { kind: 'search', provider: 'Parallel', query: spec.query, fetchedAt, results: selected, totalAvailable: results.length, message: selected.length ? 'Excerpts are partial. Read the source pages to verify details and recency.' : 'Parallel returned no results. Try different keywords.', sources: selected.map(r => ({ title: r.title, url: r.url })) };
    }
    function page(spec, body, contentType, finalURL, fetchedAt) {
        finalURL = url(finalURL);
        const html = /^text\/html\b|^application\/xhtml\+xml\b/i.test(contentType);
        if (!html && !/^text\/plain\b|^text\/markdown\b|^application\/json\b/i.test(contentType)) throw new Error('This page is not HTML or text. PDFs, images, and downloads are not supported.');
        const title = html ? text(body.match(/<title\b[^>]*>([\s\S]*?)<\/title>/i)?.[1]).slice(0, 200) : finalURL;
        const full = html ? text(body) : String(body).trim(), links = [], seen = new Set();
        if (html) {
            const clean = body.replace(/<(script|style|svg|noscript|template|iframe|object|form)\b[^>]*>[\s\S]*?<\/\1\s*>/gi, ' ');
            const pattern = /<a\b[^>]*\bhref\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))[^>]*>([\s\S]*?)<\/a\s*>/gi;
            let match;
            while ((match = pattern.exec(clean)) && links.length < 30) {
                try { const address = relativeURL(match[1] || match[2] || match[3], finalURL); if (!seen.has(address)) { seen.add(address); links.push({ title: text(match[4]).slice(0, 200) || address, url: address }); } } catch { /* exclude nonpublic and nonweb links */ }
            }
        }
        const content = full.slice(spec.offset, spec.offset + spec.maxCharacters);
        if (!full) throw new Error('This page returned no readable text. It may require JavaScript or a login.');
        return { kind: 'page', url: finalURL, title: title || finalURL, fetchedAt, contentType, content, offset: spec.offset, totalCharacters: full.length, nextOffset: spec.offset + content.length < full.length ? spec.offset + content.length : null, links, sources: [{ title: title || finalURL, url: finalURL }], untrusted: true };
    }
    const AgentWeb = { tools, publicAddress, url, relativeURL, prepare, search, parallelSearch, page };
    root.AgentWeb = AgentWeb;
    if (typeof module !== 'undefined') module.exports = AgentWeb;
})(typeof globalThis !== 'undefined' ? globalThis : this);
