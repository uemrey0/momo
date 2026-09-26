import AVFoundation
import Foundation
import MomoKit

/// Tools that start and stop meeting notes. Reading past meetings is done by the store
/// tools (`list_meetings`, `get_meeting`, `meeting_action_items_to_tasks`).
enum MeetingTools {
    /// Built for each request, so the confirmation names the speech service in use.
    @MainActor
    static func all(controller: MeetingController) -> [any MomoTool] {
        [start(controller, cloudService: controller.cloudServiceName), stop(controller)]
    }

    static func start(_ controller: MeetingController, cloudService: String?) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "start_meeting_notes",
                description:
                    "Start taking notes of the meeting the user is in: Momo records their microphone and the call's audio, transcribes them and, when the meeting ends, writes a summary with decisions and action items. Only use it when the user asks.",
                parameters: JSONSchema.object([
                    "title": JSONSchema.string(
                        "Optional meeting title; defaults to the calendar event's title")
                ]),
                requiresConfirmation: true,
                activityLabel: L("Starting meeting notes", comment: "Tool activity")),
            summary: { _ in
                cloudService.map {
                    String(
                        format: L("Take notes of this meeting? The audio is transcribed by %@."),
                        $0)
                } ?? L("Take notes of this meeting? The audio is transcribed on this Mac.")
            }
        ) { arguments in
            // The user confirmed a question that named the service, which counts as consent.
            switch await controller.requestStart(
                title: arguments["title"]?.stringValue, approvedCloud: true)
            {
            case .started:
                return
                    "Started taking meeting notes. A red dot shows next to Momo while it records; the user can stop from the menu bar, the Meetings tab or by asking."
            case .waitingForAnswer:
                return
                    "Momo needs one more answer from the user in the Meetings tab (the Screen & System Audio Recording permission for the call's audio, which can also be allowed in Momo Settings → Permissions, or microphone only) before it starts."
            case .alreadyRunning:
                return "Momo is already taking notes of a meeting."
            case .failed(let reason):
                if AVCaptureDevice.authorizationStatus(for: .audio) == .denied {
                    throw PermissionRequired(
                        .microphone, "Could not start meeting notes: microphone access is off.")
                }
                throw ToolError("Could not start meeting notes: \(reason)")
            }
        }
    }

    static func stop(_ controller: MeetingController) -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "stop_meeting_notes",
                description:
                    "Stop taking meeting notes. Momo then writes the summary, saves it with the meeting and as a note.",
                activityLabel: L("Stopping meeting notes", comment: "Tool activity"))
        ) { _ in
            guard await controller.stop() else {
                return "Momo is not taking meeting notes right now."
            }
            return
                "Stopped recording. The summary is being written; it will appear in the Meetings tab and in Notes."
        }
    }
}
