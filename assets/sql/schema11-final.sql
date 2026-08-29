-- ============================================================
-- RzaSMS / Pluriportail — SCHEMA 11 (additif)
-- Roule après schema10-final.sql.
-- ============================================================

-- ---------- Réactions emoji sur les messages ----------
create table if not exists message_reactions (
  message_id uuid not null references messages(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  emoji text not null,
  created_at timestamptz not null default now(),
  primary key (message_id, user_id, emoji)
);

alter table message_reactions enable row level security;

drop policy if exists reactions_select on message_reactions;
drop policy if exists reactions_insert on message_reactions;
drop policy if exists reactions_delete on message_reactions;

create policy reactions_select on message_reactions for select using (
  exists (
    select 1 from messages m
    join conversation_members cm on cm.conversation_id = m.conversation_id
    where m.id = message_reactions.message_id and cm.user_id = auth.uid()
  )
);
create policy reactions_insert on message_reactions for insert with check (user_id = auth.uid());
create policy reactions_delete on message_reactions for delete using (user_id = auth.uid());

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='message_reactions') then
    execute 'alter publication supabase_realtime add table public.message_reactions';
  end if;
end $$;

-- ---------- Message épinglé par groupe ----------
alter table conversations add column if not exists pinned_message_id uuid references messages(id) on delete set null;

-- ---------- Ne pas déranger programmé (heures locales du navigateur) ----------
alter table profiles add column if not exists dnd_start_hour int check (dnd_start_hour between 0 and 23);
alter table profiles add column if not exists dnd_end_hour int check (dnd_end_hour between 0 and 23);

-- ---------- Assourdissement du fond d'écran (par discussion, perso) ----------
alter table member_settings add column if not exists wallpaper_dim int not null default 0 check (wallpaper_dim between 0 and 90);

notify pgrst, 'reload schema';
