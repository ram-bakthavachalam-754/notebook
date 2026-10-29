const { test } = require('node:test');
const assert = require('node:assert/strict');
const Stream = require('../js/agent/agent-stream');
const Core = require('../js/agent/agent-core');
const sse = value => 'data: ' + JSON.stringify(value) + '\n\n';
const delta = (content, finish_reason = null) => ({choices:[{index:0,delta:{content},finish_reason}]});

test('OpenAI SSE can split across any boundary and yields text before completion', () => {
    const parser=Stream.create('openai'), first=sse(delta('Hello '));
    for (const character of first) parser.feed(character);
    assert.equal(parser.content,'Hello '); assert.equal(parser.done,false);
    parser.feed(sse(delta('world.','stop'))+'data: [DONE]\n\n');
    const result=Core.response(Core.defaults.openai,parser.finish());
    assert.equal(result.content,'Hello world.'); assert.deepEqual(result.tool_calls,[]);
});
test('streamed tools assemble complete arguments before they can execute', () => {
    const parser=Stream.create('compatible');
    parser.feed(sse({choices:[{index:0,delta:{tool_calls:[{index:0,id:'call',function:{name:'create_record',arguments:'{"collection":"notes",'}}]}}]}));
    assert.throws(()=>parser.finish(),/before the response finished/);
    parser.feed(sse({choices:[{index:0,delta:{tool_calls:[{index:0,function:{arguments:'"fields":{"title":"Streamed"}}'}}]},finish_reason:'tool_calls'}]})+'data: [DONE]\n\n');
    const answer=Core.response(Core.defaults.compatible,parser.finish());
    assert.equal(answer.tool_calls[0].function.name,'create_record'); assert.equal(JSON.parse(answer.tool_calls[0].function.arguments).fields.title,'Streamed');
});
test('Anthropic text and tool JSON deltas share the parser and preserve content block ordering', () => {
    const parser=Stream.create('anthropic');
    parser.feed('event: content_block_start\n'+sse({type:'content_block_start',index:0,content_block:{type:'text',text:''}}));
    parser.feed(sse({type:'content_block_delta',index:0,delta:{type:'text_delta',text:'I will check. '}}));
    assert.equal(parser.content,'I will check. ');
    parser.feed(sse({type:'content_block_start',index:1,content_block:{type:'tool_use',id:'tool',name:'web_search',input:{}}}));
    parser.feed(sse({type:'content_block_delta',index:1,delta:{type:'input_json_delta',partial_json:'{"query":"'}}));
    parser.feed(sse({type:'content_block_delta',index:1,delta:{type:'input_json_delta',partial_json:'Notebook"}'}}));
    parser.feed(sse({type:'message_delta',delta:{stop_reason:'tool_use'}})+sse({type:'message_stop'}));
    const answer=Core.response(Core.defaults.anthropic,parser.finish());
    assert.equal(answer.content,'I will check. '); assert.equal(JSON.parse(answer.tool_calls[0].function.arguments).query,'Notebook');
});
test('malformed, truncated and errored streams cannot be mistaken for completed answers', () => {
    const truncated=Stream.create('openai'); truncated.feed(sse(delta('Half an answer'))); assert.throws(()=>truncated.finish(),/before the response finished/);
    const malformed=Stream.create('openai'); assert.throws(()=>malformed.feed('data: not JSON\n\n'),/invalid stream/);
    const failed=Stream.create('anthropic'); assert.throws(()=>failed.feed(sse({type:'error',error:{message:'Overloaded'}})),/Overloaded/);
    const length=Stream.create('openai'); length.feed(sse(delta('Too long','length'))+'data: [DONE]\n\n'); assert.throws(()=>Core.response(Core.defaults.openai,length.finish()),/incomplete/);
});
test('Ollama-style tool calls without an index, and fed one line at a time, assemble', () => {
    const parser=Stream.create('compatible');
    const body=sse({choices:[{index:0,delta:{role:'assistant',content:'',tool_calls:[{id:'call_a1',type:'function',function:{name:'search_records',arguments:'{"collection":"notes","query":"milk"}'}}]}}]})
        +sse({choices:[{index:0,delta:{tool_calls:[{function:{name:'web_search',arguments:{query:'rain'}}}]},finish_reason:'tool_calls'}]})+'data: [DONE]\n\n';
    for (const line of body.split(/(?<=\n)/)) parser.feed(line);
    const answer=Core.response(Core.defaults.compatible,parser.finish());
    assert.deepEqual(answer.tool_calls.map(c=>[c.id,c.function.name,JSON.parse(c.function.arguments)]),[['call_a1','search_records',{collection:'notes',query:'milk'}],['call_1','web_search',{query:'rain'}]]);
});
test('Anthropic events fed one line at a time, as the native apps read them, assemble', () => {
    const parser=Stream.create('anthropic');
    const ev=(type,o)=>'event: '+type+'\ndata: '+JSON.stringify({type,...o})+'\n\n';
    const body=ev('message_start',{message:{id:'m'}})+ev('content_block_start',{index:0,content_block:{type:'text',text:''}})+ev('ping',{})
        +ev('content_block_delta',{index:0,delta:{type:'text_delta',text:'Hello '}})+ev('content_block_delta',{index:0,delta:{type:'text_delta',text:'there ✓'}})
        +ev('content_block_stop',{index:0})+ev('message_delta',{delta:{stop_reason:'end_turn'}})+ev('message_stop',{});
    for (const line of body.split(/(?<=\n)/)) parser.feed(line);
    assert.deepEqual(parser.finish().content,[{type:'text',text:'Hello there ✓'}]);
});
