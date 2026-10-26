# RevenueCat — ParentalControl

## Подключение

Официальный MCP: `https://mcp.revenuecat.ai/mcp`. В Codex подключён через OAuth.
Секретные ключи не добавлять в приложение, репозиторий или документацию.
В SDK используется только публичный ключ iOS-приложения.

## Проверенная конфигурация на 20 октября 2026

- Проект: `proj77ee7cb3` — **ParentalControl**.
- iOS-приложение: `app09b71b22ed`, bundle ID `mycompny.ParentalControl`.
- Настройки: https://app.revenuecat.com/projects/77ee7cb3/apps/app09b71b22ed
- Публичный SDK key: `appl_KrCdjMXWpMntCfiZHePfqlqHZyC`.
- Entitlement: `ParentalControl Pro` (`entl9fb6907f37`).
- Текущее offering: `default` (`ofrng9cc184c323`).
- Test Store оставлен без изменений и не используется приложением.

| План | Product ID в Apple | Product ID в RevenueCat | Пакет |
| --- | --- | --- | --- |
| Год | `mycompny.ParentalControl.pro.annual` | `prodff545d5d7b` | `$rc_annual` |
| Месяц | `mycompny.ParentalControl.pro.monthly` | `prodef86c9af44` | `$rc_monthly` |
| Навсегда | `mycompny.ParentalControl.pro.lifetime` | `prod2046b253a9` | `$rc_lifetime` |

Все три продукта связаны с общим entitlement. Год и месяц имеют тип
`subscription`; навсегда — `non_consumable`, без автопродления.

Проверены цены США: год $12.99 с бесплатными 3 днями, месяц $1.99,
навсегда $19.99. Для каждого товара подтверждены 175 цен и 175 доступных
территорий. Trial THREE_DAYS включён во всех 175 территориях только у года.
Пользователь подтвердил страны и пересчёт Apple в местные валюты.

После замены пользователем App Store Connect API key в RevenueCat план
`c3b2d814-2a0e-40ea-92ed-2d4c9388c676` успешно завершился `applied`;
все три элемента — `applied`. Ранее применение останавливалось из-за роли
Marketing старого ключа. Новые товары вместо существующих не создавались:

- группа `22497387` — ParentalControl Pro;
- год `6824998872` (ONE_YEAR);
- месяц `6824998642` (ONE_MONTH);
- навсегда `6824998873` (NON_CONSUMABLE).

Цены, availability, локализации en-US/ru и review information сохранены.
Год и месяц — `READY_TO_SUBMIT`. Навсегда пока `MISSING_METADATA`:
локализации и цены присутствуют, review screenshot имеет состояние
`UPLOAD_COMPLETE`, но imageAsset пока 0×0 и без URL. Возможна задержка
обработки; причину общего статуса Apple однозначно не сообщает.
Товары не отправлялись на проверку. Другие локали метаданных покупок не добавлены.
Review screenshots — согласованные временные пустые заглушки; перед ревью
обязательно заменить их реальным скриншотом готового пейвола.

После нажатия пользователем «Apply in App Store Connect» прямой Apple API
подтвердил настроенные App Store Server Notifications **V2** для Production
и Sandbox. Фактическую доставку событий ещё нужно проверить тестовой покупкой.

## Что осталось

1. Перепроверить статус «Навсегда» после обработки метаданных Apple.
2. Год и месяц — в одной группе, но нужно выровнять уровни, поскольку
   они дают одинаковый доступ. Сейчас Apple возвращает groupLevel 1 для года и 2 для месяца;
   перед тестированием переключения планов выровнять уровни.
3. Проверить фактическую доставку App Store Server Notifications в RevenueCat.
4. Заменить review screenshot настоящим изображением пейвола, уточнить review
   notes и определить платные функции перед отправкой на проверку.
5. Проверить загрузку offering, sandbox-покупки всех планов, восстановление,
   отмену, eligibility trial и передачу статуса родителя.

Пейвол и SubscriptionService обновлены под год/месяц/навсегда. Цены из StoreKit,
trial показывается только при подтверждённой eligibility и бесплатном вводном
периоде ровно 3 дня. Закрытие без задержки, восстановление и ссылки доступны,
фиктивная скидка удалена. Тексты обновлены во всех 21 локализации приложения.
Владельцу lifetime не предлагается повторная покупка.

Пока `SubscriptionConfig.developmentForceProUnlocked = true`: ограничения
не включались. Переключение SDK key вступит в силу после новой сборки.

## Проверки

- `node Tests/Localization/validate.cjs`
- `node Tests/Paywall/validate.cjs`
- `Tests/Paywall/main.swift` вместе с `RevenueCatConfig.swift`: проверка каталога
  и правил отображения trial (без сети и StoreKit).
- `Tests/Analytics/main.swift` вместе с `AnalyticsSchema.swift`.
- `node Tests/Analytics/validate.cjs`

Сборка без подписи не заменяет тестирование покупок на Sandbox/TestFlight.

## Изоляция проектов

`proj35cefec3` принадлежит **ScreenBlocker**, несмотря на старую ошибочную подпись
в коде. Не использовать его ключи и не менять его товары. Пользователей и покупки
между проектами автоматически не переносили.

## Документация

- [MCP](https://www.revenuecat.com/docs/tools/mcp/setup)
- [App Store Connect API key](https://www.revenuecat.com/docs/service-credentials/itunesconnect-app-specific-shared-secret/app-store-connect-api-key-configuration)
- [In-App Purchase key](https://www.revenuecat.com/docs/service-credentials/itunesconnect-app-specific-shared-secret/in-app-purchase-key-configuration)
