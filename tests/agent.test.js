const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { randomUUID } = require('node:crypto');
const Core = require('../js/agent/agent-core');
const now = '2026-10-12T12:00:00.000Z';
const options = { id: 'new-record', now, allowWrites: true };
function memoryStore() {
    const data = {}; let counter = 0;
    return { data, get: key => structuredClone(data[key]), set(key, value) {
        const fields = { app_notes:'notes', app_journal:'entries', app_tags:'tags', app_agentThreads:'threads', app_agentMessages:'messages', app_documents:'documents', app_links:'links' };
        if (!fields[key]) { data[key] = structuredClone(value); return structuredClone(value); }
        const field = fields[key], rows = data[key]?.[field] || [], removed = new Set((value._syncDeleted || []).map(r => r.id)), changed = new Map((value[field] || []).map(r => [r.id, { ...structuredClone(r), _syncHeads: ['revision-' + ++counter] }]));
        data[key] = { [field]: [...rows.filter(r => !removed.has(r.id)).map(r => changed.has(r.id) ? changed.get(r.id) : r), ...Array.from(changed.values()).filter(r => !rows.some(old => old.id === r.id))] };
        return structuredClone(data[key]);
    }, delete(key) { delete data[key]; } };
}
function withDocument(store, overrides = {}) {
    const text = overrides.text ?? 'Quarterly rent receipt. Amount paid: 2450.00 USD for October 2026. ' + 'More lines of the receipt follow. '.repeat(120);
    store.set('app_documents', { documents:[{ id:'doc', name:'receipt.pdf', type:'application/pdf', size:15511, pages:1, text, textStatus:'ready', textMethod:'pdf', textMessage:'', notes:'', tags:[], source:'documents', hasPreview:true, createdAt:now, modifiedAt:now, ...overrides }] });
    store.set('app_documentData_doc', { id:'doc', type:overrides.type || 'application/pdf', data:'data:application/pdf;base64,JVBERi0=', preview:'data:image/jpeg;base64,/9j/preview', thumb:'data:image/jpeg;base64,/9j/thumb' });
}
// Loads the finance scripts the way the iPhone and Mac apps do in JavaScriptCore.
function financeEngine(store, authorized, changed) {
    const guard = () => { if (!authorized()) throw new Error('Notebook is locked.'); };
    const sandbox = vm.createContext({
        console: { log() {}, warn() {}, error() {} }, window: {}, AppManager: { register() {} },
        localStorage: { getItem: () => null, setItem() {} },
        UIUtils: { todayISO: () => new Date().toISOString().slice(0, 10) },
        StorageManager: {
            get: key => { guard(); return store.get('app_' + key); },
            set: (key, value) => { guard(); const saved = store.set('app_' + key, value); changed('app_' + key); return saved; }
        }
    });
    for (const name of ['../js/apps/portfolio/portfolio-app.js', '../js/apps/portfolio/spending-app.js', '../js/agent/agent-finance.js']) {
        vm.runInContext(fs.readFileSync(path.join(__dirname, name), 'utf8'), sandbox);
    }
    return sandbox.AgentFinance;
}
function tools(store, authorized = () => true) {
    const finance = financeEngine(store, authorized, () => {});
    return { get: key => store.get(key), set: (key, value) => store.set(key, value), portfolioTransaction: (row, deleting) => finance.transaction(row, deleting), financeSummary: month => finance.summary(month) };
}
const toolCall = (name, args, id = randomUUID()) => ({ id, type:'function', function:{ name, arguments:JSON.stringify(args) } });

