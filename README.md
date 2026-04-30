# yt-kb · macOS menu bar app

YouTube → Markdown база знаний. Скачивает субтитры с отслеживаемых каналов и
сохраняет их как `.md`-файлы для использования с Cowork / Claude / любым
AI-инструментом.

Это нативное Swift-приложение (не Electron, не Python), живёт в menu bar,
без иконки в Dock. Phase 1 (MVP).

## Установка

### Вариант 1 — готовый DMG (рекомендуется)

1. Скачать `YTKB.dmg` со страницы [Releases](../../releases).
2. Открыть `.dmg`, перетащить `YTKB.app` в `/Applications`.
3. **Снять карантин** (приложение пока не подписано Apple Developer ID, поэтому
   Gatekeeper его блокирует по умолчанию):
   ```bash
   xattr -dr com.apple.quarantine /Applications/YTKB.app
   ```
4. Запустить из `/Applications` (Cmd+Space → "yt-kb"). Появится иконка
   📖 в menu bar справа сверху.

### Вариант 2 — собрать самому

```bash
git clone https://github.com/leopavlinskiy/yt-kb-app.git
cd yt-kb-app
./scripts/build.sh
```

Скрипт скачает `yt-dlp_macos` (~36 MB), соберёт релизный бинарник через
`swift build`, склеит `YTKB.app` bundle, ad-hoc подпишет и положит готовый
`dist/YTKB.dmg` в `dist/`.

Требования: macOS 13+, Apple Silicon, Command Line Tools (Xcode.app не нужен).

## Первый запуск

1. Иконка 📖 появилась в menu bar.
2. Открылось окно **Onboarding** — 3 шага:
   - **Шаг 1.** Выбрать папку для базы знаний (или взять дефолтную
     `~/Documents/yt-kbs`).
   - **Шаг 2.** Выбрать браузер для cookies (по умолчанию Chrome). YouTube
     требует cookies, иначе быстро включает bot-detection.
   - **Шаг 3.** Готово.
3. Кликнуть на иконку в menu bar → **+ Добавить канал** → вставить URL
   (`https://www.youtube.com/@handle`) → **Проверить URL** → **Добавить**.
4. Нажать **⟳ Проверить сейчас** → начнётся скачивание субтитров для всех
   видео канала, которых ещё нет в базе.

При первом запросе с cookies из Chrome macOS попросит разрешение на доступ
к ключам "Chrome Safe Storage" — нажмите **"Разрешать всегда"**.

## Что получите на выходе

```
~/Documents/yt-kbs/
└── имя-канала-abc123/
    ├── index.md                                ← оглавление
    ├── 2024-03-15-название-видео-VIDEOID11.md
    └── ...
```

Каждый `.md` содержит YAML-frontmatter (название, канал, URL, дата,
просмотры, язык) и транскрипт автосабов с кликабельными таймкодами обратно
на YouTube, разбитый на блоки по ~2.5 минуты.

## Идемпотентность

Перезапуск poll'а на том же канале безопасен — приложение сначала сканирует
всю базу и пропускает уже скачанные видео БЕЗ обращения к YouTube. Это
определяется по 11-символьному video_id в имени файла.

## Логи

Пишутся в `~/Library/Logs/yt-kb/yt-kb.log`. Открыть напрямую:

```bash
tail -f ~/Library/Logs/yt-kb/yt-kb.log
# или
open ~/Library/Logs/yt-kb/yt-kb.log
```

## State

Список отслеживаемых каналов и retry queue хранятся в JSON:
`~/Library/Application Support/yt-kb/state.json`.

Настройки (KB-папка через security-scoped bookmark, выбор браузера, sleep
между запросами) — в `UserDefaults` (`io.yt-kb.app`).

## Phase 1 → Phase 2

Это **MVP**. Что НЕ реализовано в Phase 1 и идёт на следующие фазы:

- **Phase 2** — каскад из 3 уровней при fetch_metadata и download_subs (для
  редких видео с проблемными форматами); SRV3/JSON3 парсеры (сейчас только
  VTT); background polling по расписанию через `NSBackgroundActivityScheduler`;
  retry queue для видео без сабов; нативные нотификации;
  channel auto-discovery из существующей KB.
- **Phase 3** — анимация menu bar иконки в polling-state, drag-and-drop
  language priority, quiet hours, расширенные настройки.
- **Phase 4** — codesigning с Developer ID, App Sandbox, notarization через
  `notarytool`, GitHub Actions CI/CD.

## Известные ограничения Phase 1

- **App Sandbox выключен.** Embedded `yt-dlp` (PyInstaller-bundle) не работает
  под sandbox без сложных entitlements или extraction в venv. Sandbox +
  notarization планируются в Phase 4.
- **Только arm64.** Universal-сборка (arm64 + x86_64) на Command Line Tools
  без Xcode.app может падать на этапе линковки x86_64; build script
  автоматически фолбэчит на arm64-only. Для Intel-Маков пока не подходит.
- **Только VTT.** Если YouTube вернёт субтитры в `srv3`/`json3` без VTT —
  приложение покажет 0 сегментов. На практике VTT почти всегда доступен;
  SRV3/JSON3 парсеры в Phase 2.
- **Только Layer 1 yt-dlp.** Если простой вызов yt-dlp падает с
  "Requested format is not available" — Phase 1 не делает фолбэков.
- **Поллинг только вручную** (через "⟳ Проверить сейчас"). Background
  scheduler — Phase 2.

## Архитектура

```
Sources/YTKBApp/
├── AppEntry.swift                    # @main, NSApplication setup
├── AppDelegate.swift                 # NSApplicationDelegate
├── MenuBarController.swift           # NSStatusItem + NSPopover
├── Logger.swift                      # ~/Library/Logs/yt-kb/yt-kb.log
├── UI/                               # SwiftUI views
├── State/                            # AppState, ChannelStore, Settings
├── YTDLP/                            # subprocess wrapper, metadata, downloader, resolver
├── Subs/                             # SubsPlanner, VTTParser
├── Markdown/                         # Renderer, ChannelIndexBuilder, Slugify
├── KB/                               # FileNaming, KBScanner (idempotency pre-scan)
└── Polling/                          # PollOperation, PollingCoordinator (singleton actor)
```

## Reference

Phase 1 — порт CLI-скрипта `yt-kb.py` (Python, ~1200 строк) на Swift. CLI
по-прежнему в `~/Desktop/yt-kbs/yt-kb.py` — все behavioural инварианты
сохраняются: каскадные стратегии, planner приоритетов, dedup rolling
captions, frontmatter, slugify правила.

## License

MIT.
