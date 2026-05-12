# yt-kb v2.0.0 — План оптимизации

> **Статус:** план готов к ревью человеком, имплементация не начата.
> **Ограничение plan mode:** в этой фазе можно редактировать только этот файл. После аппрува план **первым шагом имплементации** должен быть скопирован в `docs/v2-optimization-plan.md` (как просил пользователь), и далее идёт работа по items.
> **Ветка:** `claude/yt-kb-optimization-plan-PYFxI`.

---

## Context

Между v1.7.2 и v1.8.0 приложение стало греть Mac и жрать ресурсы. Ревёрт v1.8.1 откатил попытки оптимизации (fast verify URL, eager video-count, notifications that actually arrive), но оставил тяжёлую логику v1.8.0 без оптимизаций — худшее из двух миров. Параллельно четыре ключевых процесса медленные на порядок:

1. **Add channel** — до 15 вызовов yt-dlp ради того, чтобы показать «канал найден».
2. **Initial indexing** — серийная обработка видео внутри канала, ~40 минут на канале с 500 видео.
3. **Scheduled poll** — каждые 3 часа полный enumeration через yt-dlp, без причины.
4. **Idle ресурсы** — UNUserNotification infrastructure, throttle actor, и просто оверхед v1.8.0.

Цель v2.0.0 — быстрее по всем четырём процессам и легче по idle/poll нагрузке.

---

## Executive summary

Четыре главных изменения: **(1)** быстрая проверка канала за 1 yt-dlp вызов вместо 15; **(2)** параллельная обработка видео внутри канала через `TaskGroup` с окном 5; **(3)** RSS-feed для инкрементальных poll'ов (последние ~15 видео за ~200ms HTTP вместо тяжёлого yt-dlp), с fallback на полный enumeration раз в 7 дней и при отсутствии `channelId`; **(4)** полное удаление системных уведомлений (~270 строк), bot-check мигрирует в красный баннер popover'а + красную точку на menu-bar иконке. Эффект: add channel `~30s → 1–2s`, scheduled poll по 10 каналам `~минуты → секунды`, idle ресурсы пропадают.

Главный риск: RSS даёт только ~15 свежих видео — если автор дропнул >15 за один poll-интервал, пропустим. Митигация: weekly full-reconcile pass для каждого канала.

---

## Diff анализа v1.7.2 → HEAD

Текущее состояние ветки `main`: коммит `23f2148` (README rewrite). Состояние кода = v1.8.0 + v1.8.2 bump + macOS-15 Settings crash fix; v1.8.1 был полностью реверчен.

| Коммит | Что | Тяжесть | Решение для v2.0.0 |
|---|---|---|---|
| `460f2cf` v1.7.2 | Baseline | — | reference point |
| `f8390f0` v1.8.0 | queue-based polling + full-catalog enumeration + UNUserNotifications | **тяжёлый** | оптимизировать, не откатывать |
| `326cc55` | Sendable fixes | лёгкий | оставить (компилятор) |
| `b99ebdd` v1.8.1 | (реверчен) fast verify, eager count, notifications | — | переделать как часть v2.0.0 |
| `5d5ff9f` | (реверчен) Sendable getNotificationSettings | — | не нужно |
| `0b8de28` | Settings crash macOS 15 | лёгкий | **оставить** |
| `ef19251` v1.8.2 | bump | лёгкий | оставить |
| `8928ccf` | Revert v1.8.1 | — | уже применён |
| `e91ae41` | Revert Sendable callback | — | уже применён |
| `afa0a9e`/`23f2148` | README rewrite | — | оставить |

**Что v1.8.0 сделал тяжёлым (надо смягчить):**

* `ChannelResolver.fetchAllTabs` — параллельно enumerate `/videos`, `/shorts`, `/streams` с 5-клиентским каскадом. До 15 вызовов yt-dlp с `-I "1:99999"` на каждый ресолв. Используется и для add-channel, и для каждого scheduled poll'а.
* `PollingCoordinator` queue с `withTaskGroup` — само по себе нормально, но дефолт `maxConcurrentChannels=2` помножается на per-channel тяжесть.
* `NotificationsService` + `NotificationThrottle` + `UNUserNotificationCenter` delegate в `AppDelegate` — постоянный idle оверхед, плюс auth-запрос на старте.

**Что оставляем:**
* Queue-based polling — solid, позволяет добавлять канал mid-cycle.
* Параллельный resolver — нужен **только для initial indexing** (когда реально нужен полный каталог); add channel и scheduled poll переключаем на лёгкие пути.
* Bot-check detection логика — переезжает на новый UI-канал.

---

## Acceptance criteria для v2.0.0

| Метрика | Цель | Как измерять |
|---|---|---|
| Add channel wallclock (`@veritasium`) | < 2s | секундомер при паст-и-нажми-«Найти» |
| Add channel wallclock (геоблок / странный канал) | < 30s | fallback на медленный путь, всё равно работает |
| Scheduled poll, 10 каналов, ничего нового | < 10s | таймстампы в логах от старта до finish |
| Initial indexing, 500-видео канал | < 10min | было ~40min |
| Idle CPU (нет polls, app в трее 30+ мин) | < 1% средняя | Activity Monitor по процессу |
| Mac thermal state idle | nominal | без перегрева, проверка `pmset -g thermlog` или субъективно |
| Регрессий по парсингу субтитров / markdown / KB layout | 0 | существующие tests + ручная проверка |
| state.json миграция со старых версий | seamless | `cp` старый state.json, запустить v2.0.0, каналы на месте |

---

## Plan items

Каждый item самодостаточен. Порядок имплементации — в разделе **Rollout order**.

---

### Item 1 — `quickResolve` для добавления канала

**Problem.**
`PopoverView.resolveAdd` (`Sources/YTKBKit/UI/PopoverView.swift:416-442`) вызывает `resolver.resolveMetadata(channelURL:)`, который делает `fetchAllTabs` (`ChannelResolver.swift:109-164`) — параллельно `/videos`, `/shorts`, `/streams`, каждый таб прогоняется через 5-клиентский каскад в `fetchEntries` (`ChannelResolver.swift:183-226`). Каждый `fetchOnce` использует `-I "1:99999"` (`ChannelResolver.swift:228-247`). Худший случай — 15 yt-dlp вызовов с полным enumeration ради того, чтобы получить `name` и `channelId`. На `@veritasium` это легко ~30s.

