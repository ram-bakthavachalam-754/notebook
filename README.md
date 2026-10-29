# Notebook

A private, local-first notebook for Mac, iPhone and iPad: **Notes, Journal,
Finance, Trading, Explore, Links, Documents and an AI Agent** in one native
SwiftUI app.

There's no Notebook server and no account. Your records live in a SQLite
database on your own device. The AI agent talks directly to the provider *you*
choose, with *your* API key, or to a model running on your own machine.

## Download (Mac)

Get the latest `Notebook-<version>.dmg` from the
[Releases](../../releases) page, open it and drag Notebook to Applications.
The download is signed and notarized by Apple. It needs macOS 14 or later and
runs natively on Apple silicon and Intel.

The download keeps everything on that Mac: it has no iCloud sync. To sync with
your iPhone, build it yourself with your own Apple developer team (see
[iCloud sync](#icloud-sync-optional)).

## Connect your AI provider

Open **Agent → Agent settings** and choose one of these:

- **OpenAI** or **Anthropic**: enter a model ID and your API key.
- **OpenAI-compatible**: any server with a Chat Completions API, such as
  [Ollama](https://ollama.com) (`http://localhost:11434/v1`), LM Studio
  (`http://localhost:1234/v1`) or a hosted gateway. Local servers need no key.

Models must support tool (function) calling. Keys are stored in the device's
Keychain, never in the database, and never sync. The agent can search, read and
(with **Allow edits** on) change your notes, journal, finance records, links and
documents, and it shows every action it takes.
[More about the agent](docs/AI_AGENT.md).

## What's inside

| Section | |
| --- | --- |
| Notes, Journal | Rich text, tags, moods, photos, search. |
| Finance | Accounts and holdings, live prices, a page per ticker with charts, key numbers and news. Import and export as JSON. |
| Trading (Mac) | Daily research on a watchlist that suggests stock and defined-risk option trades sized by your own budget and risk rules, then alerts you when to sell. [How it works](docs/TRADING.md). |
| Explore (Mac) | The S&P 500, the Nasdaq-100 and tech indexes by industry, with a heat map. [Details](docs/EXPLORE.md). |
| Links, Documents | Saved web links, and files with recognized text. |
| Agent | Chat with your AI model across everything above. |

More: [Native Mac app](docs/NATIVE_MAC.md) · [Kid mode](docs/KID_MODE.md) ·
design notes and prototypes in [`docs/family/`](docs/family/notebook-design.html).

> **Not financial advice.** Trading and Explore are tools for your own research.
> Suggestions come from simple technical signals and whatever AI model you
> connect, and can be wrong. You decide, and you're responsible for, every trade.

## Privacy: what leaves your device

Notebook only connects to these services, and only when you use the feature that needs them:

- **Your AI provider**, for Agent and Trading research.
- **Web search for the agent**: DuckDuckGo, or Parallel if you add a key. The
  agent can also open pages it finds.
- **Yahoo Finance**, for quotes, charts and fundamentals.
- **Google News, Bing News and Hacker News**, for headlines.
- **Wikipedia, Nasdaq and ETF issuers' holdings pages**, for Explore's index lists.
- **Robinhood**, only if you connect it (read-only, official MCP) for real-time quotes.
- **The web page you save**, to read its title (Links).
- **Apple iCloud (CloudKit)**, only in builds you sign yourself with sync turned
  on. Records are end-to-end encrypted before upload.

There's no analytics or telemetry.

## Where your data is

On the Mac it's in `~/Library/Application Support/Notebook/notebook.sqlite`.
`scripts/backup-data.sh` makes a copy. Uninstalling the app leaves your data in
place.

## Build from source

You need a recent Xcode (built with Xcode 27) and, only for the JavaScript tests, Node 20 or later.

```sh
npm run start:macos          # build an unsigned Mac app and open it
npm run build:ios            # build for the iOS simulator
```

Or open `ios/Notebook.xcodeproj` in Xcode and run the **NotebookMac** or
**Notebook** scheme. Unsigned builds work fully, but without iCloud sync.

### iCloud sync (optional)

Sync needs a paid Apple Developer account and your own CloudKit container. Copy
`ios/Signing.local.xcconfig.example` to `ios/Signing.local.xcconfig` (it's
gitignored), fill in your team, bundle IDs and container, then follow
[iOS and sync setup](docs/IOS_SYNC.md) and
[Native Mac app → Sync](docs/NATIVE_MAC.md#sync-with-your-iphone).

### Tests

```sh
npm test                     # agent and finance JavaScript
npm run test:native          # NotebookCore: storage, conflicts, sync, document text
npm run test:ios             # iPhone UI tests in the simulator
```

### Release a Mac build

Releases are built on GitHub. Push a version tag and the
[Release workflow](.github/workflows/release.yml) builds the app, signs it with
a Developer ID, notarizes it and publishes the `.dmg` on the Releases page:

```sh
git tag v0.4.0 && git push origin v0.4.0
```

The tag sets the app's version. The workflow's comments list the repository
secrets it needs. To build the same signed `.dmg` locally, run
`npm run release:macos` (see the script for the notarization setup).

## Code

- `ios/Notebook`, `ios/NotebookMac`, `ios/Shared`: the iPhone/iPad and Mac apps.
- `native/`: the `NotebookCore` Swift package (SQLite store, encrypted CloudKit
  sync, document text recognition) used by both apps.
- `js/agent/`, `js/apps/portfolio/`: the agent's tools and provider protocol,
  and the finance calculations. Both apps run these in JavaScriptCore.

## Contributing

Issues and pull requests are welcome. Please run the tests before you open a pull request.

## License

[MIT](LICENSE)
