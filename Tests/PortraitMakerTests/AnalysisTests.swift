import CoreGraphics
import XCTest
import simd
@testable import PortraitMaker

final class AnalysisTests: XCTestCase {
    func testLeastSquaresFindsLine() throws {
        // v = 2 + 3x, with exact data.
        let rows = (0..<10).map { [1.0, Double($0)] }
        let values = (0..<10).map { 2 + 3 * Double($0) }
        let c = try XCTUnwrap(LinearAlgebra.leastSquares(rows, values))
        XCTAssertEqual(c[0], 2, accuracy: 1e-9)
        XCTAssertEqual(c[1], 3, accuracy: 1e-9)
    }

    func testLeastSquaresRejectsSingularSystem() {
        XCTAssertNil(LinearAlgebra.leastSquares([[1, 1], [2, 2], [3, 3]], [1, 2, 3]))
    }

    /// A sphere lit by a known light: the fit must find that light.
    func testFitLightFindsLightOnSphere() throws {
        let size = 120
        let light = simd_normalize(SIMD3<Float>(-0.5, 0.6, 0.62))
        var normals = [SIMD3<Float>](repeating: SIMD3(0, 0, 1), count: size * size)
        var tones = [Float](repeating: 0, count: size * size)
        var skin = [Bool](repeating: false, count: size * size)
        for y in 0..<size {
            for x in 0..<size {
                let nx = (Float(x) - 60) / 55, ny = (60 - Float(y)) / 55
                let r2 = nx * nx + ny * ny
                guard r2 < 1 else { continue }
                let i = y * size + x
                normals[i] = SIMD3(nx, ny, (1 - r2).squareRoot())
                tones[i] = 0.1 + 0.8 * max(0, simd_dot(normals[i], light))
                skin[i] = true
            }
        }
        let fit = try XCTUnwrap(FormAnalyzer.fitLight(normals: normals, tones: tones, skin: skin))
        let angle = acos(min(1, simd_dot(fit.light, light))) * 180 / .pi
        XCTAssertLessThan(angle, 3, "light found \(fit.light)")
        XCTAssertEqual(fit.ambient, 0.1, accuracy: 0.05)
    }

    func testLightDescription() {
        func form(_ light: SIMD3<Float>) -> Form {
            Form(width: 1, height: 1, normals: [], light: simd_normalize(light), shading: [], predicted: [], skin: [])
        }
        XCTAssertEqual(form(SIMD3(0, 0, 1)).lightDescription, "The light comes from the front.")
        XCTAssertTrue(form(SIMD3(-1, 1, 1)).lightDescription.hasPrefix("The light comes from above and the left"))
        XCTAssertTrue(form(SIMD3(1, 0, 1)).lightDescription.hasPrefix("The light comes from the right"))
    }

    /// An analysis where all of the image is the face, with these tones.
    private func analysis(_ pixels: [Float], width w: Int) -> Analysis {
        Analysis(
            gray: GrayImage(width: w, height: pixels.count / w, pixels: pixels), mask: [Bool](repeating: true, count: pixels.count),
            soft: pixels, medium: pixels, faceArea: Array(pixels.indices), faceTones: pixels.sorted(), eyes: nil
        )
    }

    /// A gradient from white to black. Each new value splits one value and keeps the others,
    /// so what the artist drew for fewer values stays correct.
    func testValueSplitsAreNested() {
        let w = 90
        let a = analysis((0..<(w * 10)).map { 1 - Float($0 % w) / Float(w - 1) }, width: w)
        var previous: [Float] = []
        for count in 2...9 {
            let v = LessonBuilder.valueSteps(a, count: count)
            XCTAssertEqual(Array(v.thresholds.prefix(previous.count)), previous, "the earlier splits stay")
            previous = v.thresholds
            let row = Array(v.steps[0..<w])
            XCTAssertEqual(row, row.sorted(), "light to dark from left to right")
            XCTAssertEqual(Set(row).count, count, "all \(count) steps are used")
            XCTAssertEqual(v.tones, v.tones.sorted(by: >), "lightest first")
        }
        XCTAssertEqual(LessonBuilder.valueProgression(a).count, 8)
    }

    /// Three groups of tones: two in the light (0.9 and 0.7) and one shadow (0.2). The first split
    /// separates the light from the shadow, and the second split is in the light.
    func testSplitsFollowTheLightAndShadow() throws {
        let w = 100
        let a = analysis((0..<(w * 10)).map { i -> Float in
            let x = i % w
            return x < 30 ? 0.9 : x < 60 ? 0.7 : 0.2
        }, width: w)
        let two = LessonBuilder.toneMaps(a, balance: 0, count: 2, form: nil)
        let first = try XCTUnwrap(two.thresholds.first)
        XCTAssertTrue(first > 0.2 && first <= 0.7, "the split is between the shadow and the light: \(first)")
        XCTAssertEqual(two.lightCount, 1)
        XCTAssertNil(two.newValue)
        XCTAssertEqual(two.shown, [1, 0.08], "two values are black and white")

        let three = LessonBuilder.toneMaps(a, balance: 0, count: 3, form: nil)
        XCTAssertEqual(three.lightCount, 2)
        XCTAssertTrue(three.newValueInLight)
        XCTAssertEqual(three.newValue, three.steps[40], "the new value is the darker part of the light")
        XCTAssertEqual(three.steps[40], 1)
    }

