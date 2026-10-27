import CoreGraphics
import XCTest
@testable import PortraitMaker

final class FeedbackTests: XCTestCase {
    let size = 100

    /// A dark round blob on white: an "eye" with soft edges.
    func blob(cx: Double, cy: Double, rx: Double = 10, ry: Double = 10) -> [Float] {
        (0..<(size * size)).map { i in
            let x = Double(i % size), y = Double(i / size)
            let d = ((x - cx) / rx) * ((x - cx) / rx) + ((y - cy) / ry) * ((y - cy) / ry)
            return Float(1 - 0.8 * exp(-d))
        }
    }

    func fit(reference: [Float], drawing: [Float], axes: FitAxes = .both) throws -> (fit: LocalFit, gain: Double, contrast: Double) {
        var samples: [(x: Int, y: Int)] = []
        for y in stride(from: 25, to: 75, by: 1) { for x in stride(from: 25, to: 75, by: 1) { samples.append((x, y)) } }
        return try XCTUnwrap(DrawingCheck.localFit(
            channels: [(reference: reference, drawing: drawing)], width: size, height: size,
            samples: samples, center: CGPoint(x: 50, y: 50), reach: 15, axes: axes))
    }

    func testLocalFitFindsNoChangeOnSameImage() throws {
        let image = blob(cx: 50, cy: 50)
        let result = try fit(reference: image, drawing: image)
        XCTAssertEqual(result.fit.dx, 0)
        XCTAssertEqual(result.fit.dy, 0)
        XCTAssertEqual(result.fit.sx, 1, accuracy: 0.001)
        XCTAssertEqual(result.gain, 0, accuracy: 1e-9)
    }

    func testLocalFitFindsMoveDown() throws {
        // The drawing has the blob 6 px lower: positive dy.
        let result = try fit(reference: blob(cx: 50, cy: 50), drawing: blob(cx: 50, cy: 56))
        XCTAssertEqual(result.fit.dy, 6, accuracy: 1.1)
        XCTAssertEqual(result.fit.dx, 0, accuracy: 1.1)
        XCTAssertGreaterThan(result.gain, 0.05)
    }

    func testLocalFitFindsWiderShape() throws {
        // The drawing's blob is 16% wider.
        let result = try fit(reference: blob(cx: 50, cy: 50), drawing: blob(cx: 50, cy: 50, rx: 11.6))
        XCTAssertEqual(result.fit.sx, 1.16, accuracy: 0.03)
        XCTAssertEqual(result.fit.sy, 1, accuracy: 0.03)
    }

    func testLocalFitOnVerticalAxisDoesNotMoveSideways() throws {
        let result = try fit(reference: blob(cx: 50, cy: 50), drawing: blob(cx: 56, cy: 54), axes: .vertical)
        XCTAssertEqual(result.fit.dx, 0)
        XCTAssertEqual(result.fit.dy, 4, accuracy: 1.1)
    }

    func testLocalFitIgnoresFlatReference() {
        let flat = [Float](repeating: 0.8, count: size * size)
        XCTAssertNil(DrawingCheck.localFit(
            channels: [(reference: flat, drawing: blob(cx: 50, cy: 50))], width: size, height: size,
            samples: [(50, 50), (51, 50), (52, 50)], center: CGPoint(x: 50, y: 50), reach: 10, axes: .both))
    }

    /// Moves made by one similarity transform, plus one feature with a real error.
    func testSimilarityIgnoresOneOutlier() {
        let alpha = 0.04, beta = 0.01, tx = 3.0, ty = -2.0
        var points: [(center: CGPoint, dx: Double, dy: Double, axes: FitAxes)] = []
        for (x, y) in [(-60.0, -20.0), (60, -20), (-50, -60), (50, -60), (0, 40), (0, 100), (0, -150), (-120, 0), (120, 0)] {
            points.append((CGPoint(x: x, y: y), alpha * x - beta * y + tx, beta * x + alpha * y + ty, .both))
        }
        points[0].dy += 15
        let s = DrawingCheck.similarity(points, tolerance: 2)
        XCTAssertEqual(s.alpha, alpha, accuracy: 0.002)
        XCTAssertEqual(s.beta, beta, accuracy: 0.002)
        XCTAssertEqual(s.tx, tx, accuracy: 0.3)
        XCTAssertEqual(s.ty, ty, accuracy: 0.3)
    }

    func testMatchDistributionUndoesToneCurve() {
        let reference = (0..<1000).map { Float($0) / 999 }
        let curved = reference.map { $0 * $0 }
        let matched = DrawingCheck.matchDistribution(curved, to: reference, mask: [Bool](repeating: true, count: 1000))
        for i in stride(from: 0, to: 1000, by: 50) {
            XCTAssertEqual(matched[i], reference[i], accuracy: 0.03)
        }
    }

    func check(millimetersPerPixel: Double?) -> DrawingCheck {
        let pixel = LessonBuilder.rgbaImage(1, 1) { _ in (1, 1, 1) }
        return DrawingCheck(original: pixel, aligned: pixel, pixels: [1], tones: [1], millimetersPerPixel: millimetersPerPixel)
    }

    func testShapeMessageInMillimeters() {
        // 10 px down and 20% wider, at 0.2 mm per pixel.
        let message = check(millimetersPerPixel: 0.2).shapeMessage(LocalFit(dy: 10, sx: 1.2), axes: .both, eyeWidth: 60)
        XCTAssertEqual(message, "Move it 2.0 mm up. It is 20% too wide.")
    }

    func testShapeMessageIgnoresSmallErrors() {
        // 4 px is less than 0.08 eye widths (4.8 px), and 5% is less than the 8% limit.
        let message = check(millimetersPerPixel: nil).shapeMessage(LocalFit(dx: 4, sy: 1.05), axes: .both, eyeWidth: 60)
        XCTAssertNil(message)
    }

    func testShapeMessageWithoutPaperUsesEyeWidths() {
        let message = check(millimetersPerPixel: nil).shapeMessage(LocalFit(dx: -15), axes: .horizontal, eyeWidth: 60)
        XCTAssertEqual(message, "Move it 0.25 eye widths to the right.")
    }

    func testShapeMessageNeedsOneMillimeter() {
        // 0.08 eye widths is 4.8 px, but at 0.1 mm per pixel 1 mm is 10 px: 8 px is too small to report.
        XCTAssertNil(check(millimetersPerPixel: 0.1).shapeMessage(LocalFit(dy: 8), axes: .vertical, eyeWidth: 60))
    }
}
