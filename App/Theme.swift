import AppKit
import SwiftUI

/// Design tokens for direction G, Warm Glass Piles. Views use these, never raw values.
/// Light and dark are paired values, never inverted at runtime.
enum Theme {
    // Surfaces
    static let surface = Color(light: 0xFAF7F2, dark: 0x1A1917)
    static let card = Color(light: 0xFFFFFF, dark: 0x262421)
    static let glassTint = Color(light: 0xF4F1EA, dark: 0x2A2724)

    // Text
    static let text = Color(light: 0x1A1A1A, dark: 0xECE8E0)
    static let secondary = Color(light: 0x6B665E, dark: 0xABA7A0)

    // Decisions. Fills carry an onAccent label at 5:1 or better; the plain values are for icons and text on the surface.
    static let keepFill = Color(light: 0x4A6741, dark: 0x4A6741)
    static let tossFill = Color(light: 0xA35F20, dark: 0xA35F20)
    static let keep = Color(light: 0x4A6741, dark: 0x8FB28A)
    static let toss = Color(light: 0xA35F20, dark: 0xD9A85F)
    /// Text and symbols on a keep or toss fill.
    static let onAccent = Color(light: 0xFFFFFF, dark: 0xFFFFFF)

    /// Prominent buttons that neither save nor ditch, such as Choose a folder. Neutral, so green
    /// and amber only ever mean save and ditch. White on it is 9.1:1 light and 6.9:1 dark.
    static let actionFill = Color(light: 0x4D4943, dark: 0x5C5852)

    // List rows in the column views
    /// The highlighted row, neutral for the same reason.
    static let rowSelected = actionFill
    static let rowOnPath = Color(light: 0x1A1A1A, dark: 0xECE8E0, lightAlpha: 0.12, darkAlpha: 0.14)
    static let rowHover = Color(light: 0x1A1A1A, dark: 0xECE8E0, lightAlpha: 0.06, darkAlpha: 0.08)
    static let rowPressed = Color(light: 0x1A1A1A, dark: 0xECE8E0, lightAlpha: 0.10, darkAlpha: 0.12)
    static let notice = Color(light: 0x1A1A1A, dark: 0xECE8E0, lightAlpha: 0.05, darkAlpha: 0.07)

    /// How strongly the warm surface tints the translucent window, from the Transparency
    /// setting (0 solid, 1 most see-through). It never drops below 0.3, so text stays readable.
    static func windowTint(transparency: Double) -> Double {
        1 - 0.7 * min(max(transparency, 0), 1)
    }

    enum Font {
        static let hero = SwiftUI.Font.system(size: 64, weight: .semibold, design: .serif)
        static let title = SwiftUI.Font.system(size: 40, weight: .semibold, design: .serif)
        static let sheetTitle = SwiftUI.Font.system(size: 26, weight: .semibold, design: .serif)
        static let fileName = SwiftUI.Font.system(size: 20, weight: .medium, design: .serif)
        static let count = SwiftUI.Font.system(size: 34, weight: .medium, design: .serif)
        static let bigCount = SwiftUI.Font.system(size: 56, weight: .medium, design: .serif)
    }

    enum Space {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 16
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
        static let xxl: CGFloat = 48
    }

    enum Radius {
        static let row: CGFloat = 6
        static let control: CGFloat = 8
        static let card: CGFloat = 12
        static let tray: CGFloat = 20
        static let panel: CGFloat = 24
    }

    /// Shadow plus tint for elevation; deeper and softer in dark mode.
    enum Shadow {
        static let card = Color(light: 0x000000, dark: 0x000000, lightAlpha: 0.14, darkAlpha: 0.45)
        static let cardRadius: CGFloat = 24
        static let cardY: CGFloat = 10
        static let thumb = Color(light: 0x000000, dark: 0x000000, lightAlpha: 0.14, darkAlpha: 0.40)
        static let thumbRadius: CGFloat = 6
        static let thumbY: CGFloat = 3
    }

    /// Symbol and icon sizes.
    enum Symbol {
        static let badge: CGFloat = 20
        static let status: CGFloat = 44
        static let message: CGFloat = 56
        static let fileIcon: CGFloat = 128
    }

