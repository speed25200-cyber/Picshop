#if canImport(CoreImage) && canImport(Metal)
import XCTest
import CoreImage
import CoreVideo
import Metal
import PicshopCore
@testable import PicshopImaging

/// Orientation contracts on the real frameworks: Core Image's top edge (maxY) is byte row 0
/// on every read and write, in the inpainting worker and on the canvas's render target.
final class OrientationTests: XCTestCase {
    private struct RGB: CustomStringConvertible {
        let r: Int, g: Int, b: Int
        var description: String { "(\(r), \(g), \(b))" }
    }

    /// Top half (CI y ≥ h/2) red, bottom half blue.
    private func topRedBottomBlue(width: Int, height: Int) -> CIImage {
        let w = CGFloat(width), h = CGFloat(height), half = CGFloat(height / 2)
        let red = CIImage(color: CIColor(red: 1, green: 0, blue: 0)).cropped(to: CGRect(x: 0, y: half, width: w, height: h - half))
        let blue = CIImage(color: CIColor(red: 0, green: 0, blue: 1)).cropped(to: CGRect(x: 0, y: 0, width: w, height: half))
        return red.composited(over: blue)
    }

    private func pixel(_ bytes: [UInt8], x: Int, y: Int, width: Int) -> RGB {
        let i = (y * width + x) * 4
        return RGB(r: Int(bytes[i]), g: Int(bytes[i + 1]), b: Int(bytes[i + 2]))
    }

    private func assertRed(_ p: RGB, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssert(p.r > 150 && p.g < 110 && p.b < 110, "\(message): expected red, got \(p)", file: file, line: line)
    }

    private func assertBlue(_ p: RGB, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssert(p.b > 150 && p.r < 110 && p.g < 110, "\(message): expected blue, got \(p)", file: file, line: line)
    }

    private func assertGreen(_ p: RGB, _ message: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssert(p.g > 150 && p.r < 110 && p.b < 110, "\(message): expected green, got \(p)", file: file, line: line)
    }

