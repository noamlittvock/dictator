import AppKit
import SwiftUI

// MARK: - Adaptive Color Helper

extension NSColor {
    fileprivate convenience init?(dsHex hex: String) {
        let s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        let len = s.count
        guard let v = UInt64(s, radix: 16) else { return nil }
        switch len {
        case 6:
            self.init(srgbRed: Double((v>>16)&0xFF)/255, green: Double((v>>8)&0xFF)/255,
                      blue: Double(v&0xFF)/255, alpha: 1)
        case 8:
            self.init(srgbRed: Double((v>>24)&0xFF)/255, green: Double((v>>16)&0xFF)/255,
                      blue: Double((v>>8)&0xFF)/255, alpha: Double(v&0xFF)/255)
        default: return nil
        }
    }

    fileprivate static func ds(light: String, dark: String) -> NSColor {
        NSColor(name: nil) { app in
            let isDark = app.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(dsHex: isDark ? dark : light) ?? .black
        }
    }
}

// MARK: - Color Tokens

extension Color {
    // Surfaces
    static let dsBgContent     = Color(nsColor: .ds(light: "f5efe3", dark: "100d0b"))
    static let dsBgSidebar     = Color(nsColor: .ds(light: "eae1d2", dark: "1b1714"))
    static let dsSurfaceCard   = Color(nsColor: .ds(light: "fffbf3", dark: "211c18"))
    static let dsSurfaceRaised = Color(nsColor: .ds(light: "fffbf3", dark: "2a241f"))
    static let dsSurfaceControl = Color(nsColor: .ds(light: "fffbf3", dark: "352e27"))
    static let dsSurfaceSunken = Color(nsColor: .ds(light: "e8dfd0", dark: "0a0807"))

    // Hairlines & dividers
    static let dsBorderSubtle = Color(nsColor: .ds(light: "32261a18", dark: "efe4cf17"))
    static let dsBorder       = Color(nsColor: .ds(light: "32261a29", dark: "efe4cf29"))
    static let dsBorderStrong = Color(nsColor: .ds(light: "32261a4d", dark: "efe4cf4d"))
    static let dsDivider      = Color(nsColor: .ds(light: "32261a14", dark: "efe4cf17"))

    // Text
    static let dsTextPrimary   = Color(nsColor: .ds(light: "211a14", dark: "efe4cf"))
    static let dsTextSecondary = Color(nsColor: .ds(light: "625747", dark: "c9bfae"))
    static let dsTextTertiary  = Color(nsColor: .ds(light: "6d6254", dark: "a79b89"))

    // Poster red is decorative; the adaptive action red stays readable on surfaces.
    static let dsPosterRed = Color(nsColor: NSColor(dsHex: "d93a1a")!)

    // Brand accent
    static let dsAccent        = Color(nsColor: .ds(light: "b72e14", dark: "ef593b"))
    static let dsAccentHover   = Color(nsColor: .ds(light: "99230f", dark: "ff7559"))
    static let dsAccentQuiet   = Color(nsColor: .ds(light: "d93a1a14", dark: "d93a1a24"))
    static let dsAccentQStrong = Color(nsColor: .ds(light: "d93a1a29", dark: "d93a1a3d"))
    static let dsSignal3       = Color(nsColor: .ds(light: "a34b2c", dark: "eeb18b"))
    /// Text and symbols on a filled accent button.
    static let dsOnAccent      = Color(nsColor: .ds(light: "fffbf3", dark: "170f0b"))

    // Status
    static let dsSuccess       = Color(nsColor: .ds(light: "307344", dark: "79c27a"))
    static let dsSuccessQuiet  = Color(nsColor: .ds(light: "3073441a", dark: "79c27a1a"))
    static let dsWarning       = Color(nsColor: .ds(light: "80520e", dark: "e6b76a"))
    static let dsWarningQuiet  = Color(nsColor: .ds(light: "80520e1a", dark: "e6b76a1a"))

    // Roles in diagrams and spoken-phrase chips. Never for status or actions.
    static let dsDataTeal   = Color(nsColor: .ds(light: "2f7468", dark: "7cc4b4"))
    static let dsDataOchre  = Color(nsColor: .ds(light: "8a6412", dark: "dcb45f"))
    static let dsDataPlum   = Color(nsColor: .ds(light: "6f4a86", dark: "bda2d6"))
    static let dsDataSlate  = Color(nsColor: .ds(light: "4a6078", dark: "a3b6ca"))

    // Floating panels sit over other apps, so they are warm ink in both themes.
    static let dsPanelBackground    = Color(nsColor: NSColor(dsHex: "1a1512")!)
    static let dsPanelBorder        = Color(nsColor: NSColor(dsHex: "efe4cf2e")!)
    static let dsPanelText          = Color(nsColor: NSColor(dsHex: "f3eadb")!)
    static let dsPanelTextSecondary = Color(nsColor: NSColor(dsHex: "c9bfae")!)
    static let dsPanelAccent        = Color(nsColor: NSColor(dsHex: "ff8a6e")!)
    static let dsPanelSuccess       = Color(nsColor: NSColor(dsHex: "79c27a")!)
    static let dsPanelWarning       = Color(nsColor: NSColor(dsHex: "e6b76a")!)
}

// MARK: - Scales

/// Every gap, padding and inset in the app comes from this scale.
enum DSSpace {
    /// Between a line and the line that belongs to it.
    static let hair: CGFloat = 2
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 8
    static let s: CGFloat = 12
    static let m: CGFloat = 16
    static let l: CGFloat = 24
    static let xl: CGFloat = 32
    static let xxl: CGFloat = 48
}

