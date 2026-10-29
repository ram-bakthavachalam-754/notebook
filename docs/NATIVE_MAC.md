# Native Mac app

`ios/NotebookMac` is a native SwiftUI Mac app (macOS 14 or later) that replaced
the Electron app. It shares its models with the iPhone app and opens the same
database in the same place, `~/Library/Application Support/Notebook`, so your
notes, journal, finance records, chats and documents open as they are.

| Section | What it does |
| --- | --- |
| Notes (⌘1) | Searchable list with pinned notes first; title, tags, bold, italic, heading and lists; pin, delete, keep one version of a conflict. ⌘N for a new note. |
| Journal (⌘2) | Entries by month with mood and photo thumbnails; date, mood, tags, formatting and photos. ⇧⌘N for today's entry. |
| Finance (⌘3) | Accounts and the holdings in each: value, cash, today, total gain; sortable holdings; a page per ticker with its chart, accounts, transactions, key numbers (market cap, P/E, 52-week range, earnings, analysts), technicals, Trading alerts and watchlist, news and company profile (the same page opens from Trading); add and edit accounts and buys, sells or existing holdings. Prices refresh on their own while Finance is open: every 15 seconds in real time with Robinhood connected (Settings → Trading), otherwise from Yahoo Finance. |
| Trading (⌘4) | A budget (say $10,000), a watchlist and risk rules. Twice each trading day, at 9:45 a.m. and 3:30 p.m. Eastern (New York time whatever the Mac's time zone), it researches the watchlist, your Finance stocks and a market scan (Robinhood's scanner when connected, else Yahoo's movers): technical signals (trend, moving averages, RSI, MACD, breakouts on volume, Bollinger bands), the earnings date, two days of headlines and option chains. Your AI model turns the strongest setups into a plan: buy shares, a call or put, or a debit spread, with a stop, a target and an exit date. Notebook sizes it by your rules, within a limit on what everything open could lose together, and alerts you what to buy. Tell it when you buy, and while Notebook is open and unlocked it checks prices every five minutes in market hours and alerts you when to sell: at the stop, the target or the time limit. See [TRADING.md](TRADING.md). |
| Explore (⌘5) | Every company in the S&P 500 and the Nasdaq-100, plus five tech indexes (semiconductors, two cybersecurity, cloud software, FANG+), grouped by sector, industry and sub-industry. A heat map colored by the change over a day to a year, sized by market cap; click down to a sub-industry's stocks and their ticker pages. The lists are checked weekly; companies outside the S&P 500 are placed by your AI model, and you can move any company. See [EXPLORE.md](EXPLORE.md). |
| Links (⌘7) | Saved web links in collections. Paste or drop a link and Notebook adds the page's title; add a note and tags; move between collections. The agent can search and save links too. |
| Documents (⌘8) | Add files (⇧⌘O or drop), recognized text, preview, notes and tags. |
| Agent (⌘9) | Conversations, attachments (Attach or drop files), Allow edits, provider and key settings. |
| Settings (⌘,) | Lock with Touch ID or your Mac password, idle time, iCloud status and Connect iPhone. ⌘L locks. Family: your children's apps and rules (see [KID_MODE.md](KID_MODE.md)). Trading: budget, risk rules, alerts and the Robinhood connection. |

Opening a note never rewrites it: the editor keeps every bit of the stored
HTML until you type. New notes and entries are saved only once you type.

Links are a new kind of record. Update the iPhone app before saving links:
an iPhone build from before 19 October 2026 stops syncing when it receives a
kind of record it doesn't know.

## Not in the native app

Spending, strategies, properties and debts, snapshots, the Markdown copies in
`~/Notebook`, PDF export, note templates and book layout, and wiki links. Their
data is left untouched in the database. The Markdown files no longer update.

## Try it on a copy first

Back up (Notebook closed), then point the app at a copy of the backup:

```sh
scripts/backup-data.sh
npm run build:macos
mkdir -p /tmp/nbtest/userData
cp ~/Documents/Notebook\ Backups/<backup>/Application\ Support/notebook.sqlite /tmp/nbtest/userData/
open -n --env NOTEBOOK_DATA_ROOT=/tmp/nbtest build/mac/Build/Products/Debug/Notebook.app
```

Check that the Notes, Journal and Documents counts in the sidebar match the
"current" column of the backup summary. The "records ever" column also counts
deleted ones, so it's higher. Then open some older notes with formatting,
photos or tables, and try each section. Edits stay in the copy.

## Sync with your iPhone

An unsigned build keeps everything on the Mac and never contacts iCloud. To
sync, sign it with your developer team:

1. In the Apple Developer portal, register an App ID for the Mac app (for
   example `com.yourteam.notebook.mac`) with iCloud (your existing Notebook
   container) and Push Notifications.
2. Add to `ios/Signing.local.xcconfig`:
   ```
   NOTEBOOK_MAC_BUNDLE_ID = com.yourteam.notebook.mac
   NOTEBOOK_MAC_ENTITLEMENTS = NotebookMac/NotebookMac.entitlements
   ```
3. Run `npm run build:macos:signed` (the app is at
   `build/mac-signed/Build/Products/Debug/Notebook.app`), or open
   `ios/Notebook.xcodeproj`, choose the NotebookMac scheme and run.
   `npm run build:macos` always builds an unsigned copy, which shows
   "Not set up in this build" under iCloud.
4. To install it, run `npm run install:macos`: it builds the signed app,
   quits Notebook if it's open, copies it to `/Applications/Notebook.app` and
   opens it. `npm run install:macos -- --no-build` installs the last build.
   It won't replace a different app with that name (such as an old Electron
   Notebook); rename or remove that one first, or run with `FORCE=1`.

