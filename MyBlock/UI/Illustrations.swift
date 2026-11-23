// Flat, top-down track illustrations in the style of the mood board: red lanes from above,
// athletes crouched in their blocks with singlets and hard sun shadows. Drawn in code so they
// stay sharp at any size and follow the palette.

import SwiftUI

/// One athlete seen from above in the set position.
struct Runner {
    var singlet: Color
    var trim: Color
    var skin: Color
    var hair: Color
    var shorts: Color
    var bun = false

    static let lightBlue = Runner(singlet: Color(hex: 0xBFDCF2), trim: .white, skin: Color(hex: 0xE2B48E),
                                  hair: Color(hex: 0x2A1E17), shorts: .white, bun: true)
    static let yellow = Runner(singlet: Theme.yellow, trim: .white, skin: Color(hex: 0x7A4A2E),
                               hair: Color(hex: 0x15110E), shorts: Theme.yellow)
    static let blue = Runner(singlet: Color(hex: 0x4F7FD0), trim: Color(hex: 0xBFDCF2), skin: Color(hex: 0xC98E66),
                             hair: Color(hex: 0x6B4A2C), shorts: Color(hex: 0x3B66B5), bun: true)
}

enum TrackColors {
    static let surface = Color(hex: 0xC0573F)
    static let shadow = Color(hex: 0x8E3A2A).opacity(0.55)
    static let line = Color.white
    static let mark = Theme.sky
    static let apron = Color(hex: 0xE3E7ED)
    static let rail = Color(hex: 0x4B4F57)
    static let pedal = Color(hex: 0xB9BDC4)
}

/// Lanes running up the picture with athletes in their blocks at the start line.
/// `phone` adds a camera on a tripod beside the lanes, filming across them.
struct LaneScene: View {
    var runners: [Runner?]
    var firstLane = 3
    var showPhone = false
    /// Which part the setup guide is explaining (0 phone, 1 field of view, 2 athlete).
    var emphasis: Int?

    var body: some View {
        Canvas { ctx, size in draw(&ctx, size) }
            .overlay { PrintGrain(opacity: 0.09) }
            .accessibilityHidden(true)
    }

    private func draw(_ ctx: inout GraphicsContext, _ size: CGSize) {
        let w = size.width, h = size.height
        let trackW = showPhone ? w * 0.74 : w
        let laneW = trackW / CGFloat(max(1, runners.count))
        let u = laneW / 10
        let startY = h * (showPhone ? 0.16 : 0.2)

        // Running surface and apron.
        ctx.fill(Path(CGRect(x: 0, y: 0, width: trackW, height: h)), with: .color(TrackColors.surface))
        if showPhone {
            ctx.fill(Path(CGRect(x: trackW, y: 0, width: w - trackW, height: h)), with: .color(TrackColors.apron))
        }

        // Lane lines, start line, and the small blue marks on the lines.
        var lines = Path()
        for i in 0...runners.count {
            let x = CGFloat(i) * laneW
            lines.addRect(CGRect(x: x - 1.5, y: 0, width: 3, height: h))
        }
        lines.addRect(CGRect(x: 0, y: startY - 2.5, width: trackW, height: 5))
        ctx.fill(lines, with: .color(TrackColors.line))
        for i in 0...runners.count {
            let x = CGFloat(i) * laneW
            ctx.fill(Path(CGRect(x: x - 7, y: startY - u * 3.4, width: 14, height: 3)), with: .color(TrackColors.mark))
        }

        // Lane numbers painted near the bottom of each lane.
        for i in runners.indices {
            let label = Text("\(firstLane + i)").font(Theme.Fonts.titleFixed(u * 3)).foregroundColor(TrackColors.line.opacity(0.9))
            ctx.draw(label, at: CGPoint(x: (CGFloat(i) + 0.5) * laneW, y: min(h - u * 2.0, startY + u * 15.6)))
        }

        let subject = runners.firstIndex(where: { $0 != nil })
        let phone = CGPoint(x: trackW + (w - trackW) * 0.5, y: startY + u * 6)
        if showPhone {
            drawFieldOfView(&ctx, phone: phone, startY: startY, u: u, h: h)
        }

        for (i, runner) in runners.enumerated() {
            guard let runner else { continue }
            let cx = (CGFloat(i) + 0.5) * laneW
            var layer = ctx
            drawBlocks(&layer, cx: cx, y0: startY, u: u)
            // Hard shadow from a high sun, down and to the right, as in the reference photo.
            var shadow = layer
            shadow.translateBy(x: u * 0.8, y: u * 0.55)
            drawRunner(&shadow, runner, cx: cx, y0: startY, u: u, flat: TrackColors.shadow)
            drawRunner(&layer, runner, cx: cx, y0: startY, u: u, flat: nil)
        }

        if showPhone, let subject {
            drawPhone(&ctx, size: size, phone: phone, subjectX: (CGFloat(subject) + 0.5) * laneW, u: u)
        }
    }

