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
