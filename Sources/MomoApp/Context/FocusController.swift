import Foundation
import Observation

/// A focus session: Momo stays quiet and concentrated, then celebrates when time is up.
@MainActor
@Observable
final class FocusController {
    private(set) var endDate: Date?
    private(set) var task: String?
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private weak var character: CharacterController?
    @ObservationIgnored var onFinish: ((String?) -> Void)?

    init(character: CharacterController) {
        self.character = character
    }

    var isActive: Bool { endDate != nil }

    func start(minutes: Int, task: String? = nil) {
        let minutes = min(180, max(1, minutes))
        stop(celebrate: false)
        endDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        self.task = task
        character?.ambientMood = .focused
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(minutes * 60))
            guard !Task.isCancelled else { return }
            self?.stop(celebrate: true)
        }
    }

    func stop(celebrate: Bool = false) {
        timer?.cancel()
        timer = nil
        let finishedTask = task
        let wasActive = endDate != nil
        endDate = nil
        task = nil
        if character?.ambientMood == .focused { character?.ambientMood = nil }
        if celebrate && wasActive {
            character?.celebrate()
            onFinish?(finishedTask)
        }
    }
}
