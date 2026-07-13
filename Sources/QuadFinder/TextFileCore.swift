import Foundation
import Darwin

enum TextFileEncoding: String, CaseIterable, Codable, Sendable {
    case utf8, utf8BOM
    case utf16LittleEndian, utf16BigEndian
    case utf32LittleEndian, utf32BigEndian
    case shiftJIS, eucJP, iso2022JP

    var displayName: String {
        switch self {
        case .utf8: "UTF-8"
        case .utf8BOM: "UTF-8 (BOM)"
        case .utf16LittleEndian: "UTF-16 LE"
        case .utf16BigEndian: "UTF-16 BE"
        case .utf32LittleEndian: "UTF-32 LE"
        case .utf32BigEndian: "UTF-32 BE"
        case .shiftJIS: "Shift_JIS"
        case .eucJP: "EUC-JP"
        case .iso2022JP: "ISO-2022-JP"
        }
    }

    fileprivate var foundationEncoding: String.Encoding {
        switch self {
        case .utf8, .utf8BOM: .utf8
        case .utf16LittleEndian: .utf16LittleEndian
        case .utf16BigEndian: .utf16BigEndian
        case .utf32LittleEndian: .utf32LittleEndian
        case .utf32BigEndian: .utf32BigEndian
        case .shiftJIS: .shiftJIS
        case .eucJP: .japaneseEUC
        case .iso2022JP: .iso2022JP
        }
    }

    fileprivate var bom: Data {
        switch self {
        case .utf8BOM: Data([0xEF, 0xBB, 0xBF])
        case .utf16LittleEndian: Data([0xFF, 0xFE])
        case .utf16BigEndian: Data([0xFE, 0xFF])
        case .utf32LittleEndian: Data([0xFF, 0xFE, 0x00, 0x00])
        case .utf32BigEndian: Data([0x00, 0x00, 0xFE, 0xFF])
        default: Data()
        }
    }
}

enum TextNewlineStyle: String, Codable, Sendable {
    case none, lf, crlf, cr, mixed
}

struct TextNewlineInfo: Equatable, Codable, Sendable {
    let style: TextNewlineStyle
    let preferredStyle: TextNewlineStyle
    let lfCount: Int
    let crlfCount: Int
    let crCount: Int
}

struct DecodedTextFile: Equatable, Sendable {
    /// Newlines are normalized to LF. `newlines.preferredStyle` is used when saving.
    let text: String
    let encoding: TextFileEncoding
    let newlines: TextNewlineInfo
}

enum TextFileDecodeError: Error, Equatable {
    case binary
    case undecodable
}

enum TextFileCodec {
    static func decode(_ data: Data) throws -> DecodedTextFile {
        guard !data.isEmpty else {
            return DecodedTextFile(text: "", encoding: .utf8,
                                   newlines: newlineInfo(in: ""))
        }
        // BOM Unicode and ISO-2022-JP legitimately contain NUL/ESC controls. For
        // all other BOM-less input, reject binary controls before accepting the
        // bytes as technically valid UTF-8 control scalars.
        let protectedTextEncoding = detectUnicodeBOM(data) ??
            (containsISO2022Escape(data) && canDecode(data, as: .iso2022JP) ? .iso2022JP : nil)
        if protectedTextEncoding == nil, isLikelyBinary(data) { throw TextFileDecodeError.binary }
        let encoding = protectedTextEncoding ?? detectEncoding(data)
        guard let encoding,
              let decoded = String(data: stripBOM(data, for: encoding),
                                   encoding: encoding.foundationEncoding) else {
            throw isLikelyBinary(data) ? TextFileDecodeError.binary : TextFileDecodeError.undecodable
        }
        let info = newlineInfo(in: decoded)
        return DecodedTextFile(text: normalizeNewlines(decoded), encoding: encoding,
                               newlines: info)
    }

