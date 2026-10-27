import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        // Debug mode: PortraitMaker --render <image> <output folder> [<photo of drawing> [<paper size>]]
        if args.count >= 4, args[1] == "--render" {
            exit(render(
                input: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]),
                drawing: args.count > 4 ? URL(fileURLWithPath: args[4]) : nil,
                paper: args.count > 5 ? PaperSize(rawValue: args[5]) ?? .unknown : .a4
            ))
        }
        // Debug mode: PortraitMaker --form <image> <output folder>
        if args.count == 4, args[1] == "--form" {
            exit(renderForm(input: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3])))
        }
        PortraitMakerApp.main()
    }

    static func write(_ picture: CGImage, _ name: String, in folder: URL) {
        let url = folder.appendingPathComponent("\(name).png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, picture, nil)
        CGImageDestinationFinalize(destination)
    }

    static func renderForm(input: URL, output: URL) -> Int32 {
        guard let image = LessonBuilder.loadImage(at: input) else { return 1 }
        let p = LessonBuilder.prepare(image)
        let start = Date()
        guard let form = FormAnalyzer.analyze(p.base, gray: p.gray, mask: p.mask, geometry: p.geometry) else {
            print("No form (model missing or fit failed)")
            return 1
        }
        print(String(format: "Form in %.2f s. Light %.2f %.2f %.2f. %@", Date().timeIntervalSince(start), form.light.x, form.light.y, form.light.z, form.lightDescription))
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let w = form.width, h = form.height
        write(LessonBuilder.rgbaImage(w, h) { i in
            let n = form.normals[i]
            return ((n.x + 1) / 2, (n.y + 1) / 2, n.z)
        }, "normals", in: output)
        write(LessonBuilder.rgbaImage(w, h) { i in
            let v = p.mask[i] ? form.predicted[i] : 1
            return (v, v, v)
        }, "predicted", in: output)
        write(LessonBuilder.rgbaImage(w, h) { i in
            let v = p.gray.pixels[i]
            return form.skin[i] ? (v, v * 0.7 + 0.3, v) : (v, v, v)
        }, "skin", in: output)
        let tones = LessonBuilder.boxBlur(p.gray.pixels, w, h, radius: max(1, w / 150))
        let maps = FormAnalyzer.classify(form, tones: tones, gray: p.gray.pixels, mask: p.mask)
        print(String(format: "  split %.2f terminator %.2f", maps.split, maps.terminator))
        write(LessonBuilder.rgbaImage(w, h) { maps.classes[$0].color }, "classes", in: output)
        return 0
    }

    static func render(input: URL, output: URL, drawing: URL?, paper: PaperSize) -> Int32 {
        guard let image = LessonBuilder.loadImage(at: input) else {
            print("Cannot read \(input.path)")
            return 1
        }
        var clock = Date()
        func lap(_ name: String) {
            if ProcessInfo.processInfo.environment["PM_DEBUG"] != nil { print(String(format: "  time %@: %.2f s", name, Date().timeIntervalSince(clock))) }
            clock = Date()
        }
        let lesson = LessonBuilder.build(from: image)
        lap("lesson")
        print("Face found: \(lesson.faceFound), form: \(lesson.form != nil), size \(lesson.gray.width)x\(lesson.gray.height)")
        if let form = lesson.form { print(form.form.lightDescription) }
        for m in lesson.measurements { print("  \(m.title): \(m.value)") }
        if let g = lesson.geometry {
            let h = CGFloat(lesson.gray.height)
            func top(_ p: CGPoint) -> String { String(format: "%.0f,%.0f", p.x, h - p.y) }
            print("Landmarks: eyes \(top(g.leftEye)) \(top(g.rightEye)) mouth \(top(LessonBuilder.centroid(g.lips))) nose \(top(LessonBuilder.centroid(g.nose))) eyeWidth \(String(format: "%.1f", lesson.eyeWidth))")
        }
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for stage in Stage.allCases where stage != .check {
            let underlay = stage.isLines ? lesson.photo : nil
            write(flatten(lesson.layers(for: stage), over: underlay), String(format: "%02d-%@", stage.rawValue + 1, stage.title), in: output)
        }
        guard let drawing else { return 0 }
        guard let photo = LessonBuilder.loadImage(at: drawing) else {
            print("Cannot read \(drawing.path)")
            return 1
        }
        lap("stage images")
        let flat = Paper.flatten(photo, size: paper)
        lap("paper")
        print("Paper found: \(flat.found), mm per pixel: \(flat.millimetersPerPixel.map { String(format: "%.3f", $0) } ?? "unknown")")
        guard let check = DrawingCheck.autoAlign(flat, to: lesson.analysis) else {
            print("No face found in the drawing")
            return 1
        }
        lap("align")
        print("mm per reference pixel: \(check.millimetersPerPixel.map { String(format: "%.4f", $0) } ?? "unknown")")
        let difference = check.difference(to: lesson)
        print("Values match: \(Int(difference.match * 100))%")
        lap("difference")
        let suggestions = check.suggestions(for: lesson)
        lap("suggestions")
        for s in suggestions {
            print(String(format: "  [%5.1f] %@: %@", s.severity, s.area, s.message))
        }
        write(flatten([Layer(image: check.aligned)] + lesson.lines[.features]!, over: nil), "check-lines", in: output)
        write(difference.image, "check-tones", in: output)
        return 0
    }

    /// The layers on white paper, with a faint photo below them.
    static func flatten(_ layers: [Layer], over photo: CGImage?) -> CGImage {
        let first = layers[0].image
        let rect = CGRect(x: 0, y: 0, width: first.width, height: first.height)
        let ctx = CGContext(
            data: nil, width: first.width, height: first.height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(rect)
        if let photo {
            ctx.setAlpha(0.2)
            ctx.draw(photo, in: rect)
        }
        for layer in layers {
            ctx.setAlpha(layer.opacity)
            ctx.draw(layer.image, in: rect)
        }
        return ctx.makeImage()!
    }
}

struct PortraitMakerApp: App {
    var body: some Scene {
        WindowGroup("Portrait Maker") {
            ContentView()
                .frame(minWidth: 1000, minHeight: 680)
        }
    }
}
