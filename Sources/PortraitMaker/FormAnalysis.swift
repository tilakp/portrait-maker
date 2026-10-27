import Accelerate
import CoreGraphics
import CoreML
import Foundation
import Vision

/// The 3D form of the head, from a depth model, and the light that falls on it.
/// Directions use x to the right, y up and z toward the viewer.
struct Form {
    let width: Int
    let height: Int
    /// Unit surface normal for each pixel.
    let normals: [SIMD3<Float>]
    /// Unit vector toward the light.
    let light: SIMD3<Float>
    /// normal · light for each pixel: above 0 faces the light, below 0 turns away from it.
    let shading: [Float]
    /// Brightness of the skin that the light model predicts for each pixel.
    let predicted: [Float]
    /// Skin of the face, without the eyes, brows and lips.
    let skin: [Bool]

    /// Where the light comes from, in words an artist uses.
    var lightDescription: String {
        let side = abs(light.x) < 0.17 ? "the front" : light.x < 0 ? "the left" : "the right"
        let height = light.y > 0.25 ? "above" : light.y < -0.25 ? "below" : "eye level"
        // Angle between the light and the line from the face to the viewer.
        let angle = Int((acos(max(-1, min(1, light.z))) * 180 / .pi).rounded())
        switch (side, height) {
        case ("the front", "eye level"): return "The light comes from the front."
        case ("the front", _): return "The light comes from \(height), \(angle)° from the front."
        case (_, "eye level"): return "The light comes from \(side), \(angle)° from the front."
        default: return "The light comes from \(height) and \(side), \(angle)° from the front."
        }
    }
}

enum FormAnalyzer {
    static let inputWidth = 518, inputHeight = 392

    static let model: MLModel? = {
        let url = Bundle.main.url(forResource: "DepthAnything", withExtension: "mlmodelc")
            ?? URL(fileURLWithPath: "Models/DepthAnything.mlmodelc")
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let configuration = MLModelConfiguration()
        // Not the Neural Engine: Core ML prepares this model for it again after each new build of the
        // app, and that took 280 s on an M-series Mac. On the GPU the first run takes about 10 s.
        configuration.computeUnits = .cpuAndGPU
        return try? MLModel(contentsOf: url, configuration: configuration)
    }()