**Solution.**
Добавить новый метод в `ChannelResolver`:

```swift
struct ResolvedChannelLite: Sendable {
    let name: String
    let channelId: String?   // UC...
    let channelURL: String
}

func quickResolve(channelURL: String) async throws -> ResolvedChannelLite {
    let normalised = Self.normaliseChannelURL(channelURL)  // /@handle → /@handle/videos
    var args = config.baseArgs
    args.append(contentsOf: [
        "--playlist-items", "0",                        // не ходим за entries
        "--print", "%(channel)s|%(channel_id)s|%(channel_url)s",
        "--no-warnings",
        normalised
    ])
    let result = try await runner.run(args, timeout: 20)
    guard result.exitCode == 0 else {
        throw YTDLPError.nonZeroExit(result.exitCode, result.stderr.lastNonEmptyLine)
    }
    // stdout: "Veritasium|UCHnyfMqiRRG1u-2MsSQLbXA|https://www.youtube.com/@veritasium\n"
    guard let line = String(data: result.stdout, encoding: .utf8)?
        .split(separator: "\n").first.map(String.init) else {
        throw YTDLPError.decodeFailed("quickResolve: empty stdout")
    }
    let parts = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
    guard parts.count >= 2, !parts[0].isEmpty else {
        throw YTDLPError.decodeFailed("quickResolve: bad format")
    }
    let name = parts[0]
    let channelId = parts[1].isEmpty ? nil : parts[1]
    let url = parts.count >= 3 && !parts[2].isEmpty ? parts[2] : channelURL
    return ResolvedChannelLite(name: name, channelId: channelId, channelURL: url)
}
```

В `PopoverView.resolveAdd`:

```swift
do {
    let resolver = ChannelResolver(runner: YTDLPRunner.shared, config: config)
    let lite: ResolvedChannelLite
    do {
        lite = try await resolver.quickResolve(channelURL: raw)
    } catch {
        Logger.shared.warn("quickResolve failed, falling back to full: \(error)")
        let full = try await resolver.resolveMetadata(channelURL: raw)
        lite = ResolvedChannelLite(name: full.name, channelId: full.channelId, channelURL: full.channelURL)
    }
    await MainActor.run {
        addResolvedName = lite.name
        addResolvedChannelId = lite.channelId
        // addResolvedVideoCount больше НЕ устанавливается здесь — см. Item 2
    }
}
```

**Files touched.**
* `Sources/YTKBKit/YTDLP/ChannelResolver.swift` (+~40 строк новый метод, +публикация `ResolvedChannelLite`)
* `Sources/YTKBKit/UI/PopoverView.swift` (~10 строк в `resolveAdd`)
* `Tests/YTKBAppTests/ChannelResolverTests.swift` (новый тест, мок-runner возвращает форматированный stdout)

**Risks & mitigations.**
* yt-dlp `--print` формат может вернуть `NA` для отсутствующих полей. Митигация: фильтр `parts[i].isEmpty` + проверять что `channel` не равен `"NA"`.
* `channel_id` иногда не приходит на одних только страничных URL (например `/c/Foo` без UC-id). Митигация: silently fall back на `resolveMetadata`, как пользователь подтвердил.
* `--playlist-items 0` всё ещё ходит за page metadata. Должно быть быстро (~1s), но если yt-dlp решит начать пагинацию — поставлен `timeout: 20`.
* Cookies — `config.baseArgs` уже включает `--cookies-from-browser` если настроен. Не трогаем.

**Test plan.**
* Ручной: paste `https://www.youtube.com/@veritasium` → засечь время до «Найден: Veritasium». Должно быть < 2s.
* Ручной: paste `https://www.youtube.com/channel/UCHnyfMqiRRG1u-2MsSQLbXA` → тот же результат.
* Ручной: paste кривой URL (например ссылка на видео) → должен сработать fallback или показаться внятная ошибка.
* Unit: `ChannelResolverTests` с мок-runner, который возвращает `"Veritasium|UCxxxx|https://..."`, проверяем парсинг.
* Unit: тот же тест с пустыми полями (`"|UCxxxx|"`) — должен бросить.

**Effort.** S.

**Dependencies.** Нет.

---

### Item 2 — Убрать установку `addResolvedVideoCount` в форме добавления

**Problem.**
В `PopoverView.resolveAdd` (`PopoverView.swift:422,434`) и `saveAdd` (`PopoverView.swift:452`) устанавливается `addResolvedVideoCount` из `result.reportedTotalCount`. Это поле сейчас **не отображается в UI формы Add** (форма показывает только `addResolvedName`, см. `PopoverView.swift:293-302`), но **сохраняется в `TrackedChannel.videoCount`** при `saveAdd`. Поскольку quickResolve по природе не возвращает total count, нужно убрать установку при добавлении — count будет проставлен после первого poll'а (это уже работает: `PollingCoordinator.swift:278-280`).

**Решение пользователя по UX:** в списках каналов (`ChannelRowView`, `SettingsChannelRow`) формат «412 / 432» **оставляем как есть** — он апдейтится после polls. Меняем только add flow.

**Solution.**
* Удалить `@State private var addResolvedVideoCount: Int?` из `PopoverView` (`PopoverView.swift:18`).
* Убрать строку `addResolvedVideoCount = result.reportedTotalCount` из `resolveAdd` (`PopoverView.swift:422,434`).
* В `saveAdd` передать `videoCount: nil` в `TrackedChannel` init (`PopoverView.swift:452`). Поле останется nil до первого poll'а, после чего `PollingCoordinator.pollOneInternal` его проставит.
* Никаких изменений в UI формы (там видеокаунт и так не показывался).

**Files touched.**
* `Sources/YTKBKit/UI/PopoverView.swift` (3 правки, -3 строки)

**Risks & mitigations.**
* Свежедобавленный канал на короткое время покажет в списке «0 / —» до первого poll'а. Митигация: `pollOne` всё равно запускается сразу из `saveAdd` (`PopoverView.swift:457`), поэтому в течение ~10s `videoCount` будет проставлен.

