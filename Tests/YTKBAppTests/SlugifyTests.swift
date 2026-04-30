import Foundation
import YTKBKit

@MainActor
func slugifyTests() {
    TestHarness.test("Basic lowercase kebab") {
        try expectEq(Slugify.slug("Hello World"), "hello-world")
        try expectEq(Slugify.slug("FooBar Baz"), "foobar-baz")
    }

    TestHarness.test("Collapses multiple separators") {
        try expectEq(Slugify.slug("foo   bar"), "foo-bar")
        try expectEq(Slugify.slug("foo---bar"), "foo-bar")
        try expectEq(Slugify.slug("foo   ---   bar"), "foo-bar")
    }

    TestHarness.test("Trims leading/trailing separators") {
        try expectEq(Slugify.slug("---hello---"), "hello")
        try expectEq(Slugify.slug(" Hello World "), "hello-world")
    }

    TestHarness.test("Transliterates Cyrillic") {
        try expectEq(Slugify.slug("Привет мир"), "privet-mir")
    }

    TestHarness.test("Transliterates accents") {
        try expectEq(Slugify.slug("Café résumé"), "cafe-resume")
    }

    TestHarness.test("Empty / all-punctuation falls back to 'untitled'") {
        try expectEq(Slugify.slug(""), "untitled")
        try expectEq(Slugify.slug("---"), "untitled")
        try expectEq(Slugify.slug("!!!"), "untitled")
    }

    TestHarness.test("Truncates at maxLength") {
        let long = String(repeating: "abcdefghij", count: 10)
        let slug = Slugify.slug(long, maxLength: 20)
        try expectTrue(slug.count <= 20, "slug \(slug.count) chars > 20")
    }

    TestHarness.test("Truncation prefers hyphen boundary") {
        let input = "this is a fairly long title that should be truncated at boundary"
        let slug = Slugify.slug(input, maxLength: 30)
        try expectFalse(slug.hasSuffix("-"))
        try expectFalse(slug.isEmpty)
    }

    TestHarness.test("Keeps digits") {
        try expectEq(Slugify.slug("Episode 42 — Final"), "episode-42-final")
    }
}
