import AppKit
import CoreText
import SwiftUI

/// The product site's fonts, registered only for this process, never installed on macOS.
enum DSFont {
    private static let registration: Void = {
        for name in ["Anton-Regular", "Jost"] {
            if let url = Bundle.main.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
            }
        }
    }()

    static func display(_ size: CGFloat) -> Font {
        _ = registration
        return .custom("Anton-Regular", size: size)
    }

    static func body(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        _ = registration
        return .custom("Jost-Regular", size: size).weight(weight)
    }
}

struct BrandEyebrow: View {
    let text: String

    var body: some View {
        HStack(spacing: DSSpace.xs) {
            Rectangle().fill(Color.dsPosterRed).frame(width: 16, height: 1)
            Text(text.uppercased())
                .font(DSFont.body(10, weight: .medium))
                .tracking(1.6)
                .foregroundStyle(Color.dsTextSecondary)
        }
    }
}

/// An inert illustration: no status lights or animation that could imply recording.
struct BrandDictationArt: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Image("BrandRays")
                    .resizable().scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .opacity(colorScheme == .dark ? 0.65 : 0.24)
                Image("BrandDictate")
                    .renderingMode(.template)
                    .resizable().scaledToFit()
                    .foregroundStyle(Color.dsTextPrimary)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

struct BrandGrid: View {
    var body: some View {
        Canvas { context, size in
            var path = Path()
            for x in stride(from: CGFloat(0), through: size.width, by: 40) {
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: CGFloat(0), through: size.height, by: 40) {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(path, with: .color(.dsTextPrimary.opacity(0.035)), lineWidth: 0.5)
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Home's page title. Short, so the feed stays the main thing on the page.
struct HomeBrandHeader: View {
    let keys: HotkeyTriggers

    var body: some View {
        HStack(alignment: .center, spacing: DSSpace.m) {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                HStack(spacing: DSSpace.xs) {
                    Text("Write by voice. Run by command.")
                        .font(.dsPageTitle)
                        .foregroundStyle(Color.dsTextPrimary)
                        .accessibilityAddTraits(.isHeader)
                    DSPageBriefButton(brief: HelpLibrary.brief(.home, keys: keys))
                }
                HStack(spacing: DSSpace.xs) {
                    Text(keys.dictation.displayName)
                        .font(.dsCaptionMedium)
                        .padding(.horizontal, DSSpace.xs).padding(.vertical, DSSpace.xxs)
                        .background(Color.dsSurfaceControl, in: RoundedRectangle(cornerRadius: DSRadius.control))
                        .overlay(RoundedRectangle(cornerRadius: DSRadius.control).strokeBorder(Color.dsBorder))
                    Text("Hold to speak, release to type.")
                        .font(.dsBody)
                        .foregroundStyle(Color.dsTextSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            BrandDictationArt().frame(width: DSSpace.xxl + DSSpace.m, height: DSSpace.xxl + DSSpace.m)
        }
        .padding(.top, DSSpace.m)
        .padding(.bottom, DSSpace.s)
        .dsPageFrame(.wide)
        .background(Color.dsBgContent)
        .overlay(alignment: .bottom) { Color.dsBorderSubtle.frame(height: 1) }
    }
}

struct WelcomeBrandHeader: View {
    var body: some View {
        HStack(spacing: DSSpace.l) {
            VStack(alignment: .leading, spacing: DSSpace.xs) {
                BrandEyebrow(text: "Welcome to Dictator")
                Text("Voice to Power.")
                    .font(DSFont.display(38))
                    .foregroundStyle(Color.dsTextPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(BrandVoice.welcomeIntro)
                    .font(.dsBody)
                    .foregroundStyle(Color.dsTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            BrandDictationArt().frame(width: 144, height: 128)
        }
        .padding(DSSpace.l)
        .background { BrandGrid() }
        .overlay(alignment: .bottom) { Color.dsBorderSubtle.frame(height: 1) }
    }
}
