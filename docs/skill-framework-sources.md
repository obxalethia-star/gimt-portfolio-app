# Skill framework sources

The analyst's skills live in `public.agent_skills` (see `supabase/migrations/`). This document maps every rule in those skills to the book it comes from, so you can check or change it.

Page numbers (`p.`) are positions in your own PDF/EPUB files, not the printed page numbers. Front matter shifts them, so the printed number on that page may differ by up to ~20.

## Library

| Tag in skills | Book | Your file |
|---|---|---|
| Graham | Benjamin Graham, *The Intelligent Investor* (revised edition, commentary by Jason Zweig) | THEINV~1.EPU / The Intelligent Investor |
| Finding Alphas | Igor Tulchinsky et al., *Finding Alphas* (2nd ed.) | Finding Alphas |
| Miller | Frank Miller, *Crypto Master* (2021) | Miller Crypto Master |
| Richmond | *The Crypto Crash Course* (2018) | The Crypto Crash Course |
| Achelis | Steven B. Achelis, *Technical Analysis From A to Z* (2nd ed., 2001) | TECHNI~1.PDF (probably) |
| Hale | Brian Hale, *The Only Technical Analysis Book You Will Ever Need* (2023) | book set upload |
| Roncalli | Thierry Roncalli, *Handbook of Financial Risk Management* | book set upload |
| Mandelbrot | Benoit Mandelbrot & Richard Hudson, *The (Mis)Behaviour of Markets* (2004) | book set upload |
| Patterson | Scott Patterson, *The Quants* (2010) | THEQUA~1.PDF |
| Hilpisch | Yves Hilpisch, *Python for Algorithmic Trading* (2021) | book set upload |
| Bell | Steve Bell, *Quantitative Finance For Dummies* (2016) | book set upload |
| Romero & Balch | Philip Romero & Tucker Balch, *Hedge Fund Secrets: An Introduction to Quantitative Portfolio Management* (2018) | book set upload |
| Pignataro | Paul Pignataro, *Financial Modeling and Valuation* | book set upload |
| Moschella | John Moschella, *Financial Modeling for Equity Research* (3rd ed., 2019) | book set upload |

Book Set 4 arrived empty. `ALTERN~1.PDF` and `PRACTI~1.PDF` from your folder did not clearly match any uploaded book, so neither is cited.

## Core rules (every reply)

