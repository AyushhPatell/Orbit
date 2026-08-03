//
//  OrbitListeningHUDController.swift
//  ORBITMac
//
//  Floating aura HUD: distinct motion languages for **listening** (mic) vs **speaking** (TTS),
//  similar in spirit to Siri’s readable state change—not a copy.
//

import AppKit
import Combine
import SwiftUI

// MARK: - ORBIT orb (Claude-provided implementation)

private enum OrbState: Equatable {
    case idle
    case listening
    case speaking
}

private enum ArcticSharp {
    static let bg0 = Color(red: 0 / 255, green: 5 / 255, blue: 8 / 255)
    static let bg1 = Color(red: 1 / 255, green: 10 / 255, blue: 20 / 255)
    static let bg2 = Color(red: 0 / 255, green: 4 / 255, blue: 6 / 255)

    static let nodeHi = Color(red: 228 / 255, green: 248 / 255, blue: 255 / 255)
    static let nodeLo = Color(red: 80 / 255, green: 168 / 255, blue: 238 / 255)

    static let pulseHead = Color(red: 255 / 255, green: 255 / 255, blue: 255 / 255)
    static let pulseTail = Color(red: 100 / 255, green: 200 / 255, blue: 255 / 255)

    static let conn = Color(red: 40 / 255, green: 108 / 255, blue: 195 / 255)

    static let fireGlow = Color(red: 210 / 255, green: 240 / 255, blue: 255 / 255)

    static let centerGlow = Color(red: 60 / 255, green: 148 / 255, blue: 238 / 255)

    static let accent = Color(red: 120 / 255, green: 205 / 255, blue: 255 / 255)
    static let particle = Color(red: 100 / 255, green: 188 / 255, blue: 255 / 255)

    static let shellMid = Color(red: 200 / 255, green: 235 / 255, blue: 255 / 255)
    static let shellEdge = Color(red: 248 / 255, green: 253 / 255, blue: 255 / 255)

    static let connOpacityMult: Double = 1.75
    static let nodeRadiusMult: Double = 1.28
    static let trailBaseSize: Double = 3.1
    static let trailLength: Int = 9
    static let particleSizeMult: Double = 1.35
    static let listenDotRadius: Double = 3.0
}

private struct Neuron {
    var x: Double
    var y: Double
    var vx: Double
    var vy: Double
    var radius: Double
    var phase: Double
    var firing: Bool = false
    var fireTime: Double = 0
    var connections: [Int] = []
}

private struct NeuralPulse {
    var fromIndex: Int
    var toIndex: Int
    var progress: Double
    var speed: Double
    var alpha: Double
}

private struct OrbParticle {
    var angle: Double
    var orbitRadius: Double
    var size: Double
    var angularSpeed: Double
    var baseOpacity: Double
    var driftPhase: Double
}

private struct ORBITOrb: View {
    var state: OrbState
    var size: CGFloat
    private let renderOverscan: CGFloat = 1.34

    init(state: OrbState = .idle, size: CGFloat = 220) {
        self.state = state
        self.size = size
    }

    var body: some View {
        OrbCanvas(state: state, size: size * renderOverscan)
            .scaleEffect(1 / renderOverscan)
            .frame(width: size, height: size)
    }
}

private struct OrbCanvas: View {
    var state: OrbState
    var size: CGFloat

    @StateObject private var sim: OrbSimulation

    init(state: OrbState, size: CGFloat) {
        self.state = state
        self.size = size
        _sim = StateObject(wrappedValue: OrbSimulation(size: size))
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { ctx, canvasSize in
                let t = timeline.date.timeIntervalSinceReferenceDate
                sim.render(in: ctx, size: canvasSize, t: t, state: state)
            }
        }
        .frame(width: size, height: size)
    }
}

private final class OrbSimulation: ObservableObject {
    let canvasW: CGFloat
    let R: Double
    let CX: Double
    let CY: Double

    var neurons: [Neuron]
    var pulses: [NeuralPulse]
    var particles: [OrbParticle]
    var lastFireTime: Double = 0

