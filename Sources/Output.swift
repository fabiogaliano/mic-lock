import Foundation
import Rainbow

// MARK: - Symbols

enum Sym {
    static let check = "✓".green
    static let cross = "✗".red
    static let arrow = "→".dim
    static let arrowUp = "↑"
    static let arrowDown = "↓"
    static let arrowLeft = "←"
    static let bullet = "•"
    static let signal = "▮".green
    static let silent = "▯".dim
    static let plus = "+".green
    static let minus = "-".red
    static let question = "?".yellow
    static let warning = "!".yellow
    static let cursor = "▸"
    static let current = "→".cyan
    static let priority = "●"
}

// MARK: - Text Styles

extension String {
    /// Secondary/muted text (device full names, hints)
    var muted: String { self.dim }

    /// Primary emphasis
    var primary: String { self.bold }

    /// Success state
    var success: String { self.green }

    /// Error state
    var error: String { self.red }

    /// Warning state
    var warn: String { self.yellow }

    /// Accent color for current/active items
    var accent: String { self.cyan }
}

// MARK: - Formatted Output

/// Format device name with optional alias
func formatDevice(_ name: String, alias: String?) -> String {
    if let alias = alias {
        return "\(alias.primary) \("(\(name))".muted)"
    }
    return name
}

/// Format priority position badge
func formatPosition(_ pos: Int) -> String {
    "[\(pos)]".cyan
}

/// Format RMS level display
func formatRMS(_ rms: Float, threshold: Float) -> String {
    let value = String(format: "%.6f", rms)
    let hasSignal = rms >= threshold
    let icon = hasSignal ? Sym.signal : Sym.silent
    let label = hasSignal ? "signal".dim : "silent".dim
    return "\(icon) \(value.dim) \(label)"
}

// MARK: - Section Headers

func printHeader(_ title: String) {
    print("\n\(title.primary)")
    print(String(repeating: "─", count: 40).dim)
}

func printSubtle(_ message: String) {
    print(message.muted)
}

// MARK: - Status Messages

func printSuccess(_ message: String) {
    print("\(Sym.check) \(message)")
}

func printError(_ message: String) {
    print("\(Sym.cross) \(message)")
}

func printWarning(_ message: String) {
    print("\(Sym.warning) \(message)")
}

func printInfo(_ message: String) {
    print("\(Sym.arrow) \(message)")
}
