-- Run this once in the Supabase SQL editor. Safe to re-run (idempotent).

-- ========== TABLES ==========

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

-- ========== ADDITIVE MIGRATIONS (must run before indexes that reference these) ==========

alter table public.reports add column if not exists reported_ip       text;
alter table public.reports add column if not exists reported_username text;

alter table public.events  add column if not exists ip       text;
alter table public.events  add column if not exists username text;

-- ========== INDEXES ==========

create index        if not exists reports_created_at_idx  on public.reports (created_at desc);
create index        if not exists reports_reported_ip_idx on public.reports (reported_ip);

create index        if not exists events_created_at_idx on public.events (created_at desc);
create index        if not exists events_type_idx       on public.events (type);
create index        if not exists events_session_idx    on public.events (session_id);
create index        if not exists events_ip_idx         on public.events (ip);

create unique index if not exists bans_active_ip_idx    on public.bans (ip) where active = true;
create index        if not exists bans_created_at_idx   on public.bans (banned_at desc);

-- ========== RLS ==========

alter table public.reports enable row level security;
alter table public.events  enable row level security;
alter table public.bans    enable row level security;
