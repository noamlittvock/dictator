import AppKit
import SwiftUI

@MainActor
@Observable
final class WalkieTalkieIndicatorModel {
    var phase: WalkieTalkieIndicatorPhase = .recording
    var activity: Float = 0
    /// Whole seconds left before the time limit stops the recording; nil
    /// when there is nothing to warn about.
    var countdown: Int?
    /// This recording is in voice launch mode (Right Option + Right Shift).
    var voiceLaunch = false
    var barLevels: [Float] = Array(repeating: 0, count: WalkieTalkieIndicatorView.barCount)

    /// Text beside the badge, which needs the wider window.
    var hasLabel: Bool { phase == .recording && (countdown != nil || voiceLaunch) }

    func setRecording() {
        phase = .recording
        resetLevels()
    }

    func setProcessing() {
        phase = .processing
        countdown = nil
        voiceLaunch = false
        resetLevels()
    }

    func push(_ level: Float) {
        guard phase == .recording else { return }

        let noiseFloor: Float = 0.0035
        let gained = max(0, (level - noiseFloor) * 78)
        let rawScaled = min(1, pow(gained, 0.54))
        let scaled = rawScaled < 0.045 ? 0 : rawScaled
        activity = activity * 0.64 + scaled * 0.36

        for index in barLevels.indices {
            let target = scaled * Self.responseWeights[index]
            barLevels[index] = barLevels[index] * 0.62 + target * 0.38
        }
    }

    func reset() {
        phase = .recording
        countdown = nil
        voiceLaunch = false
        resetLevels()
    }

    private func resetLevels() {
        activity = 0
        barLevels = Array(repeating: 0, count: WalkieTalkieIndicatorView.barCount)
    }

    private static let responseWeights: [Float] = [0.62, 0.96, 1.35, 1.02, 1.55, 1.08, 1.42, 0.9, 0.66]
}

enum WalkieTalkieIndicatorPhase {
    case recording
    case processing
}

/// The dictation badge: a poster-style microphone on a red disc, lightning
/// bolts around it. Drawn in the flat red / cream / ink of anti-fascist print
/// posters — no gradients, hard edges, a misregistered ink shadow. While
/// you're silent there are no bolts; as you speak they blink on and off in
/// random stop-motion around the mic, each at its own rhythm, angle and
/// reach — more of them, bigger and pushed further out the louder you are.
struct WalkieTalkieIndicatorView: View {
    @Bindable var model: WalkieTalkieIndicatorModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var beats = Beats()

