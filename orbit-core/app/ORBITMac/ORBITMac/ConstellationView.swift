//
//  ConstellationView.swift
//  ORBITMac
//
//  Wake-only constellation overlay for voice disambiguation choices.
//

import AppKit
import SwiftUI

private struct ConstellationNodePlacement: Equatable {
    let item: OrbitListeningPresence.ConstellationItem
    let center: CGPoint
}

private struct ConstellationNodeView: View {
    let item: OrbitListeningPresence.ConstellationItem
    let isSelected: Bool

    var body: some View {
        ZStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text("NODE \(String(format: "%02d", item.id))")
                    .font(.system(size: 9, weight: .black))
                    .tracking(1.0)
                    .foregroundStyle(Color(red: 120 / 255, green: 205 / 255, blue: 255 / 255).opacity(0.75))

                Text(item.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)

                Text(item.subtitle)
                    .font(.system(size: 9, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.30))
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.top, 14)
            .padding(.bottom, 12)
            .frame(width: 168, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 8 / 255, green: 14 / 255, blue: 30 / 255).opacity(0.97),
                                Color(red: 4 / 255, green: 9 / 255, blue: 20 / 255).opacity(0.98),
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                Color(red: 120 / 255, green: 205 / 255, blue: 255 / 255)
                                    .opacity(isSelected ? 0.85 : 0.28),
                                lineWidth: 1
                            )
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 17, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color(red: 120 / 255, green: 205 / 255, blue: 255 / 255).opacity(0.30),
                                        Color(red: 60 / 255, green: 120 / 255, blue: 220 / 255).opacity(0.10),
                                        Color(red: 120 / 255, green: 205 / 255, blue: 255 / 255).opacity(0.20),
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                            .opacity(isSelected ? 1.0 : 0.55)
                    }
                    .overlay(alignment: .top) {
                        Rectangle()
                            .fill(
                                LinearGradient(
                                    colors: [
                                        .clear,
                                        Color(red: 120 / 255, green: 205 / 255, blue: 255 / 255).opacity(0.50),
                                        .clear,
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            )
                            .frame(height: 1)
                            .padding(.horizontal, 34)
                    }
            }
            .shadow(color: .black.opacity(0.65), radius: 16, x: 0, y: 8)
            .shadow(
                color: Color(red: 100 / 255, green: 188 / 255, blue: 255 / 255).opacity(isSelected ? 0.40 : 0.08),
                radius: isSelected ? 20 : 10,
                x: 0,
                y: 0
            )

            ConstellationDotView()
                .offset(y: -5)
        }
    }
}

private struct ConstellationDotView: View {
    @State private var pulsing = false

    var body: some View {
        Circle()
            .fill(
                RadialGradient(
                    colors: [
                        Color(red: 200 / 255, green: 238 / 255, blue: 255 / 255).opacity(0.95),
                        Color(red: 80 / 255, green: 160 / 255, blue: 255 / 255).opacity(0.80),
                    ],
                    center: .center,
                    startRadius: 0,
                    endRadius: 4.5
                )
            )
            .frame(width: 9, height: 9)
            .shadow(
                color: Color(red: 120 / 255, green: 205 / 255, blue: 255 / 255).opacity(pulsing ? 1.0 : 0.8),
                radius: pulsing ? 8 : 5
            )
            .shadow(
                color: Color(red: 80 / 255, green: 160 / 255, blue: 255 / 255).opacity(pulsing ? 0.5 : 0.3),
                radius: pulsing ? 14 : 8
            )
            .scaleEffect(pulsing ? 1.2 : 1.0)
            .animation(.easeInOut(duration: 2).repeatForever(autoreverses: true), value: pulsing)
            .onAppear { pulsing = true }
    }
}

