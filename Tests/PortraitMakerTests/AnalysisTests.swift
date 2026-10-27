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
        let maps = ToneMaps(images: [:], steps: [], tones: [0.9, 0.6, 0.3], thresholds: [0.7, 0.4])
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
