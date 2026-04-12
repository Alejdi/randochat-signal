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

-- RLS: server uses service-role key, bypasses RLS. Lock down anon anyway.
alter table public.reports enable row level security;