    static func detectEncoding(_ data: Data) -> TextFileEncoding? {
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return .utf32BigEndian }
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return .utf32LittleEndian }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8BOM }
        if data.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        if data.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        if containsISO2022Escape(data), canDecode(data, as: .iso2022JP) { return .iso2022JP }
        if strictRoundTrip(data, as: .utf8) { return .utf8 }
        if looksLikeEUCJP(data), canDecode(data, as: .eucJP) { return .eucJP }
        if looksLikeShiftJIS(data), canDecode(data, as: .shiftJIS) { return .shiftJIS }
        return nil
    }

    static func isLikelyBinary(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        if detectUnicodeBOM(data) != nil { return false }
        let sample = data.prefix(64 * 1_024)
        if sample.contains(0) { return true }
        let controls = sample.reduce(into: 0) { count, byte in
            if byte < 0x20 && byte != 0x09 && byte != 0x0A && byte != 0x0C && byte != 0x0D && byte != 0x1B {
                count += 1
            }
        }
        return controls * 100 > sample.count * 10
    }

    static func encode(_ normalizedText: String, encoding: TextFileEncoding,
                       newline: TextNewlineStyle) throws -> Data {
        var result = encoding.bom
        let output = applyingNewline(newline, to: normalizedText)
        guard let body = output.data(using: encoding.foundationEncoding,
                                     allowLossyConversion: false) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        result.append(body)
        return result
    }

    /// Streams normalized-LF text without constructing a second full-file String.
    static func write<S: Sequence>(normalizedTextChunks: S, encoding: TextFileEncoding,
                                   newline: TextNewlineStyle, to handle: FileHandle) throws
    where S.Element == String {
        if !encoding.bom.isEmpty { try handle.write(contentsOf: encoding.bom) }
        for chunk in normalizedTextChunks {
            let output = applyingNewline(newline, to: chunk)
            guard let bytes = output.data(using: encoding.foundationEncoding,
                                          allowLossyConversion: false) else {
                throw CocoaError(.fileWriteInapplicableStringEncoding)
            }
            try handle.write(contentsOf: bytes)
        }
    }

    private static func detectUnicodeBOM(_ data: Data) -> TextFileEncoding? {
        if data.starts(with: [0x00, 0x00, 0xFE, 0xFF]) { return .utf32BigEndian }
        if data.starts(with: [0xFF, 0xFE, 0x00, 0x00]) { return .utf32LittleEndian }
        if data.starts(with: [0xEF, 0xBB, 0xBF]) { return .utf8BOM }
        if data.starts(with: [0xFE, 0xFF]) { return .utf16BigEndian }
        if data.starts(with: [0xFF, 0xFE]) { return .utf16LittleEndian }
        return nil
    }

    private static func stripBOM(_ data: Data, for encoding: TextFileEncoding) -> Data {
        let count = encoding.bom.count
        return count > 0 && data.starts(with: encoding.bom) ? data.dropFirst(count) : data
    }

    private static func strictRoundTrip(_ data: Data, as encoding: String.Encoding) -> Bool {
        guard let string = String(data: data, encoding: encoding),
              let encoded = string.data(using: encoding, allowLossyConversion: false) else { return false }
        return encoded == data
    }

    private static func canDecode(_ data: Data, as encoding: TextFileEncoding) -> Bool {
        String(data: data, encoding: encoding.foundationEncoding) != nil
    }

    private static func containsISO2022Escape(_ data: Data) -> Bool {
        let signatures: [[UInt8]] = [[0x1B, 0x24, 0x40], [0x1B, 0x24, 0x42],
                                     [0x1B, 0x28, 0x42], [0x1B, 0x28, 0x4A],
                                     [0x1B, 0x28, 0x49]]
        return signatures.contains { data.range(of: Data($0)) != nil }
    }

    private static func looksLikeEUCJP(_ data: Data) -> Bool {
        let bytes = Array(data); var i = 0; var found = false
        while i < bytes.count {
            let byte = bytes[i]
            if byte < 0x80 { i += 1; continue }
            if byte == 0x8E, i + 1 < bytes.count, (0xA1...0xDF).contains(bytes[i + 1]) {
                found = true; i += 2; continue
            }
            if byte == 0x8F, i + 2 < bytes.count,
               (0xA1...0xFE).contains(bytes[i + 1]), (0xA1...0xFE).contains(bytes[i + 2]) {
                found = true; i += 3; continue
            }
            if (0xA1...0xFE).contains(byte), i + 1 < bytes.count,
               (0xA1...0xFE).contains(bytes[i + 1]) { found = true; i += 2; continue }
            return false
        }
        return found
    }

    private static func looksLikeShiftJIS(_ data: Data) -> Bool {
        let bytes = Array(data); var i = 0; var found = false
        while i < bytes.count {
            let byte = bytes[i]
            if byte < 0x80 || (0xA1...0xDF).contains(byte) { i += 1; continue }
            if ((0x81...0x9F).contains(byte) || (0xE0...0xFC).contains(byte)), i + 1 < bytes.count {
                let trail = bytes[i + 1]
                if (0x40...0x7E).contains(trail) || (0x80...0xFC).contains(trail) {
                    found = true; i += 2; continue
                }
            }
            return false
        }
        return found
    }

    private static func newlineInfo(in text: String) -> TextNewlineInfo {
        let bytes = Array(text.utf8); var lf = 0; var crlf = 0; var cr = 0; var i = 0
        while i < bytes.count {
            if bytes[i] == 0x0D {
                if i + 1 < bytes.count, bytes[i + 1] == 0x0A { crlf += 1; i += 2 }
                else { cr += 1; i += 1 }
            } else if bytes[i] == 0x0A { lf += 1; i += 1 }
            else { i += 1 }
        }
        let nonzero = [lf, crlf, cr].filter { $0 > 0 }.count
        let style: TextNewlineStyle = nonzero == 0 ? .none : nonzero > 1 ? .mixed :
            (crlf > 0 ? .crlf : cr > 0 ? .cr : .lf)
        let preferred: TextNewlineStyle
        if crlf >= lf && crlf >= cr && crlf > 0 { preferred = .crlf }
        else if cr >= lf && cr > 0 { preferred = .cr }
        else { preferred = lf > 0 ? .lf : .none }
        return TextNewlineInfo(style: style, preferredStyle: preferred,
                               lfCount: lf, crlfCount: crlf, crCount: cr)
    }

    private static func normalizeNewlines(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func applyingNewline(_ style: TextNewlineStyle, to text: String) -> String {
        switch style {
        case .crlf: text.replacingOccurrences(of: "\n", with: "\r\n")
        case .cr: text.replacingOccurrences(of: "\n", with: "\r")
        case .none, .lf, .mixed: text
        }
    }
}

