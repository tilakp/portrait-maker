import Foundation
import simd

/// How the light falls on each part of the head, in the terms that artists use.
enum FormClass: UInt8, CaseIterable {
    case highlight, light, halftone, core, shadow, reflected, cast, localDark, background

    var isShadowFamily: Bool { [.core, .shadow, .reflected, .cast].contains(self) }

    var name: String {
        switch self {
        case .highlight: "Highlight"
        case .light: "Light"
        case .halftone: "Halftone"
        case .core: "Core shadow"
        case .shadow: "Shadow"
        case .reflected: "Reflected light"
        case .cast: "Cast shadow"
        case .localDark: "Dark local value"
        case .background: "Background"
        }
    }

    /// Colors for the form map: grays near the real values, with a tint so that the classes can be told apart.
    var color: (Float, Float, Float) {
        switch self {
        case .highlight: (1, 0.93, 0.6)
        case .light: (0.95, 0.95, 0.95)
        case .halftone: (0.78, 0.78, 0.76)
        case .core: (0.22, 0.2, 0.24)
        case .shadow: (0.45, 0.45, 0.5)
        case .reflected: (0.58, 0.66, 0.78)
        case .cast: (0.42, 0.3, 0.52)
        case .localDark: (0.72, 0.62, 0.5)
        case .background: (1, 1, 1)
        }
    }
}

struct FormMaps {
    let classes: [FormClass]
    /// The tone between the light family and the shadow family on the skin.
    let split: Float
    /// The shading value (normal · light) at the edge between light and shadow.
    let terminator: Float
}

extension FormAnalyzer {
    /// Puts each pixel of the head into a form class. On smooth skin, where the color is the same
    /// everywhere, a dark tone means shadow. On hair, a beard, the brows and clothes, the color is
    /// not the same, so the 3D form decides if a dark area is a shadow or a dark local value.
    static func classify(_ form: Form, tones: [Float], gray: [Float], mask: [Bool]) -> FormMaps {
        let w = form.width, h = form.height, s = form.shading, skin = form.skin
        func median(_ values: [Float]) -> Float? {
            guard !values.isEmpty else { return nil }
            let sorted = values.sorted()
            return sorted[sorted.count / 2]
        }
        let skinIndices = tones.indices.filter { skin[$0] }
        let lit = median(skinIndices.filter { s[$0] > 0.3 }.map { tones[$0] })
        let dark = median(skinIndices.filter { s[$0] < -0.05 }.map { tones[$0] })
        let split: Float
        if let lit, let dark, lit - dark > 0.05 {
            split = (lit + dark) / 2
        } else {
            split = median(skinIndices.map { tones[$0] }) ?? 0.5
        }

        // The terminator in the fitted light can be a little off. Move it to where the form
        // agrees best with the light and shadow that the photo shows on the skin.
        var terminator: Float = 0
        var bestAgreement = -1
        for step in -20...40 {
            let candidate = Float(step) * 0.02
            let agreement = skinIndices.reduce(0) { $0 + ((s[$1] < candidate) == (tones[$1] < split) ? 1 : 0) }
            if agreement > bestAgreement { bestAgreement = agreement; terminator = candidate }
        }

        // Hair and beards have strong fine texture, smooth skin and cast shadows do not.
        let fine = LessonBuilder.boxBlur(gray, w, h, radius: 1)
        let texture = LessonBuilder.boxBlur(gray.indices.map { abs(gray[$0] - fine[$0]) }, w, h, radius: max(2, w / 100))
        let skinTexture = skinIndices.map { texture[$0] }.sorted()
        let textureLimit = skinTexture.isEmpty ? 1 : skinTexture[Int(Float(skinTexture.count - 1) * 0.75)] * 1.6

        let shadowTones = skinIndices.filter { s[$0] < terminator - 0.12 && tones[$0] < split }.map { tones[$0] }
        let shadowMedian = median(shadowTones) ?? split * 0.7
        let litSkin = skinIndices.filter { s[$0] > terminator }.map { tones[$0] }.sorted()
        let highlightLimit = litSkin.isEmpty ? 1 : litSkin[Int(Float(litSkin.count - 1) * 0.96)]

        // The halftone is the part of the light family that turns away from the light:
        // the first third of the shading range above the terminator.
        let halftoneLimit = terminator + (1 - terminator) / 3
        func shadowClass(_ i: Int, smoothSkin: Bool) -> FormClass {
            if s[i] >= terminator - 0.12 { return .core }
            // Reflected light only shows clearly on smooth skin.
            return smoothSkin && tones[i] > shadowMedian + 0.05 ? .reflected : .shadow
        }
        func lightClass(_ i: Int) -> FormClass {
            // A highlight is the brightest light on the skin. White clothes and hair are light local values.
            if skin[i] && tones[i] >= highlightLimit && s[i] > halftoneLimit { return .highlight }
            return s[i] < halftoneLimit ? .halftone : .light
        }
        let classes = tones.indices.map { i -> FormClass in
            guard mask[i] else { return .background }
            if skin[i] && texture[i] < textureLimit {
                if tones[i] < split {
                    return s[i] > terminator + 0.2 ? .cast : shadowClass(i, smoothSkin: true)
                }
                return lightClass(i)
            }
            if s[i] < terminator { return shadowClass(i, smoothSkin: false) }
            return tones[i] < split ? .localDark : lightClass(i)
        }
        return FormMaps(classes: classes, split: split, terminator: terminator)
    }
}

