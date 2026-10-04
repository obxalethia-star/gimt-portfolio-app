# Quant Hedgefund bot: setup

A Telegram bot, run by the n8n workflow **Quant Hedgefund**. It stores your portfolio in Supabase, pulls free market data, and asks a local LangChain server (Ollama on your own server, no per-use AI costs) for a market read and a recommendation.

```
Telegram ─▶ n8n "Quant Hedgefund" ─┬─▶ Supabase (holdings, trades, skills, analysis log)
                                   ├─▶ free market data (Binance, Hyperliquid, Yahoo, Fear & Greed, CoinGecko, RSS)
                                   └─▶ local LangChain server ─▶ Ollama (qhf-text and qhf-vision models)
```

| Path | What it is |
|---|---|
| `n8n/quant-hedgefund.workflow.json` | Export of the live workflow (57 nodes). Import it with *Workflows → Import from file*. |
| `supabase/migrations/` | Database schema, RPC functions and the agent skills |
| `langchain-server/` | LangServe app, plus `install_local_ai.sh` / `uninstall_local_ai.sh` for the local AI stack |
| `docs/skill-framework-sources.md` | Every rule in the agent skills, mapped to a book and page |

## Bot commands

| Command | What it does |
|---|---|
| Send a chart screenshot (caption optional, e.g. `BTC 4h`) | Chart read with the chart checklist |
| `/market [SYMBOL]` | Market overview and a call (default BTC; stocks too, e.g. `/market AAPL`, `/market NPN.JO`) |
| `/news [topic]` | News scan for your holdings or a topic |
| `/analyze` | Investor panel: Buffett, Dalio, Wood, Ackman |
| `/risk` | Risk report (no AI) |
| `/portfolio` | Show holdings |
| `/portfolio NASDAQ:AAPL:10@182.5, BTC:0.25` | Add or update holdings (quantity@average cost) |
| `/wallet 0x…` | Link your Invo/Hyperliquid wallet (public address only) |
| `/sync` | Import Invo trades and open positions from Hyperliquid |
| CSV with caption `/import google` | Replace stock holdings from a Google Finance export |
| CSV with caption `/import invo` or `/import binance` | Import trade history |
| Anything else | Goes to the analyst |

## Where the data comes from

- **Google Finance** has no API. Export your portfolio as CSV and send it with `/import google`, or type holdings with `/portfolio`.
- **Invo** executes on Hyperliquid. `/wallet` stores your Invo account's public address, and `/sync` reads fills and open positions from Hyperliquid's public API. Never send a private key or seed phrase; the bot only accepts a `0x…` address.
- **Crypto data** comes from the Binance public API (prices) and Hyperliquid (funding, open interest, crowding), both free and keyless. CoinGlass and Glassnode aren't needed.

## Setup checklist

1. **Supabase credential.** In n8n, create a *Supabase API* credential:
   - Host: `https://hgjzvddoyqyegygatiyd.supabase.co`
   - Service Role Secret: the project's secret key (*Project Settings → API Keys*)

   Select it on the Supabase nodes (*Load Skills*, *Load Holdings*, *Load Sync State*, *Load Recent Trades*, *Log Analysis*) and on the *Save…* HTTP Request nodes.
2. **Local AI (Ollama + LangChain).** On the server that runs n8n:
   ```bash
   git clone -b claude/charming-gauss-w6usma https://github.com/obxalethia-star/gimt-portfolio-app.git
   cd gimt-portfolio-app/langchain-server
   bash install_local_ai.sh   # uses sudo where needed
   ```
   The installer leaves n8n alone: no restart, no change to its containers, config or firewall. It:
   - runs Ollama and the LangServe API in their own Docker containers (or, without Docker, as systemd services);
   - caps them at all but one CPU core and about 70% of RAM, at lower priority than n8n, so the kernel stops them first if memory runs out;
   - listens only on the server itself (and, if n8n runs in Docker, on n8n's Docker network), so nothing is exposed to the internet;
   - picks models that fit your RAM, downloads them, and checks that n8n can reach them.

   At the end it prints the exact URLs and the API key for the next step. To remove it: `bash uninstall_local_ai.sh` (`--purge` also deletes the models).
3. **Point n8n at the AI.** Use the values the installer prints:
   - On *Ask LangChain Analyst*, set the URL (usually `http://qhf-langchain:8000/analyst/invoke`).
   - Create a *Header Auth* credential named **QHF LangChain API key**, with Name `X-API-Key` and the printed key as Value.
   - Optional, for any other workflow: create an *Ollama* credential with the printed Base URL (usually `http://qhf-ollama:11434`), then use the built-in Ollama Chat Model node with model `qhf-text` (or `qhf-vision` for images).
4. **Lock the bot to yourself.** On *Telegram Trigger*, set *Restrict to Chat IDs* to your chat ID.
5. **Activate** the workflow.

## Agent skills

Every prompt lives in the Supabase table `agent_skills`, so you can edit a prompt without changing the workflow:

| Rows | Role |
|---|---|
| `core` | Evidence rules and output format |
| `chart`, `market`, `news`, `portfolio` | One checklist per mode |
| `house_rules` | Rules from your books |
| `persona_*` | Investor panel used by `/analyze` |

`docs/skill-framework-sources.md` lists the book and page behind each rule.

`20261004163000_textbook_aligned_skills.sql` updates the existing skill rows. It needs your confirmation before it runs, so it is not applied yet. To apply it, either:
- run `supabase db push` from this repo, or
- paste the file into the Supabase SQL editor.

## Server sizing

The installer sizes everything from the server's CPU and RAM. n8n and the OS always keep at least one core and 3 GB or 30% of RAM, whichever is larger.

| AI share of RAM | Text model | Models loaded at once |
|---|---|---|
| 12 GB or more | llama3.1:8b | 2 (text and vision) |
| 7–12 GB | llama3.1:8b | 1 |
| 5–7 GB | llama3.2:3b | 1 |
| under 5 GB | not installed (the server is too small) | – |

Charts always use `gemma3:4b`. The installer stops if Docker's disk has less than about 20 GB free (12 GB without Docker).

On the Oracle Always Free Ampere A1 shape (4 OCPU, 24 GB, no GPU), the AI gets 3 cores and about 17 GB. An 8B model then answers in roughly 1–3 minutes per persona, so `/analyze` sends a "working on it" message first and allows up to 10 minutes.

To choose other models, re-run the installer with overrides, e.g. `TEXT_BASE_MODEL=qwen2.5:7b bash install_local_ai.sh`. It keeps the API key and the models already downloaded.
