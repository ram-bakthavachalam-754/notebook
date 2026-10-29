const { test } = require('node:test');
const assert = require('node:assert/strict');
const http = require('node:http');
const { EventEmitter } = require('node:events');
const Web = require('../js/agent/agent-web');
const Core = require('../js/agent/agent-core');
const now = '2026-10-12T12:00:00.000Z';
const fixture = {
    Heading: 'Notebook', AbstractText: 'A notebook is used for writing.', AbstractURL: 'https://en.wikipedia.org/wiki/Notebook', AbstractSource: 'Wikipedia', Answer: '',
    Results: [{ FirstURL: 'https://example.com/official', Text: 'Official Notebook page' }],
    RelatedTopics: [{ Name: 'Related', Topics: [{ FirstURL: 'https://example.com/notes', Text: 'Notes and writing' }, { FirstURL: 'javascript:alert(1)', Text: 'Unsafe' }, { FirstURL: 'http://127.0.0.1/private', Text: 'Private' }, { FirstURL: 'https://example.com/official', Text: 'Duplicate' }] }]
};

test('DuckDuckGo requests encode the query and normalize nested source links with attribution', () => {
    const spec = Web.prepare('web_search', { query:'notes & journal?', limit:10 }), address = new URL(spec.url);
    assert.equal(address.hostname,'api.duckduckgo.com'); assert.equal(address.searchParams.get('q'),'notes & journal?');
    for (const field of ['no_html','skip_disambig','no_redirect']) assert.equal(address.searchParams.get(field),'1');
    assert.equal(address.searchParams.get('format'),'json');
    const result = Web.search(spec,fixture,now);
    assert.equal(result.results.length,3); assert.equal(result.results[0].source,'Wikipedia');
    assert.equal(result.sources[0].title,'Results from DuckDuckGo'); assert.equal(result.fetchedAt,now); assert.match(result.limitation,/not a full/);
    const short = Web.search(Web.prepare('web_search',{query:'Notebook',limit:1}),fixture,now);
    assert.equal(short.results.length,1); assert.equal(short.totalAvailable,3); assert.equal(short.limited,true);
});
test('empty DuckDuckGo answers disclose the API limit and never assert that no websites exist', () => {
    const result=Web.search(Web.prepare('web_search',{query:'latest niche news'}),{Results:[],RelatedTopics:[]},now);
    assert.equal(result.results.length,0); assert.match(result.message,/does not mean no matching web pages/);
    assert.throws(()=>Web.prepare('web_search',{query:''}),/search query/);
    assert.throws(()=>Web.prepare('web_search',{query:'x'.repeat(301)}),/search query/);
});
test('web tools remain available in read-only mode for every AI provider', () => {
    for (const provider of ['openai','anthropic','compatible']) {
        const config={...Core.defaults[provider],model:'test-model'};
        const request=Core.request(config,[{role:'user',content:'Research something'}],now,false);
        const names=request.body.tools.map(t=>t.name || t.function.name);
        assert.ok(names.includes('web_search')); assert.ok(names.includes('read_webpage')); assert.ok(!names.includes('create_record'));
    }
});
test('page reads strip scripts and forms, preserve text, resolve links and paginate long pages', () => {
    const body='<title>A &amp; B</title><style>hidden css</style><script>exfiltrate()</script><form>Secret input</form><h1>Welcome</h1><p>'+ 'Readable text. '.repeat(150)+'</p><a href="../source?q=https://example.com/a">Source</a><a href="javascript:attack()">Bad</a><a href="http://localhost/private">Private</a>';
    const spec=Web.prepare('read_webpage',{url:'https://example.com/articles/post',maxCharacters:1000});
    const first=Web.page(spec,body,'text/html; charset=UTF-8',spec.url,now);
    assert.equal(first.title,'A & B'); assert.ok(first.content.includes('Welcome'));
    for (const hidden of ['exfiltrate','hidden css','Secret input']) assert.ok(!first.content.includes(hidden));
    assert.equal(first.links.length,1); assert.equal(first.links[0].url,'https://example.com/source?q=https://example.com/a');
    assert.equal(first.content.length,1000); assert.equal(first.nextOffset,1000);
    const next=Web.page({...spec,offset:first.nextOffset},body,'text/html',spec.url,now);
    assert.equal(next.offset,1000); assert.equal(next.content.length,1000); assert.equal(first.untrusted,true);
    assert.throws(()=>Web.page(spec,'image','image/png',spec.url,now),/not HTML or text/);
    assert.throws(()=>Web.page(spec,'<script>onlyScript()</script>','text/html',spec.url,now),/no readable text/);
});
test('public URL checks block credentials, local services, reserved ranges and encoded IP bypasses', () => {
    for (const address of ['file:///private/secret','ftp://example.com/file','https://name:password@example.com','http://127.0.0.1','http://127.1','http://2130706433','http://0x7f000001','http://0177.0.0.1','http://192.168.1.1','http://10.0.0.1','http://100.64.0.1','http://169.254.169.254','http://198.18.0.1','http://192.0.2.1','http://203.0.113.1','http://224.1.1.1','http://[::1]','http://[::ffff:7f00:1]','http://[2001:0db8::1]','http://[2001:0000::1]','http://localhost','http://printer.local','https://example.com:8443','https://example.com\\@127.0.0.1','https://%31%32%37.0.0.1']) assert.throws(()=>Web.url(address),undefined,address);
    assert.equal(Web.url('https://example.com/path#section'),'https://example.com/path');
    assert.equal(Web.url('https://example.com:443/path'),'https://example.com/path');
    assert.equal(Web.publicAddress('8.8.8.8'),true); assert.equal(Web.publicAddress('2606:4700:4700::1111'),true);
});
test('Parallel search posts only the query and keeps public results with excerpts', () => {
    const spec = Web.prepare('web_search', { query: 'notebook apps 2026', limit: 2 }, 'parallel');
    assert.equal(spec.url, 'https://api.parallel.ai/v1/search');
    assert.deepEqual(spec.body, { objective: 'notebook apps 2026', search_queries: ['notebook apps 2026'], advanced_settings: { max_results: 2, excerpt_settings: { max_chars_per_result: 1500 } } });
    const result = Web.parallelSearch(spec, { search_id: 's', results: [
        { url: 'https://example.com/a', title: 'A &amp; B', publish_date: '2026-10-01', excerpts: ['First', 'Second'] },
        { url: 'http://127.0.0.1/private', title: 'Private', excerpts: ['x'] },
        { url: 'https://example.com/a', title: 'Duplicate', excerpts: [] },
        { url: 'https://example.com/b', title: null, excerpts: ['Only'] },
        { url: 'https://example.com/c', title: 'Over limit', excerpts: [] }
    ] }, now);
    assert.equal(result.provider, 'Parallel');
    assert.deepEqual(result.results.map(r => r.url), ['https://example.com/a', 'https://example.com/b']);
    assert.equal(result.results[0].title, 'A & B');
    assert.equal(result.results[0].snippet, 'First\n\nSecond');
    assert.equal(result.results[0].published, '2026-10-01');
    assert.throws(() => Web.parallelSearch(spec, { error: 'nope' }, now), /invalid answer/);
});

test('the agent describes Parallel search only when it is chosen', () => {
    const config = { provider: 'openai', baseURL: 'https://api.openai.com/v1', model: 'gpt-5.4' };
    const tool = spec => spec.body.tools.find(t => t.function.name === 'web_search').function.description;
    const plain = Core.request(config, [{ role: 'user', content: 'hi' }], now);
    const parallel = Core.request(config, [{ role: 'user', content: 'hi' }], now, true, null, null, 'parallel');
    assert.match(tool(plain), /DuckDuckGo/);
    assert.match(tool(parallel), /Parallel/);
    assert.doesNotMatch(parallel.body.messages[0].content, /DuckDuckGo/);
});