extension FormAnalyzer {
    /// Groups the head into flat planes, like a planes-of-the-head study: k-means on smoothed
    /// normals, started from fixed directions so that the result is the same each time.
    /// Returns a plane index for each pixel (-1 outside the head) and the normal of each plane.
    static func planes(_ form: Form, mask: [Bool], count: Int = 12) -> (labels: [Int], normals: [SIMD3<Float>]) {
        let w = form.width, h = form.height
        let radius = max(2, w / 50)
        let nx = LessonBuilder.boxBlur(form.normals.map(\.x), w, h, radius: radius)
        let ny = LessonBuilder.boxBlur(form.normals.map(\.y), w, h, radius: radius)
        let nz = LessonBuilder.boxBlur(form.normals.map(\.z), w, h, radius: radius)
        let smooth = (0..<(w * h)).map { simd_normalize(SIMD3(nx[$0], ny[$0], nz[$0])) }

        // Start: the front, then rings of directions around it.
        var centers: [SIMD3<Float>] = [SIMD3(0, 0, 1)]
        for ring in [(tilt: Float(0.45), n: 4), (tilt: Float(0.9), n: count - 5)] where ring.n > 0 {
            for k in 0..<ring.n {
                let a = Float(k) / Float(ring.n) * 2 * .pi + (ring.tilt > 0.5 ? .pi / 4 : 0)
                centers.append(simd_normalize(SIMD3(sin(ring.tilt) * cos(a), sin(ring.tilt) * sin(a), cos(ring.tilt))))
            }
        }
        let samples = stride(from: 0, to: w * h, by: 5).filter { mask[$0] }
        for _ in 0..<8 {
            var sums = [SIMD3<Float>](repeating: .zero, count: centers.count)
            for i in samples {
                let best = centers.indices.max(by: { simd_dot(smooth[i], centers[$0]) < simd_dot(smooth[i], centers[$1]) })!
                sums[best] += smooth[i]
            }
            for k in centers.indices where simd_length(sums[k]) > 0 { centers[k] = simd_normalize(sums[k]) }
        }
        var labels = (0..<(w * h)).map { i -> Int in
            guard mask[i] else { return -1 }
            return centers.indices.max(by: { simd_dot(smooth[i], centers[$0]) < simd_dot(smooth[i], centers[$1]) })!
        }
        // Remove small islands: each pixel takes the most common plane around it.
        let r = max(2, w / 120)
        var cleaned = labels
        for y in 0..<h {
            for x in 0..<w where labels[y * w + x] >= 0 {
                var votes = [Int](repeating: 0, count: centers.count)
                for yy in stride(from: max(0, y - r), through: min(h - 1, y + r), by: 2) {
                    for xx in stride(from: max(0, x - r), through: min(w - 1, x + r), by: 2) {
                        let l = labels[yy * w + xx]
                        if l >= 0 { votes[l] += 1 }
                    }
                }
                cleaned[y * w + x] = votes.indices.max(by: { votes[$0] < votes[$1] })!
            }
        }
        labels = cleaned
        return (labels, centers)
    }
}
