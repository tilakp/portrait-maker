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
    @State private var step = Step.shape
    /// For each step: true when the second view (more detail) is on.
    @State private var detail: [Step: Bool] = [:]
    @State private var checking = false
    @State private var squint = false
    @State private var flip = false
    @State private var compare = false
    @State private var grid = 0
    @State private var valueCount = 5
    @State private var probes: [Probe] = []
    @State private var selectedNote: UUID?
    @State private var importTarget: ImportTarget?
    @AppStorage("paperSize") private var paperSize = PaperSize.a4
    /// The photo of the drawing as loaded, so that a new paper size can flatten it again.
    @State private var drawingPhoto: CGImage?
    @State private var check: DrawingCheck?
    @State private var difference: (image: CGImage, match: Double)?
    @State private var suggestions: [Suggestion] = []
    @State private var selectedSuggestion: UUID?
    @State private var showAllSuggestions = false
    @State private var showGuideLines = false
    @State private var showValueErrors = false
    /// A flat photo of the paper that waits for the user to click the eyes.
    @State private var unaligned: Paper?
    @State private var eyeClicks: [CGPoint] = []

    var body: some View {
        Group {
            if loading {
                ProgressView("Looking at the portrait…")
            } else if let lesson {
                VStack(alignment: .leading, spacing: 14) {
                    stepBar
                    if checking { checkScreen(lesson) } else { stepScreen(lesson) }
                }
                .padding(20)
            } else {
                ContentUnavailableView {
                    Label("Open a portrait", systemImage: "person.crop.square")
                } description: {
                    Text("Drop a photo here, or click Open. A clear photo with strong light from one side works best.")
                } actions: {
                    Button("Open Portrait…") { importTarget = .portrait }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .toolbar {
            ToolbarItemGroup {
                Button { importTarget = .portrait } label: { Label("Open", systemImage: "folder") }
                    .help("Open a portrait")
                Menu {
                    Picker("Grid", selection: $grid) {
                        Text("No grid").tag(0)
                        ForEach([3, 4, 6, 8], id: \.self) { Text("\($0) columns").tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Label("Grid", systemImage: "grid")
                }
                .help("Put a grid on the pictures")
                Toggle(isOn: $squint) { Label("Squint", systemImage: "eye.slash") }
                    .help("Blur the pictures to see the big values")
                Toggle(isOn: $flip) { Label("Flip", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") }
                    .help("Mirror the pictures to see mistakes with fresh eyes")
                Toggle(isOn: $compare) { Label("Compare values", systemImage: "eyedropper") }
                    .help("Click two points to compare their values")
            }
        }
        .onChange(of: compare) { probes = [] }
        .onChange(of: step) { selectedNote = nil }
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
            checking && lesson != nil ? openDrawing(url) : openPortrait(url)
            return true
        }
    }

    // MARK: - Step bar

    private var stepBar: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases) { s in
                if s.rawValue > 0 {
                    Rectangle().fill(.secondary.opacity(0.4)).frame(width: 24, height: 1)
                }
                Button {
                    step = s
                    checking = false
                } label: {
                    HStack(spacing: 6) {
                        Text("\(s.rawValue + 1)")
                            .font(.caption.bold())
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(isCurrent(s) ? Color.accentColor : .secondary.opacity(0.3)))
                            .foregroundStyle(isCurrent(s) ? .white : .primary)
                        Text(s.title).fontWeight(isCurrent(s) ? .semibold : .regular)
                    }
                }
                .buttonStyle(.plain)
            }
            Spacer()
            Button {
                checking = true
            } label: {
                Label("Check my drawing", systemImage: "checkmark.circle")
            }
            .buttonStyle(.bordered)
            .tint(checking ? .accentColor : nil)
        }
    }

    private func isCurrent(_ s: Step) -> Bool { !checking && s == step }

    // MARK: - Step screen

    private func stepScreen(_ lesson: Lesson) -> some View {
        let showDetail = detail[step] ?? false
        let stage = step.stage(detail: showDetail)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(step.title).font(.title2.bold())
                Spacer()
                if step == .values && !showDetail {
                    Stepper(value: $valueCount, in: 2...9) {
                        Text("\(valueCount) values").monospacedDigit()
                    }
                    .onChange(of: valueCount) { updateTones() }
                    .help("Fewer values are easier. More values show more detail.")
                }
                Picker("View", selection: Binding(get: { detail[step] ?? false }, set: { detail[step] = $0 })) {
                    Text(step.views.0).tag(false)
                    Text(step.views.1).tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 230)
            }
            Text(step.instructions(detail: showDetail))
                .font(.title3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .top, spacing: 16) {
                picture(
                    lesson.layers(for: stage), pixelWidth: lesson.gray.width,
                    underlay: stage == .blockIn ? lesson.photo : nil,
                    markers: probeMarkers, overlays: noteOverlays(lesson), onTap: probe
                )
                VStack(alignment: .leading, spacing: 12) {
                    if stage != .details {
                        picture([Layer(image: lesson.photo)], pixelWidth: lesson.gray.width, markers: probeMarkers, overlays: noteOverlays(lesson), onTap: probe)
                            .frame(height: 300)
                    }
                    if step == .light || step == .values, let form = lesson.form {
                        Label(form.form.lightDescription, systemImage: "lightbulb")
                            .foregroundStyle(.secondary)
                    }
                    if step == .shape { faceNotes(lesson) }
                    Spacer()
                }
                .frame(width: 260)
            }
            HStack(spacing: 14) {
                if compare {
                    compareReadout
                } else {
                    ForEach(Array(lesson.legend(for: stage).enumerated()), id: \.offset) { _, item in
                        legend(Color(red: Double(item.color.0), green: Double(item.color.1), blue: Double(item.color.2)), item.name)
                    }
                }
                Spacer()
                Button("Back") { step = Step(rawValue: step.rawValue - 1)! }
                    .disabled(step.rawValue == 0)
                Button(step == Step.allCases.last ? "Check my drawing" : "Next") {
                    if let next = Step(rawValue: step.rawValue + 1) { step = next } else { checking = true }
                }
                .keyboardShortcut(.defaultAction)
            }
            .frame(minHeight: 32)
        }
    }

    /// At most three plain notes about what is special in this face. Click one to see it.
    @ViewBuilder private func faceNotes(_ lesson: Lesson) -> some View {
        let notes = lesson.measurements.filter { $0.note != nil }.sorted { $0.weight > $1.weight }.prefix(3)
        if !notes.isEmpty {
            Text("Look out for").font(.headline)
            ForEach(Array(notes)) { m in
                Button {
                    selectedNote = selectedNote == m.id ? nil : m.id
                } label: {
                    Text(m.note!)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(selectedNote == m.id ? Color.orange.opacity(0.25) : Color.secondary.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func noteOverlays(_ lesson: Lesson) -> [Overlay] {
        guard let m = lesson.measurements.first(where: { $0.id == selectedNote }) else { return [] }
        return [Overlay(segments: m.segments, color: .orange)]
    }

    // MARK: - Check screen

    @ViewBuilder private func checkScreen(_ lesson: Lesson) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Check my drawing").font(.title2.bold())
                Spacer()
                if check != nil && unaligned == nil {
                    Toggle("Guide lines", isOn: $showGuideLines).toggleStyle(.button)
                    Toggle("Value errors", isOn: $showValueErrors).toggleStyle(.button)
                    Menu {
                        Picker("Paper size", selection: $paperSize) {
                            ForEach(PaperSize.allCases) { Text($0.rawValue).tag($0) }
                        }
                        Divider()
                        Button("New Photo…") { importTarget = .drawing }
                        Button("Align by Hand") {
                            unaligned = drawingPhoto.map { Paper.flatten($0, size: paperSize) }
                            eyeClicks = []
                        }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                    .fixedSize()
                    .onChange(of: paperSize) { if let drawingPhoto { processDrawing(drawingPhoto) } }
                }
            }
            if let unaligned {
                HStack {
                    Text("Click the center of the eye on the left in your drawing, then the eye on the right.")
                        .font(.title3)
                    Spacer()
                    if check != nil {
                        Button("Cancel") {
                            self.unaligned = nil
                            eyeClicks = []
                        }
                    }
                }
                picture(
                    [Layer(image: unaligned.image)], pixelWidth: unaligned.image.width,
                    markers: eyeClicks.enumerated().map { ("\($0.offset + 1)", $0.element) },
                    overlays: [], onTap: { clickEye($0, in: unaligned) }
                )
            } else if let check {
                Text(summary).font(.title3)
                HStack(alignment: .top, spacing: 16) {
                    drawingPicture(lesson, check)
                    VStack(alignment: .leading, spacing: 10) {
                        picture([Layer(image: lesson.photo)], pixelWidth: lesson.gray.width, markers: [], overlays: [], onTap: { _ in })
                            .frame(height: 240)
                        correctionList
                    }
                    .frame(width: 300)
                }
            } else {
                ContentUnavailableView {
                    Label("Add a photo of your drawing", systemImage: "camera")
                } description: {
                    Text("Photograph all of your paper from straight above, in even light, on a darker table. Drop the photo here, or click the button.")
                } actions: {
                    Button("Add Photo…") { importTarget = .drawing }
                        .buttonStyle(.borderedProminent)
                        .disabled(lesson.analysis.eyes == nil)
                    Picker("Paper size", selection: $paperSize) {
                        ForEach(PaperSize.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .frame(width: 200)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            HStack {
                Spacer()
                Button("Back to the steps") { checking = false }
            }
        }
    }

    private var summary: String {
        guard difference != nil else { return "Comparing your drawing with the photo…" }
        let count = suggestions.filter { $0.kind != .missing || $0.area != "Alignment" }.count
        if suggestions.first?.area == "Alignment" { return "The drawing could not be lined up with the photo." }
        if count == 0 { return "Well done: no large errors. Now compare the details by eye." }
        return count == 1 ? "One thing to correct." : "Start with the first correction. The numbers show where they are."
    }

    /// The suggestions in view: the three most important, or all of them.
    private var visibleSuggestions: [Suggestion] {
        showAllSuggestions ? suggestions : Array(suggestions.prefix(3))
    }

    private func drawingPicture(_ lesson: Lesson, _ check: DrawingCheck) -> some View {
        var layers = [Layer(image: showValueErrors ? difference?.image ?? check.aligned : check.aligned)]
        if showGuideLines {
            layers += lesson.lines[.blockIn]!.map { Layer(image: $0.image, opacity: $0.opacity, tinted: true) }
        }
        let numbers = visibleSuggestions.enumerated().map { ("\($0.offset + 1)", CGPoint(x: $0.element.rect.midX, y: $0.element.rect.midY)) }
        var overlays: [Overlay] = []
        if let s = suggestions.first(where: { $0.id == selectedSuggestion }) {
            overlays.append(Overlay(rect: s.rect, arrow: s.move, color: .cyan))
        }
        return picture(layers, pixelWidth: lesson.gray.width, markers: numbers + probeMarkers, overlays: overlays, onTap: probe)
    }

    @ViewBuilder private var correctionList: some View {
        if !suggestions.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(Array(visibleSuggestions.enumerated()), id: \.element.id) { index, s in
                        Button {
                            selectedSuggestion = selectedSuggestion == s.id ? nil : s.id
                        } label: {
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(index + 1)")
                                    .font(.caption.bold()).foregroundStyle(.white)
                                    .frame(width: 20, height: 20)
                                    .background(Circle().fill(.red))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(s.area).bold()
                                    Text(s.message).fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 6).fill(selectedSuggestion == s.id ? Color.cyan.opacity(0.2) : Color.secondary.opacity(0.1)))
                        }
                        .buttonStyle(.plain)
                    }
                    if suggestions.count > 3 {
                        Button(showAllSuggestions ? "Show fewer" : "Show all \(suggestions.count)") { showAllSuggestions.toggle() }
                            .buttonStyle(.link)
                    }
                    Text("Left and right are as you see them in the picture.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Compare values

    private var probeMarkers: [(String, CGPoint)] {
        guard compare else { return [] }
        return probes.enumerated().map { ($0.offset == 0 ? "A" : "B", $0.element.point) }
    }

    @ViewBuilder private var compareReadout: some View {
        if probes.isEmpty {
            Text("Click two points to compare their values.").foregroundStyle(.secondary)
        }
        ForEach(Array(probes.enumerated()), id: \.element.id) { index, probe in
            HStack(spacing: 8) {
                // Each value on the same neutral gray, so its neighbors cannot trick the eye.
                Rectangle()
                    .fill(Color(white: Double(probe.value)))
                    .frame(width: 26, height: 26)
                    .padding(6)
                    .background(Color(white: 0.5))
                Text(index == 0 ? "A" : "B").bold()
            }
        }
        if probes.count == 2 {
            Text(verdict(probes[0], probes[1]))
        }
    }

    private func probe(_ point: CGPoint) {
        guard compare, let lesson else { return }
        let x = min(max(Int(point.x), 0), lesson.gray.width - 1), y = min(max(Int(point.y), 0), lesson.gray.height - 1)
        let probe = Probe(
            point: point, value: lesson.gray.value(x: x, y: y),
            step: lesson.tones.step(of: lesson.analysis.medium[y * lesson.gray.width + x])
        )
        probes = probes.count >= 2 ? [probe] : probes + [probe]
    }

    private func verdict(_ a: Probe, _ b: Probe) -> String {
        let difference = Int(((a.value - b.value) * 100).rounded())
        if abs(difference) <= 3 { return "The same value." }
        let darker = difference > 0 ? "B" : "A"
        let steps = abs(a.step - b.step)
        return steps == 0 ? "\(darker) is a little darker." : "\(darker) is darker, by \(steps == 1 ? "one value" : "\(steps) values")."
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

    // MARK: - Loading

    private func openPortrait(_ url: URL, then drawing: URL? = nil) {
        guard let image = load(url) else { return }
        loading = true
        probes = []
        check = nil
        drawingPhoto = nil
        difference = nil
        suggestions = []
        unaligned = nil
        checking = false
        step = .shape
        let count = valueCount
        Task.detached {
            let built = LessonBuilder.build(from: image, valueCount: count)
            await MainActor.run {
                lesson = built
                loading = false
                if let drawing { openDrawing(drawing) }
            }
        }
    }

    private func openDrawing(_ url: URL) {
        guard let image = load(url) else { return }
        drawingPhoto = image
        checking = true
        processDrawing(image)
    }

    private func processDrawing(_ photo: CGImage) {
        guard let analysis = lesson?.analysis else { return }
        let size = paperSize
        difference = nil
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
        let count = valueCount, form = lesson?.form?.maps
        Task.detached {
            let tones = LessonBuilder.toneMaps(analysis, balance: 0, count: count, form: form)
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
        showAllSuggestions = false
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
