-- ============================================================
-- RzaSMS / Pluriportail — Schéma Supabase
-- ============================================================

create extension if not exists "pgcrypto";

-- ---------- PROFILES ----------
create table if not exists profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  email text not null,
  code text unique,
  favicon_mode text not null default 'double-l' check (favicon_mode in ('double-l','image-l','off')),
  notifications_enabled boolean not null default true,
  created_at timestamptz not null default now()
);

alter table profiles enable row level security;

create policy profiles_select on profiles for select using (true);
create policy profiles_update_self on profiles for update using (id = auth.uid());

-- ---------- CODE RZA-{n} (bijective base36, s'épuise avant d'allonger) ----------
create sequence if not exists rza_code_seq start 1;

create or replace function bijective_base36(n bigint) returns text
language plpgsql immutable as $$
declare
  chars text := '0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  result text := '';
  m bigint;
begin
  while n > 0 loop
    n := n - 1;
    m := n % 36;
    result := substr(chars, (m+1)::int, 1) || result;
    n := n / 36;
  end loop;
  return result;
end; $$;

create or replace function generate_rza_code() returns text
language plpgsql as $$
declare seq_val bigint;
begin
  seq_val := nextval('rza_code_seq');
  return 'RZA-' || bijective_base36(seq_val);
end; $$;

-- Auto-création du profil à l'inscription
create or replace function handle_new_user() returns trigger
language plpgsql security definer as $$
begin
  insert into public.profiles(id, email, code)
  values (new.id, new.email, generate_rza_code());
  return new;
end; $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
after insert on auth.users
for each row execute function handle_new_user();

-- ---------- AMIS ----------
create table if not exists friends (
  id uuid primary key default gen_random_uuid(),
  requester_id uuid not null references profiles(id) on delete cascade,
  addressee_id uuid not null references profiles(id) on delete cascade,
  status text not null default 'pending' check (status in ('pending','accepted')),
  created_at timestamptz not null default now(),
  unique(requester_id, addressee_id)
);

alter table friends enable row level security;

create policy friends_select on friends for select
  using (requester_id = auth.uid() or addressee_id = auth.uid());
create policy friends_insert on friends for insert
  with check (requester_id = auth.uid());
create policy friends_update on friends for update
  using (addressee_id = auth.uid() or requester_id = auth.uid());

-- Envoyer une demande via code RZA
create or replace function send_friend_request(p_code text) returns uuid
language plpgsql security definer as $$
declare
  target_id uuid;
  new_id uuid;
begin
  select id into target_id from profiles where code = upper(p_code);
  if target_id is null then
    raise exception 'code_introuvable';
  end if;
  if target_id = auth.uid() then
    raise exception 'auto_ajout_impossible';
  end if;
  insert into friends(requester_id, addressee_id)
  values (auth.uid(), target_id)
  on conflict (requester_id, addressee_id) do nothing
  returning id into new_id;
  return new_id;
end; $$;

-- Accepter une demande -> crée le DM
create or replace function accept_friend_request(p_friend_row uuid) returns uuid
language plpgsql security definer as $$
declare
  req record;
  conv_id uuid;
begin
  select * into req from friends where id = p_friend_row and addressee_id = auth.uid() and status = 'pending';
  if not found then
    raise exception 'demande_introuvable';
  end if;
  update friends set status = 'accepted' where id = p_friend_row;

  select c.id into conv_id
  from conversations c
  join conversation_members m1 on m1.conversation_id = c.id and m1.user_id = req.requester_id
  join conversation_members m2 on m2.conversation_id = c.id and m2.user_id = req.addressee_id
  where c.type = 'dm'
  limit 1;

  if conv_id is null then
    insert into conversations(type, creator_id) values ('dm', req.requester_id) returning id into conv_id;
    insert into conversation_members(conversation_id, user_id, role) values
      (conv_id, req.requester_id, 'creator'),
      (conv_id, req.addressee_id, 'member');
  end if;
  return conv_id;