    var body: some View {
        HStack(spacing: DSSpace.xs) {
            badge
            if let seconds = model.countdown {
                Text(WalkieTalkieIndicatorView.countdownText(seconds))
                    .font(.dsBodyMedium)
                    .monospacedDigit()
                    .foregroundStyle(Color.dsPanelWarning)
                    .padding(.horizontal, DSSpace.s)
                    .frame(height: 30)
                    .background(Capsule().fill(Color.dsPanelBackground))
                    .overlay(Capsule().strokeBorder(Color.dsPanelBorder, lineWidth: 1.5))
                    .accessibilityLabel(WalkieTalkieIndicatorView.countdownText(seconds))
            } else if model.voiceLaunch {
                // Text, not only colour, says which mode this is. The
                // time-limit warning above takes this place when it's up.
                Text(Self.voiceLaunchLabel)
                    .font(.dsBodyMedium)
                    .foregroundStyle(Palette.ink)
                    .padding(.horizontal, DSSpace.s)
                    .frame(height: 30)
                    .background(Capsule().fill(Palette.cream))
                    .overlay(Capsule().strokeBorder(Palette.ink, lineWidth: 1.5))
            }
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.88), value: model.voiceLaunch)
    }

    /// Uses the same name as the Commands page.
    static let voiceLaunchLabel = "Commands"

    /// "Stopping in 7…", the text beside the badge in the last seconds.
    static func countdownText(_ seconds: Int) -> String { "Stopping in \(seconds)…" }

    private var badge: some View {
        ZStack {
            TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: model.phase != .recording)) { timeline in
                Canvas { context, size in
                    draw(in: &context, size: size, at: timeline.date)
                }
            }
            .opacity(model.phase == .recording ? 1 : 0)
            .scaleEffect(model.phase == .recording ? 1 : 0.4)

            ProcessingSpinner(color: Palette.cream)
                .opacity(model.phase == .processing ? 1 : 0)
                .scaleEffect(model.phase == .processing ? 0.86 : 0.45)
        }
        .frame(
            width: Self.size(for: model.phase).width,
            height: Self.size(for: model.phase).height
        )
        .background {
            Circle()
                .fill(model.voiceLaunch ? Palette.cream : Palette.red)
                .overlay(Circle().strokeBorder(model.voiceLaunch ? Palette.ink : Palette.cream, lineWidth: 2))
                .overlay(Circle().strokeBorder(Palette.ink, lineWidth: 0.75))
        }
        .animation(.spring(response: 0.22, dampingFraction: 0.88), value: model.phase)
    }

    /// Width of the window while a label sits beside the badge.
    static let labelWindowWidth: CGFloat = 54 + 8 + 128

    static func size(for phase: WalkieTalkieIndicatorPhase, label: Bool = false) -> NSSize {
        if label, phase == .recording {
            return NSSize(width: labelWindowWidth, height: 54)
        }
        switch phase {
        case .recording:
            return NSSize(width: 54, height: 54)
        case .processing:
            return NSSize(width: 34, height: 34)
        }
    }

    static let barCount = 9

    // MARK: - Drawing

    /// Everything is laid out on a 44 × 44 grid and scaled to the badge.
    private static let grid: CGFloat = 44
    private static let micCenter = CGPoint(x: 22, y: 17)
    /// Bottom of the stand, where the microphone stays planted.
    private static let micBase: CGFloat = 35.6
    /// Where bolts can strike: loosely the poster's up / level / down on each
    /// side, deliberately uneven (four right, three left) so the sides never
    /// mirror each other.
    private static let rayAngles: [Double] = [-50, -16, 16, 42, 224, 190, 152]
    /// Which voice band drives each bolt.
    private static let rayBands = [1, 3, 5, 7, 2, 4, 6]
    /// A bolt's centre sits between these distances from the mic; louder
    /// speech and luck push it out toward the rim.
    private static let innerDistance: CGFloat = 13
    private static let outerDistance: CGFloat = 17

    private func draw(in context: inout GraphicsContext, size: CGSize, at date: Date) {
        let activity = CGFloat(model.activity)

        context.scaleBy(x: size.width / Self.grid, y: size.height / Self.grid)

        var bolts = context
        bolts.clip(to: Path(ellipseIn: CGRect(x: 2.4, y: 2.4, width: 39.2, height: 39.2)))
        for ray in Self.rayAngles.indices {
            let band = Self.rayBands[ray]
            let energy = min(1, max(activity * 0.8, CGFloat(model.barLevels[band]) * 1.2))
            guard energy > 0.06 else { continue }
            // Each frame of the "film" rolls the dice per bolt; louder speech
            // lights more of them, bigger and further out. Reduce Motion
            // holds them steady instead.
            let step = reduceMotion ? 0 : beats.seed(ray, at: date, hold: 0.04...(0.26 - 0.12 * Double(energy)))
            let roll = Self.random(ray: ray, step: step)
            let chance = reduceMotion ? 1 : min(0.8, 0.15 + 0.7 * energy)
            guard roll.on < chance else { continue }
            let scale = (0.7 + 0.25 * energy) * (reduceMotion ? 1 : 0.8 + 0.4 * roll.size)
            let push = reduceMotion ? 0.3 : min(1, roll.push * (0.5 + 0.7 * energy))
            let center = Self.innerDistance + push * (Self.outerDistance - Self.innerDistance)
            let length = 11 * scale
            let path = Self.bolt(
                angle: Self.rayAngles[ray] + (reduceMotion ? 0 : (roll.tilt - 0.5) * 26),
                distance: center - length / 2,
                length: length,
                width: 5.5 * scale,
                mirrored: reduceMotion ? ray >= 4 : roll.flip < 0.5
            )
            bolts.fill(path, with: .color(model.voiceLaunch ? Palette.red : Palette.cream))
            bolts.stroke(path, with: .color(Palette.ink), style: StrokeStyle(lineWidth: 0.75, lineJoin: .miter))
        }

        // The microphone rants: cartoon squash-and-stretch planted on its
        // base — taller and thinner, then short and fat — with a jerky lean,
        // all scaled by how loud you are. Still when you're silent.
        if !reduceMotion && activity > 0 {
            let pose = beats.pose(at: date, activity: Double(activity))
            let stretch = CGFloat(pose.stretch) * 0.17 * activity
            let lean = pose.lean * 13 * Double(activity)
            context.translateBy(x: Self.micCenter.x, y: Self.micBase)
            context.rotate(by: .degrees(lean))
            context.scaleBy(x: 1 - 0.7 * stretch, y: 1 + stretch)
            context.translateBy(x: -Self.micCenter.x, y: -Self.micBase)
        }

        var shadow = context
        shadow.translateBy(x: 1.1, y: 1.1)
        let shadowColor = model.voiceLaunch ? Palette.creamShadow : Palette.shadow
        Self.drawMicrophone(in: &shadow, head: shadowColor, hardware: shadowColor, detail: shadowColor)
        Self.drawMicrophone(in: &context, head: model.voiceLaunch ? Palette.red : Palette.cream, hardware: Palette.ink, detail: Palette.ink)
    }

    private static func drawMicrophone(in context: inout GraphicsContext, head: Color, hardware: Color, detail: Color) {
        let capsule = Path(roundedRect: CGRect(x: 17.5, y: 8, width: 9, height: 16), cornerRadius: 4.5)
        context.fill(capsule, with: .color(head))
        context.stroke(capsule, with: .color(hardware), lineWidth: 1.3)

        var grille = Path()
        for y in [11.0, 13.2, 15.4] {
            for x in [19.8, 22.0, 24.2] {
                grille.addEllipse(in: CGRect(x: x - 0.6, y: y - 0.6, width: 1.2, height: 1.2))
            }
        }
        grille.addRect(CGRect(x: 17.5, y: 17.3, width: 9, height: 1.5))
        for x in [20.3, 23.7] {
            grille.addRect(CGRect(x: x - 0.4, y: 19.9, width: 0.8, height: 2.3))
        }
        context.fill(grille, with: .color(detail))

        var yoke = Path()
        yoke.move(to: CGPoint(x: 15.1, y: 15.5))
        yoke.addLine(to: CGPoint(x: 15.1, y: 21))
        yoke.addQuadCurve(to: CGPoint(x: 28.9, y: 21), control: CGPoint(x: 22, y: 34))
        yoke.addLine(to: CGPoint(x: 28.9, y: 15.5))
        context.stroke(yoke, with: .color(hardware), style: StrokeStyle(lineWidth: 1.9, lineCap: .butt, lineJoin: .miter))

        var stand = Path()
        stand.addRect(CGRect(x: 21, y: 27, width: 2, height: 5))
        stand.move(to: CGPoint(x: 17.8, y: 32))
        stand.addLine(to: CGPoint(x: 26.2, y: 32))
        stand.addLine(to: CGPoint(x: 29, y: 35.6))
        stand.addLine(to: CGPoint(x: 15, y: 35.6))
        stand.closeSubpath()
        context.fill(stand, with: .color(hardware))
    }

    /// A lightning bolt: straight zig-zag edges with hard corners and a
    /// needle tip pointing outward along `angle`. Mirrored on the left
    /// so both sides lean the same way.
    private static func bolt(angle: Double, distance: CGFloat, length: CGFloat, width: CGFloat, mirrored: Bool) -> Path {
        let radians = angle * .pi / 180
        let along = CGVector(dx: cos(radians), dy: sin(radians))
        let across = CGVector(dx: -along.dy, dy: along.dx)
        // (across, along) in a unit box; the tip sits at along = 1.
        // Straight edges on a straight axis: tail centred, tip centred, two
        // hard kinks between — like the poster's bolts.
        let shape: [(CGFloat, CGFloat)] = [
            (0.4, 0), (0.8, 0), (0.58, 0.4), (0.78, 0.4), (0.5, 1), (0.42, 0.58), (0.22, 0.58),
        ]
        var path = Path()
        for (index, point) in shape.enumerated() {
            let a = distance + point.1 * length
            let c = ((mirrored ? 1 - point.0 : point.0) - 0.5) * width
            let p = CGPoint(
                x: micCenter.x + along.dx * a + across.dx * c,
                y: micCenter.y + along.dy * a + across.dy * c
            )
            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
        }
        path.closeSubpath()
        return path
    }

    /// Stable pseudo-random numbers in 0..<1 for a bolt at a given
    /// stop-motion step (SplitMix64), so a frame looks the same however often
    /// SwiftUI redraws it.
    private static func random(ray: Int, step: UInt64) -> (on: CGFloat, size: CGFloat, tilt: Double, push: CGFloat, flip: Double) {
        var state = step &* 0x9E37_79B9_7F4A_7C15 &+ UInt64(ray + 1) &* 0xBF58_476D_1CE4_E5B9
        func next() -> Double {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Double(z >> 11) / Double(1 << 53)
        }
        return (CGFloat(next()), CGFloat(next()), next(), CGFloat(next()), next())
    }

    private enum Palette {
        static let red = Color(red: 0.78, green: 0.16, blue: 0.13)
        static let shadow = Color(red: 0.45, green: 0.07, blue: 0.06)
        static let cream = Color(red: 0.96, green: 0.91, blue: 0.82)
        static let creamShadow = Color(red: 0.76, green: 0.68, blue: 0.56)
        static let ink = Color(red: 0.08, green: 0.07, blue: 0.07)
    }
}

