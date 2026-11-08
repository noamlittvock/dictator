import XCTest
@testable import Dictator

final class HelpLibraryTests: XCTestCase {
    private let rightCommand = HotkeyTriggers(dictation: KeyCombo(DictationKey(keyCode: 54)))

    func testEveryTabHasTopicsAndEveryIDIsUnique() {
        let topics = HelpLibrary.topics(keys: .standard)
        for tab in HelpTab.allCases { XCTAssertFalse(topics.filter { $0.tab == tab }.isEmpty, tab.title) }
        XCTAssertEqual(Set(topics.map(\.id)).count, topics.count)
    }

    func testEveryBriefOpensARealTopic() {
        let ids = Set(HelpLibrary.topics(keys: .standard).map(\.id))
        for page in HelpPage.allCases {
            let brief = HelpLibrary.brief(page, keys: .standard)
            XCTAssertTrue(ids.contains(brief.topicID), brief.title)
            XCTAssertLessThanOrEqual(words(brief.summary), 14, "\(brief.title) is a brief, not a manual")
        }
    }

    func testEverySettingsTabHasItsOwnBrief() {
        let briefs = SettingsSection.tabs.map { HelpLibrary.brief(HelpPage(settings: $0), keys: .standard).title }
        XCTAssertEqual(Set(briefs).count, SettingsSection.tabs.count)
        XCTAssertEqual(HelpPage(settings: .typedApps), HelpPage(settings: .history))
    }

    func testTheManualCoversEveryPage() {
        let titles = Set(HelpLibrary.topics(keys: .standard).filter { $0.tab == .manual }.map(\.title))
        for item in SidebarItem.allCases where item != .help { XCTAssertTrue(titles.contains(item.title), item.title) }
    }

    func testInstructionsFollowTheChosenKey() {
        let text = HelpLibrary.topics(keys: rightCommand).map(\.searchText).joined(separator: " ")
        XCTAssertTrue(text.contains("Right ⌘ Command"))
        XCTAssertTrue(text.contains("Right ⌘ + Right Shift"))
        XCTAssertFalse(text.contains("Right ⌥"))
        XCTAssertTrue(HelpLibrary.brief(.commands, keys: rightCommand).summary.contains("Right ⌘ + Right Shift"))
    }

    func testSearchNeedsEveryWordAndPutsTitlesFirst() {
        let topics = HelpLibrary.topics(keys: .standard)
        XCTAssertEqual(HelpLibrary.search("  ", in: topics), [])
        XCTAssertEqual(HelpLibrary.search("xyzzy", in: topics), [])
        XCTAssertEqual(HelpLibrary.search("CLOUD", in: topics).first?.id, "faq-cloud")
        XCTAssertEqual(HelpLibrary.search("tailscale account", in: topics).map(\.id), ["advanced-macs"])
    }

    private func words(_ line: String) -> Int { line.split(whereSeparator: \.isWhitespace).count }

    /// Help shows first. Long text is how it turned back into a manual.
    func testHelpStaysShort() {
        let topics = HelpLibrary.topics(keys: .standard)
        for topic in topics {
            for line in topic.blocks.flatMap(\.lines) {
                XCTAssertLessThanOrEqual(words(line), 16, line)
            }
        }
        for topic in topics where topic.tab == .basics {
            XCTAssertNotNil(topic.scene, topic.title)
            XCTAssertEqual(topic.blocks.flatMap(\.lines).count, 1, topic.title)
            XCTAssertLessThanOrEqual(topic.blocks.flatMap(\.lines).map(words).reduce(0, +), 9, topic.title)
        }
    }

    func testBriefsShowAPicture() {
        for page in HelpPage.allCases where page != .settingsAdvanced {
            XCTAssertNotNil(HelpLibrary.brief(page, keys: .standard).scene, HelpLibrary.brief(page, keys: .standard).title)
        }
    }

    func testHelpUsesTheProductsWords() {
        let topics = HelpLibrary.topics(keys: .standard)
        let briefs = HelpPage.allCases.map { HelpLibrary.brief($0, keys: .standard) }
        let all = topics.map(\.searchText) + briefs.map { "\($0.title) \($0.summary)" }
        for text in all {
            for banned in [" Core ", " Edge ", "brains", " port ", " token "] {
                XCTAssertFalse(text.contains(banned), "\(banned) in: \(text)")
            }
        }
    }
}