    init(size: CGFloat) {
        canvasW = size
        R = Double(size) * 0.5 * 0.965
        CX = Double(size) * 0.5
        CY = Double(size) * 0.5

        var ns = (0 ..< 24).map { _ -> Neuron in
            Neuron(
                x: Double(size) * 0.5 + (Double.random(in: -0.5 ... 0.5)) * Double(size) * 0.44,
                y: Double(size) * 0.5 + (Double.random(in: -0.5 ... 0.5)) * Double(size) * 0.44,
                vx: Double.random(in: -0.20 ... 0.20),
                vy: Double.random(in: -0.20 ... 0.20),
                radius: Double.random(in: 2.2 ... 5.4),
                phase: Double.random(in: 0 ... Double.pi * 2)
            )
        }

        for i in ns.indices {
            let sorted = ns.indices
                .filter { $0 != i }
                .sorted {
                    hypot(ns[$0].x - ns[i].x, ns[$0].y - ns[i].y) <
                        hypot(ns[$1].x - ns[i].x, ns[$1].y - ns[i].y)
                }
            ns[i].connections = Array(sorted.prefix(3))
        }

        neurons = ns
        pulses = []
        particles = (0 ..< 110).map { _ in
            OrbParticle(
                angle: Double.random(in: 0 ... Double.pi * 2),
                orbitRadius: Double(size) * 0.5 * 1.065 + Double.random(in: 0 ... Double(size) * 0.5 * 0.32),
                size: (0.75 + Double.random(in: 0 ... 2.0)) * ArcticSharp.particleSizeMult,
                angularSpeed: (Double.random(in: -0.5 ... 0.5)) * 0.004,
                baseOpacity: Double.random(in: 0.22 ... 0.72),
                driftPhase: Double.random(in: 0 ... Double.pi * 2)
            )
        }
    }

    func render(in ctx: GraphicsContext, size: CGSize, t: Double, state: OrbState) {
        let spd: Double = state == .idle ? 0.20 : state == .listening ? 0.54 : 0.96
        let fireRate: Double = state == .idle ? 2.30 : state == .listening ? 0.68 : 0.22
        let fitScale: CGFloat = 0.68
        var fitted = ctx
        fitted.translateBy(x: CX, y: CY)
        fitted.scaleBy(x: fitScale, y: fitScale)
        fitted.translateBy(x: -CX, y: -CY)

        drawHalo(fitted, state: state)
        drawArcRings(fitted, t: t, state: state)
        drawInterior(fitted, t: t, state: state, spd: spd, fireRate: fireRate)
        drawShell(fitted)
        drawParticles(fitted, t: t, state: state)
        if state == .speaking { drawSpeakingRings(fitted, t: t) }
        if state == .listening { drawListeningDots(fitted, t: t) }
    }

