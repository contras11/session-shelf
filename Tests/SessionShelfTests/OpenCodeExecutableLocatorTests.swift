import Foundation
import XCTest
@testable import SessionShelfCore

final class OpenCodeExecutableLocatorTests: XCTestCase {
    func test既定候補へ固定パスとPATHを順序どおり追加する() {
        let candidates = OpenCodeExecutableLocator.candidates(
            explicitExecutables: nil,
            searchPath: "/custom/bin:/opt/homebrew/bin:/another/bin"
        )

        XCTAssertEqual(
            candidates.map(\.path),
            [
                "/custom/bin/opencode",
                "/opt/homebrew/bin/opencode",
                "/another/bin/opencode",
                "/usr/local/bin/opencode",
                "/opt/local/bin/opencode"
            ]
        )
    }

    func test空要素と相対PATHを拒否する() {
        let candidates = OpenCodeExecutableLocator.candidates(
            explicitExecutables: nil,
            searchPath: ":relative/bin:./bin:/absolute/bin:"
        )

        XCTAssertTrue(candidates.map(\.path).contains("/absolute/bin/opencode"))
        XCTAssertFalse(candidates.map(\.path).contains { $0.contains("relative/bin/opencode") })
        XCTAssertFalse(candidates.map(\.path).contains { $0.hasSuffix("/./bin/opencode") })
    }

    func test明示候補は既定候補より優先して重複を除く() {
        let explicit = URL(fileURLWithPath: "/custom/bin/opencode")
        let candidates = OpenCodeExecutableLocator.candidates(
            explicitExecutables: [explicit, explicit],
            searchPath: "/ignored/bin"
        )

        XCTAssertEqual(candidates.map(\.path), ["/custom/bin/opencode"])
    }
}
