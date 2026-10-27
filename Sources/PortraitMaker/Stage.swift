enum Stage: Int, CaseIterable, Identifiable {
    case proportions, blockIn, features
    case baseTone, shadows, fourTones, darks, highlights
    case edges, details
    case check

    var id: Int { rawValue }

    static let groups: [(name: String, stages: [Stage])] = [
        ("Shape", [.proportions, .blockIn, .features]),
        ("Tone", [.baseTone, .shadows, .fourTones, .darks, .highlights]),
        ("Finish", [.edges, .details]),
        ("Check", [.check]),
    ]

    var isLines: Bool { [.proportions, .blockIn, .features].contains(self) }
    var usesTones: Bool { [.baseTone, .shadows, .fourTones, .darks, .highlights, .check].contains(self) }

    var title: String {
        switch self {
        case .proportions: "Proportions"
        case .blockIn: "Block-in"
        case .features: "Features"
        case .baseTone: "Base tone"
        case .shadows: "Shadow shapes"
        case .fourTones: "Four tones"
        case .darks: "Darkest accents"
        case .highlights: "Highlights"
        case .edges: "Edges"
        case .details: "Details"
        case .check: "Check your drawing"
        }
    }

    var symbol: String {
        switch self {
        case .proportions: "circle.dashed"
        case .blockIn: "pentagon"
        case .features: "eye"
        case .baseTone: "square.fill.on.square"
        case .shadows: "circle.lefthalf.filled"
        case .fourTones: "square.stack.3d.down.right"
        case .darks: "moon.fill"
        case .highlights: "sun.max"
        case .edges: "scribble"
        case .details: "pencil.tip"
        case .check: "checkmark.circle"
        }
    }

    var instructions: String {
        switch self {
        case .proportions:
            "Draw a light circle for the skull. Then draw the jaw down to the chin. The blue lines show the brow, the nose base and the chin. Use the grid to put the size and position of the head right. Press lightly. You will erase these lines later."
        case .blockIn:
            "Draw the outline of the head and hair with straight lines only. Do not draw curves or details. Look for the angles where the outline changes direction."
        case .features:
            "Put the eyes, brows, nose and mouth on the blue lines. Draw each feature as a simple shape with straight lines. Measure the space between the features against the photo."
        case .baseTone:
            "Hatch one light, even tone over all of the head. Do not hatch the white areas. They are the brightest lights. This tone is the start for all the other tones."
        case .shadows:
            "Find the shadow side. All of the gray area is shadow. Hatch all of it with one more layer. Keep the edge between light and shadow clear. Do not shade small parts yet."
        case .fourTones:
            "Make the tones darker step by step. Compare each area on your paper with its gray here. Add layers of hatching until the tones are the same. Work on the full head, not on one part at a time."
        case .darks:
            "Find the darkest areas: eye sockets, nostrils, the line between the lips, and the hair. Make only these areas very dark."
        case .highlights:
            "The yellow areas are the brightest lights. Lift them with an eraser. Use a hard eraser for small, sharp lights."
        case .edges:
            "Dark lines show hard edges. Keep these edges sharp. Light lines show softer edges. In all other areas, blend the tones so that they go softly into each other."
        case .details:
            "Now look at the photo. Add small details last: the pupils, the corners of the mouth, single hairs. Use Squint to check the big tones. Use Flip to find mistakes in proportion."
        case .check:
            "Take a photo of your drawing and add it here. The app aligns it to the reference. Lines shows the shapes on your drawing. Tones shows where your drawing is too dark (red) or too light (blue)."
        }
    }
}
