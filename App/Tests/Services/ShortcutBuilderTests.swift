import XCTest
@testable import DuplicatorCore
@testable import MacAppDuplicator

final class ShortcutBuilderTests: XCTestCase {
    private var dir: URL!
    private var target: URL!
    private var launcher: URL!
    private var builder: ShortcutBuilder!

    override func setUpWithError() throws {
        dir = try makeAppTemporaryDirectory()
        target = try writeFakeTarget(named: "Target", bundleIdentifier: "com.example.target", version: "1.0", in: dir)
        // The fake target needs a real Mach-O executable for AppInspector; /bin/ls is a universal binary. Copy, don't link.
        try FileManager.default.removeItem(at: target.appending(path: "Contents/MacOS/Target"))
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/ls"), to: target.appending(path: "Contents/MacOS/Target"))
        launcher = dir.appending(path: "Launcher")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/echo"), to: launcher)
        builder = ShortcutBuilder(launcherBinary: launcher, signingIdentity: nil)
    }

    override func tearDownWithError() throws { try FileManager.default.removeItem(at: dir) }

    private func config(name: String = "Target Work") -> ShortcutConfig {
        var c = makeConfig(name: name, targetPath: target.path)
        c.iconMode = .generated
        return c
    }

    func testCreateWritesSignedBundleWithIconAndRefusesDuplicate() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)

        XCTAssertEqual(bundle.lastPathComponent, "Target Work.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/Resources/AppIcon.icns").path))
        let record = try LibraryScanner.record(forBundleAt: bundle)
        XCTAssertEqual(record.config.iconMode, .generated)
        let verify = Process()
        verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", bundle.path]
        verify.standardError = Pipe()
        try verify.run(); verify.waitUntilExit()
        XCTAssertEqual(verify.terminationStatus, 0)

        XCTAssertThrowsError(try builder.create(config: config(), in: out)) { error in
            guard case ShortcutBuilder.BuilderError.alreadyExists = error else { return XCTFail("\(error)") }
        }
    }

    func testCreateWithMissingTargetThrows() {
        var c = config()
        c.targetPath = dir.appending(path: "Gone.app").path
        XCTAssertThrowsError(try builder.create(config: c, in: dir)) { error in
            guard case ShortcutBuilder.BuilderError.targetMissing = error else { return XCTFail("\(error)") }
        }
    }

    func testRegenerateRewritesInPlaceAndKeepsPath() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        var record = try LibraryScanner.record(forBundleAt: bundle)
        var updated = record.config
        updated.arguments = ["--flag"]
        let rewritten = try builder.regenerate(record: record, config: updated)
        XCTAssertEqual(rewritten, bundle)
        record = try LibraryScanner.record(forBundleAt: rewritten)
        XCTAssertEqual(record.config.arguments, ["--flag"])
    }

    func testRegenerateStampsCurrentEngineVersion() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var stale = config()
        stale.engineVersion = 0
        let bundle = try writeShortcutBundle(named: "Target Work", in: out, config: stale, engineVersion: 0)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        XCTAssertEqual(record.config.engineVersion, 0)

        let rewritten = try builder.regenerate(record: record, config: record.config)

        let data = try Data(contentsOf: rewritten.appending(path: "Contents/Info.plist"))
        let info = try XCTUnwrap(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        XCTAssertEqual(info[ShortcutConfig.engineVersionInfoPlistKey] as? Int, ShortcutConfig.currentEngineVersion)
        let rawConfig = try XCTUnwrap(info[ShortcutConfig.infoPlistKey] as? [String: Any])
        XCTAssertEqual(try ShortcutConfig(plistDictionary: rawConfig).engineVersion, ShortcutConfig.currentEngineVersion)
    }

    func testDuplicateCreatesSecondBundleWithNewIdentity() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let first = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: first)
        let second = try builder.duplicate(record: record, newName: "Target Personal", in: out, takenSlugs: [record.config.slug])
        let copy = try LibraryScanner.record(forBundleAt: second)
        XCTAssertEqual(second.lastPathComponent, "Target Personal.app")
        XCTAssertEqual(copy.config.slug, ShortcutConfig.slug(for: "Target Personal"))
        XCTAssertEqual(copy.config.bundleIdentifier, ShortcutConfig.bundleIdentifier(forSlug: copy.config.slug))
        XCTAssertEqual(copy.config.dataPath, ShortcutConfig.defaultDataPath(forSlug: copy.config.slug, home: FileManager.default.homeDirectoryForCurrentUser))
        XCTAssertNotEqual(copy.config.dataPath, record.config.dataPath, "a duplicate gets its own default data folder, not the original's")
        XCTAssertEqual(copy.config.targetPath, record.config.targetPath)
    }

    func testCreateRefusesAShortcutAsTheTarget() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let shortcut = try builder.create(config: config(), in: out)
        var chained = config(name: "Chained")
        chained.targetPath = shortcut.path

        XCTAssertThrowsError(try builder.create(config: chained, in: out)) { error in
            guard case ShortcutBuilder.BuilderError.targetIsShortcut(let path) = error else { return XCTFail("unexpected error \(error)") }
            XCTAssertEqual(path, shortcut.path)
            XCTAssertEqual(error.localizedDescription, "Target Work is an App Duplicator shortcut, not an app. Choose the original app instead.")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: out.appending(path: "Chained.app").path), "nothing is written for a refused target")
    }

    func testRegenerateRefusesTheShortcutItselfAsTheTarget() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        var selfTarget = record.config
        selfTarget.targetPath = bundle.path

        XCTAssertThrowsError(try builder.regenerate(record: record, config: selfTarget)) { error in
            guard case ShortcutBuilder.BuilderError.targetIsShortcut = error else { return XCTFail("unexpected error \(error)") }
        }
        XCTAssertEqual(try LibraryScanner.record(forBundleAt: bundle).config.targetPath, record.config.targetPath, "the refused write leaves the bundle as it was")
    }

    func testDuplicateDeDuplicatesTheSlugAgainstTheLibrary() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let first = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: first)
        // "Target-Work" gets its own file name but folds to the original's slug.
        XCTAssertEqual(ShortcutConfig.slug(for: "Target-Work"), record.config.slug, "precondition: the names collide on the slug")

        let second = try builder.duplicate(record: record, newName: "Target-Work", in: out, takenSlugs: [record.config.slug])
        let copy = try LibraryScanner.record(forBundleAt: second)
        let expected = "\(record.config.slug)-2"
        XCTAssertEqual(second.lastPathComponent, "Target-Work.app")
        XCTAssertEqual(copy.config.slug, expected)
        XCTAssertEqual(copy.config.bundleIdentifier, ShortcutConfig.bundleIdentifier(forSlug: expected))
        XCTAssertEqual(copy.config.dataPath, ShortcutConfig.defaultDataPath(forSlug: expected, home: FileManager.default.homeDirectoryForCurrentUser))
        XCTAssertNotEqual(copy.config.bundleIdentifier, record.config.bundleIdentifier)
    }

    func testCreateResolvesDefaultDataPathWhenNil() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        var c = config()
        c.dataMode = .auto
        c.dataPath = nil
        let bundle = try builder.create(config: c, in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        XCTAssertEqual(record.config.dataPath, ShortcutConfig.defaultDataPath(forSlug: c.slug, home: FileManager.default.homeDirectoryForCurrentUser))
    }

    func testCreateKeepsNilDataPathWhenDataModeDisabled() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        var c = config()
        c.dataMode = .disabled
        c.dataPath = nil
        let bundle = try builder.create(config: c, in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        XCTAssertNil(record.config.dataPath)
    }

    func testExportCopiesBundle() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        let exported = try builder.export(record: record, to: dir.appending(path: "exported.app"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: exported.appending(path: "Contents/Info.plist").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path))
    }

    func testExportRefusesTheShortcutItselfAndPathsInsideOrAroundIt() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        for destination in [bundle, bundle.appending(path: "Contents/Nested.app"), out] {
            XCTAssertThrowsError(try builder.export(record: record, to: destination)) { error in
                guard case ShortcutBuilder.BuilderError.exportOverlapsShortcut = error else { return XCTFail("\(destination.path): \(error)") }
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/Info.plist").path), "self-export must leave the shortcut intact")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["Target Work.app"], "no staging copy left behind")
    }

    func testExportRefusesTheTargetAndPathsInsideOrAroundIt() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        let targetExecutable = try Data(contentsOf: target.appending(path: "Contents/MacOS/Target"))
        for destination in [target!, target.appending(path: "Contents/Inner.app"), dir!] {
            XCTAssertThrowsError(try builder.export(record: record, to: destination)) { error in
                guard case ShortcutBuilder.BuilderError.exportOverlapsTarget = error else { return XCTFail("\(destination.path): \(error)") }
            }
        }
        XCTAssertEqual(try Data(contentsOf: target.appending(path: "Contents/MacOS/Target")), targetExecutable, "the target is never touched")
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appending(path: "Contents/Info.plist").path))
    }

    func testExportReplacesAnExistingDestination() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        let exportDir = dir.appending(path: "export", directoryHint: .isDirectory)
        let destination = exportDir.appending(path: "Exported.app", directoryHint: .isDirectory)
        // The destination is a previous export (a shortcut bundle); a plain app there would be refused.
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bundle, to: destination)
        try Data("old".utf8).write(to: destination.appending(path: "old-marker"))

        let outcome = try builder.exportCopy(record: record, to: destination)
        let exported = outcome.exportedURL
        let trashed = try XCTUnwrap(outcome.trashedExisting, "the existing destination goes to the Trash")
        addTeardownBlock { try FileManager.default.removeItem(at: trashed) }

        XCTAssertEqual(exported.standardizedFileURL.path, destination.standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appending(path: "old-marker").path))
        XCTAssertEqual(try Data(contentsOf: trashed.appending(path: "old-marker")), Data("old".utf8), "replaced, never deleted")
        XCTAssertEqual(try Data(contentsOf: destination.appending(path: "Contents/Info.plist")), try Data(contentsOf: bundle.appending(path: "Contents/Info.plist")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/Info.plist").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exportDir.path), ["Exported.app"], "no staging copy left behind")
    }

    /// A plain app (no MADConfig) at `<tmp>/Foreign.app`, like Safari or any installed app.
    private func makeForeignApp() throws -> URL {
        try writeFakeTarget(named: "Foreign", bundleIdentifier: "com.example.foreign", version: "1.0", in: dir)
    }

    private func relativeFileList(under root: URL) throws -> [String] {
        try (FileManager.default.subpathsOfDirectory(atPath: root.path)).sorted()
    }

    func testExportRefusesDestinationInsideForeignAppBundle() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        let foreign = try makeForeignApp()
        let before = try relativeFileList(under: foreign)

        XCTAssertThrowsError(try builder.export(record: record, to: foreign.appending(path: "Contents/X.app", directoryHint: .isDirectory))) { error in
            guard case ShortcutBuilder.BuilderError.exportIntoForeignApp(let app) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(app.standardizedFileURL.path, foreign.standardizedFileURL.path)
        }
        XCTAssertEqual(try relativeFileList(under: foreign), before, "nothing was written into the foreign app")
    }

    func testExportRefusesReplacingForeignAppBundle() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        let foreign = try makeForeignApp()
        let before = try relativeFileList(under: foreign)

        XCTAssertThrowsError(try builder.export(record: record, to: foreign)) { error in
            guard case ShortcutBuilder.BuilderError.exportIntoForeignApp = error else { return XCTFail("\(error)") }
        }
        XCTAssertEqual(try relativeFileList(under: foreign), before, "the foreign app was not trashed or changed")
        XCTAssertNil(try FileManager.default.contentsOfDirectory(atPath: dir.path).first { ShortcutBuilder.isStagingName($0) }, "no staging copy left behind")
    }

    func testExportRefusesOverlapWithAnotherRecordsTarget() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        let otherTarget = dir.appending(path: "Other Target.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: otherTarget, withIntermediateDirectories: true)

        XCTAssertThrowsError(try builder.export(record: record, to: otherTarget, otherTargetPaths: ["not absolute", otherTarget.path])) { error in
            guard case ShortcutBuilder.BuilderError.exportOverlapsTarget = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherTarget.path), "the other record's target is never trashed")
    }

    func testExportStillReplacesPreviousExport() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        let destination = dir.appending(path: "Exported.app", directoryHint: .isDirectory)

        let first = try builder.exportCopy(record: record, to: destination)
        XCTAssertNil(first.trashedExisting)
        let second = try builder.exportCopy(record: record, to: destination, otherTargetPaths: ["/Applications/Elsewhere.app"])
        let trashed = try XCTUnwrap(second.trashedExisting, "the previous export goes to the Trash")
        addTeardownBlock { try FileManager.default.removeItem(at: trashed) }
        XCTAssertTrue(TargetGuard.isShortcutBundle(at: destination))
    }

    func testFailedExportKeepsTheSourceAndAnyExistingDestination() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)

        // The destination folder does not exist, so the staging copy fails before anything is moved.
        XCTAssertThrowsError(try builder.export(record: record, to: dir.appending(path: "missing/Exported.app")))
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/Info.plist").path))

        // The source is gone, so the copy fails; the existing destination must survive untouched.
        let exportDir = dir.appending(path: "export", directoryHint: .isDirectory)
        let destination = exportDir.appending(path: "Exported.app", directoryHint: .isDirectory)
        // The destination is a previous export (a shortcut bundle); a plain app there would be refused.
        try FileManager.default.createDirectory(at: exportDir, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bundle, to: destination)
        try Data("old".utf8).write(to: destination.appending(path: "old-marker"))
        try FileManager.default.moveItem(at: bundle, to: dir.appending(path: "moved-away.app"))
        XCTAssertThrowsError(try builder.export(record: record, to: destination))
        XCTAssertEqual(try Data(contentsOf: destination.appending(path: "old-marker")), Data("old".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: exportDir.path), ["Exported.app"], "no staging copy left behind")
    }

    func testDeleteRefusesAnUnsafeDataFolderBeforeTrashingAnything() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        var c = config()
        c.dataMode = .homeOverride
        c.dataPath = out.path
        let bundle = try builder.create(config: c, in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)

        XCTAssertThrowsError(try builder.delete(record: record, removeData: true)) { error in
            guard case DataPathGuardError.overlapsLibraryFolder = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.path), "a refused delete must not trash the bundle either")

        let shared = dir.appending(path: "shared", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shared, withIntermediateDirectories: true)
        c.dataPath = shared.path
        let rewritten = try builder.regenerate(record: record, config: c)
        XCTAssertThrowsError(try builder.delete(record: try LibraryScanner.record(forBundleAt: rewritten), removeData: true, otherRecordDataPaths: [shared.path])) { error in
            guard case DataPathGuardError.usedByAnotherShortcut = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: rewritten.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: shared.path))
    }

    func testDeleteRemovesBundleAndOptionallyDataFolder() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        var c = config()
        let data = dir.appending(path: "data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        c.dataMode = .homeOverride
        c.dataPath = data.path
        let bundle = try builder.create(config: c, in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)

        let trashedBundle = try builder.delete(record: record, removeData: false)
        addTeardownBlock { for url in trashedBundle { try FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(trashedBundle.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: bundle.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: data.path))

        let again = try builder.create(config: c, in: out)
        let trashedBoth = try builder.delete(record: try LibraryScanner.record(forBundleAt: again), removeData: true)
        addTeardownBlock { for url in trashedBoth { try FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(trashedBoth.count, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: data.path))
    }

    func testExportRefusesACaseVariantOfTheShortcutsPath() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        for destination in [out.appending(path: "target work.app"), out.appending(path: "TARGET WORK.app/Contents/Copy.app")] {
            XCTAssertThrowsError(try builder.exportCopy(record: record, to: destination)) { error in
                guard case ShortcutBuilder.BuilderError.exportOverlapsShortcut = error else { return XCTFail("\(destination.path): \(error)") }
            }
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["Target Work.app"], "nothing staged, trashed or replaced")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/Info.plist").path))
    }

    func testExportRefusesASymlinkToTheShortcut() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        let link = dir.appending(path: "Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: bundle)
        let folderLink = dir.appending(path: "link-to-out")
        try FileManager.default.createSymbolicLink(at: folderLink, withDestinationURL: out)
        for destination in [link, folderLink.appending(path: "Target Work.app")] {
            XCTAssertThrowsError(try builder.exportCopy(record: record, to: destination)) { error in
                guard case ShortcutBuilder.BuilderError.exportOverlapsShortcut = error else { return XCTFail("\(destination.path): \(error)") }
            }
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), bundle.path, "the link is never replaced")
        XCTAssertTrue(FileManager.default.fileExists(atPath: bundle.appending(path: "Contents/Info.plist").path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: out.path), ["Target Work.app"])
    }

    func testExportRefusesTheResolvedTargetWhenTheStoredPathIsStale() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        // The target moved after the shortcut was made; the stored path no longer holds it.
        let moved = dir.appending(path: "Moved/Renamed.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: moved.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: target, to: moved)
        let executable = try Data(contentsOf: moved.appending(path: "Contents/MacOS/Target"))
        for destination in [moved, moved.appending(path: "Contents/Inner.app"), moved.deletingLastPathComponent()] {
            XCTAssertThrowsError(try builder.exportCopy(record: record, to: destination, resolvedTargetPath: moved.path)) { error in
                guard case ShortcutBuilder.BuilderError.exportOverlapsTarget = error else { return XCTFail("\(destination.path): \(error)") }
            }
        }
        XCTAssertEqual(try Data(contentsOf: moved.appending(path: "Contents/MacOS/Target")), executable, "the target is never touched")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: moved.deletingLastPathComponent().path), ["Renamed.app"])
    }

    func testExportSweepsStaleStagingCopiesAndNothingElse() throws {
        let out = dir.appending(path: "out", directoryHint: .isDirectory)
        let bundle = try builder.create(config: config(), in: out)
        let record = try LibraryScanner.record(forBundleAt: bundle)
        let exportDir = dir.appending(path: "export", directoryHint: .isDirectory)
        // Left behind by crashed exports: the staging names `exportCopy` makes, for this destination and another one.
        let stale = [".Exported.app.mad-export-\(UUID().uuidString)", ".Other.app.mad-export-\(UUID().uuidString)"]
        // Look-alikes the sweep must keep.
        let kept = [".Exported.app.mad-export-not-a-uuid", "Exported.app.mad-export-\(UUID().uuidString)", "Notes"]
        for name in stale + kept {
            try FileManager.default.createDirectory(at: exportDir.appending(path: name), withIntermediateDirectories: true)
        }

        let outcome = try builder.exportCopy(record: record, to: exportDir.appending(path: "Exported.app", directoryHint: .isDirectory))

        XCTAssertNil(outcome.trashedExisting, "nothing was at the destination")
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: exportDir.path)), Set(kept + ["Exported.app"]))
        XCTAssertTrue(ShortcutBuilder.isStagingName(stale[0]))
        XCTAssertFalse(ShortcutBuilder.isStagingName(kept[0]))
    }
}