test('agent searches every collection, reads complete content and preserves rich text on metadata-only edits', () => {
    const store = memoryStore(), io = tools(store);
    store.set('app_notes', { notes:[{ id:'n', title:'Original', content:'<h1>Keep formatting</h1>', tags:['work'] }] });
    const schema = Core.execute('notebook_schema', {}, io, options);
    assert.equal(schema.collections.length, 17);
    const found = Core.execute('search_records', { collection:'notes', query:'formatting' }, io, options).records[0];
    assert.equal(found.id, 'n');
    assert.equal(Core.execute('read_record', { collection:'notes', id:'n' }, io, options).record.content, '<h1>Keep formatting</h1>');
    Core.execute('update_record', { collection:'notes', id:'n', revision:found.revision, fields:{ title:'Changed' } }, io, options);
    assert.equal(store.get('app_notes').notes[0].content, '<h1>Keep formatting</h1>');
    assert.throws(() => Core.execute('update_record', { collection:'notes', id:'n', revision:found.revision, fields:{ title:'Stale' } }, io, options), /changed since/);
});
test('documents are searchable by recognized text, readable in pages, and only their name, notes and tags can change', () => {
    const store=memoryStore(), io={...tools(store), remove:key=>store.delete(key)};
    withDocument(store);
    const schema=Core.execute('notebook_schema',{},io,options).collections.find(c=>c.collection==='documents');
    assert.ok(schema.sample.text.length<=300); assert.match(schema.fields,/read_document/);
    const found=Core.execute('search_records',{collection:'documents',query:'2450.00'},io,options);
    assert.equal(found.records[0].id,'doc'); assert.match(found.records[0].excerpt,/snippet/); assert.match(found.records[0].excerpt,/2450\.00/);
    assert.equal(Core.execute('search_records',{collection:'documents',query:'missing words'},io,options).total,0);
    const read=Core.execute('read_record',{collection:'documents',id:'doc'},io,options);
    assert.ok(read.record.text.length<=1500); assert.match(read.hint,/read_document/); assert.equal(read.record.textLength>1500,true);
    const first=Core.execute('read_document',{id:'doc',maxCharacters:1000},io,options);
    assert.equal(first.kind,'document'); assert.equal(first.content.length,1000); assert.equal(first.nextOffset,1000); assert.equal(first.untrusted,true); assert.equal(first.view,undefined);
    const rest=Core.execute('read_document',{id:'doc',offset:first.nextOffset,maxCharacters:20000},io,options);
    assert.equal(rest.nextOffset,null); assert.equal(first.content+rest.content,store.get('app_documents').documents[0].text);
    assert.throws(()=>Core.execute('read_document',{id:'nope'},io,options),/not found/);
    assert.throws(()=>Core.execute('create_record',{collection:'documents',fields:{name:'fake.pdf',text:'invented'}},io,options),/uploading files/);
    assert.throws(()=>Core.execute('update_record',{collection:'documents',id:'doc',revision:read.revision,fields:{text:'rewritten'}},io,options),/Only a document/);
    Core.execute('update_record',{collection:'documents',id:'doc',revision:read.revision,fields:{notes:'October rent',tags:['rent']}},io,options);
    const updated=store.get('app_documents').documents[0];
    assert.equal(updated.notes,'October rent'); assert.match(updated.text,/Quarterly rent/);
    const again=Core.execute('read_record',{collection:'documents',id:'doc'},io,options);
    Core.execute('delete_record',{collection:'documents',id:'doc',revision:again.revision},io,options);
    assert.deepEqual(store.get('app_documents').documents,[]); assert.equal(store.get('app_documentData_doc'),undefined);
});
test('image documents are described in the user turn and attached as images only for vision-capable providers', () => {
    const store=memoryStore(), io=tools(store);
    withDocument(store,{id:'doc',name:'invoice.png',type:'image/png',text:'Invoice 4471'});
    const user=Core.shape({role:'user',content:'What is this?',attachments:[{id:'doc',name:'invoice.png',type:'image/png'}]});
    assert.match(user.content,/Attached documents: "invoice.png" \(document id doc, image\/png\)/); assert.deepEqual(user.images,['doc']);
    const toolResult=Core.shape({role:'tool',tool_call_id:'c1',tool:'read_document',content:JSON.stringify(Core.execute('read_document',{id:'doc'},io,options))});
    assert.deepEqual(toolResult.images,['doc']); assert.match(toolResult.content,/"view":"image"/);
    const messages=[user,{role:'assistant',content:'',tool_calls:[toolCall('read_document',{id:'doc'},'c1')]},toolResult];
    const loader=Core.imageLoader(io);
    assert.deepEqual(loader('doc'),{mediaType:'image/jpeg',data:'/9j/preview'}); assert.equal(loader('missing'),null);
    const openai=Core.request(Core.defaults.openai,messages,now,true,loader).body.messages;
    assert.equal(typeof openai[1].content,'string','an earlier mention of the same image is not resent');
    assert.equal(openai[3].role,'tool'); assert.equal(typeof openai[3].content,'string');
    assert.equal(openai[4].role,'user'); assert.equal(openai[4].content[1].image_url.url,'data:image/jpeg;base64,/9j/preview');
    assert.equal(openai.some(m=>'images' in m),false);
    const claude=Core.request(Core.defaults.anthropic,messages,now,true,loader).body.messages;
    const result=claude.at(-1).content[0];
    assert.equal(result.type,'tool_result'); assert.equal(result.content[1].type,'image'); assert.equal(result.content[1].source.media_type,'image/jpeg');
    const compatible=Core.request({...Core.defaults.compatible,model:'local'},messages,now,true,loader).body.messages;
    assert.equal(compatible.length,4); assert.equal(JSON.stringify(compatible).includes('/9j/preview'),false);
    const inline=Core.request(Core.defaults.openai,[user],now,true,loader).body.messages[1];
    assert.equal(inline.content[0].text,user.content+'\n\nCurrent date/time: '+now); assert.equal(inline.content[1].type,'image_url');
    assert.equal(Core.history([{id:'u',role:'user',content:'Look',attachments:[{id:'doc',name:'invoice.png',type:'image/png'}],runID:'r',runAt:now,sequence:0}])[0].images[0],'doc');
    assert.ok(Core.tools.some(t=>t.function.name==='read_document'));
    assert.match(Core.request(Core.defaults.openai,[user],now,true).body.messages[0].content,/Documents are files the user uploaded/);
});
test('search paginates deterministically and includes matches beyond the first page', () => {
    const store=memoryStore(), io=tools(store);
    store.set('app_notes', {notes:Array.from({length:55}, (_,i)=>({id:String(i),title:'Project '+i}))});
    const first=Core.execute('search_records',{collection:'notes',limit:50},io,options);
    const last=Core.execute('search_records',{collection:'notes',offset:first.nextOffset,limit:50},io,options);
    assert.equal(first.total,55); assert.equal(last.records.length,5); assert.equal(last.nextOffset,null);
});
test('read-only mode, protected metadata, unknown collections and unsafe HTML cannot bypass tool constraints', () => {
    const store=memoryStore(), io=tools(store);
    assert.throws(()=>Core.execute('create_record',{collection:'notes',fields:{title:'No'}},io,{...options,allowWrites:false}),/read-only/);
    for (const field of ['_syncHeads','apiKey','__proto__','id']) assert.throws(()=>Core.execute('create_record',{collection:'notes',fields:JSON.parse('{"'+field+'":"bad"}')},io,options),/protected/);
    assert.throws(()=>Core.execute('read_record',{collection:'agent-settings',id:'secret'},io,options),/Unknown collection/);
    Core.execute('create_record',{collection:'journal',fields:{content:'<script>attack()</script>\nHello',tags:['daily']}},io,options);
    assert.equal(store.get('app_journal').entries[0].content,'<p>&lt;script&gt;attack()&lt;/script&gt;<br>Hello</p>');
    assert.equal(store.get('app_journal').entries[0].mood,'neutral');
});
test('agent excludes secrets and sync metadata from tool output, while supplying opaque revisions', () => {
    const store=memoryStore(), io=tools(store);
    store.set('app_portfolio',{accounts:[{id:'a',name:'Account',brokerage:{accessToken:'secret'},apiKey:'secret',_syncHeads:['head']}]});
    const schema=Core.execute('notebook_schema',{},io,options);
    const read=Core.execute('read_record',{collection:'portfolio.accounts',id:'a'},io,options);
    assert.equal(read.revision,'["head"]'); assert.equal(read.record.brokerage,undefined);
    assert.equal(JSON.stringify(schema).includes('secret'),false);
});
test('portfolio buys, edits, deletes and options keep cash consistent; invalid sells and linked deletes write nothing', () => {
    const store=memoryStore(), io=tools(store);
    store.set('app_portfolio',{accounts:[{id:'a',name:'Account',cashBalance:1000}],transactions:[]});
    const buy={collection:'portfolio.transactions',fields:{accountId:'a',type:'buy',ticker:'AAPL',quantity:2,pricePerShare:100,date:'2026-10-12'}};
    Core.execute('create_record',buy,io,options);
    assert.equal(store.get('app_portfolio').accounts[0].cashBalance,800);
    const read=Core.execute('read_record',{collection:buy.collection,id:options.id},io,options);
    Core.execute('update_record',{collection:buy.collection,id:options.id,revision:read.revision,fields:{quantity:3}},io,options);
    assert.equal(store.get('app_portfolio').accounts[0].cashBalance,700);
    const account=Core.execute('read_record',{collection:'portfolio.accounts',id:'a'},io,options);
    assert.throws(()=>Core.execute('delete_record',{collection:'portfolio.accounts',id:'a',revision:account.revision},io,options),/has transactions/);
    assert.throws(()=>Core.execute('create_record',{...buy,fields:{...buy.fields,type:'sell',quantity:4}},io,{...options,id:'bad'}),/enough shares/);
    assert.equal(store.get('app_portfolio').accounts[0].cashBalance,700);
    const changed=Core.execute('read_record',{collection:buy.collection,id:options.id},io,options);
    Core.execute('delete_record',{collection:buy.collection,id:options.id,revision:changed.revision},io,options);
    assert.equal(store.get('app_portfolio').accounts[0].cashBalance,1000);
    Core.execute('create_record',{...buy,fields:{...buy.fields,ticker:'AAPL261218C00250000',quantity:1,pricePerShare:2}},io,{...options,id:'option'});
    assert.equal(store.get('app_portfolio').accounts[0].cashBalance,800);
});
test('selling every fractional share is allowed despite floating-point sums', () => {
    const store=memoryStore(), io=tools(store);
    store.set('app_portfolio',{accounts:[{id:'a',name:'Account',cashBalance:1000}],transactions:[
        {id:'b1',accountId:'a',type:'buy',ticker:'VTI',quantity:0.7,pricePerShare:10,date:'2026-10-01'},
        {id:'b2',accountId:'a',type:'buy',ticker:'VTI',quantity:0.1,pricePerShare:10,date:'2026-10-02'}]});
    Core.execute('create_record',{collection:'portfolio.transactions',fields:{accountId:'a',type:'sell',ticker:'VTI',quantity:0.8,pricePerShare:10,date:'2026-10-03'}},io,{...options,id:'s'});
    assert.equal(store.get('app_portfolio').transactions.length,3);
});
test('financial validation blocks invalid quantities, balances, account links, and duplicate snapshot days', () => {
    const store=memoryStore(), io=tools(store);
    for (const fields of [{accountId:'missing',type:'buy',quantity:1,pricePerShare:20}, {accountId:'missing',amount:'20'}]) assert.throws(()=>Core.execute('create_record',{collection:'portfolio.transactions',fields},io,options));
    assert.throws(()=>Core.execute('create_record',{collection:'spending.accounts',fields:{name:'Bank',balance:200}},io,options),/Bank balance/);
    Core.execute('create_record',{collection:'history.snapshots',fields:{date:'2026-10-12',netWorth:10}},io,options);
    assert.equal(store.get('app_portfolio-history').snapshots[0].id,'2026-10-12');
    assert.throws(()=>Core.execute('create_record',{collection:'history.snapshots',fields:{date:'2026-10-12',netWorth:20}},io,{...options,id:'other'}),/already exists/);
});
test('nested finance patches preserve unrelated bank balances and strategy settings', () => {
    const store=memoryStore(), io=tools(store);
    store.set('app_spending',{accounts:[{id:'bank',name:'Checking',balance:{current:100,available:90,limit:null}}]});
    const read=Core.execute('read_record',{collection:'spending.accounts',id:'bank'},io,options);
    Core.execute('update_record',{collection:'spending.accounts',id:'bank',revision:read.revision,fields:{balance:{current:200}}},io,options);
    assert.deepEqual(store.get('app_spending').accounts[0].balance,{current:200,available:90,limit:null});
});
test('finance summary uses existing calculations and explicitly reports missing market prices', () => {
    const store=memoryStore(), io=tools(store);
    store.set('app_portfolio',{accounts:[{id:'a',name:'Brokerage',cashBalance:1000}],transactions:[{id:'t',accountId:'a',type:'holding',ticker:'AAPL',quantity:2,pricePerShare:100,date:'2026-10-01'}]});
    store.set('app_spending',{accounts:[],transactions:[{id:'s',amount:20,date:'2026-10-05',category:'GROCERIES'}],rules:[]});
    const summary=Core.execute('finance_summary',{month:'2026-10'},io,options);
    assert.deepEqual(Array.from(summary.unpriced),['AAPL']); assert.equal(summary.holdings[0].totalShares,2); assert.equal(summary.spending.spend,20);
});
test('OpenAI and compatible use Chat Completions; Anthropic groups tool results with their calls', () => {
    const call=toolCall('notebook_schema',{},'call-1');
    const messages=[{role:'user',content:'Read data'},{role:'assistant',content:'Looking',tool_calls:[call]},{role:'tool',tool_call_id:'call-1',content:'{}'},{role:'user',content:'Thanks'}];
    const openai=Core.request(Core.defaults.openai,messages,now,true);
    assert.equal(openai.url,'https://api.openai.com/v1/chat/completions'); assert.equal(openai.body.store,false);
    const claude=Core.request(Core.defaults.anthropic,messages,now,true);
    assert.equal(claude.url,'https://api.anthropic.com/v1/messages'); assert.equal(claude.body.messages[1].content[1].type,'tool_use');
    assert.equal(claude.body.messages[2].content[0].type,'tool_result'); assert.equal(claude.body.messages[2].content[1].text,'Thanks\n\nCurrent date/time: '+now);
    assert.equal(Core.request(Core.defaults.openai,messages,now,false).body.tools.some(t=>t.function.name==='create_record'),false);
    const parsed=Core.response(Core.defaults.anthropic,{stop_reason:'tool_use',content:[{type:'tool_use',id:'c',name:'notebook_schema',input:{}}]});
    assert.equal(parsed.tool_calls[0].function.arguments,'{}');
    assert.throws(()=>Core.response(Core.defaults.openai,{choices:[{finish_reason:'length',message:{content:'half'}}]}),/incomplete/);
});
test('the time rides on the newest user message so the prompt and earlier turns stay cacheable', () => {
    const local={...Core.defaults.compatible,model:'local'}, messages=[{role:'user',content:'First'},{role:'assistant',content:'Done'},{role:'user',content:'Second'}];
    const early=Core.request(local,messages,'2026-10-12T12:00:00Z',true).body.messages, late=Core.request(local,messages,'2026-10-12T12:05:00Z',true).body.messages;
    assert.deepEqual(early.slice(0,3),late.slice(0,3),'the system prompt and earlier turns do not change with the time');
    assert.equal(late[3].content,'Second\n\nCurrent date/time: 2026-10-12T12:05:00Z');
    assert.match(Core.request(local,[],'2026-10-12T12:00:00Z',true).body.messages[0].content,/Current date\/time: 2026-10-12T12:00:00Z/);
});
test('interrupted and concurrently merged turns retain correct tool ordering for either provider', () => {
    const call=toolCall('create_record',{collection:'notes',fields:{title:'Note'}},'pending');
    const messages=[{id:'a',role:'user',content:'First',runID:'run1',runAt:now,sequence:0},{id:'b',role:'assistant',tool_calls:[call],runID:'run1',runAt:now,sequence:1},{id:'c',role:'user',content:'Second',runID:'run2',runAt:'2026-10-12T12:01:00Z',sequence:0}];
    const history=Core.history(messages.reverse());
    assert.deepEqual(history.map(m=>m.role),['user','assistant','tool','user']); assert.match(history[2].content,/outcome may be unknown/);
    assert.doesNotThrow(()=>Core.request(Core.defaults.anthropic,history,now,true));
});
test('concurrent conversation title versions display as one chat with the canonical message thread ID', () => {
    const rows = [{id:'chat~second',_syncEntity:'chat',_syncConflict:true,title:'Phone title',createdAt:now},{id:'chat',_syncEntity:'chat',_syncConflict:false,title:'Mac title',createdAt:now},{id:'newer',title:'Newer conversation',createdAt:'2026-10-13T00:00:00Z'}];
    const threads=Core.threads(rows);
    assert.equal(threads.length,2); assert.equal(threads[0].id,'newer'); assert.equal(threads[1].id,'chat'); assert.equal(threads[1].title,'Mac title');
});
test('agent saves links into existing collections, validates urls and deletes explicitly', () => {
    const store = memoryStore(), io = tools(store);
    Core.execute('create_record', { collection:'links', fields:{ type:'collection', name:'Recipes' } }, io, { ...options, id:'c1' });
    Core.execute('create_record', { collection:'links', fields:{ url:'https://example.com/soup', title:'Soup', collectionId:'c1', tags:['dinner'] } }, io, { ...options, id:'l1' });
    const saved = store.get('app_links').links.find(r => r.id === 'l1');
    assert.equal(saved.type, 'link'); assert.equal(saved.savedBy, 'Agent'); assert.equal(saved.collectionId, 'c1');
    assert.throws(() => Core.execute('create_record', { collection:'links', fields:{ url:'javascript:alert(1)' } }, io, { ...options, id:'l2' }), /http or https/);
    assert.throws(() => Core.execute('create_record', { collection:'links', fields:{ url:'https://example.com', collectionId:'missing' } }, io, { ...options, id:'l3' }), /existing collection/);
    assert.throws(() => Core.execute('create_record', { collection:'links', fields:{ type:'folder', name:'x' } }, io, { ...options, id:'l4' }), /type/);
    const found = Core.execute('search_records', { collection:'links', query:'soup' }, io, options).records[0];
    assert.equal(found.id, 'l1');
    Core.execute('delete_record', { collection:'links', id:'l1', revision:found.revision }, io, options);
    assert.equal(store.get('app_links').links.some(r => r.id === 'l1'), false);
});

test('Trading tools are offered only when the host has Trading, and read-only drops its changes', () => {
    const names = spec => spec.body.tools.map(t => t.function ? t.function.name : t.name);
    const messages = [{ role:'user', content:'How are my trades?' }];
    const without = Core.request(Core.defaults.openai, messages, now, true);
    assert.ok(!names(without).some(n => n.startsWith('trading_')));
    assert.doesNotMatch(without.body.messages[0].content, /trading_overview/);
    const edits = Core.request(Core.defaults.anthropic, messages, now, true, null, null, null, true);
    assert.deepEqual(names(edits).filter(n => n.startsWith('trading_')), ['trading_overview', 'trading_alerts', 'trading_ticker', 'trading_update']);
    assert.match(edits.body.system, /trading_overview/);
    const readOnly = Core.request(Core.defaults.openai, messages, now, false, null, null, null, true);
    assert.deepEqual(names(readOnly).filter(n => n.startsWith('trading_')), ['trading_overview', 'trading_alerts', 'trading_ticker']);
    // The host runs them; the shared engine never does.
    assert.throws(() => Core.execute('trading_overview', {}, { get:() => ({}) }, options), /Unknown/);
});
