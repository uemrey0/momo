import AppKit
import Foundation
import MomoKit

/// Mail drafts and Messages. Momo never sends email itself: it opens a draft for the user to
/// review. Messages are only sent after the user confirms the recipient and the text.
enum CommunicationTools {
    static func all() -> [any MomoTool] {
        [composeEmail(), sendMessage()]
    }

    // MARK: - Mail

    static func composeEmail() -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "compose_email",
                description:
                    "Open a new email draft with recipients, subject and body filled in, for the user to review and send themselves. It never sends. Look up addresses with search_contacts first if the user gives a name.",
                parameters: JSONSchema.object(
                    [
                        "to": JSONSchema.string("Recipient email addresses, comma separated"),
                        "cc": JSONSchema.string("Optional CC addresses, comma separated"),
                        "subject": JSONSchema.string("Subject line"),
                        "body": JSONSchema.string("The email's text"),
                    ], required: ["subject", "body"]),
                activityLabel: L("Writing an email draft"))
        ) { arguments in
            let to = addresses(arguments["to"]?.stringValue)
            let cc = addresses(arguments["cc"]?.stringValue)
            let subject = arguments["subject"]?.stringValue ?? ""
            let body = arguments["body"]?.stringValue ?? ""
            if await usesAppleMail() {
                do {
                    try await draftInMail(to: to, cc: cc, subject: subject, body: body)
                    return "Opened a draft in Mail for the user to review. It has not been sent."
                } catch {
                    // Fall back to a mailto: link below, e.g. when Automation is not allowed.
                }
            }
            guard let url = mailtoURL(to: to, cc: cc, subject: subject, body: body) else {
                throw ToolError("I couldn't build the email draft.")
            }
            let opened = await MainActor.run { NSWorkspace.shared.open(url) }
            guard opened else { throw ToolError("No email app is set up.") }
            return "Opened a draft in the user's email app to review. It has not been sent."
        }
    }

    private static func addresses(_ text: String?) -> [String] {
        (text ?? "").split(whereSeparator: { $0 == "," || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    @MainActor
    private static func usesAppleMail() -> Bool {
        guard let probe = URL(string: "mailto:someone@example.com"),
            let app = NSWorkspace.shared.urlForApplication(toOpen: probe)
        else { return false }
        return Bundle(url: app)?.bundleIdentifier == "com.apple.mail"
    }

    private static func draftInMail(
        to: [String], cc: [String], subject: String, body: String
    ) async throws {
        var lines = [
            "tell application \"Mail\"",
            "set draft to make new outgoing message with properties {subject:\(AppleScriptText.literal(subject)), content:\(AppleScriptText.literal(body)), visible:true}",
            "tell draft",
        ]
        for address in to {
            lines.append(
                "make new to recipient at end of to recipients with properties {address:\(AppleScriptText.literal(address))}"
            )
        }
        for address in cc {
            lines.append(
                "make new cc recipient at end of cc recipients with properties {address:\(AppleScriptText.literal(address))}"
            )
        }
        lines += ["end tell", "activate", "end tell"]
        _ = try await AppleScriptRunner.run(lines.joined(separator: "\n"))
    }

    /// A `mailto:` URL with percent-encoded fields.
    static func mailtoURL(to: [String], cc: [String], subject: String, body: String) -> URL? {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = to.joined(separator: ",")
        var items = [
            URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body),
        ]
        if !cc.isEmpty { items.append(URLQueryItem(name: "cc", value: cc.joined(separator: ","))) }
        components.queryItems = items
        // URLComponents leaves "+" alone, which mail apps read as a space.
        components.percentEncodedQuery = components.percentEncodedQuery?
            .replacingOccurrences(of: "+", with: "%2B")
        return components.url
    }

    // MARK: - Messages

    static func sendMessage() -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "send_message",
                description:
                    "Send an iMessage (or SMS through the user's iPhone) with the Messages app. The recipient must be a phone number or email address; use search_contacts to find it when the user gives a name. The user confirms before it is sent.",
                parameters: JSONSchema.object(
                    [
                        "recipient": JSONSchema.string(
                            "Phone number (with country code if known) or email address"),
                        "text": JSONSchema.string("The message to send"),
                    ], required: ["recipient", "text"]),
                requiresConfirmation: true, activityLabel: L("Sending a message")),
            summary: { arguments in
                String(
                    format: L("Send a message to %@:\n“%@”"),
                    arguments["recipient"]?.stringValue ?? "", arguments["text"]?.stringValue ?? "")
            }
        ) { arguments in
            guard
                let recipient = arguments["recipient"]?.stringValue?
                    .trimmingCharacters(in: .whitespaces), isValidRecipient(recipient)
            else {
                throw ToolError(
                    "The recipient must be a phone number or an email address. Look it up with search_contacts."
                )
            }
            guard let text = arguments["text"]?.stringValue, !text.isEmpty else {
                throw ToolError("The message text is empty.")
            }
            let recipientLiteral = AppleScriptText.literal(recipient)
            let textLiteral = AppleScriptText.literal(text)
            let script = """
                tell application "Messages"
                    try
                        set theService to first account whose service type = iMessage
                        send \(textLiteral) to participant \(recipientLiteral) of theService
                        return "iMessage"
                    on error
                        set theService to first account whose service type = SMS
                        send \(textLiteral) to participant \(recipientLiteral) of theService
                        return "SMS"
                    end try
                end tell
                """
            let service = try await AppleScriptRunner.run(script)
            return
                "Sent the message to \(recipient) via \(service). Messages doesn't report delivery, so the user can check the Messages app."
        }
    }

    /// Accepts email addresses and phone numbers such as "+90 (555) 123-45-67".
    static func isValidRecipient(_ recipient: String) -> Bool {
        if recipient.contains("@") {
            return recipient.split(separator: "@").count == 2 && !recipient.contains(" ")
        }
        let allowed = CharacterSet(charactersIn: "+0123456789 ()-.")
        let digits = recipient.filter(\.isNumber).count
        return digits >= 3 && recipient.unicodeScalars.allSatisfy(allowed.contains)
    }
}
