import CoreGraphics
import Foundation

/// One correction for the drawing.
struct Suggestion: Identifiable {
    enum Kind { case shape, value, missing }

    let id = UUID()
    let kind: Kind
    let area: String
    let message: String
    /// Larger is more important.
    let severity: Double
    /// The area in the reference, in pixels, top-left origin.
    let rect: CGRect
    /// For a shape error: where the drawing has the feature now, and where it must go.
    let move: (from: CGPoint, to: CGPoint)?
}

/// The result of a local search: how the drawing's version of an area is moved and scaled
/// against the reference. A positive dy means that the drawing has the area lower.
struct LocalFit {
    var dx: Double = 0, dy: Double = 0, sx: Double = 1, sy: Double = 1
    var score: Double = -1
}

enum FitAxes { case both, vertical, horizontal }

extension DrawingCheck {
    /// Shape errors for each feature and value errors for each area of the head, the largest first.
    func suggestions(for lesson: Lesson) -> [Suggestion] {
        guard let g = lesson.geometry else { return [] }
        let shapes = shapeSuggestions(lesson, g)
        // When most features have a large shape error, the alignment is wrong, not the drawing.
        let large = shapes.filter { $0.kind == .shape && $0.severity > 6 }
        if large.count >= 4 {
            return [Suggestion(
                kind: .missing, area: "Alignment",
                message: "Most features seem to be in the wrong place, so the drawing is probably not aligned well. Click Align by Hand and click the centers of the eyes.",
                severity: 100, rect: CGRect(x: 0, y: 0, width: lesson.analysis.width, height: lesson.analysis.height), move: nil)]
        }
        let result = shapes + valueSuggestions(lesson, g)
        return Array(result.sorted { $0.severity > $1.severity }.prefix(14))
    }

    // MARK: - Shapes

    private func shapeSuggestions(_ lesson: Lesson, _ g: LessonBuilder.FaceGeometry) -> [Suggestion] {
        let a = lesson.analysis
        let h = CGFloat(a.height), ew = lesson.eyeWidth
        func top(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: h - p.y) }
        func box(_ pts: [CGPoint], margin: CGFloat, minWidth: CGFloat = 0, minHeight: CGFloat = 0) -> CGRect {
            let t = pts.map(top)
            let r = CGRect(x: t.map(\.x).min()!, y: t.map(\.y).min()!, width: 0, height: 0)
                .union(CGRect(x: t.map(\.x).max()!, y: t.map(\.y).max()!, width: 0, height: 0))
                .insetBy(dx: -margin, dy: -margin)
            let dw = max(0, minWidth - r.width) / 2, dh = max(0, minHeight - r.height) / 2
            return r.insetBy(dx: -dw, dy: -dh)
        }
        func around(_ p: CGPoint, _ width: CGFloat, _ height: CGFloat) -> CGRect {
            let t = top(p)
            return CGRect(x: t.x - width / 2, y: t.y - height / 2, width: width, height: height)
        }

        let (leftEye, rightEye) = g.leftEye.x < g.rightEye.x ? (g.leftEyeOutline, g.rightEyeOutline) : (g.rightEyeOutline, g.leftEyeOutline)
        let (leftBrow, rightBrow) = LessonBuilder.centroid(g.leftBrowOutline).x < LessonBuilder.centroid(g.rightBrowOutline).x
            ? (g.leftBrowOutline, g.rightBrowOutline) : (g.rightBrowOutline, g.leftBrowOutline)
        let crown = lesson.outline.max(by: { g.height($0) < g.height($1) }) ?? g.brow
        let level = lesson.outline.filter { abs(g.height($0)) < lesson.headHeight * 0.1 }
        let leftSide = level.min(by: { LessonBuilder.dot($0, g.across) < LessonBuilder.dot($1, g.across) }) ?? g.leftEye
        let rightSide = level.max(by: { LessonBuilder.dot($0, g.across) < LessonBuilder.dot($1, g.across) }) ?? g.rightEye

