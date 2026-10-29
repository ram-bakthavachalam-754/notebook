/* Shared presentation only: transport and saved responses always retain every character. */
(function(root) {
    function reveal(text) {
        // Reveal finished paragraphs. Keep incomplete fences, links and tables
        // together so they do not change shape while the user is reading.
        let fence = null, boundary = 0, offset = 0;
        for (const line of text.split('\n')) {
            const marker = line.match(/^\s*(`{3,}|~{3,})/);
            if (marker) {
                if (!fence) fence = marker[1];
                else if (marker[1][0] === fence[0] && marker[1].length >= fence.length) fence = null;
            }
            if (!fence && !line.trim()) boundary = offset;
            offset += line.length + 1;
        }
        return text.slice(0, boundary).trimEnd();
    }

    function blocks(text) {
        const lines = text.replace(/\r\n/g, '\n').split('\n'), result = [];
        let i = 0, list = [];
        const add = (kind, content, extra = {}) => result.push({ id: result.length, kind, content, ...extra });
        const marker = line => line.match(/^(\s*)(?:(\d{1,9})[.)]|([-*+]))\s+(.*)$/);
        const heading = line => line.match(/^(#{1,6})\s+(.+)$/);
        const rule = line => /^\s*(?:-{3,}|\*{3,}|_{3,})\s*$/.test(line);
        const fence = line => line.match(/^\s*(`{3,}|~{3,})([^\s]*)\s*$/);
        const separator = line => /^\s*\|?\s*:?-{2,}:?\s*(\|\s*:?-{2,}:?\s*)+\|?\s*$/.test(line || '');
        const cells = line => line.trim().replace(/^\||\|$/g,'').split(/(?<!\\)\|/).map(cell=>cell.trim().replace(/\\\|/g,'|'));
        while (i < lines.length) {
            const line = lines[i];
            if (!line.trim()) { i++; continue; }
            const code = fence(line);
            if (code) {
                const content = []; list = []; i++;
                while (i < lines.length && !new RegExp('^\\s*' + code[1][0] + '{' + code[1].length + ',}\\s*$').test(lines[i])) content.push(lines[i++]);
                i++; add('code', content.join('\n'), { language: code[2] }); continue;
            }
            if (heading(line)) { list = []; add('heading', heading(line)[2], { level: heading(line)[1].length }); i++; continue; }
            const bold = line.match(/^\*\*(.+)\*\*$/);
            if (bold) { list = []; add('heading', bold[1], {level:3}); i++; continue; }
            if (rule(line)) { list = []; add('rule',''); i++; continue; }
            if (line.includes('|') && separator(lines[i+1])) {
                list = []; const rows = [cells(line)]; i += 2;
                while (i < lines.length && lines[i].includes('|') && lines[i].trim()) rows.push(cells(lines[i++]));
                add('table','',{rows}); continue;
            }
            if (/^\s*>/.test(line)) {
                list = []; const content = [];
                while (i < lines.length && /^\s*>/.test(lines[i])) content.push(lines[i++].replace(/^\s*>\s?/,''));
                add('quote',content.join('\n')); continue;
            }
            const item = marker(line);
            if (item) {
                const indent = item[1].length, ordered = item[2] !== undefined;
                while (list.length && list.at(-1).indent > indent) list.pop();
                let current = list.at(-1);
                if (!current || current.indent !== indent || current.ordered !== ordered) {
                    current = {indent,ordered,next:Number(item[2] || 1)};
                    if (list.at(-1)?.indent === indent) list.pop();
                    list.push(current);
                }
                const content = [item[4]], contentIndent = line.length-item[4].length; i++;
                while (i < lines.length) {
                    if (!lines[i].trim()) {
                        if (i+1 < lines.length && lines[i+1].match(/^\s*/)[0].length >= contentIndent && !marker(lines[i+1])) {content.push(''); i++; continue;}
                        break;
                    }
                    if (marker(lines[i]) || lines[i].match(/^\s*/)[0].length < contentIndent) break;
                    content.push(lines[i++].slice(contentIndent));
                }
                add('item',content.join('\n'),{marker:ordered?String(current.next++)+'.':'•',depth:list.length-1}); continue;
            }
            list = []; const content = [line]; i++;
            while (i < lines.length && lines[i].trim() && !marker(lines[i]) && !heading(lines[i]) && !rule(lines[i]) && !fence(lines[i]) && !/^\s*>/.test(lines[i]) && !separator(lines[i+1])) content.push(lines[i++]);
            add('paragraph',content.join('\n'));
        }
        return result;
    }
    const AgentPresentation = { reveal, blocks, interval: 600 };
    root.AgentPresentation = AgentPresentation;
    if (typeof module !== 'undefined') module.exports = AgentPresentation;
})(typeof globalThis !== 'undefined' ? globalThis : this);