private struct ConstellationThreadsView: View {
    let orbCenter: CGPoint
    let nodeCenters: [CGPoint]
    let strokeColor: Color

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, _ in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let dashPhase = CGFloat(t * (20.0 / 3.0)).truncatingRemainder(dividingBy: 20)
                for pt in nodeCenters {
                    var path = Path()
                    path.move(to: orbCenter)
                    path.addLine(to: pt)
                    context.stroke(
                        path,
                        with: .color(strokeColor),
                        style: StrokeStyle(lineWidth: 1, dash: [5, 5], dashPhase: -dashPhase)
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

struct ConstellationRootView: View {
    @ObservedObject private var presence = OrbitListeningPresence.shared
    @State private var visible = false

    private let nodeW: CGFloat = 168
    private let nodeH: CGFloat = 86

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            let orb = orbInfo(in: size)
            let placements = layout(items: presence.constellationItems, in: size, orbCenter: orb.center, orbRadius: orb.radius)

            ZStack {
                if presence.constellationVisible && !placements.isEmpty {
                    ConstellationThreadsView(
                        orbCenter: orb.center,
                        nodeCenters: placements.map(\.center),
                        strokeColor: threadColor(for: NSApplication.shared.effectiveAppearance)
                    )
                    .opacity(visible ? 1 : 0)
                    .animation(.easeOut(duration: 0.38), value: visible)

                    ForEach(Array(placements.enumerated()), id: \.element.item.id) { idx, placed in
                        let launch = CGSize(
                            width: orb.center.x - placed.center.x,
                            height: orb.center.y - placed.center.y
                        )

                        ConstellationNodeView(item: placed.item, isSelected: false)
                            .position(placed.center)
                            .offset(visible ? .zero : launch)
                            .scaleEffect(visible ? 1.0 : 0.12, anchor: .center)
                            .opacity(visible ? 1.0 : 0.0)
                            .animation(
                                visible
                                    ? .timingCurve(0.34, 1.18, 0.64, 1, duration: 0.64).delay(0.04 + Double(idx) * 0.055)
                                    : .timingCurve(0.4, 0.0, 0.6, 1.0, duration: 0.38).delay(Double(idx) * 0.018),
                                value: visible
                            )
                    }

                    hintStrip(count: placements.count, totalFound: presence.constellationTotalFound)
                        .position(x: size.width / 2, y: size.height - 28)
                        .transition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: presence.constellationVisible) { _, newValue in
                if newValue {
                    withAnimation(.easeOut(duration: 0.12)) { visible = true }
                } else {
                    withAnimation(.easeIn(duration: 0.24)) { visible = false }
                }
            }
            .onAppear {
                visible = presence.constellationVisible
            }
        }
    }

    private func hintStrip(count: Int, totalFound: Int) -> some View {
        HStack(spacing: 5) {
            if totalFound > count {
                Text("Found \(totalFound) — top \(count)")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.45))
                dividerLine
            }
            let shown = min(3, count)
            ForEach(1 ... shown, id: \.self) { i in
                if i > 1 { dividerLine }
                token("say", "open \(i)")
            }
            dividerLine
            if count > 3 {
                Text("… \"open \(count)\" · \"cancel\"")
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.32))
            } else {
                token("say", "cancel")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(.black.opacity(0.58))
        .clipShape(Capsule())
        .overlay {
            Capsule()
                .strokeBorder(.white.opacity(0.07), lineWidth: 1)
        }
    }

    private var dividerLine: some View {
        Rectangle()
            .fill(.white.opacity(0.09))
            .frame(width: 1, height: 11)
    }

