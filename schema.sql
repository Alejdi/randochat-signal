-- Run this in the Supabase SQL editor. Safe to re-run (idempotent).

-- ========== MODERATION TABLES ==========

create table if not exists public.reports (
  id           bigint generated always as identity primary key,
  reporter_sid text   not null,
  reported_sid text   not null,
  reason       text,
  created_at   timestamptz not null default now()
);

create table if not exists public.events (
  id          bigint generated always as identity primary key,
  session_id  text   not null,
  type        text   not null,
  country     text,
  duration_ms integer,
  data        jsonb,
  created_at  timestamptz not null default now()
);

create table if not exists public.bans (
  id         bigint generated always as identity primary key,
  ip         text not null,
  reason     text,
  banned_by  text,
  banned_at  timestamptz not null default now(),
  expires_at timestamptz,
  active     boolean     not null default true
);

-- ========== ECONOMY TABLES ==========

-- Persistent user identity keyed by a device UUID the client stores in
-- localStorage. No auth yet; Phase 2 will migrate to Supabase Auth.
create table if not exists public.users (
  id            bigint generated always as identity primary key,
  device_id     text   not null unique,
  username      text,
  balance_cents bigint not null default 0 check (balance_cents >= 0),
  created_at    timestamptz not null default now(),
  last_seen_at  timestamptz not null default now()
);

-- Every gift is immutable. sender loses amount_cents, receiver gains
-- receiver_cut_cents (70%), platform gets platform_cut_cents (30%).
create table if not exists public.gifts (
  id                 bigint generated always as identity primary key,
  sender_id          bigint not null references public.users(id),
  receiver_id        bigint not null references public.users(id),
  gift_type          text   not null,
  amount_cents       bigint not null,
  receiver_cut_cents bigint not null,
  platform_cut_cents bigint not null,
  created_at         timestamptz not null default now()
);

-- Append-only ledger of every coin movement for any user.
create table if not exists public.ledger (
  id            bigint generated always as identity primary key,
  user_id       bigint not null references public.users(id),
  kind          text   not null,  -- topup | gift_sent | gift_received | cashout | refund
  delta_cents   bigint not null,
  balance_after bigint not null,
  ref_id        bigint,
  note          text,
  created_at    timestamptz not null default now()
);

-- ========== ADDITIVE MIGRATIONS ==========

alter table public.reports add column if not exists reported_ip       text;
alter table public.reports add column if not exists reported_username text;
alter table public.events  add column if not exists ip       text;
alter table public.events  add column if not exists username text;

-- ========== INDEXES ==========

create index if not exists reports_created_at_idx  on public.reports (created_at desc);
create index if not exists reports_reported_ip_idx on public.reports (reported_ip);

create index if not exists events_created_at_idx on public.events (created_at desc);
create index if not exists events_type_idx       on public.events (type);
create index if not exists events_session_idx    on public.events (session_id);
create index if not exists events_ip_idx         on public.events (ip);

create unique index if not exists bans_active_ip_idx  on public.bans (ip) where active = true;
create index        if not exists bans_created_at_idx on public.bans (banned_at desc);

create index if not exists gifts_sender_idx     on public.gifts (sender_id);
create index if not exists gifts_receiver_idx   on public.gifts (receiver_id);
create index if not exists gifts_created_at_idx on public.gifts (created_at desc);

create index if not exists ledger_user_idx    on public.ledger (user_id, created_at desc);
create index if not exists ledger_kind_idx    on public.ledger (kind);

-- ========== RLS (service role bypasses all of this) ==========

alter table public.reports enable row level security;
alter table public.events  enable row level security;
alter table public.bans    enable row level security;
alter table public.users   enable row level security;
alter table public.gifts   enable row level security;
alter table public.ledger  enable row level security;

-- ========== RPC: ensure user exists (upsert-on-connect) ==========

create or replace function public.ensure_user(
  p_device   text,
  p_username text
) returns jsonb
language plpgsql
security definer
as $$
declare
  v_id      bigint;
  v_balance bigint;
