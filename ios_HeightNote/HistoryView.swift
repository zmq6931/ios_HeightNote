import SwiftUI
import UniformTypeIdentifiers

/// 历史记录列表
struct HistoryView: View {
    @ObservedObject var store: PointStore
    @Environment(\.dismiss) private var dismiss

    @State private var showImporter = false
    @State private var importError: String?

    var body: some View {
        NavigationStack {
            Group {
                if store.sessions.isEmpty {
                    ContentUnavailableView(
                        "还没有测量记录",
                        systemImage: "tray",
                        description: Text("回到测量页标记几个点后点“保存”，或点右上角“导入”读入 Excel")
                    )
                } else {
                    List {
                        ForEach(store.sessions) { session in
                            NavigationLink {
                                SessionDetailView(store: store, session: session)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(session.name).font(.headline)
                                    Text(subtitle(for: session))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) {
                                    withAnimation { store.delete(session) }
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("历史记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showImporter = true
                    } label: {
                        Label("导入", systemImage: "square.and.arrow.up.on.square")
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: [UTType(filenameExtension: "xlsx") ?? .data],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result, let url = urls.first {
                    importExcel(from: url)
                }
            }
            .alert("导入失败", isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            )) {
                Button("好", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private func subtitle(for session: MeasurementSession) -> String {
        var text = "\(session.points.count) 个点"
        if let maxDiff = session.maxHeightDiff {
            text += " · 最大高差 \(String(format: "%.2f", maxDiff)) 米"
        }
        return text
    }

    private func importExcel(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            let points = try XlsxIO.readPoints(from: data)
            store.importSession(
                name: url.deletingPathExtension().lastPathComponent,
                points: points
            )
        } catch {
            importError = (error as? LocalizedError)?.errorDescription ?? "读取文件失败"
        }
    }
}

/// 单次测量记录的详情
struct SessionDetailView: View {
    @ObservedObject var store: PointStore
    @State private var session: MeasurementSession

    @State private var mode: ElevationMode = .relative
    @State private var idA: UUID
    @State private var idB: UUID

    // 参考标高编辑
    @State private var showRefEditor = false
    @State private var editingRefID: UUID?
    @State private var editingRefValue = ""

    init(store: PointStore, session: MeasurementSession) {
        self.store = store
        _session = State(initialValue: session)
        let points = session.points
        if points.count >= 2 {
            _idA = State(initialValue: points[points.count - 2].id)
            _idB = State(initialValue: points[points.count - 1].id)
        } else {
            _idA = State(initialValue: points.first?.id ?? UUID())
            _idB = State(initialValue: points.first?.id ?? UUID())
        }
    }

    private func elevationText(for point: MarkedPoint) -> String {
        ElevationFormatter.displayText(
            for: point, points: session.points, mode: mode,
            referenceID: session.referencePointID,
            referenceValue: session.referenceElevation
        )
    }

    var body: some View {
        List {
            Section {
                Picker("显示模式", selection: $mode) {
                    Text("相对标高").tag(ElevationMode.relative)
                    Text("绝对标高").tag(ElevationMode.absolute)
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
            }

            Section("各点标高") {
                ForEach(session.points) { point in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Circle()
                                .fill(Color(uiColor: MeasureSessionManager.markerColor(forIndex: point.index)))
                                .frame(width: 10, height: 10)
                            Text(point.displayName)
                            Spacer()
                            Text(elevationText(for: point))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        // 完整坐标（与 Excel 导出一致，y 才是高度方向）
                        Text("左右 x \(coordinateText(point.position[0]))   高度 y \(coordinateText(point.position[1]))   前后 z \(coordinateText(point.position[2]))")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                }
            }

            referenceSection

            if session.points.count >= 2 {
                Section("任选两点算高度差") {
                    Picker("点 A", selection: $idA) {
                        ForEach(session.points) { Text($0.displayName).tag($0.id) }
                    }
                    Picker("点 B", selection: $idB) {
                        ForEach(session.points) { Text($0.displayName).tag($0.id) }
                    }
                    if let a = point(idA), let b = point(idB), a.id != b.id {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(b.displayName) − \(a.displayName) = \(formatHeight(b.y - a.y))")
                                .font(.title3.bold().monospacedDigit())
                            Text(heightSentence(a, b))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
        }
        .navigationTitle(session.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    exportSession()
                } label: {
                    Label("导出", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    @ViewBuilder
    private var referenceSection: some View {
        Section("参考标高") {
            if let rid = session.referencePointID,
               let ref = session.points.first(where: { $0.id == rid }),
               let value = session.referenceElevation {
                LabeledContent("参考点", value: ref.displayName)
                LabeledContent("参考标高", value: String(format: "%.2f m", value))
            } else {
                Text("未设置（设置后可显示绝对标高）")
                    .foregroundStyle(.secondary)
            }
            Button {
                editingRefID = session.referencePointID ?? session.points.first?.id
                editingRefValue = session.referenceElevation.map { String(format: "%.2f", $0) } ?? ""
                showRefEditor = true
            } label: {
                Label(
                    (session.referencePointID == nil) ? "设置参考标高" : "修改参考标高",
                    systemImage: "slider.horizontal.2"
                )
            }
        }
        .sheet(isPresented: $showRefEditor) {
            SessionRefEditorView(
                points: session.points,
                refID: $editingRefID,
                valueText: $editingRefValue
            ) {
                let normalized = editingRefValue
                    .replacingOccurrences(of: ",", with: ".")
                    .replacingOccurrences(of: "，", with: ".")
                    .replacingOccurrences(of: "。", with: ".")
                if let id = editingRefID, let v = Float(normalized) {
                    store.updateReference(sessionID: session.id, referenceID: id, referenceValue: v)
                    session.referencePointID = id
                    session.referenceElevation = v
                    if mode == .relative { mode = .absolute }
                } else {
                    store.updateReference(sessionID: session.id, referenceID: nil, referenceValue: nil)
                    session.referencePointID = nil
                    session.referenceElevation = nil
                }
            }
        }
    }

    private func point(_ id: UUID) -> MarkedPoint? {
        session.points.first { $0.id == id }
    }

    /// 与 Excel 导出一致的 4 位小数格式
    private func coordinateText(_ value: Float) -> String {
        String(format: "%.4f", value)
    }

    private func exportSession() {
        let safeName = session.name.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName).xlsx")
        do {
            try XlsxWriter.workbookData(
                points: session.points,
                referenceID: session.referencePointID,
                referenceValue: session.referenceElevation
            ).write(to: url)
            ShareSheet.present(url)
        } catch {
            // 导出失败极少见，静默忽略
        }
    }
}

/// 详情页的参考标高编辑
struct SessionRefEditorView: View {
    let points: [MarkedPoint]
    @Binding var refID: UUID?
    @Binding var valueText: String
    var onApply: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var invalidInput = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("参考点", selection: $refID) {
                        ForEach(points) { p in
                            Text(p.displayName).tag(Optional(p.id))
                        }
                    }
                    TextField("参考标高（米），如 100.00", text: $valueText)
                        .keyboardType(.decimalPad)
                    if invalidInput {
                        Text("请输入数字，例如 100.00")
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    Button(role: .destructive) {
                        refID = nil
                        valueText = ""
                        onApply()
                        dismiss()
                    } label: {
                        Text("清除参考（只看相对标高）")
                    }
                } footer: {
                    Text("所有点的绝对标高 = 参考标高 + 与参考点的高差。")
                }
            }
            .navigationTitle("参考标高")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") {
                        let normalized = valueText
                            .replacingOccurrences(of: ",", with: ".")
                            .replacingOccurrences(of: "，", with: ".")
                            .replacingOccurrences(of: "。", with: ".")
                        if refID != nil && !valueText.isEmpty && Float(normalized) == nil {
                            invalidInput = true
                            return
                        }
                        onApply()
                        dismiss()
                    }
                }
            }
        }
    }
}
