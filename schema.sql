-- Run once in the Supabase SQL editor.

create table if not exists public.reports (
  id           bigint generated always as identity primary key,
  reporter_sid text   not null,
  reported_sid text   not null,
  reason       text,
  created_at   timestamptz not null default now()
);

create index if not exists reports_created_at_idx on public.reports (created_at desc);
create index if not exists reports_reported_sid_idx on public.reports (reported_sid);

alter table public.reports enable row level security;

-- Session metrics: one row per event. Session id groups events per socket.
create table if not exists public.events (
  id          bigint generated always as identity primary key,
  session_id  text   not null,
  type        text   not null,        -- session_start | match | skip | block | report | session_end
  country     text,
  duration_ms integer,
  data        jsonb,
  created_at  timestamptz not null default now()
);

create index if not exists events_created_at_idx on public.events (created_at desc);
create index if not exists events_type_idx       on public.events (type);
create index if not exists events_session_idx    on public.events (session_id);

alter table public.events enable row level security;

-- Handy aggregates for your tiny dashboard (query these from SQL editor):
-- Active today:
--   select count(distinct session_id) from events
--     where type='session_start' and created_at > now() - interval '1 day';
-- Avg session length (minutes):
--   select avg(duration_ms)/60000.0 from events
--     where type='session_end' and duration_ms is not null and created_at > now() - interval '7 days';
-- Skips per session:
--   select session_id, count(*) as skips from events
--     where type='skip' group by session_id order by skips desc limit 50;
-- Match rate:
--   select count(*) filter (where type='match') * 1.0 /
--          nullif(count(*) filter (where type='session_start'), 0) as matches_per_session
--     from events where created_at > now() - interval '1 day';
