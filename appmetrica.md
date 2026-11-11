# События AppMetrica — ParentalControl

Схема 5 · 11 ноября 2026 · 51 событие. «—» означает отсутствие параметров.

## Обозначения параметров

- `result` — результат: `success` — успешно, `failed` — ошибка, `cancelled` — отмена/прерывание, `timeout` — истекло ожидание, `unavailable` — недоступно. Особые значения указаны в таблицах.
- `role` — роль: `parent` — родитель, `child` — ребёнок, `unselected` — ещё не выбрана. В онбординге — роль показываемого сценария.
- `mode` — запуск онбординга: `first_launch` — первоначальная настройка, `replay` — повторный просмотр.
- `permission` — разрешение: `notifications` — уведомления, `screenTime` — Экранное время, `location` — местоположение.
- `true` / `false` — да / нет.

## Онбординг и разрешения

| Событие | Что показывает | Параметры |
|---|---|---|
| `role_selected` | Выбор роли телефона | `role` |
| `onboarding_flow_shown` | Показ онбординга | `mode`, `role` |
| `onboarding_step_shown` | Показ шага, включая возврат назад | `step` — шаг; `mode`, `role` |
| `onboarding_step_continue` | Продолжение с текущего шага | `step`; `ready` — выполнены условия шага; `role` |
| `onboarding_closed` | Завершение последнего шага онбординга | `mode`, `role` |
| `onboarding_share_app` | Открытие «Поделиться приложением» при настройке | — |
| `onboarding_permission_request` | Запрос разрешения из онбординга | `permission`, `role` |
| `permission_request_result` | Результат запроса разрешения | `permission`; `granted` — разрешение получено; для геолокации — доступ «Всегда» |

`step`: `parentIntro` / `childIntro` — знакомство для родителя / ребёнка; `install` — установка на второй телефон; `notifications` — уведомления; `screenTime` — Экранное время; `location` — геолокация; `pairing` — связь устройств; `pin` — PIN; `apps` — выбор приложений; `protection` — защита от удаления; `limit` — дневной лимит; `finish` — завершение.

## Связь устройств и родительский режим

| Событие | Что показывает | Параметры |
|---|---|---|
| `pairing_code_request` | Результат создания кода связи | `result`: `success` / `failed` |
| `pairing_join` | Результат присоединения по коду | `result`: `success` / `failed` |
| `devices_unlink` | Результат отвязки устройств | `result`: `success` / `failed` |
| `parent_mode_enter` | Результат входа по PIN | `result`: `success` — вход выполнен; `wrong_pin` — неверный PIN; `locked_out` — временно запрещены попытки; `not_configured` — PIN не задан; `unavailable` — проверка недоступна |
| `parent_mode_exit_tap` | Нажатие выхода из родительского режима | — |
| `parent_pin_change` | Ответ сервера на изменение PIN | `action`: `set` — установить/изменить, `clear` — удалить; `result`: `success` / `failed` |

## Навигация и главный экран

| Событие | Что показывает | Параметры |
|---|---|---|
| `main_tab_select` | Переход на вкладку, включая программный | `tab`: `home` — главная, `tasks` — задания, `schedule` — расписание, `map` — карта, `statistics` — статистика, `blocklist` — список блокировки, `settings` — настройки, `parentEntry` — вход родителя |
| `dashboard_pairing_connect_tap` | Нажатие подключения устройств на главной | — |
| `dashboard_pro_badge_tap` | Нажатие Premium на главной | — |

## Блокировка и дневной лимит

| Событие | Что показывает | Параметры |
|---|---|---|
| `blocklist_pick_apps_tap` | Открытие выбора отслеживаемых приложений | — |
| `blocklist_picker_dismissed` | Закрытие выбора приложений | `apps_count` — число приложений; `categories_count` — категорий; `domains_count` — доменов. Если изменение запрещено доступом: вместо счётчиков `action=blocked_limit` |
| `blocklist_manual_block` | Ручное переключение блокировки на телефоне ребёнка | `action`: `block` — блокировать, `unblock` — разблокировать |
| `remote_block_request` | Родитель отправляет блокировку/разблокировку | `action`: `block` / `unblock` |
| `remote_block_result` | Результат ожидания выполнения команды | `action`: `block` / `unblock`; `result`: `success` / `failed` / `timeout` / `cancelled` |
| `daily_budget_saved` | Сервер принял изменение лимита или времени | `kind`: `limit` — дневной лимит, `adjustment` — добавление/снятие времени; `minutes` — заданное значение в минутах, отрицательное для снятия; только для `limit`: `limit_mode` — `every_day` (единый лимит) / `weekdays` (по дням недели). Для анализа величины дневного лимита: `kind=limit`, `limit_mode=every_day` |
| `daily_budget_save_failed` | Ошибка сохранения лимита или времени | `kind`: `limit` / `adjustment` |