struct ExternalFileStamp: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let size: UInt64
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64

    static func capture(at url: URL) throws -> Self {
        var info = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            fstatat(AT_FDCWD, path, &info, 0)
        }
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return Self(device: UInt64(info.st_dev), inode: UInt64(info.st_ino),
                    size: UInt64(info.st_size),
                    modificationSeconds: Int64(info.st_mtimespec.tv_sec),
                    modificationNanoseconds: Int64(info.st_mtimespec.tv_nsec))
    }
}

enum ExternalFileState: Equatable, Sendable {
    case unchanged
    case modified(ExternalFileStamp)
    case replaced(ExternalFileStamp)
    case deleted
    case inaccessible(Int32)

    static func compare(expected: ExternalFileStamp, url: URL) -> Self {
        do {
            let current = try ExternalFileStamp.capture(at: url)
            if current == expected { return .unchanged }
            if current.device != expected.device || current.inode != expected.inode { return .replaced(current) }
            return .modified(current)
        } catch let error as NSError where error.domain == NSPOSIXErrorDomain {
            return error.code == Int(ENOENT) ? .deleted : .inaccessible(Int32(error.code))
        } catch {
            return .inaccessible(EIO)
        }
    }
}

enum SafeTextSaveError: Error, Equatable {
    case externalConflict(ExternalFileState)
    case unsupportedFileType
}

enum SafeAtomicFileWriter {
    /// The writer is called with a same-directory temporary file. It may emit data in arbitrary chunks.
    @discardableResult
    static func replaceItem(at destination: URL, expectedStamp: ExternalFileStamp? = nil,
                            writer: (FileHandle) throws -> Void) throws -> ExternalFileStamp {
        if let expectedStamp {
            let state = ExternalFileState.compare(expected: expectedStamp, url: destination)
            guard state == .unchanged else { throw SafeTextSaveError.externalConflict(state) }
        }
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: destination.path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw SafeTextSaveError.unsupportedFileType
        }
        let originalStat = try posixStat(destination)
        let xattrs = readExtendedAttributes(destination)
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).quadfinder-\(UUID().uuidString).tmp")
        guard manager.createFile(atPath: temporary.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var shouldRemoveTemporary = true
        defer { if shouldRemoveTemporary { try? manager.removeItem(at: temporary) } }

        let handle = try FileHandle(forWritingTo: temporary)
        do {
            try writer(handle)
            try handle.synchronize()
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        guard chmod(temporary.path, originalStat.st_mode & 0o7777) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        // Ownership preservation is possible for owners/privileged callers. Failure is harmless:
        // the temp file is already owned by the saving user.
        _ = chown(temporary.path, originalStat.st_uid, originalStat.st_gid)
        writeExtendedAttributes(xattrs, to: temporary)

        if let expectedStamp {
            let state = ExternalFileState.compare(expected: expectedStamp, url: destination)
            guard state == .unchanged else { throw SafeTextSaveError.externalConflict(state) }
        }
        guard rename(temporary.path, destination.path) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        shouldRemoveTemporary = false
        return try ExternalFileStamp.capture(at: destination)
    }

    private static func posixStat(_ url: URL) throws -> stat {
        var value = stat()
        let status = url.withUnsafeFileSystemRepresentation { path in
            fstatat(AT_FDCWD, path, &value, 0)
        }
        guard status == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard (value.st_mode & S_IFMT) == S_IFREG else { throw SafeTextSaveError.unsupportedFileType }
        return value
    }

    private static func readExtendedAttributes(_ url: URL) -> [String: Data] {
        let length = listxattr(url.path, nil, 0, 0)
        guard length > 0 else { return [:] }
        var names = [CChar](repeating: 0, count: length)
        guard listxattr(url.path, &names, names.count, 0) == length else { return [:] }
        var result: [String: Data] = [:]
        var start = 0
        while start < names.count {
            let end = names[start...].firstIndex(of: 0) ?? names.count
            guard end > start else { start += 1; continue }
            let name = names[start..<end].map { UInt8(bitPattern: $0) }
            let string = String(decoding: name, as: UTF8.self)
            let size = getxattr(url.path, string, nil, 0, 0, 0)
            if size >= 0 {
                var bytes = Data(count: size)
                let read = bytes.withUnsafeMutableBytes { buffer in
                    getxattr(url.path, string, buffer.baseAddress, size, 0, 0)
                }
                if read == size { result[string] = bytes }
            }
            start = end + 1
        }
        return result
    }

    private static func writeExtendedAttributes(_ attributes: [String: Data], to url: URL) {
        for (name, data) in attributes {
            data.withUnsafeBytes { buffer in
                _ = setxattr(url.path, name, buffer.baseAddress, data.count, 0, 0)
            }
        }
    }
}
