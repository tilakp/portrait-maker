import CoreGraphics
import Foundation

/// One proportion of the head, measured in the units that artists use.
struct Measurement: Identifiable {
    let id = UUID()
    let title: String
    let value: String
    /// What a typical head shows, so the artist can see what is special about this one.
    let typical: String
    /// Lines that show what was measured, in pixels, top-left origin.
    let segments: [(CGPoint, CGPoint)]
    /// A plain sentence when this face is different from a typical face, else nil.
    var note: String? = nil
    /// How different, in units of the normal spread. Larger is more special.
    var weight: Double = 0
}

enum Measurements {
    /// Proportions from the face landmarks. `outline` is the head outline (hair included),
    /// in Core Graphics coordinates, the same as the geometry.
    static func measure(_ g: LessonBuilder.FaceGeometry, outline: [CGPoint], height: Int) -> [Measurement] {
        let h = CGFloat(height)
        func top(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x, y: h - p.y) }
        func across(_ p: CGPoint) -> CGFloat { LessonBuilder.dot(p, g.across) }
        func extent(_ pts: [CGPoint]) -> (min: CGPoint, max: CGPoint) {
            (pts.min(by: { across($0) < across($1) })!, pts.max(by: { across($0) < across($1) })!)
        }
        func ratio(_ v: CGFloat) -> String { String(format: "%.2f", v) }
        func one(_ v: CGFloat) -> String { String(format: "%.1f", v) }

        let leftEye = extent(g.leftEyeOutline), rightEye = extent(g.rightEyeOutline)
        let eyeWidth = ((across(leftEye.max) - across(leftEye.min)) + (across(rightEye.max) - across(rightEye.min))) / 2
        guard eyeWidth > 1 else { return [] }

        // Head height: top of the head outline to the chin, along the face axis.
        let crown = outline.max(by: { g.height($0) < g.height($1) }) ?? g.brow
        let headHeight = g.height(crown) - g.height(g.chin)
        let headSides = extent(outline.filter { abs(g.height($0)) < headHeight * 0.15 })
        let headWidth = across(headSides.max) - across(headSides.min)

        // The eye on the left in the image comes first.
        let (first, second) = across(leftEye.min) < across(rightEye.min) ? (leftEye, rightEye) : (rightEye, leftEye)
        let gap = across(second.min) - across(first.max)
        let jaw = extent(g.jaw)
        let faceWidth = across(jaw.max) - across(jaw.min)
        let nose = extent(g.nose), mouth = extent(g.lips)
        let pupils = hypot(g.rightEye.x - g.leftEye.x, g.rightEye.y - g.leftEye.y)
        let middle = g.height(g.brow) - g.height(g.noseBase)
        let lower = g.height(g.noseBase) - g.height(g.chin)
        let eyeLine = (g.height(crown) - g.height(g.eyes)) / headHeight

        // A note when the face is outside the normal spread around the canon.
        func differs(_ actual: CGFloat, _ typical: CGFloat, _ spread: CGFloat, more: String, less: String) -> (String?, Double) {
            let d = actual - typical
            guard abs(d) > spread else { return (nil, 0) }
            return (d > 0 ? more : less, Double(abs(d) / spread))
        }
        let eyePercent = Int((eyeLine * 100).rounded())
        let eyes = differs(eyeLine, 0.5, 0.04,
                           more: "The eyes are lower than usual: at \(eyePercent)% of the head height from the top.",
                           less: "The eyes are higher than usual: at \(eyePercent)% of the head height from the top.")
        let apart = differs(gap / eyeWidth, 1, 0.15,
                            more: "The eyes are far apart: \(one(gap / eyeWidth)) eye widths between them.",
                            less: "The eyes are close together: \(one(gap / eyeWidth)) eye widths between them.")
        let wide = differs(faceWidth / eyeWidth, 5, 0.4,
                           more: "The face is wide: \(one(faceWidth / eyeWidth)) eye widths at the cheeks.",
                           less: "The face is narrow: \(one(faceWidth / eyeWidth)) eye widths at the cheeks.")
        let lowerFace = differs(lower / max(middle, 1), 1, 0.08,
                                more: "The lower face is long: nose to chin is \(ratio(lower / max(middle, 1))) × brow to nose.",
                                less: "The lower face is short: nose to chin is \(ratio(lower / max(middle, 1))) × brow to nose.")
        let noseWidth = (across(nose.max) - across(nose.min)) / eyeWidth
        let noseNote = differs(noseWidth, 1, 0.15,
                               more: "The nose is wide: \(one(noseWidth)) eye widths.",
                               less: "The nose is narrow: \(one(noseWidth)) eye widths.")
        let mouthRatio = (across(mouth.max) - across(mouth.min)) / max(pupils, 1)
        let mouthNote = differs(mouthRatio, 1, 0.12,
                                more: "The mouth is wide: its corners are outside the pupils.",
                                less: "The mouth is narrow: its corners are inside the pupils.")

