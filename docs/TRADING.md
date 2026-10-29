# Trading

Trading (Mac, ⌘4) alerts you what to buy, for a budget you set aside, and
then when to sell what you bought. You place the trades yourself, at your
broker, and tell Notebook what you bought.

Not investment advice: the ideas come from rules and your AI model, and both
can be wrong. Options can lose everything paid for them.

## Each trading day

Twice each trading day, or when you press Research Now:

- **9:45 a.m. Eastern:** 15 minutes after the open, when option quotes are live.
- **3:30 p.m. Eastern:** 30 minutes before the close, when the day's price bar
  is nearly final, so signals that formed during the day are reliable and you
  can still act before the close.

The times are New York time whatever your Mac's time zone, and they follow
daylight saving (6:45 a.m. and 12:30 p.m. in California). The overview shows
them in your time. A run missed while the Mac was off or locked happens when
Notebook is next open, if the market is still open.


1. **Stocks to look at:** your watchlist, the stocks you hold in Finance and,
   with "Also scan the market" on, a market scan. All scans cover US stocks
   (no ETFs) worth at least $2 billion and priced at $5 or more.
   - **With Robinhood connected,** Robinhood's scanner runs four screens live,
     without saving anything to your account. Changes count the regular
     session only, and the 10 strongest from each screen are kept:
     - up 4% or more on at least 1.5× normal volume
     - down 4% or more on at least 1.5× normal volume
     - 3× normal volume or more
     - RSI under 35 while above the 200-day average (oversold in an uptrend)
   - **Otherwise,** Yahoo's most active, gainers and losers lists.

   Each alert's plan shows how the stock was found, and the AI model is told too.
   - **Too small to trade:** research skips any stock, including ones on your
     watchlist or in Finance, that trades fewer than 1 million shares a day
     (its 20-day average) or is worth less than $2 billion. Change both in
     Settings → Trading; Last research says why each one was skipped. A
     market cap Yahoo doesn't give doesn't count against a stock.
2. **Signals:** a year of daily prices for each stock. Rules score them:
   trend (price and the 50- and 200-day averages), golden and death crosses,
   MACD crosses, RSI oversold, recovering or overbought, breakouts and
   breakdowns through the 20-day range on heavy volume, pullbacks to the 20-day
   average in an uptrend, and Bollinger bands. A score of +2 or more is bullish
   and −2 or less is bearish. Bearish setups count only when options are on.
3. **A closer look** at the strongest (up to eight a run, strongest first): the next
   earnings date, two days of headlines from Google News, and an
   option chain three to ten weeks out (after earnings when possible). It then
   picks the contract nearest the money and a debit spread to the target.
   Contracts need open interest of at least 50 and a bid/ask spread under a
   quarter of the price.
4. **The decision:** your AI model (Agent Settings) gets the numbers, the
   headlines and the trades that fit your rules. It chooses one trade or
   passes, and sets the stop, the target and how long to hold. Without a model,
   only setups scoring ±3 become ideas, with default levels.
5. **Sizing:** Notebook sizes the trade from your rules, never the model.
   - **Stocks:** lose at most "risk per stock trade" (1% of $10,000 = $100) if
     the stop is hit. Spend at most "largest stock position" (20%).
   - **Options:** spend at most "most per option trade" (5%). That is the most
     the trade can lose.
   - **Defaults:** the stop is 2 ATRs from the price and the target 3 ATRs.
     The model's levels are used only when they're on the right side, within
     5 ATRs, and the reward is at least the risk.

Only defined-risk trades are suggested: buying shares, calls and puts, and
call or put debit spreads. Bearish ideas are always puts or put spreads, never
short stock.

The money available for sizing is the budget, plus what your sold trades
made or lost, less what your open trades and waiting alerts cost.

**Total risk at once** (10% by default, so $1,000 of $10,000) caps what
everything you hold and every waiting alert could lose together. Shares
count the loss to their stop; options count everything paid. New alerts are
sized to fit what's left, and when nothing is left, research says so and
waits until you skip or sell something. There is no daily limit on alerts.

## Alerts

