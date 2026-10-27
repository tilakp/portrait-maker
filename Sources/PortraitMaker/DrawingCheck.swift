import CoreGraphics
import CoreImage
import Foundation
import Vision

/// Paper sizes in millimeters, short side first.
enum PaperSize: String, CaseIterable, Identifiable {
    case a4 = "A4", a3 = "A3", letter = "Letter", nineByTwelve = "9 × 12 in", elevenByFourteen = "11 × 14 in"
    case unknown = "Other size"

    var id: String { rawValue }

    var millimeters: (short: Double, long: Double)? {
        switch self {
        case .a4: (210, 297)
        case .a3: (297, 420)
        case .letter: (215.9, 279.4)
        case .nineByTwelve: (228.6, 304.8)
        case .elevenByFourteen: (279.4, 355.6)
        case .unknown: nil
        }
    }
}

/// The photo of the drawing after the paper is made flat.
struct Paper {
    let image: CGImage
    /// Millimeters for each pixel of `image`. Nil when the paper or its size is not known.
    let millimetersPerPixel: Double?
    let found: Bool

    /// Finds the paper with Vision and removes the perspective, so that the paper is a rectangle.
    /// With a known paper size, the rectangle gets the paper's proportions and a scale in millimeters.
    static func flatten(_ photo: CGImage, size: PaperSize) -> Paper {
        let request = VNDetectDocumentSegmentationRequest()
        try? VNImageRequestHandler(cgImage: photo).perform([request])
        let w = CGFloat(photo.width), h = CGFloat(photo.height)
        guard let page = request.results?.first, page.confidence > 0.5,
              page.boundingBox.width * page.boundingBox.height > 0.2
        else { return Paper(image: whitened(photo, paperFound: false), millimetersPerPixel: nil, found: false) }

        func point(_ p: CGPoint) -> CIVector { CIVector(x: p.x * w, y: p.y * h) }
        let filter = CIFilter(name: "CIPerspectiveCorrection")!
        filter.setValue(CIImage(cgImage: photo), forKey: kCIInputImageKey)
        filter.setValue(point(page.topLeft), forKey: "inputTopLeft")
        filter.setValue(point(page.topRight), forKey: "inputTopRight")
        filter.setValue(point(page.bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(point(page.bottomRight), forKey: "inputBottomRight")
        let context = CIContext()
        guard let output = filter.outputImage,
              let flat = context.createCGImage(output, from: output.extent)
        else { return Paper(image: whitened(photo, paperFound: false), millimetersPerPixel: nil, found: false) }

        guard let mm = size.millimeters else { return Paper(image: whitened(flat, paperFound: true), millimetersPerPixel: nil, found: true) }
        // The corrected photo has the proportions of the photo, not of the paper. Give it the paper's.
        let landscape = flat.width > flat.height
        let long = max(flat.width, flat.height)
        let short = Int((Double(long) * mm.short / mm.long).rounded())
        let (tw, th) = landscape ? (long, short) : (short, long)
        let ctx = CGContext(
            data: nil, width: tw, height: th, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.interpolationQuality = .high
        ctx.draw(flat, in: CGRect(x: 0, y: 0, width: tw, height: th))
        let white = whitened(ctx.makeImage()!, paperFound: true)
        // Whitening can make the image smaller, so take the scale from the final image.
        return Paper(image: white, millimetersPerPixel: mm.long / Double(max(white.width, white.height)), found: true)
    }

    /// Makes the paper white, so that uneven light on the paper does not change the values.
    /// When the paper was found, its light comes from a band along the edges of the paper, where
    /// people rarely draw. A drawing with a dark background then does not count as paper.
    /// Without the paper, one value (the bright end of the photo) is used for all of it.
    static func whitened(_ image: CGImage, paperFound: Bool) -> CGImage {
        let gray = LessonBuilder.grayscale(LessonBuilder.scaled(image, maxSide: 2000))
        let w = gray.width, h = gray.height, raw = gray.pixels
        let band = 0.06
        var light: [Float]
        if paperFound {
            let samples = stride(from: 0, to: w * h, by: 5).filter { i in
                let x = Double(i % w) / Double(w), y = Double(i / w) / Double(h)
                return x < band || x > 1 - band || y < band || y > 1 - band
            }
            light = DrawingCheck.paperLight(raw, w, h, samples: samples)
        } else {
            let sorted = raw.sorted()
            light = [Float](repeating: sorted[Int(Float(sorted.count - 1) * 0.97)], count: raw.count)
        }
        let flat = raw.indices.map { min(raw[$0] / max(light[$0], 0.05), 1) }
        return LessonBuilder.rgbaImage(w, h) { (flat[$0], flat[$0], flat[$0]) }
    }
}

/// A photo of the user's drawing, aligned to the reference by the two eyes.
struct DrawingCheck {
    /// The flat photo of the paper, for aligning by hand.
    let original: CGImage
    /// The aligned drawing at the size of the reference.
    let aligned: CGImage
    /// The aligned drawing after the paper is made white. 0 is black, 1 is white.
    let pixels: [Float]
    /// `pixels` with the same blur as the four-tone map.
    let tones: [Float]
    /// Millimeters on the paper for each pixel of the reference. Nil when the paper size is not known.
    let millimetersPerPixel: Double?

    /// Finds the eyes in the drawing with Vision. Returns nil when no face is found.
    static func autoAlign(_ paper: Paper, to analysis: Analysis) -> DrawingCheck? {
        let drawing = paper.image
        let small = LessonBuilder.scaled(drawing, maxSide: 1600)
        guard let face = LessonBuilder.faceLandmarks(small),
              let g = LessonBuilder.FaceGeometry(face, size: CGSize(width: small.width, height: small.height))
        else { return nil }
        let scale = CGFloat(drawing.width) / CGFloat(small.width)
        let h = CGFloat(small.height)
        var a = CGPoint(x: g.leftEye.x * scale, y: (h - g.leftEye.y) * scale)
        var b = CGPoint(x: g.rightEye.x * scale, y: (h - g.rightEye.y) * scale)
        if a.x > b.x { swap(&a, &b) }
        return align(paper, eyes: (a, b), to: analysis)
    }

    /// `eyes` are in pixels of the drawing, top-left origin, the left one in the image first.
    static func align(_ paper: Paper, eyes: (CGPoint, CGPoint), to analysis: Analysis) -> DrawingCheck? {
        guard let target = analysis.eyes else { return nil }
        let drawing = paper.image

        // Similarity transform (scale, rotation, move) that puts the drawing's eyes on the reference's eyes.
        let from = CGPoint(x: eyes.1.x - eyes.0.x, y: eyes.1.y - eyes.0.y)
        let to = CGPoint(x: target.1.x - target.0.x, y: target.1.y - target.0.y)
        let scale = hypot(to.x, to.y) / max(hypot(from.x, from.y), 1)
        let angle = atan2(to.y, to.x) - atan2(from.y, from.x)
        let start = CGAffineTransform(translationX: -eyes.0.x, y: -eyes.0.y)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(rotationAngle: angle))
            .concatenating(CGAffineTransform(translationX: target.0.x, y: target.0.y))

        // The eyes are a good start, but small errors in them move the full drawing.
        // Correct the alignment with the tones of the full head.
        let first = render(drawing, start, analysis)
        let transform = refine(start, tones: first.tones, analysis)
        let (pixels, tones) = transform == start ? first : render(drawing, transform, analysis)
        let aligned = LessonBuilder.rgbaImage(analysis.width, analysis.height) { i in (pixels[i], pixels[i], pixels[i]) }
        // The transform scales the drawing to the reference, so one reference pixel is 1 / scale drawing pixels.
        let scaleToReference = Double(sqrt(abs(transform.a * transform.d - transform.b * transform.c)))
        return DrawingCheck(
            original: drawing, aligned: aligned, pixels: pixels, tones: tones,
            millimetersPerPixel: paper.millimetersPerPixel.map { $0 / scaleToReference }
        )
    }

    /// Draws the photo of the drawing at the size of the reference and makes the paper white.
    static func render(_ drawing: CGImage, _ transform: CGAffineTransform, _ analysis: Analysis) -> (pixels: [Float], tones: [Float]) {
        let w = analysis.width, h = analysis.height
        func draw(background: UInt8, _ draw: (CGContext, CGRect) -> Void) -> [Float] {
            var bytes = [UInt8](repeating: background, count: w * h)
            bytes.withUnsafeMutableBytes { buffer in
                let ctx = CGContext(
                    data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                    space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
                )!
                ctx.interpolationQuality = .high
                // Work in top-left coordinates, the same as the eye points.
                ctx.translateBy(x: 0, y: CGFloat(h))
                ctx.scaleBy(x: 1, y: -1)
                ctx.concatenate(transform)
                ctx.translateBy(x: 0, y: CGFloat(drawing.height))
                ctx.scaleBy(x: 1, y: -1)
                draw(ctx, CGRect(x: 0, y: 0, width: drawing.width, height: drawing.height))
            }
            return bytes.map { Float($0) / 255 }
        }
        let raw = draw(background: 255) { ctx, rect in ctx.draw(drawing, in: rect) }
        let covered = draw(background: 0) { ctx, rect in
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(rect)
        }

        // The paper is already white (Paper.whitened). Outside the photo, use white paper.
        let flat = raw.indices.map { covered[$0] > 0.5 ? raw[$0] : 1 }
        let head = flat.indices.filter { analysis.mask[$0] }.map { flat[$0] }.sorted()
        let dark = head.isEmpty ? 0 : head[Int(Float(head.count - 1) * 0.01)]
        // Pencil cannot be as dark as a photo, so artists compress the range of values. Compare the
        // drawing in its own range: its darkest pencil in the head is the darkest tone of the photo.
        let photoHead = analysis.medium.indices.filter { analysis.mask[$0] }.map { analysis.medium[$0] }.sorted()
        let darkest = photoHead.isEmpty ? 0.1 : photoHead[Int(Float(photoHead.count - 1) * 0.01)]
        let pixels = flat.map { min(max(darkest + ($0 - dark) / max(1 - dark, 0.05) * (1 - darkest), 0), 1) }
        return (pixels, LessonBuilder.boxBlur(pixels, w, h, radius: max(1, w / 150)))
    }

    /// Tries small changes of size, rotation and position around the eye midpoint, and keeps
    /// the one where the drawing's tones follow the photo's tones best (Pearson correlation).
    /// A coarse search first, then a fine search around the best result.
    static func refine(_ transform: CGAffineTransform, tones: [Float], _ a: Analysis) -> CGAffineTransform {
        guard let eyes = a.eyes else { return transform }
        let w = a.width, h = a.height
        let step = max(1, w / 100)
        var points: [(x: Float, y: Float)] = []
        var reference: [Float] = []
        for y in stride(from: 0, to: h, by: step) {
            for x in stride(from: 0, to: w, by: step) where a.mask[y * w + x] {
                points.append((Float(x), Float(y)))
                reference.append(a.medium[y * w + x])
            }
        }
        guard points.count > 100 else { return transform }
        let n = Float(points.count)
        let refMean = reference.reduce(0, +) / n
        let refCentered = reference.map { $0 - refMean }
        let refNorm = refCentered.map { $0 * $0 }.reduce(0, +).squareRoot()
        let cx = Float(eyes.0.x + eyes.1.x) / 2, cy = Float(eyes.0.y + eyes.1.y) / 2

        func score(_ s: Float, _ angle: Float, _ dx: Float, _ dy: Float) -> Float {
            // For each reference point, the point of the current alignment that moves onto it.
            let c = cos(-angle) / s, sn = sin(-angle) / s
            var values = [Float](repeating: 1, count: points.count)
            for (i, p) in points.enumerated() {
                let qx = p.x - cx - dx, qy = p.y - cy - dy
                let x = Int(c * qx - sn * qy + cx), y = Int(sn * qx + c * qy + cy)
                if x >= 0, x < w, y >= 0, y < h { values[i] = tones[y * w + x] }
            }
            let mean = values.reduce(0, +) / n
            var dotProduct: Float = 0, norm: Float = 0
            for i in values.indices {
                let v = values[i] - mean
                dotProduct += v * refCentered[i]
                norm += v * v
            }
            return dotProduct / max(norm.squareRoot() * refNorm, 1e-6)
        }

        var best = (score: score(1, 0, 0, 0), s: Float(1), angle: Float(0), dx: Float(0), dy: Float(0))
        let degree = Float.pi / 180
        // Steps and the number of steps to each side, from coarse to fine. The coarse search
        // covers 20% in size, 4 degrees and 12% of the width in position.
        let searches: [(s: Float, sCount: Int, angle: Float, shift: Float, shiftCount: Int)] = [
            (0.05, 4, 2 * degree, Float(w) * 0.02, 6),
            (0.015, 3, 0.7 * degree, Float(w) * 0.006, 5),
            (0.005, 3, 0.25 * degree, Float(w) * 0.002, 5),
        ]
        for search in searches {
            let center = best
            for i in -search.sCount...search.sCount {
                for j in -2...2 {
                    for k in -search.shiftCount...search.shiftCount {
                        for l in -search.shiftCount...search.shiftCount {
                            let s = center.s + Float(i) * search.s, angle = center.angle + Float(j) * search.angle
                            let dx = center.dx + Float(k) * search.shift, dy = center.dy + Float(l) * search.shift
                            let value = score(s, angle, dx, dy)
                            if value > best.score { best = (value, s, angle, dx, dy) }
                        }
                    }
                }
            }
        }
        guard best.s != 1 || best.angle != 0 || best.dx != 0 || best.dy != 0 else { return transform }
        return transform
            .concatenating(CGAffineTransform(translationX: CGFloat(-cx), y: CGFloat(-cy)))
            .concatenating(CGAffineTransform(scaleX: CGFloat(best.s), y: CGFloat(best.s)))
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(best.angle)))
            .concatenating(CGAffineTransform(translationX: CGFloat(cx + best.dx), y: CGFloat(cy + best.dy)))
    }