end; $$;

-- ---------- CONVERSATIONS ----------
create table if not exists conversations (
  id uuid primary key default gen_random_uuid(),
  type text not null check (type in ('dm','group')),
  name text,
  creator_id uuid references profiles(id),
  wallpaper_public int check (wallpaper_public between 1 and 5),
  created_at timestamptz not null default now()
);

create table if not exists conversation_members (
  conversation_id uuid not null references conversations(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  role text not null default 'member' check (role in ('creator','moderator','member')),
  joined_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

alter table conversations enable row level security;
alter table conversation_members enable row level security;

create policy conv_select on conversations for select using (
  exists (select 1 from conversation_members cm where cm.conversation_id = id and cm.user_id = auth.uid())
);
create policy conv_update_wallpaper on conversations for update using (
  exists (select 1 from conversation_members cm where cm.conversation_id = id and cm.user_id = auth.uid()
          and cm.role in ('creator','moderator'))
);

create policy members_select on conversation_members for select using (
  exists (select 1 from conversation_members cm where cm.conversation_id = conversation_id and cm.user_id = auth.uid())
);

-- ---------- COULEURS DE BULLES (personnelles, par observateur) ----------
create table if not exists member_bubble_colors (
  conversation_id uuid not null references conversations(id) on delete cascade,
  viewer_id uuid not null references profiles(id) on delete cascade,
  target_user_id uuid not null references profiles(id) on delete cascade,
  color text not null default '#3a7bd5',
  primary key (conversation_id, viewer_id, target_user_id)
);

alter table member_bubble_colors enable row level security;

create policy bubble_select on member_bubble_colors for select using (viewer_id = auth.uid());
create policy bubble_upsert on member_bubble_colors for insert with check (viewer_id = auth.uid());
create policy bubble_update on member_bubble_colors for update using (viewer_id = auth.uid());

-- ---------- PARAMÈTRES PERSONNELS PAR CONVERSATION (mute, fond privé) ----------
create table if not exists member_settings (
  conversation_id uuid not null references conversations(id) on delete cascade,
  user_id uuid not null references profiles(id) on delete cascade,
  notifications_enabled boolean not null default true,
  wallpaper_private int check (wallpaper_private between 1 and 5),
  last_read_at timestamptz not null default now(),
  primary key (conversation_id, user_id)
);

alter table member_settings enable row level security;

create policy msettings_select on member_settings for select using (user_id = auth.uid());
create policy msettings_upsert on member_settings for insert with check (user_id = auth.uid());
create policy msettings_update on member_settings for update using (user_id = auth.uid());

-- ---------- DEMANDES DE FOND D'ÉCRAN PUBLIC (groupes) ----------
create table if not exists wallpaper_requests (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references conversations(id) on delete cascade,
  requested_by uuid not null references profiles(id),
  wallpaper_index int not null check (wallpaper_index between 1 and 5),
  status text not null default 'pending' check (status in ('pending','approved','rejected')),
  created_at timestamptz not null default now()
);

alter table wallpaper_requests enable row level security;

create policy wreq_select on wallpaper_requests for select using (
  exists (select 1 from conversation_members cm where cm.conversation_id = conversation_id and cm.user_id = auth.uid())
);
create policy wreq_insert on wallpaper_requests for insert with check (requested_by = auth.uid());
create policy wreq_update on wallpaper_requests for update using (
  exists (select 1 from conversation_members cm where cm.conversation_id = conversation_id and cm.user_id = auth.uid()
          and cm.role in ('creator','moderator'))
);

-- Demander/appliquer un fond public. DM = appliqué direct. Groupe = direct si mod/créateur, sinon requête pending.
create or replace function request_public_wallpaper(p_conversation_id uuid, p_index int) returns text
language plpgsql security definer as $$
declare
  conv record;
  my_role text;
begin
  select * into conv from conversations where id = p_conversation_id;
  select role into my_role from conversation_members where conversation_id = p_conversation_id and user_id = auth.uid();
  if my_role is null then raise exception 'non_membre'; end if;

  if conv.type = 'dm' then
    update conversations set wallpaper_public = p_index where id = p_conversation_id;
    return 'applique';
  end if;

  if my_role in ('creator','moderator') then
    update conversations set wallpaper_public = p_index where id = p_conversation_id;
    return 'applique';
  else
    insert into wallpaper_requests(conversation_id, requested_by, wallpaper_index)
    values (p_conversation_id, auth.uid(), p_index);
    return 'en_attente';
  end if;
end; $$;

create or replace function approve_wallpaper_request(p_request_id uuid, p_approve boolean) returns void
language plpgsql security definer as $$
declare
  req record;
  my_role text;
begin
  select * into req from wallpaper_requests where id = p_request_id and status = 'pending';
  if not found then raise exception 'requete_introuvable'; end if;
  select role into my_role from conversation_members where conversation_id = req.conversation_id and user_id = auth.uid();
  if my_role not in ('creator','moderator') then raise exception 'non_autorise'; end if;

  if p_approve then
    update conversations set wallpaper_public = req.wallpaper_index where id = req.conversation_id;
    update wallpaper_requests set status = 'approved' where id = p_request_id;
  else
    update wallpaper_requests set status = 'rejected' where id = p_request_id;
  end if;
end; $$;

-- ---------- PROMOTION DE MODÉRATEUR ----------
create or replace function promote_moderator(p_conversation_id uuid, p_user_id uuid) returns void
language plpgsql security definer as $$
declare my_role text;
begin
  select role into my_role from conversation_members where conversation_id = p_conversation_id and user_id = auth.uid();
  if my_role not in ('creator','moderator') then raise exception 'non_autorise'; end if;

  update conversation_members set role = 'moderator'
  where conversation_id = p_conversation_id and user_id = p_user_id and role = 'member';
end; $$;
-- Note: aucune fonction de rétrogradation n'existe pour le rôle 'creator' -> il ne peut jamais être rétrogradé.

-- ---------- MESSAGES ----------
create table if not exists messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references conversations(id) on delete cascade,
  sender_id uuid not null references profiles(id),
  content text not null,
  created_at timestamptz not null default now(),
  edited_at timestamptz,
  deleted boolean not null default false
);

alter table messages enable row level security;

create policy msg_select on messages for select using (
  exists (select 1 from conversation_members cm where cm.conversation_id = conversation_id and cm.user_id = auth.uid())
);
create policy msg_insert on messages for insert with check (
  sender_id = auth.uid()
  and exists (select 1 from conversation_members cm where cm.conversation_id = conversation_id and cm.user_id = auth.uid())
);
create policy msg_update on messages for update using (sender_id = auth.uid());

-- Garde-fou: suppression <=5min, modification <=15min, après c'est verrouillé
create or replace function message_update_guard() returns trigger
language plpgsql security definer as $$
begin
  if old.sender_id <> auth.uid() then
    raise exception 'pas_proprietaire';
  end if;

  if new.deleted = true and old.deleted = false then
    if now() - old.created_at > interval '5 minutes' then
      raise exception 'fenetre_suppression_expiree';
    end if;
    new.content := '[Message supprimé]';
  elsif new.content is distinct from old.content then
    if old.deleted = true then
      raise exception 'message_supprime';
    end if;
    if now() - old.created_at > interval '15 minutes' then
      raise exception 'fenetre_modification_expiree';
    end if;
    new.edited_at := now();
  end if;
  return new;
end; $$;

drop trigger if exists trg_message_update_guard on messages;
create trigger trg_message_update_guard before update on messages
for each row execute function message_update_guard();

-- Realtime
alter publication supabase_realtime add table messages;
alter publication supabase_realtime add table conversations;
alter publication supabase_realtime add table conversation_members;
alter publication supabase_realtime add table friends;
alter publication supabase_realtime add table wallpaper_requests;
