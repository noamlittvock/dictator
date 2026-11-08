import AppKit
import SwiftUI

/// The icon of where a Voice launch card's action goes: an app's own icon, a
/// website's icon on a light tile, or a symbol or letter when there is none.
struct VoiceIconView: View {
    let source: VoiceIconSource
    var size: CGFloat = 32
    var dimmed = false
    @State private var fetched: VoiceIcons.Found?

    var body: some View {
        let found = VoiceIcons.now(source) ?? fetched
        Group {
            switch found {
            case .app(let image)?:
                Image(nsImage: image).resizable().interpolation(.high).frame(width: size, height: size)
            case .site(let image)?:
                tile(background: .dsSurfaceRaised) {
                    Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
                        .padding(DSSpace.xxs)
                }
            case nil:
                tile(background: .dsSurfaceControl) { fallback }
            }
        }
        .frame(width: size, height: size)
        .saturation(dimmed ? 0 : 1)
        .opacity(dimmed ? 0.55 : 1)
        .accessibilityHidden(true)
        .task(id: source) {
            guard VoiceIcons.now(source) == nil else { return }
            fetched = await VoiceIcons.load(source)
        }
    }

    /// Matches the visible size of a macOS app icon, which leaves a margin.
    private func tile<Content: View>(background: Color, @ViewBuilder content: () -> Content) -> some View {
        let side = size * 0.8
        let shape = RoundedRectangle(cornerRadius: DSRadius.control, style: .continuous)
        return content()
            .frame(width: side, height: side)
            .background(background, in: shape)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.dsBorder, lineWidth: 0.5))
    }

    @ViewBuilder private var fallback: some View {
        switch source.fallback {
        case .symbol(let name):
            Image(systemName: name).font(.dsIcon).foregroundStyle(Color.dsTextSecondary)
        case .letter(let letter):
            Text(letter).font(.dsCaptionMedium).foregroundStyle(Color.dsTextSecondary)
        }
    }
}

/// Finds a card's icon: apps from LaunchServices, websites from `SiteIconStore`.
@MainActor
enum VoiceIcons {
    enum Found: Equatable {
        case app(NSImage)
        case site(NSImage)
    }

    private static var apps: [VoiceIconSource.Candidate: NSImage?] = [:]

    /// The icon when it can be had without waiting. Nil while a website's
    /// icon may still arrive, and when the fallback is the answer.
    static func now(_ source: VoiceIconSource) -> Found? {
        for candidate in source.candidates {
            switch candidate {
            case .app, .scheme:
                if let image = appIcon(candidate) { return .app(image) }
            case .site(let host):
                if let image = SiteIconStore.shared.cached(host) { return .site(image) }
                if !SiteIconStore.shared.isMissing(host) { return nil }
            }
        }
        return nil
    }

    static func load(_ source: VoiceIconSource) async -> Found? {
        for candidate in source.candidates {
            switch candidate {
            case .app, .scheme:
                if let image = appIcon(candidate) { return .app(image) }
            case .site(let host):
                if let image = await SiteIconStore.shared.icon(for: host) { return .site(image) }
            }
        }
        return nil
    }

    private static func appIcon(_ candidate: VoiceIconSource.Candidate) -> NSImage? {
        if let known = apps[candidate] { return known }
        var url: URL?
        switch candidate {
        case .app(let id): url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
        case .scheme(let scheme): url = URL(string: "\(scheme)://").flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
        case .site: url = nil
        }
        let image = url.map { NSWorkspace.shared.icon(forFile: $0.path) }
        apps[candidate] = image
        return image
    }
}
