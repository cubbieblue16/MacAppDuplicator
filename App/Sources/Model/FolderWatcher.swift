import Foundation
import Synchronization

/// Watches library folders for writes/renames/deletes with `DispatchSource` and coalesces bursts (spec §7).
/// Folders that do not exist when `start()` runs are skipped; call `stop()`/`start()` again after changing the list.
@MainActor
final class FolderWatcher {
    private let folders: [URL]
    private let debounce: Duration
    private let onChange: @MainActor () -> Void
    /// In a `Mutex` so the nonisolated `deinit` can cancel the sources (final review M8).
    private let sources = Mutex<[any DispatchSourceFileSystemObject]>([])
    private var pending: Task<Void, Never>?

    init(folders: [URL], debounce: Duration = .milliseconds(300), onChange: @escaping @MainActor () -> Void) {
        self.folders = folders
        self.debounce = debounce
        self.onChange = onChange
    }

    /// Releasing a source without cancelling it skips its cancel handler, so the `O_EVTONLY` descriptor would leak
    /// (final review M8). A `@MainActor` class's deinit is nonisolated: it touches only `Sendable` state, reading
    /// `pending` before calling `cancelSources()` because only nonisolated members stay reachable after a method call.
    deinit {
        pending?.cancel()
        cancelSources()
    }

    /// Number of folders currently watched; 0 after `stop()`.
    var watchedSourceCount: Int { sources.withLock { $0.count } }

    func start() {
        stop()
        // Sources are created inside the lock so each one is in the lock's region from birth (Swift 6 region isolation).
        sources.withLock { list in
            for folder in folders {
                let descriptor = open(folder.path, O_EVTONLY)
                guard descriptor >= 0 else { continue }
                let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main)
                source.setEventHandler { [weak self] in
                    MainActor.assumeIsolated { self?.schedule() }
                }
                source.setCancelHandler { close(descriptor) }
                source.resume()
                list.append(source)
            }
        }
    }

    func stop() {
        cancelSources()
        pending?.cancel()
        pending = nil
    }

    /// Cancels and forgets every source. A cancelled source runs its cancel handler on `.main`, which closes the
    /// descriptor. Nonisolated so `deinit` can call it; it touches only the `Mutex`.
    nonisolated private func cancelSources() {
        sources.withLock { list in
            list.forEach { $0.cancel() }
            list.removeAll()
        }
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