    private func token(_ lead: String, _ cmd: String) -> some View {
        HStack(spacing: 4) {
            Text(lead)
                .foregroundStyle(.white.opacity(0.50))
            Text("\"\(cmd)\"")
                .foregroundStyle(Color(red: 120 / 255, green: 205 / 255, blue: 255 / 255).opacity(0.88))
        }
        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Color(red: 120 / 255, green: 205 / 255, blue: 255 / 255).opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .strokeBorder(Color(red: 120 / 255, green: 205 / 255, blue: 255 / 255).opacity(0.22), lineWidth: 1)
        }
    }

    private func orbInfo(in size: CGSize) -> (center: CGPoint, radius: CGFloat) {
        let orbPanelSize: CGFloat = 116
        let x = size.width / 2
        let y = 8 + orbPanelSize / 2
        return (CGPoint(x: x, y: y), 52)
    }

    private func threadColor(for appearance: NSAppearance) -> Color {
        let isDark = appearance.bestMatch(from: [.darkAqua, .vibrantDark]) != nil
        if isDark {
            return Color(red: 120 / 255, green: 205 / 255, blue: 255 / 255).opacity(0.20)
        }
        return Color(red: 20 / 255, green: 55 / 255, blue: 140 / 255).opacity(0.35)
    }

    private func layout(
        items: [OrbitListeningPresence.ConstellationItem],
        in size: CGSize,
        orbCenter: CGPoint,
        orbRadius: CGFloat
    ) -> [ConstellationNodePlacement] {
        let count = min(items.count, 15)
        guard count > 0 else { return [] }

        let padX: CGFloat = 90
        let padBottom: CGFloat = 20
        let minY = orbCenter.y + orbRadius + 24 + nodeH / 2
        let maxY = size.height - nodeH - padBottom
        let gap: CGFloat = 14
        let rInner = min(size.width * 0.18, 160)
        let rOuter = min(size.width * 0.40, 370)
        let halfFan: CGFloat = {
            switch count {
            case ...2: return 40
            case ...3: return 55
            case ...5: return 72
            case ...8: return 82
            case ...12: return 86
            default: return 88
            }
        }()

        let aStart = 90 - halfFan
        let aEnd = 90 + halfFan

        // Three radius bands for depth: close, mid, far
        let rMid = (rInner + rOuter) / 2
        let radiusBands = [rInner, rOuter, rMid, rOuter, rInner, rMid, rOuter, rInner]

        var points: [CGPoint] = []
        for i in 0 ..< count {
            let t = count == 1 ? 0.5 : CGFloat(i) / CGFloat(count - 1)
            let deg = aStart + t * (aEnd - aStart)
            let rad = deg * .pi / 180
            let jitter = CGFloat(((i * 23 + 11) % 17 - 8) * 12)
            let r = radiusBands[i % radiusBands.count] + jitter
            var x = orbCenter.x + cos(rad) * r
            var y = orbCenter.y + sin(rad) * r

            x = max(padX + nodeW / 2, min(size.width - padX - nodeW / 2, x))
            y = max(minY, min(maxY, y))
            points.append(CGPoint(x: x, y: y))
        }

        let hw = nodeW / 2
        let hh = nodeH / 2
        for _ in 0 ..< 120 {
            var moved = false
            for a in 0 ..< points.count {
                for b in (a + 1) ..< points.count {
                    var pa = points[a]
                    var pb = points[b]
                    let ox = (nodeW + gap) - abs(pa.x - pb.x)
                    let oy = (nodeH + gap) - abs(pa.y - pb.y)
                    if ox > 0, oy > 0 {
                        if ox < oy {
                            let push = ox / 2 + 1
                            let dir: CGFloat = pa.x >= pb.x ? 1 : -1
                            pa.x += dir * push
                            pb.x -= dir * push
                        } else {
                            let push = oy / 2 + 1
                            let dir: CGFloat = pa.y >= pb.y ? 1 : -1
                            pa.y += dir * push
                            pb.y -= dir * push
                        }
                        points[a] = pa
                        points[b] = pb
                        moved = true
                    }
                }
            }

            for i in 0 ..< points.count {
                points[i].x = max(padX + hw, min(size.width - padX - hw, points[i].x))
                points[i].y = max(minY + hh, min(maxY, points[i].y))
            }
            if !moved { break }
        }

        return Array(items.prefix(count).enumerated()).map { idx, item in
            ConstellationNodePlacement(item: item, center: points[idx])
        }
    }
}