**Test plan.**
* Ручной: добавить канал → в списке сразу должен появиться без числа total. После завершения первого poll'а — должно появиться «X / Y».

**Effort.** S.

**Dependencies.** Item 1 (вместе уезжают).

---

### Item 3 — Параллельная обработка видео внутри канала через `TaskGroup`

**Problem.**
`PollOperation.pollChannel` (`Sources/YTKBKit/Polling/PollOperation.swift:101-118` для новых, `124-142` для retry) обрабатывает видео серийно через простой `for`-loop. Каждое `await processVideo(...)` блокирует следующее. Канал на 500 видео × ~5s/видео = ~40min.

**Solution.**
Sliding-window TaskGroup внутри `pollChannel`. Новая настройка `Settings.maxConcurrentVideos` (Int, range 1...8, default 5).

```swift
@Published var maxConcurrentVideos: Int = 5   // clamp 1...8
```

Внутри `pollChannel`, заменить циклы `for (idx, ref) in toProcess.enumerated() { ... }` на:

```swift
let maxConcurrent = max(1, min(8, await MainActor.run { /* read settings */ }))

// Per-channel monotonic counter — UI ожидает что current только растёт.
actor ProgressCounter {
    var processed = 0
    func advance() -> Int { processed += 1; return processed }
}
let counter = ProgressCounter()

await withTaskGroup(of: (VideoRef, PollOutcome).self) { group in
    var nextIndex = 0
    var inFlight = 0
    var stopped = false   // bot-check или cancellation → не стартуем новые

    func tryStart() {
        while inFlight < maxConcurrent, nextIndex < toProcess.count, !stopped {
            if cancellation.isCancelled { stopped = true; break }
            let ref = toProcess[nextIndex]
            nextIndex += 1
            inFlight += 1
            group.addTask { [self] in
                let outcome = await processVideo(ref: ref, kbRoot: kbRoot, channel: channel, report: &localReport)
                // Локальный report актора — см. Risks ниже. Реальная имплементация
                // должна аккуратно мутировать report через actor isolation; в этом
                // плане упрощено.
                return (ref, outcome)
            }
        }
    }

    tryStart()
    while let (ref, outcome) = await group.next() {
        inFlight -= 1
        let current = await counter.advance()
        let label = ref.title.map { String($0.prefix(60)) } ?? ref.videoId
        progress(ChannelProgress(
            phase: .processing,
            current: current,
            total: totalSteps,
            label: label,
            isInitialIndexing: isInitial,
            reportedChannelTotal: reportedTotal
        ))
        applyOutcome(outcome, ref: ref, channelURL: channel.url, channelName: channel.name, isRetry: false, report: &report)
        if case .ok = outcome {
            onIndexed?(IndexedVideoEvent(videoId: ref.videoId, title: ref.title))
        }
        if report.botCheckHit || cancellation.isCancelled {
            stopped = true
            group.cancelAll()       // отменяет pending — Swift cancellation cooperative
            // SIGTERM уже выпустит YTDLPRunner.terminateAll() через cancel() пути
        }
        if !stopped { tryStart() }
    }
}
```

То же самое для retry-loop (`PollOperation.swift:124-142`), но в собственном TaskGroup'е после завершения первого. Семантика: retry-видео идут вторым этапом, не параллельно с новыми.

**Важные инварианты:**
1. **Cancellation.** `cancellation.isCancelled` проверяется при старте каждой новой таски и в `await group.next()` цикле. Уже-стартовавшие таски прерываются через `YTDLPRunner.terminateAll()` (`PollingCoordinator.swift:37`).
2. **Bot-check.** Если `outcome` ставит `report.botCheckHit = true` (`PollOperation.swift:191-193`), мы вызываем `group.cancelAll()` и больше не стартуем. PendingTasks (которые ещё не дошли до yt-dlp) завершаются без работы; уже-стартовавшие yt-dlp процессы продолжают работать до конца или до SIGTERM от coordinator'а (он сетит `cancellation.isCancelled` если poll целиком прерван).
3. **Прогресс.** Текущее `current` обновляется через actor counter в порядке **завершения** видео, не старта. UI ожидает монотонность — это сохраняется.
4. **Mutation safety.** `report` мутируется в одной таске (consumer loop `for await ...`), не внутри `addTask`. `processVideo` возвращает `outcome` value type, дальше `applyOutcome` мутирует `report` уже на consumer-side.

**Files touched.**
* `Sources/YTKBKit/Polling/PollOperation.swift` (основное, ~80 строк изменений / +20)
* `Sources/YTKBKit/State/Settings.swift` (+`maxConcurrentVideos`, ~20 строк: property + Keys + load/save + clamp)
* `Sources/YTKBKit/UI/SettingsView.swift` (+Stepper или Picker для `maxConcurrentVideos`, ~10 строк)
* `Tests/YTKBAppTests/...` — нет существующих PollOperation тестов; добавлять интеграционный тест без mock-yt-dlp нецелесообразно. Ручной тест.

**Risks & mitigations.**
* **YouTube bot-detection** при 5 параллельных запросах. Митигация: clamp 1...8, default 5; настройка в UI; cookies используются те же (один браузер), нагрузка — это последовательные subprocesses, не одновременные HTTP в одной TLS-сессии.
* **YTDLPRunner concurrency.** Сейчас `YTDLPRunner` запускает каждый вызов через отдельный `Process`. 5 параллельных Process — нормально для macOS, но всплеск disk I/O при первом старте. Митигация: проверить на 500-канале, если CPU/disk пиково, добавить лёгкий semaphore.
* **TaskGroup ordering.** Прогресс может прыгать (видео завершаются в random порядке). Митигация: counter actor + label из ref гарантирует что UI видит монотонный `current` и осмысленный `label`.
* **Cancellation race.** Если bot-check сработал на видео N, а N+1 уже в полёте — N+1 может тоже упасть на тот же error и записать его в report. Митигация: `applyOutcome` — идемпотентен по `botCheckHit` (флаг просто True).
* **Сохранение последовательности retry → new.** Retry-loop сейчас идёт после new-loop. Сохраняем эту последовательность: два независимых TaskGroup'а, второй стартует только после `await` первого.