    private func drawBlocks(_ ctx: inout GraphicsContext, cx: CGFloat, y0: CGFloat, u: CGFloat) {
        let rail = CGRect(x: cx - u * 0.35, y: y0 + u * 7.4, width: u * 0.7, height: u * 4.2)
        ctx.fill(Path(roundedRect: rail, cornerRadius: u * 0.2), with: .color(TrackColors.rail))
        for (dx, dy) in [(-1.4, 8.6), (1.4, 10.6)] {
            let pedal = CGRect(x: cx + u * dx - u * 0.9, y: y0 + u * dy, width: u * 1.8, height: u * 0.8)
            ctx.fill(Path(roundedRect: pedal, cornerRadius: u * 0.15), with: .color(TrackColors.pedal))
            ctx.stroke(Path(roundedRect: pedal, cornerRadius: u * 0.15), with: .color(Theme.navy.opacity(0.6)), lineWidth: 1)
        }
    }

    /// The athlete from above: hands on the line, straight arms, back, hips, and feet on the pedals.
    /// `flat` paints everything one color (for the shadow).
    private func drawRunner(_ ctx: inout GraphicsContext, _ r: Runner, cx: CGFloat, y0: CGFloat, u: CGFloat, flat: Color?) {
        func c(_ color: Color) -> GraphicsContext.Shading { .color(flat ?? color) }
        let skin = r.skin

        // Lower legs back to the pedals, with socks and shoes.
        for (dx, footY) in [(-1.4, 8.7), (1.4, 10.7)] {
            var leg = Path()
            leg.move(to: CGPoint(x: cx + u * dx * 0.7, y: y0 + u * 6.6))
            leg.addLine(to: CGPoint(x: cx + u * dx, y: y0 + u * (footY - 0.6)))
            ctx.stroke(leg, with: c(skin), style: StrokeStyle(lineWidth: u * 1.1, lineCap: .round))
            let sock = CGRect(x: cx + u * dx - u * 0.55, y: y0 + u * (footY - 1.1), width: u * 1.1, height: u * 0.6)
            ctx.fill(Path(roundedRect: sock, cornerRadius: u * 0.2), with: c(Theme.white))
            let shoe = CGRect(x: cx + u * dx - u * 0.6, y: y0 + u * (footY - 0.6), width: u * 1.2, height: u * 1.3)
            ctx.fill(Path(ellipseIn: shoe), with: c(Theme.navy))
        }

        // Arms: short from above, because the shoulders sit almost over the hands in set.
        for side in [-1.0, 1.0] {
            var arm = Path()
            arm.move(to: CGPoint(x: cx + u * 2.35 * side, y: y0 + u * 1.9))
            arm.addLine(to: CGPoint(x: cx + u * 2.2 * side, y: y0 + u * 0.15))
            ctx.stroke(arm, with: c(skin), style: StrokeStyle(lineWidth: u * 1.15, lineCap: .round))
            let hand = CGRect(x: cx + u * 2.2 * side - u * 0.6, y: y0 - u * 0.5, width: u * 1.2, height: u * 0.8)
            ctx.fill(Path(ellipseIn: hand), with: c(skin))
        }

        // Shorts across the hips.
        let hips = CGRect(x: cx - u * 2.0, y: y0 + u * 5.7, width: u * 4.0, height: u * 1.7)
        ctx.fill(Path(roundedRect: hips, cornerRadius: u * 0.8), with: c(r.shorts))

        // Back: broad shoulders tapering to the waist. Skin first, the singlet over it.
        var back = Path()
        back.move(to: CGPoint(x: cx - u * 2.75, y: y0 + u * 2.0))
        back.addQuadCurve(to: CGPoint(x: cx + u * 2.75, y: y0 + u * 2.0), control: CGPoint(x: cx, y: y0 + u * 0.9))
        back.addQuadCurve(to: CGPoint(x: cx + u * 1.9, y: y0 + u * 6.2), control: CGPoint(x: cx + u * 2.7, y: y0 + u * 4.4))
        back.addLine(to: CGPoint(x: cx - u * 1.9, y: y0 + u * 6.2))
        back.addQuadCurve(to: CGPoint(x: cx - u * 2.75, y: y0 + u * 2.0), control: CGPoint(x: cx - u * 2.7, y: y0 + u * 4.4))
        ctx.fill(back, with: c(skin))

        // Racerback singlet: narrow straps at the shoulders, full width lower down.
        var singlet = Path()
        singlet.move(to: CGPoint(x: cx - u * 1.2, y: y0 + u * 1.6))
        singlet.addQuadCurve(to: CGPoint(x: cx + u * 1.2, y: y0 + u * 1.6), control: CGPoint(x: cx, y: y0 + u * 2.5))
        singlet.addQuadCurve(to: CGPoint(x: cx + u * 2.05, y: y0 + u * 6.2), control: CGPoint(x: cx + u * 1.6, y: y0 + u * 3.9))
        singlet.addLine(to: CGPoint(x: cx - u * 2.05, y: y0 + u * 6.2))
        singlet.addQuadCurve(to: CGPoint(x: cx - u * 1.2, y: y0 + u * 1.6), control: CGPoint(x: cx - u * 1.6, y: y0 + u * 3.9))
        ctx.fill(singlet, with: c(r.singlet))
        if flat == nil {
            ctx.stroke(singlet, with: .color(r.trim), lineWidth: u * 0.3)
        }

        // Head forward between the shoulders, seen from above: hair, with a bun for some athletes.
        let head = CGRect(x: cx - u * 1.2, y: y0 - u * 0.2, width: u * 2.4, height: u * 2.5)
        ctx.fill(Path(ellipseIn: head), with: c(r.hair))
        if r.bun {
            ctx.fill(Path(ellipseIn: CGRect(x: cx - u * 0.55, y: y0 + u * 1.95, width: u * 1.1, height: u * 0.9)), with: c(r.hair))
        }
    }

