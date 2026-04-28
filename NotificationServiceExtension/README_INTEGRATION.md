# Notification Service Extension — гайд по интеграции

Этот таргет нужен, чтобы push с командой от родителя сохранялся в App Group **до** того,
как iOS покажет баннер. Если основное приложение спит/выгружено, NSE всё равно успевает
записать команду в общую очередь, а основное приложение применит её при следующем
пробуждении (push, scenePhase active, BGAppRefresh).

Папка `NotificationServiceExtension/` уже содержит готовые файлы:

- `NotificationService.swift` — основная логика (захват команды → запись в App Group).
- `Info.plist` — точка входа NSE (`com.apple.usernotifications.service`).
- `NotificationServiceExtension.entitlements` — App Group `group.mycompny.parentalcontrol`.

Эти файлы НЕ добавятся в проект автоматически — нужно создать таргет в Xcode и привязать
к нему уже существующие файлы. Ниже — пошаговая инструкция.

---

## Шаг 1. Создать новый target

1. Открой `ParentalControl.xcodeproj` в Xcode.
2. В навигаторе выбери проект `ParentalControl` → жми `+` внизу списка таргетов
   (`File → New → Target...`).
3. В шаблонах: **iOS → Notification Service Extension** → `Next`.
4. Параметры:
   - **Product Name:** `NotificationServiceExtension`
   - **Team:** твой обычный team (тот же что у основного таргета).
   - **Organization Identifier:** оставь твой (бандл получится `mycompny.parentalcontrol.NotificationServiceExtension` — имя должно совпадать со схемой основного бандла).
   - **Bundle Identifier:** должен быть `<основной bundle id>.NotificationServiceExtension`.
     Например, если основной — `mycompny.parentalcontrol`, то NSE — `mycompny.parentalcontrol.NotificationServiceExtension`.
   - **Language:** Swift.
   - **Embed in Application:** `ParentalControl`.
5. Нажми `Finish`. Если Xcode спросит «Activate scheme?» — `Activate`.

Xcode создаст:
- Новую группу `NotificationServiceExtension/` с `NotificationService.swift` и `Info.plist`.
- Новый target `NotificationServiceExtension`.

## Шаг 2. Заменить сгенерированные файлы на готовые

Готовые файлы лежат в `NotificationServiceExtension/` рядом с проектом
(уровень `ParentalControl.xcodeproj/`). Xcode по умолчанию положит свою группу
тоже в эту папку, либо рядом — нужно убедиться что используются НАШИ файлы.

Самый чистый путь:

1. В Finder найди папку, которую сделал Xcode (если она не совпадает с
   `/Users/narbutovich/Vadim/SwiftProject/ParentalControl/NotificationServiceExtension/`),
   и **удали оттуда** сгенерированные `NotificationService.swift` и `Info.plist`.
2. В Xcode в группе `NotificationServiceExtension` правой кнопкой по сгенерированным
   `NotificationService.swift` и `Info.plist` → `Delete` → `Move to Trash`.
3. Правой кнопкой по группе `NotificationServiceExtension` → `Add Files to "ParentalControl"...`
4. Выбери из `NotificationServiceExtension/`:
   - `NotificationService.swift`
   - `Info.plist`
   - `NotificationServiceExtension.entitlements`
5. В диалоге:
   - **Copy items if needed:** ВЫКЛЮЧЕНО (файлы уже на месте).
   - **Create groups:** включено.
   - **Add to targets:** ТОЛЬКО `NotificationServiceExtension` (не основной таргет!).
6. Нажми `Add`.

## Шаг 3. Настроить target NotificationServiceExtension

1. Выбери `NotificationServiceExtension` target → вкладка `Signing & Capabilities`.
2. **Signing:**
   - Включи `Automatically manage signing` (как у основного таргета).
   - Выбери Team.
3. **Capabilities (`+ Capability`):**
   - **App Groups** → выбери `group.mycompny.parentalcontrol`
     (тот же, что у основного таргета и других extensions).
