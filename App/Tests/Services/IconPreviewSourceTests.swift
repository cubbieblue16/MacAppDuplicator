import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class IconPreviewSourceTests: XCTestCase {
    private let savedIcon = URL(fileURLWithPath: "/nonexistent/Claude Work.app/Contents/Resources/AppIcon.icns")
    private let targetIcon = URL(fileURLWithPath: "/nonexistent/Target.app/Contents/Resources/Target.icns")

    private func config(_ mode: IconMode, custom: String? = nil, name: String = "Claude Work", target: String = "/Applications/Target.app") -> ShortcutConfig {
        var c = makeConfig(name: name, targetPath: target)
        c.iconMode = mode
        c.customIconPath = custom
        return c
    }

    /// Both icon files present; the two nil cases call `IconPreviewSource.resolve` directly.
    private func resolve(draft: ShortcutConfig, saved: ShortcutConfig) -> IconPreviewSource {
        IconPreviewSource.resolve(draft: draft, saved: saved, savedIconURL: savedIcon, targetIconURL: targetIcon)
    }

    // MARK: copied

    func testCopiedSavedUsesTheSavedIcon() {
        XCTAssertEqual(resolve(draft: config(.copied), saved: config(.copied)), .file(savedIcon))
    }

    func testCopiedSavedSurvivesARename() {
        XCTAssertEqual(resolve(draft: config(.copied, name: "Claude Home"), saved: config(.copied)), .file(savedIcon))
    }

    func testCopiedDraftUsesTheTargetsIcon() {
        XCTAssertEqual(resolve(draft: config(.copied), saved: config(.generated)), .file(targetIcon))
    }

    func testCopiedDraftWithANewTargetUsesThatTargetsIcon() {
        XCTAssertEqual(resolve(draft: config(.copied, target: "/Applications/Other.app"), saved: config(.copied)), .file(targetIcon))
    }

    func testCopiedDraftWithoutATargetIconIsAPlaceholder() {
        let source = IconPreviewSource.resolve(draft: config(.copied), saved: config(.generated), savedIconURL: savedIcon, targetIconURL: nil)
        XCTAssertEqual(source, .placeholder)
    }

    // MARK: custom

    func testCustomSavedUsesTheSavedIcon() {
        let saved = config(.custom, custom: "/Users/someone/Pictures/work.png")
        XCTAssertEqual(resolve(draft: saved, saved: saved), .file(savedIcon))
    }

    func testCustomDraftUsesTheChosenFile() {
        let source = resolve(draft: config(.custom, custom: "/Users/someone/Pictures/new.png"), saved: config(.custom, custom: "/Users/someone/Pictures/work.png"))
        XCTAssertEqual(source, .file(URL(fileURLWithPath: "/Users/someone/Pictures/new.png")))
    }

    func testCustomDraftWithoutAFileIsAPlaceholder() {
        XCTAssertEqual(resolve(draft: config(.custom), saved: config(.copied)), .placeholder)
    }

    // MARK: generated

    func testGeneratedSavedUsesTheSavedIcon() {
        XCTAssertEqual(resolve(draft: config(.generated), saved: config(.generated)), .file(savedIcon))
    }

    func testGeneratedDraftAfterAModeSwitchRendersTheInitials() {
        XCTAssertEqual(resolve(draft: config(.generated), saved: config(.copied)), .generated(initials: IconRenderer.initials(for: "Claude Work")))
    }

    func testGeneratedDraftWithNewInitialsRendersThem() {
        let source = resolve(draft: config(.generated, name: "Personal Mail"), saved: config(.generated))
        XCTAssertEqual(source, .generated(initials: IconRenderer.initials(for: "Personal Mail")))
    }

    // MARK: no saved icon file

    func testAnUnchangedDraftWithoutASavedIconPreviewsFromTheDraft() {
        let source = IconPreviewSource.resolve(draft: config(.generated), saved: config(.generated), savedIconURL: nil, targetIconURL: nil)
        XCTAssertEqual(source, .generated(initials: IconRenderer.initials(for: "Claude Work")))
    }
}
