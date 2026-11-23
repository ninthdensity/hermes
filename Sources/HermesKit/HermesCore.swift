import CHermesCore
import Foundation

public struct HermesCoreError: LocalizedError, Equatable {
    public let message: String
    public var errorDescription: String? { message }
}

/// Swift face of the Rust document core.
public enum HermesCore {
    public static func decodeFile(_ data: Data) throws -> DocumentModel {
        let json = try call(data, hermes_decode_file)
        return try JSONDecoder().decode(DocumentModel.self, from: json)
    }

    public static func encodeFile(_ model: DocumentModel) throws -> Data {
        try call(try encodeInterchange(model), hermes_encode_file)
    }

    public static func decodeMarkdown(_ data: Data) throws -> DocumentModel? {
        let json = try call(data, hermes_decode_markdown)
        return try JSONDecoder().decode(DocumentModel?.self, from: json)
    }

    public static func encodeMarkdown(_ model: DocumentModel) throws -> Data {
        try call(try encodeInterchange(model), hermes_encode_markdown)
    }

    public static func plainText(_ model: DocumentModel) throws -> String {
        String(decoding: try call(try encodeInterchange(model), hermes_plain_text), as: UTF8.self)
    }

    public static func wordCount(_ text: String) -> Int {
        var text = text
        return text.withUTF8 { Int(hermes_word_count($0.baseAddress, $0.count)) }
    }

    /// Encodes `DocumentModel` directly to compact UTF-8 JSON, omitting default values so
    /// both Swift serialization and Rust parsing avoid reflection and redundant bytes.
    static func encodeInterchange(_ model: DocumentModel) throws -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(64 + model.blocks.count * 80)
        bytes.append(contentsOf: #"{"appearance":""#.utf8)
        bytes.append(contentsOf: model.appearance.rawValue.utf8)
        bytes.append(contentsOf: #"","blocks":["#.utf8)
        for (blockIndex, block) in model.blocks.enumerated() {
            if blockIndex > 0 { bytes.append(0x2C) } // ,
            bytes.append(0x7B) // {
            var needsComma = false
            if block.style != .body {
                bytes.append(contentsOf: #""style":""#.utf8)
                bytes.append(contentsOf: block.style.rawValue.utf8)
                bytes.append(0x22)
                needsComma = true
            }
            if let list = block.list {
                if needsComma { bytes.append(0x2C) }
                bytes.append(contentsOf: #""list":""#.utf8)
                bytes.append(contentsOf: list.rawValue.utf8)
                bytes.append(0x22)
                needsComma = true
            }
            if block.alignment != .left {
                if needsComma { bytes.append(0x2C) }
                bytes.append(contentsOf: #""alignment":""#.utf8)
                bytes.append(contentsOf: block.alignment.rawValue.utf8)
                bytes.append(0x22)
                needsComma = true
            }
            if let lineHeight = block.lineHeight {
                guard lineHeight.isFinite else { throw HermesCoreError(message: "Invalid line height value.") }
                if needsComma { bytes.append(0x2C) }
                bytes.append(contentsOf: #""lineHeight":"#.utf8)
                bytes.append(contentsOf: String(lineHeight).utf8)
                needsComma = true
            }
            if !block.runs.isEmpty {
                if needsComma { bytes.append(0x2C) }
                bytes.append(contentsOf: #""runs":["#.utf8)
                for (runIndex, run) in block.runs.enumerated() {
                    if runIndex > 0 { bytes.append(0x2C) }
                    bytes.append(contentsOf: #"{"text":"#.utf8)
                    appendJSONString(run.text, to: &bytes)
                    if run.bold { bytes.append(contentsOf: #","bold":true"#.utf8) }
                    if run.italic { bytes.append(contentsOf: #","italic":true"#.utf8) }
                    if run.underline { bytes.append(contentsOf: #","underline":true"#.utf8) }
                    if run.strikethrough { bytes.append(contentsOf: #","strikethrough":true"#.utf8) }
                    if run.code { bytes.append(contentsOf: #","code":true"#.utf8) }
                    if let link = run.link {
                        bytes.append(contentsOf: #","link":"#.utf8)
                        appendJSONString(link, to: &bytes)
                    }
                    if let fontSize = run.fontSize {
                        bytes.append(contentsOf: #","fontSize":"#.utf8)
                        bytes.append(contentsOf: String(fontSize).utf8)
                    }
                    if let spacing = run.letterSpacing {
                        guard spacing.isFinite else { throw HermesCoreError(message: "Invalid letter spacing value.") }
                        bytes.append(contentsOf: #","letterSpacing":"#.utf8)
                        bytes.append(contentsOf: String(spacing).utf8)
                    }
                    bytes.append(0x7D) // }
                }
                bytes.append(0x5D) // ]
            }
            bytes.append(0x7D) // }
        }
        bytes.append(contentsOf: "]}" .utf8)
        return Data(bytes)
    }

    private static func appendJSONString(_ string: String, to out: inout [UInt8]) {
        out.append(0x22) // "
        var string = string
        string.withUTF8 { utf8 in
            var start = 0
            let count = utf8.count
            for i in 0..<count {
                let byte = utf8[i]
                if byte == 0x22 || byte == 0x5C || byte < 0x20 {
                    if i > start {
                        out.append(contentsOf: utf8[start..<i])
                    }
                    switch byte {
                    case 0x22: out.append(contentsOf: [0x5C, 0x22]) // \"
                    case 0x5C: out.append(contentsOf: [0x5C, 0x5C]) // \\
                    case 0x08: out.append(contentsOf: [0x5C, 0x62]) // \b
                    case 0x0C: out.append(contentsOf: [0x5C, 0x66]) // \f
                    case 0x0A: out.append(contentsOf: [0x5C, 0x6E]) // \n
                    case 0x0D: out.append(contentsOf: [0x5C, 0x72]) // \r
                    case 0x09: out.append(contentsOf: [0x5C, 0x74]) // \t
                    default:
                        let hex: [UInt8] = [0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37,
                                            0x38, 0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66]
                        out.append(contentsOf: [0x5C, 0x75, 0x30, 0x30, hex[Int(byte >> 4)], hex[Int(byte & 0x0F)]])
                    }
                    start = i + 1
                }
            }
            if start < count {
                out.append(contentsOf: utf8[start..<count])
            }
        }
        out.append(0x22) // "
    }

    private static func call(
        _ input: Data,
        _ fn: (UnsafePointer<UInt8>?, Int) -> HermesBuffer
    ) throws -> Data {
        let buffer = input.withUnsafeBytes { raw in
            fn(raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        defer { hermes_buffer_free(buffer) }
        let bytes = buffer.ptr.map { Data(bytes: $0, count: buffer.len) } ?? Data()
        guard buffer.ok else {
            throw HermesCoreError(message: String(decoding: bytes, as: UTF8.self))
        }
        return bytes
    }
}
