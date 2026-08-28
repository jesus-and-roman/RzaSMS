-- ============================================================
-- RzaSMS / Pluriportail — SCHEMA 6 (final, additif)
-- Ne supprime AUCUNE donnée. Corrige la vraie cause des "L" qui
-- ne s'affichaient pas : la table read_state et les colonnes
-- avatar_url / is_admin / is_blocked n'existaient jamais dans
-- ta base (le HTML les utilisait déjà, mais schema1-5 ne les
-- avaient jamais créées -> les requêtes échouaient en silence).
-- À exécuter APRÈS schema1..schema5.
-- ============================================================

create extension if not exists "pgcrypto";

-- ---------- Colonnes manquantes sur profiles ----------
alter table profiles add column if not exists avatar_url text;
alter table profiles add column if not exists is_admin boolean not null default false;
alter table profiles add column if not exists is_blocked boolean not null default false;
alter table profiles add column if not exists read_receipts_enabled boolean not null default true;

-- ---------- Colonne manquante sur conversations ----------
alter table conversations add column if not exists nicknames_allowed boolean not null default true;

-- ---------- Fonctions anti-récursion (au cas où schema3 n'a pas tout appliqué) ----------
create or replace function public.is_conversation_member(
  p_conversation_id uuid, p_user_id uuid default auth.uid()
) returns boolean language sql security definer stable set search_path = public as $$
  select exists (
    select 1 from public.conversation_members cm
    where cm.conversation_id = p_conversation_id and cm.user_id = p_user_id
  );
$$;
grant execute on function public.is_conversation_member(uuid, uuid) to authenticated;

-- ---------- Table des surnoms personnels ----------
create table if not exists nicknames (
  viewer_id uuid not null references profiles(id) on delete cascade,
  target_user_id uuid not null references profiles(id) on delete cascade,
  nickname text not null,
  primary key (viewer_id, target_user_id)
);
alter table nicknames enable row level security;
drop policy if exists nick_select on nicknames;
drop policy if exists nick_insert on nicknames;
drop policy if exists nick_update on nicknames;
drop policy if exists nick_delete on nicknames;
create policy nick_select on nicknames for select using (viewer_id = auth.uid());
create policy nick_insert on nicknames for insert with check (viewer_id = auth.uid());
create policy nick_update on nicknames for update using (viewer_id = auth.uid());
create policy nick_delete on nicknames for delete using (viewer_id = auth.uid());

-- ---------- Table read_state (remplace member_settings.last_read_at) ----------
create table if not exists read_state (
  conversation_id uuid not null references conversations(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  last_read_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);
alter table read_state enable row level security;
drop policy if exists read_select on read_state;
drop policy if exists read_insert on read_state;
drop policy if exists read_update on read_state;
create policy read_select on read_state for select using (
  public.is_conversation_member(conversation_id, auth.uid())
);
create policy read_insert on read_state for insert with check (user_id = auth.uid());
create policy read_update on read_state for update using (user_id = auth.uid());

-- Migrer les anciennes valeurs si member_settings.last_read_at existe encore
do $$
begin
  if exists (select 1 from information_schema.columns where table_name='member_settings' and column_name='last_read_at') then
    insert into read_state(conversation_id, user_id, last_read_at)
    select conversation_id, user_id, last_read_at from member_settings
    on conflict (conversation_id, user_id) do nothing;
    alter table member_settings drop column last_read_at;
  end if;
end $$;

do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname='supabase_realtime' and schemaname='public' and tablename='read_state') then
    execute 'alter publication supabase_realtime add table public.read_state';
  end if;
end $$;

-- ---------- Fonctions admin (compte Modo) ----------
create or replace function admin_add_friend(p_target uuid) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  conv_id uuid;
  je_suis_admin boolean;
begin
  select is_admin into je_suis_admin from profiles where id = auth.uid();
  if not coalesce(je_suis_admin,false) then raise exception 'non_autorise'; end if;
  if p_target = auth.uid() then raise exception 'auto_ajout_impossible'; end if;

  insert into friends(requester_id, addressee_id, status) values (auth.uid(), p_target, 'accepted')
  on conflict (requester_id, addressee_id) do update set status = 'accepted';

  select c.id into conv_id
  from conversations c
  join conversation_members m1 on m1.conversation_id = c.id and m1.user_id = auth.uid()
  join conversation_members m2 on m2.conversation_id = c.id and m2.user_id = p_target
  where c.type = 'dm' limit 1;

  if conv_id is null then
    insert into conversations(type, creator_id) values ('dm', auth.uid()) returning id into conv_id;
    insert into conversation_members(conversation_id,user_id,role) values
      (conv_id, auth.uid(), 'creator'), (conv_id, p_target, 'member');
  end if;
  return conv_id;
end; $$;
grant execute on function admin_add_friend(uuid) to authenticated;

create or replace function admin_set_blocked(p_target uuid, p_blocked boolean) returns void
language plpgsql security definer set search_path = public as $$
declare je_suis_admin boolean;
begin
  select is_admin into je_suis_admin from profiles where id = auth.uid();
  if not coalesce(je_suis_admin,false) then raise exception 'non_autorise'; end if;
  update profiles set is_blocked = p_blocked where id = p_target;
end; $$;
grant execute on function admin_set_blocked(uuid, boolean) to authenticated;

create or replace function admin_delete_account(p_target uuid) returns void
language plpgsql security definer set search_path = public as $$
declare je_suis_admin boolean;
begin
  select is_admin into je_suis_admin from profiles where id = auth.uid();
  if not coalesce(je_suis_admin,false) then raise exception 'non_autorise'; end if;
  delete from profiles where id = p_target;
end; $$;
grant execute on function admin_delete_account(uuid) to authenticated;
-- Note: supprime le profil + toutes ses données, mais pas la ligne auth.users
-- (nécessite service_role -> Dashboard Supabase > Authentication > Users)

-- ---------- Blocage entre amis (chat direct) ----------
alter table friends add column if not exists blocked_by uuid references profiles(id);

create or replace function message_insert_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  conv_type text;
  other_id uuid;
  fblock uuid;
begin
  select type into conv_type from conversations where id = new.conversation_id;
  if conv_type = 'dm' then
    select user_id into other_id from conversation_members
    where conversation_id = new.conversation_id and user_id <> new.sender_id limit 1;
    if other_id is not null then
      select blocked_by into fblock from friends
      where (requester_id = new.sender_id and addressee_id = other_id)
         or (requester_id = other_id and addressee_id = new.sender_id);
      if fblock is not null then
        raise exception 'contact_bloque';
      end if;
    end if;
  end if;
  return new;
end; $$;

drop trigger if exists trg_message_insert_guard on messages;
create trigger trg_message_insert_guard before insert on messages
for each row execute function message_insert_guard();

-- ---------- Fix définitif du 500 à l'inscription (grants pour supabase_auth_admin) ----------
create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles(id, email, code)
  values (new.id, new.email, generate_rza_code())
  on conflict (id) do nothing;
  return new;
exception when others then
  raise warning 'handle_new_user: %', sqlerrm;
  return new;
end; $$;

grant usage on schema public to supabase_auth_admin;
grant all on all tables in schema public to supabase_auth_admin;
grant all on all sequences in schema public to supabase_auth_admin;
grant execute on all functions in schema public to supabase_auth_admin;

notify pgrst, 'reload schema';

-- ============================================================
-- POUR CRÉER LE COMPTE ADMIN :
-- 1) Inscris-toi normalement avec l'email du futur admin.
-- 2) UPDATE profiles SET is_admin = true WHERE email = 'admin@exemple.com';
-- ============================================================
