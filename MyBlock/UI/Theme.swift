// All visual tokens live here. Views must not hard-code colors, fonts or spacing.
//
// Direction: Swiss / Olympic-poster graphic design. White ground, navy type, the style-board
// colors used as flat blocks (track red, sun yellow, sky blue). Titles in Archivo Expanded,
// body in Roboto. Sentence case, a strict grid,
// hairline rules instead of boxes, square corners, no outlines or fake shadows.

import CoreText
import SwiftUI

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

enum Theme {
    // MARK: Palette (from the style board)
    static let white = Color.white
    /// Ink: type, icons, rules.
    static let navy = Color(hex: 0x0B1B3F)
    /// Track red: the one primary action, and the running surface.
    static let red = Color(hex: 0xC9503F)
    static let redPressed = Color(hex: 0xA63F31)
    /// Sun yellow: the coaching cue, highlights.
    static let yellow = Color(hex: 0xF8D86A)
    /// Sky blue: secondary accent.
    static let sky = Color(hex: 0x5FA0D9)
    /// Old-paper cream from the board, used only as an occasional warm band.
    static let cream = Color(hex: 0xFFF5DD)
    /// Deeper sky for text and marks on white (the light sky is too pale for type).
    static let skyDeep = Color(hex: 0x2F6FB0)
    /// Cool light grey for input fields and secondary buttons.
    static let tint = Color(hex: 0xEEF1F5)

    /// Section accents cycle through the board colors, like the circles on the style board.
    static let accents: [Color] = [red, sky, yellow, navy]

    // MARK: Roles
    static let background = white
    static let surface = tint
    static let text = navy
    static let textMuted = navy.opacity(0.6)
    static let hairline = navy.opacity(0.12)
    static let accent = red
    static let accentText = white
    /// Text on dark (camera, video) backgrounds.
    static let onDark = white

    // MARK: Grades. Each also has its own icon, so color is never the only signal.
    static let gradeGood = Color(hex: 0x2F6FB0)
    static let gradeNear = Color(hex: 0xD9A21F)
    static let gradeOff = red
    static let gradeUnknown = navy.opacity(0.35)

    enum Space {
        static let xs: CGFloat = 4
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        /// Side margin of every screen.
        static let gutter: CGFloat = 20
    }

    enum Radius {
        static let sm: CGFloat = 2
        static let md: CGFloat = 4
    }

    /// Minimum touch target.
    static let minTouch: CGFloat = 48

    // MARK: Type

    enum Fonts {
        /// Archivo Expanded: a wide, heavy grotesque with lowercase, close to Horizon.
        /// Bundled from Google Fonts (SIL Open Font License).
        enum TitleWeight: String {
            case black = "ArchivoExpanded-Black"
            case extraBold = "ArchivoExpanded-ExtraBold"
        }

        static func title(_ size: CGFloat, relativeTo style: Font.TextStyle = .title, weight: TitleWeight = .black) -> Font {
            .custom(weight.rawValue, size: size, relativeTo: style)
        }

        /// Fixed-size titles for full-screen start states and illustrations (no Dynamic Type).
        static func titleFixed(_ size: CGFloat, weight: TitleWeight = .black) -> Font {
            .custom(weight.rawValue, fixedSize: size)
        }

        static func roboto(_ weight: RobotoWeight, _ size: CGFloat, relativeTo style: Font.TextStyle) -> Font {
            .custom(weight.postScriptName, size: size, relativeTo: style)
        }

        static let display = title(40, relativeTo: .largeTitle)
        static let screenTitle = title(26, relativeTo: .title)
        static let sectionTitle = title(17, relativeTo: .headline, weight: .extraBold)
        /// Big numbers (scores, setting values).
        static let number = title(22, relativeTo: .title2, weight: .extraBold)
        static let bigNumber = title(46, relativeTo: .largeTitle)
        /// Small label above content ("Next rep"), sentence case.
        static let meta = roboto(.medium, 13, relativeTo: .footnote)

        static let heading = roboto(.bold, 17, relativeTo: .headline)
        static let label = roboto(.medium, 17, relativeTo: .body)
        static let body = roboto(.regular, 16, relativeTo: .body)
        static let small = roboto(.regular, 14, relativeTo: .footnote)
        static let smallBold = roboto(.bold, 14, relativeTo: .footnote)
        static let button = roboto(.bold, 17, relativeTo: .body)
        static let cue = roboto(.bold, 22, relativeTo: .title2)
    }

    enum RobotoWeight {
        case regular, medium, bold, black
        var postScriptName: String {
            switch self {
            case .regular: "Roboto-Regular"
            case .medium: "Roboto-Medium"
            case .bold: "Roboto-Bold"
            case .black: "Roboto-Black"
            }
        }
    }

    /// Full-screen tints behind the start states. Text carries the meaning; color supports it.
    enum Stage {
        static let ready = Color(hex: 0x0B1B3F, opacity: 0.7)
        static let marks = Color(hex: 0x0B1B3F, opacity: 0.92)
        static let set = Color(hex: 0xF8D86A)
        static let go = Color(hex: 0xC9503F)
        static let done = Color(hex: 0x2F6FB0)
        static let failed = Color(hex: 0x0B1B3F)
    }
}

/// Registers the bundled fonts (Archivo Expanded, Roboto) once at launch.
enum FontRegistry {
    static func registerBundledFonts() {
        let urls = ["ttf", "otf"].flatMap { Bundle.main.urls(forResourcesWithExtension: $0, subdirectory: nil) ?? [] }
        for url in urls {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}

enum TextStyle {
    case title, heading, body, small

    var font: Font {
        switch self {
        case .title: Theme.Fonts.screenTitle
        case .heading: Theme.Fonts.heading
        case .body: Theme.Fonts.body
        case .small: Theme.Fonts.small
        }
    }

    var color: Color { self == .small ? Theme.textMuted : Theme.text }
}

extension View {
    func textStyle(_ style: TextStyle) -> some View {
        font(style.font).foregroundStyle(style.color)
    }
}

extension Grade {
    var color: Color {
        switch self {
        case .green: Theme.gradeGood
        case .yellow: Theme.gradeNear
        case .red: Theme.gradeOff
        case .unknown: Theme.gradeUnknown
        }
    }
}
