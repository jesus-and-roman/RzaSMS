-- Autoriser un utilisateur connecté à créer une conversation
-- dont il est lui-même le créateur.

DROP POLICY IF EXISTS "users_can_create_conversations"
ON public.conversations;

CREATE POLICY "users_can_create_conversations"
ON public.conversations
FOR INSERT
TO authenticated
WITH CHECK (
  creator_id = auth.uid()
);

ALTER TABLE public.conversations ENABLE ROW LEVEL SECURITY;