    private func drawHalo(_ ctx: GraphicsContext, state: OrbState) {
        let opacity = state == .listening ? 0.27 : 0.13
        let g = ctx.resolve(GraphicsContext.Shading.radialGradient(
            Gradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: ArcticSharp.particle.opacity(opacity), location: 0.5),
                .init(color: .clear, location: 1.0),
            ]),
            center: CGPoint(x: CX, y: CY),
            startRadius: R * 0.74,
            endRadius: R * 1.17
        ))
        ctx.fill(Circle().path(in: CGRect(x: CX - R * 1.17, y: CY - R * 1.17, width: R * 2.34, height: R * 2.34)), with: g)
    }

    private func drawArcRings(_ ctx: GraphicsContext, t: Double, state: OrbState) {
        let opacity = state == .idle ? 0.20 : state == .listening ? 0.58 : 0.38
        let speed = state == .idle ? 0.30 : state == .listening ? 0.96 : 1.88
        let baseRot = t * speed

        let rings: [(rot: Double, radius: Double, start: Double, end: Double, lw: Double)] = [
            (baseRot, R + 23 * scale, 0, .pi * 0.9, 1.5),
            (-baseRot * 1.7, R + 40 * scale, .pi * 0.3, .pi * 1.74, 1.0),
            (baseRot * 0.65, R + 55 * scale, 0.1, .pi * 1.24, 0.7),
        ]

        for ring in rings {
            var gc = ctx
            gc.translateBy(x: CX, y: CY)
            gc.rotate(by: .radians(ring.rot))
            let path = Path { p in
                p.addArc(
                    center: .zero,
                    radius: ring.radius,
                    startAngle: .radians(ring.start),
                    endAngle: .radians(ring.end),
                    clockwise: false
                )
            }
            gc.stroke(path, with: .color(ArcticSharp.accent.opacity(opacity)), lineWidth: ring.lw)
        }
    }

    private func drawInterior(_ ctx: GraphicsContext, t: Double, state: OrbState, spd: Double, fireRate: Double) {
        let orbRect = CGRect(x: CX - R, y: CY - R, width: R * 2, height: R * 2)

        var clipped = ctx
        clipped.clip(to: Path(ellipseIn: orbRect))

        clipped.fill(
            Path(ellipseIn: orbRect),
            with: .radialGradient(
                Gradient(stops: [
                    .init(color: ArcticSharp.bg0, location: 0.0),
                    .init(color: ArcticSharp.bg1, location: 0.52),
                    .init(color: ArcticSharp.bg2, location: 1.0),
                ]),
                center: CGPoint(x: CX, y: CY),
                startRadius: 0,
                endRadius: R
            )
        )

        let maxDist = R * 0.84
        for i in neurons.indices {
            neurons[i].x += neurons[i].vx * spd
            neurons[i].y += neurons[i].vy * spd
            let dx = neurons[i].x - CX
            let dy = neurons[i].y - CY
            let d = sqrt(dx * dx + dy * dy)
            if d > maxDist {
                neurons[i].vx -= (dx / d) * 0.055
                neurons[i].vy -= (dy / d) * 0.055
            }
        }

        if t - lastFireTime > fireRate * (0.65 + Double.random(in: 0 ... 0.7)) {
            lastFireTime = t
            let src = Int.random(in: 0 ..< neurons.count)
            for j in neurons[src].connections {
                pulses.append(NeuralPulse(
                    fromIndex: src,
                    toIndex: j,
                    progress: 0,
                    speed: Double.random(in: 0.014 ... 0.036),
                    alpha: Double.random(in: 0.85 ... 1.0)
                ))
            }
            neurons[src].firing = true
            neurons[src].fireTime = t
        }

        let connBaseOp = 0.14 * ArcticSharp.connOpacityMult
        for i in neurons.indices {
            for j in neurons[i].connections {
                let n = neurons[i]
                let m = neurons[j]
                let d = hypot(m.x - n.x, m.y - n.y)
                if d < R * 0.95 {
                    let al = max(0, (1 - d / (R * 0.95)) * connBaseOp)
                    let path = Path {
                        $0.move(to: CGPoint(x: n.x, y: n.y))
                        $0.addLine(to: CGPoint(x: m.x, y: m.y))
                    }
                    clipped.stroke(path, with: .color(ArcticSharp.conn.opacity(al)), lineWidth: 0.9)
                }
            }
        }

        let speedMult = state == .speaking ? 2.6 : state == .listening ? 1.58 : 1.0
        var toRemove: [Int] = []
        for i in pulses.indices {
            pulses[i].progress += pulses[i].speed * speedMult
            if pulses[i].progress >= 1.0 {
                let toIdx = pulses[i].toIndex
                neurons[toIdx].firing = true
                neurons[toIdx].fireTime = t
                toRemove.append(i)
                continue
            }
            let n = neurons[pulses[i].fromIndex]
            let m = neurons[pulses[i].toIndex]
            let prog = pulses[i].progress
            let alpha = pulses[i].alpha

            for tr in 0 ..< ArcticSharp.trailLength {
                let tp = max(0, prog - Double(tr) * 0.036)
                let tx = n.x + (m.x - n.x) * tp
                let ty = n.y + (m.y - n.y) * tp
                let ta = alpha * (1 - Double(tr) / Double(ArcticSharp.trailLength)) * 0.80
                let sz = max(0.3, ArcticSharp.trailBaseSize - Double(tr) * 0.28)
                let trailColor = prog < 0.5 ? ArcticSharp.pulseTail : ArcticSharp.pulseHead
                let dotRect = CGRect(x: tx - sz, y: ty - sz, width: sz * 2, height: sz * 2)
                clipped.fill(Path(ellipseIn: dotRect), with: .color(trailColor.opacity(ta)))
            }

            let headSz = ArcticSharp.trailBaseSize + 0.4
            let px = n.x + (m.x - n.x) * prog
            let py = n.y + (m.y - n.y) * prog
            let headRect = CGRect(x: px - headSz, y: py - headSz, width: headSz * 2, height: headSz * 2)
            clipped.fill(Path(ellipseIn: headRect), with: .color(ArcticSharp.pulseHead.opacity(alpha)))
        }
        for i in toRemove.reversed() {
            pulses.remove(at: i)
        }

        for n in neurons {
            let fired = n.firing && (t - n.fireTime) < 0.44
            let fa = fired ? max(0, 1 - (t - n.fireTime) / 0.44) : 0.0

            if fired {
                let glowR = 20.0
                let glowRect = CGRect(x: n.x - glowR, y: n.y - glowR, width: glowR * 2, height: glowR * 2)
                clipped.fill(Path(ellipseIn: glowRect), with: .radialGradient(
                    Gradient(stops: [
                        .init(color: ArcticSharp.fireGlow.opacity(fa * 0.94), location: 0.0),
                        .init(color: ArcticSharp.fireGlow.opacity(fa * 0.34), location: 0.45),
                        .init(color: .clear, location: 1.0),
                    ]),
                    center: CGPoint(x: n.x, y: n.y),
                    startRadius: 0,
                    endRadius: glowR
                ))
            }

            let nr = n.radius * ArcticSharp.nodeRadiusMult * (1 + fa * 0.58)
            let nRect = CGRect(x: n.x - nr, y: n.y - nr, width: nr * 2, height: nr * 2)
            let nColor = fired ? ArcticSharp.nodeHi : ArcticSharp.nodeLo
            clipped.fill(Path(ellipseIn: nRect), with: .radialGradient(
                Gradient(stops: [
                    .init(color: nColor.opacity(0.80 + fa * 0.20), location: 0.0),
                    .init(color: .clear, location: 1.0),
                ]),
                center: CGPoint(x: n.x, y: n.y),
                startRadius: 0,
                endRadius: nr
            ))
        }

        let cgOp = state == .speaking ? 0.44 : 0.22
        let cgR = 52.0 * scale
        let cgRect = CGRect(x: CX - cgR, y: CY - cgR, width: cgR * 2, height: cgR * 2)
        clipped.fill(Path(ellipseIn: cgRect), with: .radialGradient(
            Gradient(stops: [
                .init(color: ArcticSharp.centerGlow.opacity(cgOp), location: 0.0),
                .init(color: .clear, location: 1.0),
            ]),
            center: CGPoint(x: CX, y: CY),
            startRadius: 0,
            endRadius: cgR
        ))
    }

    private func drawShell(_ ctx: GraphicsContext) {
        let orbRect = CGRect(x: CX - R, y: CY - R, width: R * 2, height: R * 2)
        ctx.fill(Path(ellipseIn: orbRect), with: .radialGradient(
            Gradient(stops: [
                .init(color: .clear, location: 0.0),
                .init(color: ArcticSharp.shellMid.opacity(0.42), location: 0.68),
                .init(color: ArcticSharp.shellEdge.opacity(0.86), location: 0.86),
                .init(color: Color.white.opacity(0.96), location: 1.0),
            ]),
            center: CGPoint(x: CX, y: CY),
            startRadius: R * 0.60,
            endRadius: R
        ))
    }

    private func drawParticles(_ ctx: GraphicsContext, t: Double, state: OrbState) {
        let om = state == .idle ? 0.50 : state == .listening ? 1.58 : 1.02
        let pm = state == .idle ? 0.30 : state == .listening ? 1.38 : 0.84
        let spr = state == .listening ? 1.27 : 1.0

        for pt in particles {
            let ang = pt.angle + pt.angularSpeed * pm * t
            let wb: Double
            switch state {
            case .listening:
                wb = sin(t * 2.5 + pt.driftPhase) * 16
            case .speaking:
                wb = sin(t * 5.0 + pt.driftPhase) * 9
            case .idle:
                wb = sin(t * 0.8 + pt.driftPhase) * 4
            }
            let pr = (pt.orbitRadius + wb) * spr
            let px = CX + cos(ang) * pr
            let py = CY + sin(ang) * pr
            let al = max(0, min(1, pt.baseOpacity * om * (0.6 + sin(t * 1.2 + pt.driftPhase) * 0.4)))
            let sz = pt.size
            let rect = CGRect(x: px - sz, y: py - sz, width: sz * 2, height: sz * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(ArcticSharp.particle.opacity(al)))
        }
    }

    private func drawSpeakingRings(_ ctx: GraphicsContext, t: Double) {
        for i in 0 ..< 3 {
            let ph = (t * 1.65 + Double(i) * 0.48).truncatingRemainder(dividingBy: 1.56)
            let rr = R + ph * 60.0 * scale
            let al = max(0, (1 - ph / 1.56) * 0.48)
            let lw = max(0.1, 1.6 - ph * 0.70)
            let rect = CGRect(x: CX - rr, y: CY - rr, width: rr * 2, height: rr * 2)
            ctx.stroke(Path(ellipseIn: rect), with: .color(ArcticSharp.accent.opacity(al)), lineWidth: lw)
        }
    }

    private func drawListeningDots(_ ctx: GraphicsContext, t: Double) {
        for i in 0 ..< 8 {
            let a = (Double(i) / 8.0) * Double.pi * 2 + t * 0.57
            let dr = R + (13 + sin(t * 2.0 + Double(i)) * 5) * scale
            let al = 0.34 + sin(t * 2.5 + Double(i) * 1.22) * 0.24
            let px = CX + cos(a) * dr
            let py = CY + sin(a) * dr
            let sz = ArcticSharp.listenDotRadius * scale
            let rect = CGRect(x: px - sz, y: py - sz, width: sz * 2, height: sz * 2)
            ctx.fill(Path(ellipseIn: rect), with: .color(ArcticSharp.accent.opacity(max(0, al))))
        }
    }

    var scale: Double { Double(canvasW) / 220.0 }
}


