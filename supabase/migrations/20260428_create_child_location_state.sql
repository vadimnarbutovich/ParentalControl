-- Stores the latest known location of the paired child device for each family.
-- One row per family. Updated by the child device after it receives a `request_location`
-- alert push. Read by the parent device when it opens the Map tab or taps "Refresh location".

CREATE TABLE IF NOT EXISTS public.child_location_state (
    family_id uuid NOT NULL,
    child_device_id uuid NOT NULL,
    latitude double precision NOT NULL,
    longitude double precision NOT NULL,
    horizontal_accuracy double precision,
    captured_at timestamptz NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (family_id),
    CONSTRAINT child_location_state_family_fkey FOREIGN KEY (family_id)
        REFERENCES public.families(id) ON DELETE CASCADE,
    CONSTRAINT child_location_state_child_fkey FOREIGN KEY (child_device_id)
        REFERENCES public.devices(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS child_location_state_child_device_idx
    ON public.child_location_state (child_device_id);

ALTER TABLE public.child_location_state ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS service_role_full_access_location ON public.child_location_state;
CREATE POLICY service_role_full_access_location
    ON public.child_location_state
    FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);
