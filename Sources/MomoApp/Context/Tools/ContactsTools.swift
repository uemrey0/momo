@preconcurrency import Contacts
import Foundation
import MomoKit

/// Looks people up in the user's contacts, to find a phone number or email address.
enum ContactsTools {
    static func all() -> [any MomoTool] {
        [searchContacts()]
    }

    static func searchContacts() -> any MomoTool {
        ClosureTool(
            ToolDefinition(
                name: "search_contacts",
                description:
                    "Look up people in the user's Contacts by name, email or phone number and get their phone numbers and email addresses. Use it before send_message or compose_email when the user names a person.",
                parameters: JSONSchema.object(
                    ["query": JSONSchema.string("A name, email address or phone number")],
                    required: ["query"]),
                activityLabel: L("Looking up contacts"))
        ) { arguments in
            guard
                let query = arguments["query"]?.stringValue?
                    .trimmingCharacters(in: .whitespaces), !query.isEmpty
            else {
                throw ToolError("A name, email or phone number is required.")
            }
            let store = CNContactStore()
            try await ensureAccess(store)
            let keys: [any CNKeyDescriptor] = [
                CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
                CNContactOrganizationNameKey, CNContactPhoneNumbersKey, CNContactEmailAddressesKey,
            ].map { $0 as NSString }
            let predicate: NSPredicate
            if query.contains("@") {
                predicate = CNContact.predicateForContacts(matchingEmailAddress: query)
            } else if query.filter(\.isNumber).count >= 5, !query.contains(where: \.isLetter) {
                predicate = CNContact.predicateForContacts(
                    matching: CNPhoneNumber(stringValue: query))
            } else {
                predicate = CNContact.predicateForContacts(matchingName: query)
            }
            let contacts = try store.unifiedContacts(matching: predicate, keysToFetch: keys)
            guard !contacts.isEmpty else { return "No contacts match “\(query)”." }
            return contacts.prefix(10).map(describe).joined(separator: "\n")
        }
    }

    private static func ensureAccess(_ store: CNContactStore) async throws {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized:
            return
        case .notDetermined:
            if (try? await store.requestAccess(for: .contacts)) == true { return }
        default:
            break
        }
        throw PermissionRequired(.contacts, "Momo can't read Contacts: access is off.")
    }

    /// "Ayşe Yılmaz (Acme) — phone: mobile +90 555 …; email: work ayse@…"
    private static func describe(_ contact: CNContact) -> String {
        var name = [contact.givenName, contact.familyName].filter { !$0.isEmpty }
            .joined(separator: " ")
        if name.isEmpty { name = contact.nickname.isEmpty ? "(no name)" : contact.nickname }
        if !contact.organizationName.isEmpty { name += " (\(contact.organizationName))" }
        var parts = [name]
        let phones = contact.phoneNumbers.map { labeled($0.label, $0.value.stringValue) }
        if !phones.isEmpty { parts.append("phone: " + phones.joined(separator: ", ")) }
        let emails = contact.emailAddresses.map { labeled($0.label, $0.value as String) }
        if !emails.isEmpty { parts.append("email: " + emails.joined(separator: ", ")) }
        return parts.joined(separator: " — ")
    }

    private static func labeled(_ label: String?, _ value: String) -> String {
        guard let label, !label.isEmpty else { return value }
        return "\(CNLabeledValue<NSString>.localizedString(forLabel: label)) \(value)"
    }
}
