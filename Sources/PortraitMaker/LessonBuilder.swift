import CoreGraphics
import Foundation
import ImageIO
import Vision
import simd

struct GrayImage {
    let width: Int
    let height: Int
    /// 0 is black, 1 is white. Row 0 is the top row.
    let pixels: [Float]

    func value(x: Int, y: Int) -> Float {
        pixels[min(max(y, 0), height - 1) * width + min(max(x, 0), width - 1)]
    }
}

struct Layer {
    let image: CGImage
    var opacity: Double = 1
    /// Draw the lines in a strong color, so they show on top of a pencil drawing.
    var tinted = false
}

/// Everything that the tone maps need, so they can be made again when the controls change.
struct Analysis {
    let gray: GrayImage
    let mask: [Bool]
    let soft: [Float]
    let medium: [Float]
    /// Pixels of the face that set the value steps.
    let faceArea: [Int]
    /// Tones inside the face, sorted.
    let faceTones: [Float]
    /// Eye centers in pixels, top-left origin, the left one in the image first.
    let eyes: (CGPoint, CGPoint)?

    var width: Int { gray.width }
    var height: Int { gray.height }

    func percentile(_ p: Float) -> Float {
        faceTones[Int(Float(faceTones.count - 1) * min(max(p, 0), 1))]
    }
}

struct ToneMaps {
    let images: [Stage: CGImage]
    /// The value step of each pixel. Step 0 is the lightest.
    let steps: [Int]
    /// The gray of each step, lightest first.
    let tones: [Float]
    /// The tone where each step after the first starts, from light to dark.
    let thresholds: [Float]

    var count: Int { tones.count }

    /// The value step of a tone, with the same thresholds as the map.
    func step(of tone: Float) -> Int { thresholds.filter { tone < $0 }.count }
}

/// The form of the head and the maps made from it. Nil when the depth model is not available.
struct FormResult {
    let form: Form
    let maps: FormMaps
    let families: CGImage
    let classes: CGImage
    let planes: CGImage
}

struct Lesson {
    let analysis: Analysis
    let photo: CGImage
    let lines: [Stage: [Layer]]
    let edges: CGImage
    let form: FormResult?
    var tones: ToneMaps
    let faceFound: Bool
    let measurements: [Measurement]
    /// Units for the measure tool, in pixels: the mean eye width and the head height.
    let eyeWidth: CGFloat
    let headHeight: CGFloat
    let geometry: LessonBuilder.FaceGeometry?
    /// The head outline, Core Graphics coordinates.
    let outline: [CGPoint]

    var gray: GrayImage { analysis.gray }

    func layers(for stage: Stage) -> [Layer] {
        if stage.isLines { return lines[stage] ?? [] }
        switch stage {
        case .planes:
            guard let form else { return lines[.blockIn] ?? [] }
            return [Layer(image: form.planes)] + (lines[.blockIn]?.suffix(1).map { Layer(image: $0.image, opacity: 0.5) } ?? [])
        case .shadows: return [Layer(image: form?.families ?? tones.images[.shadows]!)]
        case .form: return [Layer(image: form?.classes ?? tones.images[.shadows]!)]
        case .edges: return [Layer(image: edges)]
        case .details, .check: return [Layer(image: photo)]
        default: return [Layer(image: tones.images[stage]!)]
        }
    }

    /// The colors that a stage uses, with their names, for the legend below the picture.
    func legend(for stage: Stage) -> [(color: (Float, Float, Float), name: String)] {
        switch stage {
        case .shadows where form != nil:
            return LessonBuilder.familyColors
        case .form where form != nil:
            return FormClass.allCases.filter { $0 != .background }.map { ($0.color, $0.name) }
        case .values:
            return tones.tones.enumerated().map { (($0.element, $0.element, $0.element), "\($0.offset + 1)") }
        default:
            return []
        }
    }
}

enum LessonBuilder {
    static let maxSide = 1000

    static let familyColors: [(color: (Float, Float, Float), name: String)] = [
        ((1, 1, 1), "Light family"),
        ((0.86, 0.8, 0.7), "Dark local value in the light"),
        ((0.55, 0.55, 0.57), "Shadow family"),
    ]

