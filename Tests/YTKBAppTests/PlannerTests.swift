import Foundation
import YTKBKit

@MainActor
func plannerTests() {
    TestHarness.test("pickLang exact match") {
        let tracks: [String: [SubFormat]] = ["en": [], "ru": [], "fr-FR": []]
        try expectEq(SubsPlanner.pickLang("ru", in: tracks), "ru")
    }

    TestHarness.test("pickLang prefix match") {
        let tracks: [String: [SubFormat]] = ["en-US": [], "ru-RU": []]
        try expectEq(SubsPlanner.pickLang("en", in: tracks), "en-US")
        try expectEq(SubsPlanner.pickLang("ru", in: tracks), "ru-RU")
    }

    TestHarness.test("pickLang case-insensitive prefix") {
        let tracks: [String: [SubFormat]] = ["EN-GB": []]
        try expectEq(SubsPlanner.pickLang("en", in: tracks), "EN-GB")
    }

    TestHarness.test("pickLang no match returns nil") {
        let tracks: [String: [SubFormat]] = ["en": [], "ru": []]
        try expectNil(SubsPlanner.pickLang("ja", in: tracks))
    }

    TestHarness.test("pickLang empty/nil tracks return nil") {
        try expectNil(SubsPlanner.pickLang("en", in: [:]))
        try expectNil(SubsPlanner.pickLang("en", in: nil))
    }

    TestHarness.test("pickLang nil desired returns nil") {
        let tracks: [String: [SubFormat]] = ["en": []]
        try expectNil(SubsPlanner.pickLang(nil, in: tracks))
    }

    TestHarness.test("Default plan orders original → english → any") {
        let meta = makeMeta(language: "ru", auto: ["en": [], "ru": [], "fr": []], manual: ["en": [], "ru": []])
        let plan = SubsPlanner.buildPlan(meta: meta)
        try expectEq(
            plan.attempts.map { "\($0.langKey)|\($0.isAuto)" },
            ["ru|true", "ru|false", "en|true", "en|false"]
        )
    }

    TestHarness.test("Plan dedupes across tiers") {
        let meta = makeMeta(language: "en", auto: ["en": []], manual: ["en": []])
        let plan = SubsPlanner.buildPlan(meta: meta)
        try expectEq(plan.attempts.count, 2)
        try expectEq(plan.attempts[0].langKey, "en")
        try expectTrue(plan.attempts[0].isAuto)
        try expectFalse(plan.attempts[1].isAuto)
    }

    TestHarness.test("Plan skips tiers when lang not available") {
        let meta = makeMeta(language: "ja", auto: ["en": []], manual: [:])
        let plan = SubsPlanner.buildPlan(meta: meta)
        try expectEq(plan.attempts.map(\.langKey), ["en"])
        try expectTrue(plan.attempts[0].isAuto)
    }

    TestHarness.test("Plan falls back to alphabetical @any") {
        let meta = makeMeta(language: nil, auto: ["fr": [], "es": [], "zh": []], manual: ["pt": []])
        let plan = SubsPlanner.buildPlan(meta: meta)
        try expectEq(plan.attempts.first?.langKey, "es")
        try expectTrue(plan.attempts.first?.isAuto ?? false)
        try expectTrue(plan.attempts.contains { $0.langKey == "pt" && !$0.isAuto })
    }

    TestHarness.test("Empty meta produces empty plan") {
        let meta = makeMeta(language: "en", auto: nil, manual: nil)
        let plan = SubsPlanner.buildPlan(meta: meta)
        try expectTrue(plan.attempts.isEmpty)
    }

    TestHarness.test("Custom priority overrides defaults") {
        let meta = makeMeta(language: "ru", auto: ["en": [], "ru": [], "fr": []], manual: [:])
        let plan = SubsPlanner.buildPlan(meta: meta, languagePriority: ["fr", "@english"])
        try expectEq(plan.attempts.map(\.langKey), ["fr", "en"])
    }

    TestHarness.test("Custom priority raw code prefix-matches") {
        let meta = makeMeta(language: "en", auto: ["fr-FR": []], manual: [:])
        let plan = SubsPlanner.buildPlan(meta: meta, languagePriority: ["fr"])
        try expectEq(plan.attempts.first?.langKey, "fr-FR")
    }

    TestHarness.test("isFallback detects language mismatch") {
        try expectTrue(SubsPlanner.isFallback("en", original: "ru"))
        try expectFalse(SubsPlanner.isFallback("ru", original: "ru"))
        try expectFalse(SubsPlanner.isFallback("ru-RU", original: "ru"))
        try expectTrue(SubsPlanner.isFallback("en-US", original: "ru-RU"))
        try expectFalse(SubsPlanner.isFallback("en", original: nil))
    }
}

private func makeMeta(
    language: String?,
    auto: [String: [SubFormat]]?,
    manual: [String: [SubFormat]]?
) -> VideoMetadata {
    var dict: [String: Any] = ["id": "abc12345678", "title": "test"]
    if let language { dict["language"] = language }
    if let auto = auto {
        dict["automatic_captions"] = auto.mapValues { _ in [] as [[String: String]] }
    }
    if let manual = manual {
        dict["subtitles"] = manual.mapValues { _ in [] as [[String: String]] }
    }
    let data = try! JSONSerialization.data(withJSONObject: dict)
    return try! JSONDecoder().decode(VideoMetadata.self, from: data)
}
