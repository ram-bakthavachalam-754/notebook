/* Incremental SSE parser shared by Electron and iOS JavaScriptCore. */
(function (root) {
    'use strict';
    class Stream {
        constructor(provider) { this.provider = provider; this.buffer = ''; this.content = ''; this.calls = new Map(); this.blocks = new Map(); this.done = false; this.reason = null; this.size = 0; }
        feed(chunk) {
            this.size += chunk.length;
            if (this.size > 10 * 1024 * 1024) throw new Error('The provider response was too large.');
            this.buffer += chunk;
            let match;
            while ((match = /\r?\n\r?\n/.exec(this.buffer))) {
                const frame = this.buffer.slice(0, match.index); this.buffer = this.buffer.slice(match.index + match[0].length);
                const data = frame.split(/\r?\n/).filter(line => line.startsWith('data:')).map(line => line.slice(5).replace(/^ /, '')).join('\n');
                if (!data || this.done) continue;
                if (data.trim() === '[DONE]') { this.done = true; continue; }
                let value; try { value = JSON.parse(data); } catch { throw new Error('The provider returned an invalid stream event.'); }
                if (value.error || value.type === 'error') throw new Error(value.error?.message || 'The provider interrupted the response.');
                if (this.provider === 'anthropic') this.claude(value); else this.openai(value);
            }
            return this.content;
        }
        openai(value) {
            const choice = value.choices?.find(c => c.index == null || c.index === 0);
            if (!choice) return;
            const delta = choice.delta || {};
            if (typeof delta.content === 'string') this.content += delta.content;
            if (typeof delta.refusal === 'string') this.content += delta.refusal;
            for (const fragment of delta.tool_calls || []) {
                // Ollama and some other servers leave out the index: a fragment
                // with a name starts the next call, anything else continues the last.
                const index = fragment.index != null ? fragment.index : fragment.function?.name ? this.calls.size : this.calls.size - 1;
                if (!Number.isInteger(index) || index < 0 || index >= 20) throw new Error('Invalid streamed tool call.');
                if (!this.calls.has(index)) this.calls.set(index, { id: '', type: 'function', function: { name: '', arguments: '' } });
                const call = this.calls.get(index);
                if (fragment.id) call.id += fragment.id;
                if (fragment.function?.name) call.function.name += fragment.function.name;
                if (fragment.function?.arguments) call.function.arguments += typeof fragment.function.arguments === 'string' ? fragment.function.arguments : JSON.stringify(fragment.function.arguments);
            }
            if (choice.finish_reason) this.reason = choice.finish_reason;
        }
        claude(value) {
            if (value.type === 'content_block_start') {
                const block = value.content_block;
                if (block?.type === 'tool_use') this.blocks.set(value.index, { type: 'tool_use', id: block.id, name: block.name, input: block.input || {}, partial: '' });
                else if (block?.type === 'text') { this.blocks.set(value.index, { type: 'text', text: block.text || '' }); this.content += block.text || ''; }
            }
            if (value.type === 'content_block_delta') {
                const block = this.blocks.get(value.index);
                if (value.delta?.type === 'text_delta' && block?.type === 'text') { block.text += value.delta.text; this.content += value.delta.text; }
                if (value.delta?.type === 'input_json_delta' && block?.type === 'tool_use') block.partial += value.delta.partial_json;
            }
            if (value.type === 'message_delta' && value.delta?.stop_reason) this.reason = value.delta.stop_reason;
            if (value.type === 'message_stop') this.done = true;
        }
        finish() {
            if (this.buffer.trim()) this.feed('\n\n');
            if (!this.done) throw new Error('The connection ended before the response finished.');
            if (this.provider === 'anthropic') {
                const content = Array.from(this.blocks.entries()).sort((a,b) => a[0]-b[0]).map(([,block]) => {
                    if (block.type === 'text') return block;
                    let input; try { input = block.partial ? JSON.parse(block.partial) : block.input; } catch { throw new Error('The model returned incomplete tool arguments.'); }
                    return { type: 'tool_use', id: block.id, name: block.name, input };
                });
                return { content, stop_reason: this.reason };
            }
            const calls = Array.from(this.calls.entries()).sort((a,b) => a[0]-b[0]).map(([,call]) => call);
            calls.forEach((call, i) => { if (!call.id && call.function.name) call.id = 'call_' + i; });
            for (const call of calls) { if (!call.function.arguments) call.function.arguments = '{}'; if (!call.id || !call.function.name) throw new Error('The model returned incomplete tool calls.'); try { JSON.parse(call.function.arguments); } catch { throw new Error('The model returned incomplete tool arguments.'); } }
            return { choices: [{ finish_reason: this.reason || (calls.length ? 'tool_calls' : 'stop'), message: { role: 'assistant', content: this.content, tool_calls: calls } }] };
        }
    }
    const AgentStream = { create: provider => new Stream(provider) };
    root.AgentStream = AgentStream;
    if (typeof module !== 'undefined') module.exports = AgentStream;
})(typeof globalThis !== 'undefined' ? globalThis : this);