/// Irregular comic timing. Each bolt and the microphone hold a pose for a
/// random beat, never a steady rhythm, then snap to the next. Not observed:
/// it only advances as frames are drawn.
private final class Beats {
    private struct Slot {
        var seed: UInt64
        var until: Date
    }

    struct Pose {
        var stretch: Double
        var lean: Double
    }

    private var slots: [Int: Slot] = [:]
    private var from = Pose(stretch: 0, lean: 0)
    private var to = Pose(stretch: 0, lean: 0)
    private var posedAt = Date.distantPast
    private var nextPose = Date.distantPast

    /// A random number that changes after an unpredictable hold.
    func seed(_ key: Int, at date: Date, hold: ClosedRange<Double>) -> UInt64 {
        if let slot = slots[key], slot.until > date { return slot.seed }
        let slot = Slot(seed: .random(in: 0...UInt64.max), until: date + .random(in: hold))
        slots[key] = slot
        return slot.seed
    }

    /// The microphone's pose (each in -1...1). It snaps to a new one after a
    /// hold of anywhere from a blink to a dramatic freeze, with a few frames of
    /// overshoot so each snap lands with a jolt.
    func pose(at date: Date, activity: Double) -> Pose {
        if date >= nextPose {
            from = current(at: date)
            // Mostly the opposite of the last squash, but not always; lean
            // picks a side on its own, so it can lurch the same way twice.
            let flip = Double.random(in: 0...1) < 0.75 ? -1.0 : 1.0
            to = Pose(
                stretch: flip * (to.stretch == 0 ? 1 : to.stretch.sign == .minus ? -1 : 1) * .random(in: 0.35...1),
                lean: .random(in: -1...1)
            )
            let roll = Double.random(in: 0...1)
            let hold = roll < 0.1 ? .random(in: 0.35...0.6) : 0.05 + roll * roll * 0.3
            posedAt = date
            nextPose = date + hold / (0.6 + activity)
        }
        return current(at: date)
    }

    private func current(at date: Date) -> Pose {
        let t = min(1, max(0, date.timeIntervalSince(posedAt) / 0.07))
        // Ease out with a little overshoot.
        let k = 1 + 2.2 * pow(t - 1, 3) + 1.2 * pow(t - 1, 2)
        return Pose(
            stretch: from.stretch + (to.stretch - from.stretch) * k,
            lean: from.lean + (to.lean - from.lean) * k
        )
    }
}

private struct ProcessingSpinner: View {
    let color: Color
    @State private var rotation: Double = 0

    var body: some View {
        Circle()
            .trim(from: 0.16, to: 0.84)
            .stroke(
                color,
                style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
            )
            .frame(width: 17, height: 17)
            .rotationEffect(.degrees(rotation))
            .onAppear {
                rotation = 0
                withAnimation(.linear(duration: 0.78).repeatForever(autoreverses: false)) {
                    rotation = 360
                }
            }
    }
}