1. **Buy:** each new idea is a notification ("Buy 20 NVDA shares at about
   $182") and goes under To Buy, with the plan and the reasons. Buy at your
   broker if it still looks right, then choose I Bought This… with the
   quantity and price you got. Or choose Skip.
2. **Sell:** while the market is open, Notebook checks prices every five
   minutes. When something you bought reaches its stop, its target or its exit
   date, you get a "Sell" notification. Options are due out four days before
   they expire. When you've sold, choose I Sold This… with the price.
3. **Ending:** an alert you haven't acted on ends when the stock reaches the
   stop or target first, or after two trading days, since its price and plan
   go stale. It moves to Past Alerts; I Bought It Anyway… still works there.

Alerts need Notebook running and unlocked on the Mac. Closing the window
keeps it running; locking (idle, sleep, ⌘L) pauses alerts until you unlock.

The overview shows how many alerts are waiting, your profit on trades you
logged (sold and still open), how many sold trades made money, and how much
of the budget is free.

The watchlist shows each stock's volume today and its three-month average,
and an alert shows the stock's 20-day average volume and market cap.

## Ticker pages

Click a watchlist stock, a ticker in Last research, or About on an alert to
open its ticker page. It's the same page Finance opens from a holding, and it
shows the following:

- **Price:** the live price and chart.
- **Your position:** what you own, from Finance.
- **Key numbers:** market cap, P/E, the 52-week range, dividend yield, the
  next earnings date and the analysts' consensus and target (from Yahoo).
- **Technicals:** the same indicators and signal score research uses, and
  today's volume against the 20-day average.
- **Trading:** this stock's alerts, and a button to add it to or remove it
  from the watchlist.
- **News:** the latest headlines. Each opens in the News reader with your
  model's summary, as do the headlines on an alert.

## Market data

**Robinhood (recommended).** In Settings → Trading (⌘, or the sliders button in Trading), choose
Connect Robinhood…. The sign-in page opens in your browser on that Mac; log in
and approve Notebook. It uses Robinhood's official Trading MCP server
(`agent.robinhood.com/mcp/trading`). Sign-in is OAuth with PKCE, with the
reply caught on `127.0.0.1`, so Notebook never sees your password. The tokens
stay in that Mac's keychain and refresh on their own.

Notebook only reads from Robinhood. It can call only the read-only tools
listed in `RobinhoodLink.readOnly`, never an order tool. With Robinhood
connected, these come from Robinhood, for Trading and for Finance:

- **Stock quotes:** real time, regular session only (`get_equity_quotes`),
  all symbols in one call. Finance refreshes them every 15 seconds while it's
  open.
- **Price history:** daily bars for about 13 months (`get_equity_historicals`).
- **Option chains:** the expirations and contracts (`get_option_chains`,
  `get_option_instruments`).
- **Option quotes:** live bid and ask, open interest, implied volatility and
  delta (`get_option_quotes`), in bulk. Finance looks up each option
  holding's Robinhood id once and remembers it on that Mac. Ideas save each contract's Robinhood id, so
  open trades are priced live too.

Copy Diagnostics puts sample answers from these tools on the clipboard, along
with what Notebook read from them, including what the market scan found.

- **Market scan:** Robinhood's scanner (`preview_scan`), as described under
  "Each trading day".

**Yahoo Finance** (no account) supplies company names, earnings dates, key
numbers and analyst ratings. It also fills in anything Robinhood doesn't answer, and
everything when Robinhood isn't connected.

- **Stock quotes:** near real time.
- **Option quotes:** usually about 15 minutes delayed, without Greeks.
- **Reliability:** these are unofficial endpoints that Yahoo can change or
  rate-limit.

## Data

Settings, the watchlist and alerts (with the trades you logged) are
"trading" records in the notebook database, and they sync through iCloud.
iPhone builds from 19 October 2026 or later keep them unread until they get a
Trading screen. The last research notes and prices stay on the Mac, in
`trading-cache.json`.

## The agent

The agent (Agent, on the Mac and iPhone) can read all of this: the overview,
every alert and logged trade, ticker pages and research notes. With
Allow edits on, it can change the watchlist and settings, log buys and sells,
skip or delete alerts, and run research when you ask. See
[the agent's Trading tools](AI_AGENT.md#trading).

## Code

- `native/Sources/NotebookCore/TradingMath.swift`: indicators, signal rules,
  levels and sizing, tested in `TradingMathTests`.
- `ios/Notebook/TradingModel.swift`: research, alerts, your trades,
  watching, notifications and Yahoo Finance.
- `ios/Notebook/RobinhoodLink.swift`: Robinhood sign-in and the read-only
  MCP client.
- `ios/NotebookMac/TradingViews.swift`: the screens.
- `ios/NotebookMac/TickerViews.swift`: the ticker page Finance and Trading share.
- `--test-trading <dir>` (DEBUG Mac build) runs a real research pass, prints
  the ideas and draws the screens to images. Point it at a test copy with
  `NOTEBOOK_DATA_ROOT`.
