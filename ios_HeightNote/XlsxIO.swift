import Foundation
import Compression

// MARK: - 错误定义

enum XlsxError: LocalizedError {
    case badZip
    case badSheet
    case noRows

    var errorDescription: String? {
        switch self {
        case .badZip: return "文件不是有效的 Excel(.xlsx) 文件"
        case .badSheet: return "文件里找不到工作表数据"
        case .noRows: return "表格里没有可识别的数据行（需要 number,x,y,z 四列）"
        }
    }
}

// MARK: - CRC32（zip 校验用）

enum CRC32 {
    static let table: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFFFFFF
    }
}

// MARK: - 极简 ZIP 写入（store 模式，不压缩）

struct ZipWriter {
    private(set) var data = Data()
    private var centralDirectory: Data = Data()
    private var entries: [(name: String, crc: UInt32, size: UInt32, offset: UInt32)] = []

    mutating func addFile(name: String, contents: Data) {
        let offset = UInt32(data.count)
        let crc = CRC32.checksum(contents)
        let size = UInt32(contents.count)
        let nameBytes = Data(name.utf8)

        var header = Data()
        header.appendLE(UInt32(0x04034b50))   // local file header 签名
        header.appendLE(UInt16(20))           // 需要的版本
        header.appendLE(UInt16(0))            // flags
        header.appendLE(UInt16(0))            // 压缩方式：store
        header.appendLE(UInt16(0))            // 时间
        header.appendLE(UInt16(0x4A21))       // 日期 2020-01-01
        header.appendLE(crc)
        header.appendLE(size)                 // 压缩后大小
        header.appendLE(size)                 // 原始大小
        header.appendLE(UInt16(nameBytes.count))
        header.appendLE(UInt16(0))            // extra 长度
        data.append(header)
        data.append(nameBytes)
        data.append(contents)

        entries.append((name, crc, size, offset))
    }

    mutating func finalize() -> Data {
        let centralStart = UInt32(data.count)
        for e in entries {
            var cd = Data()
            cd.appendLE(UInt32(0x02014b50))   // central directory 签名
            cd.appendLE(UInt16(20))           // 制作版本
            cd.appendLE(UInt16(20))           // 需要的版本
            cd.appendLE(UInt16(0))            // flags
            cd.appendLE(UInt16(0))            // 压缩方式
            cd.appendLE(UInt16(0))            // 时间
            cd.appendLE(UInt16(0x4A21))       // 日期
            cd.appendLE(e.crc)
            cd.appendLE(e.size)
            cd.appendLE(e.size)
            cd.appendLE(UInt16(e.name.utf8.count))
            cd.appendLE(UInt16(0))            // extra
            cd.appendLE(UInt16(0))            // comment
            cd.appendLE(UInt16(0))            // 起始磁盘
            cd.appendLE(UInt16(0))            // 内部属性
            cd.appendLE(UInt32(0))            // 外部属性
            cd.appendLE(e.offset)
            cd.append(Data(e.name.utf8))
            centralDirectory.append(cd)
        }
        data.append(centralDirectory)

        var eocd = Data()
        eocd.appendLE(UInt32(0x06054b50))     // EOCD 签名
        eocd.appendLE(UInt16(0))
        eocd.appendLE(UInt16(0))
        eocd.appendLE(UInt16(entries.count))
        eocd.appendLE(UInt16(entries.count))
        eocd.appendLE(UInt32(centralDirectory.count))
        eocd.appendLE(centralStart)
        eocd.appendLE(UInt16(0))
        data.append(eocd)
        return data
    }
}

private extension Data {
    mutating func appendLE(_ v: UInt16) {
        append(UInt8(v & 0xFF))
        append(UInt8(v >> 8))
    }

    mutating func appendLE(_ v: UInt32) {
        append(UInt8(v & 0xFF))
        append(UInt8((v >> 8) & 0xFF))
        append(UInt8((v >> 16) & 0xFF))
        append(UInt8(v >> 24))
    }
}

// MARK: - ZIP 读取（支持 store 和 deflate）

enum ZipReader {
    static func entries(in data: Data) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let bytes = [UInt8](data)
        guard bytes.count > 4 else { throw XlsxError.badZip }

