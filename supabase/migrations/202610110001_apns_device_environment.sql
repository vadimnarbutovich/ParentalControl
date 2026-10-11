-- Additive: existing tokens stay valid, unknown environments are learned on APNs acceptance.
ALTER TABLE public.devices ADD COLUMN apns_environment text
  CHECK (apns_environment IN ('sandbox', 'production'));

CREATE INDEX devices_apns_token_idx ON public.devices (apns_token)
  WHERE apns_token IS NOT NULL;

-- Atomic registration: an old client must not erase a learned environment when
-- refreshing the same token. A changed token must never inherit the old environment.
CREATE FUNCTION public.pc_register_apns_token(
  p_device_id uuid, p_token text, p_environment text DEFAULT NULL
) RETURNS void
LANGUAGE plpgsql SECURITY INVOKER SET search_path = '' AS $$
BEGIN
  IF p_token IS NULL OR p_token !~ '^[0-9a-f]+$' OR length(p_token) % 2 <> 0
     OR length(p_token) > 1024 THEN
    RAISE EXCEPTION 'Invalid APNs token';
  END IF;
  IF p_environment IS NOT NULL AND p_environment NOT IN ('sandbox', 'production') THEN
    RAISE EXCEPTION 'Invalid APNs environment';
  END IF;
  UPDATE public.devices
  SET apns_environment = CASE
        WHEN p_environment IS NOT NULL THEN p_environment
        WHEN apns_token = p_token THEN apns_environment
        ELSE NULL END,
      apns_token = p_token
  WHERE id = p_device_id;
END;
$$;
REVOKE ALL ON FUNCTION public.pc_register_apns_token(uuid, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.pc_register_apns_token(uuid, text, text) TO service_role;
