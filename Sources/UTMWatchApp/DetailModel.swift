import Combine
import Foundation
import UTMWatchCore
import UTMWatchStore

/// State of the detail window: which time frame is shown, the pinned and hovered moments, and the loaded data.
final class DetailModel: ObservableObject {
    static let lengths: [(seconds: Int, label: String)] = [
        (300, "5 min"), (900, "15 min"), (3600, "1 hour"), (21600, "6 hours"), (86400, "24 hours"), (604800, "7 days"),
    ]

    @Published private(set) var lengthSeconds = 900
    /// End of the frame; nil means live (the frame follows now).
    @Published private(set) var end: Date?
    @Published var pin: Date?
    @Published var hover: Date?
    /// VM whose lines stay bright in the tracks while the others fade; nil shows all equally.
    @Published var focus: String?
    @Published private(set) var history = History(from: 0, to: 0)
    @Published private(set) var stats: HistoryStore.Stats?

    /// False while the window is closed, so nothing is computed for an invisible view.
    var isActive = false { didSet { if isActive { refresh(force: true); refreshStats() } } }

    /// Set when this window shows another Mac of the fleet: its history then comes from the hub, not from this Mac's
    /// memory and database. The closure calls back on the main thread; nil means the hub did not answer.
    var remoteLoad: ((_ from: Int64, _ to: Int64, _ maxPoints: Int?, _ done: @escaping (History?) -> Void) -> Void)?
    var isRemote: Bool { remoteLoad != nil }

    /// Forgets what is shown, for when the window turns to a different Mac.
    func reset() {
        generation += 1
        // An empty frame ending now, not one at 1970: the tracks place the pointer by the frame's times.
        let now = Date().msSince1970
        history = History(from: now - Int64(lengthSeconds) * 1000, to: now)
        pin = nil; hover = nil; focus = nil; end = nil
        lastQuery = .distantPast
    }

    private let model: AppModel
    private let settings: AppSettings
    private var generation = 0
    private var lastQuery = Date.distantPast
    private var lastStats = Date.distantPast
    private var cancellable: AnyCancellable?

    init(model: AppModel, settings: AppSettings) {
        self.model = model
        self.settings = settings
        cancellable = model.$snapshot.receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh(force: false) }
        otherVMsSetting = settings.$showOtherVMs.dropFirst().receive(on: RunLoop.main).sink { [weak self] _ in self?.refresh(force: true) }
    }

    private var otherVMsSetting: AnyCancellable?

    private func shown(_ h: History) -> History {
        settings.showOtherVMs ? h : OtherVMs.hidden(in: h)
    }

    var isLive: Bool { end == nil }
    var frameEnd: Date { end ?? Date() }
    var frameStart: Date { frameEnd.addingTimeInterval(-Double(lengthSeconds)) }

    /// The moment the table and tiles describe; nil means "now" (live with nothing pinned or hovered).
    var readoutTime: Date? { pin ?? hover ?? (isLive ? nil : frameEnd) }

    // MARK: Navigation

    func select(length: Int) {
        var newEnd = end
        // With a pinned moment, zoom around it; stay live only if the pin is still inside the live frame.
        if let pin, !(isLive && pin > Date().addingTimeInterval(-Double(length))) {
            newEnd = pin.addingTimeInterval(Double(length) / 2)
        }
        lengthSeconds = length
        setEnd(newEnd)
    }

    func stepBack() { setEnd(frameEnd.addingTimeInterval(-Double(lengthSeconds) / 2)) }
    func stepForward() { if !isLive { setEnd(frameEnd.addingTimeInterval(Double(lengthSeconds) / 2)) } }
    func goLive() { pin = nil; hover = nil; setEnd(nil) }

    func jump(to date: Date) {
        let t = min(date, Date())
        pin = t
        setEnd(t.addingTimeInterval(Double(lengthSeconds) / 2))
    }

    /// Moves the pinned moment by whole samples (negative = earlier). With nothing pinned it starts from the end of the frame.
    func stepPin(samples: Int) {
        let step = max(1000, Int64(history.bucketMs)) * Int64(samples)
        let base = (pin ?? frameEnd).msSince1970
        let latest = min(history.to, Date().msSince1970)
        pin = Date(ms: min(max(history.from, base + step), latest))
    }

    private func setEnd(_ date: Date?) {
        if let date, date < Date() { end = date } else { end = nil }
        hover = nil
        refresh(force: true)
    }

    // MARK: Loading

    func refresh(force: Bool) {
        guard isActive else { return }
        let to = frameEnd.msSince1970, from = to - Int64(lengthSeconds) * 1000
        if let remoteLoad {
            // Another Mac: ask the hub. A live frame is asked again every five seconds, a fixed one only when it changes.
            if !force, !(isLive && Date().timeIntervalSince(lastQuery) >= 5) { return }
            lastQuery = Date()
            generation += 1
            let g = generation
            remoteLoad(from, to, 800) { [weak self] h in
                guard let self, g == self.generation, let h else { return }
                self.history = self.shown(h)
                // A pointer position read against an older frame means nothing in this one.
                if let hover = self.hover?.msSince1970, hover < h.from || hover > h.to { self.hover = nil }
            }
            return
        }
        if isLive, lengthSeconds <= 3600 {
            // Short live frames come straight from memory: no disk access, updates on every sample.
            generation += 1
            history = shown(model.ring.history(from: from, to: to, bucketMs: Double(settings.sampleInterval) * 1000))
        } else {
            // Long live frames barely move per sample; re-query them twice a minute.
            if !force, !(isLive && Date().timeIntervalSince(lastQuery) >= 30) { return }
            guard let store = model.store else { history = History(from: from, to: to); return }
            lastQuery = Date()
            generation += 1
            let g = generation
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let h = store.load(from: from, to: to, maxPoints: 800)
                DispatchQueue.main.async {
                    guard let self, g == self.generation else { return } // a newer request superseded this one
                    self.history = self.shown(h)
                }
            }
        }
        if Date().timeIntervalSince(lastStats) >= 30 { refreshStats() }
    }

    func refreshStats() {
        guard !isRemote, let store = model.store else { return }
        lastStats = Date()
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let s = store.stats()
            DispatchQueue.main.async { self?.stats = s }
        }
    }
}