    /// The value step of each pixel of the drawing, with the same thresholds as the photo.
    func steps(_ maps: ToneMaps) -> [Int] {
        tones.map { maps.step(of: $0) }
    }

    /// Red where the drawing is darker than the value map, blue where it is lighter.
    /// Also returns the part of the head where the values are the same, from 0 to 1.
    func difference(to lesson: Lesson) -> (image: CGImage, match: Double) {
        let a = lesson.analysis
        let drawn = steps(lesson.tones)
        // Positive where the drawing is darker: a larger step is darker.
        let steps = drawn.indices.map { i -> Float in
            a.mask[i] ? Float(drawn[i] - lesson.tones.steps[i]) : 0
        }
        // Smooth the difference, so that a small error in alignment at the edge
        // between two tones does not show as a wrong area.
        let smooth = LessonBuilder.boxBlur(steps, a.width, a.height, radius: max(2, a.width / 80))
        var same = 0, total = 0
        let image = LessonBuilder.rgbaImage(a.width, a.height) { i in
            let v = 1 - (1 - self.pixels[i]) * 0.35
            guard a.mask[i] else { return (v, v, v) }
            let d = smooth[i]
            total += 1
            if abs(d) < 0.5 { same += 1; return (v, v, v) }
            let alpha = min(abs(d), 2) * 0.35
            let color: (Float, Float, Float) = d > 0 ? (0.95, 0.25, 0.2) : (0.2, 0.45, 1)
            return (v + (color.0 - v) * alpha, v + (color.1 - v) * alpha, v + (color.2 - v) * alpha)
        }
        return (image, total > 0 ? Double(same) / Double(total) : 0)
    }

