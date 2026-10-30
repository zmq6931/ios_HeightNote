import SwiftUI
import UIKit
import AVFoundation
import UniformTypeIdentifiers

struct ContentView: View {
    @StateObject private var manager = MeasureSessionManager()
    @StateObject private var store = PointStore()

    /// 当前选中用于计算高度差的点（最多 2 个）
    @State private var selectedIDs: [UUID] = []
    @State private var showHistory = false
    @State private var toast: String?

    // 标高设置
    @State private var showElevationSettings = false

    // 保存命名
    @State private var showSaveDialog = false
    @State private var saveName = ""

    // 重命名
    @State private var renamingPoint: MarkedPoint?
    @State private var renameText = ""

    // AR 画面重建（黑屏自救）
    @State private var arViewID = UUID()
    @State private var showARRetry = false

    // 导入 Excel
    @State private var showImporter = false
    @State private var importError: String?

    var body: some View {
        ZStack {
            cameraLayer
            overlayLayer
        }
        .sheet(isPresented: $showHistory) {
            HistoryView(store: store)
        }
        .sheet(isPresented: $showElevationSettings, onDismiss: revertIfElevationBroken) {
            ElevationSettingsView(manager: manager)
        }
        // 新增/撤销点后，自动选中最近的两个点，马上能看到高度差
        .onChange(of: manager.points) { _, newPoints in
            if newPoints.count >= 2 {
                selectedIDs = newPoints.suffix(2).map(\.id)
            } else {
                selectedIDs = newPoints.map(\.id)
            }
        }
        .onChange(of: manager.missNotice) { _, _ in
            if manager.pendingPlacement == nil {
                showToast("这里检测不到表面，换个位置或角度再点")
            }
        }
        .onChange(of: manager.displayMode) { _, newMode in
            manager.refreshAllLabels()
            // 切到绝对标高但还没设参考 → 直接弹出标高设置
            if newMode == .absolute, !referenceIsSet {
                showElevationSettings = true
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

    private func importExcel(from url: URL) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            let imported = try XlsxIO.readPoints(from: Data(contentsOf: url))
            manager.pendingPlacement = imported
        } catch {
            importError = (error as? LocalizedError)?.errorDescription ?? "读取文件失败"
        }
    }

    /// 关闭标高设置后，如果处于绝对模式但没有参考，退回相对模式，避免满屏“未设参考”
    private func revertIfElevationBroken() {
        if manager.displayMode == .absolute, !referenceIsSet {
            manager.displayMode = .relative
            manager.refreshAllLabels()
        }
    }

    // MARK: - 摄像头画面（模拟器没有摄像头，显示占位说明）

    @ViewBuilder
    private var cameraLayer: some View {
        #if targetEnvironment(simulator)
        Color(.systemGray5)
            .ignoresSafeArea()
            .overlay(
                VStack(spacing: 12) {
                    Image(systemName: "camera.aperture")
                        .font(.system(size: 56))
                        .foregroundStyle(.secondary)
                    Text("模拟器没有摄像头")
                        .font(.headline)
                    Text("AR 测量请用真机体验（iPhone 15 Pro Max）")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            )
        #else
        ARMeasureView(manager: manager)
            .id(arViewID)
            .ignoresSafeArea()
            .task(id: manager.trackingHint) {
                // "请缓慢移动手机"持续 12 秒以上 → 显示重试按钮
                if manager.trackingHint == "请缓慢移动手机，识别周围环境" {
                    try? await Task.sleep(for: .seconds(12))
                    if manager.trackingHint == "请缓慢移动手机，识别周围环境" {
                        showARRetry = true
                    }
                } else {
                    showARRetry = false
                }
            }
        #endif
    }

    // MARK: - 顶部提示 + 底部操作面板

    private var overlayLayer: some View {
        VStack(spacing: 10) {
            HStack {
                Spacer()
                if manager.pendingPlacement == nil {
                    Button {
                        showImporter = true
                    } label: {
                        Image(systemName: "square.and.arrow.down.on.square")
                            .font(.body.weight(.semibold))
                            .padding(9)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .tint(.primary)
                }
            }

            if let pending = manager.pendingPlacement {
                placementBanner(pending)
            } else if let trouble = manager.troubleHint {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(trouble).font(.footnote.bold())
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .foregroundStyle(.white)
                .background(Color.orange, in: Capsule())
            } else if let hint = manager.trackingHint {
                trackingBanner(hint)
            }
            if let toast {
                Text(toast)
                    .font(.footnote.bold())
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
            }
            Spacer()
            controlPanel
        }
        .padding()
    }

    @ViewBuilder
    private var controlPanel: some View {
        VStack(spacing: 12) {
            if manager.points.isEmpty {
                instructionCard
            } else {
                modeRow
                if manager.displayMode == .absolute && !referenceIsSet {
                    Button {
                        showElevationSettings = true
                    } label: {
                        Label("还没有设置参考标高，点此设置", systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote.bold())
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                if selectedIDs.count == 2, let pair = selectedPair {
                    diffCard(pair.0, pair.1)
                } else if manager.points.count >= 2 {
                    Text("再点选一个点，即可计算高度差")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                pointChips
                buttonRow
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    private var instructionCard: some View {
        VStack(spacing: 10) {
            Label("怎么用", systemImage: "camera.metering.matrix")
                .font(.headline)
            VStack(alignment: .leading, spacing: 8) {
                step("1", "缓慢移动手机，让画面识别出环境")
                step("2", "点击屏幕标记高度点，第一个点是基准点")
                step("3", "已知某点的真实标高？点 ⚙︎ 设置参考，即可看绝对标高")
                step("4", "点选任意两个点算高度差，随时保存或导出 Excel")
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity)
    }

    private func step(_ n: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(n)
                .font(.caption.bold())
                .frame(width: 20, height: 20)
                .background(Circle().fill(.tint.opacity(0.15)))
            Text(text)
        }
    }

    /// 显示模式切换 + 标高设置入口
    private var modeRow: some View {
        HStack(spacing: 10) {
            Picker("显示模式", selection: $manager.displayMode) {
                Text("相对标高").tag(ElevationMode.relative)
                Text("绝对标高").tag(ElevationMode.absolute)
            }
            .pickerStyle(.segmented)

            Button {
                showElevationSettings = true
            } label: {
                Image(systemName: referenceIsSet ? "gearshape.fill" : "gearshape")
                    .font(.title3)
            }
            .tint(referenceIsSet ? .accentColor : .secondary)
        }
    }

    private var referenceIsSet: Bool {
        manager.referencePointID != nil && manager.referenceElevation != nil
    }

    private func diffCard(_ a: MarkedPoint, _ b: MarkedPoint) -> some View {
        VStack(spacing: 4) {
            Text("\(b.displayName) − \(a.displayName) = \(formatHeight(b.y - a.y))")
                .font(.title3.bold().monospacedDigit())
            Text(heightSentence(a, b))
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("\(a.displayName) \(manager.elevationText(for: a))　\(b.displayName) \(manager.elevationText(for: b))")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private var pointChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(manager.points) { point in
                    pointChip(point)
                }
            }
            .padding(.vertical, 2)
        }
        .alert("重命名", isPresented: Binding(
            get: { renamingPoint != nil },
            set: { if !$0 { renamingPoint = nil } }
        )) {
            TextField("点的名字", text: $renameText)
            Button("确定") {
                if let p = renamingPoint {
                    manager.rename(pointID: p.id, to: renameText)
                }
                renamingPoint = nil
            }
            Button("取消", role: .cancel) { renamingPoint = nil }
        }
    }

    private func pointChip(_ point: MarkedPoint) -> some View {
        let isSelected = selectedIDs.contains(point.id)

        return HStack(spacing: 6) {
            Circle()
                .fill(Color(uiColor: MeasureSessionManager.markerColor(forIndex: point.index)))
                .frame(width: 10, height: 10)
            Text(point.displayName).font(.subheadline.bold())
            Text(manager.elevationText(for: point))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            Capsule().fill(isSelected ? Color.accentColor.opacity(0.2) : Color(uiColor: .secondarySystemFill))
        )
        .overlay(
            Capsule().strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
        )
        .onTapGesture { toggleSelection(point.id) }
        .contextMenu {
            Button {
                renameText = point.displayName
                renamingPoint = point
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            if point.id != manager.referencePointID {
                Button {
                    manager.referencePointID = point.id
                    manager.refreshAllLabels()
                    showElevationSettings = true
                } label: {
                    Label("设为参考点", systemImage: "star")
                }
            }
        }
    }

    private var buttonRow: some View {
        HStack(spacing: 8) {
            Button {
                manager.undoLast()
            } label: {
                Label("撤销", systemImage: "arrow.uturn.backward")
            }
            .disabled(manager.points.isEmpty)

            Button(role: .destructive) {
                manager.clearAll()
            } label: {
                Label("清空", systemImage: "trash")
            }
            .disabled(manager.points.isEmpty)

            Spacer()

            Button {
                exportCurrent()
            } label: {
                Label("导出", systemImage: "square.and.arrow.up")
            }
            .disabled(manager.points.isEmpty)

            Button {
                saveName = PointStore.defaultSessionName()
                showSaveDialog = true
            } label: {
                Label("保存", systemImage: "square.and.arrow.down")
            }
            .disabled(manager.points.isEmpty)

            Button {
                showHistory = true
            } label: {
                Label("历史", systemImage: "clock.arrow.circlepath")
            }
        }
        .font(.subheadline)
        .controlSize(.small)
        .buttonStyle(.bordered)
        .tint(.primary)
        .alert("保存测量记录", isPresented: $showSaveDialog) {
            TextField("记录名称", text: $saveName)
            Button("保存") { saveSession() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("默认按日期命名，可改成工地/位置名，方便以后确认")
        }
    }

    // MARK: - 操作

    private var selectedPair: (MarkedPoint, MarkedPoint)? {
        guard selectedIDs.count == 2,
              let a = manager.points.first(where: { $0.id == selectedIDs[0] }),
              let b = manager.points.first(where: { $0.id == selectedIDs[1] })
        else { return nil }
        return (a, b)
    }

    private func toggleSelection(_ id: UUID) {
        if let i = selectedIDs.firstIndex(of: id) {
            selectedIDs.remove(at: i)
        } else {
            selectedIDs.append(id)
            if selectedIDs.count > 2 { selectedIDs.removeFirst() }
        }
    }

    /// 黑屏自救：销毁并重建 AR 画面（相当于 App 内重启相机）
    private func retryAR() {
        manager.clearAll()
        manager.trackingHint = nil
        showARRetry = false
        arViewID = UUID()
    }

    private func saveSession() {
        store.save(manager.points,
                   name: saveName,
                   referenceID: manager.referencePointID,
                   referenceValue: manager.referenceElevation)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        showToast("已保存到历史记录")
    }

    private func exportCurrent() {
        guard !manager.points.isEmpty else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日-HHmm"
        let name = "高度笔记-\(formatter.string(from: Date())).xlsx"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        do {
            try XlsxWriter.workbookData(
                points: manager.points,
                referenceID: manager.referencePointID,
                referenceValue: manager.referenceElevation
            ).write(to: url)
            ShareSheet.present(url)
        } catch {
            showToast("导出失败：\(error.localizedDescription)")
        }
    }

    /// 导入点的放置提示
    private func placementBanner(_ pending: [MarkedPoint]) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "scope")
            VStack(alignment: .leading, spacing: 2) {
                Text("已导入 \(pending.count) 个点").font(.footnote.bold())
                Text("请在现实中点击「\(pending.first?.displayName ?? "P1")」原来的位置，整组点会自动对齐（高度自动对准）")
                    .font(.caption2)
            }
            Button {
                manager.pendingPlacement = nil
            } label: {
                Text("取消")
                    .font(.footnote.bold())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .foregroundStyle(.white)
        .background(Color.blue, in: Capsule())
    }

    private func trackingBanner(_ hint: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text(hint).font(.footnote)
            if showARRetry {
                Button {
                    retryAR()
                } label: {
                    Text("重试")
                        .font(.footnote.bold())
                        .padding(.horizontal, 10)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange))
                        .foregroundStyle(.white)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            if toast == text { toast = nil }
        }
    }
}

// MARK: - 临时诊断：普通相机预览（验证相机访问本身是否正常）

struct CameraPreviewTest: UIViewRepresentable {
    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        let session = AVCaptureSession()
        session.sessionPreset = .vga640x480
        if let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
           let input = try? AVCaptureDeviceInput(device: device),
           session.canAddInput(input) {
            session.addInput(input)
            view.previewLayer.session = session
            session.startRunning()
        }
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

// MARK: - 标高设置

struct ElevationSettingsView: View {
    @ObservedObject var manager: MeasureSessionManager
    @Environment(\.dismiss) private var dismiss

    @State private var refID: UUID?
    @State private var valueText: String
    @State private var invalidInput = false

    init(manager: MeasureSessionManager) {
        self.manager = manager
        _refID = State(initialValue: manager.referencePointID ?? manager.points.first?.id)
        if let v = manager.referenceElevation {
            _valueText = State(initialValue: String(format: "%.2f", v))
        } else {
            _valueText = State(initialValue: "")
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("参考点", selection: $refID) {
                        ForEach(manager.points) { p in
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
                } header: {
                    Text("设置参考")
                } footer: {
                    Text("已知某点的真实标高时，选它作参考点并输入标高值。之后所有点的绝对标高 = 参考标高 + 与参考点的高差。")
                }

                Section {
                    Button(role: .destructive) {
                        manager.referencePointID = nil
                        manager.referenceElevation = nil
                        manager.refreshAllLabels()
                        dismiss()
                    } label: {
                        Text("清除参考（只看相对标高）")
                    }
                }
            }
            .navigationTitle("标高设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("应用") { apply() }
                }
            }
        }
    }

    private func apply() {
        guard let refID else { return }
        let normalized = valueText
            .replacingOccurrences(of: ",", with: ".")
            .replacingOccurrences(of: "，", with: ".")
            .replacingOccurrences(of: "。", with: ".")
        guard let value = Float(normalized) else {
            invalidInput = true
            return
        }
        manager.referencePointID = refID
        manager.referenceElevation = value
        manager.displayMode = .absolute   // 设置完参考自动切到绝对标高
        manager.refreshAllLabels()
        dismiss()
    }
}

// MARK: - 系统分享面板（直接从根控制器弹出，比包在 SwiftUI sheet 里可靠）

enum ShareSheet {
    static func present(_ url: URL) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first,
              let root = scene.keyWindow?.rootViewController
        else { return }
        // 找到最上层控制器再弹（避免被已打开的页面挡住）
        var top = root
        while let presented = top.presentedViewController {
            top = presented
        }
        let vc = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        top.present(vc, animated: true)
    }
}