        func u16(_ o: Int) -> Int { Int(bytes[o]) | (Int(bytes[o + 1]) << 8) }
        func u32(_ o: Int) -> Int { u16(o) | (u16(o + 2) << 16) }

        var offset = 0
        while offset + 4 <= bytes.count {
            // 遇到中央目录（或非法数据）就停止
            if u32(offset) != 0x04034b50 { break }
            let method = u16(offset + 8)
            let compSize = u32(offset + 18)
            let uncompSize = u32(offset + 22)
            let nameLen = u16(offset + 26)
            let extraLen = u16(offset + 28)
            let nameStart = offset + 30
            guard nameStart + nameLen <= bytes.count else { break }
            let name = String(bytes: bytes[nameStart..<(nameStart + nameLen)], encoding: .utf8) ?? ""
            let dataStart = nameStart + nameLen + extraLen
            guard dataStart + compSize <= bytes.count else { break }
            let payload = data.subdata(in: dataStart..<(dataStart + compSize))

            let content: Data
            if method == 0 {
                content = payload
            } else if method == 8 {
                guard let inflated = inflate(payload, uncompressedSize: uncompSize) else {
                    throw XlsxError.badZip
                }
                content = inflated
            } else {
                throw XlsxError.badZip
            }
            result[name] = content
            offset = dataStart + compSize
        }
        if result.isEmpty { throw XlsxError.badZip }
        return result
    }

    /// zip 里的 deflate 是原始 deflate 流，用 Compression 的 ZLIB 解
    private static func inflate(_ data: Data, uncompressedSize: Int) -> Data? {
        guard uncompressedSize > 0 else { return Data() }
        var output = Data(count: uncompressedSize)
        let written = data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
            output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
                compression_decode_buffer(
                    dst.bindMemory(to: UInt8.self).baseAddress!, uncompressedSize,
                    src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard written == uncompressedSize else { return nil }
        return output
    }
}

// MARK: - .xlsx 生成

enum XlsxWriter {
    /// 固定格式：number, x, y, z（带表头）；有参考时附"相对高差""绝对标高"两列
    static func workbookData(points: [MarkedPoint],
                             referenceID: UUID? = nil,
                             referenceValue: Float? = nil) -> Data {
        var rows: [[String]] = [["number", "x", "y", "z", "相对高差", "绝对标高"]]
        if let base = points.first {
            for p in points {
                let relDiff = String(format: "%.4f", p.heightRelativeTo(base))
                let absolute = ElevationFormatter
                    .absoluteElevation(of: p, points: points,
                                       referenceID: referenceID,
                                       referenceValue: referenceValue)
                    .map { String(format: "%.4f", $0) } ?? ""
                rows.append([
                    String(p.index),
                    String(format: "%.4f", p.position[0]),
                    String(format: "%.4f", p.position[1]),
                    String(format: "%.4f", p.position[2]),
                    relDiff,
                    absolute,
                ])
            }
        }
        return workbookData(rows: rows)
    }

    static func workbookData(rows: [[String]]) -> Data {
        var sheet = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>

        """
        for (ri, row) in rows.enumerated() {
            sheet += "<row r=\"\(ri + 1)\">"
            for (ci, value) in row.enumerated() {
                let ref = columnLetter(ci) + String(ri + 1)
                if let d = Double(value), value.range(of: "^[0-9.\\-+eE]+$", options: .regularExpression) != nil {
                    sheet += "<c r=\"\(ref)\"><v>\(d)</v></c>"
                } else {
                    let escaped = value
                        .replacingOccurrences(of: "&", with: "&amp;")
                        .replacingOccurrences(of: "<", with: "&lt;")
                    sheet += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t>\(escaped)</t></is></c>"
                }
            }
            sheet += "</row>"
        }
        sheet += "</sheetData></worksheet>"

        let contentTypes = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/><Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/></Types>
        """

        let rootRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """

        let workbook = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="HeightNote" sheetId="1" r:id="rId1"/></sheets></workbook>
        """

        let workbookRels = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles" Target="styles.xml"/></Relationships>
        """

        let styles = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><fonts count="1"><font><sz val="11"/><name val="Calibri"/></font></fonts><fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills><borders count="1"><border/></borders><cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs><cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs></styleSheet>
        """

        var zip = ZipWriter()
        zip.addFile(name: "[Content_Types].xml", contents: Data(contentTypes.utf8))
        zip.addFile(name: "_rels/.rels", contents: Data(rootRels.utf8))
        zip.addFile(name: "xl/workbook.xml", contents: Data(workbook.utf8))
        zip.addFile(name: "xl/_rels/workbook.xml.rels", contents: Data(workbookRels.utf8))
        zip.addFile(name: "xl/styles.xml", contents: Data(styles.utf8))
        zip.addFile(name: "xl/worksheets/sheet1.xml", contents: Data(sheet.utf8))
        return zip.finalize()
    }