    private func drawFieldOfView(_ ctx: inout GraphicsContext, phone: CGPoint, startY: CGFloat, u: CGFloat, h: CGFloat) {
        let top = CGPoint(x: 0, y: max(0, startY - u * 9))
        let bottom = CGPoint(x: 0, y: min(h, startY + u * 17))
        var cone = Path()
        cone.move(to: phone)
        cone.addLine(to: top)
        cone.addLine(to: bottom)
        cone.closeSubpath()
        let strong = emphasis == nil || emphasis == 1
        ctx.fill(cone, with: .color(Theme.yellow.opacity(strong ? 0.22 : 0.1)))
        var edges = Path()
        edges.move(to: top)
        edges.addLine(to: phone)
        edges.addLine(to: bottom)
        ctx.stroke(edges, with: .color(Theme.yellow.opacity(strong ? 1 : 0.55)), style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
    }

    private func drawPhone(_ ctx: inout GraphicsContext, size: CGSize, phone: CGPoint, subjectX: CGFloat, u: CGFloat) {
        let h = size.height

        // Tripod legs and the phone, side-on with its lens toward the lanes.
        // Three legs spread evenly under the phone, with feet.
        var legs = Path()
        for angle in [Double.pi * 0.25, Double.pi * 0.9, Double.pi * 1.6] {
            let foot = CGPoint(x: phone.x + cos(angle) * u * 2.8, y: phone.y + sin(angle) * u * 2.8)
            legs.move(to: phone)
            legs.addLine(to: foot)
            ctx.fill(Path(ellipseIn: CGRect(x: foot.x - 2.5, y: foot.y - 2.5, width: 5, height: 5)), with: .color(Theme.navy))
        }
        ctx.stroke(legs, with: .color(Theme.navy), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        let body = CGRect(x: phone.x - u * 0.8, y: phone.y - u * 2.2, width: u * 1.6, height: u * 4.4)
        let phoneEmphasis = emphasis == nil || emphasis == 0
        ctx.fill(Path(roundedRect: body.offsetBy(dx: 3, dy: 3), cornerRadius: u * 0.4), with: .color(Theme.navy))
        ctx.fill(Path(roundedRect: body, cornerRadius: u * 0.4), with: .color(phoneEmphasis ? Theme.red : Theme.white))
        ctx.stroke(Path(roundedRect: body, cornerRadius: u * 0.4), with: .color(Theme.navy), lineWidth: 2)
        ctx.fill(Path(ellipseIn: CGRect(x: body.minX + u * 0.2, y: phone.y - u * 1.6, width: u * 0.6, height: u * 0.6)),
                 with: .color(Theme.navy))

        // Dimension line from the athlete's lane to the phone.
        let dimY = h - u * 2.4
        var dimension = Path()
        dimension.move(to: CGPoint(x: subjectX, y: dimY))
        dimension.addLine(to: CGPoint(x: phone.x, y: dimY))
        for x in [subjectX, phone.x] {
            dimension.move(to: CGPoint(x: x, y: dimY - u * 0.9))
            dimension.addLine(to: CGPoint(x: x, y: dimY + u * 0.9))
        }
        ctx.stroke(dimension, with: .color(Theme.navy), lineWidth: 2)
        let tag = Text("3–5 m").font(Theme.Fonts.roboto(.bold, max(11, u * 1.5), relativeTo: .caption)).foregroundColor(Theme.navy)
        let mid = CGPoint(x: (subjectX + phone.x) / 2, y: dimY)
        let resolved = ctx.resolve(tag)
        let tagSize = resolved.measure(in: size)
        let tagRect = CGRect(x: mid.x - tagSize.width / 2 - 6, y: mid.y - tagSize.height / 2 - 2,
                             width: tagSize.width + 12, height: tagSize.height + 4)
        ctx.fill(Path(roundedRect: tagRect, cornerRadius: 3), with: .color(Theme.white))
        ctx.stroke(Path(roundedRect: tagRect, cornerRadius: 3), with: .color(Theme.navy), lineWidth: 1.5)
        ctx.draw(resolved, at: mid)

        let phoneLabel = Text("Phone").font(Theme.Fonts.roboto(.bold, max(11, u * 1.4), relativeTo: .caption)).foregroundColor(Theme.navy)
        ctx.draw(phoneLabel, at: CGPoint(x: phone.x, y: phone.y - u * 3.6))
    }
}

/// The placement guide picture: one athlete in lane 4, the phone beside the track.
struct PlacementDiagram: View {
    let highlight: Int?

    var body: some View {
        LaneScene(runners: [nil, .yellow, nil], firstLane: 3, showPhone: true, emphasis: highlight)
            .accessibilityElement()
            .accessibilityLabel("Diagram from above: the phone stands on a tripod 3 to 5 metres to the side of the lane, filming across it toward the athlete in the blocks.")
    }
}

/// Faint print grain, like ink on old poster paper. Deterministic, so it never shimmers.
struct PrintGrain: View {
    var opacity: Double = 0.07
    /// Light grain on dark fields, dark grain on light ones.
    var light = false

    var body: some View {
        Canvas { ctx, size in
            var seed: UInt64 = 0x9E3779B97F4A7C15
            func next() -> Double {
                seed = seed &* 6364136223846793005 &+ 1442695040888963407
                return Double(seed >> 11) / Double(1 << 53)
            }
            let count = Int(size.width * size.height / 38)
            var dots = Path()
            for _ in 0..<count {
                let r = 0.4 + next() * 0.9
                dots.addEllipse(in: CGRect(x: next() * size.width, y: next() * size.height, width: r, height: r))
            }
            ctx.fill(dots, with: .color((light ? Color.white : Color.black).opacity(opacity)))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