        var result: [Measurement] = []
        result.append(Measurement(
            title: "Head height to width", value: ratio(headHeight / max(headWidth, 1)),
            typical: "About 1.3 with hair, seen from the front.",
            segments: [(top(g.axis(g.height(crown))), top(g.axis(g.height(g.chin)))), (top(headSides.min), top(headSides.max))]))
        result.append(Measurement(
            title: "Eye line", value: "\(eyePercent)% from the top",
            typical: "About 50% of the head height.",
            segments: [(top(g.axis(g.height(crown))), top(g.axis(g.height(g.eyes)))), (top(first.min), top(second.max))],
            note: eyes.0, weight: eyes.1))
        result.append(Measurement(
            title: "Space between the eyes", value: "\(one(gap / eyeWidth)) eye widths",
            typical: "About 1 eye width.",
            segments: [(top(first.max), top(second.min)), (top(first.min), top(first.max))],
            note: apart.0, weight: apart.1))
        result.append(Measurement(
            title: "Face width at the cheeks", value: "\(one(faceWidth / eyeWidth)) eye widths",
            typical: "About 5 eye widths.",
            segments: [(top(jaw.min), top(jaw.max))],
            note: wide.0, weight: wide.1))
        result.append(Measurement(
            title: "Nose base to chin", value: "\(ratio(lower / max(middle, 1))) × brow to nose base",
            typical: "About 1: the lower two thirds of the face are equal.",
            segments: [(top(g.axis(g.height(g.brow))), top(g.axis(g.height(g.noseBase)))),
                       (top(g.axis(g.height(g.noseBase))), top(g.axis(g.height(g.chin))))],
            note: lowerFace.0, weight: lowerFace.1))
        result.append(Measurement(
            title: "Nose width", value: "\(one(noseWidth)) eye widths",
            typical: "About 1 eye width: the wings of the nose are below the inner corners of the eyes.",
            segments: [(top(nose.min), top(nose.max))],
            note: noseNote.0, weight: noseNote.1))
        result.append(Measurement(
            title: "Mouth width", value: "\(ratio(mouthRatio)) × the space between the pupils",
            typical: "About 1: the corners of the mouth are below the pupils.",
            segments: [(top(mouth.min), top(mouth.max)), (top(g.leftEye), top(g.rightEye))],
            note: mouthNote.0, weight: mouthNote.1))

        // Tilt: the angle of the eye line. Positive when the eye on the right is higher.
        let tilt = atan2(g.across.y, g.across.x) * 180 / .pi
        if abs(tilt) >= 1 {
            result.append(Measurement(
                title: "Head tilt", value: "\(Int(abs(tilt).rounded()))° \(tilt > 0 ? "up to the right" : "down to the right")",
                typical: "Draw the eye line at this angle, and all the other feature lines parallel to it.",
                segments: [(top(first.min), top(second.max))],
                note: abs(tilt) >= 3 ? "The head tilts \(Int(abs(tilt).rounded()))°. Draw the eye line and all the feature lines at this angle." : nil,
                weight: Double(abs(tilt)) / 3))
        }
        // Turn: compare the two sides of the face from the face axis at the cheeks.
        let center = across(g.axis(g.height(g.eyes)))
        let leftSide = center - across(jaw.min), rightSide = across(jaw.max) - center
        let turn = min(leftSide, rightSide) / max(max(leftSide, rightSide), 1)
        if turn < 0.9 {
            result.append(Measurement(
                title: "Turn of the head", value: "far side \(ratio(turn)) × near side",
                typical: "In a front view both sides are equal. The far side looks narrower when the head turns.",
                segments: [(top(jaw.min), top(g.axis(g.height(g.eyes)))), (top(g.axis(g.height(g.eyes))), top(jaw.max))],
                note: "The head is turned: the far side of the face is only \(ratio(turn)) × the near side.",
                weight: Double((0.9 - turn) / 0.1)))
        }
        return result
    }

    /// Length in eye widths and as a part of the head height, and the angle from vertical.
    static func describe(_ a: CGPoint, _ b: CGPoint, eyeWidth: CGFloat, headHeight: CGFloat) -> String {
        let length = hypot(b.x - a.x, b.y - a.y)
        // Angle from vertical, from 0 to 90 degrees, with the side it leans to.
        let angle = atan2(abs(b.x - a.x), abs(b.y - a.y)) * 180 / .pi
        let lean = (b.x - a.x) * (b.y - a.y) > 0 ? "right" : "left"
        let direction = angle < 1 ? "vertical" : angle > 89 ? "horizontal"
            : "\(Int(angle.rounded()))° from vertical, leaning \(lean) at the bottom"
        return String(format: "%.1f eye widths, %d%% of the head height. ", length / max(eyeWidth, 1), Int((length / max(headHeight, 1) * 100).rounded())) + direction.prefix(1).uppercased() + direction.dropFirst() + "."
    }
}
