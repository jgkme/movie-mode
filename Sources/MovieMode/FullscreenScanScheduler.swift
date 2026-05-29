import Foundation

@MainActor
final class FullscreenScanScheduler {
    private var timer: Timer?
    private let interval: TimeInterval
    private let scan: () -> Void

    init(interval: TimeInterval = 0.5, scan: @escaping () -> Void) {
        self.interval = interval
        self.scan = scan
    }

    func start() {
        stop()
        scan()

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            self?.scan()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
