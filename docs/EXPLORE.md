# Explore

Explore (Mac, ⌘5) follows the leading stocks in every industry. It keeps a
master list of the companies in a few well-known indexes, groups them by
sector, industry and sub-industry, and shows how each group is doing on a heat
map. Kids' Notebooks don't have it.

## The lists

Pick a list at the top of the middle column:

| List | Companies | Members come from |
| --- | --- | --- |
| S&P 500 | ~500 | Wikipedia's "List of S&P 500 companies", which also gives each one's sector and sub-industry |
| Nasdaq-100 | ~100 | Nasdaq's list (api.nasdaq.com) |
| Semiconductors · SOXX | 30 | The PHLX Semiconductor index, from Nasdaq's index site |
| Cybersecurity · CIBR | ~42 | The Nasdaq CTA Cybersecurity index, from Nasdaq's index site |
| Cyber Security (ISE) · HACK | ~22 | Amplify's daily holdings file for HACK |
| Cloud Software · WCLD | ~64 | The BVP Nasdaq Emerging Cloud index, from Nasdaq's index site |
| FANG+ · FNGS | 10 | The FANG+ ETN's holdings page on stockanalysis.com |

- Explore checks the lists when first opened and then once a week, or when
  you press Refresh. Who joined or left a list shows on its page for 30 days.
- A source that can't be reached, or returns a list far too short, leaves that
  list as it was.
- Shares listed only abroad (Trend Micro, Thales) are left out. Index members
  are checked against US quotes by name as well as ticker, because a foreign
  ticker can belong to a different US company (Atos's ATO is Atmos Energy's
  in the US).
- Two share classes of one company count once (GOOGL with GOOG, FOXA with
  FOX, NWSA with NWS), so Alphabet isn't twice its size on the map.
- Left out: IGV (iShares doesn't let apps download its holdings), XLK (the
  same as S&P 500 › Information Technology) and the Nasdaq Composite (3,000+
  stocks).

## Sectors, industries and sub-industries

Groups follow the GICS standard: 11 sectors, 74 industries and 163
sub-industries, built into the app.

- **S&P 500 companies** are where S&P puts them.
- **Everyone else** (Cloudflare, Zscaler, ASML…) has no published group, so
  your AI model (Agent Settings) places each one once and the answer is saved.
  These show an **AI** badge. Without a model they wait under Unclassified.
- **You can move any company:** right-click it → Move to Another
  Sub-industry. Your choice wins over S&P's and your model's and shows
  **MOVED**.

Placements are "explore" records, so they sync to your other devices. The
lists, history and last prices are a cache file (`explore-cache.json`) beside
the database; deleting it only means Explore fetches them again.

## The pages

- **Heat map:** color is the change over the chosen period (1D, 1W, 1M, 3M,
  YTD, 1Y), full red or green at ±3% for a day up to ±40% for a year. Size is
  market cap, or Equal. The tech lists start at Equal, since a few giants
  (Microsoft is in Cybersecurity) would fill the map.
- **A group's change** is the market-cap-weighted average of its companies.
- **Levels:** All → sector → industry → sub-industry → ticker page. The S&P
  500 and Nasdaq-100 open on their sectors; the shorter tech lists open
  straight on their stocks.
- **Top 5** keeps the five largest companies in each sub-industry: the leaders.
- **Badges:** OWN for stocks you hold in Finance, WATCH for your Trading
  watchlist (right-click to add or remove).
- A stock opens the same ticker page as Finance and Trading.

## Prices

- **1D, price, market cap and volume:** Trading's quotes. Prices are
  Robinhood's live ones when it's connected (Settings → Trading), else
  Yahoo's; market cap and volume are always Yahoo's. They refresh every two
  minutes while Explore is open.
- **1W to 1Y:** a year of Yahoo daily closes for every company, fetched once a
  day (30 requests of 20 stocks) and measured against the live price.
