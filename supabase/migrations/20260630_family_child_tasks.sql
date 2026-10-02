-- Задания для ребёнка, синхронизируемые parent → child (по образцу family_block_schedules).
-- Разовые задания; фото-отчёт у нас НЕ хранится — ребёнок отправляет его родителю через
-- системный share sheet. Приложение ведёт только статус и награду во времени.

CREATE TABLE IF NOT EXISTS public.family_child_tasks (
    id uuid PRIMARY KEY,
    family_id uuid NOT NULL REFERENCES public.families(id) ON DELETE CASCADE,
    title text NOT NULL,
    details text NOT NULL DEFAULT '',
    reward_seconds integer NOT NULL DEFAULT 0,
    status text NOT NULL DEFAULT 'pending'
        CHECK (status = ANY (ARRAY['pending'::text, 'submitted'::text, 'approved'::text])),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    submitted_at timestamptz,
    approved_at timestamptz,
    deleted_at timestamptz
);

CREATE INDEX IF NOT EXISTS family_child_tasks_family_id_idx
    ON public.family_child_tasks (family_id);

ALTER TABLE public.family_child_tasks ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS service_role_full_access_family_child_tasks ON public.family_child_tasks;
CREATE POLICY service_role_full_access_family_child_tasks
    ON public.family_child_tasks
    FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

-- Пассивная команда 'tasks_updated' (как 'schedules_updated'): просим другое устройство
-- перетянуть список заданий.
ALTER TABLE public.focus_commands
    DROP CONSTRAINT IF EXISTS focus_commands_command_type_check;

ALTER TABLE public.focus_commands
    ADD CONSTRAINT focus_commands_command_type_check
    CHECK (command_type = ANY (ARRAY[
        'start_focus'::text,
        'end_focus'::text,
        'reset_earned_balance'::text,
        'add_earned_seconds'::text,
        'subtract_earned_seconds'::text,
        'request_location'::text,
        'schedules_updated'::text,
        'schedule_started'::text,
        'schedule_ended'::text,
        'tasks_updated'::text
    ]));
