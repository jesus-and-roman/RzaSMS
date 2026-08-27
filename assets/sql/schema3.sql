-- ============================================================
-- RzaSMS / Pluriportail — SCHEMA 3
-- Correction RLS / récursion infinie
--
-- À exécuter APRÈS Schema 1 ou Schema 2
-- ============================================================

create extension if not exists "pgcrypto";


-- ============================================================
-- 1. FONCTIONS DE VÉRIFICATION RLS
-- ============================================================
-- Ces fonctions utilisent SECURITY DEFINER afin de pouvoir
-- vérifier conversation_members sans déclencher sa propre
-- policy RLS et provoquer une récursion infinie.


create or replace function public.is_conversation_member(
  p_conversation_id uuid,
  p_user_id uuid default auth.uid()
)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1
    from public.conversation_members cm
    where cm.conversation_id = p_conversation_id
      and cm.user_id = p_user_id
  );
$$;


create or replace function public.is_conversation_creator(
  p_conversation_id uuid,
  p_user_id uuid default auth.uid()
)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1
    from public.conversations c
    where c.id = p_conversation_id
      and c.creator_id = p_user_id
  );
$$;


create or replace function public.conversation_user_role(
  p_conversation_id uuid,
  p_user_id uuid default auth.uid()
)
returns text
language sql
security definer
stable
set search_path = public
as $$
  select cm.role
  from public.conversation_members cm
  where cm.conversation_id = p_conversation_id
    and cm.user_id = p_user_id
  limit 1;
$$;


-- ============================================================
-- 2. PERMISSIONS DES FONCTIONS
-- ============================================================

grant execute on function public.is_conversation_member(uuid, uuid)
to authenticated;

grant execute on function public.is_conversation_creator(uuid, uuid)
to authenticated;

grant execute on function public.conversation_user_role(uuid, uuid)
to authenticated;


-- ============================================================
-- 3. CONVERSATIONS — POLICIES
-- ============================================================

alter table public.conversations enable row level security;

drop policy if exists conv_select on public.conversations;
drop policy if exists conv_insert on public.conversations;
drop policy if exists conv_update_wallpaper on public.conversations;


-- Lire uniquement les conversations auxquelles on appartient
create policy conv_select
on public.conversations
for select
using (
  public.is_conversation_member(id, auth.uid())
);


-- Créer une conversation
create policy conv_insert
on public.conversations
for insert
with check (
  creator_id = auth.uid()
);


-- Modifier une conversation si on est créateur/modérateur
create policy conv_update_wallpaper
on public.conversations
for update
using (
  public.conversation_user_role(id, auth.uid())
  in ('creator', 'moderator')
)
with check (
  true
);


-- ============================================================
-- 4. CONVERSATION_MEMBERS — POLICIES
-- ============================================================

alter table public.conversation_members enable row level security;

drop policy if exists members_select on public.conversation_members;
drop policy if exists members_insert on public.conversation_members;
drop policy if exists members_update on public.conversation_members;


-- ------------------------------------------------------------
-- SELECT
-- ------------------------------------------------------------
-- IMPORTANT :
-- Ne JAMAIS refaire directement :
--
-- exists (
--   select 1 from conversation_members ...
-- )
--
-- ici, car cela provoque une récursion RLS.
--
-- On utilise la fonction SECURITY DEFINER.

create policy members_select
on public.conversation_members
for select
using (
  public.is_conversation_member(conversation_id, auth.uid())
);


-- ------------------------------------------------------------
-- INSERT
-- ------------------------------------------------------------
-- Le créateur peut ajouter les membres d'un groupe.
--
-- Cela permet au JS de faire :
--
-- conversations.insert(...)
-- conversation_members.insert(...)
--
create policy members_insert
on public.conversation_members
for insert
with check (
  public.is_conversation_creator(conversation_id, auth.uid())
);


-- ------------------------------------------------------------
-- UPDATE
-- ------------------------------------------------------------
-- Permet aux créateurs/modérateurs de modifier les rôles.
--
-- Le HTML utilise notamment promote_moderator().
-- La fonction SQL elle-même est SECURITY DEFINER, mais cette
-- policy protège également les modifications directes.

create policy members_update
on public.conversation_members
for update
using (
  public.conversation_user_role(conversation_id, auth.uid())
  in ('creator', 'moderator')
)
with check (
  true
);


-- ============================================================
-- 5. MESSAGES — POLICIES
-- ============================================================

alter table public.messages enable row level security;

drop policy if exists msg_select on public.messages;
drop policy if exists msg_insert on public.messages;


create policy msg_select
on public.messages
for select
using (
  public.is_conversation_member(conversation_id, auth.uid())
);


create policy msg_insert
on public.messages
for insert
with check (
  sender_id = auth.uid()
  and public.is_conversation_member(conversation_id, auth.uid())
);


-- ============================================================
-- 6. WALLPAPER REQUESTS — POLICIES
-- ============================================================

alter table public.wallpaper_requests enable row level security;

drop policy if exists wreq_select on public.wallpaper_requests;
drop policy if exists wreq_insert on public.wallpaper_requests;
drop policy if exists wreq_update on public.wallpaper_requests;


create policy wreq_select
on public.wallpaper_requests
for select
using (
  public.is_conversation_member(conversation_id, auth.uid())
);