        let regions: [(name: String, rect: CGRect, axes: FitAxes)] = [
            ("Eye on the left", box(leftEye, margin: ew * 0.2, minWidth: ew * 1.4, minHeight: ew * 0.9), .both),
            ("Eye on the right", box(rightEye, margin: ew * 0.2, minWidth: ew * 1.4, minHeight: ew * 0.9), .both),
            ("Brow on the left", box(leftBrow, margin: ew * 0.25), .both),
            ("Brow on the right", box(rightBrow, margin: ew * 0.25), .both),
            ("Nose", box(g.nose, margin: ew * 0.3), .both),
            ("Mouth", box(g.lips, margin: ew * 0.15, minHeight: ew * 0.7), .both),
            ("Chin", around(g.chin, ew * 2, ew * 1.2), .vertical),
            ("Top of the head", around(crown, ew * 2.4, ew * 1.2), .vertical),
            ("Side of the head on the left", around(leftSide, ew * 1.2, ew * 2), .horizontal),
            ("Side of the head on the right", around(rightSide, ew * 1.2, ew * 2), .horizontal),
        ]

        // The paper, the pencil and the photo change the tone curve of the drawing. Give the drawing
        // the same tone distribution as the reference over the head, so that the shape search
        // compares like with like.
        // Compare sharp images: small errors of shape show in the detail.
        let sharpReference = LessonBuilder.boxBlur(a.gray.pixels, a.width, a.height, radius: 1)
        let sharpDrawing = LessonBuilder.boxBlur(pixels, a.width, a.height, radius: 1)
        let matched = Self.matchDistribution(sharpDrawing, to: sharpReference, mask: a.mask)
        let channels = [(reference: sharpReference, drawing: matched)]
        let debug = ProcessInfo.processInfo.environment["PM_DEBUG"] != nil

        // 1. Local search in each area.
        var fits: [(name: String, rect: CGRect, axes: FitAxes, fit: LocalFit, gain: Double)] = []
        var result: [Suggestion] = []
        for region in regions {
            let rect = region.rect.intersection(CGRect(x: 0, y: 0, width: a.width, height: a.height))
            guard rect.width > 4, rect.height > 4,
                  let fit = Self.localFit(
                      channels: channels, width: a.width, height: a.height,
                      samples: sampleGrid(rect, step: max(1, Int(ew / 20))), center: CGPoint(x: rect.midX, y: rect.midY),
                      reach: Double(ew) * 0.6, axes: region.axes)
            else { continue }
            if debug {
                print(String(format: "    %@: dx %.1f dy %.1f sx %.2f sy %.2f score %.3f gain %.3f contrast %.3f", region.name, fit.fit.dx, fit.fit.dy, fit.fit.sx, fit.fit.sy, fit.fit.score, fit.gain, fit.contrast))
            }
            if fit.contrast < 0.03 {
                result.append(Suggestion(
                    kind: .missing, area: region.name, message: "This area looks empty. Draw it first, then check again.",
                    severity: 3, rect: rect, move: nil))
            } else if fit.fit.score > 0.45 {
                fits.append((region.name, rect, region.axes, fit.fit, fit.gain))
            }
        }

        // 2. The drawing as a whole can be a little larger, turned or moved, and real errors pull the
        // first alignment too. Fit one similarity transform to all the local moves, without the
        // outliers, and keep only what is left: the error of each area against the drawing as a whole.
        let eyes = a.eyes ?? (.zero, .zero)
        let origin = CGPoint(x: (eyes.0.x + eyes.1.x) / 2, y: (eyes.0.y + eyes.1.y) / 2)
        let whole = Self.similarity(
            fits.map { (center: CGPoint(x: $0.rect.midX - origin.x, y: $0.rect.midY - origin.y), dx: $0.fit.dx, dy: $0.fit.dy, axes: $0.axes) },
            tolerance: Double(ew) * 0.1)
        func residual(_ f: (name: String, rect: CGRect, axes: FitAxes, fit: LocalFit, gain: Double)) -> LocalFit {
            let u = (x: Double(f.rect.midX - origin.x), y: Double(f.rect.midY - origin.y))
            var r = f.fit
            if f.axes != .vertical { r.dx -= whole.alpha * u.x - whole.beta * u.y + whole.tx }
            if f.axes != .horizontal { r.dy -= whole.beta * u.x + whole.alpha * u.y + whole.ty }
            r.sx /= 1 + whole.alpha
            r.sy /= 1 + whole.alpha
            return r
        }
        if debug {
            print(String(format: "    whole drawing: scale %.3f rotation %.4f move %.1f %.1f", 1 + whole.alpha, whole.beta, whole.tx, whole.ty))
        }

