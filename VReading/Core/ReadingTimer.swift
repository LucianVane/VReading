import UIKit

/// 阅读计时: 进入阅读页开始, 后台/离开时暂停; 超过 5 分钟无翻页等操作不计时
final class ReadingTimer {
    private let bookId: String
    private var segmentStart = Date()
    private var lastActivity = Date()
    private var timer: Timer?
    private var active = false
    private var observers: [NSObjectProtocol] = []
    private let idleLimit: TimeInterval = 300

    init(bookId: String) { self.bookId = bookId }

    func start() {
        guard !active else { return }
        active = true
        segmentStart = Date()
        lastActivity = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.flush() }
        let nc = NotificationCenter.default
        observers = [
            nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in self?.flush(); self?.active = false },
            nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                self?.active = true
                self?.segmentStart = Date()
                self?.lastActivity = Date()
            },
        ]
    }

    /// 翻页、查词等操作
    func activity() { lastActivity = Date() }

    func flush() {
        guard active else { return }
        let now = Date()
        let end = min(now, lastActivity.addingTimeInterval(idleLimit))
        let secs = Int(end.timeIntervalSince(segmentStart))
        if secs > 0 { AppDatabase.shared.addReadingTime(secs, bookId: bookId) }
        segmentStart = now
    }

    func stop() {
        flush()
        active = false
        timer?.invalidate()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }
}
