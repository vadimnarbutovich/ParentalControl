-- Fresh destination project only; not an incremental migration for the old project.
-- Explicit backend-only policies; clients still have no table grants.
CREATE POLICY backend_only ON public."child_location_state" FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY backend_only ON public."child_runtime_state" FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY backend_only ON public."daily_stats_snapshots" FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY backend_only ON public."devices" FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY backend_only ON public."families" FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY backend_only ON public."family_block_schedules" FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY backend_only ON public."family_child_tasks" FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY backend_only ON public."family_focus_desired_state" FOR ALL TO service_role USING (true) WITH CHECK (true);
CREATE POLICY backend_only ON public."focus_commands" FOR ALL TO service_role USING (true) WITH CHECK (true);