        // 3. Widths: the corners of the mouth and the wings of the nose, each searched left and right
        // only. This finds a wrong width better than the size of the full box.
        var widths: [String: Double] = [:]
        for (name, points) in [("Mouth", g.lips), ("Nose", g.nose)] where points.count > 2 {
            let ordered = points.sorted { LessonBuilder.dot($0, g.across) < LessonBuilder.dot($1, g.across) }
            let corners = [ordered.first!, ordered.last!].map { around($0, ew * 0.7, ew * 0.6) }.compactMap { rect -> Double? in
                let rect = rect.intersection(CGRect(x: 0, y: 0, width: a.width, height: a.height))
                guard rect.width > 4, rect.height > 4,
                      let fit = Self.localFit(
                          channels: channels, width: a.width, height: a.height,
                          samples: sampleGrid(rect, step: max(1, Int(ew / 20))), center: CGPoint(x: rect.midX, y: rect.midY),
                          reach: Double(ew) * 0.4, axes: .horizontal),
                      fit.fit.score > 0.45
                else { return nil }
                return fit.fit.dx
            }
            guard corners.count == 2 else { continue }
            let width = Double(LessonBuilder.dot(ordered.last!, g.across) - LessonBuilder.dot(ordered.first!, g.across))
            // Take away the scale of the drawing as a whole.
            widths[name] = (corners[1] - corners[0]) / max(width, 1) - whole.alpha
            if debug {
                print(String(format: "    %@ corners: left %.1f right %.1f width change %.2f", name, corners[0], corners[1], widths[name]!))
            }
        }
        func widthSentence(_ name: String) -> String? {
            guard let change = widths[name], abs(change) >= 0.08 else { return nil }
            return "It is \(Int((abs(change) * 100).rounded()))% too \(change > 0 ? "wide" : "narrow"): check its corners against the \(name == "Mouth" ? "pupils" : "inner corners of the eyes")."
        }