| Rule | Source |
|---|---|
| Investment vs speculation: an investment, after thorough analysis, promises safety of principal and an adequate return | Graham p.29 |
| Keep speculation in a separate "mad money" account, never more than 10% of assets | Graham p.53 |
| Keep risky assets like Bitcoin to about 10% of the portfolio | Miller p.68 |
| Mr. Market: prices are offers, not verdicts on value | Graham p.182 |
| Plan setup, trigger and exit before entry | Miller pp.153–163; Hale p.128 ("Stick to your trading plan") |
| A repackaged indicator is not a second confirmation | Achelis (Dorsey's Relative Volatility Index entry) |
| A signal needs an economic rationale and must survive costs and turnover | Finding Alphas p.289 (rationale), ch. 7 *Turnover* |
| Risk at most 1% per crypto trade and 2% per traditional-market trade | Miller pp.401–402 |
| Reward:risk at least 1:2, ideally 1:3 | Miller p.225; Hale p.128 (ideally above 1:2) |
| Stop about 2× ATR, then trail it | Miller pp.362–372; Hale pp.51–53 (ATR) |
| Never size above half-Kelly | Hilpisch p.297; Kelly and Thorp in Patterson pp.26–40 |
| Prices leap rather than glide, so VaR is a floor and gaps skip stops | Mandelbrot, "Ten Heresies" (ch. XII); Bell p.137 (fat tails) |

## Chart snapshot

| Rule | Source |
|---|---|
| Trends and levels differ across timeframes | Hale pp.67–69 |
| Dow Theory swing structure | Achelis pp.144–146 |
| Broken resistance becomes support | Miller p.196 |
| Fibonacci 38.2 / 50 / 61.8% retracements | Hale pp.40–41; Miller p.324 |
| Head-and-shoulders volume on the neckline break | Hale p.103 |
| Rising volume and OI confirm the trend; both falling warns it may end | Achelis p.253 (*Open Interest*) |
| Don't chase hype; trade the plan, not the emotion | Graham pp.27–28, 44; Hale pp.6, 128 |

## Market overview

| Rule | Source |
|---|---|
| Volatility clusters | Bell p.146 (GARCH); Mandelbrot p.2 |
| Crowded, leveraged trades unwind together | Patterson (August 2007 quant crash, pp.16, 39, 52) |
| BTC dominance and alt rotation | Miller p.183 |
| Open interest is a snapshot in the bot's data, so the OI-trend rule only applies to charts that show OI | design note; see Achelis above |

## News scan

| Rule | Source |
|---|---|
| Value change vs mood change | Graham p.182 (Mr. Market) |
| Prices drift on after good news and recover about half of a bad-news drop | Romero & Balch pp.72–73 (event studies) |
| "If it looks too good to be true, it almost always is" | Richmond p.96 |
| Regulation is a live risk for crypto | Richmond pp.35–36 |

## Portfolio review and risk

| Rule | Source |
|---|---|
| Some advisers cap a single position at 5%; diversification beyond 20–40 names adds little | Romero & Balch p.55 |
| Correlations are unstable; balance risk across asset classes (risk parity) | Bell pp.287–288 |
| Historical VaR / expected shortfall | Roncalli p.22 and pp.101–104 |
| Euler risk contributions (the bot's `risk_contribution_pct`) | Roncalli p.140 (§2.3.1) |
| Model risk | Roncalli §2.2.5.4 |
| Drawdown and Sortino ratio | Romero & Balch pp.21–22 |
| Win rate of 40–60% is normal | Miller pp.153–163 |
| Signs a strategy has stopped working | Finding Alphas ch. 3 *Cutting Losses* (pp.36–40) |
| Data snooping and overfitting | Hilpisch pp.131–133; Finding Alphas ch. 9 |
| Leverage: at 20:1 the margin is 5%, so a 5% adverse move wipes it out | Hilpisch p.255; Hale pp.128–129 (margin close-out) |
| Stocks between 25% and 75% of the defensive portfolio; rebalance | Graham p.36; Zweig p.102 |
| Dollar-cost averaging | Graham p.37 |

## Valuation (personas and house rules)

| Rule | Source |
|---|---|
| Three core methods: comparable companies, precedent transactions, DCF | Pignataro p.306 |
| DCF on unlevered free cash flow at the WACC | Pignataro pp.308–322 |
| The terminal value is usually most of a DCF | Pignataro p.309 |
| Target price band from multiples, DCF and a risk estimate | Moschella p.18 |
| Seven defensive-investor tests | Graham p.287, detail pp.294–295 |
| P/E × P/B no higher than 22.5 | Graham p.295 |
| Margin of safety | Graham ch. 20 (p.509) |
| Moat | Zweig in Graham pp.258–259 |
| Coin checklist: team, purpose, progress, cost | Richmond pp.81–82 |
| Read the white paper | Richmond p.100; Miller p.51 |
| Cold wallet for long-term coins | Richmond pp.83–90 |

## Investor panel coverage

| Persona | Coverage in your books | What the lens is built from |
|---|---|---|
| Warren Buffett | Graham (Zweig's commentary on Buffett, moat), Romero & Balch p.32 (great business at a fair price), Patterson, Mandelbrot | Graham's rules plus the valuation books |
| Ray Dalio | Romero & Balch bio pp.69–70 (global macro; "the consensus is often wrong"; learn from mistakes); Bell pp.287–288 (risk parity) | Risk parity, growth/inflation regimes, Patterson on leverage |
| Cathie Wood | Not in any of your books | Her public innovation-platform style, plus Richmond and Miller for crypto due diligence and Mandelbrot for tail risk |
| Bill Ackman | Not in any of your books | His public concentrated-activist style, plus Graham's enterprising investor, Pignataro/Moschella valuation and Romero & Balch event studies |

Every persona is told not to invent quotes, trades or current opinions for the real person.

## House limits (not from the books)

These are defaults set for this bot. Change them in the skill text if you prefer other numbers.

- Flag a single position above 20% or an asset class above 60%.
- Total open risk at most 6%.
- Flag perps within 15% of liquidation.

## Corrections from the first version

- "Only risk money you can afford to lose" is Hale ("Risk only what you're prepared to lose", p.128), not Richmond.
- The line "crypto can fall 50–80%" was not in any of the books, so it was removed.
- "Signals decay" was reworded. Finding Alphas uses "decay" for signal smoothing; the rule now uses its quality traits and its "strategy stopped working" signals.
- Position size now follows Miller: 1% per crypto trade, 2% per traditional-market trade (previously a blanket 1–2%).
- The open-interest rule now follows Achelis (volume with OI). The bot's market data has only an OI snapshot, so the skill no longer claims an OI trend from it.
- The no-chasing (FOMO) check is now sourced to Graham and Hale. Neither crypto guide uses the term.
- Added: Fibonacci levels, 2× ATR stops, half-Kelly, fat tails and volatility clustering, crowding, Euler risk contributions, event-study drift, the coin checklist, and DCF/comps inputs for the valuation personas.