    func testValueNamesFollowTheFamilies() {
        XCTAssertEqual(ValueGuide.names(count: 2, light: 1), ["Light", "Shadow"])
        XCTAssertEqual(ValueGuide.names(count: 5, light: 2), ["Light 1", "Light 2", "Shadow 1", "Shadow 2", "Shadow 3"])
        XCTAssertTrue(ValueGuide.instruction(count: 3, newInLight: true).hasPrefix("The light splits"))
        XCTAssertTrue(ValueGuide.instruction(count: 3, newInLight: false).hasPrefix("The shadow splits"))
    }

    /// A drawing done only in light gray: the check must say that the darks are too light.
    func testLightDrawingHasDarksTooLight() {
        let w = 40, h = 40
        let photo = (0..<(w * h)).map { 1 - Float($0 % w) / Float(w - 1) }
        let a = Analysis(
            gray: GrayImage(width: w, height: h, pixels: photo), mask: [Bool](repeating: true, count: w * h),
            soft: photo, medium: photo, faceArea: Array(photo.indices), faceTones: photo.sorted(), eyes: nil
        )
        func drawing(darkest: Float) -> CGImage {
            LessonBuilder.rgbaImage(w, h) { i in
                let v = 1 - (1 - darkest) * Float(i % w) / Float(w - 1)
                return (v, v, v)
            }
        }
        let light = DrawingCheck.render(drawing(darkest: 0.7), .identity, a)
        XCTAssertGreaterThan(light.dark, 0.5)
        let full = DrawingCheck.render(drawing(darkest: 0.15), .identity, a)
        XCTAssertLessThan(full.dark, 0.5)
    }

    func testValueTonesGoFromLightToDark() {
        for count in 2...9 {
            let tones = LessonBuilder.valueTones(count: count)
            XCTAssertEqual(tones.count, count)
            XCTAssertEqual(tones.first!, 0.95, accuracy: 0.02)
            XCTAssertEqual(tones.last!, 0.13, accuracy: 0.02)
            XCTAssertEqual(tones, tones.sorted(by: >), "lightest first")
        }
    }

    func testStepOfToneUsesThresholds() {
        let maps = ToneMaps(
            images: [:], steps: [], tones: [0.9, 0.6, 0.3], thresholds: [0.7, 0.4],
            outlines: LessonBuilder.rgbaImage(1, 1) { _ in (1, 1, 1) }
        )
        XCTAssertEqual(maps.step(of: 0.8), 0)
        XCTAssertEqual(maps.step(of: 0.5), 1)
        XCTAssertEqual(maps.step(of: 0.1), 2)
    }

    func testSimplifyKeepsOnlyCorners() {
        // An L shape: a straight line to (10, 0), then up to (10, 10).
        let points = (0...10).map { CGPoint(x: $0, y: 0) } + (1...10).map { CGPoint(x: 10, y: $0) }
        let simple = LessonBuilder.simplify(points, epsilon: 0.5)
        XCTAssertEqual(simple, [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 10, y: 10)])
    }

    func testMeasureDescribesLengthAndAngle() {
        let vertical = Measurements.describe(CGPoint(x: 50, y: 0), CGPoint(x: 50, y: 100), eyeWidth: 50, headHeight: 400)
        XCTAssertEqual(vertical, "2.0 eye widths, 25% of the head height. Vertical.")
        let leaning = Measurements.describe(CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 100), eyeWidth: 50, headHeight: 400)
        XCTAssertTrue(leaning.hasSuffix("45° from vertical, leaning right at the bottom."), leaning)
    }

    func testFormFamilies() {
        XCTAssertTrue(FormClass.core.isShadowFamily)
        XCTAssertTrue(FormClass.cast.isShadowFamily)
        XCTAssertTrue(FormClass.reflected.isShadowFamily)
        XCTAssertFalse(FormClass.halftone.isShadowFamily)
        XCTAssertFalse(FormClass.localDark.isShadowFamily, "a dark local value in the light is not shadow")
    }

    func testPaperSizes() {
        XCTAssertEqual(PaperSize.a4.millimeters?.long, 297)
        XCTAssertEqual(PaperSize.letter.millimeters?.short, 215.9)
        XCTAssertNil(PaperSize.unknown.millimeters)
    }
}
