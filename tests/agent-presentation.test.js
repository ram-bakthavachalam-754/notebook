const { test } = require('node:test');
const assert = require('node:assert/strict');
const Presentation = require('../js/agent/agent-presentation');

test('separate story lists keep their original numbers after descriptions', () => {
    const reply = '# Top stories\n\n1. **First story**\n\nFirst description.\n\n2. **Second story**\n\nSecond description.\n\n3. **Third story**';
    const items = Presentation.blocks(reply).filter(block=>block.kind==='item');
    assert.deepEqual(items.map(item=>item.marker),['1.','2.','3.']);
});
test('indented descriptions and nested bullets belong to their ordered item', () => {
    const reply = '3. **Story**\n\n   A description with **emphasis**.\n   Still the same paragraph.\n\n   - Supporting point\n\n4. Next story';
    const items = Presentation.blocks(reply);
    assert.equal(items[0].content,'**Story**\n\nA description with **emphasis**.\nStill the same paragraph.');
    assert.equal(items[1].depth,1); assert.equal(items[2].marker,'4.');
});
test('repeated 1 markers form a normal consecutive list', () => {
    assert.deepEqual(Presentation.blocks('1. First\n\n1. Second\n\n1. Third').map(block=>block.marker),['1.','2.','3.']);
});
test('live reveal waits for complete paragraphs and retains every finished block', () => {
    const received = 'A finished paragraph.\n\nA partial [source](https://';
    assert.equal(Presentation.reveal(received),'A finished paragraph.');
    assert.equal(Presentation.reveal(received+'example.com/).\n\n'),received+'example.com/).');
    assert.equal(Presentation.reveal('A single unfinished paragraph.'),'');
});
test('fenced code with blank lines is held until its closing fence', () => {
    const source = 'Lead.\n\n```js\nconst value = 1;\n\nconst second = 2;\n';
    assert.equal(Presentation.reveal(source),'Lead.');
    assert.equal(Presentation.reveal(source+'```\n\nTail'),(source+'```').trimEnd());
    const code = Presentation.blocks(source+'```\n\nTail')[1];
    assert.equal(code.kind,'code'); assert.equal(code.language,'js'); assert.equal(code.content,'const value = 1;\n\nconst second = 2;');
});
test('mobile prose preserves heading hierarchy, quotes, tables and source links', () => {
    const blocks = Presentation.blocks('# Title\n\n## Section\n\n> A quote\n> More\n\n| Item | Source |\n| --- | --- |\n| Fact | [Source](https://example.com/) |\n\n---\n\nDone.');
    assert.deepEqual(blocks.map(block=>block.kind),['heading','heading','quote','table','rule','paragraph']);
    assert.deepEqual(blocks.filter(block=>block.kind==='heading').map(block=>block.level),[1,2]);
    assert.equal(blocks[2].content,'A quote\nMore');
    assert.deepEqual(blocks[3].rows,[['Item','Source'],['Fact','[Source](https://example.com/)']]);
});
