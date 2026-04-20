# Yandex AppMetrica — ParentalControl

## 1) Подключение

1. Консоль: https://appmetrica.yandex.ru — приложение iOS ParentalControl, API Key.
2. **SPM:** `https://github.com/appmetrica/appmetrica-sdk-ios.git`, продукт `AppMetricaCore`, таргет `ParentalControl`.
3. **Ключ:** константа `metricaAPIKey` в [`ParentalControl/Analytics/AppAnalytics.swift`](ParentalControl/Analytics/AppAnalytics.swift) (как в HabitsTracker — `AppMetricaConfiguration(apiKey:)` в коде).
4. Активация: `AppAnalytics.activateMetricaIfNeeded()` вызывается один раз при появлении корня (`ParentalControlApp` → `ContentView.onAppear`).
5. Отправка событий: `AppAnalytics.report(_:parameters:)` → `AppMetrica.reportEvent`.

## 2) События и параметры

### Нижняя панель (Tab bar)

- `main_tab_select` — пользователь переключил вкладку
  - `tab`: `home` | `statistics` | `blocklist` | `settings` (соответствует Главная, Статистика, Блокировка, Настройки)

### Главный экран (дашборд)

- `dashboard_earn_card_tap` — тап по карточке в блоке «Заработать минуты`
  - `kind`: `steps` | `squat` | `pushup`
- `dashboard_focus_control_tap` — старт/стоп фокусировки
  - `action`: `start` | `end`
  - при `start`: `duration_minutes`: Int (выбранная длительность)
- `dashboard_pro_badge_tap` — тап по бейджу Pro (до открытия paywall)

### Статистика

- `statistics_calendar_open` — кнопка календаря в шапке
- `statistics_day_chip_tap` — тап по дню в полоске недели
  - `date_key`: String, `yyyy-MM-dd` (start of day, текущий календарь)
- `statistics_segment_tap` — переключение «Активность» / «Использование»
  - `segment`: `activity` | `app_usage`

### Список блокировки

- `blocklist_pick_apps_tap` — «Выбрать приложения»
- `blocklist_picker_dismissed` — закрытие системного пикера (без имён приложений)
  - `apps_count`, `categories_count`, `domains_count`: Int
- `blocklist_monitoring_slide` — жест слайдера мониторинга
  - `action`: `pause` | `resume`

### Настройки

- `settings_premium_tap` — строка премиума / разблокировки
- `settings_conversion_open` — «Количество упражнений за минуту»
- `settings_midnight_reset_toggle` — свитч «Сброс баланса в полночь»
  - `enabled`: Bool
- `settings_onboarding_replay_tap` — показать онбординг снова
- `settings_feedback_tap` — обратная связь (почта)
- `settings_rate_app_tap` — оценить в App Store
- `settings_share_app_tap` — поделиться приложением
- `settings_permissions_open` — открытие листа разрешений (**только DEBUG**)

### Лист конверсии (внутри настроек)

- `conversion_apply_defaults_tap` — «Значения по умолчанию»
- `conversion_save_tap` — «Сохранить»
  - `valid`: Bool (все три поля распарсились как положительные целые)
  - при наличии: `steps_per_minute`, `squats_per_minute`, `pushups_per_minute`: Int

### Paywall

- `paywall_open` — экран подписки показан
  - `source`: String — см. `PaywallOpenSource` (`settings`, `dashboard_badge`, `limited_feature`)
- `paywall_cta_tap` — основная кнопка покупки
  - `cta_type`: `continue` | `start_trial` (совпадает с подписью CTA: trial при weekly + introductory offer)

### Онбординг

- `onboarding_flow_shown` — появление потока
  - `mode`: `first_launch` | `replay`
- `onboarding_closed` — пользователь завершил онбординг (нижняя кнопка «Начнём» на финале или картинка ButtonGo; при повторном просмотре из настроек — закрытие реплея)
  - `mode`: `first_launch` | `replay`

## 3) TODO / расширение

- **`paywall_open.source`:** при добавлении ограничений для бесплатных пользователей завести новые значения источника (и кейсы в `PaywallOpenSource`), передавать их при открытии paywall с гейтов. Сейчас заглушка: `limited_feature`.