    private func maxDifference(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).map { abs(Int($0) - Int($1)) }.max() ?? 0
    }

    private func pixelBuffer(width: Int, height: Int, format: OSType, fillRow: (Int, UnsafeMutableRawPointer) -> Void) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()]
        XCTAssertEqual(CVPixelBufferCreate(nil, width, height, format, attributes as CFDictionary, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let base = try XCTUnwrap(CVPixelBufferGetBaseAddress(pixelBuffer))
        let rowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        for y in 0..<height { fillRow(y, base + y * rowBytes) }
        return pixelBuffer
    }

    // MARK: CIImage → CGImage → bytes

    func testCGImageFromCIImageIsUpright() throws {
        let width = 24, height = 16
        let cg = try XCTUnwrap(ImageSupport.cgImage(from: topRedBottomBlue(width: width, height: height)))
        XCTAssertEqual(cg.width, width)
        XCTAssertEqual(cg.height, height)
        let bytes = ImageSupport.rgbaBytes(from: cg)
        assertRed(pixel(bytes, x: width / 2, y: 0, width: width), "row 0 is the CI top")
        assertBlue(pixel(bytes, x: width / 2, y: height - 1, width: width), "the last row is the CI bottom")
    }

    func testBytesOfARectAreTopDown() throws {
        // A 4×4 window across the boundary (CI y 6–10, red from y 8): rows 0–1 red, rows 2–3 blue.
        let bytes = try XCTUnwrap(ImageSupport.rgbaBytes(of: topRedBottomBlue(width: 24, height: 16), rect: CGRect(x: 4, y: 6, width: 4, height: 4)))
        XCTAssertEqual(bytes.count, 4 * 4 * 4)
        assertRed(pixel(bytes, x: 1, y: 0, width: 4), "row 0")
        assertRed(pixel(bytes, x: 1, y: 1, width: 4), "row 1")
        assertBlue(pixel(bytes, x: 1, y: 2, width: 4), "row 2")
        assertBlue(pixel(bytes, x: 1, y: 3, width: 4), "row 3")
    }

    // MARK: Round trips

    func testRGBABytesRoundTrip() throws {
        let width = 7, height = 5
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let i = (y * width + x) * 4
                bytes[i] = UInt8((x * 37 + y * 11) % 256)
                bytes[i + 1] = UInt8((x * 13 + y * 53) % 256)
                bytes[i + 2] = UInt8((x * 71 + y * 29) % 256)
            }
        }
        let image = try XCTUnwrap(ImageSupport.ciImage(rgba: bytes, width: width, height: height))
        XCTAssertEqual(image.extent, CGRect(x: 0, y: 0, width: width, height: height))
        let back = try XCTUnwrap(ImageSupport.rgbaBytes(of: image))
        XCTAssertEqual(back.count, bytes.count)
        XCTAssertLessThanOrEqual(maxDifference(bytes, back), 2, "same colour space both ways: no flip, no colour shift")
    }

    func testGrayBytesRoundTrip() throws {
        let width = 9, height = 4
        let bytes = (0..<(width * height)).map { UInt8(($0 * 29) % 256) }
        for space in [CGColorSpaceCreateDeviceGray(), RenderContext.maskColorSpace] {
            let image = try XCTUnwrap(ImageSupport.ciImage(gray: bytes, width: width, height: height, colorSpace: space))
            let back = try XCTUnwrap(ImageSupport.grayBytes(of: image, colorSpace: space))
            XCTAssertEqual(back.count, bytes.count)
            XCTAssertLessThanOrEqual(maxDifference(bytes, back), 2, "\(space)")
        }
    }

    // MARK: Vision masks and model outputs

    func testVisionMaskBufferKeepsTopRowsOnTop() throws {
        let width = 16, height = 12
        let eightBit = try pixelBuffer(width: width, height: height, format: kCVPixelFormatType_OneComponent8) { y, row in
            let values = row.assumingMemoryBound(to: UInt8.self)
            for x in 0..<width { values[x] = y < 3 ? 255 : 0 }
        }
        let float = try pixelBuffer(width: width, height: height, format: kCVPixelFormatType_OneComponent32Float) { y, row in
            let values = row.assumingMemoryBound(to: Float.self)
            for x in 0..<width { values[x] = y < 3 ? 1 : 0 }
        }
        for (name, buffer) in [("OneComponent8", eightBit), ("OneComponent32Float", float)] {
            for scale in [1, 2] {
                let w = width * scale, h = height * scale
                let bytes = MaskStore.bytes(from: buffer, width: w, height: h)
                XCTAssertEqual(bytes.count, w * h)
                XCTAssertGreaterThan(bytes[w / 2], 200, "\(name) ×\(scale): row 0 is selected, at full strength at the border")
                XCTAssertLessThan(bytes[(h - 1) * w + w / 2], 30, "\(name) ×\(scale): the last row is not")
                let box = MaskStore.boundingBox(of: bytes, width: w, height: h, threshold: 127)
                XCTAssertEqual(box.minY, 0, accuracy: 0.01, "\(name) ×\(scale)")
                XCTAssertEqual(box.maxY, 0.25, accuracy: 0.06, "\(name) ×\(scale)")
            }
        }
    }

    #if canImport(CoreML)
    func testModelOutputBufferIsTopDownAndUntouched() throws {
        let width = 8, height = 6
        // 32BGRA: the top two rows (200, 10, 20), the rest (15, 30, 220).
        let buffer = try pixelBuffer(width: width, height: height, format: kCVPixelFormatType_32BGRA) { y, row in
            let values = row.assumingMemoryBound(to: UInt8.self)
            let (r, g, b): (UInt8, UInt8, UInt8) = y < 2 ? (200, 10, 20) : (15, 30, 220)
            for x in 0..<width {
                values[x * 4] = b; values[x * 4 + 1] = g; values[x * 4 + 2] = r; values[x * 4 + 3] = 255
            }
        }
        let output = try XCTUnwrap(CoreMLImageModel.rgbaBytes(fromImageBuffer: buffer))
        XCTAssertEqual(output.width, width)
        XCTAssertEqual(output.height, height)
        let top = pixel(output.rgba, x: 3, y: 0, width: width)
        let bottom = pixel(output.rgba, x: 3, y: height - 1, width: width)
        XCTAssertLessThanOrEqual(max(abs(top.r - 200), abs(top.g - 10), abs(top.b - 20)), 2, "row 0 is the buffer's first row, values unchanged: \(top)")
        XCTAssertLessThanOrEqual(max(abs(bottom.r - 15), abs(bottom.g - 30), abs(bottom.b - 220)), 2, "last row: \(bottom)")
    }
    #endif

    // MARK: Inpainting

    func testInpaintingWorkerSeesUprightCropAndFillLandsOnTheHole() async throws {
        let width = 200, height = 100
        let image = topRedBottomBlue(width: width, height: height)
        let extent = image.extent
        // A hole near the top-left: normalised (0.1, 0.1, 0.2, 0.3), CI x 20–60, y 60–90.
        let hole = PSRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3)
        let mask = CIImage(color: .white).cropped(to: hole.ciRect(in: extent)).composited(over: CIImage(color: .black).cropped(to: extent))
        let recorder = RecordingInpainter()
        let pipeline = InpaintingPipeline(neural: recorder)
        let result = try await pipeline.fill(image: image, mask: mask, boundingBox: hole, feather: 0.01)

        // The crop is the hole plus a 96 px margin, clipped to the picture: CI (0, 0, 156, 100), at full scale (156 < 1024).
        let seen = try XCTUnwrap(recorder.recorded)
        XCTAssertEqual(seen.width, 156)
        XCTAssertEqual(seen.height, height)
        let w = seen.width, h = seen.height
        guard seen.rgba.count == w * h * 4, seen.mask.count == w * h else { return XCTFail("the worker's buffers do not match its size") }
        assertRed(pixel(seen.rgba, x: w / 2, y: 0, width: w), "the worker's row 0 is the CI top")
        assertBlue(pixel(seen.rgba, x: w / 2, y: h - 1, width: w), "the worker's last row is the CI bottom")
        // Crop rows 10–39 and columns 20–59, grown by the pipeline's 1 px dilation.
        let seenHole = MaskStore.boundingBox(of: seen.mask, width: w, height: h)
        XCTAssertEqual(seenHole.minX * Double(w), 19, accuracy: 1.5)
        XCTAssertEqual(seenHole.maxX * Double(w), 61, accuracy: 1.5)
        XCTAssertEqual(seenHole.minY * Double(h), 9, accuracy: 1.5, "the worker's hole is at the top, like the image's")
        XCTAssertEqual(seenHole.maxY * Double(h), 41, accuracy: 1.5)

        let out = try XCTUnwrap(ImageSupport.rgbaBytes(of: result))
        XCTAssertEqual(out.count, width * height * 4)
        assertGreen(pixel(out, x: 40, y: 25, width: width), "the fill lands on the hole (top-left)")
        assertBlue(pixel(out, x: 40, y: 80, width: width), "below the hole stays blue")
        assertRed(pixel(out, x: 150, y: 25, width: width), "beside the hole stays red")
    }

    // MARK: Canvas

    func testCanvasPlacementPutsTheImageTopAtTheFrameTop() {
        let transform = CanvasPlacement.transform(imageExtent: CGRect(x: 0, y: 0, width: 100, height: 50), frame: CGRect(x: 10, y: 20, width: 200, height: 100),
                                                  drawableSize: CGSize(width: 400, height: 300), scale: 2)
        // CI (0, 50), the image's top-left, lands 40 px below the drawable's top (frame.minY × scale).
        let topLeft = CGPoint(x: 0, y: 50).applying(transform)
        XCTAssertEqual(topLeft.x, 20, accuracy: 1e-9)
        XCTAssertEqual(topLeft.y, 260, accuracy: 1e-9)
        let bottomRight = CGPoint(x: 100, y: 0).applying(transform)
        XCTAssertEqual(bottomRight.x, 420, accuracy: 1e-9)
        XCTAssertEqual(bottomRight.y, 60, accuracy: 1e-9)
    }

    /// Renders like `MetalCanvasView.draw` into an offscreen texture and reads texture row 0,
    /// the row the display shows at the top. Settles whether the canvas is upright.
    func testCanvasRenderTargetShowsTheCITopOnRowZero() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw XCTSkip("No Metal device") }
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let width = 16, height = 16
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite, .renderTarget]
        #if os(macOS)
        descriptor.storageMode = device.hasUnifiedMemory ? .shared : .managed
        #else
        descriptor.storageMode = .shared
        #endif
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))
        let commandBuffer = try XCTUnwrap(queue.makeCommandBuffer())

        let destination = CanvasPlacement.destination(width: width, height: height, commandBuffer: commandBuffer) { texture }
        let drawableSize = CGSize(width: width, height: height)
        let image = topRedBottomBlue(width: 8, height: 8)
        let placed = image.transformed(by: CanvasPlacement.transform(imageExtent: image.extent, frame: CGRect(origin: .zero, size: drawableSize), drawableSize: drawableSize, scale: 1))
        let background = CIImage(color: CIColor(red: 0, green: 0, blue: 0)).cropped(to: CGRect(origin: .zero, size: drawableSize))
        let task = try RenderContext.shared.startTask(toRender: placed.composited(over: background), to: destination)
        #if os(macOS)
        if texture.storageMode == .managed, let blit = commandBuffer.makeBlitCommandEncoder() {
            blit.synchronize(resource: texture)
            blit.endEncoding()
        }
        #endif
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        _ = try task.waitUntilCompleted()

        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&bytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        // bgra8Unorm stores B, G, R, A.
        let top = (width / 2) * 4
        let bottom = ((height - 1) * width + width / 2) * 4
        assertRed(RGB(r: Int(bytes[top + 2]), g: Int(bytes[top + 1]), b: Int(bytes[top])), "texture row 0 (the top of the screen) shows the CI top")
        assertBlue(RGB(r: Int(bytes[bottom + 2]), g: Int(bytes[bottom + 1]), b: Int(bytes[bottom])), "the last texture row shows the CI bottom")
    }

    // MARK: Guard

    /// Bitmaps are read through `ImageSupport` (top-down by contract), never through a probe.
    func testNoRuntimeOrientationProbeInSources() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let files = (FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?.allObjects ?? []).compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        guard !files.isEmpty else { throw XCTSkip("Sources are not reachable from the test bundle") }
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("bitmapIsTopDown"), "\(file.lastPathComponent) brings back the orientation probe")
            // LensBlur reads one averaged pixel, which has no orientation.
            if file.lastPathComponent != "LensBlur.swift" {
                XCTAssertFalse(text.contains("toBitmap:"), "\(file.lastPathComponent): read bitmaps through ImageSupport's top-down helpers")
            }
        }
    }
}

/// Records what the pipeline hands the engine and paints the hole pure green.
private final class RecordingInpainter: Inpainter, @unchecked Sendable {
    let name = "Recorder"
    let preferredLongestSide = 1024
    private let lock = NSLock()
    private var last: (rgba: [UInt8], mask: [UInt8], width: Int, height: Int)?

    var recorded: (rgba: [UInt8], mask: [UInt8], width: Int, height: Int)? { lock.withLock { last } }

    func inpaint(rgba: [UInt8], mask: [UInt8], width: Int, height: Int) async throws -> [UInt8] {
        lock.withLock { last = (rgba, mask, width, height) }
        var out = rgba
        for i in 0..<(width * height) where mask[i] > 127 {
            out[i * 4] = 0; out[i * 4 + 1] = 255; out[i * 4 + 2] = 0; out[i * 4 + 3] = 255
        }
        return out
    }
}
#endif
