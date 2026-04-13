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
  kind          text   not null,  -- topup | gift_sent | gift_received | cashout_pending | cashout_paid | cashout_refund | admin_credit | admin_debit
  delta_cents   bigint not null,
  balance_after bigint not null,
  ref_id        bigint,
  note          text,
  created_at    timestamptz not null default now()
);

-- Manual cashout requests. User submits, admin processes by hand.
create table if not exists public.cashout_requests (
  id            bigint generated always as identity primary key,
  user_id       bigint not null references public.users(id),
  amount_cents  bigint not null check (amount_cents > 0),
  method        text   not null,                  -- 'paypal' | 'crypto' | 'bank' | 'other'
  destination   text   not null,                  -- paypal email / wallet address / iban / etc.
  note          text,
  status        text   not null default 'pending',-- pending | paid | rejected
  admin_note    text,
  processed_at  timestamptz,
  processed_by  text,
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

create index if not exists cashout_status_idx on public.cashout_requests (status, created_at desc);
create index if not exists cashout_user_idx   on public.cashout_requests (user_id, created_at desc);

-- ========== RLS (service role bypasses all of this) ==========

alter table public.reports enable row level security;
alter table public.events  enable row level security;
alter table public.bans    enable row level security;
alter table public.users            enable row level security;
alter table public.gifts            enable row level security;
alter table public.ledger           enable row level security;
alter table public.cashout_requests enable row level security;

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
  values (p_device, p_username, 5)  -- 5 coin bootstrap — exactly one heart to try
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

-- ========== RPC: manual topup (used by admin after receiving payment off-chain) ==========

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

-- ========== RPC: admin credit (by user id, with ref) ==========

create or replace function public.admin_credit(
  p_user_id      bigint,
  p_amount_cents integer,
  p_note         text,
  p_ref          text
) returns jsonb
language plpgsql
security definer
as $$
declare v_balance_after bigint;
begin
  if p_amount_cents = 0 then raise exception 'amount cannot be zero'; end if;
  -- negative amount_cents = debit (admin adjusts down)
  update public.users
    set balance_cents = balance_cents + p_amount_cents,
        last_seen_at  = now()
    where id = p_user_id
    returning balance_cents into v_balance_after;
  if v_balance_after is null then raise exception 'user not found'; end if;
  if v_balance_after < 0 then
    raise exception 'would go negative (balance after=%)', v_balance_after;
  end if;

  insert into public.ledger (user_id, kind, delta_cents, balance_after, note)
  values (p_user_id,
          case when p_amount_cents > 0 then 'admin_credit' else 'admin_debit' end,
          p_amount_cents,
          v_balance_after,
          coalesce(p_note, '') || case when p_ref is not null then ' [ref:' || p_ref || ']' else '' end);

  return jsonb_build_object('id', p_user_id, 'balance_cents', v_balance_after);
end;
$$;

-- ========== RPC: create cashout request ==========
-- Debits balance immediately so the user can't gift the same coins while their
-- request is pending. If admin later rejects, we refund via process_cashout_request.

create or replace function public.create_cashout_request(
  p_device      text,
  p_amount      integer,
  p_method      text,
  p_destination text,
  p_note        text
) returns jsonb
language plpgsql
security definer
as $$
declare
  v_user_id    bigint;
  v_balance    bigint;
  v_request_id bigint;
  v_balance_after bigint;
begin
  if p_amount is null or p_amount <= 0 then raise exception 'amount must be positive'; end if;
  if p_method not in ('paypal', 'crypto', 'bank', 'other') then raise exception 'invalid method'; end if;
  if p_destination is null or length(trim(p_destination)) < 3 then raise exception 'destination required'; end if;

  select id, balance_cents into v_user_id, v_balance
  from public.users where device_id = p_device for update;
  if v_user_id is null then raise exception 'user not found'; end if;
  if v_balance < p_amount then raise exception 'insufficient balance'; end if;

  update public.users set balance_cents = balance_cents - p_amount
    where id = v_user_id
    returning balance_cents into v_balance_after;

  insert into public.cashout_requests (user_id, amount_cents, method, destination, note, status)
  values (v_user_id, p_amount, p_method, trim(p_destination), p_note, 'pending')
  returning id into v_request_id;

  insert into public.ledger (user_id, kind, delta_cents, balance_after, ref_id, note)
  values (v_user_id, 'cashout_pending', -p_amount, v_balance_after, v_request_id, p_method);

  return jsonb_build_object(
    'request_id', v_request_id,
    'balance_cents', v_balance_after
  );
end;
$$;

-- ========== RPC: process cashout request (admin action) ==========

create or replace function public.process_cashout_request(
  p_request_id   bigint,
  p_new_status   text,                -- 'paid' | 'rejected'
  p_admin_note   text,
  p_processed_by text
) returns jsonb
language plpgsql
security definer
as $$
declare
  v_user_id       bigint;
  v_amount        bigint;
  v_old_status    text;
  v_balance_after bigint;
begin
  if p_new_status not in ('paid', 'rejected') then raise exception 'invalid status'; end if;

  select user_id, amount_cents, status into v_user_id, v_amount, v_old_status
  from public.cashout_requests where id = p_request_id for update;
  if v_user_id is null then raise exception 'request not found'; end if;
  if v_old_status <> 'pending' then raise exception 'already processed: %', v_old_status; end if;

  update public.cashout_requests
    set status       = p_new_status,
        admin_note   = p_admin_note,
        processed_at = now(),
        processed_by = p_processed_by
    where id = p_request_id;

  if p_new_status = 'rejected' then
    update public.users
      set balance_cents = balance_cents + v_amount
      where id = v_user_id
      returning balance_cents into v_balance_after;

    insert into public.ledger (user_id, kind, delta_cents, balance_after, ref_id, note)
    values (v_user_id, 'cashout_refund', v_amount, v_balance_after, p_request_id, p_admin_note);
  else
    -- 'paid' — balance was already debited at request creation
    select balance_cents into v_balance_after from public.users where id = v_user_id;
    insert into public.ledger (user_id, kind, delta_cents, balance_after, ref_id, note)
    values (v_user_id, 'cashout_paid', 0, v_balance_after, p_request_id, p_admin_note);
  end if;

  return jsonb_build_object(
    'id', p_request_id,
    'status', p_new_status,
    'user_id', v_user_id,
    'balance_cents', v_balance_after
  );
end;
$$;