**Test plan.**
* Ручной: канал на ~50 видео, добавить → засечь время. До: ~250s. После: ~50s при concurrency=5.
* Ручной: на полпути нажать «Остановить» → должен прерваться < 2s, никаких ghost-процессов в `ps aux | grep yt-dlp`.
* Ручной: на канале который триггерит bot-check — должно остановиться, в report `botCheckHit=true`, остальные каналы coordinator'ом не стартуются.
* Ручной: progress bar в UI движется монотонно (без скачков назад).

**Effort.** M.

**Dependencies.** Нет, но логически делается одновременно с Item 4 (RSS) — оба меняют `pollChannel`.

---

### Item 4 — RSS-feed для инкрементальных poll'ов + ветвление в `pollChannel`

**Problem.**
`PollOperation.pollChannel` (`PollOperation.swift:77`) на каждом scheduled poll вызывает `resolver.listVideosWithCount`, который опять идёт через тот же тяжёлый `fetchAllTabs` (3 таба × до 5 клиентов = до 15 yt-dlp вызовов с `-I "1:99999"`). Для ответа на вопрос «появилось ли 1-2 новых видео на канале» это абсурдный оверкилл и главная причина перегрева Mac.

**Solution.**

#### 4a. Новый модуль `RSSFetcher`

Файл `Sources/YTKBKit/Polling/RSSFetcher.swift`:

```swift
import Foundation

struct RSSVideo: Sendable {
    let videoId: String
    let title: String?
    let published: Date?
}

enum RSSFetchError: Error {
    case missingChannelId
    case http(Int)
    case network(Error)
    case parse(String)
    case empty
}

actor RSSFetcher {
    static let shared = RSSFetcher()

    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 15
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    func fetchLatest(channelId: String) async throws -> [RSSVideo] {
        guard channelId.hasPrefix("UC") else { throw RSSFetchError.missingChannelId }
        let urlString = "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelId)"
        guard let url = URL(string: urlString) else { throw RSSFetchError.parse("bad url") }

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await session.data(from: url) }
        catch { throw RSSFetchError.network(error) }

        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RSSFetchError.http(http.statusCode)
        }
        let parser = YTRSSParser()
        let videos = try parser.parse(data: data)
        if videos.isEmpty { throw RSSFetchError.empty }
        return videos
    }
}

/// Минимальный XMLParser-based delegate. Парсит <entry><yt:videoId>...</yt:videoId>
/// <title>...</title><published>...</published></entry> блоки.
private final class YTRSSParser: NSObject, XMLParserDelegate {
    private var videos: [RSSVideo] = []
    private var inEntry = false
    private var currentId: String?
    private var currentTitle: String?
    private var currentPublished: String?
    private var elementName: String?
    private var buffer = ""
    private var parseError: Error?

    func parse(data: Data) throws -> [RSSVideo] {
        let p = XMLParser(data: data)
        p.delegate = self
        guard p.parse() else { throw RSSFetchError.parse(p.parserError?.localizedDescription ?? "unknown") }
        if let e = parseError { throw e }
        return videos
    }

    func parser(_ parser: XMLParser, didStartElement n: String, namespaceURI: String?, qualifiedName q: String?, attributes: [String : String] = [:]) {
        elementName = n
        buffer = ""
        if n == "entry" {
            inEntry = true; currentId = nil; currentTitle = nil; currentPublished = nil
        }
    }
    func parser(_ parser: XMLParser, foundCharacters s: String) { buffer += s }
    func parser(_ parser: XMLParser, didEndElement n: String, namespaceURI: String?, qualifiedName q: String?) {
        guard inEntry else { elementName = nil; return }
        switch n {
        case "yt:videoId", "videoId": currentId = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        case "title": currentTitle = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        case "published": currentPublished = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        case "entry":
            if let id = currentId, id.count == 11 {
                let date: Date? = currentPublished.flatMap { ISO8601DateFormatter().date(from: $0) }
                videos.append(RSSVideo(videoId: id, title: currentTitle, published: date))
            }
            inEntry = false
        default: break
        }
        elementName = nil; buffer = ""
    }
}
```

Никаких внешних зависимостей — только Foundation.

#### 4b. Ветвление в `pollChannel`

Добавить в `TrackedChannel` новое поле:

```swift
package var lastFullReconcileAt: Date? = nil
```

И в кастомный декодер: `lastFullReconcileAt = try c.decodeIfPresent(Date.self, forKey: .lastFullReconcileAt)`.

Логика в `PollOperation.pollChannel`:

```swift
let isInitial = channel.lastPolledAt == nil
let weekAgo = Date().addingTimeInterval(-7 * 24 * 3600)
let needsFullReconcile = (channel.lastFullReconcileAt ?? .distantPast) < weekAgo
let hasChannelId = (channel.channelId?.hasPrefix("UC") == true)

let videos: [VideoRef]
let reportedTotal: Int?
let didFullEnum: Bool

if isInitial || needsFullReconcile || !hasChannelId {
    // Тяжёлый путь — полный enumeration.
    do {
        let resolved = try await resolver.listVideosWithCount(channelURL: channel.url)
        videos = resolved.videos
        reportedTotal = resolved.reportedTotal
        report.reportedChannelTotal = reportedTotal
        didFullEnum = true
    } catch {
        if cancellation.isCancelled { report.cancelled = true; return report }
        report.firstError = "не удалось получить список видео: \(error)"
        report.botCheckHit = isBotCheck(report.firstError ?? "")
        return report
    }
} else {
    // Лёгкий путь — RSS.
    do {
        let rss = try await RSSFetcher.shared.fetchLatest(channelId: channel.channelId!)
        videos = rss.map { VideoRef(videoId: $0.videoId, title: $0.title) }
        reportedTotal = nil   // RSS не знает total
        didFullEnum = false
    } catch {
        Logger.shared.warn("RSS fallback to full for \(channel.name): \(error)")
        // Fallback на тяжёлый путь — лучше медленно чем пропустить.
        do {
            let resolved = try await resolver.listVideosWithCount(channelURL: channel.url)
            videos = resolved.videos
            reportedTotal = resolved.reportedTotal
            report.reportedChannelTotal = reportedTotal
            didFullEnum = true
        } catch {
            report.firstError = "RSS+full failed: \(error)"
            report.botCheckHit = isBotCheck(report.firstError ?? "")
            return report
        }
    }
}

// Дальше идёт тот же KBScanner.scanExistingIds + diff + processVideo loop (с TaskGroup из Item 3).
```

