import Foundation
import Darwin
import Testing
@testable import QuadFinder

struct TextFileCoreTests {
    @Test func decodesUnicodeBOMsAndRoundTrips() throws {
        let text = "日本語\nsecond"
        for encoding in [TextFileEncoding.utf8BOM, .utf16LittleEndian, .utf16BigEndian,
                         .utf32LittleEndian, .utf32BigEndian] {
            let bytes = try TextFileCodec.encode(text, encoding: encoding, newline: .crlf)
            let decoded = try TextFileCodec.decode(bytes)
            #expect(decoded.text == text)
            #expect(decoded.encoding == encoding)
            #expect(decoded.newlines.style == .crlf)
            #expect(try TextFileCodec.encode(decoded.text, encoding: decoded.encoding,
                                             newline: decoded.newlines.preferredStyle) == bytes)
        }
    }

    @Test func detectsUTF8WithoutBOM() throws {
        let data = Data("plain café 日本語".utf8)
        let result = try TextFileCodec.decode(data)
        #expect(result.encoding == .utf8)
        #expect(result.text == "plain café 日本語")
    }

    @Test func legacyJapaneseEncodingsRoundTrip() throws {
        let text = "日本語のテキスト"
        for encoding in [TextFileEncoding.shiftJIS, .eucJP, .iso2022JP] {
            let data = try TextFileCodec.encode(text, encoding: encoding, newline: .lf)
            let decoded = try TextFileCodec.decode(data)
            #expect(decoded.encoding == encoding)
            #expect(decoded.text == text)
            #expect(try TextFileCodec.encode(decoded.text, encoding: encoding,
                                             newline: .lf) == data)
        }
    }

    @Test func detectsBinaryWithoutMisclassifyingBOMUnicode() throws {
        #expect(TextFileCodec.isLikelyBinary(Data([0, 1, 2, 3, 4])))
        #expect(throws: TextFileDecodeError.binary) {
            try TextFileCodec.decode(Data([0, 1, 2, 3, 4]))
        }
        let utf16 = try TextFileCodec.encode("abc", encoding: .utf16LittleEndian, newline: .lf)
        #expect(!TextFileCodec.isLikelyBinary(utf16))
        #expect(try TextFileCodec.decode(utf16).text == "abc")
    }

    @Test func reportsMixedNewlinesAndNormalizesEditingText() throws {
        let decoded = try TextFileCodec.decode(Data("a\r\nb\nc\rd\r\n".utf8))
        #expect(decoded.text == "a\nb\nc\nd\n")
        #expect(decoded.newlines.style == .mixed)
        #expect(decoded.newlines.preferredStyle == .crlf)
        #expect(decoded.newlines.crlfCount == 2)
        #expect(decoded.newlines.lfCount == 1)
        #expect(decoded.newlines.crCount == 1)
    }

    @Test func streamingEncoderWritesChunksAndBOMOnce() throws {
        let url = temporaryURL()
        FileManager.default.createFile(atPath: url.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        try TextFileCodec.write(normalizedTextChunks: ["one\n", "two\n"],
                                encoding: .utf8BOM, newline: .crlf, to: handle)
        try handle.close()
        let decoded = try TextFileCodec.decode(Data(contentsOf: url))
        #expect(decoded.encoding == .utf8BOM)
        #expect(decoded.text == "one\ntwo\n")
        #expect(decoded.newlines.style == .crlf)
    }

    @Test func atomicWriterPreservesModeAndExtendedAttributes() throws {
        let url = temporaryURL()
        try Data("old".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(chmod(url.path, 0o640) == 0)
        let attribute = Data("metadata".utf8)
        attribute.withUnsafeBytes { bytes in
            #expect(setxattr(url.path, "com.quadfinder.test", bytes.baseAddress,
                             attribute.count, 0, 0) == 0)
        }
        let stamp = try ExternalFileStamp.capture(at: url)
        let newStamp = try SafeAtomicFileWriter.replaceItem(at: url, expectedStamp: stamp) { handle in
            try handle.write(contentsOf: Data("new value".utf8))
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "new value")
        #expect(newStamp.inode != stamp.inode)
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { fstatat(AT_FDCWD, $0, &info, 0) }
        #expect(status == 0)
        #expect(info.st_mode & 0o777 == 0o640)
        let size = getxattr(url.path, "com.quadfinder.test", nil, 0, 0, 0)
        #expect(size == attribute.count)
    }

    @Test func atomicWriterRejectsExternalModificationAndLeavesItUntouched() throws {
        let url = temporaryURL()
        try Data("original".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let stamp = try ExternalFileStamp.capture(at: url)
        try Data("external edit".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(2)],
                                              ofItemAtPath: url.path)
        #expect(throws: SafeTextSaveError.self) {
            try SafeAtomicFileWriter.replaceItem(at: url, expectedStamp: stamp) { handle in
                try handle.write(contentsOf: Data("editor edit".utf8))
            }
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == "external edit")
    }

    @Test func externalStateDistinguishesModificationReplacementAndDeletion() throws {
        let url = temporaryURL()
        try Data("one".utf8).write(to: url)
        let first = try ExternalFileStamp.capture(at: url)
        #expect(ExternalFileState.compare(expected: first, url: url) == .unchanged)
        try Data("longer".utf8).write(to: url)
        if case .modified = ExternalFileState.compare(expected: first, url: url) {} else {
            Issue.record("Expected same-inode modification")
        }
        try FileManager.default.removeItem(at: url)
        try Data("replacement".utf8).write(to: url)
        if case .replaced = ExternalFileState.compare(expected: first, url: url) {} else {
            Issue.record("Expected inode replacement")
        }
        try FileManager.default.removeItem(at: url)
        #expect(ExternalFileState.compare(expected: first, url: url) == .deleted)
    }

    private func temporaryURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("QuadFinder-\(UUID().uuidString)")
    }
}
