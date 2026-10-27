import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct Probe: Identifiable {
    let id = UUID()
    /// Pixel position in the lesson image, top-left origin.
    let point: CGPoint
    let value: Float
    /// The value step at the point, 0 is the lightest.
    let step: Int
}

enum ImportTarget { case portrait, drawing }

enum CheckMode: String, CaseIterable {
    case lines = "Lines", tones = "Values", drawing = "Drawing"
}

/// The tool that a click on a picture uses.
enum Tool { case none, compare, measure }

/// Lines and boxes drawn on a picture, in pixels of the picture, top-left origin.
struct Overlay {
    var segments: [(CGPoint, CGPoint)] = []
    var rect: CGRect?
    var arrow: (from: CGPoint, to: CGPoint)?
    var color: Color = .orange
}

struct ContentView: View {
    @State private var lesson: Lesson?
    @State private var loading = false
    @State private var stage: Stage? = .proportions
    @State private var squint = false
    @State private var flip = false
    @State private var underlay = true
    @State private var tool = Tool.none
    @State private var grid = 0
    @State private var balance = 0.0
    @State private var valueCount = 5
    @State private var probes: [Probe] = []
    @State private var measurePoints: [CGPoint] = []
    @State private var selectedMeasurement: UUID?
    @State private var importTarget: ImportTarget?
    @AppStorage("paperSize") private var paperSize = PaperSize.a4
    /// The photo of the drawing as loaded, so that a new paper size can flatten it again.
    @State private var drawingPhoto: CGImage?
    @State private var check: DrawingCheck?
    @State private var difference: (image: CGImage, match: Double)?
    @State private var suggestions: [Suggestion] = []
    @State private var selectedSuggestion: UUID?
    @State private var checkMode = CheckMode.lines
    /// A flat photo of the paper that waits for the user to click the eyes.
    @State private var unaligned: Paper?
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
                ProgressView("Analyzing the portrait…")
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
                Toggle(isOn: toolBinding(.compare)) { Label("Compare values", systemImage: "eyedropper") }
                Toggle(isOn: toolBinding(.measure)) { Label("Measure", systemImage: "ruler") }
                Toggle(isOn: $underlay) { Label("Photo under lines", systemImage: "photo") }
                    .disabled(stage?.isLines != true)
            }
        }
        .onChange(of: tool) {
            probes = []
            measurePoints = []
        }
        .onChange(of: stage) {
            selectedMeasurement = nil
            selectedSuggestion = nil
        }
        .onAppear {
            Task.detached(priority: .utility) { FormAnalyzer.warmUp() }
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

    private func toolBinding(_ value: Tool) -> Binding<Bool> {
        Binding(get: { tool == value }, set: { tool = $0 ? value : .none })
    }

    // MARK: - Detail

    private func detail(_ lesson: Lesson, _ stage: Stage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Step \(stage.rawValue + 1) of \(Stage.allCases.count): \(stage.title)")
                .font(.title2.bold())
            Text(stage.instructions)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(5)
            if !lesson.faceFound && (stage == .proportions || stage == .features || stage == .check) {
                Text("No face was found in the portrait, so this step is limited.")
                    .foregroundStyle(.orange)
            }
            if lesson.form == nil && [.planes, .shadows, .form].contains(stage) {
                Text("The depth model is not available, so this step uses the photo only.")
                    .foregroundStyle(.orange)
            }
            if stage.showsLight, let form = lesson.form {
                Label(form.form.lightDescription, systemImage: "lightbulb")
                    .foregroundStyle(.secondary)
            }
            if stage.usesValues && (stage != .check || checkMode == .tones) {
                valueControls
            }
            if stage == .check { checkControls(lesson) }
            HStack(alignment: .top, spacing: 16) {
                mainPicture(lesson, stage)
                sidePanel(lesson, stage)
                    .frame(width: 300)
            }
            footer(stage)
        }
        .padding(20)
    }

    private var valueControls: some View {
        HStack {
            Stepper(value: $valueCount, in: 2...9) {
                Text("Value steps: \(valueCount)").monospacedDigit()
            }
            .onChange(of: valueCount) { updateTones() }
            Divider().frame(height: 16)
            Text("Shadow amount")
            Slider(
                value: $balance, in: -1...1,
                label: { EmptyView() },
                minimumValueLabel: { Text("Less") },
                maximumValueLabel: { Text("More") },
                onEditingChanged: { editing in if !editing { updateTones() } }
            )
            .frame(maxWidth: 280)
            Button("Reset") { balance = 0; updateTones() }
                .disabled(balance == 0)
        }
    }

    @ViewBuilder private func mainPicture(_ lesson: Lesson, _ stage: Stage) -> some View {
        if stage != .check {
            picture(
                lesson.layers(for: stage), pixelWidth: lesson.gray.width,
                underlay: stage.isLines && underlay ? lesson.photo : nil,
                markers: markers, overlays: overlays(lesson), onTap: click
            )
        } else if let unaligned {
            let names = ["1", "2"]
            picture(
                [Layer(image: unaligned.image)], pixelWidth: unaligned.image.width,
                markers: eyeClicks.enumerated().map { (names[$0.offset], $0.element) },
                overlays: [], onTap: { clickEye($0, in: unaligned) }
            )
        } else if let check {
            switch checkMode {
            case .lines:
                picture(
                    [Layer(image: check.aligned)] + lesson.lines[.features]!.map { Layer(image: $0.image, opacity: $0.opacity, tinted: true) },
                    pixelWidth: lesson.gray.width, markers: markers, overlays: overlays(lesson), onTap: click
                )
            case .tones:
                if let difference {
                    picture([Layer(image: difference.image)], pixelWidth: lesson.gray.width, markers: markers, overlays: overlays(lesson), onTap: click)
                } else {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            case .drawing:
                picture([Layer(image: check.aligned)], pixelWidth: lesson.gray.width, markers: markers, overlays: overlays(lesson), onTap: click)
            }
        } else {
            ContentUnavailableView {
                Label("Add your drawing", systemImage: "camera")
            } description: {
                Text("Take a photo of all of your paper from straight above, in even light, on a darker table. Drop it here, or click the button.")
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
                .frame(maxWidth: 260)
                if checkMode == .tones, let difference {
                    Text("Values are the same on \(Int((difference.match * 100).rounded()))% of the head.")
                }
                Spacer()
                Picker("Paper", selection: $paperSize) {
                    ForEach(PaperSize.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 170)
                .onChange(of: paperSize) { if let drawingPhoto { processDrawing(drawingPhoto) } }
                Button("Align by Hand") {
                    unaligned = drawingPhoto.map { Paper.flatten($0, size: paperSize) }
                    eyeClicks = []
                }
                Button("New Photo…") { importTarget = .drawing }
            }
        }
    }

    // MARK: - Side panel

    @ViewBuilder private func sidePanel(_ lesson: Lesson, _ stage: Stage) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if stage != .details {
                picture([Layer(image: lesson.photo)], pixelWidth: lesson.gray.width, markers: markers, overlays: overlays(lesson), onTap: click)
                    .frame(height: stage.showsMeasurements || (stage == .check && check != nil) ? 260 : nil)
            }
            if stage.showsMeasurements && !lesson.measurements.isEmpty {
                Text("Measurements").font(.headline)
                List(lesson.measurements, selection: $selectedMeasurement) { m in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(m.title).bold()
                            Spacer()
                            Text(m.value).monospacedDigit()
                        }
                        Text(m.typical).font(.caption).foregroundStyle(.secondary)
                    }
                    .tag(m.id)
                }
                .listStyle(.bordered)
            }
            if stage == .check && check != nil {
                suggestionList
            }
        }
    }

    @ViewBuilder private var suggestionList: some View {
        HStack {
            Text("What to correct").font(.headline)
            Spacer()
            Text("\(suggestions.count)").foregroundStyle(.secondary)
        }
        if check?.millimetersPerPixel == nil {
            Text("For distances in millimeters, choose the paper size and include all of the paper in the photo.")
                .font(.caption).foregroundStyle(.secondary)
        }
        if suggestions.isEmpty && difference != nil {
            Text("No large errors found. Compare the details by eye now.")
                .foregroundStyle(.secondary)
        }
        List(suggestions, selection: $selectedSuggestion) { s in
            HStack(alignment: .top) {
                Image(systemName: s.kind == .shape ? "ruler" : s.kind == .value ? "circle.lefthalf.filled" : "questionmark.circle")
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(s.area).bold()
                    Text(s.message).font(.callout).fixedSize(horizontal: false, vertical: true)
                }
            }
            .tag(s.id)
        }
        .listStyle(.bordered)
        Text("Left and right are as you see them in the picture.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func overlays(_ lesson: Lesson) -> [Overlay] {
        var result: [Overlay] = []
        if let m = lesson.measurements.first(where: { $0.id == selectedMeasurement }) {
            result.append(Overlay(segments: m.segments, color: .orange))
        }
        if let s = suggestions.first(where: { $0.id == selectedSuggestion }) {
            result.append(Overlay(rect: s.rect, arrow: s.move, color: .cyan))
        }
        if tool == .measure && measurePoints.count == 2 {
            result.append(Overlay(segments: [(measurePoints[0], measurePoints[1])], color: .green))
        }
        return result
    }

    private var markers: [(String, CGPoint)] {
        switch tool {
        case .compare: return probes.enumerated().map { ($0.offset == 0 ? "A" : "B", $0.element.point) }
        case .measure: return measurePoints.enumerated().map { ("\($0.offset + 1)", $0.element) }
        case .none: return []
        }
    }

    @ViewBuilder private func footer(_ stage: Stage) -> some View {
        HStack(spacing: 16) {
            if tool == .compare {
                if probes.isEmpty {
                    Text("Click two points on a picture to compare their values.")
                        .foregroundStyle(.secondary)
                }
                ForEach(Array(probes.enumerated()), id: \.element.id) { index, probe in
                    swatch(index == 0 ? "A" : "B", probe)
                }
                if probes.count == 2 {
                    Text(verdict(probes[0], probes[1]))
                }
            } else if tool == .measure, let lesson {
                if measurePoints.count < 2 {
                    Text("Click two points on a picture to measure a length and an angle.")
                        .foregroundStyle(.secondary)
                } else {
                    Text(Measurements.describe(measurePoints[0], measurePoints[1], eyeWidth: lesson.eyeWidth, headHeight: lesson.headHeight))
                }
            } else if let lesson, !lesson.legend(for: stage).isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 14) {
                        ForEach(Array(lesson.legend(for: stage).enumerated()), id: \.offset) { _, item in
                            legend(Color(red: Double(item.color.0), green: Double(item.color.1), blue: Double(item.color.2)), item.name)
                        }
                    }
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
            RoundedRectangle(cornerRadius: 3).fill(color).frame(width: 18, height: 18)
                .overlay(RoundedRectangle(cornerRadius: 3).stroke(.secondary.opacity(0.5)))
            Text(text)
        }
    }

    // MARK: - Picture

    /// Layers drawn on white paper, scaled to fit. Taps are reported in pixels of the layers, top-left origin.
    private func picture(
        _ layers: [Layer], pixelWidth: Int, underlay: CGImage? = nil,
        markers: [(String, CGPoint)], overlays: [Overlay], onTap: @escaping (CGPoint) -> Void
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
                .overlay { overlayCanvas(overlays, scale: scale) }
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

    private func overlayCanvas(_ overlays: [Overlay], scale: CGFloat) -> some View {
        Canvas { context, _ in
            func p(_ point: CGPoint) -> CGPoint { CGPoint(x: point.x * scale, y: point.y * scale) }
            for overlay in overlays {
                var path = Path()
                for (a, b) in overlay.segments {
                    path.move(to: p(a))
                    path.addLine(to: p(b))
                }
                if let rect = overlay.rect {
                    path.addRect(CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale))
                }
                if let arrow = overlay.arrow {
                    let a = p(arrow.from), b = p(arrow.to)
                    path.move(to: a)
                    path.addLine(to: b)
                    let angle = atan2(b.y - a.y, b.x - a.x)
                    for side in [-0.5, 0.5] {
                        path.move(to: b)
                        path.addLine(to: CGPoint(x: b.x - 9 * cos(angle + side), y: b.y - 9 * sin(angle + side)))
                    }
                }
                context.stroke(path, with: .color(.black.opacity(0.5)), lineWidth: 4)
                context.stroke(path, with: .color(overlay.color), lineWidth: 2)
            }
        }
        .allowsHitTesting(false)
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

    // MARK: - Tools

    private func click(_ point: CGPoint) {
        guard let lesson else { return }
        switch tool {
        case .compare:
            let x = min(max(Int(point.x), 0), lesson.gray.width - 1), y = min(max(Int(point.y), 0), lesson.gray.height - 1)
            let probe = Probe(
                point: point, value: lesson.gray.value(x: x, y: y),
                step: lesson.tones.step(of: lesson.analysis.medium[y * lesson.gray.width + x])
            )
            probes = probes.count >= 2 ? [probe] : probes + [probe]
        case .measure:
            measurePoints = measurePoints.count >= 2 ? [point] : measurePoints + [point]
        case .none:
            break
        }
    }

    /// Each value is shown on the same neutral gray, so its neighbors cannot trick the eye.
    private func swatch(_ name: String, _ probe: Probe) -> some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color(white: Double(probe.value)))
                .frame(width: 32, height: 32)
                .padding(8)
                .background(Color(white: 0.5))
            Text("\(name): step \(probe.step + 1) of \(lesson?.tones.count ?? 0), \(Int(((1 - probe.value) * 100).rounded()))% dark")
                .monospacedDigit()
        }
    }

    private func verdict(_ a: Probe, _ b: Probe) -> String {
        let difference = Int(((a.value - b.value) * 100).rounded())
        if abs(difference) <= 3 { return "Almost the same value." }
        let steps = abs(a.step - b.step)
        let stepText = steps == 0 ? "the same step" : steps == 1 ? "1 step" : "\(steps) steps"
        return difference > 0 ? "B is \(difference)% darker (\(stepText))." : "A is \(-difference)% darker (\(stepText))."
    }

    // MARK: - Loading

    private func openPortrait(_ url: URL, then drawing: URL? = nil) {
        guard let image = load(url) else { return }
        loading = true
        probes = []
        measurePoints = []
        check = nil
        drawingPhoto = nil
        difference = nil
        suggestions = []
        unaligned = nil
        balance = 0
        let count = valueCount
        Task.detached {
            let built = LessonBuilder.build(from: image, valueCount: count)
            await MainActor.run {
                lesson = built
                stage = .proportions
                loading = false
                if let drawing { openDrawing(drawing) }
            }
        }
    }

    private func openDrawing(_ url: URL) {
        guard let image = load(url) else { return }
        drawingPhoto = image
        processDrawing(image)
    }

    private func processDrawing(_ photo: CGImage) {
        guard let analysis = lesson?.analysis else { return }
        let size = paperSize
        Task.detached {
            let paper = Paper.flatten(photo, size: size)
            let aligned = DrawingCheck.autoAlign(paper, to: analysis)
            await MainActor.run {
                if let aligned {
                    setCheck(aligned)
                } else {
                    unaligned = paper
                    eyeClicks = []
                }
            }
        }
    }

    private func clickEye(_ point: CGPoint, in paper: Paper) {
        eyeClicks.append(point)
        guard eyeClicks.count == 2, let analysis = lesson?.analysis else { return }
        let sorted = eyeClicks.sorted { $0.x < $1.x }
        unaligned = nil
        eyeClicks = []
        Task.detached {
            let aligned = DrawingCheck.align(paper, eyes: (sorted[0], sorted[1]), to: analysis)
            await MainActor.run { if let aligned { setCheck(aligned) } }
        }
    }

    private func setCheck(_ newCheck: DrawingCheck) {
        check = newCheck
        refreshDifference()
    }

    private func updateTones() {
        guard let analysis = lesson?.analysis else { return }
        let value = Float(balance), count = valueCount, form = lesson?.form?.maps
        Task.detached {
            let tones = LessonBuilder.toneMaps(analysis, balance: value, count: count, form: form)
            await MainActor.run {
                lesson?.tones = tones
                refreshDifference()
            }
        }
    }

    private func refreshDifference() {
        guard let check, let lesson else { return }
        difference = nil
        selectedSuggestion = nil
        Task.detached {
            let result = check.difference(to: lesson)
            let list = check.suggestions(for: lesson)
            await MainActor.run {
                difference = result
                suggestions = list
            }
        }
    }

    private func load(_ url: URL) -> CGImage? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return LessonBuilder.loadImage(at: url)
    }
}
