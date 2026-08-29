-- ============================================================
-- RzaSMS / Pluriportail — SCHEMA 7 (additif)
-- Roule après schema6-final.sql. N'efface rien.
-- ============================================================

-- ---------- Colonnes ----------
alter table profiles add column if not exists username text;
alter table profiles add column if not exists favicon_preset text not null default 'pluriportail'
  check (favicon_preset in ('pluriportail','gmail','newtab','classroom'));

-- ============================================================
-- FIX DU 403 SUR LA CRÉATION DE GROUPE
-- Cause réelle : conv_insert exigeait creator_id = auth.uid(), mais le
-- SELECT juste après l'INSERT (`.select().single()`) est bloqué par
-- conv_select tant que le créateur n'est pas encore dans
-- conversation_members (ce qui n'arrivait qu'après un 2e insert).
-- Solution propre : tout faire dans une fonction SECURITY DEFINER,
-- comme pour les DM.
-- ============================================================

create or replace function create_group(p_name text, p_member_ids uuid[]) returns uuid
language plpgsql security definer set search_path = public as $$
declare
  new_id uuid;
  mid uuid;
begin
  insert into conversations(type, name, creator_id) values ('group', p_name, auth.uid()) returning id into new_id;
  insert into conversation_members(conversation_id, user_id, role) values (new_id, auth.uid(), 'creator');
  if p_member_ids is not null then
    foreach mid in array p_member_ids loop
      if mid <> auth.uid() then
        insert into conversation_members(conversation_id, user_id, role) values (new_id, mid, 'member')
        on conflict do nothing;
      end if;
    end loop;
  end if;
  return new_id;
end; $$;
grant execute on function create_group(text, uuid[]) to authenticated;

-- ---------- Kick (modo/créateur, le créateur est intouchable) ----------
create or replace function group_kick_member(p_conversation_id uuid, p_target uuid) returns void
language plpgsql security definer set search_path = public as $$
declare my_role text; target_role text;
begin
  select role into my_role from conversation_members where conversation_id = p_conversation_id and user_id = auth.uid();
  if my_role not in ('creator','moderator') then raise exception 'non_autorise'; end if;

  select role into target_role from conversation_members where conversation_id = p_conversation_id and user_id = p_target;
  if target_role is null then raise exception 'pas_membre'; end if;
  if target_role = 'creator' then raise exception 'impossible_expulser_createur'; end if;

  delete from conversation_members where conversation_id = p_conversation_id and user_id = p_target;
end; $$;
grant execute on function group_kick_member(uuid, uuid) to authenticated;

-- ---------- Ajouter au groupe par code RZA (direct si déjà amis, sinon demande d'ami) ----------
create or replace function group_add_by_code(p_conversation_id uuid, p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare
  my_role text;
  target_id uuid;
  already_friend boolean;
begin
  select role into my_role from conversation_members where conversation_id = p_conversation_id and user_id = auth.uid();
  if my_role not in ('creator','moderator') then raise exception 'non_autorise'; end if;

  select id into target_id from profiles where code = upper(p_code);
  if target_id is null then raise exception 'code_introuvable'; end if;

  if exists (select 1 from conversation_members where conversation_id = p_conversation_id and user_id = target_id) then
    raise exception 'deja_membre';
  end if;

  select exists(
    select 1 from friends where status = 'accepted' and
    ((requester_id = auth.uid() and addressee_id = target_id) or (requester_id = target_id and addressee_id = auth.uid()))
  ) into already_friend;

  if already_friend then
    insert into conversation_members(conversation_id, user_id, role) values (p_conversation_id, target_id, 'member');
    return 'ajoute';
  else
    insert into friends(requester_id, addressee_id) values (auth.uid(), target_id)
    on conflict (requester_id, addressee_id) do nothing;
    return 'demande_envoyee';
  end if;
end; $$;
grant execute on function group_add_by_code(uuid, text) to authenticated;

notify pgrst, 'reload schema';
