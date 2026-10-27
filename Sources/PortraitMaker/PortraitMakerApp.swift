import AppKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

@main
enum Entry {
    static func main() {
        let args = CommandLine.arguments
        // Debug mode: PortraitMaker --render <image> <output folder> [<photo of drawing>]
        if args.count >= 4, args[1] == "--render" {
            exit(render(
                input: URL(fileURLWithPath: args[2]), output: URL(fileURLWithPath: args[3]),
                drawing: args.count > 4 ? URL(fileURLWithPath: args[4]) : nil
            ))
        }
        PortraitMakerApp.main()
    }

    static func render(input: URL, output: URL, drawing: URL?) -> Int32 {
        guard let image = LessonBuilder.loadImage(at: input) else {
            print("Cannot read \(input.path)")
            return 1
        }
        let lesson = LessonBuilder.build(from: image)
        print("Face found: \(lesson.faceFound), size \(lesson.gray.width)x\(lesson.gray.height)")
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        func write(_ picture: CGImage, _ name: String) {
            let url = output.appendingPathComponent("\(name).png")
            let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, picture, nil)
            CGImageDestinationFinalize(destination)
            print(url.path)
        }
        for stage in Stage.allCases where stage != .check {
            let underlay = stage.isLines ? lesson.photo : nil
            write(flatten(lesson.layers(for: stage), over: underlay), String(format: "%02d-%@", stage.rawValue + 1, stage.title))
        }
        if let drawing {
            guard let photo = LessonBuilder.loadImage(at: drawing) else {
                print("Cannot read \(drawing.path)")
                return 1
            }
            guard let check = DrawingCheck.autoAlign(photo, to: lesson.analysis) else {
                print("No face found in the drawing")
                return 1
            }
            let difference = check.difference(to: lesson)
            print("Tones match: \(Int(difference.match * 100))%")
            write(flatten([Layer(image: check.aligned)] + lesson.lines[.features]!, over: nil), "check-lines")
            write(difference.image, "check-tones")
        }
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
                .frame(minWidth: 900, minHeight: 650)
        }
    }
}

struct Probe: Identifiable {
    let id = UUID()
    /// Pixel position in the lesson image, top-left origin.
    let point: CGPoint
    let value: Float
}

enum ImportTarget { case portrait, drawing }

enum CheckMode: String, CaseIterable {
    case lines = "Lines", tones = "Tones", drawing = "Drawing"
}

struct ContentView: View {
    @State private var lesson: Lesson?
    @State private var loading = false
    @State private var stage: Stage? = .proportions
    @State private var squint = false
    @State private var flip = false
    @State private var underlay = true
    @State private var compare = false
    @State private var grid = 0
    @State private var balance = 0.0
    @State private var probes: [Probe] = []
    @State private var importTarget: ImportTarget?
    @State private var check: DrawingCheck?
    @State private var difference: (image: CGImage, match: Double)?
    @State private var checkMode = CheckMode.lines
    /// A drawing that waits for the user to click its eyes.
    @State private var unaligned: CGImage?
    @State private var eyeClicks: [CGPoint] = []