И в конце успешного `pollChannel`, если `didFullEnum == true` — сохранить `lastFullReconcileAt = Date()` в report, чтобы `PollingCoordinator.pollOneInternal` его перенёс на `TrackedChannel`:

```swift
// В PollChannelReport:
var didFullReconcile: Bool = false

// В PollOperation.pollChannel, после успешного full enum:
report.didFullReconcile = didFullEnum

// В PollingCoordinator.pollOneInternal, около строки 277:
if report.didFullReconcile {
    built.lastFullReconcileAt = Date()
}
```

#### 4c. Lazy resolve `channelId` для старых каналов

Если `channel.channelId == nil` (канал добавлен до того, как стали сохранять channelId), путь `!hasChannelId` уводит нас в full enum. Это уже работает корректно — full enum выставит channelId, и `PollingCoordinator.pollOneInternal` его сохранит. Нужно только убедиться что в `pollOneInternal` это происходит. Сейчас (`PollingCoordinator.swift:276-280`) обновляется `built.videoCount`, но не `channelId`. Добавить:

```swift
if built.channelId == nil, let id = report.resolvedChannelId {
    built.channelId = id
}
```

И в `PollChannelReport` добавить `var resolvedChannelId: String?`, выставлять его в full-enum ветке из `merged.channelId`.

Альтернативно (более чисто): добавить `func quickResolveChannelId(channelURL: String) async throws -> String?` в `ChannelResolver` (то же что `quickResolve` из Item 1) и вызывать его перед основным polling если `channelId == nil`. Чище, но +1 yt-dlp на канал. **Рекомендация: пойти по основному пути (full enum заполняет всё)**, поскольку у такого канала всё равно будет needsFullReconcile=true на первом запуске.

**Files touched.**
* `Sources/YTKBKit/Polling/RSSFetcher.swift` (новый, ~100 строк)
* `Sources/YTKBKit/Polling/PollOperation.swift` (~40 строк изменений в `pollChannel`)
* `Sources/YTKBKit/State/ChannelStore.swift` (+`lastFullReconcileAt` поле и в декодере, ~5 строк)
* `Sources/YTKBKit/Polling/PollingCoordinator.swift` (~10 строк: сохранение `lastFullReconcileAt` и `channelId` из report)
* `Tests/YTKBAppTests/RSSFetcherTests.swift` (новый, проверка парсинга на статичной XML-фикстуре)
* (опционально) `Tests/YTKBAppTests/Fixtures/sample-feed.xml` (положить пример Atom feed)

**Risks & mitigations.**
* **RSS не возвращает shorts/streams отдельно.** Atom feed YouTube включает всё, что было опубликовано (видео + shorts + streams) в общем потоке. Митигация: проверить на канале с активными shorts (например Hormozi) — должны прилетать.
* **RSS вернёт удалённое/приватное видео в feed.** yt-dlp при попытке metadata на таком вернёт ошибку → попадёт в retry-queue (`PollOperation.applyOutcome` → `noSubs`/`error` уже обрабатывается). Митигация: ничего, существующая retry-логика покрывает.
* **RSS rate-limiting.** YouTube не публикует лимиты, но на практике стабильно работает для тысяч запросов/час с одного IP. При 10 каналах раз в 3 часа — ~80 запросов в день. Митигация: при HTTP 429 — fallback на full enum + warning в логи.
* **Weekly reconcile cost.** Раз в 7 дней × N каналов будет всплеск тяжёлой работы. Если у юзера 20 каналов, может прозвучать «вы говорили будет легче, а тут опять греется». Митигация: spread — не все каналы full-reconcile в один день, а растянуть. Простейший способ: использовать существующий `lastPolledAt` (или `addedAt`) как seed: `needsFullReconcile = Date().timeIntervalSince(channel.lastFullReconcileAt ?? channel.addedAt) >= 7 * 24 * 3600`. Каналы добавлены в разное время → reconcile растянут естественно.
* **Channels без channelId** (старые v1.6.x). Митигация: первый poll после апгрейда — full enum, channelId заполняется. Никакой явной migration не нужно.
* **state.json совместимость.** Новое поле `lastFullReconcileAt` опциональное и читается через `decodeIfPresent` → старые state.json грузятся без ошибок. Каналы без поля считаются «давно не делавшие reconcile» (значение `nil` → `.distantPast` → нужен reconcile) — первый scheduled poll будет тяжёлый, потом легко.

**Test plan.**
* Unit: `RSSFetcherTests` с зафиксированной XML-фикстурой → ожидаем N видео с правильными ID/title.
* Unit: `RSSFetcherTests` с пустым feed → expects `RSSFetchError.empty`.
* Unit: `RSSFetcherTests` с порченным XML → expects `RSSFetchError.parse`.
* Ручной: 10 каналов с `lastPolledAt != nil` → запустить scheduled poll → весь цикл < 30s, в логах видно `using RSS` для каждого.
* Ручной: новый канал → первый poll = full enum, второй (через minute спустя ручной) = RSS.
* Ручной: канал с `channelId = nil` (вручную отредактировать state.json) → первый poll = full enum, заполнит channelId, второй = RSS.
* Ручной: пройти 8 дней (или мокать дату) → следующий poll = full enum (weekly reconcile).
* Ручной: симулировать сетевой fail (выключить wifi на момент RSS) → ожидаем fallback на full enum + warning в логах.

**Effort.** M.

**Dependencies.** Технически независим, но имплементируется одновременно с Item 3 (оба меняют `pollChannel`).

---

### Item 5 — Полностью удалить системные уведомления

**Problem.**
v1.8.0 добавил `NotificationsService` + `NotificationThrottle` + UNUserNotificationCenter delegate в AppDelegate. Это инфраструктура с idle оверхедом (хотя и небольшим), плюс auth-запрос при первом запуске, плюс настройка в Settings которая мутит главный экран. Пользователь подтвердил полное удаление, кроме bot-check сигнала — он мигрирует в UI banner (см. Item 6).