private struct OrbitListeningHUDRootView: View {
    @ObservedObject private var presence = OrbitListeningPresence.shared
    private let orbSize: CGFloat = 104
    private let orbPanelSize: CGFloat = 116
    private let cardWidth: CGFloat = 420
    private let cardHeight: CGFloat = 260
    private let compactCardWidth: CGFloat = 340
    private let compactCardHeight: CGFloat = 88

    private var isCompactCard: Bool { presence.wakeVoiceCard?.title.isEmpty == true }

    var body: some View {
        ZStack {
            Color.clear.ignoresSafeArea()
            if let card = presence.wakeVoiceCard {
                wakeVoiceCard(card)
                    .transition(.opacity.combined(with: .scale(scale: 0.88)))
            } else {
                switch presence.orbDisplayMode {
                case .listening:
                    ORBITOrb(state: .listening, size: orbSize)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                case .speaking:
                    ORBITOrb(state: .speaking, size: orbSize)
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                case .hidden:
                    EmptyView()
                }
            }
        }
        .frame(
            width:  presence.wakeVoiceCard == nil ? orbPanelSize : (isCompactCard ? compactCardWidth : cardWidth),
            height: presence.wakeVoiceCard == nil ? orbPanelSize : (isCompactCard ? compactCardHeight : cardHeight)
        )
        .background(Color.clear)
        .animation(.spring(response: 0.42, dampingFraction: 0.86), value: presence.orbDisplayMode)
        .animation(.spring(response: 0.36, dampingFraction: 0.84), value: presence.wakeVoiceCard)
    }