    /// Grays for a value scale, lightest first, at even steps of perceived lightness (CIE L*).
    static func valueTones(count: Int) -> [Float] {
        (0..<count).map { i in
            let l = 96 - (96 - 14) * Double(i) / Double(max(count - 1, 1))
            let y = l > 8 ? pow((l + 16) / 116, 3) : l / 903.3
            let srgb = y <= 0.0031308 ? 12.92 * y : 1.055 * pow(y, 1 / 2.4) - 0.055
            return Float(srgb)
        }
    }

    static func loadImage(at url: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3000,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// The head crop and what Vision finds in it.
    struct Prepared {
        let base: CGImage
        let gray: GrayImage
        let mask: [Bool]
        let face: VNFaceObservation?
        let geometry: FaceGeometry?
    }

    static func prepare(_ source: CGImage) -> Prepared {
        let base = scaled(source.cropping(to: headCrop(in: source)) ?? source, maxSide: maxSide)
        let face = faceLandmarks(base)
        return Prepared(
            base: base, gray: grayscale(base), mask: personMask(base), face: face,
            geometry: face.flatMap { FaceGeometry($0, size: CGSize(width: base.width, height: base.height)) }
        )
    }

    static func build(from source: CGImage, valueCount: Int = 5) -> Lesson {
        let prepared = prepare(source)
        let base = prepared.base, gray = prepared.gray, mask = prepared.mask
        let face = prepared.face, geometry = prepared.geometry
        let w = base.width, h = base.height

        // Take the value steps from the face only. Dark hair and clothes then go to the
        // darkest steps, and the light and shadow sides of the face separate.
        var toneArea = gray.pixels.indices.filter { mask[$0] }
        if let box = face?.boundingBox {
            let x0 = Int(box.minX * CGFloat(w)), x1 = Int(box.maxX * CGFloat(w))
            let y0 = Int((1 - box.maxY) * CGFloat(h)), y1 = Int((1 - box.minY) * CGFloat(h))
            toneArea = toneArea.filter { (x0..<x1).contains($0 % w) && (y0..<y1).contains($0 / w) }
        }
        let medium = boxBlur(gray.pixels, w, h, radius: max(1, w / 150))
        let analysis = Analysis(
            gray: gray,
            mask: mask,
            soft: boxBlur(gray.pixels, w, h, radius: max(2, w / 60)),
            medium: medium,
            faceArea: toneArea,
            faceTones: toneArea.map { gray.pixels[$0] }.sorted(),
            eyes: geometry.map { g in
                let a = CGPoint(x: g.leftEye.x, y: CGFloat(h) - g.leftEye.y)
                let b = CGPoint(x: g.rightEye.x, y: CGFloat(h) - g.rightEye.y)
                return a.x < b.x ? (a, b) : (b, a)
            }
        )

        let photo = rgbaImage(w, h) { i in (gray.pixels[i], gray.pixels[i], gray.pixels[i]) }
        let outline = headOutline(width: w, height: h, mask: mask, face: face)
        let proportions = drawLines(w, h) { ctx in drawProportions(ctx, outline: outline, geometry: geometry) }
        let blockIn = drawLines(w, h) { ctx in drawBlockIn(ctx, outline: outline) }
        let features = drawLines(w, h) { ctx in drawFeatures(ctx, face: face, geometry: geometry) }
        let form = formResult(prepared, medium: medium, outline: outline)
        let measurements = geometry.map { Measurements.measure($0, outline: outline, height: h) } ?? []
        let eyeWidth = geometry.map { g in
            [g.leftEyeOutline, g.rightEyeOutline].map { pts in
                let a = pts.map { dot($0, g.across) }
                return (a.max() ?? 0) - (a.min() ?? 0)
            }.reduce(0, +) / 2
        } ?? CGFloat(w) / 10
        let headHeight = geometry.map { g in (outline.map(g.height).max() ?? 0) - g.height(g.chin) } ?? CGFloat(h) * 0.8

        return Lesson(
            analysis: analysis,
            photo: photo,
            lines: [
                .proportions: [Layer(image: proportions)],
                .blockIn: [Layer(image: proportions, opacity: 0.3), Layer(image: blockIn)],
                .features: [Layer(image: blockIn, opacity: 0.4), Layer(image: features)],
            ],
            edges: edgeMap(analysis, skin: form?.form.skin),
            form: form,
            tones: toneMaps(analysis, balance: 0, count: valueCount, form: form?.maps),
            faceFound: face != nil,
            measurements: measurements,
            eyeWidth: eyeWidth,
            headHeight: headHeight,
            geometry: geometry,
            outline: outline
        )
    }

    static func formResult(_ p: Prepared, medium: [Float], outline: [CGPoint]) -> FormResult? {
        guard let form = FormAnalyzer.analyze(p.base, gray: p.gray, mask: p.mask, geometry: p.geometry) else { return nil }
        let w = form.width, h = form.height
        let maps = FormAnalyzer.classify(form, tones: medium, gray: p.gray.pixels, mask: p.mask)
        let families = rgbaImage(w, h) { i in
            let c = maps.classes[i]
            if c == .background { return (1, 1, 1) }
            if c.isShadowFamily { return familyColors[2].color }
            return c == .localDark ? familyColors[1].color : familyColors[0].color
        }
        let classes = rgbaImage(w, h) { maps.classes[$0].color }

        // Planes: each plane flat, with the gray that the fitted light gives it, and dark edges between planes.
        // The planes are for the head and the neck only: stop a little below the chin.
        var head = p.mask
        if let g = p.geometry {
            let limit = g.height(g.chin) - ((outline.map(g.height).max() ?? 0) - g.height(g.chin)) * 0.12
            for i in head.indices where head[i] {
                let point = CGPoint(x: CGFloat(i % w), y: CGFloat(h - 1 - i / w))
                if g.height(point) < limit { head[i] = false }
            }
        }
        let (labels, normals) = FormAnalyzer.planes(form, mask: head)
        let shade = normals.map { 0.25 + 0.7 * max(0, simd_dot($0, form.light)) }
        let planes = rgbaImage(w, h) { i in
            let l = labels[i]
            guard l >= 0 else { return (1, 1, 1) }
            let x = i % w, y = i / w
            let edge = (x + 1 < w && labels[i + 1] != l) || (y + 1 < h && labels[i + w] != l)
            if edge { return (0.15, 0.15, 0.2) }
            let v = shade[l]
            return (v, v, v)
        }
        return FormResult(form: form, maps: maps, families: families, classes: classes, planes: planes)
    }

    // MARK: - Tones

    /// `balance` is from -1 (less shadow) to 1 (more shadow). `count` is the number of value steps.
    static func toneMaps(_ a: Analysis, balance: Float, count: Int, form: FormMaps?) -> ToneMaps {
        let w = a.width, h = a.height, mask = a.mask
        let shift = balance * 0.2
        // Even parts of the face for each step, moved by the shadow amount.
        let thresholds = (1..<count).map { k in a.percentile(1 - Float(k) / Float(count) + shift) }
        let steps = a.medium.indices.map { i -> Int in
            mask[i] ? thresholds.filter { a.medium[i] < $0 }.count : 0
        }
        // Each step shows the median tone of the photo in that step, so that the map, the photo and
        // the drawing check agree. A step with no pixels takes the gray of an even value scale.
        var groups = [[Float]](repeating: [], count: count)
        for i in a.faceArea { groups[steps[i]].append(a.medium[i]) }
        let even = valueTones(count: count)
        let tones = groups.indices.map { k -> Float in
            let g = groups[k].sorted()
            return g.isEmpty ? even[k] : g[g.count / 2]
        }
        let brightest = a.percentile(0.92 + shift * 0.25)
        func isHighlight(_ i: Int) -> Bool {
            if let form { return form.classes[i] == .highlight }
            return mask[i] && a.medium[i] >= brightest
        }
        func faded(_ i: Int) -> Float { 1 - (1 - tones[steps[i]]) * 0.2 }

        let baseTone = rgbaImage(w, h) { i in
            let v: Float = mask[i] && !isHighlight(i) ? tones[min(1, count - 1)] : 1
            return (v, v, v)
        }
        let split = a.percentile(0.5 + shift)
        let shadows = rgbaImage(w, h) { i in
            let v: Float = mask[i] && a.soft[i] < split ? 0.55 : 1
            return (v, v, v)
        }
        let values = rgbaImage(w, h) { i in
            let v = tones[steps[i]]
            return (v, v, v)
        }
        let darks = rgbaImage(w, h) { i in
            let v: Float = steps[i] == count - 1 ? 0.08 : faded(i)
            return (v, v, v)
        }
        let highlights = rgbaImage(w, h) { i in
            if isHighlight(i) { return (1, 0.82, 0.3) }
            let v = faded(i)
            return (v, v, v)
        }
        return ToneMaps(
            images: [.baseTone: baseTone, .shadows: shadows, .values: values, .darks: darks, .highlights: highlights],
            steps: steps, tones: tones, thresholds: thresholds
        )
    }

    /// Strong changes of tone are hard edges. Sobel filter on the medium blur.
    /// The limits come from the skin when it is known, so that hair texture and clothes do not set them.
    static func edgeMap(_ a: Analysis, skin: [Bool]?) -> CGImage {
        let w = a.width, h = a.height, m = a.medium
        var strength = [Float](repeating: 0, count: w * h)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let gx = m[i - w + 1] + 2 * m[i + 1] + m[i + w + 1] - m[i - w - 1] - 2 * m[i - 1] - m[i + w - 1]
                let gy = m[i + w - 1] + 2 * m[i + w] + m[i + w + 1] - m[i - w - 1] - 2 * m[i - w] - m[i - w + 1]
                strength[i] = a.mask[i] ? (gx * gx + gy * gy).squareRoot() : 0
            }
        }
        func limits(_ area: [Int]) -> (hard: Float, soft: Float) {
            let sorted = area.map { strength[$0] }.sorted()
            guard !sorted.isEmpty else { return (1, 1) }
            return (sorted[Int(Float(sorted.count - 1) * 0.94)], sorted[Int(Float(sorted.count - 1) * 0.85)])
        }
        let head = limits(strength.indices.filter { a.mask[$0] })
        var inFace = skin ?? [Bool](repeating: false, count: w * h)
        if skin == nil { for i in a.faceArea { inFace[i] = true } }
        let face = limits(strength.indices.filter { inFace[$0] })
        return rgbaImage(w, h) { i in
            let l = inFace[i] ? face : head
            let v: Float = strength[i] >= l.hard ? 0.15 : strength[i] >= l.soft ? 0.65 : 1 - (1 - a.gray.pixels[i]) * 0.15
            return (v, v, v)
        }
    }

    // MARK: - Vision

    /// Crop around the largest face, with room for the hair and the neck. Top-left origin.
    static func headCrop(in image: CGImage) -> CGRect {
        let full = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let request = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let box = request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width })?.boundingBox
        else { return full }
        let fw = box.width * full.width, fh = box.height * full.height
        let cx = box.midX * full.width
        let cy = (1 - box.midY) * full.height - fh * 0.15
        let crop = CGRect(x: cx - fw, y: cy - fh * 1.3, width: fw * 2, height: fh * 2.6)
        return crop.intersection(full).integral
    }

    /// True where the person is. Row 0 is the top row.
    static func personMask(_ image: CGImage) -> [Bool] {
        let w = image.width, h = image.height
        let all = [Bool](repeating: true, count: w * h)
        let request = VNGeneratePersonSegmentationRequest()
        request.qualityLevel = .accurate
        request.outputPixelFormat = kCVPixelFormatType_OneComponent8
        try? VNImageRequestHandler(cgImage: image).perform([request])
        guard let buffer = request.results?.first?.pixelBuffer else { return all }

        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let mw = CVPixelBufferGetWidth(buffer), mh = CVPixelBufferGetHeight(buffer)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
        let bytes = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        var mask = all
        for y in 0..<h {
            let my = y * mh / h
            for x in 0..<w {
                mask[y * w + x] = bytes[my * rowBytes + x * mw / w] > 127
            }
        }
        // A mask that covers almost nothing is a failed segmentation.
        return mask.filter { $0 }.count > w * h / 20 ? mask : all
    }

    static func faceLandmarks(_ image: CGImage) -> VNFaceObservation? {
        let request = VNDetectFaceLandmarksRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return request.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width })
    }

    // MARK: - Lines

    /// Points of the face in Core Graphics coordinates (bottom-left origin), the same as Vision's points.
    struct FaceGeometry {
        let leftEye, rightEye, eyes, brow, noseBase, mouth, chin: CGPoint
        /// Unit vectors: across the face (parallel to the eyes) and up the face.
        let across, up: CGPoint
        let halfWidth: CGFloat
        let jaw: [CGPoint]
        let nose, lips: [CGPoint]
        let leftEyeOutline, rightEyeOutline, leftBrowOutline, rightBrowOutline: [CGPoint]

        init?(_ face: VNFaceObservation, size: CGSize) {
            guard let marks = face.landmarks else { return nil }
            func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] { region?.pointsInImage(imageSize: size) ?? [] }
            let jaw = points(marks.faceContour), nose = points(marks.nose)
            guard !jaw.isEmpty, !nose.isEmpty else { return nil }
            leftEye = centroid(points(marks.leftEye))
            rightEye = centroid(points(marks.rightEye))
            brow = centroid(points(marks.leftEyebrow) + points(marks.rightEyebrow))
            mouth = centroid(points(marks.outerLips))
            eyes = CGPoint(x: (leftEye.x + rightEye.x) / 2, y: (leftEye.y + rightEye.y) / 2)
            across = normalized(CGPoint(x: rightEye.x - leftEye.x, y: rightEye.y - leftEye.y))
            var up = CGPoint(x: -across.y, y: across.x)
            if dot(up, CGPoint(x: brow.x - mouth.x, y: brow.y - mouth.y)) < 0 { up = CGPoint(x: -up.x, y: -up.y) }
            self.up = up
            noseBase = nose.min(by: { dot($0, up) < dot($1, up) })!
            chin = jaw.min(by: { dot($0, up) < dot($1, up) })!
            halfWidth = face.boundingBox.width * size.width * 0.7
            self.jaw = jaw
            self.nose = nose
            lips = points(marks.outerLips)
            leftEyeOutline = points(marks.leftEye)
            rightEyeOutline = points(marks.rightEye)
            leftBrowOutline = points(marks.leftEyebrow)
            rightBrowOutline = points(marks.rightEyebrow)
        }

        /// Distance from the eye midpoint along the face axis.
        func height(_ p: CGPoint) -> CGFloat { dot(CGPoint(x: p.x - eyes.x, y: p.y - eyes.y), up) }
        /// The point on the face axis at a height.
        func axis(_ d: CGFloat) -> CGPoint { CGPoint(x: eyes.x + up.x * d, y: eyes.y + up.y * d) }

        /// A line across the face, centered on the face axis.
        func level(_ p: CGPoint, halfLength: CGFloat? = nil) -> [CGPoint] {
            let c = axis(height(p)), l = halfLength ?? halfWidth
            return [CGPoint(x: c.x - across.x * l, y: c.y - across.y * l), CGPoint(x: c.x + across.x * l, y: c.y + across.y * l)]
        }
    }

    /// Head outline: rays from the face center to the edge of the person mask.
    static func headOutline(width w: Int, height h: Int, mask: [Bool], face: VNFaceObservation?) -> [CGPoint] {
        let center = face.map { CGPoint(x: $0.boundingBox.midX * CGFloat(w), y: $0.boundingBox.midY * CGFloat(h)) }
            ?? CGPoint(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
        var outline: [CGPoint] = []
        for step in 0..<90 {
            let angle = Double(step) / 90 * 2 * .pi
            var last = center
            var r: CGFloat = 0
            while true {
                let p = CGPoint(x: center.x + r * cos(angle), y: center.y + r * sin(angle))
                let x = Int(p.x), y = h - 1 - Int(p.y)
                guard x >= 0, x < w, y >= 0, y < h else { break }
                if mask[y * w + x] { last = p }
                r += 1
            }
            outline.append(last)
        }
        return outline
    }

    static func drawLines(_ w: Int, _ h: Int, _ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        draw(ctx)
        return ctx.makeImage()!
    }

    static func unit(_ ctx: CGContext) -> CGFloat { CGFloat(ctx.width) / 400 }

    static func setGuideStyle(_ ctx: CGContext) {
        ctx.setStrokeColor(red: 0.2, green: 0.45, blue: 0.9, alpha: 0.75)
        ctx.setLineWidth(1.2 * unit(ctx))
        ctx.setLineDash(phase: 0, lengths: [6 * unit(ctx), 4 * unit(ctx)])
    }

    /// Skull circle, jaw, face axis and the brow, nose base and chin lines.
    static func drawProportions(_ ctx: CGContext, outline: [CGPoint], geometry g: FaceGeometry?) {
        ctx.setStrokeColor(gray: 0.3, alpha: 1)
        ctx.setLineWidth(1.6 * unit(ctx))
        guard let g else {
            // Without a face, the bounding box of the head is the only proportion.
            let xs = outline.map(\.x), ys = outline.map(\.y)
            ctx.stroke(CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!))
            return
        }
        let top = outline.map(g.height).max() ?? g.height(g.brow) * 3
        let brow = g.height(g.brow)
        let center = g.axis(brow + (top - brow) * 0.35)
        let radius = top - g.height(center)
        ctx.strokeEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        stroke(ctx, simplify(g.jaw, epsilon: CGFloat(ctx.width) * 0.03), closed: false)

        setGuideStyle(ctx)
        for p in [g.brow, g.noseBase, g.chin] {
            stroke(ctx, g.level(p, halfLength: radius * 1.15), closed: false)
        }
        stroke(ctx, [g.axis(top + radius * 0.1), g.axis(g.height(g.chin) - radius * 0.15)], closed: false)
    }

    static func drawBlockIn(_ ctx: CGContext, outline: [CGPoint]) {
        ctx.setStrokeColor(gray: 0.3, alpha: 1)
        ctx.setLineWidth(2 * unit(ctx))
        stroke(ctx, simplifyClosed(outline, epsilon: CGFloat(ctx.width) * 0.02), closed: true)
    }

    /// Features as simple straight-line shapes, with guide lines parallel to the eye line.
    static func drawFeatures(_ ctx: CGContext, face: VNFaceObservation?, geometry g: FaceGeometry?) {
        guard let face, let marks = face.landmarks, let g else { return }
        let size = CGSize(width: ctx.width, height: ctx.height)
        func points(_ region: VNFaceLandmarkRegion2D?) -> [CGPoint] { region?.pointsInImage(imageSize: size) ?? [] }
        let eps = size.width * 0.008

        ctx.setStrokeColor(gray: 0.2, alpha: 1)
        ctx.setLineWidth(1.6 * unit(ctx))
        stroke(ctx, simplify(points(marks.faceContour), epsilon: eps), closed: false)
        for region in [marks.leftEyebrow, marks.rightEyebrow, marks.nose] {
            stroke(ctx, simplify(points(region), epsilon: eps), closed: false)
        }
        for region in [marks.leftEye, marks.rightEye, marks.outerLips] {
            stroke(ctx, simplifyClosed(points(region), epsilon: eps * 0.5), closed: true)
        }

        setGuideStyle(ctx)
        for p in [g.brow, g.eyes, g.noseBase, g.mouth, g.chin] {
            stroke(ctx, g.level(p), closed: false)
        }
        stroke(ctx, [g.axis(g.height(g.brow) + g.halfWidth * 0.3), g.axis(g.height(g.chin) - g.halfWidth * 0.1)], closed: false)
    }

    static func stroke(_ ctx: CGContext, _ pts: [CGPoint], closed: Bool) {
        guard pts.count > 1 else { return }
        ctx.beginPath()
        ctx.addLines(between: pts)
        if closed { ctx.closePath() }
        ctx.strokePath()
    }

    /// Douglas-Peucker: keeps only the corners, so curves become straight lines.
    static func simplify(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard pts.count > 2, let a = pts.first, let b = pts.last else { return pts }
        var farthest = 0
        var maxDistance: CGFloat = 0
        for i in 1..<(pts.count - 1) {
            let d = distance(pts[i], toSegment: a, b)
            if d > maxDistance { maxDistance = d; farthest = i }
        }
        guard maxDistance > epsilon else { return [a, b] }
        let left = simplify(Array(pts[...farthest]), epsilon: epsilon)
        let right = simplify(Array(pts[farthest...]), epsilon: epsilon)
        return left.dropLast() + right
    }

    static func simplifyClosed(_ pts: [CGPoint], epsilon: CGFloat) -> [CGPoint] {
        guard pts.count > 3 else { return pts }
        let start = pts[0]
        let far = pts.indices.max(by: { hypot(pts[$0].x - start.x, pts[$0].y - start.y) < hypot(pts[$1].x - start.x, pts[$1].y - start.y) })!
        let first = simplify(Array(pts[...far]), epsilon: epsilon)
        let second = simplify(Array(pts[far...]) + [start], epsilon: epsilon)
        return first.dropLast() + second.dropLast()
    }

    static func distance(_ p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        guard length > 0 else { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / length))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    static func centroid(_ pts: [CGPoint]) -> CGPoint {
        guard !pts.isEmpty else { return .zero }
        let n = CGFloat(pts.count)
        return CGPoint(x: pts.map(\.x).reduce(0, +) / n, y: pts.map(\.y).reduce(0, +) / n)
    }

    static func dot(_ a: CGPoint, _ b: CGPoint) -> CGFloat { a.x * b.x + a.y * b.y }

    static func normalized(_ p: CGPoint) -> CGPoint {
        let length = hypot(p.x, p.y)
        return length > 0 ? CGPoint(x: p.x / length, y: p.y / length) : CGPoint(x: 1, y: 0)
    }

    // MARK: - Pixels

    static func scaled(_ image: CGImage, maxSide: Int) -> CGImage {
        let scale = min(1, CGFloat(maxSide) / CGFloat(max(image.width, image.height)))
        let w = Int(CGFloat(image.width) * scale), h = Int(CGFloat(image.height) * scale)
        let ctx = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()!
    }

    static func grayscale(_ image: CGImage) -> GrayImage {
        let w = image.width, h = image.height
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return GrayImage(width: w, height: h, pixels: bytes.map { Float($0) / 255 })
    }

    static func rgbaImage(_ w: Int, _ h: Int, _ color: (Int) -> (Float, Float, Float)) -> CGImage {
        var data = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            let (r, g, b) = color(i)
            data[i * 4] = UInt8(max(0, min(255, r * 255)))
            data[i * 4 + 1] = UInt8(max(0, min(255, g * 255)))
            data[i * 4 + 2] = UInt8(max(0, min(255, b * 255)))
        }
        return data.withUnsafeMutableBytes { buffer in
            CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!.makeImage()!
        }
    }

    /// Three passes of a box blur, which is close to a Gaussian blur.
    static func boxBlur(_ src: [Float], _ w: Int, _ h: Int, radius r: Int) -> [Float] {
        var a = src
        var b = [Float](repeating: 0, count: src.count)
        let n = Float(2 * r + 1)
        for _ in 0..<3 {
            for y in 0..<h {
                let row = y * w
                var sum: Float = 0
                for x in -r...r { sum += a[row + min(max(x, 0), w - 1)] }
                for x in 0..<w {
                    b[row + x] = sum / n
                    sum += a[row + min(x + r + 1, w - 1)] - a[row + max(x - r, 0)]
                }
            }
            for x in 0..<w {
                var sum: Float = 0
                for y in -r...r { sum += b[min(max(y, 0), h - 1) * w + x] }
                for y in 0..<h {
                    a[y * w + x] = sum / n
                    sum += b[min(y + r + 1, h - 1) * w + x] - b[max(y - r, 0) * w + x]
                }
            }
        }
        return a
    }
}
