-- Run this once in the Supabase SQL editor. Safe to re-run (idempotent).

create table if not exists public.reports (
  id           bigint generated always as identity primary key,
  reporter_sid text   not null,
  reported_sid text   not null,
  reason       text,
  reported_ip  text,
  reported_username text,
  created_at   timestamptz not null default now()
);
create index if not exists reports_created_at_idx  on public.reports (created_at desc);
create index if not exists reports_reported_ip_idx on public.reports (reported_ip);
alter table public.reports enable row level security;

-- Session metrics. One row per event. session_id groups events per socket.
create table if not exists public.events (
  id          bigint generated always as identity primary key,
  session_id  text   not null,
  type        text   not null,           -- session_start | match | skip | block | report | session_end
  country     text,
  ip          text,
  username    text,
  duration_ms integer,
  data        jsonb,
  created_at  timestamptz not null default now()
);
create index if not exists events_created_at_idx on public.events (created_at desc);
create index if not exists events_type_idx       on public.events (type);
create index if not exists events_session_idx    on public.events (session_id);
create index if not exists events_ip_idx         on public.events (ip);
alter table public.events enable row level security;

-- Additive migrations for existing deployments (columns may not exist on old schema)
alter table public.reports add column if not exists reported_ip       text;
alter table public.reports add column if not exists reported_username text;
alter table public.events  add column if not exists ip       text;
alter table public.events  add column if not exists username text;

-- Bans. Signaling server reads active rows and rejects matching IPs on connect.
create table if not exists public.bans (
  id         bigint generated always as identity primary key,
  ip         text not null,
  reason     text,
  banned_by  text,
  banned_at  timestamptz not null default now(),
  expires_at timestamptz,                 -- null = permanent
  active     boolean     not null default true
);
create unique index if not exists bans_active_ip_idx on public.bans (ip) where active = true;
create index if not exists bans_created_at_idx on public.bans (banned_at desc);
alter table public.bans enable row level security;