    @ViewBuilder
    private func wakeVoiceCard(_ card: OrbitListeningPresence.WakeVoiceCard) -> some View {
        if card.title.isEmpty {
            compactQuestionCard(card.body)
        } else {
            standardWakeCard(card)
        }
    }

    /// Compact pill for clarification questions — no title, mic icon, single-line feel.
    private func compactQuestionCard(_ question: String) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(0.65))
            Text(question)
                .font(.system(size: 15, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.96))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground(cornerRadius: 20))
        .shadow(color: .black.opacity(0.52), radius: 20, x: 0, y: 8)
    }

    /// Standard card for file picks, confirmations, and informational briefings — title + scrollable body.
    private func standardWakeCard(_ card: OrbitListeningPresence.WakeVoiceCard) -> some View {
        let hint: String? = {
            switch card.title {
            case "Choose a file": return "Say open 1, open 2, or cancel"
            case "Confirm":       return "Say yes to confirm, or cancel"
            default:              return nil
            }
        }()
        return VStack(alignment: .leading, spacing: 8) {
            Text(card.title)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white.opacity(0.98))
            ScrollView {
                Text(card.body)
                    .font(.system(size: 15, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.95))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.disabled)
            }
            .frame(maxHeight: 165)
            if let hint {
                Text(hint)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.72))
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(cardBackground(cornerRadius: 22))
        .shadow(color: .black.opacity(0.55), radius: 28, x: 0, y: 12)
    }

    private func cardBackground(cornerRadius: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .fill(Color(red: 0.05, green: 0.08, blue: 0.18).opacity(0.96))
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .strokeBorder(
                    LinearGradient(
                        colors: [Color.white.opacity(0.14), Color.white.opacity(0.04)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.0
                )
        }
    }
}

