# RevenueCat MCP в Cursor

## Файл `~/.cursor/mcp.json`

В корне Cursor добавлен сервер `revenuecat` рядом с существующими MCP. Замените в файле строку  
`YOUR_REVENUECAT_API_V2_SECRET_KEY` на **Secret API key v2** из [RevenueCat → Project → API keys](https://app.revenuecat.com/) (отдельный ключ для MCP, по желанию read-only).

URL сервера: `https://mcp.revenuecat.ai/mcp` — см. [документацию RevenueCat MCP](https://www.revenuecat.com/docs/tools/mcp/setup).

**Не коммить** `mcp.json` с реальным ключом в git.

## Как проверить, что MCP работает

1. Сохраните `~/.cursor/mcp.json` с **реальным** Bearer-токеном (формат: `Bearer sk_...`).
2. **Перезапустите Cursor** или откройте **Settings → MCP** и убедитесь, что сервер **revenuecat** в статусе подключён (зелёный / без ошибки).
3. В чате с агентом с включёнными MCP-инструментами попросите что-то вроде: «покажи проекты RevenueCat» / «список приложений в проекте» — если инструменты отвечают, MCP живой.
4. При ошибке авторизации проверьте, что ключ именно **API v2 secret**, а не публичный SDK key приложения.

Альтернатива для отладки: [MCP Inspector](https://www.revenuecat.com/docs/tools/mcp/setup) (Streamable HTTP, тот же URL, Bearer token).

**В приложении ParentalControl** по-прежнему используется только **публичный** iOS SDK key в `RevenueCatPublicSDKKey` — это не тот же ключ, что для MCP.

## Проект ParentalControl в RevenueCat

- **Project ID:** `proj35cefec3`
- В проекте должно быть приложение **App Store** с bundle **`mycompny.ParentalControl`** (не только Test Store). Публичный ключ этого приложения → `RevenueCatPublicSDKKey` в Xcode.
- Entitlement lookup **`ParentalControl Pro`**, offering **`default`**, пакеты **`$rc_weekly`** и **`$rc_annual`** — как в `RevenueCatConfig.swift`; продукты подключаются после создания подписок в App Store Connect.
