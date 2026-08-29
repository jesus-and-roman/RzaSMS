-- ============================================================
-- RzaSMS / Pluriportail — SCHEMA 10 (additif)
-- Roule après schema9-final.sql.
-- ============================================================

-- ---------- DIAGNOSTIC image_urls ----------
-- Si tu as déjà roulé schema8-final.sql, cette ligne ne fait rien de mal
-- (IF NOT EXISTS). Si la colonne manquait vraiment, elle est créée ici.
alter table messages add column if not exists image_urls jsonb;

-- Vérifie que la colonne existe bien avant de continuer (erreur claire si non) :
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_name = 'messages' and column_name = 'image_urls'
  ) then
    raise exception 'image_urls n''a pas pu être créée -- vérifie que tu es sur le bon projet Supabase';
  end if;
end $$;

-- Force le rechargement du cache PostgREST via pg_notify (plus fiable que
-- NOTIFY brut quand tu passes par le pooler en mode transaction) :
select pg_notify('pgrst', 'reload schema');

-- Si l'erreur "Could not find the image_urls column" persiste après ce script :
-- 1) Supabase Dashboard > Settings > API > bouton "Reload schema cache"
-- 2) Ou Settings > General > "Restart project" (redémarre complètement l'API)
-- 3) Vérifie que tu es connecté au BON projet (l'URL doit être cehdmgveddexdphynwti.supabase.co)

-- ---------- Personnalisation du compte ----------
alter table profiles add column if not exists accent_color text not null default '#ff5d73';
alter table profiles add column if not exists status_text text;
alter table profiles add column if not exists show_online_status boolean not null default true;

-- ---------- Personnalisation des groupes ----------
alter table conversations add column if not exists description text;
alter table conversations add column if not exists icon_url text;
alter table conversations add column if not exists locked_by_mod boolean not null default false;
alter table conversations add column if not exists slow_mode_seconds int not null default 0;

-- ---------- Épingler une discussion (perso, par utilisateur) ----------
alter table member_settings add column if not exists pinned boolean not null default false;

-- ---------- Verrou de groupe : seuls créateur/modérateurs peuvent écrire ----------
create or replace function message_insert_guard() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  conv_type text;
  other_id uuid;
  fblock uuid;
  is_locked boolean;
  slow_secs int;
  my_role text;
  last_msg_at timestamptz;
begin
  select type, locked_by_mod, slow_mode_seconds into conv_type, is_locked, slow_secs
  from conversations where id = new.conversation_id;

  select role into my_role from conversation_members
  where conversation_id = new.conversation_id and user_id = new.sender_id;

  if is_locked and my_role not in ('creator','moderator') then
    raise exception 'groupe_verrouille';
  end if;

  if slow_secs > 0 and my_role not in ('creator','moderator') then
    select max(created_at) into last_msg_at from messages
    where conversation_id = new.conversation_id and sender_id = new.sender_id;
    if last_msg_at is not null and now() - last_msg_at < make_interval(secs => slow_secs) then
      raise exception 'mode_lent_actif';
    end if;
  end if;

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

notify pgrst, 'reload schema';
