import AppKit
import Security

/// The program that opened a link, as its code signature identifies it.
protocol LinkSender {
    /// Whether the program's signature is valid, carries the signing
    /// identifier `identifier`, and comes from this app's own team.
    func isSigned(as identifier: String) -> Bool
}

/// The sender of the Apple Event AppKit is handling, resolved to its running
/// code by the event's audit token, or by its pid when the event carries no
/// token.
struct AppleEventSender: LinkSender {
    let code: SecCode

    /// The sender of `NSAppleEventManager`'s current event; nil outside an
    /// event handler or when the sender's code cannot be found. Call it
    /// synchronously inside `application(_:open:)`, while the event is
    /// current and the sender's pid still names the sender.
    static func current() -> AppleEventSender? {
        guard let event = NSAppleEventManager.shared().currentAppleEvent else { return nil }
        var attributes: [CFString: Any] = [:]
        if let token = event.attributeDescriptor(forKeyword: AEKeyword(keySenderAuditTokenAttr))?.data,
           token.count == MemoryLayout<audit_token_t>.size {
            attributes[kSecGuestAttributeAudit] = token
        } else if let pid = event.attributeDescriptor(forKeyword: AEKeyword(keySenderPIDAttr))?.int32Value, pid > 0 {
            attributes[kSecGuestAttributePid] = pid
        } else {
            return nil
        }
        var code: SecCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &code) == errSecSuccess,
              let code else { return nil }
        return AppleEventSender(code: code)
    }

    func isSigned(as identifier: String) -> Bool {
        guard let team = Self.ownTeam, let requirement = Self.requirement(identifier: identifier, team: team)
        else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The team identifier of this app's own signature; nil for an unsigned
    /// or ad hoc build, which then trusts no sender.
    private static let ownTeam: String? = {
        var me: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
              == errSecSuccess,
              let team = (info as? [CFString: Any])?[kSecCodeInfoTeamIdentifier] as? String,
              isRequirementSafe(team)
        else { return nil }
        return team
    }()

    /// Signed by Apple's chain (Developer ID, App Store or Apple Development)
    /// to `team`, with signing identifier `identifier`.
    private static func requirement(identifier: String, team: String) -> SecRequirement? {
        guard isRequirementSafe(identifier) else { return nil }
        let text = "identifier \"\(identifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess else { return nil }
        return requirement
    }

    /// Letters, digits, dots and hyphens: a value that cannot end the quoted
    /// string of a requirement.
    private static func isRequirementSafe(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "." || $0 == "-"
        }
    }
}
