import Foundation

/// Watches library folders for writes/renames/deletes with `DispatchSource` and coalesces bursts (spec §7).
/// Folders that do not exist when `start()` runs are skipped; call `stop()`/`start()` again after changing the list.
@MainActor
final class FolderWatcher {
    private let folders: [URL]
    private let debounce: Duration
    private let onChange: @MainActor () -> Void
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: Task<Void, Never>?

    init(folders: [URL], debounce: Duration = .milliseconds(300), onChange: @escaping @MainActor () -> Void) {
        self.folders = folders
        self.debounce = debounce
        self.onChange = onChange
    }

    func start() {
        stop()
        for folder in folders {
            let descriptor = open(folder.path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.schedule() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        sources.forEach { $0.cancel() }
        sources.removeAll()
        pending?.cancel()
        pending = nil
    }

    private func schedule() {
        pending?.cancel()
        let delay = debounce
        pending = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.onChange()
        }
    }
}