**Solution.**

Удалить:
1. **`Sources/YTKBKit/Polling/NotificationsService.swift`** — весь файл (117 строк).
2. **`NotificationThrottle` actor** из `PollingCoordinator.swift:349-362` — весь блок (14 строк).
3. **Все call-sites `NotificationsService.shared.post*`** в `PollingCoordinator.swift`:
   * `pollOneInternal`, строки 254-265 — блок «if !isInitial { Task { ... postNewVideo ... } }».
   * `pollOneInternal`, строки 314-319 — блок postChannelError.
   * `postSummaryNotification` целиком, строки 324-343 — заменить на no-op или удалить + удалить вызов на строке 200.
4. **`Settings.swift`:**
   * Property `notificationsEnabled` (строка 81).
   * Keys.notificationsEnabled (строка 57).
   * Properties quietHoursEnabled/Start/End (строки 82-84) и их Keys (строки 58-60) — quietHours имеет смысл только для notifications. Если код где-то ещё их читает — убрать. (Проверить grep'ом.)
   * Load/save для всех перечисленных.
5. **`SettingsView.swift`:** все toggle / picker для перечисленных полей (~30 строк UI).
6. **`AppDelegate.swift`:**
   * `UNUserNotificationCenterDelegate` conformance.
   * Регистрация delegate (`UNUserNotificationCenter.current().delegate = self`).
   * Click handler `userNotificationCenter(_:didReceive:withCompletionHandler:)`.
   * `willPresent` handler.
   * `import UserNotifications` если больше нигде не нужен.

Замены на UI banner для bot-check — отдельный Item 6.

**Files touched.**
* `Sources/YTKBKit/Polling/NotificationsService.swift` (удалить целиком)
* `Sources/YTKBKit/Polling/PollingCoordinator.swift` (-~80 строк)
* `Sources/YTKBKit/State/Settings.swift` (-~30 строк: notificationsEnabled + quietHours + Keys + load/save)
* `Sources/YTKBKit/UI/SettingsView.swift` (-~30 строк UI)
* `Sources/YTKBKit/AppDelegate.swift` (-~30 строк)
* `Info.plist` — проверить нет ли `NSUserNotificationAlertStyle` или похожих ключей, удалить.
* `entitlements.plist` — `com.apple.security.network.client` нужен для RSS, не трогаем. Notifications не требуют отдельного entitlement.

**Risks & mitigations.**
* **Юзеры, которые полагались на push-уведомления о новых видео.** UX-решение пользователя: «не нужно». Митигация: recent-videos список в popover уже показывает что нового было (`appState.channelStore.recentVideos`, `PopoverView.swift:31-34`). Этого достаточно.
* **Откат state.json/UserDefaults.** `notificationsEnabled` и quietHours хранятся в UserDefaults; если оставить «осиротевшие» ключи — никакого вреда, при следующем чтении они просто не используются. Удалять явно не обязательно. Чисто косметика — можно сделать миграционный one-shot `defaults.removeObject(forKey: "notificationsEnabled")` в bootstrap, но не критично.
* **Bot-check.** Покрывается Item 6.

**Test plan.**
* Build clean, проверить что нет ссылок на удалённые типы (`swift build` покажет).
* Запустить app: при первом запуске НЕ должно быть system dialog «yt-kb wants to send notifications».
* В Settings — нет тогглов про уведомления / quiet hours.
* Прогнать poll, скачать видео — никаких banners в Notification Center.

**Effort.** S.

**Dependencies.** Item 6 (bot-check banner) — должен быть имплементирован вместе или непосредственно после, иначе bot-check сигнал теряется.

---

### Item 6 — Bot-check UI: красный баннер в popover + точка на menu-bar иконке

**Problem.**
После удаления `NotificationsService` (Item 5) пропадает критичный сигнал «индексация залипла из-за bot-check'а YouTube'а». Сейчас он отправляется через `postBotCheck` (`PollingCoordinator.swift:332-334`, `NotificationsService.swift:98-108`).

**Solution.**

#### 6a. Состояние в `AppState`

```swift
// Sources/YTKBKit/State/AppState.swift
@Published var botCheckActive: Bool = false
```

Сетим в `true` когда `report.botCheckHit == true` в `PollingCoordinator.pollOneInternal`. Сетим в `false` при успешном завершении любого polled-видео (или при следующем успешном poll'е канала).

```swift
// В PollingCoordinator.pollOneInternal, около строки 306-320:
await MainActor.run {
    appState.channelStore.updateChannel(updatedChannel)
    for vid in resolved { appState.channelStore.removeRetryEntry(videoId: vid) }
    for entry in newEntries { appState.channelStore.addRetryEntry(entry) }
    for entry in updatedEntries { appState.channelStore.updateRetryEntry(entry) }
    if okCount == 0, let err = errSnapshot {
        appState.lastError = err
    }
    if report.botCheckHit {
        appState.botCheckActive = true
    } else if okCount > 0 {
        appState.botCheckActive = false   // успешное скачивание → бот-чек больше неактуален
    }
}
```

#### 6b. Баннер в popover

В `PopoverView.swift` после header (или над channelSection) добавить:

```swift
@ViewBuilder
private var botCheckBanner: some View {
    if appState.botCheckActive {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.shield.fill")
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("YouTube требует подтверждение")
                    .font(.callout).fontWeight(.medium).foregroundStyle(.white)
                Text("Войдите в YouTube в выбранном браузере и нажмите «Проверить сейчас».")
                    .font(.caption2).foregroundStyle(.white.opacity(0.9)).lineLimit(2)
            }
            Spacer()
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Color.red)
    }
}
```

Вставить в `body` после `header`/`Divider`.

#### 6c. Точка на menu-bar иконке

В `MenuBarController.swift` (просмотреть текущий код иконки):

```swift
// Прослушиваем appState.$botCheckActive
appState.$botCheckActive
    .receive(on: RunLoop.main)
    .sink { [weak self] active in
        self?.updateStatusItemIcon(botCheck: active)
    }
    .store(in: &cancellables)

private func updateStatusItemIcon(botCheck: Bool) {
    guard let button = statusItem.button else { return }
    if botCheck {
        // Один из вариантов:
        button.image = NSImage(systemSymbolName: "text.book.closed.fill", accessibilityDescription: nil)
        button.contentTintColor = .systemRed
    } else {
        button.image = NSImage(systemSymbolName: "text.book.closed.fill", accessibilityDescription: nil)
        button.contentTintColor = nil
    }
}
```

Альтернатива: composited icon с маленькой красной точкой в углу (через `NSImage` overlay). Простой `contentTintColor = .systemRed` проще и читается мгновенно.

**Files touched.**
* `Sources/YTKBKit/State/AppState.swift` (+`botCheckActive`)
* `Sources/YTKBKit/Polling/PollingCoordinator.swift` (~10 строк в pollOneInternal)
* `Sources/YTKBKit/UI/PopoverView.swift` (+~25 строк botCheckBanner + вставка в body)
* `Sources/YTKBKit/MenuBarController.swift` (~10 строк подписки + helper)

**Risks & mitigations.**
* **Иконка может остаться красной если юзер закрыл app не разблокировав bot-check.** Митигация: `botCheckActive` персистится только в памяти, при перезапуске app сбрасывается. Это норма — на старте делаем фоновый poll, если bot-check всё ещё актуален, флаг снова поднимется.
* **`contentTintColor` может не работать на старых macOS.** Если macOS < 11 — не поддерживается, но мы и так требуем 13+ (Info.plist). OK.
* **Юзер не заметит баннер если popover открыт без полла.** Митигация: красная точка на иконке menu-bar бросается в глаза постоянно.

**Test plan.**
* Ручной: вручную сетить `appState.botCheckActive = true` через debug (или triggernuть bot-check на test-канале) → проверить что:
  * Открытие popover показывает красный banner с текстом.
  * Иконка в menu-bar красная.
* Ручной: нажать «Проверить сейчас», убедиться что после успешного скачивания первого видео — `botCheckActive = false`, иконка обычная, banner пропал.
* Ручной: bot-check продолжает срабатывать → флаг остаётся.

**Effort.** S.

**Dependencies.** Item 5 (одновременно).

---

### Item 7 — Weekly full-reconcile стратегия

> Объединено с Item 4 (`lastFullReconcileAt` логика). Перечислен здесь для прозрачности dependency graph'а, отдельных правок нет.

См. Item 4, секция 4b.

---

### Item 8 — Cleanup и финальные штрихи

**Problem.**
После Items 1-6 в коде останутся осиротевшие куски: настройка `quietHours*` если не убрана, `import UserNotifications` в файлах где он больше не нужен, мёртвые комментарии «// per spec §9», возможные пустые extension'ы.

**Solution.**
* `grep -r "NotificationsService\|NotificationThrottle\|UNUserNotification\|notificationsEnabled\|quietHours" Sources/` — нулевой результат после имплементации Items 5-6 (кроме Item 8 cleanup-комментов).
* Удалить `import UserNotifications` отовсюду кроме файлов где он реально нужен (вероятно — нигде).
* Запустить `swift build -c release` и `swift test` — должны проходить.
* Bump `Info.plist:CFBundleShortVersionString` → `2.0.0`. Bump `CFBundleVersion` (сейчас «23») → следующее значение.
* README — обновить changelog secция если есть, упомянуть v2.0.0 в feature list.

**Files touched.**
* `Info.plist` (2 правки)
* Возможно `README.md` (упоминание v2.0.0)
* Тестовые правки от grep-cleanup'а

**Risks & mitigations.**
* **CI/release pipeline.** `.github/workflows/auto-tag.yml` уже подхватит bump версии и создаст тег. `release.yml` соберёт DMG, подпишет, нотаризует, опубликует. **Никаких изменений в CI не нужно.** Auto-update на пользователях сработает в течение 6 часов после релиза (`UpdateChecker` каждые 6 часов опрашивает GitHub Releases).
* **Migration теста.** Перед мержем сделать smoke-тест: скопировать state.json с старой версии (например v1.8.2 build), запустить v2.0.0 build → каналы на месте, видео не пропали, при следующем poll всё работает.

**Test plan.**
* `swift test` — все существующие тесты + новые из items 1, 4 проходят.
* `scripts/build.sh` локально → DMG монтируется → app запускается → smoke-pass (добавить канал, дождаться poll'а, открыть скачанный markdown).
* Перед публикацией: smoke-test на реальной свежей macOS машине, проверить gatekeeper не блокирует подписанный DMG.

**Effort.** S.

**Dependencies.** Items 1-6 (всё перед ним).

---

## Rollout order

Граф зависимостей:

```
Item 1 (quickResolve) ──┐
                        ├─→ Item 2 (drop addResolvedVideoCount)
                        │
Item 5 (kill notifs) ───┤
                        ├─→ Item 6 (bot-check UI)
                        │
Item 3 (TaskGroup) ─────┐
                        ├─→ Item 4 (RSS + branching)
                        │   ├── Item 7 (weekly reconcile — внутри 4)
                        │
                        └─→ Item 8 (cleanup + version bump + release)
```

**Рекомендуемый порядок коммитов / PR'ов:**

1. **PR #1: «Quick resolve for Add channel»** — Items 1 + 2.
   * Безопасный, изолированный, мгновенный win по UX. Никаких изменений в polling.
2. **PR #2: «Remove notifications, add bot-check banner»** — Items 5 + 6.
   * Большое удаление кода, надо проверить что ничего не сломалось. Запустить app и убедиться что bot-check визуально работает.
3. **PR #3: «Per-video parallel processing»** — Item 3.
   * Изменение core polling. Тестировать на канале с 50+ видео, проверять отмену, bot-check abort.
4. **PR #4: «RSS-based incremental polling + weekly reconcile»** — Item 4 (+7).
   * Самое большое изменение. После него — поллы должны быть быстрыми.
5. **PR #5: «v2.0.0 release: version bump + cleanup»** — Item 8.
   * Bump Info.plist → авто-тэг → авто-релиз → пользователи получат update через 6 часов.

Каждый PR — draft, ревью человеком (отдельным промптом), merge — отдельным промптом. Версию **не** бампим до последнего PR'а.

---

## Open questions

1. **Default `maxConcurrentChannels`** — оставить 2 или поднять до 3? Пользователь в задаче упомянул «вторично», но логично заодно проверить: с RSS-путём 3 каналам параллельно делать почти нечего → нагрузки прибавится мало, а manual «Проверить сейчас» по 10 каналам ускорится. **Рекомендация:** оставить 2 в v2.0.0, тюнить в v2.1 после реальных метрик.
2. **Pre-pass RSS-fetch для scheduled poll'а** — fetch all RSS-feeds in parallel (например up to 10), потом queue только те каналы, где есть delta. Сэкономит ещё пару секунд на «ничего нового» сценарии. **Рекомендация:** не делать в v2.0.0, добавить если метрики покажут что 10-канальный scheduled poll всё ещё медленный.
3. **Прямой `quickResolveChannelId` для миграции** — для каналов без channelId сейчас в плане «лениво заполняем при первом full enum». Альтернатива — миграционный one-shot при первом запуске v2.0.0, который проходит по всем каналам с `channelId == nil`, дёргает `quickResolve`, сохраняет. **Рекомендация:** не делать. Lazy путь работает и не блокирует юзера.
4. **Counter-actor для прогресса в Item 3** — псевдокод выше использует actor для монотонного counter'а. На практике можно обойтись просто `let processed = max(1, idx+1)` если идти от завершённых количеств. Финальная имплементация может выбрать упрощение.
5. **Channels с очень частыми publishes (например live-стримеры)** — RSS показывает 15 последних. Если канал публикует >15 в день, weekly full-reconcile может не быть достаточным. **Рекомендация:** мониторить после релиза, в v2.1 ввести adaptive reconcile (если предыдущий цикл показал что прочитанных = 15, делать reconcile при следующем).
6. **Локализация баннеров и текстов** — приложение русифицировано. Все новые строки в Items 6, 8 — на русском (как и существующий UI). Проверить что нет английских strings-by-accident.
7. **Telemetry / measure** — нет ли смысла залогировать `wallclock(quickResolve)`, `wallclock(pollChannel)` в Logger для самопроверки acceptance criteria? **Рекомендация:** простой `Logger.shared.info` с миллисекундами на ключевых точках — копеечно и сильно поможет при дебаге.

---

## Verification (как тестировать end-to-end)

### Build/CI

```bash
swift build
swift test
scripts/build.sh
# → должен получиться подписанный/нотаризованный DMG (если на CI с секретами)
```

### Ручной flow проверки

1. **Backup state**: `cp ~/Library/Application\ Support/yt-kb/state.json /tmp/state-pre.json`
2. **Install** свежую v2.0.0 DMG поверх v1.8.2.
3. **Запустить**, не делая ничего:
   * Проверить idle CPU через Activity Monitor (5 минут наблюдения). Target < 1% avg.
   * Никакого system dialog'а про notifications.
4. **Add channel** `https://www.youtube.com/@veritasium`:
   * Засечь время от нажатия Find до «Найден: Veritasium». Target < 2s.
   * После добавления — poll стартует автоматом. Прогресс-бар плывёт.
5. **Stop polling** mid-cycle через «Остановить»:
   * Должно прерваться < 2s.
   * `ps aux | grep yt-dlp` — никаких ghost процессов через 5s.
6. **Scheduled poll** на 5 ранее-добавленных каналах:
   * Trigger «Проверить сейчас» (manual путь, но та же логика после Item 4).
   * Время до завершения. Target ~10s если нет новых видео.
   * В логах (`Logger`) видно `using RSS` для каждого канала.
7. **Force bot-check** — добавить непроверенный канал без cookies, либо сетит руками `appState.botCheckActive = true`:
   * Красный баннер в popover виден.
   * Menu-bar иконка красная.
   * Нажать «Проверить сейчас» после починки (логин в браузер) → флаг сбрасывается.
8. **Mac thermals** — после indexing'а ~500-видео канала: Mac не должен быть hotter than nominal в течение 10 мин после завершения cycle'а.
9. **state.json compatibility** — `diff /tmp/state-pre.json ~/Library/Application\ Support/yt-kb/state.json`: каналы все на месте, новое поле `lastFullReconcileAt` опционально появилось.

### Unit tests

```bash
swift test --filter ChannelResolverTests        # quickResolve parsing
swift test --filter RSSFetcherTests             # XML парсинг RSS
swift test --filter SchedulerIntervalTests      # без изменений, sanity
swift test                                       # вся свита
```

### Pre-release smoke

* Локально собрать DMG: `scripts/build.sh`.
* Открыть DMG, перетащить app в /Applications, запустить из /Applications.
* `spctl --assess -vv /Applications/YTKB.app` → должен быть accepted, source Notarized.

---

## Что НЕ делаем в v2.0.0

* Не трогаем парсеры субтитров (`SRV3Parser`, `JSON3Parser`, `VTTParser`).
* Не трогаем `MarkdownRenderer`, `KBScanner`, `KBConsolidator`, `Slugify`, `FileNaming`.
* Не вводим внешние зависимости — RSS-парсер через `Foundation.XMLParser`.
* Не меняем форматы state.json кроме добавления опциональных полей.
* Не трогаем entitlements/sandbox/codesigning.
* Не добавляем новые фичи (Pro, summary, Whisper, search и т.п.) — это v2.1+.
* Не меняем CI/release pipeline — он самодостаточен.

---

## Estimate

* PR #1 (quickResolve): ~1 час имплементации + 30 мин ручной QA.
* PR #2 (kill notifs + bot-check banner): ~2 часа имплементации + 30 мин QA.
* PR #3 (per-video parallelism): ~3 часа имплементации + 1 час QA на разных каналах.
* PR #4 (RSS + branching): ~4 часа имплементации + 1 час QA + 30 мин unit tests.
* PR #5 (cleanup + release): ~1 час + smoke-test.

Итого: ~12-13 часов работы + QA. Реально за 2 дня сосредоточенной работы можно отгрузить v2.0.0.
