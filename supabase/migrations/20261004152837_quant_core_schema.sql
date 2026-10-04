-- Quant Hedgefund core schema.
-- n8n talks to this database with the project's secret (service role) key, which bypasses RLS.
-- RLS is enabled with no policies so the anon/publishable key can read or write nothing.

-- One row per Telegram user of the bot.
create table public.bot_users (
  telegram_id bigint primary key,
  username text,
  hyperliquid_wallet text check (hyperliquid_wallet is null or hyperliquid_wallet ~ '^0x[0-9a-f]{40}$'),
  base_currency text not null default 'USD',
  risk_per_trade_pct numeric not null default 1.0 check (risk_per_trade_pct > 0 and risk_per_trade_pct <= 10),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Current holdings snapshot per source.
--   google_finance : stocks/ETFs mirrored from the Google Finance portfolio (CSV import)
--   invo           : open perp positions + USDC equity pulled from Hyperliquid (Invo executes there)
--   binance/manual : anything else
create table public.holdings (
  id bigint generated always as identity primary key,
  telegram_id bigint not null references public.bot_users (telegram_id) on delete cascade,
  source text not null check (source in ('google_finance', 'invo', 'binance', 'manual')),
  symbol text not null,
  asset_class text not null default 'stock'
    check (asset_class in ('stock', 'etf', 'crypto', 'crypto_perp', 'commodity', 'fx', 'bond', 'cash', 'other')),
  exchange text,
  quantity numeric not null, -- negative = short (perps)
  avg_cost numeric,
  currency text not null default 'USD',
  leverage numeric,
  liquidation_price numeric,
  unrealized_pnl numeric,
  updated_at timestamptz not null default now(),
  unique (telegram_id, source, symbol)
);

-- Historical executions. external_id makes re-imports idempotent
-- (Hyperliquid trade id, Binance trade id, or a deterministic hash for CSV rows).
create table public.trades (
  id bigint generated always as identity primary key,
  telegram_id bigint not null references public.bot_users (telegram_id) on delete cascade,
  source text not null check (source in ('invo', 'binance', 'google_finance', 'csv', 'manual')),
  external_id text not null,
  symbol text not null,
  side text not null check (side in ('buy', 'sell')),
  direction text, -- e.g. 'Open Long', 'Close Short'
  quantity numeric not null check (quantity > 0),
  price numeric not null check (price >= 0),
  notional numeric generated always as (quantity * price) stored,
  fee numeric not null default 0,
  fee_currency text,
  realized_pnl numeric,
  executed_at timestamptz not null,
  raw jsonb,
  inserted_at timestamptz not null default now(),
  unique (telegram_id, source, external_id)
);

create index trades_user_time_idx on public.trades (telegram_id, executed_at desc);
create index trades_user_symbol_idx on public.trades (telegram_id, symbol);

-- The analyst "skill framework": prompt modules the n8n agent loads at runtime.
-- Edit a row's body in the Supabase table editor to change the bot's behaviour without touching n8n.
create table public.agent_skills (
  slug text primary key, -- core | chart | market | news | portfolio | house_rules
  title text not null,
  body text not null,
  enabled boolean not null default true,
  version integer not null default 1,
  updated_at timestamptz not null default now()
);

-- Journal of every AI call, so recommendations can be reviewed against what happened next.
create table public.analysis_log (
  id bigint generated always as identity primary key,
  telegram_id bigint not null,
  mode text not null check (mode in ('chart', 'market', 'news', 'analyze', 'ask')),
  symbol text,
  request text,
  response text not null,
  bias text,
  action text,
  created_at timestamptz not null default now()
);

create index analysis_log_user_time_idx on public.analysis_log (telegram_id, created_at desc);

alter table public.bot_users enable row level security;
alter table public.holdings enable row level security;
alter table public.trades enable row level security;
alter table public.agent_skills enable row level security;
alter table public.analysis_log enable row level security;

-- Open positions only, with cost basis.
create view public.v_portfolio with (security_invoker = true) as
select
  h.telegram_id,
  h.source,
  h.symbol,
  h.asset_class,
  h.exchange,
  h.quantity,
  h.avg_cost,
  h.quantity * h.avg_cost as cost_basis,
  h.currency,
  h.leverage,
  h.liquidation_price,
  h.unrealized_pnl,
  h.updated_at
from public.holdings h
where h.quantity <> 0;

-- What /sync needs: the wallet and the newest Hyperliquid fill already stored (epoch ms).
create view public.v_sync_state with (security_invoker = true) as
select
  u.telegram_id,
  u.hyperliquid_wallet,
  coalesce(
    (select (extract(epoch from max(t.executed_at)) * 1000)::bigint
     from public.trades t
     where t.telegram_id = u.telegram_id and t.source = 'invo'),
    0
  ) as last_fill_ms
from public.bot_users u;

-- Upsert a batch of holdings for one source. With p_replace, symbols missing from the batch are
-- deleted (used for Hyperliquid positions, where the batch is the complete current state).
create function public.upsert_holdings(
  p_telegram_id bigint,
  p_username text,
  p_source text,
  p_rows jsonb,
  p_replace boolean default false
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_upserted integer;
  v_deleted integer := 0;
begin
  insert into public.bot_users (telegram_id, username)
  values (p_telegram_id, nullif(p_username, ''))
  on conflict (telegram_id) do update
    set username = coalesce(excluded.username, public.bot_users.username), updated_at = now();

  if p_replace then
    delete from public.holdings h
    where h.telegram_id = p_telegram_id
      and h.source = p_source
      and h.symbol not in (
        select upper(trim(r ->> 'symbol')) from jsonb_array_elements(p_rows) r
        where nullif(trim(r ->> 'symbol'), '') is not null
      );
    get diagnostics v_deleted = row_count;
  end if;

  insert into public.holdings (
    telegram_id, source, symbol, asset_class, exchange, quantity, avg_cost, currency,
    leverage, liquidation_price, unrealized_pnl, updated_at
  )
  select distinct on (upper(trim(r ->> 'symbol')))
    p_telegram_id,
    p_source,
    upper(trim(r ->> 'symbol')),
    coalesce(nullif(r ->> 'asset_class', ''), 'stock'),
    nullif(r ->> 'exchange', ''),
    (r ->> 'quantity')::numeric,
    nullif(r ->> 'avg_cost', '')::numeric,
    coalesce(nullif(upper(r ->> 'currency'), ''), 'USD'),
    nullif(r ->> 'leverage', '')::numeric,
    nullif(r ->> 'liquidation_price', '')::numeric,
    nullif(r ->> 'unrealized_pnl', '')::numeric,
    now()
  from jsonb_array_elements(p_rows) r
  where nullif(trim(r ->> 'symbol'), '') is not null
    and nullif(r ->> 'quantity', '') is not null
  on conflict (telegram_id, source, symbol) do update set
    asset_class = excluded.asset_class,
    exchange = coalesce(excluded.exchange, public.holdings.exchange),
    quantity = excluded.quantity,
    avg_cost = coalesce(excluded.avg_cost, public.holdings.avg_cost),
    currency = excluded.currency,
    leverage = excluded.leverage,
    liquidation_price = excluded.liquidation_price,
    unrealized_pnl = excluded.unrealized_pnl,
    updated_at = now();
  get diagnostics v_upserted = row_count;

  return jsonb_build_object('upserted', v_upserted, 'deleted', v_deleted);
end;
$$;

-- Insert executions, skipping any already stored (same source + external_id).
create function public.ingest_trades(
  p_telegram_id bigint,
  p_username text,
  p_source text,
  p_rows jsonb
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_inserted integer;
begin
  insert into public.bot_users (telegram_id, username)
  values (p_telegram_id, nullif(p_username, ''))
  on conflict (telegram_id) do update
    set username = coalesce(excluded.username, public.bot_users.username), updated_at = now();

  insert into public.trades (
    telegram_id, source, external_id, symbol, side, direction, quantity, price, fee,
    fee_currency, realized_pnl, executed_at, raw
  )
  select distinct on (r ->> 'external_id')
    p_telegram_id,
    p_source,
    r ->> 'external_id',
    upper(trim(r ->> 'symbol')),
    lower(r ->> 'side'),
    nullif(r ->> 'direction', ''),
    abs((r ->> 'quantity')::numeric),
    (r ->> 'price')::numeric,
    coalesce(nullif(r ->> 'fee', '')::numeric, 0),
    nullif(r ->> 'fee_currency', ''),
    nullif(r ->> 'realized_pnl', '')::numeric,
    (r ->> 'executed_at')::timestamptz,
    r -> 'raw'
  from jsonb_array_elements(p_rows) r
  where nullif(r ->> 'external_id', '') is not null
    and lower(r ->> 'side') in ('buy', 'sell')
    and nullif(r ->> 'quantity', '')::numeric <> 0
  on conflict (telegram_id, source, external_id) do nothing;
  get diagnostics v_inserted = row_count;

  return jsonb_build_object('inserted', v_inserted, 'received', jsonb_array_length(p_rows));
end;
$$;

-- Store the public Hyperliquid address that Invo trades from (never a private key).
create function public.set_hyperliquid_wallet(
  p_telegram_id bigint,
  p_username text,
  p_wallet text
) returns jsonb
language plpgsql
set search_path = ''
as $$
declare
  v_wallet text := lower(trim(p_wallet));
begin
  if v_wallet !~ '^0x[0-9a-f]{40}$' then
    raise exception 'That does not look like a wallet address. Send /wallet 0x followed by 40 hex characters.';
  end if;

  insert into public.bot_users (telegram_id, username, hyperliquid_wallet)
  values (p_telegram_id, nullif(p_username, ''), v_wallet)
  on conflict (telegram_id) do update
    set hyperliquid_wallet = excluded.hyperliquid_wallet,
        username = coalesce(excluded.username, public.bot_users.username),
        updated_at = now();

  return jsonb_build_object('wallet', v_wallet);
end;
$$;

revoke execute on function public.upsert_holdings(bigint, text, text, jsonb, boolean) from public, anon, authenticated;
revoke execute on function public.ingest_trades(bigint, text, text, jsonb) from public, anon, authenticated;
revoke execute on function public.set_hyperliquid_wallet(bigint, text, text) from public, anon, authenticated;
grant execute on function public.upsert_holdings(bigint, text, text, jsonb, boolean) to service_role;
grant execute on function public.ingest_trades(bigint, text, text, jsonb) to service_role;
grant execute on function public.set_hyperliquid_wallet(bigint, text, text) to service_role;