begin
  if p_device is null or length(p_device) < 8 then
    raise exception 'invalid device id';
  end if;

  insert into public.users (device_id, username, balance_cents)
  values (p_device, p_username, 100)  -- 100 coin bootstrap so users can try gifting
  on conflict (device_id) do update
    set username     = coalesce(excluded.username, public.users.username),
        last_seen_at = now()
  returning id, balance_cents into v_id, v_balance;

  return jsonb_build_object('id', v_id, 'balance_cents', v_balance);
end;
$$;

-- ========== RPC: atomic gift transaction ==========

create or replace function public.send_gift(
  p_sender_device   text,
  p_receiver_device text,
  p_gift_type       text,
  p_amount_cents    integer
) returns jsonb
language plpgsql
security definer
as $$
declare
  v_sender_id             bigint;
  v_receiver_id           bigint;
  v_sender_balance        bigint;
  v_receiver_cut          integer;
  v_platform_cut          integer;
  v_sender_balance_after  bigint;
  v_receiver_balance_after bigint;
  v_gift_id               bigint;
begin
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'amount must be positive';
  end if;
  if p_sender_device = p_receiver_device then
    raise exception 'cannot gift self';
  end if;

  -- Lock sender row and verify balance
  select id, balance_cents into v_sender_id, v_sender_balance
  from public.users where device_id = p_sender_device for update;
  if v_sender_id is null then raise exception 'sender not found'; end if;
  if v_sender_balance < p_amount_cents then raise exception 'insufficient balance'; end if;

  -- Lock receiver row
  select id into v_receiver_id
  from public.users where device_id = p_receiver_device for update;
  if v_receiver_id is null then raise exception 'receiver not found'; end if;

  -- 30% platform fee, integer math so no fractional coins
  v_platform_cut := (p_amount_cents * 30) / 100;
  v_receiver_cut := p_amount_cents - v_platform_cut;

  update public.users
    set balance_cents = balance_cents - p_amount_cents,
        last_seen_at  = now()
    where id = v_sender_id
    returning balance_cents into v_sender_balance_after;

  update public.users
    set balance_cents = balance_cents + v_receiver_cut,
        last_seen_at  = now()
    where id = v_receiver_id
    returning balance_cents into v_receiver_balance_after;

  insert into public.gifts (sender_id, receiver_id, gift_type, amount_cents, receiver_cut_cents, platform_cut_cents)
  values (v_sender_id, v_receiver_id, p_gift_type, p_amount_cents, v_receiver_cut, v_platform_cut)
  returning id into v_gift_id;

  insert into public.ledger (user_id, kind, delta_cents, balance_after, ref_id, note)
  values (v_sender_id, 'gift_sent', -p_amount_cents, v_sender_balance_after, v_gift_id, p_gift_type);

  insert into public.ledger (user_id, kind, delta_cents, balance_after, ref_id, note)
  values (v_receiver_id, 'gift_received', v_receiver_cut, v_receiver_balance_after, v_gift_id, p_gift_type);

  return jsonb_build_object(
    'gift_id', v_gift_id,
    'sender_id', v_sender_id,
    'receiver_id', v_receiver_id,
    'sender_balance', v_sender_balance_after,
    'receiver_balance', v_receiver_balance_after,
    'receiver_cut', v_receiver_cut,
    'platform_cut', v_platform_cut
  );
end;
$$;

-- ========== RPC: test-mode topup (no real money) ==========

create or replace function public.topup_balance(
  p_device       text,
  p_amount_cents integer,
  p_note         text
) returns jsonb
language plpgsql
security definer
as $$
declare
  v_user_id       bigint;
  v_balance_after bigint;
begin
  if p_amount_cents is null or p_amount_cents <= 0 then
    raise exception 'amount must be positive';
  end if;

  update public.users
    set balance_cents = balance_cents + p_amount_cents,
        last_seen_at  = now()
    where device_id = p_device
    returning id, balance_cents into v_user_id, v_balance_after;

  if v_user_id is null then raise exception 'user not found'; end if;

  insert into public.ledger (user_id, kind, delta_cents, balance_after, note)
  values (v_user_id, 'topup', p_amount_cents, v_balance_after, p_note);

  return jsonb_build_object('id', v_user_id, 'balance_cents', v_balance_after);
end;
$$;
