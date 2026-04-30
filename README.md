# yt-kb · macOS menu bar app

YouTube → Markdown база знаний. Скачивает субтитры с отслеживаемых каналов и
сохраняет их как `.md`-файлы для использования с Cowork / Claude / любым
AI-инструментом.

Это нативное Swift-приложение (не Electron, не Python), живёт в menu bar,
без иконки в Dock.

## Установка

### Вариант 1 — готовый DMG (рекомендуется)

1. Скачать `YTKB.dmg` со страницы [Releases](../../releases/latest).
2. Открыть `.dmg`, перетащить `YTKB.app` в `/Applications`.
3. **Снять карантин** (приложение ad-hoc подписано, без Apple Developer ID,
   поэтому Gatekeeper его блокирует по умолчанию):
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
   - **Шаг 3.** Если в выбранной папке уже есть скачанные ранее каналы —
     приложение их найдёт и предложит добавить на отслеживание.
3. Кликнуть на иконку в menu bar → **+ Добавить канал** → вставить URL
   (`https://www.youtube.com/@handle`) → **Проверить URL** → **Добавить**.
4. Дальше каналы будут опрашиваться автоматически (по умолчанию каждые 3
   часа). Чтобы запустить опрос немедленно — **⟳ Проверить сейчас**.

При первом запросе с cookies из Chrome macOS попросит разрешение на доступ
к ключам "Chrome Safe Storage" — нажмите **"Разрешать всегда"**.

## Что внутри

### Pipeline

- **Каскадный fetch_metadata (3 уровня)**: simple call → drop cookies
  при format error или пустых сабах с cookies → aggressive
  (`--extractor-args player_client=web_safari,web,android` + permissive `-f`)
- **Каскадный _download_subs (3 уровня)** по той же схеме
- **Subtitle priority planner**: настраиваемый, по умолчанию
  оригинальный язык → английский → любой; для каждого языка пробуются
  и authrn-subs, и manual-subs
- **3 формата субтитров**: VTT (regex parser), SRV3 (XMLParser), JSON3
  (JSONDecoder); общий dedup для rolling auto-captions
- **Markdown rendering**: YAML frontmatter (title, channel, video_id,
  url, published, duration, view_count, language, source) + H1 + meta-блок
  + опциональный `<details>` description + `## Транскрипт` чанками по 150 сек
  с кликабельными `?t=Xs` ссылками обратно на YouTube
- **index.md**: per-channel оглавление, регенерируется на каждое новое видео,
  сортировка по дате DESC, header с counters/views
- **Idempotency**: pre-scan KB-дерева по regex `-([\w-]{11})\.md$`
  исключает уже скачанные видео ДО любых yt-dlp вызовов

### Background polling

- `NSBackgroundActivityScheduler` с атомарным `isPolling` guard
- Configurable интервал: 1 / 3 / 6 / 24 часа
- Quiet hours (опционально, диапазон HH:MM)
- Manual reload через `⌘R` или кнопку — параллельно scheduled polling
  не запускается

### Retry queue

- Видео без сабов попадают в queue, повторно проверяются каждые 6+ часов
- Максимум 7 попыток за 7 дней; после этого — `permanent_no_subs`,
  больше не пробуется но остаётся видим в UI
- Это нужно потому что YouTube auto-captions появляются НЕ сразу после
  публикации видео — иногда через сутки

### Notifications

- На каждый scheduled poll с N>0 новыми видео: "yt-kb: скачано N
  транскриптов"
- На ошибку поллинга канала впервые
- На bot-check (Sign in to confirm) — критичная

### State storage

- Список каналов + retry queue: `~/Library/Application Support/yt-kb/state.json`
- Настройки: `UserDefaults` (`io.yt-kb.app`), включая security-scoped
  bookmark на KB-папку (переживает relaunch)
- Логи: `~/Library/Logs/yt-kb/yt-kb.log`

## Что получите на выходе

```
~/Documents/yt-kbs/
└── имя-канала-abc123/
    ├── index.md                                ← оглавление
    ├── 2024-03-15-название-видео-VIDEOID11.md
    └── ...
```

## Архитектура

```
Sources/YTKBApp/
├── AppEntry.swift                    @main, NSApplication setup
├── AppDelegate.swift                 NSApplicationDelegate
├── MenuBarController.swift           NSStatusItem + NSPopover + pulse anim
├── Logger.swift                      ~/Library/Logs/yt-kb/yt-kb.log
├── UI/                               SwiftUI views (popover, settings, onboarding)
├── State/                            AppState, ChannelStore, Settings (UserDefaults)
├── YTDLP/                            Process wrapper, metadata, subs, channel resolver
│   ├── YTDLPRunner.swift             actor — async subprocess wrapper
│   ├── MetadataFetcher.swift         3-layer cascade
│   ├── SubsDownloader.swift          3-layer cascade
│   └── ChannelResolver.swift         --flat-playlist + 11-char filter + nested recurse
├── Subs/                             SubsPlanner, VTT/SRV3/JSON3 parsers
├── Markdown/                         Renderer, ChannelIndexBuilder, Slugify
├── KB/                               FileNaming, KBScanner (idempotency), AutoDiscovery
└── Polling/
    ├── PollingScheduler.swift        NSBackgroundActivityScheduler integration
    ├── PollingCoordinator.swift      singleton actor — atomic isPolling guard
    ├── PollOperation.swift           one channel cycle; report with counters + retry mutations
    ├── RetryProcessor.swift          backoff/permanent rules
    └── NotificationsService.swift    UNUserNotificationCenter wrapper
```

## Известные ограничения

- **App Sandbox выключен.** Embedded `yt-dlp` (PyInstaller-bundle) не работает
  под sandbox без либо сложных entitlements (`disable-library-validation` +
  `allow-unsigned-executable-memory`), либо extraction в venv. Sandbox +
  notarization планируются вместе с Developer ID code signing.
- **arm64-only DMG.** Universal-сборка (arm64 + x86_64) на Command Line Tools
  без Xcode.app падает на этапе линковки x86_64; build script автоматически
  фолбэчит на arm64-only. Для Intel-Маков нужен Xcode.app или GitHub Actions
  с macOS-runner — в planning.
- **Не подписано Developer ID.** Только ad-hoc codesign. Gatekeeper
  блокирует первый запуск; нужен `xattr -dr com.apple.quarantine`.

## Логи и troubleshooting

```bash
tail -f ~/Library/Logs/yt-kb/yt-kb.log
# или открыть в Console.app:
open ~/Library/Logs/yt-kb/yt-kb.log
```

**Все видео в `no_subs`** — у канала автосабов на языке оригинала может не
быть. Поправь Settings → Дополнительно → "Приоритет языков субтитров",
добавь `@english` или конкретный код языка наверх списка.

**bot-check (Sign in to confirm)** — Chrome не залогинен в YouTube или
cookies протухли. Залогинься в Chrome, попробуй снова. Или поменяй
Settings → Базовые → Браузер на Safari/Firefox/Brave.

**Safari как источник cookies** — приложению нужно дать Full Disk Access
(System Settings → Privacy & Security → Full Disk Access → +YTKB.app).

## License

MIT.