    /// Calm ease-out, no overshoot.
    enum Motion {
        static let fast = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.2)
        static let base = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.4)
        static let slow = Animation.timingCurve(0.22, 1, 0.36, 1, duration: 0.6)
    }

    enum Swipe {
        /// How far a card must travel before letting go decides it.
        static let threshold: CGFloat = 120
    }

    enum Size {
        static let trayWidth: CGFloat = 156
        static let trayWidthLarge: CGFloat = 220
        static let cardMaxWidth: CGFloat = 820
        static let columnWidth: CGFloat = 248
        static let columnsHeight: CGFloat = 188
        /// A column row's drawn height; the click target is padded to `rowHitHeight`.
        static let rowHeight: CGFloat = 26
        static let rowHitHeight: CGFloat = 32
        static let rowIcon: CGFloat = 18
        static let headerHeight: CGFloat = 36
        static let trayThumb: CGFloat = 60
        static let trayThumbLarge: CGFloat = 96
        static let gridThumb: CGFloat = 64
        static let gridCell: CGFloat = 104
        static let gridMaxWidth: CGFloat = 640
        /// Sheets, the confirm and review lists inside them, and list thumbnails.
        static let sheetWidth: CGFloat = 560
        static let sheetListMin: CGFloat = 120
        static let sheetListMax: CGFloat = 340
        static let listThumb: CGFloat = 32
        static let listRowHeight: CGFloat = 36
        /// The tray popover list.
        static let popoverWidth: CGFloat = 340
        static let popoverMaxHeight: CGFloat = 420
        /// The find field, the path menu and short reading measures.
        static let findWidth: CGFloat = 340
        static let pathWidth: CGFloat = 360
        static let readingWidth: CGFloat = 440
        static let startListWidth: CGFloat = 320
        /// Chips, key caps and the progress ring.
        static let chipHeight: CGFloat = 22
        static let keyCap: CGFloat = 20
        static let ring: CGFloat = 14
        static let ringLine: CGFloat = 2.5
        static let decisionButtonMinWidth: CGFloat = 96
        static let primaryButtonMinWidth: CGFloat = 200
        /// How far each card waiting underneath sits below the one above it.
        static let backCardStep: CGFloat = 12
        static let dropLine: CGFloat = 3
        static let progressWidth: CGFloat = 120
        static let settingsWidth: CGFloat = 520
        static let settingsGeneralHeight: CGFloat = 260
        static let settingsRemindersHeight: CGFloat = 470
        /// The smallest the main window goes; every screen is checked at this size.
        static let windowMinWidth: CGFloat = 860
        static let windowMinHeight: CGFloat = 720
    }
}

extension Color {
    /// A colour with separate light and dark values, given as 0xRRGGBB, with optional opacity.
    init(light: UInt32, dark: UInt32, lightAlpha: Double = 1, darkAlpha: Double = 1) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: isDark ? darkAlpha : lightAlpha)
        })
    }
}

/// Hover, press and selection fills for list rows, so every row has its states.
struct RowButtonStyle: ButtonStyle {
    var selection: Color?

    func makeBody(configuration: Configuration) -> some View {
        RowBody(configuration: configuration, selection: selection)
    }

    private struct RowBody: View {
        let configuration: ButtonStyleConfiguration
        let selection: Color?
        @State private var isHovering = false

        var body: some View {
            let shape = RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
            configuration.label
                // Hover and press show over a selection too, under the label.
                .background(shape.fill(selection ?? .clear).overlay(shape.fill(state)))
                .padding(.vertical, (Theme.Size.rowHitHeight - Theme.Size.rowHeight) / 2)
                .contentShape(Rectangle())
                .onHover { isHovering = $0 }
        }

        private var state: Color {
            if configuration.isPressed { return Theme.rowPressed }
            return isHovering ? Theme.rowHover : .clear
        }
    }
}

extension View {
    /// Warm Liquid Glass in the given shape, the house style for every glass surface.
    func warmGlass(in shape: some Shape, interactive: Bool = false) -> some View {
        glassEffect(.regular.tint(Theme.glassTint.opacity(0.45)).interactive(interactive), in: shape)
    }
}
