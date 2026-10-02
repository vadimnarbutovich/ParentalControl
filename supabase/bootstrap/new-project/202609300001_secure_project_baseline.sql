-- Fresh destination project only; not an incremental migration for the old project.
-- Baseline copied from the development project; no user records or secrets.
SET search_path = public, extensions, pg_catalog;
CREATE EXTENSION IF NOT EXISTS pg_net WITH SCHEMA extensions;
CREATE EXTENSION IF NOT EXISTS pg_cron WITH SCHEMA pg_catalog;

CREATE TABLE public."child_location_state" (
  "family_id" uuid NOT NULL,
  "child_device_id" uuid NOT NULL,
  "latitude" double precision NOT NULL,
  "longitude" double precision NOT NULL,
  "horizontal_accuracy" double precision,
  "captured_at" timestamp with time zone NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
CREATE TABLE public."child_runtime_state" (
  "family_id" uuid NOT NULL,
  "child_device_id" uuid NOT NULL,
  "is_focus_active" boolean DEFAULT false NOT NULL,
  "focus_ends_at" timestamp with time zone,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "available_seconds" integer DEFAULT 0 NOT NULL
);
CREATE TABLE public."daily_stats_snapshots" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "family_id" uuid NOT NULL,
  "child_device_id" uuid NOT NULL,
  "day_start" date NOT NULL,
  "steps" integer DEFAULT 0 NOT NULL,
  "earned_seconds" integer DEFAULT 0 NOT NULL,
  "spent_seconds" integer DEFAULT 0 NOT NULL,
  "push_ups" integer DEFAULT 0 NOT NULL,
  "squats" integer DEFAULT 0 NOT NULL,
  "focus_session_total_seconds" integer DEFAULT 0 NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
CREATE TABLE public."devices" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "family_id" uuid,
  "install_id" text NOT NULL,
  "role" text NOT NULL,
  "device_secret" text NOT NULL,
  "apns_token" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
CREATE TABLE public."families" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "pairing_code" text NOT NULL,
  "status" text DEFAULT 'active'::text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "parent_pin_hash" text,
  "parent_pin_salt" text,
  "parent_pin_updated_at" timestamp with time zone,
  "parent_is_pro" boolean DEFAULT false NOT NULL,
  "parent_is_pro_updated_at" timestamp with time zone
);
CREATE TABLE public."family_block_schedules" (
  "id" uuid NOT NULL,
  "family_id" uuid NOT NULL,
  "name" text NOT NULL,
  "icon" text DEFAULT 'calendar'::text NOT NULL,
  "accent" text DEFAULT 'purple'::text NOT NULL,
  "start_hour" smallint NOT NULL,
  "start_minute" smallint NOT NULL,
  "end_hour" smallint NOT NULL,
  "end_minute" smallint NOT NULL,
  "weekdays" smallint[] NOT NULL,
  "is_enabled" boolean DEFAULT false NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "deleted_at" timestamp with time zone,
  "is_currently_active" boolean DEFAULT false NOT NULL,
  "last_state_change_at" timestamp with time zone,
  "timezone_identifier" text DEFAULT 'UTC'::text NOT NULL
);
CREATE TABLE public."family_child_tasks" (
  "id" uuid NOT NULL,
  "family_id" uuid NOT NULL,
  "title" text NOT NULL,
  "details" text DEFAULT ''::text NOT NULL,
  "reward_seconds" integer DEFAULT 0 NOT NULL,
  "status" text DEFAULT 'pending'::text NOT NULL,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "submitted_at" timestamp with time zone,
  "approved_at" timestamp with time zone,
  "deleted_at" timestamp with time zone
);
CREATE TABLE public."family_focus_desired_state" (
  "family_id" uuid NOT NULL,
  "should_focus_active" boolean DEFAULT false NOT NULL,
  "desired_duration_seconds" integer,
  "updated_by_device_id" uuid,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL
);
CREATE TABLE public."focus_commands" (
  "id" uuid DEFAULT gen_random_uuid() NOT NULL,
  "family_id" uuid NOT NULL,
  "requested_by_device_id" uuid NOT NULL,
  "target_device_id" uuid NOT NULL,
  "command_type" text NOT NULL,
  "duration_seconds" integer,
  "status" text DEFAULT 'queued'::text NOT NULL,
  "error_message" text,
  "created_at" timestamp with time zone DEFAULT now() NOT NULL,
  "updated_at" timestamp with time zone DEFAULT now() NOT NULL,
  "applied_at" timestamp with time zone,
  "retry_count" integer DEFAULT 0 NOT NULL,
  "last_push_attempt_at" timestamp with time zone,
  "intent_id" uuid,
  "expires_at" timestamp with time zone DEFAULT (now() + '00:10:00'::interval) NOT NULL
);
ALTER TABLE public."devices" ADD CONSTRAINT "devices_install_id_key" UNIQUE (install_id);
ALTER TABLE public."devices" ADD CONSTRAINT "devices_pkey" PRIMARY KEY (id);
ALTER TABLE public."devices" ADD CONSTRAINT "devices_role_check" CHECK ((role = ANY (ARRAY['parent'::text, 'child'::text])));
ALTER TABLE public."daily_stats_snapshots" ADD CONSTRAINT "daily_stats_snapshots_child_device_id_day_start_key" UNIQUE (child_device_id, day_start);
ALTER TABLE public."daily_stats_snapshots" ADD CONSTRAINT "daily_stats_snapshots_pkey" PRIMARY KEY (id);
ALTER TABLE public."family_focus_desired_state" ADD CONSTRAINT "family_focus_desired_state_pkey" PRIMARY KEY (family_id);
ALTER TABLE public."child_runtime_state" ADD CONSTRAINT "child_runtime_state_pkey" PRIMARY KEY (family_id);
ALTER TABLE public."family_block_schedules" ADD CONSTRAINT "family_block_schedules_end_hour_check" CHECK (((end_hour >= 0) AND (end_hour <= 23)));
ALTER TABLE public."family_block_schedules" ADD CONSTRAINT "family_block_schedules_end_minute_check" CHECK (((end_minute >= 0) AND (end_minute <= 59)));
ALTER TABLE public."family_block_schedules" ADD CONSTRAINT "family_block_schedules_pkey" PRIMARY KEY (id);
ALTER TABLE public."family_block_schedules" ADD CONSTRAINT "family_block_schedules_start_hour_check" CHECK (((start_hour >= 0) AND (start_hour <= 23)));
ALTER TABLE public."family_block_schedules" ADD CONSTRAINT "family_block_schedules_start_minute_check" CHECK (((start_minute >= 0) AND (start_minute <= 59)));
ALTER TABLE public."focus_commands" ADD CONSTRAINT "focus_commands_command_type_check" CHECK ((command_type = ANY (ARRAY['start_focus'::text, 'end_focus'::text, 'reset_earned_balance'::text, 'add_earned_seconds'::text, 'subtract_earned_seconds'::text, 'request_location'::text, 'schedules_updated'::text, 'schedule_started'::text, 'schedule_ended'::text, 'tasks_updated'::text])));
ALTER TABLE public."focus_commands" ADD CONSTRAINT "focus_commands_pkey" PRIMARY KEY (id);
ALTER TABLE public."focus_commands" ADD CONSTRAINT "focus_commands_status_check" CHECK ((status = ANY (ARRAY['queued'::text, 'sent'::text, 'delivered'::text, 'applied'::text, 'failed'::text])));
ALTER TABLE public."child_location_state" ADD CONSTRAINT "child_location_state_pkey" PRIMARY KEY (family_id);
ALTER TABLE public."families" ADD CONSTRAINT "families_pairing_code_key" UNIQUE (pairing_code);
ALTER TABLE public."families" ADD CONSTRAINT "families_pkey" PRIMARY KEY (id);
ALTER TABLE public."family_child_tasks" ADD CONSTRAINT "family_child_tasks_pkey" PRIMARY KEY (id);
ALTER TABLE public."family_child_tasks" ADD CONSTRAINT "family_child_tasks_status_check" CHECK ((status = ANY (ARRAY['pending'::text, 'submitted'::text, 'approved'::text])));
ALTER TABLE public."devices" ADD CONSTRAINT "devices_family_id_fkey" FOREIGN KEY (family_id) REFERENCES families(id) ON DELETE SET NULL;
ALTER TABLE public."daily_stats_snapshots" ADD CONSTRAINT "daily_stats_snapshots_child_device_id_fkey" FOREIGN KEY (child_device_id) REFERENCES devices(id) ON DELETE CASCADE;
ALTER TABLE public."daily_stats_snapshots" ADD CONSTRAINT "daily_stats_snapshots_family_id_fkey" FOREIGN KEY (family_id) REFERENCES families(id) ON DELETE CASCADE;
ALTER TABLE public."family_focus_desired_state" ADD CONSTRAINT "family_focus_desired_state_family_id_fkey" FOREIGN KEY (family_id) REFERENCES families(id) ON DELETE CASCADE;
ALTER TABLE public."family_focus_desired_state" ADD CONSTRAINT "family_focus_desired_state_updated_by_device_id_fkey" FOREIGN KEY (updated_by_device_id) REFERENCES devices(id) ON DELETE SET NULL;
ALTER TABLE public."child_runtime_state" ADD CONSTRAINT "child_runtime_state_child_device_id_fkey" FOREIGN KEY (child_device_id) REFERENCES devices(id) ON DELETE CASCADE;
ALTER TABLE public."child_runtime_state" ADD CONSTRAINT "child_runtime_state_family_id_fkey" FOREIGN KEY (family_id) REFERENCES families(id) ON DELETE CASCADE;
ALTER TABLE public."family_block_schedules" ADD CONSTRAINT "family_block_schedules_family_id_fkey" FOREIGN KEY (family_id) REFERENCES families(id) ON DELETE CASCADE;
ALTER TABLE public."focus_commands" ADD CONSTRAINT "focus_commands_family_id_fkey" FOREIGN KEY (family_id) REFERENCES families(id) ON DELETE CASCADE;
ALTER TABLE public."focus_commands" ADD CONSTRAINT "focus_commands_requested_by_device_id_fkey" FOREIGN KEY (requested_by_device_id) REFERENCES devices(id) ON DELETE CASCADE;
ALTER TABLE public."focus_commands" ADD CONSTRAINT "focus_commands_target_device_id_fkey" FOREIGN KEY (target_device_id) REFERENCES devices(id) ON DELETE CASCADE;
ALTER TABLE public."child_location_state" ADD CONSTRAINT "child_location_state_child_fkey" FOREIGN KEY (child_device_id) REFERENCES devices(id) ON DELETE CASCADE;
ALTER TABLE public."child_location_state" ADD CONSTRAINT "child_location_state_family_fkey" FOREIGN KEY (family_id) REFERENCES families(id) ON DELETE CASCADE;
ALTER TABLE public."family_child_tasks" ADD CONSTRAINT "family_child_tasks_family_id_fkey" FOREIGN KEY (family_id) REFERENCES families(id) ON DELETE CASCADE;
CREATE INDEX idx_devices_family_role ON public.devices USING btree (family_id, role);
CREATE INDEX idx_daily_stats_family_day ON public.daily_stats_snapshots USING btree (family_id, day_start DESC);
CREATE INDEX idx_family_focus_desired_state_updated_at ON public.family_focus_desired_state USING btree (updated_at DESC);
CREATE INDEX family_block_schedules_family_idx ON public.family_block_schedules USING btree (family_id) WHERE (deleted_at IS NULL);
CREATE INDEX family_block_schedules_family_id_idx ON public.family_block_schedules USING btree (family_id);
CREATE INDEX idx_focus_commands_target_status_created ON public.focus_commands USING btree (target_device_id, status, created_at DESC);
CREATE INDEX idx_focus_commands_retry_scan ON public.focus_commands USING btree (family_id, status, updated_at DESC, retry_count);
CREATE UNIQUE INDEX idx_focus_commands_parent_intent ON public.focus_commands USING btree (requested_by_device_id, intent_id) WHERE (intent_id IS NOT NULL);
CREATE INDEX idx_focus_commands_pending_expiry ON public.focus_commands USING btree (status, expires_at, updated_at DESC);
CREATE INDEX child_location_state_child_device_idx ON public.child_location_state USING btree (child_device_id);
CREATE INDEX family_child_tasks_family_id_idx ON public.family_child_tasks USING btree (family_id);