@MainActor
final class OrbitListeningHUDController {
    static let shared = OrbitListeningHUDController()

    private var panel: NSPanel?
    private var cancellable: AnyCancellable?
    private var hostView: NSHostingView<OrbitListeningHUDRootView>?

    private init() {}

    private func makeTransparent(_ v: NSView?) {
        guard let v else { return }
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.clear.cgColor
        v.layer?.isOpaque = false
        for sub in v.subviews { makeTransparent(sub) }
    }

    func bootstrap() {
        guard panel == nil else { return }
        let hv = NSHostingView(rootView: OrbitListeningHUDRootView())
        hv.wantsLayer = true
        hostView = hv
        let rect = Self.defaultFrame(wakeVoiceCard: nil)

        let p = NSPanel(
            contentRect: rect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.level = .statusBar + 1
        p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.isFloatingPanel = true
        p.becomesKeyOnlyIfNeeded = false
        p.ignoresMouseEvents = true
        p.contentView = hv
        // Force layout so AppKit creates CALayers, then configure all of them transparent.
        hv.layoutSubtreeIfNeeded()
        makeTransparent(hv)
        panel = p

        cancellable = Publishers.CombineLatest(
            OrbitListeningPresence.shared.$orbDisplayMode,
            OrbitListeningPresence.shared.$wakeVoiceCard
        )
            .receive(on: RunLoop.main)
            .sink { [weak self] mode, card in
                self?.apply(orbMode: mode, wakeVoiceCard: card)
            }

        apply(
            orbMode: OrbitListeningPresence.shared.orbDisplayMode,
            wakeVoiceCard: OrbitListeningPresence.shared.wakeVoiceCard
        )
    }

    private func apply(
        orbMode: OrbitListeningPresence.OrbDisplayMode,
        wakeVoiceCard: OrbitListeningPresence.WakeVoiceCard?
    ) {
        guard let panel else { return }
        let shouldShow = wakeVoiceCard != nil || orbMode != .hidden
        if !shouldShow {
            panel.orderOut(nil)
            return
        }
        panel.setFrame(Self.defaultFrame(wakeVoiceCard: wakeVoiceCard), display: true)
        // Re-apply transparency after every resize — AppKit may recreate layers on frame changes.
        makeTransparent(hostView)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
    }

    private static func defaultFrame(wakeVoiceCard: OrbitListeningPresence.WakeVoiceCard?) -> NSRect {
        let (panelWidth, panelHeight): (CGFloat, CGFloat)
        if let card = wakeVoiceCard {
            if card.title.isEmpty {
                panelWidth = 340; panelHeight = 88   // compact question pill
            } else {
                panelWidth = 420; panelHeight = 260  // standard file-pick / confirm card
            }
        } else {
            panelWidth = 116; panelHeight = 116      // orb
        }
        guard let screen = NSScreen.main else {
            return NSRect(x: 100, y: 100, width: panelWidth, height: panelHeight)
        }
        let vf = screen.visibleFrame
        let x = vf.midX - panelWidth / 2
        let y = vf.maxY - panelHeight - 8
        return NSRect(x: x, y: y, width: panelWidth, height: panelHeight)
    }
}
