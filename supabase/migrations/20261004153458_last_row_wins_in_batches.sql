-- When a batch repeats a symbol (holdings) or external_id (trades), keep the last occurrence
-- instead of an arbitrary one.

create or replace function public.upsert_holdings(
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
  select distinct on (upper(trim(e.r ->> 'symbol')))
    p_telegram_id,
    p_source,
    upper(trim(e.r ->> 'symbol')),
    coalesce(nullif(e.r ->> 'asset_class', ''), 'stock'),
    nullif(e.r ->> 'exchange', ''),
    (e.r ->> 'quantity')::numeric,
    nullif(e.r ->> 'avg_cost', '')::numeric,
    coalesce(nullif(upper(e.r ->> 'currency'), ''), 'USD'),
    nullif(e.r ->> 'leverage', '')::numeric,
    nullif(e.r ->> 'liquidation_price', '')::numeric,
    nullif(e.r ->> 'unrealized_pnl', '')::numeric,
    now()
  from jsonb_array_elements(p_rows) with ordinality as e(r, n)
  where nullif(trim(e.r ->> 'symbol'), '') is not null
    and nullif(e.r ->> 'quantity', '') is not null
  order by upper(trim(e.r ->> 'symbol')), e.n desc
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

create or replace function public.ingest_trades(
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
  select distinct on (e.r ->> 'external_id')
    p_telegram_id,
    p_source,
    e.r ->> 'external_id',
    upper(trim(e.r ->> 'symbol')),
    lower(e.r ->> 'side'),
    nullif(e.r ->> 'direction', ''),
    abs((e.r ->> 'quantity')::numeric),
    (e.r ->> 'price')::numeric,
    coalesce(nullif(e.r ->> 'fee', '')::numeric, 0),
    nullif(e.r ->> 'fee_currency', ''),
    nullif(e.r ->> 'realized_pnl', '')::numeric,
    (e.r ->> 'executed_at')::timestamptz,
    e.r -> 'raw'
  from jsonb_array_elements(p_rows) with ordinality as e(r, n)
  where nullif(e.r ->> 'external_id', '') is not null
    and lower(e.r ->> 'side') in ('buy', 'sell')
    and nullif(e.r ->> 'quantity', '')::numeric <> 0
  order by e.r ->> 'external_id', e.n desc
  on conflict (telegram_id, source, external_id) do nothing;
  get diagnostics v_inserted = row_count;

  return jsonb_build_object('inserted', v_inserted, 'received', jsonb_array_length(p_rows));
end;
$$;
