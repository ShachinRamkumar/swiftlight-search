import XCTest
import DigUpCoreAIRuntime

final class JPEGDecodeTests: XCTestCase {
    func testMalformedJPEGReturnsErrorWithoutExitingProcess() throws {
        guard #available(macOS 27, *) else { return }
        let folder=URL(fileURLWithPath:NSTemporaryDirectory()).appendingPathComponent("c1-jpeg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true)
        defer { try? FileManager.default.removeItem(at:folder) }
        let file=folder.appendingPathComponent("broken.jpg")
        let cases: [[UInt8]]=[[0xff,0xd8], [0xff,0xd8,0xff,0xd9], [0xff,0xd8,0xff,0xe0,0,16,74,70]]
        for bytes in cases {
            try Data(bytes).write(to:file)
            XCTAssertThrowsError(try VisionHostPrep.decode(file))
        }
    }
}
