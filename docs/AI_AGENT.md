# AI Agent

Open **Agent** on Mac (Cmd+5) or the **Agent** tab on iPhone/iPad. In **Agent
settings**, choose OpenAI, Anthropic, or an OpenAI-compatible server, enter a
model ID and your API key, and save. Models must support function/tool calling.
The model ID is editable; availability depends on your provider account.

OpenAI uses `/v1/chat/completions`; Anthropic uses `/v1/messages`. A custom
server's base URL should include its API prefix, for example
`https://your-server.example/v1`. The app adds `/chat/completions`. Local
servers such as LM Studio can leave the API key blank. Compatible endpoints
receive standard Chat Completions requests with tools and `max_tokens`.
HTTP endpoints are supported for servers on your own network; use HTTPS for
remote servers. On iPhone, `localhost` means the phone: use your computer's
LAN address for a server running there and allow local network access.

Each device runs its own agent and connects directly to its configured
provider. The phone can chat and make changes with the Mac closed or without
pairing. An internet connection to the provider (or access to a local model
server) is required for new AI responses. Existing conversations and app data
remain available offline.

Keys are stored outside the record store: stored in a nonsynchronizing,
device-only Keychain item on each device.
Provider keys are isolated by provider and endpoint. Switching the custom
server URL never sends a previous server's key to the new server. Keys and
provider settings do not sync; configure each device separately. Leave the
key field blank to keep an existing key, or select **Remove saved key**.

Conversations, messages, and action results are individual SQLite revision
records. They join the existing encrypted CloudKit queue and preserve messages
added independently on different devices. Pair both devices using the existing
iCloud setup to sync chats and data; update both apps before syncing agent
records. Signed/provisioned builds are still required for live CloudKit sync.
See [iCloud setup](IOS_SYNC.md). Local SQLite has the same disk-access
protection as the rest of Notebook; the app lock is not disk encryption.

The agent can search, read, create, update, and delete notes, journal entries,
tags, investment accounts and transactions, properties, debts, strategies,
watchlists, saved snapshots, bank/card accounts, spending records, and category
rules. It can also search and read Documents (see below). It uses the existing holdings and spending calculations. Portfolio
transaction edits reverse the old cash effect and apply the new one in one
SQLite write. Invalid account links, missing quantities/prices, overselling,
stale revisions, and deleting accounts/properties with dependent records are
rejected. Attachments remain in the existing media store; the agent works with
the textual record bodies and does not interpret photo/video contents.

**Allow edits** enables requested changes. Turn it off to analyze and search
without changing records. The conversation shows each tool result and the
records changed. Expand an activity to inspect its result. **Stop** cancels
the current request and prevents subsequent actions; completed actions remain
saved. Locking Notebook stops the agent. On iOS, backgrounding cancels a run;
you can continue the conversation when you reopen the app.

Responses stream live on Mac and iOS. A working indicator appears immediately,
then changes to writing, searching, reading, or saving as the agent progresses.
Finished paragraphs appear in quiet batches about every 600 ms. Incomplete
code blocks and tables wait until their structure is ready. **Live text** is a
per-device preference: turn it off to show each reply only when complete.
Incomplete tool arguments are never executed. If a response is stopped or disconnected, received text is retained
as an interrupted reply and completed actions stay saved. Compatible servers
that return a regular JSON response remain supported.

Chat updates preserve existing message nodes and expanded action details.
Sending moves to the new question once; streaming and completion leave your
viewport in place. **New text below** / **Jump to latest** lets you move to the
end explicitly. Desktop updates preserve finished paragraphs and selections;
the saved reply takes over the live article in place. Replies use a narrower
reading column, distinct heading levels, hanging list indents, and formatted
quotes, code and tables on both devices. Section selection, buttons, and dialogs
use smooth motion and respect Reduce Motion.

## Trading

On the Mac and iPhone, the agent sees everything in Trading. Its tools run
natively against Trading's own model, so the numbers match the screen:

- `trading_overview`: settings and risk rules, the Trading watchlist, the
  budget, cash and what's free, open risk against the total risk limit, profit
  on sold and open trades, alert counts, the last research run with its notes,
  the schedule, and whether Robinhood is connected.
- `trading_alerts`: alerts by status (buy, holding, sold, skipped, missed,
  open) with the full plan, the trade you logged, and the current value and
  profit, priced the way Trading prices them.
- `trading_ticker`: what a ticker page shows: the quote, company profile and
  key numbers, technicals and signal score, its alerts and research note, and
  headlines (untrusted data).
- `trading_update` (with **Allow edits**): add or remove watchlist symbols,
  change settings (including the minimum volume and market cap research
  uses), log that you bought or sold an alert, skip or delete one. Settings
  are checked (positive budget, percentages up to 100).

Research itself runs only from Trading, on its schedule or with Research Now,
never from the agent. The tools record what you did; they never place a trade.
Children never get them.
Electron has no Trading, so it doesn't offer them. `--test-agent-trading`
(DEBUG Mac build) runs each tool on a test alert and prints PASS or FAIL;
point it at a test copy with `NOTEBOOK_DATA_ROOT`.