        // 4. Words for what is left.
        var reported: Set<String> = []
        for f in fits {
            var r = residual(f)
            // For the mouth and the nose, the width comes from the corners.
            let cornerWidth = widths[f.name] != nil
            if cornerWidth { r.sx = 1 }
            let sentences = [shapeMessage(r, axes: f.axes, eyeWidth: Double(ew)), cornerWidth ? widthSentence(f.name) : nil].compactMap { $0 }
            guard !sentences.isEmpty else { continue }
            reported.insert(f.name)
            let moveSize = hypot(r.dx, r.dy) / Double(ew)
            let sizeError = max(abs(r.sx - 1), abs(r.sy - 1), abs(widths[f.name] ?? 0))
            let target = CGPoint(x: f.rect.midX, y: f.rect.midY)
            result.append(Suggestion(
                kind: .shape, area: f.name, message: sentences.joined(separator: " "),
                severity: moveSize * 10 + sizeError * 12, rect: f.rect,
                move: moveSize > 0.03 ? (CGPoint(x: target.x + r.dx, y: target.y + r.dy), target) : nil))
        }
        for name in ["Mouth", "Nose"] where !reported.contains(name) {
            guard let sentence = widthSentence(name), let region = regions.first(where: { $0.name == name }) else { continue }
            result.append(Suggestion(kind: .shape, area: name, message: sentence, severity: abs(widths[name]!) * 12, rect: region.rect, move: nil))
        }
        return result
    }

    /// A similarity transform as a move of each point: dx = alpha·x - beta·y + tx, dy = beta·x + alpha·y + ty,
    /// where 1 + alpha is about the scale and beta about the rotation in radians. Least squares over the
    /// measured parts of the moves, three times, each time without the points far from the fit.
    static func similarity(
        _ points: [(center: CGPoint, dx: Double, dy: Double, axes: FitAxes)], tolerance: Double
    ) -> (alpha: Double, beta: Double, tx: Double, ty: Double) {
        var inliers = Array(points.indices)
        var solution = (alpha: 0.0, beta: 0.0, tx: 0.0, ty: 0.0)
        for _ in 0..<3 {
            var rows: [[Double]] = [], values: [Double] = []
            for i in inliers {
                let p = points[i], x = Double(p.center.x), y = Double(p.center.y)
                if p.axes != .vertical { rows.append([x, -y, 1, 0]); values.append(p.dx) }
                if p.axes != .horizontal { rows.append([y, x, 0, 1]); values.append(p.dy) }
            }
            guard rows.count >= 6, let c = LinearAlgebra.leastSquares(rows, values) else { break }
            solution = (c[0], c[1], c[2], c[3])
            let errors = points.indices.map { i -> Double in
                let p = points[i], x = Double(p.center.x), y = Double(p.center.y)
                let ex = p.axes == .vertical ? 0 : p.dx - (c[0] * x - c[1] * y + c[2])
                let ey = p.axes == .horizontal ? 0 : p.dy - (c[1] * x + c[0] * y + c[3])
                return hypot(ex, ey)
            }
            let median = errors.sorted()[errors.count / 2]
            inliers = points.indices.filter { errors[$0] <= max(2.5 * median, tolerance) }
        }
        return solution
    }

    /// Words for a shape error, or nil when the area is close enough.
    func shapeMessage(_ fit: LocalFit, axes: FitAxes, eyeWidth: Double) -> String? {
        func distance(_ pixels: Double) -> String {
            if let mm = millimetersPerPixel {
                let value = abs(pixels) * mm
                return value < 10 ? String(format: "%.1f mm", value) : "\(Int(value.rounded())) mm"
            }
            return String(format: "%.2f eye widths", abs(pixels) / eyeWidth)
        }
        // Report a move from 0.08 eye widths and 1 mm, and a size error from 8%.
        let minimum = max(eyeWidth * 0.08, millimetersPerPixel.map { 1 / $0 } ?? 0)
        var parts: [String] = []
        var moves: [String] = []
        if fit.dy.magnitude >= minimum { moves.append("\(distance(fit.dy)) \(fit.dy > 0 ? "up" : "down")") }
        if fit.dx.magnitude >= minimum { moves.append("\(distance(fit.dx)) to the \(fit.dx > 0 ? "left" : "right")") }
        if !moves.isEmpty { parts.append("Move it " + moves.joined(separator: " and ") + ".") }
        if axes == .both {
            var sizes: [String] = []
            if abs(fit.sy - 1) >= 0.08 { sizes.append("\(Int((abs(fit.sy - 1) * 100).rounded()))% too \(fit.sy > 1 ? "tall" : "short")") }
            if abs(fit.sx - 1) >= 0.08 { sizes.append("\(Int((abs(fit.sx - 1) * 100).rounded()))% too \(fit.sx > 1 ? "wide" : "narrow")") }
            if !sizes.isEmpty { parts.append("It is " + sizes.joined(separator: " and ") + ".") }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Quantile mapping: each tone of `values` gets the reference tone at the same rank inside the mask.
    static func matchDistribution(_ values: [Float], to reference: [Float], mask: [Bool]) -> [Float] {
        let inside = values.indices.filter { mask[$0] }
        guard inside.count > 100 else { return values }
        let source = inside.map { values[$0] }.sorted()
        let target = inside.map { reference[$0] }.sorted()
        // A table of 256 bins from tone to rank to reference tone.
        var table = [Float](repeating: 0, count: 256)
        var j = 0
        for bin in 0..<256 {
            let tone = Float(bin) / 255
            while j < source.count - 1 && source[j] < tone { j += 1 }
            table[bin] = target[j * (target.count - 1) / max(source.count - 1, 1)]
        }
        return values.map { table[min(255, max(0, Int(($0 * 255).rounded())))] }
    }

    private func sampleGrid(_ rect: CGRect, step: Int) -> [(x: Int, y: Int)] {
        var points: [(x: Int, y: Int)] = []
        for y in stride(from: Int(rect.minY), to: Int(rect.maxY), by: step) {
            for x in stride(from: Int(rect.minX), to: Int(rect.maxX), by: step) { points.append((x, y)) }
        }
        return points
    }

    /// Finds the move and the size of the drawing's version of an area that best matches the reference:
    /// the mean Pearson correlation over the channels (tones and edges). Moves first, then sizes
    /// around the best move. Returns nil when the reference area has no detail to match.
    /// `gain` is how much better the result is than no change.
    static func localFit(
        channels: [(reference: [Float], drawing: [Float])], width w: Int, height h: Int,
        samples: [(x: Int, y: Int)], center: CGPoint, reach: Double, axes: FitAxes
    ) -> (fit: LocalFit, gain: Double, contrast: Double)? {
        let prepared = channels.map { channel -> (centered: [Double], norm: Double) in
            let ref = samples.map { Double(channel.reference[$0.y * w + $0.x]) }
            let mean = ref.reduce(0, +) / Double(ref.count)
            let centered = ref.map { $0 - mean }
            return (centered, centered.map { $0 * $0 }.reduce(0, +).squareRoot())
        }
        guard prepared[0].norm / Double(samples.count).squareRoot() > 0.02 else { return nil }
        let cx = Double(center.x), cy = Double(center.y)

        func values(_ f: LocalFit, _ image: [Float]) -> [Double] {
            samples.map { p in
                let x = Int((cx + (Double(p.x) - cx) * f.sx + f.dx).rounded())
                let y = Int((cy + (Double(p.y) - cy) * f.sy + f.dy).rounded())
                return x >= 0 && x < w && y >= 0 && y < h ? Double(image[y * w + x]) : 1
            }
        }
        func score(_ f: LocalFit) -> Double {
            var total = 0.0
            for (channel, ref) in zip(channels, prepared) {
                let v = values(f, channel.drawing)
                let m = v.reduce(0, +) / Double(v.count)
                var dotProduct = 0.0, n = 0.0
                for i in v.indices {
                    let d = v[i] - m
                    dotProduct += d * ref.centered[i]
                    n += d * d
                }
                total += dotProduct / max(n.squareRoot() * ref.norm, 1e-9)
            }
            return total / Double(channels.count)
        }

        var best = LocalFit()
        best.score = score(best)
        let none = best.score
        let step = reach / 15
        let xs = axes == .vertical ? [0.0] : stride(from: -reach, through: reach, by: step).map { $0 }
        let ys = axes == .horizontal ? [0.0] : stride(from: -reach, through: reach, by: step).map { $0 }
        for dy in ys {
            for dx in xs {
                var f = LocalFit(dx: dx, dy: dy)
                f.score = score(f)
                if f.score > best.score { best = f }
            }
        }
        if axes == .both {
            let center = best
            for sy in stride(from: 0.8, through: 1.2001, by: 0.02) {
                for sx in stride(from: 0.8, through: 1.2001, by: 0.02) {
                    for ddy in [-step / 2, 0, step / 2] {
                        for ddx in [-step / 2, 0, step / 2] {
                            var f = LocalFit(dx: center.dx + ddx, dy: center.dy + ddy, sx: sx, sy: sy)
                            f.score = score(f)
                            if f.score > best.score { best = f }
                        }
                    }
                }
            }
        }
        // Prefer no change when the best result is hardly better.
        if best.score - none < 0.002 {
            best = LocalFit()
            best.score = none
        }
        let v = values(best, channels[0].drawing)
        let m = v.reduce(0, +) / Double(v.count)
        let contrast = (v.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(v.count)).squareRoot()
        return (best, best.score - none, contrast)
    }

    // MARK: - Values

    private func valueSuggestions(_ lesson: Lesson, _ g: LessonBuilder.FaceGeometry) -> [Suggestion] {
        let a = lesson.analysis
        let w = a.width, h = a.height
        let drawn = steps(lesson.tones)
        let skin = lesson.form?.form.skin
        let classes = lesson.form?.maps.classes
        let center = LessonBuilder.dot(g.axis(g.height(g.eyes)), g.across)
        let noseHalf = lesson.eyeWidth * 0.6
        let jawAcross = g.jaw.map { LessonBuilder.dot($0, g.across) }
        let eyeBoxes = [g.leftEyeOutline, g.rightEyeOutline].map { pts -> (CGPoint, CGFloat) in
            (LessonBuilder.centroid(pts), lesson.eyeWidth * 0.9)
        }

        func zone(_ i: Int) -> String? {
            guard a.mask[i] else { return nil }
            let p = CGPoint(x: CGFloat(i % w), y: CGFloat(h - 1 - i / w))
            let height = g.height(p), side = LessonBuilder.dot(p, g.across) - center
            let sideName = side < 0 ? "on the left" : "on the right"
            if let socket = eyeBoxes.first(where: { hypot(p.x - $0.0.x, p.y - $0.0.y) < $0.1 }) {
                return "Eye socket \(socket.0.x < g.eyes.x ? "on the left" : "on the right")"
            }
            let isSkin = skin?[i] ?? (height < g.height(g.brow) + lesson.headHeight * 0.15 && height > g.height(g.chin))
            if !isSkin {
                if height > g.height(g.brow) - lesson.eyeWidth * 0.5 { return "Hair" }
                if height < g.height(g.chin), side > (jawAcross.min() ?? 0) - center, side < (jawAcross.max() ?? 0) - center { return "Neck" }
                return nil
            }
            if height > g.height(g.brow) { return "Forehead" }
            if height < g.height(g.mouth) - lesson.eyeWidth * 0.3 { return "Chin" }
            if abs(side) < noseHalf && height > g.height(g.noseBase) - lesson.eyeWidth * 0.2 { return "Nose" }
            if height > g.height(g.mouth) - lesson.eyeWidth * 0.3 && height < g.height(g.noseBase) && abs(side) < noseHalf * 1.4 {
                return "Mouth"
            }
            return "Cheek \(sideName)"
        }

        // Value errors are patches: connected areas where the smoothed difference is at least
        // 0.6 of a step. Each patch is named by the area at its center.
        let diff = drawn.indices.map { a.mask[$0] ? Float(drawn[$0] - lesson.tones.steps[$0]) : 0 }
        let smooth = LessonBuilder.boxBlur(diff, w, h, radius: max(2, Int(lesson.eyeWidth / 4)))
        let step = 2
        let gw = (w + step - 1) / step, gh = (h + step - 1) / step
        var label = [Int](repeating: -1, count: gw * gh)
        var patches: [(cells: [Int], sign: Float)] = []
        for start in 0..<(gw * gh) where label[start] < 0 {
            let i = (start / gw) * step * w + (start % gw) * step
            let v = smooth[i]
            guard a.mask[i], abs(v) >= 0.6 else { continue }
            let sign: Float = v > 0 ? 1 : -1
            var stack = [start], cells: [Int] = []
            label[start] = patches.count
            while let c = stack.popLast() {
                cells.append(c)
                let cx = c % gw, cy = c / gw
                for (nx, ny) in [(cx - 1, cy), (cx + 1, cy), (cx, cy - 1), (cx, cy + 1)] where nx >= 0 && nx < gw && ny >= 0 && ny < gh {
                    let n = ny * gw + nx
                    let j = ny * step * w + nx * step
                    if label[n] < 0, a.mask[j], smooth[j] * sign >= 0.6 {
                        label[n] = patches.count
                        stack.append(n)
                    }
                }
            }
            patches.append((cells, sign))
        }

        // A patch must be at least about 3/4 of an eye width across.
        let minimumCells = Int(pow(lesson.eyeWidth * 0.75 / CGFloat(step), 2))
        return patches.compactMap { patch -> Suggestion? in
            guard patch.cells.count >= minimumCells else { return nil }
            let pixels = patch.cells.map { ($0 / gw) * step * w + ($0 % gw) * step }
            let mean = pixels.map { smooth[$0] }.reduce(0, +) / Float(pixels.count)
            let xs = pixels.map { $0 % w }, ys = pixels.map { $0 / w }
            let rect = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()! + step, height: ys.max()! - ys.min()! + step)
            // The name: the most common area and family in the patch.
            var names: [String: Int] = [:]
            for i in pixels.prefix(4000) {
                guard let name = zone(i) else { continue }
                let family = classes.map { $0[i].isShadowFamily ? "shadow side" : "light side" }
                names[family.map { "\(name), \($0)" } ?? name, default: 0] += 1
            }
            guard let area = names.max(by: { $0.value < $1.value })?.key else { return nil }
            let steps = max(1, Int(abs(mean).rounded()))
            let unit = steps == 1 ? "value step" : "value steps"
            let size = millimetersPerPixel.map { String(format: " in an area about %.0f mm wide", Double(rect.width) * $0) } ?? ""
            let message = mean > 0
                ? "About \(steps) \(unit) too dark\(size). Use less pressure, or lift it with a kneaded eraser."
                : "About \(steps) \(unit) too light\(size). Add layers of hatching until it matches."
            return Suggestion(
                kind: .value, area: area.prefix(1).uppercased() + area.dropFirst(), message: message,
                severity: Double(abs(mean)) * Double(pixels.count).squareRoot() / 6, rect: rect, move: nil)
        }
    }
}
