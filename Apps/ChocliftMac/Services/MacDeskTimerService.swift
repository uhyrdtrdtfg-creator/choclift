import AppKit
import ChocliftCore
import Foundation

private final class DeskTimerTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    func replace(with next: Task<Void, Never>?) {
        lock.lock()
        let previous = task
        task = next
        lock.unlock()
        previous?.cancel()
    }

    func cancel() {
        replace(with: nil)
    }
}

@MainActor
public final class MacDeskTimerService {
    public private(set) var state: DeskTimerState = .idle
    public var onStateChanged: ((DeskTimerState) -> Void)?
    public var onCompleted: (() -> Void)?

    private let nowProvider: () -> Date
    private let taskBox = DeskTimerTaskBox()
    private var runGeneration: UInt64 = 0
    private var terminationObserver: NSObjectProtocol?

    public init(nowProvider: @escaping () -> Date = { Date() }) {
        self.nowProvider = nowProvider
        terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.stop()
            }
        }
    }

    deinit {
        if let terminationObserver {
            NotificationCenter.default.removeObserver(terminationObserver)
        }
        taskBox.cancel()
    }

    public func start(presetSeconds: Int) {
        runGeneration &+= 1
        let next = DeskTimerState.started(preset: presetSeconds, now: nowProvider())
        state = next
        armCountdownTask(for: next.endsAt, generation: runGeneration)
        onStateChanged?(next)
    }

    public func pause() {
        guard state.phase == .running else { return }
        runGeneration &+= 1
        taskBox.cancel()
        let next = state.paused(at: nowProvider())
        state = next
        onStateChanged?(next)
    }

    public func resume() {
        guard state.phase == .paused else { return }
        runGeneration &+= 1
        taskBox.cancel()
        let next = state.resumed(at: nowProvider())
        state = next
        if next.phase == .running {
            armCountdownTask(for: next.endsAt, generation: runGeneration)
        }
        onStateChanged?(next)
    }

    public func reset() {
        runGeneration &+= 1
        taskBox.cancel()
        let next = state.reset()
        if state != next {
            state = next
            onStateChanged?(next)
        }
    }

    public func stop() {
        runGeneration &+= 1
        taskBox.cancel()
    }

    private func armCountdownTask(for endsAt: Date?, generation: UInt64) {
        guard let endsAt else {
            taskBox.cancel()
            return
        }
        let task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self,
                      self.runGeneration == generation,
                      self.state.phase == .running else {
                    return
                }
                let remainingInterval = endsAt.timeIntervalSince(self.nowProvider())
                if remainingInterval <= 0 {
                    self.completeActiveTimer(generation: generation)
                    return
                }
                let slice = min(0.25, max(0.02, remainingInterval))
                await CancellableDelay.sleepUntilCancelled(seconds: slice)
            }
        }
        taskBox.replace(with: task)
    }

    private func completeActiveTimer(generation: UInt64) {
        guard runGeneration == generation, state.phase == .running else { return }
        runGeneration &+= 1
        taskBox.cancel()
        let finished = state.reset()
        state = finished
        onStateChanged?(finished)
        onCompleted?()
    }
}