    /// Runs the model once on a blank image, so that the first portrait does not wait for Core ML.
    static func warmUp() {
        let ctx = CGContext(
            data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        _ = ctx.makeImage().flatMap(nearness)
    }

    static func analyze(
        _ image: CGImage, gray: GrayImage, mask: [Bool], geometry g: LessonBuilder.FaceGeometry?
    ) -> Form? {
        let w = image.width, h = image.height
        guard let near = nearness(image) else { return nil }
        let smooth = LessonBuilder.boxBlur(near, w, h, radius: max(2, w / 120))

        // The model gives relative nearness only. Scale it so that the nose tip is in front of
        // the cheek outline by half the face width, which is the usual depth of a head.
        var scale: Float = 1
        if let g {
            func at(_ p: CGPoint) -> Float {
                smooth[min(max(h - 1 - Int(p.y), 0), h - 1) * w + min(max(Int(p.x), 0), w - 1)]
            }
            let cheeks = Array(g.jaw.prefix(3)) + Array(g.jaw.suffix(3))
            let nose = g.nose.map(at).max() ?? 0
            let depth = nose - cheeks.map(at).reduce(0, +) / Float(cheeks.count)
            let faceWidth = Float(hypot(g.jaw.first!.x - g.jaw.last!.x, g.jaw.first!.y - g.jaw.last!.y))
            if depth > 0 { scale = 0.5 * faceWidth / depth }
        } else {
            let inside = smooth.indices.filter { mask[$0] }.map { smooth[$0] }.sorted()
            if let low = inside.first, let high = inside.last, high > low { scale = 0.2 * Float(w) / (high - low) }
        }

        var normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: w * h)
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let i = y * w + x
                let dx = (smooth[i + 1] - smooth[i - 1]) * 0.5 * scale
                let dyDown = (smooth[i + w] - smooth[i - w]) * 0.5 * scale
                normals[i] = simd_normalize(SIMD3(-dx, dyDown, 1))
            }
        }

        let skin = skinMask(width: w, height: h, mask: mask, geometry: g)
        let tones = LessonBuilder.boxBlur(gray.pixels, w, h, radius: max(1, w / 150))
        guard let fit = fitLight(normals: normals, tones: tones, skin: skin) else { return nil }
        let shading = normals.map { simd_dot($0, fit.light) }
        let predicted = shading.map { fit.ambient + fit.albedo * max(0, $0) }
        return Form(width: w, height: h, normals: normals, light: fit.light, shading: shading, predicted: predicted, skin: skin)
    }

    /// Lambertian fit on the skin: brightness = ambient + albedo × max(0, normal · light).
    /// Pixels that face the light but are much darker than the fit (a beard, a cast shadow)
    /// and pixels that turn away from the light do not follow the linear model, so the fit
    /// runs again without them.
    static func fitLight(normals: [SIMD3<Float>], tones: [Float], skin: [Bool]) -> (light: SIMD3<Float>, ambient: Float, albedo: Float)? {
        var samples = stride(from: 0, to: normals.count, by: 3).filter { skin[$0] }
        guard samples.count > 300 else { return nil }
        var result: (light: SIMD3<Float>, ambient: Float, albedo: Float)?
        for _ in 0..<4 {
            let rows = samples.map { i -> [Double] in
                let n = normals[i]
                return [1, Double(n.x), Double(n.y), Double(n.z)]
            }
            guard samples.count > 100,
                  let c = LinearAlgebra.leastSquares(rows, samples.map { Double(tones[$0]) })
            else { break }
            let vector = SIMD3(Float(c[1]), Float(c[2]), Float(c[3]))
            let albedo = simd_length(vector)
            guard albedo > 1e-4 else { break }
            let light = vector / albedo
            result = (light, Float(c[0]), albedo)

            let residuals = samples.map { tones[$0] - (Float(c[0]) + simd_dot(normals[$0], vector)) }
            let sigma = (residuals.map { $0 * $0 }.reduce(0, +) / Float(residuals.count)).squareRoot()
            samples = zip(samples, residuals)
                .filter { simd_dot(normals[$0.0], light) > 0.05 && $0.1 > -1.5 * sigma }
                .map(\.0)
        }
        return result
    }

    /// The face from the jaw to a line above the brows, without the eyes, brows and lips.
    static func skinMask(width w: Int, height h: Int, mask: [Bool], geometry g: LessonBuilder.FaceGeometry?) -> [Bool] {
        guard let g else { return mask }
        var bytes = [UInt8](repeating: 0, count: w * h)
        bytes.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
            )!
            // Forehead: the brows moved up by a third of the brow to chin distance.
            let lift = (g.height(g.brow) - g.height(g.chin)) * 0.35
            let up = CGPoint(x: g.up.x * lift, y: g.up.y * lift)
            var outline = g.jaw
            let first = g.jaw.first!, last = g.jaw.last!
            outline.append(CGPoint(x: last.x + up.x, y: last.y + up.y))
            outline.append(CGPoint(x: first.x + up.x, y: first.y + up.y))
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.addLines(between: outline)
            ctx.closePath()
            ctx.fillPath()

            ctx.setFillColor(gray: 0, alpha: 1)
            ctx.setStrokeColor(gray: 0, alpha: 1)
            ctx.setLineWidth(CGFloat(w) * 0.02)
            ctx.setLineJoin(.round)
            for region in [g.leftEyeOutline, g.rightEyeOutline, g.leftBrowOutline, g.rightBrowOutline, g.lips] where region.count > 2 {
                ctx.addLines(between: region)
                ctx.closePath()
                ctx.drawPath(using: .fillStroke)
            }
        }
        return bytes.indices.map { bytes[$0] > 127 && mask[$0] }
    }

    /// Relative nearness for each pixel of the image (larger is nearer). The image is fitted
    /// into the model's fixed input with gray bars, and the result is scaled back.
    static func nearness(_ image: CGImage) -> [Float]? {
        guard let model else { return nil }
        let w = image.width, h = image.height
        let scale = min(Double(inputWidth) / Double(w), Double(inputHeight) / Double(h))
        let cw = Int(Double(w) * scale), ch = Int(Double(h) * scale)
        let ox = (inputWidth - cw) / 2, oy = (inputHeight - ch) / 2

        let ctx = CGContext(
            data: nil, width: inputWidth, height: inputHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: inputWidth, height: inputHeight))
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: ox, y: inputHeight - oy - ch, width: cw, height: ch))
        guard let input = ctx.makeImage(),
              let feature = try? MLFeatureValue(
                  cgImage: input, pixelsWide: inputWidth, pixelsHigh: inputHeight,
                  pixelFormatType: kCVPixelFormatType_32BGRA, options: nil),
              let output = try? model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["image": feature])),
              let buffer = output.featureValue(for: "depth")?.imageBufferValue
        else { return nil }

        // Half floats to floats with Accelerate, so that the code also builds for Intel Macs.
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let bw = CVPixelBufferGetWidth(buffer), bh = CVPixelBufferGetHeight(buffer)
        var values = [Float](repeating: 0, count: bw * bh)
        values.withUnsafeMutableBytes { out in
            var source = vImage_Buffer(
                data: CVPixelBufferGetBaseAddress(buffer), height: vImagePixelCount(bh), width: vImagePixelCount(bw),
                rowBytes: CVPixelBufferGetBytesPerRow(buffer))
            var target = vImage_Buffer(
                data: out.baseAddress, height: vImagePixelCount(bh), width: vImagePixelCount(bw), rowBytes: bw * 4)
            vImageConvert_Planar16FtoPlanarF(&source, &target, 0)
        }

        // Bilinear scale from the content area of the output back to the image.
        var result = [Float](repeating: 0, count: w * h)
        let sx = Double(cw) / Double(w) * Double(bw) / Double(inputWidth)
        let sy = Double(ch) / Double(h) * Double(bh) / Double(inputHeight)
        let x0 = Double(ox) * Double(bw) / Double(inputWidth), y0 = Double(oy) * Double(bh) / Double(inputHeight)
        for y in 0..<h {
            let fy = min(max(y0 + (Double(y) + 0.5) * sy - 0.5, 0), Double(bh - 1))
            let iy = min(Int(fy), bh - 2), ty = Float(fy - Double(iy))
            for x in 0..<w {
                let fx = min(max(x0 + (Double(x) + 0.5) * sx - 0.5, 0), Double(bw - 1))
                let ix = min(Int(fx), bw - 2), tx = Float(fx - Double(ix))
                let a = values[iy * bw + ix], b = values[iy * bw + ix + 1]
                let c = values[(iy + 1) * bw + ix], d = values[(iy + 1) * bw + ix + 1]
                result[y * w + x] = (a * (1 - tx) + b * tx) * (1 - ty) + (c * (1 - tx) + d * tx) * ty
            }
        }
        return result
    }
}