## Documents and attachments

Files added in **Documents** (Cmd+6 on Mac, the Documents tab on iPhone/iPad) are
available to the agent like notes and Finance records. The `documents` collection
holds each file's name, type, size, page count, your notes and tags, and the text
recognized on-device: PDFKit for PDF text, Vision for images and scanned pages, a
built-in reader for Word, Excel and PowerPoint files, and plain decoding for text,
CSV, JSON, HTML and RTF. `search_records` matches names, notes, tags and recognized
text, and returns a snippet around the match. `read_document` returns the text in
pages of up to 20,000 characters with `nextOffset`, plus page markers such as
`[Page 3]` for multi-page PDFs and `[Sheet]`/`[Slide]` markers for Office files.
`read_record` returns a document's metadata with a short text preview. Tools cannot
create documents; `update_record` may change only name, notes and tags, and
`delete_record` removes the document and its bytes when the user asks.

**Attach in chat.** The paperclip (or dropping files on the composer, or pasting an
image) saves the files to Documents first, then references them in the message.
The model sees the list of attached documents with their ids and reads them with
`read_document`. Image attachments, and image documents read with `read_document`,
are also sent to the model as images when the provider is OpenAI or Anthropic
(the eight most recent distinct images per request, each at its latest mention,
using the downscaled preview). OpenAI-compatible servers receive the recognized
text only. The user message stores `attachments` (id, name, type) so both devices
show the same chips; the images themselves are loaded from the document record at
request time and are never duplicated into the conversation.

Document contents are untrusted data in the system prompt. Recognized text and
previews are produced locally; a document's text and image reach the AI provider
only when the agent reads that document in a conversation. Documents, their bytes
(`app_documentData_<id>`), and previews are revision records in the shared
encrypted sync queue, like journal media; the 25 MB per-file limit bounds sync
payloads. The original bytes are stored, never altered; previews are JPEG
renderings up to 1600 px, and list thumbnails up to 320 px.

## Web browsing

The agent can use `web_search` and `read_webpage` with every configured model,
including in read-only mode. Search uses DuckDuckGo's public Instant Answer API
directly; no extra key or account is needed. Its API provides topic abstracts,
answers, and related links, **not complete search-result listings or a news
feed**. An empty answer does not establish that no matching pages exist. This
limitation is included in each tool result and the agent's instructions.
[DuckDuckGo's published API documentation](https://github.com/duckduckgo/duckduckgo-publisher/blob/master/share/site/duckduckgo/api.tx).

The agent can read returned source URLs or a public URL supplied in chat.
HTML is converted to text without executing scripts; page links and longer
text can be followed through further tool calls. Replies cite sources, and
web activities show clickable DuckDuckGo/source attribution and retrieval
times. Those results are saved with the conversation and sync to the phone.
Both devices perform their own browsing; no Mac proxy is required.

Only public HTTP/HTTPS pages on standard ports are supported. Requests omit
provider API keys, login credentials, and cookies. Local/private/reserved
addresses, embedded URL credentials, oversized responses, and unsafe redirects
are rejected. Pages that require JavaScript, login, PDF reading, or downloads
are not supported. Search queries go to DuckDuckGo; pages are fetched directly
from their host, and their contents are passed to the chosen AI provider.
The system prompt treats web text as untrusted data and instructs the agent to
keep private notebook contents and credentials out of queries and URLs.

Relevant record contents and conversation context are sent to the chosen AI
provider while chatting. Retrieved records are treated as data in the system
prompt, and API keys and connection credentials are excluded from tool output.
The agent only changes local Finance records: it cannot execute real trades,
payments, or bank transfers. Current market quotes are not fetched by the
agent; finance summaries identify unpriced holdings, and saved snapshots are
available for historical valuations.

The shared tool definitions, data validation, history normalization, attachment
shaping, image loading, and provider protocol live in `js/agent/agent-core.js`;
text recognition lives in `native/Sources/NotebookCore/DocumentText.swift`, used
by both apps. Swift owns HTTP and uses JavaScriptCore to run the tool code on
iPhone and Mac.
Turns are stored before tools execute, and interrupted tool calls get an
explicit unknown-outcome result when a conversation resumes. Context includes
up to 16 recent complete turns within a 180 KB target; older messages remain
stored and readable in the UI. Runs stop after 24 model requests or 100 tool
calls, preserving completed work for a follow-up.

Protocol references: [OpenAI function calling](https://developers.openai.com/api/docs/guides/function-calling)
and [Anthropic tool calls](https://platform.claude.com/docs/en/agents-and-tools/tool-use/handle-tool-calls).

Validation: `npm test` covers the shared tool code: record edits, cash
adjustments, document tools, attachment shaping, provider stream parsing, web
search parsing and reply presentation.
`npm run test:native` covers independent-device chat merging, exercises the
shared agent tools in JavaScriptCore, and checks text recognition and document
records in SQLite.
