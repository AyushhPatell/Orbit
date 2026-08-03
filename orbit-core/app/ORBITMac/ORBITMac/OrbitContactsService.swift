//
//  OrbitContactsService.swift
//  ORBITMac
//
//  CNContactStore wrapper — fuzzy contact lookup for call/message intents.
//

import Contacts
import Foundation

@MainActor
class OrbitContactsService {
    static let shared = OrbitContactsService()
    private let store = CNContactStore()
    private var accessGranted = false

    private init() {}

    // MARK: - Access

    var hasAccess: Bool {
        if accessGranted { return true }
        let status = CNContactStore.authorizationStatus(for: .contacts)
        switch status {
        case .authorized:
            accessGranted = true; return true
        case .denied, .restricted, .notDetermined:
            return false
        default:
            accessGranted = true; return true
        }
    }

    func requestAccessIfNeeded() async {
        guard !hasAccess else { return }
        do {
            let granted = try await store.requestAccess(for: .contacts)
            accessGranted = granted
        } catch {
            accessGranted = false
        }
    }

    // MARK: - Lookup

    private static let fetchKeys: [CNKeyDescriptor] = [
        CNContactGivenNameKey as CNKeyDescriptor,
        CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactNicknameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor,
    ]

    /// Returns the best matching contact for a spoken name query.
    func findContact(named query: String) throws -> CNContact? {
        guard hasAccess else {
            throw OrbitContactsError.noAccess
        }
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return nil }

        // Try CNContact's built-in name predicate first (handles full names well)
        let predicate = CNContact.predicateForContacts(matchingName: q)
        let matches = try store.unifiedContacts(matching: predicate, keysToFetch: Self.fetchKeys)
        if let first = matches.first { return first }

        // Fallback: fetch all and do fuzzy contains match on given + family name
        var result: CNContact?
        let fetchRequest = CNContactFetchRequest(keysToFetch: Self.fetchKeys)
        try store.enumerateContacts(with: fetchRequest) { contact, stop in
            let full = "\(contact.givenName) \(contact.familyName)".lowercased().trimmingCharacters(in: .whitespaces)
            let nick = contact.nickname.lowercased()
            let lower = q.lowercased()
            if full.contains(lower) || nick.contains(lower)
                || contact.givenName.lowercased().contains(lower)
                || contact.familyName.lowercased().contains(lower) {
                result = contact
                stop.pointee = true
            }
        }
        return result
    }

    // MARK: - Best phone / email

    /// Prefers mobile, then iPhone, then first available.
    func bestPhone(for contact: CNContact) -> String? {
        let numbers = contact.phoneNumbers
        let mobileLabels: [CNLabeledValue<CNPhoneNumber>]
        mobileLabels = numbers.filter {
            let label = ($0.label ?? "").lowercased()
            return label.contains("mobile") || label.contains("iphone") || label == CNLabelPhoneNumberMobile
        }
        let chosen = mobileLabels.first ?? numbers.first
        return chosen?.value.stringValue
    }

    func bestEmail(for contact: CNContact) -> String? {
        contact.emailAddresses.first?.value as String?
    }

    func displayName(for contact: CNContact) -> String {
        let full = "\(contact.givenName) \(contact.familyName)".trimmingCharacters(in: .whitespacesAndNewlines)
        if !full.isEmpty { return full }
        if !contact.nickname.isEmpty { return contact.nickname }
        return contact.emailAddresses.first?.value as String? ?? "Unknown"
    }
}

enum OrbitContactsError: LocalizedError {
    case noAccess
    case notFound(String)

    var errorDescription: String? {
        switch self {
        case .noAccess:
            return "I don\u{2019}t have access to your Contacts. Allow access in System Settings \u{2192} Privacy & Security \u{2192} Contacts."
        case .notFound(let name):
            return "I couldn\u{2019}t find \u{201C}\(name)\u{201D} in your contacts."
        }
    }
}