CREATE OR REPLACE FUNCTION public.set_updated_at()
 RETURNS trigger
 LANGUAGE plpgsql
AS $function$
begin
  new.updated_at = now();
  return new;
end;
$function$;
ALTER FUNCTION public."set_updated_at"() SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION public.replace_focus_command_atomic(p_family_id uuid, p_parent_device_id uuid, p_child_device_id uuid, p_command_type text, p_duration_seconds integer, p_intent_id uuid, p_has_token boolean)
 RETURNS TABLE(id uuid, family_id uuid, command_type text, duration_seconds integer, status text, created_at timestamp with time zone, updated_at timestamp with time zone, retry_count integer, last_push_attempt_at timestamp with time zone, error_message text, intent_id uuid, expires_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  existing public.focus_commands%rowtype;
  inserted public.focus_commands%rowtype;
begin
  if p_intent_id is not null then
    select c.* into existing
    from public.focus_commands as c
    where c.requested_by_device_id = p_parent_device_id
      and c.intent_id = p_intent_id
    order by c.created_at desc
    limit 1;

    if found then
      return query
      select
        existing.id,
        existing.family_id,
        existing.command_type,
        existing.duration_seconds,
        existing.status,
        existing.created_at,
        existing.updated_at,
        existing.retry_count,
        existing.last_push_attempt_at,
        existing.error_message,
        existing.intent_id,
        existing.expires_at;
      return;
    end if;
  end if;

  update public.focus_commands as c
  set status = 'failed',
      error_message = 'superseded_by_newer_command',
      updated_at = now()
  where c.family_id = p_family_id
    and c.target_device_id = p_child_device_id
    and c.status = any(array['queued', 'sent', 'delivered']);

  insert into public.focus_commands (
    family_id,
    requested_by_device_id,
    target_device_id,
    command_type,
    duration_seconds,
    status,
    error_message,
    retry_count,
    last_push_attempt_at,
    intent_id,
    expires_at
  )
  values (
    p_family_id,
    p_parent_device_id,
    p_child_device_id,
    p_command_type,
    p_duration_seconds,
    case when p_has_token then 'sent' else 'queued' end,
    case when p_has_token then null else 'Child APNs token missing' end,
    0,
    case when p_has_token then now() else null end,
    p_intent_id,
    now() + interval '10 minutes'
  )
  returning * into inserted;

  return query
  select
    inserted.id,
    inserted.family_id,
    inserted.command_type,
    inserted.duration_seconds,
    inserted.status,
    inserted.created_at,
    inserted.updated_at,
    inserted.retry_count,
    inserted.last_push_attempt_at,
    inserted.error_message,
    inserted.intent_id,
    inserted.expires_at;
end;
$function$;
ALTER FUNCTION public."replace_focus_command_atomic"(p_family_id uuid, p_parent_device_id uuid, p_child_device_id uuid, p_command_type text, p_duration_seconds integer, p_intent_id uuid, p_has_token boolean) SET search_path = public, pg_temp;

CREATE OR REPLACE FUNCTION public.cleanup_abandoned_families()
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
  linked_ttl   constant interval := interval '15 days';
  unpaired_ttl constant interval := interval '1 hour';
  doomed uuid[];
begin
  -- Собираем id брошенных семей по двум правилам.
  select array_agg(f.id) into doomed
  from families f
  where
    -- (1) несвязанные (нет child-устройства) старше 1 часа
    (
      not exists (select 1 from devices d where d.family_id = f.id and d.role = 'child')
      and greatest(
            f.created_at, f.updated_at,
            coalesce((select max(updated_at) from family_focus_desired_state x where x.family_id = f.id), 'epoch'::timestamptz)
          ) < now() - unpaired_ttl
    )
    or
    -- (2) связанные без активности >15 дней (по heartbeat-сигналам)
    (
      exists (select 1 from devices d where d.family_id = f.id and d.role = 'child')
      and greatest(
            f.created_at, f.updated_at,
            coalesce((select max(updated_at) from child_runtime_state       x where x.family_id = f.id), 'epoch'::timestamptz),
            coalesce((select max(updated_at) from daily_stats_snapshots     x where x.family_id = f.id), 'epoch'::timestamptz),
            coalesce((select max(updated_at) from family_focus_desired_state x where x.family_id = f.id), 'epoch'::timestamptz),
            coalesce((select max(updated_at) from child_location_state       x where x.family_id = f.id), 'epoch'::timestamptz)
          ) < now() - linked_ttl
    );

  if doomed is not null and array_length(doomed, 1) > 0 then
    -- Сначала явно удаляем device-строки этих семей (FK = SET NULL иначе оставил бы их «осиротевшими»,
    -- а триггер updated_at сбросил бы им возраст на «сейчас»).
    delete from devices where family_id = any(doomed);
    -- Затем сами семьи; зависимые таблицы уйдут по ON DELETE CASCADE.
    delete from families where id = any(doomed);
  end if;

  -- Дочистка ранее осиротевших устройств (family_id IS NULL) по реальному возрасту (created_at):
  -- updated_at ненадёжен (триггер бьёт его при SET NULL). Активный юзер переинициализируется при след.запуске.
  delete from devices d
  where d.family_id is null
    and d.created_at < now() - linked_ttl;
end;
$function$;
ALTER FUNCTION public."cleanup_abandoned_families"() SET search_path = public, pg_temp;
CREATE TRIGGER trg_families_updated_at BEFORE UPDATE ON public.families FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_devices_updated_at BEFORE UPDATE ON public.devices FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_focus_commands_updated_at BEFORE UPDATE ON public.focus_commands FOR EACH ROW EXECUTE FUNCTION set_updated_at();
CREATE TRIGGER trg_daily_stats_snapshots_updated_at BEFORE UPDATE ON public.daily_stats_snapshots FOR EACH ROW EXECUTE FUNCTION set_updated_at();
ALTER TABLE public."child_location_state" ENABLE ROW LEVEL SECURITY;
ALTER TABLE public."child_runtime_state" ENABLE ROW LEVEL SECURITY;
ALTER TABLE public."daily_stats_snapshots" ENABLE ROW LEVEL SECURITY;
ALTER TABLE public."devices" ENABLE ROW LEVEL SECURITY;
ALTER TABLE public."families" ENABLE ROW LEVEL SECURITY;
ALTER TABLE public."family_block_schedules" ENABLE ROW LEVEL SECURITY;
ALTER TABLE public."family_child_tasks" ENABLE ROW LEVEL SECURITY;
ALTER TABLE public."family_focus_desired_state" ENABLE ROW LEVEL SECURITY;
ALTER TABLE public."focus_commands" ENABLE ROW LEVEL SECURITY;

-- iOS uses authenticated Edge Functions, never direct Data API table access.
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC, anon, authenticated;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM PUBLIC, anon, authenticated;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC, anon, authenticated;
GRANT ALL ON ALL TABLES IN SCHEMA public TO service_role;
GRANT ALL ON ALL SEQUENCES IN SCHEMA public TO service_role;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO service_role;
REVOKE CREATE ON SCHEMA public FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON TABLES FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE ALL ON SEQUENCES FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON TABLES TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT ALL ON SEQUENCES TO service_role;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO service_role;