The first sync asks to use the "com.ram.notebook.sync.v1" Keychain item (the
notebook key the old Electron sync helper saved); choose Always Allow. The notebook
stays paired with your iPhone; no new pairing is needed.

## Saving links from Safari (iPhone)

The iPhone app includes a share extension: Share → Notebook saves the page to
Links (Unsorted), with an optional note. It's added the next time you open
Notebook. The extension and the app share a small inbox through an App
Group, so it works only in a build signed with one. Add to
`ios/Signing.local.xcconfig`:

```
NOTEBOOK_APP_GROUP = group.com.yourteam.notebook
CODE_SIGN_ENTITLEMENTS = Notebook/NotebookWithShare.entitlements
NOTEBOOK_SHARE_ENTITLEMENTS = NotebookShare/NotebookShare.entitlements
```

`NotebookWithShare.entitlements` is the usual iCloud entitlements plus the App
Group. With automatic signing, Xcode registers the group and the extension's
App ID (`<your app ID>.share`). Without these lines the extension still shows
in the share sheet but says saving isn't set up.

## News

News (Mac and iPhone) brings back nenva's News app: headlines on the
topics you follow, from Google News and Bing News (Hacker News can be added
in Topics). Headlines are quoted as published, never written by AI. Choose
topics in Topics: pick from the catalog or type any topic.

Opening a story reads the article on your device with the agent's safe web
reader, and your own model (Agent Settings) writes a detailed summary in
nenva's style (background, specifics, then Key points), labeled with the
model and what it was written from. Google News links are traded for the
publisher's address first, as nenva did. When an article can't be read
(paywalls, consent walls), the summary is written from other outlets'
coverage of the same headline instead, and says so. Without a model you get
the article's text.

Catch Me Up, at the top of Latest, has your model write a one-line digest
per topic from the headlines on screen, labeled as AI-written. It's dropped
when headlines refresh.

Headlines are fetched when News is open, at most every 30 minutes, and kept
only on this device (`news-cache.json`). Your topics, sources and saved
stories sync as the `news` record kind; update every device before using
News. Kids don't get News.

## Sharing

Share a note, a links collection or a Finance account with someone else who
uses Notebook (Mac and iPhone):

- **Notes**: the Share button in the note's toolbar. People you add can edit
  or only view. Their copy shows under Shared with You in Notes.
- **Links collections**: Share… on the collection (right-click on the Mac,
  press and hold on iPhone), or the Share button while it's open.
- **Finance accounts**: the Share button on the account. Always view only, at
  a level you pick: balance only, balance and holdings, or holdings and
  transactions. The other person sees it under Shared with You in Finance,
  valued with their own prices, and it never counts in their totals.

In the share sheet, type the email address of their Apple Account, choose Can
edit or View only, press Add Person, then use Send Invitation Link. When they
open the link, Notebook accepts it; if it opens somewhere else, they can paste
it in Settings → Sharing. Settings → Sharing also lists everything you've
shared and everything shared with you. Stop Sharing keeps the item in your
notebook and removes it for everyone else; deleting a shared note or
collection deletes it for everyone; Leave removes someone else's item from
yours.

How it's kept apart from your notebook: a shared item moves out of your
private notebook into its own iCloud zone (`Share-<id>`), its own local file
(`Shares/<id>.sqlite` next to `notebook.sqlite`) and its own key. Records in
the zone are encrypted with that key; the key travels in the zone in a
CloudKit encrypted field that only the people on the share can read. Your
notebook's key and its sync engine are never involved, and shared items sync
with plain CloudKit change fetches, separate from your notebook's sync.
CloudKit enforces View only.

Needs:

- Signed builds with iCloud on, for both people (like sync). An unsigned
  build shows Share but says it needs iCloud.
- `CKSharingSupported` is in both Info.plists. A Development build creates
  the `ShareKey`, `ShareInfo` and `NotebookChange` record types in the share
  zones on first use; deploy the schema to Production in the CloudKit Console
  before TestFlight.

Not tested with iCloud yet: everything above needs two signed builds on two
Apple Accounts. On this Mac the local side was tested without iCloud (a
DEBUG run, `--test-sharing <png>`): moving a note, a collection and an account
into a share and back, edits landing in the share, view-only items refusing
edits, account levels, and stop, delete and leave. Not built: the agent
reading shared items, notifications when something is shared with you (a
notice appears in the app instead), and family chips in the share sheet.