create policy wreq_insert
on public.wallpaper_requests
for insert
with check (
  requested_by = auth.uid()
  and public.is_conversation_member(conversation_id, auth.uid())
);


create policy wreq_update
on public.wallpaper_requests
for update
using (
  public.conversation_user_role(conversation_id, auth.uid())
  in ('creator', 'moderator')
)
with check (
  true
);


-- ============================================================
-- 7. CORRECTION DES FONCTIONS SECURITY DEFINER
-- ============================================================
-- On impose explicitement search_path = public pour éviter
-- qu'un objet d'un autre schema soit utilisé par erreur.


create or replace function public.request_public_wallpaper(
  p_conversation_id uuid,
  p_index int
)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  conv record;
  my_role text;
begin

  if p_index < 1 or p_index > 5 then
    raise exception 'index_fond_invalide';
  end if;

  select *
  into conv
  from public.conversations
  where id = p_conversation_id;

  if not found then
    raise exception 'conversation_introuvable';
  end if;

  select cm.role
  into my_role
  from public.conversation_members cm
  where cm.conversation_id = p_conversation_id
    and cm.user_id = auth.uid();

  if my_role is null then
    raise exception 'non_membre';
  end if;


  -- DM : application immédiate
  if conv.type = 'dm' then

    update public.conversations
    set wallpaper_public = p_index
    where id = p_conversation_id;

    return 'applique';

  end if;


  -- Groupe : créateur/modérateur
  if my_role in ('creator', 'moderator') then

    update public.conversations
    set wallpaper_public = p_index
    where id = p_conversation_id;

    return 'applique';

  end if;


  -- Groupe : membre normal → demande
  insert into public.wallpaper_requests(
    conversation_id,
    requested_by,
    wallpaper_index
  )
  values (
    p_conversation_id,
    auth.uid(),
    p_index
  );

  return 'en_attente';

end;
$$;


create or replace function public.approve_wallpaper_request(
  p_request_id uuid,
  p_approve boolean
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  req record;
  my_role text;
begin

  select *
  into req
  from public.wallpaper_requests
  where id = p_request_id
    and status = 'pending';

  if not found then
    raise exception 'requete_introuvable';
  end if;


  select cm.role
  into my_role
  from public.conversation_members cm
  where cm.conversation_id = req.conversation_id
    and cm.user_id = auth.uid();


  if my_role not in ('creator', 'moderator') then
    raise exception 'non_autorise';
  end if;


  if p_approve then

    update public.conversations
    set wallpaper_public = req.wallpaper_index
    where id = req.conversation_id;

    update public.wallpaper_requests
    set status = 'approved'
    where id = p_request_id;

  else

    update public.wallpaper_requests
    set status = 'rejected'
    where id = p_request_id;

  end if;

end;
$$;


-- ============================================================
-- 8. PROMOTION MODÉRATEUR
-- ============================================================

create or replace function public.promote_moderator(
  p_conversation_id uuid,
  p_user_id uuid
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  my_role text;
begin

  select cm.role
  into my_role
  from public.conversation_members cm
  where cm.conversation_id = p_conversation_id
    and cm.user_id = auth.uid();

  if my_role not in ('creator', 'moderator') then
    raise exception 'non_autorise';
  end if;


  update public.conversation_members
  set role = 'moderator'
  where conversation_id = p_conversation_id
    and user_id = p_user_id
    and role = 'member';

end;
$$;


-- ============================================================
-- 9. ACCEPTATION D'UNE DEMANDE D'AMI
-- ============================================================
-- Version sécurisée avec search_path explicite.


create or replace function public.accept_friend_request(
  p_friend_row uuid
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  req record;
  conv_id uuid;
begin

  select *
  into req
  from public.friends
  where id = p_friend_row
    and addressee_id = auth.uid()
    and status = 'pending';

  if not found then
    raise exception 'demande_introuvable';
  end if;


  update public.friends
  set status = 'accepted'
  where id = p_friend_row;


  -- Chercher un DM existant entre les deux utilisateurs
  select c.id
  into conv_id
  from public.conversations c
  join public.conversation_members m1
    on m1.conversation_id = c.id
   and m1.user_id = req.requester_id
  join public.conversation_members m2
    on m2.conversation_id = c.id
   and m2.user_id = req.addressee_id
  where c.type = 'dm'
  limit 1;


  -- Sinon créer le DM
  if conv_id is null then

    insert into public.conversations(
      type,
      creator_id
    )
    values (
      'dm',
      req.requester_id
    )
    returning id into conv_id;


    insert into public.conversation_members(
      conversation_id,
      user_id,
      role
    )
    values
      (
        conv_id,
        req.requester_id,
        'creator'
      ),
      (
        conv_id,
        req.addressee_id,
        'member'
      );

  end if;


  return conv_id;

end;
$$;


-- ============================================================
-- 10. PERMISSIONS RPC
-- ============================================================

grant execute on function public.request_public_wallpaper(uuid, int)
to authenticated;

grant execute on function public.approve_wallpaper_request(uuid, boolean)
to authenticated;

grant execute on function public.promote_moderator(uuid, uuid)
to authenticated;

grant execute on function public.accept_friend_request(uuid)
to authenticated;


-- ============================================================
-- 11. REFRESH DU CACHE POSTGREST
-- ============================================================

notify pgrst, 'reload schema';


-- ============================================================
-- SCHEMA 3 TERMINÉ
-- ============================================================