enum DSRadius {
    /// Buttons, fields, chips and tabs.
    static let control: CGFloat = 6
    /// Cards, sheets' inner groups and panels.
    static let card: CGFloat = 10
}

enum DSLayout {
    /// The left and right edge of every page.
    static let gutter: CGFloat = 24
    /// The width of a page, gutters included. A reading page fills the
    /// default window, so pages end at the same edge as you move between them.
    static let readingPage: CGFloat = 768
    /// For pages that are lists or diagrams.
    static let widePage: CGFloat = 1088
    /// The width of a page's "?" brief.
    static let brief: CGFloat = 320
    /// The height of a Help picture, and the widest thing inside one.
    static let helpScene: CGFloat = 124
    static let helpSceneContent: CGFloat = 280
}

/// Text roles. SF for everything you work with; Anton for page titles only.
/// `DSFont` itself is for the brand lockup and eyebrows.
extension Font {
    static var dsPageTitle: Font { DSFont.display(28) }
    static let dsSheetTitle = Font.system(size: 15, weight: .semibold)
    static let dsSection = Font.system(size: 13, weight: .semibold)
    static let dsBody = Font.system(size: 13)
    static let dsBodyMedium = Font.system(size: 13, weight: .medium)
    static let dsSecondary = Font.system(size: 12)
    static let dsSecondaryMedium = Font.system(size: 12, weight: .medium)
    /// The smallest readable text in the app.
    static let dsCaption = Font.system(size: 11)
    static let dsCaptionMedium = Font.system(size: 11, weight: .medium)
    static let dsMono = Font.system(size: 12, design: .monospaced)
    static let dsMonoCaption = Font.system(size: 11, design: .monospaced)
    /// A single large number or phrase inside a card.
    static let dsStat = Font.system(size: 22, weight: .semibold)

    // SF Symbols.
    static let dsIconSmall = Font.system(size: 11)
    static let dsIcon = Font.system(size: 13)
    static let dsIconLarge = Font.system(size: 17)
    static let dsIconHero = Font.system(size: 28, weight: .light)
}

// MARK: - DSCard

/// The one card in the app. Fills its width; pass `padding: 0` for rows that
/// bring their own padding.
struct DSCard<Content: View>: View {
    var padding: CGFloat = DSSpace.m
    @ViewBuilder let content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .dsCardSurface()
    }
}

extension View {
    /// The card fill and hairline, for a shape that manages its own layout.
    func dsCardSurface(_ fill: Color = .dsSurfaceCard, border: Color = .dsBorderSubtle) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: DSRadius.card, style: .continuous).strokeBorder(border, lineWidth: 1))
    }
}

// MARK: - DSBadge

struct DSBadge: View {
    enum Tone { case neutral, accent, success, warning }
    let text: String
    var tone: Tone = .neutral
    var mono: Bool = false
    var caps: Bool = false

    private var bg: Color {
        switch tone {
        case .neutral: return Color.dsSurfaceControl
        case .accent:  return Color.dsAccentQuiet
        case .success: return Color.dsSuccessQuiet
        case .warning: return Color.dsWarningQuiet
        }
    }
    private var fg: Color {
        switch tone {
        case .neutral: return Color.dsTextSecondary
        case .accent:  return Color.dsAccent
        case .success: return Color.dsSuccess
        case .warning: return Color.dsWarning
        }
    }

    var body: some View {
        Text(caps ? text.uppercased() : text)
            .font(mono ? .dsMonoCaption : .dsCaptionMedium)
            .tracking(caps ? 0.6 : 0)
            .foregroundStyle(fg)
            .padding(.horizontal, DSSpace.xs).padding(.vertical, DSSpace.hair)
            .background(bg, in: Capsule())
    }
}

// MARK: - DSSection

struct DSSection: View {
    let title: String
    var subtitle: String? = nil
    var trailing: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpace.s) {
            VStack(alignment: .leading, spacing: DSSpace.hair) {
                Text(title)
                    .font(.dsSection)
                    .foregroundStyle(Color.dsTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                if let subtitle {
                    Text(subtitle)
                        .font(.dsSecondary)
                        .foregroundStyle(Color.dsTextSecondary)
                }
            }
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.dsMonoCaption)
                    .foregroundStyle(Color.dsTextTertiary)
            }
        }
    }
}

// MARK: - DSSidebarNavItem

struct DSSidebarNavItem: View {
    let icon: String
    let label: String
    let active: Bool
    var badge: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: DSSpace.xs) {
                Image(systemName: icon)
                    .font(.dsIcon)
                    .foregroundStyle(active ? Color.dsAccent : Color.dsTextSecondary)
                    .frame(width: DSSpace.m + DSSpace.xxs, alignment: .center)
                Text(label)
                    .font(.dsBodyMedium)
                    .foregroundStyle(active ? Color.dsTextPrimary : Color.dsTextSecondary)
                Spacer()
                if let badge { DSBadge(text: badge, tone: .accent, mono: true) }
            }
            .padding(.horizontal, DSSpace.xs)
            .padding(.vertical, DSSpace.xs)
            .dsSelectionBackground(active)
            // Without this the clear background (inactive state) is not
            // hit-tested — only the icon/label glyphs respond to clicks.
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

extension View {
    /// The selected look for navigation: the sidebar and page tabs.
    func dsSelectionBackground(_ selected: Bool) -> some View {
        background(selected ? Color.dsAccentQuiet : Color.clear,
                   in: RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous))
    }
}