    var body: some View {
        NavigationSplitView {
            List(selection: $stage) {
                ForEach(Stage.groups, id: \.name) { group in
                    Section(group.name) {
                        ForEach(group.stages) { stage in
                            Label("\(stage.rawValue + 1). \(stage.title)", systemImage: stage.symbol)
                                .tag(stage)
                        }
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 220)
            .disabled(lesson == nil)
        } detail: {
            if loading {
                ProgressView("Preparing the stages…")
            } else if let lesson, let stage {
                detail(lesson, stage)
            } else {
                ContentUnavailableView {
                    Label("Open a portrait", systemImage: "person.crop.square")
                } description: {
                    Text("Drop a photo here, or click Open. Use a clear photo with strong light from one side.")
                } actions: {
                    Button("Open Portrait…") { importTarget = .portrait }
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { importTarget = .portrait } label: { Label("Open", systemImage: "folder") }
                Menu {
                    Picker("Grid", selection: $grid) {
                        Text("No grid").tag(0)
                        ForEach([3, 4, 6, 8], id: \.self) { Text("\($0) columns").tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Grid", systemImage: "grid")
                }
                Toggle(isOn: $squint) { Label("Squint", systemImage: "eye.slash") }
                Toggle(isOn: $flip) { Label("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                Toggle(isOn: $compare) { Label("Compare tones", systemImage: "eyedropper") }
                Toggle(isOn: $underlay) { Label("Photo under lines", systemImage: "photo") }
                    .disabled(stage?.isLines != true)
            }
        }
        .onChange(of: compare) { probes = [] }
        .onAppear {
            // Paths at launch open a portrait and a drawing: open -a PortraitMaker --args <portrait> [<drawing>]
            let paths = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }.map { URL(fileURLWithPath: $0) }
            if let portrait = paths.first {
                openPortrait(portrait, then: paths.dropFirst().first)
            }
        }
        .fileImporter(
            isPresented: Binding(get: { importTarget != nil }, set: { if !$0 { importTarget = nil } }),
            allowedContentTypes: [.image]
        ) { result in
            guard case .success(let url) = result else { return }
            importTarget == .drawing ? openDrawing(url) : openPortrait(url)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            stage == .check && lesson != nil ? openDrawing(url) : openPortrait(url)
            return true
        }
    }

    // MARK: - Detail

    private func detail(_ lesson: Lesson, _ stage: Stage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Step \(stage.rawValue + 1) of \(Stage.allCases.count): \(stage.title)")
                .font(.title2.bold())
            Text(stage.instructions)
            if !lesson.faceFound && (stage == .proportions || stage == .features || stage == .check) {
                Text("No face was found in the portrait, so this step is limited.")
                    .foregroundStyle(.orange)
            }
            if stage.usesTones && (stage != .check || checkMode == .tones) {
                HStack {
                    Text("Shadow amount")
                    Slider(
                        value: $balance, in: -1...1,
                        label: { EmptyView() },
                        minimumValueLabel: { Text("Less") },
                        maximumValueLabel: { Text("More") },
                        onEditingChanged: { editing in if !editing { updateTones() } }
                    )
                    .frame(maxWidth: 320)
                    Button("Reset") { balance = 0; updateTones() }
                        .disabled(balance == 0)
                }
            }
            if stage == .check { checkControls(lesson) }
            HStack(spacing: 16) {
                mainPicture(lesson, stage)
                picture([Layer(image: lesson.photo)], pixelWidth: lesson.gray.width, markers: probeMarkers, onTap: probe)
                    .frame(maxWidth: 260)
                    .opacity(stage == .details ? 0 : 1)
            }
            footer(stage)
        }
        .padding(20)
    }

    @ViewBuilder private func mainPicture(_ lesson: Lesson, _ stage: Stage) -> some View {
        if stage != .check {
            picture(
                lesson.layers(for: stage), pixelWidth: lesson.gray.width,
                underlay: stage.isLines && underlay ? lesson.photo : nil, markers: probeMarkers, onTap: probe
            )
        } else if let unaligned {
            let names = ["1", "2"]
            picture(
                [Layer(image: unaligned)], pixelWidth: unaligned.width,
                markers: eyeClicks.enumerated().map { (names[$0.offset], $0.element) },
                onTap: { clickEye($0, in: unaligned) }
            )
        } else if let check {
            switch checkMode {
            case .lines:
                picture(
                    [Layer(image: check.aligned)] + lesson.lines[.features]!.map { Layer(image: $0.image, opacity: $0.opacity, tinted: true) },
                    pixelWidth: lesson.gray.width, markers: probeMarkers, onTap: probe
                )
            case .tones:
                if let difference {
                    picture([Layer(image: difference.image)], pixelWidth: lesson.gray.width, markers: probeMarkers, onTap: probe)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .drawing:
                picture([Layer(image: check.aligned)], pixelWidth: lesson.gray.width, markers: probeMarkers, onTap: probe)
            }
        } else {
            ContentUnavailableView {
                Label("Add your drawing", systemImage: "camera")
            } description: {
                Text("Take a photo of your paper from straight above, in even light. Drop it here, or click the button.")
            } actions: {
                Button("Add Photo of Drawing…") { importTarget = .drawing }
                    .disabled(lesson.analysis.eyes == nil)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private func checkControls(_ lesson: Lesson) -> some View {
        if unaligned != nil {
            HStack {
                Text(check == nil
                     ? "The app could not find the face in your drawing. Click the center of the eye on the left, then the eye on the right."
                     : "Click the center of the eye on the left in your drawing, then the eye on the right.")
                    .foregroundStyle(.orange)
                Spacer()
                if check != nil {
                    Button("Cancel") {
                        unaligned = nil
                        eyeClicks = []
                    }
                }
            }
        } else if check != nil {
            HStack(spacing: 12) {
                Picker("View", selection: $checkMode) {
                    ForEach(CheckMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
                if checkMode == .tones, let difference {
                    Text("Tones are the same on \(Int((difference.match * 100).rounded()))% of the head.")
                }
                Spacer()
                Button("Align by Hand") {
                    unaligned = check?.original
                    eyeClicks = []
                }
                Button("New Photo…") { importTarget = .drawing }
            }
        }
    }

    private var probeMarkers: [(String, CGPoint)] {
        guard compare else { return [] }
        return probes.enumerated().map { ($0.offset == 0 ? "A" : "B", $0.element.point) }
    }

    @ViewBuilder private func footer(_ stage: Stage) -> some View {
        HStack(spacing: 16) {
            if compare {
                if probes.isEmpty {
                    Text("Click two points on a picture to compare their tones.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(probes.enumerated()), id: \.element.id) { index, probe in
                    swatch(index == 0 ? "A" : "B", probe.value)
                }
                if probes.count == 2 {
                    Text(verdict(probes[0].value, probes[1].value))
                }
            } else if stage == .check && checkMode == .tones && check != nil {
                legend(Color(red: 0.95, green: 0.25, blue: 0.2), "Too dark")
                legend(Color(red: 0.2, green: 0.45, blue: 1), "Too light")
            }
            Spacer()
            Button("Back") { self.stage = Stage(rawValue: stage.rawValue - 1) }
                .disabled(stage.rawValue == 0)
            Button("Next") { self.stage = Stage(rawValue: stage.rawValue + 1) }
                .disabled(stage == Stage.allCases.last)
                .keyboardShortcut(.defaultAction)
        }
        .frame(height: 56)
    }

    private func legend(_ color: Color, _ text: String) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(color.opacity(0.7)).frame(width: 18, height: 18)
            Text(text)
        }
    }

    // MARK: - Picture

    /// Layers drawn on white paper, scaled to fit. Taps are reported in pixels of the layers, top-left origin.
    private func picture(
        _ layers: [Layer], pixelWidth: Int, underlay: CGImage? = nil,
        markers: [(String, CGPoint)], onTap: @escaping (CGPoint) -> Void
    ) -> some View {
        let first = layers[0].image
        return GeometryReader { geo in
            let fit = fitRect(CGSize(width: first.width, height: first.height), in: geo.size)
            let scale = fit.width / CGFloat(pixelWidth)
            ZStack(alignment: .topLeading) {
                ZStack {
                    Color.white
                    if let underlay {
                        Image(decorative: underlay, scale: 1).resizable().opacity(0.2)
                    }
                    ForEach(layers.indices, id: \.self) { i in
                        layerImage(layers[i])
                    }
                }
                .frame(width: fit.width, height: fit.height)
                .blur(radius: squint ? 6 : 0)
                .overlay { gridLines(size: fit.size) }
                .scaleEffect(x: flip ? -1 : 1)
                .offset(x: fit.minX, y: fit.minY)
                .shadow(radius: 2)

                ForEach(markers.indices, id: \.self) { i in
                    let point = markers[i].1
                    let x = flip ? CGFloat(pixelWidth) - point.x : point.x
                    Text(markers[i].0)
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(.red))
                        .position(x: fit.minX + x * scale, y: fit.minY + point.y * scale)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                guard fit.contains(location) else { return }
                var x = (location.x - fit.minX) / scale
                if flip { x = CGFloat(pixelWidth) - x }
                onTap(CGPoint(x: x, y: (location.y - fit.minY) / scale))
            }
        }
    }

    @ViewBuilder private func layerImage(_ layer: Layer) -> some View {
        if layer.tinted {
            Image(decorative: layer.image, scale: 1).renderingMode(.template).resizable()
                .foregroundStyle(Color(red: 0.9, green: 0.2, blue: 0.5))
                .opacity(layer.opacity)
        } else {
            Image(decorative: layer.image, scale: 1).resizable().opacity(layer.opacity)
        }
    }

    /// Square cells, counted from the top-left corner.
    private func gridLines(size: CGSize) -> some View {
        Canvas { context, _ in
            guard grid > 0 else { return }
            let cell = size.width / CGFloat(grid)
            var path = Path()
            for i in 1..<grid {
                path.move(to: CGPoint(x: CGFloat(i) * cell, y: 0))
                path.addLine(to: CGPoint(x: CGFloat(i) * cell, y: size.height))
            }
            var y = cell
            while y < size.height {
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: size.width, y: y))
                y += cell
            }
            context.stroke(path, with: .color(Color(red: 0.9, green: 0.3, blue: 0.2).opacity(0.6)), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    private func fitRect(_ size: CGSize, in bounds: CGSize) -> CGRect {
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let w = size.width * scale, h = size.height * scale
        return CGRect(x: (bounds.width - w) / 2, y: (bounds.height - h) / 2, width: w, height: h)
    }

    // MARK: - Tone compare

    private func probe(_ point: CGPoint) {
        guard compare, let lesson else { return }
        let probe = Probe(point: point, value: lesson.gray.value(x: Int(point.x), y: Int(point.y)))
        probes = probes.count >= 2 ? [probe] : probes + [probe]
    }

    /// Each tone is shown on the same neutral gray, so its neighbors cannot trick the eye.
    private func swatch(_ name: String, _ value: Float) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color(white: Double(value)))
                .frame(width: 32, height: 32)
                .padding(8)
                .background(Color(white: 0.5))
            Text("\(name): \(Int(((1 - value) * 100).rounded()))% dark")
                .monospacedDigit()
        }
    }

    private func verdict(_ a: Float, _ b: Float) -> String {
        let difference = Int(((a - b) * 100).rounded())
        if abs(difference) <= 3 { return "Almost the same tone." }
        return difference > 0 ? "B is \(difference)% darker." : "A is \(-difference)% darker."
    }

    // MARK: - Loading

    private func openPortrait(_ url: URL, then drawing: URL? = nil) {
        guard let image = load(url) else { return }
        loading = true
        probes = []
        check = nil
        difference = nil
        unaligned = nil
        balance = 0
        Task.detached {
            let built = LessonBuilder.build(from: image)
            await MainActor.run {
                lesson = built
                stage = .proportions
                loading = false
                if let drawing { openDrawing(drawing) }
            }
        }
    }

    private func openDrawing(_ url: URL) {
        guard let image = load(url), let analysis = lesson?.analysis else { return }
        Task.detached {
            let aligned = DrawingCheck.autoAlign(image, to: analysis)
            await MainActor.run {
                if let aligned {
                    setCheck(aligned)
                } else {
                    unaligned = image
                    eyeClicks = []
                }
            }
        }
    }

    private func clickEye(_ point: CGPoint, in drawing: CGImage) {
        eyeClicks.append(point)
        guard eyeClicks.count == 2, let analysis = lesson?.analysis else { return }
        let sorted = eyeClicks.sorted { $0.x < $1.x }
        unaligned = nil
        eyeClicks = []
        Task.detached {
            let aligned = DrawingCheck.align(drawing, eyes: (sorted[0], sorted[1]), to: analysis)
            await MainActor.run { if let aligned { setCheck(aligned) } }
        }
    }

    private func setCheck(_ newCheck: DrawingCheck) {
        check = newCheck
        refreshDifference()
    }

    private func updateTones() {
        guard let analysis = lesson?.analysis else { return }
        let value = Float(balance)
        Task.detached {
            let tones = LessonBuilder.toneMaps(analysis, balance: value)
            await MainActor.run {
                lesson?.tones = tones
                refreshDifference()
            }
        }
    }

    private func refreshDifference() {
        guard let check, let lesson else { return }
        difference = nil
        Task.detached {
            let result = check.difference(to: lesson)
            await MainActor.run { difference = result }
        }
    }

    private func load(_ url: URL) -> CGImage? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return LessonBuilder.loadImage(at: url)
    }
}