`remote_block_result.success` — подтверждено состояние ребёнка; `timeout` не исключает более позднего выполнения. `daily_budget_saved` подтверждает сохранение на сервере, а не применение на телефоне. Счётчики выбора не содержат названий приложений.

Начиная со схемы 5 время в `daily_budget_saved` передаётся как `minutes`. Старые события с `seconds` остаются без изменений; значения семи отдельных дней не передаются.

## Расписание и задания

| Событие | Что показывает | Параметры |
|---|---|---|
| `schedule_change` | Локальное изменение расписания | `action`: `save` — сохранить, `toggle` — включить/выключить, `delete` — удалить; `enabled` — включено (для save/toggle); `is_new` — новое расписание (для save); `title` — сохранённое название (только save, включая шаблоны) |
| `schedule_sync_result` | Ответ сервера на изменение расписания | `action`: `save` / `delete`; `result`: `success` / `failed` |
| `task_action` | Ответ сервера на действие с заданием | `action`: `create` — создать, `edit` — изменить, `delete` — удалить, `submit` — отправить на проверку, `approve` — подтвердить; `result`: `success` / `failed`; `title` — название из ответа сервера (только create/edit + success) |

`title` — реальный текст названия: без пробелов по краям, до 200 символов; кириллица и emoji сохраняются. Пустые названия не передаются. Описания заданий не отправляются. Названия поступают только при новых сохранениях в обновлённой сборке, без выгрузки старых записей.

## Карта и статистика

| Событие | Что показывает | Параметры |
|---|---|---|
| `location_request` | Начало запроса местоположения, кнопкой или автоматически при входе | — |
| `location_request_result` | Результат запроса; успех — получена свежая подходящая точка | `result`: `success` / `failed` / `timeout` / `unavailable` / `cancelled` |
| `statistics_calendar_open` | Открытие календаря статистики | — |
| `statistics_day_select` | Изменение выбранного дня | — |
| `statistics_summary_open` | Открытие сводки статистики | — |

## Настройки и защита от удаления

| Событие | Что показывает | Параметры |
|---|---|---|
| `removal_protection_open` | Открытие настройки защиты | `source`: `settings` — настройки, `onboarding` — онбординг |
| `removal_protection_enable` | Результат включения защиты | `result`: `success` / `failed` |
| `removal_protection_disable` | Успешное отключение защиты | — |
| `settings_premium_tap` | Нажатие строки подписки | — |
| `settings_language_tap` | Переход в системные настройки языка | — |
| `settings_permissions_open` | Открытие диагностики разрешений, только Debug | — |
| `settings_pin_change_tap` | Открытие изменения PIN | — |
| `settings_pin_clear_tap` | Нажатие удаления PIN | — |
| `settings_pin_set_tap` | Открытие установки PIN | — |
| `settings_onboarding_replay_tap` | Нажатие повторного просмотра онбординга | — |
| `settings_rate_app_tap` | Переход к оценке приложения | — |
| `settings_share_app_tap` | Открытие «Поделиться» | — |
| `settings_feedback_tap` | Нажатие обратной связи | — |

## Пейвол, покупка и восстановление

| Событие | Что показывает | Параметры |
|---|---|---|
| `paywall_open` | Показ пейвола | `source`: `settings` — настройки, `dashboard_badge` — Premium на главной, `limited_feature` — закрытая функция |
| `paywall_cta_tap` | Нажатие основной кнопки пейвола | `cta_type`: `continue` — продолжить, `start_trial` — начать пробный период (текст кнопки, не подтверждение триала) |
| `purchase_started` | Начало покупки | `plan`: `monthly` — месяц, `annual` — год, `lifetime` — навсегда, `other` — другой тариф |
| `purchase_result` | Результат покупки | `plan` — тариф; `result`: `success` / `failed` / `cancelled` / `pending_verification` — ожидается подтверждение сервером |
| `restore_started` | Начало восстановления покупок | — |
| `restore_result` | Результат восстановления | `result`: `restored` — восстановлено, `no_active_subscription` — активной покупки нет, `failed` — ошибка, `pending_verification` — ожидается подтверждение сервером |

## Коротко об отчётах

- Модель телефона, iOS и версия приложения — технические данные SDK, не параметры из таблиц. ID семьи не передаётся.
- Общие поля к событиям не добавляются. `app`, `schema_version`, `distribution` хранятся отдельно в окружении SDK. Debug пишет события только в консоль.
- Старые сборки и исторические события могут содержать прежние параметры. Нажатие кнопки не означает завершение действия; для результата смотрите соответствующее событие.
- Контракт: [AnalyticsSchema.swift](ParentalControl/Analytics/AnalyticsSchema.swift). Проверка каталога: `node Tests/Analytics/validate.cjs`.
