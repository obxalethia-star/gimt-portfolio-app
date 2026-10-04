# Quant Hedgefund bot: setup

A Telegram bot, run by the n8n workflow **Quant Hedgefund**. It stores your portfolio in Supabase, pulls free market data, and asks a self-hosted LangChain server (Ollama on your Oracle VM) for a market read and a recommendation.

```
Telegram ─▶ n8n "Quant Hedgefund" ─┬─▶ Supabase (holdings, trades, skills, analysis log)
                                   ├─▶ free market data (Binance, Hyperliquid, Yahoo, Fear & Greed, CoinGecko, RSS)
                                   └─▶ LangChain server on the Oracle VM ─▶ Ollama (llama3.1:8b text, gemma3:4b vision)
```

| Path | What it is |
|---|---|
| `n8n/quant-hedgefund.workflow.json` | Export of the live workflow (57 nodes). Import it with *Workflows → Import from file*. |
| `supabase/migrations/` | Database schema, RPC functions and the agent skills |
| `langchain-server/` | LangServe app plus a one-shot Oracle VM installer |
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
2. **LangChain server.** On the Oracle VM:
   ```bash
   git clone <this repo> && cd gimt-portfolio-app/langchain-server
   bash setup_oracle_vm.sh   # uses sudo where needed
   ```
   The script installs Ollama, pulls the models, and starts the `qhf-langchain` systemd service on port 8000. It also prints an API key. Next, in OCI, add an ingress rule for TCP 8000 to the VM's subnet Security List (ideally only from your n8n server's IP).
3. **Point n8n at the server.**
   - On *Ask LangChain Analyst*, set the URL to `http://<VM public IP>:8000/analyst/invoke`.
   - Create a *Header Auth* credential named **QHF LangChain API key**, with Name `X-API-Key` and Value set to the key the script printed.
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

## VM sizing

The defaults assume the Oracle Always Free Ampere A1 shape (4 OCPU, 24 GB RAM, no GPU). On that shape:
- An 8B text model answers in roughly 1–3 minutes per persona, so `/analyze` sends a "working on it" message first and allows up to 10 minutes.
- The four personas share a prompt prefix, so Ollama can reuse the cached prefix between them.

On a smaller VM, set `TEXT_MODEL` in `/opt/qhf-langchain/.env` to a smaller model (e.g. `llama3.2:3b`) and restart the service.
