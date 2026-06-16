import Foundation

/// Codable representation of a user-authored terminal color scheme as stored
/// on disk in `~/tbd/terminal-themes/<id>.json`. Converts to a runtime
/// `TerminalColorScheme` for the renderer. See the user-custom-terminal-themes
/// design doc.
struct UserTerminalTheme: Codable, Equatable, Hashable {
    let schemaVersion: Int
    let id: String
    let displayName: String
    let ansi: [String]
    let foreground: String
    let background: String
    let cursor: String
    let selection: String

    enum ValidationError: Error, Equatable {
        case wrongAnsiCount(Int)
        case invalidHex(field: String, value: String)
        case invalidID(String)
        case unsupportedSchemaVersion(Int)
    }

    func validated() throws -> UserTerminalTheme {
        guard schemaVersion == 1 else {
            throw ValidationError.unsupportedSchemaVersion(schemaVersion)
        }
        guard ansi.count == 16 else { throw ValidationError.wrongAnsiCount(ansi.count) }
        for (i, hex) in ansi.enumerated() {
            guard Self.parseHex(hex) != nil else {
                throw ValidationError.invalidHex(field: "ansi[\(i)]", value: hex)
            }
        }
        for (name, hex) in [
            ("foreground", foreground), ("background", background),
            ("cursor", cursor), ("selection", selection)
        ] {
            guard Self.parseHex(hex) != nil else {
                throw ValidationError.invalidHex(field: name, value: hex)
            }
        }
        guard !id.isEmpty, id.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil else {
            throw ValidationError.invalidID(id)
        }
        return self
    }

    func toScheme() throws -> TerminalColorScheme {
        _ = try validated()
        return TerminalColorScheme(
            id: id,
            displayName: displayName,
            ansi: ansi.map { Self.color(fromHex: $0)! },
            foreground: Self.color(fromHex: foreground)!,
            background: Self.color(fromHex: background)!,
            cursor: Self.color(fromHex: cursor)!,
            selection: Self.color(fromHex: selection)!
        )
    }

    static func parseHex(_ hex: String) -> (UInt8, UInt8, UInt8)? {
        guard let rgb = TerminalRGB(hex: hex) else { return nil }
        return (rgb.r, rgb.g, rgb.b)
    }

    static func color(fromHex hex: String) -> TerminalRGB? {
        TerminalRGB(hex: hex)
    }

    static func hex(from color: TerminalRGB) -> String {
        color.hexString
    }
}