4. Перейди на вкладку `Build Settings`:
   - Поиск `Code Signing Entitlements` → значение
     `NotificationServiceExtension/NotificationServiceExtension.entitlements`.
   - Поиск `Info.plist File` → значение `NotificationServiceExtension/Info.plist`.
   - Поиск `iOS Deployment Target` → выставь то же, что у основного таргета (например 16.0+).
   - Поиск `Swift Language Version` → тот же, что у основного.
5. Перейди на вкладку `General` → `Frameworks and Libraries` — должно быть пусто
   (или только `UserNotifications.framework`, который Xcode добавит сам).

## Шаг 4. Проверить Embed Foundation Extensions

1. Выбери основной target `ParentalControl` → `General` → `Frameworks, Libraries, and Embedded Content`
   (или `Build Phases → Embed Foundation Extensions` для extensions).
2. Убедись, что `NotificationServiceExtension.appex` есть в списке embedded (Xcode добавляет автоматически).

## Шаг 5. Проверить provisioning

1. Меню `Xcode → Settings → Accounts → твой Apple ID → Manage Certificates / Profiles`.
2. App Store Connect → создай новый App ID для NSE (если используется ручной provisioning):
   `<основной bundle id>.NotificationServiceExtension`.
3. Provisioning profile должен включать capability **App Groups**.
4. Если используется automatic signing — Xcode сделает это сам.

## Шаг 6. Проверить, что бэкенд шлёт mutable-content

В `supabase/functions/parental-control-sync/index.ts` и
`supabase/functions/parental-control-balance-sync/index.ts` уже стоят:
```
"apns-push-type": "alert",
"apns-priority": "10",
"mutable-content": 1,
"content-available": 1,
"interruption-level": "time-sensitive"
```
Без `mutable-content: 1` NSE не запустится — это уже сделано.

## Шаг 7. Билд + тест

1. Подключи устройство ребёнка (NSE НЕ работает в симуляторе для удалённых push'ей —
   работает в обычной TestFlight/Dev сборке).
2. Build & Run основной target `ParentalControl` на устройстве.
3. На устройстве родителя нажми `Включить блокировку` → должен прийти push на ребёнка.
4. **Тест надёжности**: оставь телефон ребёнка с заблокированным экраном на 30+ минут
   (без зарядки — критично для активации Low Power режима push throttling).
5. Из родителя отправь команду → push должен прийти и блокировка должна включиться
   даже без касания экрана.

## Как проверить, что NSE действительно отрабатывает

Самый простой способ — добавить временно отладочный print в `NotificationService.didReceive`,
например изменить заголовок:

```swift
mutable.title = "[NSE] " + (mutable.title.isEmpty ? "Команда" : mutable.title)
```

Если заголовок в push приходит с префиксом `[NSE]` — extension точно срабатывает.
После проверки префикс убери.

Альтернатива — `Console.app` на Mac → найти процесс `NotificationServiceExtension`
и смотреть его логи (понадобится подключенное устройство и допуск разработчика).

## Чек-лист после интеграции

- [ ] Target `NotificationServiceExtension` создан и собирается без ошибок.
- [ ] App Group `group.mycompny.parentalcontrol` подключён.
- [ ] Bundle ID NSE — `<основной>.NotificationServiceExtension`.
- [ ] `mutable-content: 1` приходит в payload (см. бэкенд — уже настроено).
- [ ] При получении push на устройстве ребёнка с долгим idle команда применяется.
- [ ] При свежем holding-чарже отправь 5 команд подряд — все 5 ack'нулись на бэкенде
      (проверь в Supabase таблицу команд: `status = applied`).

## Известные ограничения

- В iOS Simulator реальные удалённые push не дойдут (только локальные через `xcrun simctl`).
  Тестировать ОБЯЗАТЕЛЬНО на реальном устройстве.
- В Low Power Mode (зарядка <20%) Apple может ещё сильнее throttle'ить push, но
  alert-приоритет 10 обходит это в подавляющем большинстве случаев.
- Если пользователь принудительно «свайпом вверх» закрыл приложение из multitasking —
  iOS может задерживать push до первого ручного открытия. Это уже не наша зона.
  Чтобы такого не происходило, рекомендуется в UI добавить экран-объяснение, чтобы
  родитель НЕ закрывал приложение ребёнка свайпом.