    /// The light on the paper: a smooth surface (second order in x and y) fitted to the paper samples.
    /// A second fit leaves out samples that are much darker than the first fit, such as pencil marks.
    static func paperLight(_ raw: [Float], _ w: Int, _ h: Int, samples: [Int]) -> [Float] {
        func terms(_ i: Int) -> [Double] {
            let x = Double(i % w) / Double(w), y = Double(i / w) / Double(h)
            return [1, x, y, x * x, x * y, y * y]
        }
        func fit(_ indices: [Int]) -> [Double]? {
            guard indices.count >= 200 else { return nil }
            return LinearAlgebra.leastSquares(indices.map(terms), indices.map { Double(raw[$0]) })
        }
        func value(_ c: [Double], _ i: Int) -> Float { Float(zip(c, terms(i)).map { $0 * $1 }.reduce(0, +)) }

        guard let first = fit(samples) else {
            // Not enough paper outside the person: use one value for all of the paper.
            let sorted = raw.sorted()
            return [Float](repeating: sorted[Int(Float(sorted.count - 1) * 0.97)], count: raw.count)
        }
        let clean = samples.filter { raw[$0] > value(first, $0) - 0.08 }
        let c = fit(clean) ?? first
        return raw.indices.map { value(c, $0) }
    }
}
