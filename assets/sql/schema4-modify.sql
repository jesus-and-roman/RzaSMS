ALTER TABLE conversations
  DROP CONSTRAINT IF EXISTS conversations_wallpaper_public_check;

ALTER TABLE conversations
  ADD CONSTRAINT conversations_wallpaper_public_check
  CHECK (wallpaper_public BETWEEN 1 AND 10);


ALTER TABLE member_settings
  DROP CONSTRAINT IF EXISTS member_settings_wallpaper_private_check;

ALTER TABLE member_settings
  ADD CONSTRAINT member_settings_wallpaper_private_check
  CHECK (wallpaper_private BETWEEN 1 AND 10);


ALTER TABLE wallpaper_requests
  DROP CONSTRAINT IF EXISTS wallpaper_requests_wallpaper_index_check;

ALTER TABLE wallpaper_requests
  ADD CONSTRAINT wallpaper_requests_wallpaper_index_check
  CHECK (wallpaper_index BETWEEN 1 AND 10);

CREATE OR REPLACE FUNCTION public.request_public_wallpaper(
  p_conversation_id uuid,
  p_index integer
)
RETURNS text
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  conv record;
  my_role text;
begin

  if p_index < 1 or p_index > 10 then
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
$function$;
