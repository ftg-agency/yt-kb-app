import Foundation

/// Minimal test harness — works on Swift toolchains without XCTest or Testing framework
/// (e.g. CommandLineTools-only systems). Used by `main.swift` to drive all suites.
@MainActor
struct TestHarness {
    static var failures: [String] = []
    static var passed = 0
    static var failed = 0
    static var currentSuite = ""
    static var teardownBlocks: [() -> Void] = []

    static func suite(_ name: String, _ body: () -> Void) {
        currentSuite = name
        print("\n— \(name) —")
        body()
    }

    static func test(_ name: String, _ body: () throws -> Void) {
        teardownBlocks = []
        do {
            try body()
            passed += 1
            print("  ✓ \(name)")
        } catch let err as ExpectError {
            failed += 1
            let msg = "  ✗ \(name) at \(err.file):\(err.line): \(err.message)"
            failures.append("[\(currentSuite)] \(msg)")
            print(msg)
        } catch {
            failed += 1
            let msg = "  ✗ \(name): \(error)"
            failures.append("[\(currentSuite)] \(msg)")
            print(msg)
        }
        for block in teardownBlocks { block() }
        teardownBlocks = []
    }

    static func addTeardown(_ block: @escaping () -> Void) {
        teardownBlocks.append(block)
    }

    static func summary() -> Int {
        print("\n========================================")
        print("Passed: \(passed)  Failed: \(failed)")
        if !failures.isEmpty {
            print("\nFailures:")
            for f in failures { print("  \(f)") }
        }
        return failed == 0 ? 0 : 1
    }
}

struct ExpectError: Error {
    let message: String
    let file: String
    let line: Int
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String = "expectation failed", file: String = #file, line: Int = #line) throws {
    if !condition() {
        throw ExpectError(message: message, file: shortFile(file), line: line)
    }
}

func expectEq<T: Equatable>(_ actual: T, _ expected: T, _ context: String = "", file: String = #file, line: Int = #line) throws {
    if actual != expected {
        let ctx = context.isEmpty ? "" : " (\(context))"
        throw ExpectError(message: "expected \(expected), got \(actual)\(ctx)", file: shortFile(file), line: line)
    }
}

func expectNil<T>(_ value: T?, _ context: String = "", file: String = #file, line: Int = #line) throws {
    if value != nil {
        let ctx = context.isEmpty ? "" : " (\(context))"
        throw ExpectError(message: "expected nil, got \(value!)\(ctx)", file: shortFile(file), line: line)
    }
}

func expectNotNil<T>(_ value: T?, _ context: String = "", file: String = #file, line: Int = #line) throws {
    if value == nil {
        let ctx = context.isEmpty ? "" : " (\(context))"
        throw ExpectError(message: "expected non-nil\(ctx)", file: shortFile(file), line: line)
    }
}

func expectClose(_ actual: Double, _ expected: Double, accuracy: Double = 0.001, file: String = #file, line: Int = #line) throws {
    if abs(actual - expected) > accuracy {
        throw ExpectError(message: "expected \(expected) ± \(accuracy), got \(actual)", file: shortFile(file), line: line)
    }
}

func expectContains(_ haystack: String, _ needle: String, file: String = #file, line: Int = #line) throws {
    if !haystack.contains(needle) {
        throw ExpectError(message: "expected substring \"\(needle)\" not found in \"\(haystack.prefix(100))…\"", file: shortFile(file), line: line)
    }
}

func expectTrue(_ condition: @autoclosure () -> Bool, _ message: String = "expected true", file: String = #file, line: Int = #line) throws {
    if !condition() {
        throw ExpectError(message: message, file: shortFile(file), line: line)
    }
}

func expectFalse(_ condition: @autoclosure () -> Bool, _ message: String = "expected false", file: String = #file, line: Int = #line) throws {
    if condition() {
        throw ExpectError(message: message, file: shortFile(file), line: line)
    }
}

private func shortFile(_ path: String) -> String {
    (path as NSString).lastPathComponent
}

// MARK: - Bundle.module access for Fixtures/

enum TestFixtures {
    /// Returns the URL to a fixture file in `Tests/YTKBAppTests/Fixtures/`.
    /// In SPM, resources declared with `.copy(...)` end up inside the test target's bundle.
    static func url(_ name: String, ext: String) -> URL? {
        Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")
    }
}