    /// 0→A, 1→B, 26→AA …
    static func columnLetter(_ i: Int) -> String {
        var s = ""
        var n = i
        while n >= 0 {
            s = String(UnicodeScalar(65 + n % 26)!) + s
            n = n / 26 - 1
        }
        return s
    }
}

// MARK: - .xlsx 解析

/// 解析 xl/sharedStrings.xml（别的软件导出的 xlsx 常把文字放在这里）
final class SharedStringsParser: NSObject, XMLParserDelegate {
    private var strings: [String] = []
    private var current = ""
    private var inText = false

    static func parse(_ data: Data) -> [String] {
        let parser = SharedStringsParser()
        let p = XMLParser(data: data)
        p.delegate = parser
        p.parse()
        return parser.strings
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if name == "si" { current = "" }
        if name == "t" { inText = true }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if inText { current += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        if name == "t" { inText = false }
        if name == "si" { strings.append(current) }
    }
}

/// 解析 worksheet 的行/单元格
final class SheetParser: NSObject, XMLParserDelegate {
    private var rows: [[String]] = []
    private var currentRow: [String]?
    private var cellType = ""        // "" 数字 / "s" 共享字符串 / "inlineStr"
    private var cellText = ""
    private var collecting = false
    private let sharedStrings: [String]

    init(sharedStrings: [String]) { self.sharedStrings = sharedStrings }

    static func parse(_ data: Data, sharedStrings: [String]) -> [[String]] {
        let parser = SheetParser(sharedStrings: sharedStrings)
        let p = XMLParser(data: data)
        p.delegate = parser
        p.parse()
        return parser.rows
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                qualifiedName: String?, attributes attrs: [String: String]) {
        switch name {
        case "row":
            currentRow = []
        case "c":
            cellType = attrs["t"] ?? ""
            cellText = ""
        case "v", "t":
            collecting = true
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if collecting { cellText += string }
    }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                qualifiedName: String?) {
        switch name {
        case "v", "t":
            collecting = false
        case "c":
            var value = cellText
            if cellType == "s", let idx = Int(cellText), idx < sharedStrings.count {
                value = sharedStrings[idx]
            }
            currentRow?.append(value)
        case "row":
            if let row = currentRow {
                rows.append(row)
            }
            currentRow = nil
        default:
            break
        }
    }
}

// MARK: - 对外的导入接口

enum XlsxIO {
    /// 从 .xlsx 数据里读出测量点（自动跳过表头行）
    static func readPoints(from data: Data) throws -> [MarkedPoint] {
        let files = try ZipReader.entries(in: data)

        var shared: [String] = []
        if let ss = files["xl/sharedStrings.xml"] {
            shared = SharedStringsParser.parse(ss)
        }

        guard let sheetName = files.keys.first(where: { $0.hasPrefix("xl/worksheets/sheet") })
        else { throw XlsxError.badSheet }
        let rows = SheetParser.parse(files[sheetName]!, sharedStrings: shared)
        guard !rows.isEmpty else { throw XlsxError.noRows }

        var points: [MarkedPoint] = []
        for (i, row) in rows.enumerated() {
            let cells = row.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            // 需要 number,x,y,z 四列；表头或格式不对的行直接跳过
            guard cells.count >= 4,
                  let x = Float(cells[1]),
                  let y = Float(cells[2]),
                  let z = Float(cells[3])
            else { continue }
            let index: Int
            if let d = Double(cells[0]), let n = Int(exactly: d.rounded()) {
                index = max(n, 1)
            } else {
                index = i + 1
            }
            points.append(MarkedPoint(index: index, position: [x, y, z]))
        }
        guard !points.isEmpty else { throw XlsxError.noRows }
        return points
    }
}
