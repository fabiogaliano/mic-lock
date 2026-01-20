import Foundation

// MARK: - Raw Mode

func enableRawMode() -> termios {
    var raw = termios()
    tcgetattr(STDIN_FILENO, &raw)
    let original = raw
    raw.c_lflag &= ~UInt(ICANON | ECHO)
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    return original
}

func disableRawMode(_ original: termios) {
    var term = original
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &term)
}

// MARK: - Key Reading

enum Key: Equatable {
    case up
    case down
    case enter
    case space
    case escape
    case char(Character)
    case unknown
}

func readKey() -> Key {
    var buf = [UInt8](repeating: 0, count: 3)
    let n = read(STDIN_FILENO, &buf, 3)

    if n == 1 {
        switch buf[0] {
        case 0x0D, 0x0A: return .enter
        case 0x20: return .space
        case 0x1B: return .escape
        case 0x71: return .char("q")
        case 0x6A: return .down   // j
        case 0x6B: return .up     // k
        default:
            let scalar = Unicode.Scalar(buf[0])
            return .char(Character(scalar))
        }
    } else if n == 3 && buf[0] == 27 && buf[1] == 91 {
        switch buf[2] {
        case 65: return .up
        case 66: return .down
        default: return .unknown
        }
    }
    return .unknown
}

// MARK: - ANSI Escape Codes

enum Ansi {
    static let clearScreen = "\u{001B}[H\u{001B}[J"
    static let clearLine = "\u{001B}[K"
    static let hideCursor = "\u{001B}[?25l"
    static let showCursor = "\u{001B}[?25h"
    static let reverseVideo = "\u{001B}[7m"
    static let reset = "\u{001B}[0m"
    static let moveHome = "\u{001B}[H"

    static func moveTo(row: Int, col: Int) -> String {
        "\u{001B}[\(row);\(col)H"
    }
}
