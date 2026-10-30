import Foundation

/// 标高显示模式
enum ElevationMode: String, Codable {
    case relative   // 相对标高（相对第一个点的高差）
    case absolute   // 绝对标高（参考标高 + 高差）
}

/// 一个被标记的测量点
struct MarkedPoint: Codable, Identifiable, Equatable, Hashable {
    var id = UUID()
    var index: Int          // 序号（从 1 开始）
    var name: String?       // 自定义名字；nil 时显示 P{index}
    var position: [Float]   // AR 世界坐标 x/y/z（米）
    var timestamp = Date()

    /// 高度就是 y 坐标（AR 坐标系的 y 轴与重力对齐）
    var y: Float { position[1] }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return "P\(index)"
    }

    /// 相对基准点（第一个点）的高度差（米），正数=更高
    func heightRelativeTo(_ base: MarkedPoint) -> Float { y - base.y }
}

/// 一次测量会话：同一次打开相机时标记的所有点
struct MeasurementSession: Codable, Identifiable {
    var id = UUID()
    var name: String
    var createdAt = Date()
    var points: [MarkedPoint]
    var referencePointID: UUID?      // 参考点
    var referenceElevation: Float?   // 参考点的已知标高（米）

    /// 本组点中的最大高差（最高点 − 最低点）
    var maxHeightDiff: Float? {
        guard let base = points.first else { return nil }
        let heights = points.map { $0.heightRelativeTo(base) }
        guard let maxH = heights.max(), let minH = heights.min() else { return nil }
        return maxH - minH
    }
}

/// 标高文字换算（测量页和历史详情共用）
enum ElevationFormatter {
    /// 绝对标高 = 参考标高 + (该点 − 参考点) 的高差；没设置参考时返回 nil
    static func absoluteElevation(of point: MarkedPoint,
                                  points: [MarkedPoint],
                                  referenceID: UUID?,
                                  referenceValue: Float?) -> Float? {
        guard let referenceID, let referenceValue,
              let ref = points.first(where: { $0.id == referenceID })
        else { return nil }
        return referenceValue + (point.y - ref.y)
    }

    /// 点旁边显示的标高文字
    static func displayText(for point: MarkedPoint,
                            points: [MarkedPoint],
                            mode: ElevationMode,
                            referenceID: UUID?,
                            referenceValue: Float?) -> String {
        guard let base = points.first else { return "" }
        switch mode {
        case .relative:
            if point.id == base.id { return "基准" }
            return formatHeight(point.heightRelativeTo(base))
        case .absolute:
            guard let v = absoluteElevation(of: point, points: points,
                                            referenceID: referenceID,
                                            referenceValue: referenceValue)
            else { return "未设参考" }
            return String(format: "%.2f m", v)
        }
    }
}

/// 测量记录的存取：保存到沙盒的 JSON 文件，App 重启后仍在
final class PointStore: ObservableObject {
    @Published private(set) var sessions: [MeasurementSession] = []

    private let fileURL: URL

    init() {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        fileURL = dir.appendingPathComponent("heightnote_sessions.json")
        load()
    }

    static func defaultSessionName() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: Date())
    }

    func save(_ points: [MarkedPoint],
              name: String,
              referenceID: UUID?,
              referenceValue: Float?) {
        guard !points.isEmpty else { return }
        let sessionName = name.isEmpty ? Self.defaultSessionName() : name
        sessions.insert(
            MeasurementSession(name: sessionName,
                               points: points,
                               referencePointID: referenceID,
                               referenceElevation: referenceValue),
            at: 0
        )
        persist()
    }

    /// 导入 Excel 后生成一条记录
    func importSession(name: String, points: [MarkedPoint]) {
        sessions.insert(
            MeasurementSession(name: name, points: points,
                               referencePointID: nil, referenceElevation: nil),
            at: 0
        )
        persist()
    }

    /// 更新某条记录的参考点/参考标高（导入的记录也可以设置参考了）
    func updateReference(sessionID: UUID, referenceID: UUID?, referenceValue: Float?) {
        guard let i = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        sessions[i].referencePointID = referenceID
        sessions[i].referenceElevation = referenceValue
        persist()
    }

    func delete(_ session: MeasurementSession) {
        sessions.removeAll { $0.id == session.id }
        persist()
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([MeasurementSession].self, from: data)
        else { return }
        sessions = decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(sessions) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}

// MARK: - 显示用的格式化

func formatHeight(_ meters: Float) -> String {
    String(format: "%+.2f m", meters)
}

/// 用一句话描述两点高低关系，如 “窗台 比 P1 高 0.35 米”
func heightSentence(_ a: MarkedPoint, _ b: MarkedPoint) -> String {
    let diff = b.y - a.y
    if diff >= 0 {
        return "\(b.displayName) 比 \(a.displayName) 高 \(String(format: "%.2f", diff)) 米"
    } else {
        return "\(b.displayName) 比 \(a.displayName) 低 \(String(format: "%.2f", -diff)) 米"
    }
}
