-- Расширяем CHECK в focus_commands.command_type, разрешая значения,
-- которые отправляет cron-evaluator расписаний:
--   - 'schedule_started' — cron обнаружил начало активного окна.
--   - 'schedule_ended'   — cron обнаружил конец активного окна.
-- До этой миграции вставка таких команд падала с 23514, исключение проглатывалось
-- блоком catch в cronEvaluateBlockSchedules, и пуш ребёнку не уходил.

ALTER TABLE public.focus_commands
    DROP CONSTRAINT IF EXISTS focus_commands_command_type_check;

ALTER TABLE public.focus_commands
    ADD CONSTRAINT focus_commands_command_type_check
    CHECK (command_type = ANY (ARRAY[
        'start_focus'::text,
        'end_focus'::text,
        'reset_earned_balance'::text,
        'add_earned_seconds'::text,
        'request_location'::text,
        'schedules_updated'::text,
        'schedule_started'::text,
        'schedule_ended'::text
    ]));
