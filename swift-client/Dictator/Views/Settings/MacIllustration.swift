import SwiftUI

/// Line drawing of a Mac for Settings › Your Macs.
struct MacIllustration: View {
    let kind: MachineKind
    var stroke: Color = .dsTextPrimary
    var fill: Color = .dsSurfaceSunken

    var body: some View {
        Canvas { context, size in
            let w = size.width, h = size.height
            let line = StrokeStyle(lineWidth: 1.6, lineJoin: .round)
            func rect(_ x: CGFloat, _ y: CGFloat, _ rw: CGFloat, _ rh: CGFloat, _ r: CGFloat) -> Path {
                Path(roundedRect: CGRect(x: x * w, y: y * h, width: rw * w, height: rh * h), cornerRadius: r)
            }
            switch kind {
            case .laptop:
                let screen = rect(0.21, 0.14, 0.58, 0.60, 5)
                context.stroke(screen, with: .color(stroke), style: line)
                context.fill(rect(0.25, 0.19, 0.50, 0.50, 2), with: .color(fill))
                var base = Path()
                base.move(to: CGPoint(x: 0.12 * w, y: 0.79 * h))
                base.addLine(to: CGPoint(x: 0.88 * w, y: 0.79 * h))
                base.addLine(to: CGPoint(x: 0.84 * w, y: 0.87 * h))
                base.addLine(to: CGPoint(x: 0.16 * w, y: 0.87 * h))
                base.closeSubpath()
                context.stroke(base, with: .color(stroke), style: line)
            case .mini:
                let box = rect(0.23, 0.60, 0.54, 0.25, 8)
                context.fill(box, with: .color(fill))
                context.stroke(box, with: .color(stroke), style: line)
                context.fill(Path(ellipseIn: CGRect(x: 0.30 * w, y: 0.715 * h, width: 3, height: 3)), with: .color(stroke))
            case .studio, .pro, .other:
                let box = kind == .pro ? rect(0.33, 0.10, 0.34, 0.76, 7) : rect(0.27, 0.35, 0.46, 0.50, 9)
                context.fill(box, with: .color(fill))
                context.stroke(box, with: .color(stroke), style: line)
                if kind != .pro {
                    context.stroke(rect(0.33, 0.69, 0.07, 0.03, 1.5), with: .color(stroke), style: line)
                    context.stroke(rect(0.43, 0.69, 0.07, 0.03, 1.5), with: .color(stroke), style: line)
                }
            case .imac:
                context.stroke(rect(0.16, 0.04, 0.68, 0.69, 5), with: .color(stroke), style: line)
                context.fill(rect(0.19, 0.09, 0.62, 0.52, 2), with: .color(fill))
                var stand = Path()
                stand.move(to: CGPoint(x: 0.44 * w, y: 0.73 * h))
                stand.addLine(to: CGPoint(x: 0.41 * w, y: 0.88 * h))
                stand.addLine(to: CGPoint(x: 0.59 * w, y: 0.88 * h))
                stand.addLine(to: CGPoint(x: 0.56 * w, y: 0.73 * h))
                context.stroke(stand, with: .color(stroke), style: line)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The two jobs an AI model can do, with their colour and symbol.
enum ModelJob: String, CaseIterable, Identifiable {
    case speech, cleanup
    var id: String { rawValue }

    var title: String {
        switch self {
        case .speech: "Speech to text"
        case .cleanup: "Clean up text"
        }
    }

    var symbol: String {
        switch self {
        case .speech: "waveform"
        case .cleanup: "sparkle"
        }
    }

    var color: Color {
        switch self {
        case .speech: .dsAccent
        case .cleanup: Color.dsDataTeal
        }
    }
}
