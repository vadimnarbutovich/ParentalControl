-- Block schedules synced parent → child (applied via Device Activity on child).
-- Mirrors production schema when deploying via Supabase MCP / dashboard.

CREATE TABLE IF NOT EXISTS public.family_block_schedules (
    id uuid PRIMARY KEY,
    family_id uuid NOT NULL REFERENCES public.families(id) ON DELETE CASCADE,
    name text NOT NULL,
    icon text NOT NULL DEFAULT 'calendar',
    accent text NOT NULL DEFAULT 'purple',
    start_hour smallint NOT NULL,
    start_minute smallint NOT NULL,
    end_hour smallint NOT NULL,
    end_minute smallint NOT NULL,
    weekdays smallint[] NOT NULL,
    is_enabled boolean NOT NULL DEFAULT false,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    deleted_at timestamptz
);

CREATE INDEX IF NOT EXISTS family_block_schedules_family_id_idx
    ON public.family_block_schedules (family_id);

ALTER TABLE public.family_block_schedules ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS service_role_full_access_family_block_schedules ON public.family_block_schedules;
CREATE POLICY service_role_full_access_family_block_schedules
    ON public.family_block_schedules
    FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);
