enum Stage: Int, CaseIterable, Identifiable {
    case proportions, blockIn, planes, features
    case baseTone, shadows, form, values, darks, highlights
    case edges, details
    case check

    var id: Int { rawValue }

    static let groups: [(name: String, stages: [Stage])] = [
        ("Shape", [.proportions, .blockIn, .planes, .features]),
        ("Tone", [.baseTone, .shadows, .form, .values, .darks, .highlights]),
        ("Finish", [.edges, .details]),
        ("Check", [.check]),
    ]

    var isLines: Bool { [.proportions, .blockIn, .features].contains(self) }
    /// Stages that change with the value steps and the shadow amount.
    var usesValues: Bool { [.baseTone, .values, .darks, .highlights, .check].contains(self) }
    /// Stages that show where the light comes from.
    var showsLight: Bool { [.planes, .baseTone, .shadows, .form, .values].contains(self) }
    /// Stages that show the proportion measurements.
    var showsMeasurements: Bool { [.proportions, .features].contains(self) }

    var title: String {
        switch self {
        case .proportions: "Proportions"
        case .blockIn: "Block-in"
        case .planes: "Planes"
        case .features: "Features"
        case .baseTone: "Base tone"
        case .shadows: "Shadow shapes"
        case .form: "Form"
        case .values: "Values"
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
        case .planes: "cube"
        case .features: "eye"
        case .baseTone: "square.fill.on.square"
        case .shadows: "circle.lefthalf.filled"
        case .form: "light.max"
        case .values: "square.stack.3d.down.right"
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
            "Draw a light circle for the skull. Then draw the jaw down to the chin. The blue lines show the brow, the nose base and the chin. Check your drawing against the measurements on the right. Press lightly. You will erase these lines later."
        case .blockIn:
            "Draw the outline of the head and hair with straight lines only. Do not draw curves or details. Look for the angles where the outline changes direction. Use Measure to check an angle."
        case .planes:
            "These are the big planes of this head, shaded by the light in the photo. Each plane has one value. Find where the planes change direction: the forehead, the side of the head, the cheekbone, the side of the nose. The edges between the planes are where the values change."
        case .features:
            "Put the eyes, brows, nose and mouth on the blue lines. Draw each feature as a simple shape with straight lines. Measure the spaces between the features in eye widths."
        case .baseTone:
            "Hatch one light, even tone over all of the head. Do not hatch the white areas. They are the highlights. This tone is the start for all the other values."
        case .shadows:
            "Separate the light family from the shadow family. Hatch all of the shadow family with one tone. Keep the edge between the families clear. The tan areas are dark local values (hair, a beard, dark clothes) in the light. They are not shadow, so keep them lighter than the shadow family where they turn into the shadow."
        case .form:
            "Model the form inside each family. The halftone is where the form turns away from the light. The core shadow is the darkest part of the shadow, next to the light. Reflected light makes the shadow a little lighter away from the core. Cast shadows have sharper edges than form shadows."
        case .values:
            "Match each area to its value step. Step 1 is the lightest. Compare an area on your paper with its gray here, and add layers of hatching until they are the same. Work on the full head, not on one part at a time."
        case .darks:
            "Find the darkest values: the eye sockets, the nostrils, the line between the lips, and the core of the hair. Make only these areas very dark."
        case .highlights:
            "The yellow areas are the brightest lights on the skin. Lift them with an eraser. Use a hard eraser for small, sharp lights."
        case .edges:
            "Dark lines show hard edges. Keep these edges sharp. Light lines show softer edges. In all other areas, blend the values so that they go softly into each other."
        case .details:
            "Now look at the photo. Add small details last: the pupils, the corners of the mouth, single hairs. Use Squint to check the big values. Use Flip to find mistakes in proportion."
        case .check:
            "Take a photo of your drawing and add it here. The app aligns it to the reference and lists what to correct, from the largest error to the smallest."
        }
    }
}

/// Names for the values in the two families, light and shadow, and what to draw when a value is added.
enum ValueGuide {
    /// The number of values that the Light & shadow step goes up to. More values are optional.
    static let target = 5

    /// One name for each value, lightest first. `light` is the number of values in the light family.
    static func names(count: Int, light: Int) -> [String] {
        func family(_ name: String, _ n: Int) -> [String] { n == 1 ? [name] : (1...n).map { "\(name) \($0)" } }
        return family("Light", light) + family("Shadow", count - light)
    }

    /// What to draw for the value map. `newInLight` tells which family the last new value is in.
    static func instruction(count: Int, newInLight: Bool) -> String {
        if count == 2 {
            return "Squint and see only two shapes: the light (white) and the shadow (black). Draw the edge of the shadow shape lightly. Then hatch all of the shadow with one even tone. Leave the light as white paper."
        }
        let more = count < target ? " Click Add a value for the next value." : ""
        return newInLight
            ? "The light splits in two. Hatch one light layer on the orange area only. Keep it lighter than all of the shadow." + more
            : "The shadow splits in two. Hatch one more layer on the orange area only. All the other areas stay as they are." + more
    }
}

/// The three steps that the artist sees, in the order of drawing. Each step has two views:
/// the main one, and one with more detail.
enum Step: Int, CaseIterable, Identifiable {
    case shape, light, finish

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .shape: "Shape"
        case .light: "Light & shadow"
        case .finish: "Finish"
        }
    }

    /// The names of the two views.
    var views: (String, String) {
        switch self {
        case .shape: ("Lines", "Planes")
        case .light: ("Values", "Form")
        case .finish: ("Darks & lights", "Edges")
        }
    }

    /// The stage that each view shows.
    func stage(detail: Bool) -> Stage {
        switch self {
        case .shape: detail ? .planes : .blockIn
        case .light: detail ? .form : .values
        case .finish: detail ? .edges : .darks
        }
    }

    /// One technique tip, and one mistake that beginners often make, for the step.
    var tip: (tip: String, mistake: String) {
        switch self {
        case .shape: (
            "Hold the pencil far from the point and draw light lines. You will erase most of them.",
            "Beginners put the eyes too high. The eyes are near the middle of the head, not in the top third."
        )
        case .light: (
            "Everything in the light is lighter than everything in the shadow. Keep the two families apart.",
            "Beginners shade one feature at a time. Hatch each shape as one tone, across the features."
        )
        case .finish: (
            "Squint and flip the picture to find errors. Correct the big shapes before the small details.",
            "Beginners do not make the darks dark enough. Use your softest pencil for the darkest accents."
        )
        }
    }

    func instructions(detail: Bool) -> String {
        switch (self, detail) {
        case (.shape, false):
            "Draw the big shape of the head with light, straight lines. Then put the eyes, nose and mouth on the blue lines."
        case (.shape, true):
            "See the head as a few flat planes. Each plane gets one value, and the values change where the planes turn."
        case (.light, false):
            "Start with the light and the shadow. Then add one value at a time."
        case (.light, true):
            "This is why the shadow is where it is. Inside the shadow, the core shadow next to the light is the darkest. Reflected light makes the rest of the shadow a little lighter. Cast shadows have sharp edges."
        case (.finish, false):
            "Make the black areas your darkest darks. Lift the yellow spots with an eraser: they are the brightest lights. Then add the small details."
        case (.finish, true):
            "Keep the edges on the dark lines sharp. Make all the other edges soft. Squint to check that the big values are still right."
        }
    }
}
