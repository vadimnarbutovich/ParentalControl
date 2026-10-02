-- APNs credentials are provisioned separately in Vault; never put private keys in migrations.
CREATE OR REPLACE FUNCTION public.pc_get_apns_config()
RETURNS jsonb
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = ''
AS $$
  SELECT decrypted_secret::jsonb FROM vault.decrypted_secrets WHERE name = 'pc_apns_config';
$$;
REVOKE ALL ON FUNCTION public.pc_get_apns_config() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pc_get_apns_config() TO service_role;
