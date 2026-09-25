/// Something that happened on the Mac that Momo reacts to.
public enum FaceEvent: String, CaseIterable, Sendable, Identifiable {
    /// The user completed a task.
    case taskCompleted
    /// A calendar event starts soon.
    case meetingSoon
    /// A new email arrived.
    case newMail
    /// The battery is running low.
    case lowBattery
    /// Something Momo tried to do failed.
    case failure
    /// Screen sharing or recording started; Momo hides in the notch.
    case screenSharingStarted
    /// Screen sharing or recording ended; Momo comes back out.
    case screenSharingEnded
    /// It is very late at night.
    case lateNight

    public var id: String { rawValue }
}
