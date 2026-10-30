import SwiftUI
import ARKit
import RealityKit
import UIKit
import simd

/// 管理 AR 会话：追踪状态、点击标记点、场景内标签、撤销/清空
final class MeasureSessionManager: NSObject, ObservableObject {
    @Published var points: [MarkedPoint] = []
    @Published var trackingHint: String?
    /// 需要用户处理的严重问题提示（权限被拒 / AR 启动异常）
    @Published var troubleHint: String?
    /// 点击没有命中任何表面时更新（ContentView 监听它弹提示）
    @Published var missNotice = Date.distantPast
    /// 标高显示模式与参考标高
    @Published var displayMode: ElevationMode = .relative
    @Published var referencePointID: UUID?
    @Published var referenceElevation: Float?
    /// 导入待放置的点：非空时下一次点击屏幕 = 在现实中指定第一个点的位置
    @Published var pendingPlacement: [MarkedPoint]?

    private(set) weak var arView: ARView?
    private var anchors: [UUID: AnchorEntity] = [:]
    private var labels: [UUID: Entity] = [:]
    private var frameTickCount = 0

    /// 点循环使用的颜色，屏幕上的圆点用同样的颜色对应
    private static let palette: [UIColor] = [
        .systemOrange, .systemBlue, .systemGreen, .systemPurple, .systemTeal,
    ]

    static func markerColor(forIndex index: Int) -> UIColor {
        palette[(index - 1) % palette.count]
    }

    /// 点的标高文字（跟随当前显示模式和参考设置）
    func elevationText(for point: MarkedPoint) -> String {
        ElevationFormatter.displayText(for: point, points: points, mode: displayMode,
                                       referenceID: referencePointID,
                                       referenceValue: referenceElevation)
    }

    @MainActor func attach(to view: ARView) {
        arView = view
        view.session.delegate = self
        checkCameraPermission()
    }

    /// 相机权限没给的话 AR 会一直"初始化中"且没有画面，先主动确认/申请
    private func checkCameraPermission() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            startSession()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    if granted {
                        self?.startSession()
                    } else {
                        self?.troubleHint = "没有相机权限：请到 设置 → 高度笔记 → 相机 里打开"
                    }
                }
            }
        case .denied, .restricted:
            troubleHint = "没有相机权限：请到 设置 → 高度笔记 → 相机 里打开"
        @unknown default:
            startSession()
        }
    }

    private func startSession() {
        guard let view = arView else { return }
        // 最低负载配置：只开平面检测（sceneReconstruction/environmentTexturing 对本 App 无用）
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = [.horizontal, .vertical]
        view.session.run(config)
    }

    /// 点击屏幕 → 射线打到现实物体 → 记录一个点（或完成导入点的放置）
    @MainActor func handleTap(at screenPoint: CGPoint) {
        guard let view = arView else { return }
        if let result = raycast(in: view, at: screenPoint) {
            if let pending = pendingPlacement {
                pendingPlacement = nil
                placeImported(pending, at: result.worldTransform)
            } else {
                addPoint(worldTransform: result.worldTransform)
            }
        } else {
            missNotice = Date()
        }
    }

    /// 依次尝试：已识别平面（含范围）→ 平面无限延伸 → 估算平面
    private func raycast(in view: ARView, at point: CGPoint) -> ARRaycastResult? {
        for target: ARRaycastQuery.Target in [.existingPlaneGeometry, .existingPlaneInfinite, .estimatedPlane] {
            if let result = view.raycast(from: point, allowing: target, alignment: .any).first {
                return result
            }
        }
        return nil
    }

    @MainActor private func addPoint(worldTransform: simd_float4x4) {
        let t = worldTransform.columns.3
        let nextIndex = (points.map(\.index).max() ?? 0) + 1
        insertPoint(MarkedPoint(index: nextIndex, position: [t.x, t.y, t.z]))
    }

    /// 把一个点放进当前会话：建锚点、小球、标签
    @MainActor private func insertPoint(_ point: MarkedPoint) {
        // 锚点只保留位置、不带回平面的旋转，方便标签按世界坐标竖直摆放
        var placement = matrix_identity_float4x4
        placement.columns.3 = simd_float4(point.position[0], point.position[1], point.position[2], 1)
        let anchor = AnchorEntity(world: placement)

        let sphere = ModelEntity(
            mesh: .generateSphere(radius: 0.008),
            materials: [UnlitMaterial(color: Self.markerColor(forIndex: point.index))]
        )
        anchor.addChild(sphere)

        let label = makeLabel(text: labelText(for: point))
        anchor.addChild(label)
        labels[point.id] = label

        arView?.scene.addAnchor(anchor)
        anchors[point.id] = anchor

        points.append(point)
    }

    /// 放置导入的点：以文件里第一个点为锚，把整组点平移到你点击的现实位置。
    /// 高度方向自动对准（y 轴永远与重力对齐）；水平朝向和当时测量时的站姿有关，可能有偏差。
    @MainActor func placeImported(_ imported: [MarkedPoint], at worldTransform: simd_float4x4) {
        guard let first = imported.first else { return }
        let a = worldTransform.columns.3
        let offset = SIMD3<Float>(
            a.x - first.position[0],
            a.y - first.position[1],
            a.z - first.position[2]
        )
        let renumber = !points.isEmpty
        let startIndex = points.map(\.index).max() ?? 0
        for (i, p) in imported.enumerated() {
            var np = p
            np.id = UUID()
            if renumber { np.index = startIndex + 1 + i }   // 会话里已有点时接续编号，自定义名保留
            np.position = [p.position[0] + offset.x,
                           p.position[1] + offset.y,
                           p.position[2] + offset.z]
            np.timestamp = Date()
            insertPoint(np)
        }
        refreshAllLabels()
    }

    // MARK: - 场景内标签（名字 + 标高）

    @MainActor private func labelText(for point: MarkedPoint) -> String {
        "\(point.displayName)  \(elevationText(for: point))"
    }

    @MainActor private func makeLabel(text: String) -> Entity {
        let container = Entity()

        // 3D 文字（generateText 用的是 UIKit 字体，中文没问题）
        let font = MeshResource.Font.systemFont(ofSize: 10, weight: .bold)
        let textMesh = MeshResource.generateText(text, extrusionDepth: 0.2, font: font)
        let textEntity = ModelEntity(mesh: textMesh, materials: [UnlitMaterial(color: .white)])

        let extent = textEntity.visualBounds(relativeTo: nil).extents
        let targetHeight: Float = 0.012
        let scale = targetHeight / max(Float(extent.y), 0.001)
        textEntity.scale = SIMD3<Float>(repeating: scale)
        let w = Float(extent.x) * scale
        let h = Float(extent.y) * scale

        // 深色底板，保证亮处也看得清白字
        let backing = ModelEntity(
            mesh: .generatePlane(width: w + 0.008, height: h + 0.005),
            materials: [UnlitMaterial(color: UIColor(white: 0.08, alpha: 1))]
        )
        container.addChild(backing)
        textEntity.position = SIMD3<Float>(-w / 2, -h / 2, 0.0015)
        container.addChild(textEntity)

        // 标签悬在小球上方
        container.position = SIMD3<Float>(0, 0.035, 0)
        return container
    }

    /// 名字/模式/参考变化后，重建标签
    @MainActor func refreshAllLabels() {
        for point in points {
            guard let old = labels[point.id] else { continue }
            old.removeFromParent()
            let new = makeLabel(text: labelText(for: point))
            anchors[point.id]?.addChild(new)
            labels[point.id] = new
        }
    }

    // MARK: - 点的编辑

    @MainActor func rename(pointID: UUID, to newName: String) {
        guard let i = points.firstIndex(where: { $0.id == pointID }) else { return }
        points[i].name = newName.isEmpty ? nil : newName
        refreshAllLabels()
    }

    @MainActor func undoLast() {
        guard let last = points.popLast() else { return }
        anchors[last.id]?.removeFromParent()
        anchors[last.id] = nil
        labels[last.id] = nil
        refreshAllLabels()
    }

    @MainActor func clearAll() {
        for point in points {
            anchors[point.id]?.removeFromParent()
        }
        anchors.removeAll()
        labels.removeAll()
        points = []
    }
}

extension MeasureSessionManager: ARSessionDelegate {
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        let hint: String?
        switch camera.trackingState {
        case .normal:
            DispatchQueue.main.async {
                self.troubleHint = nil
                self.trackingHint = nil
            }
            return
        case .notAvailable:
            hint = "追踪不可用，请挥动一下手机重新识别"
        case .limited(.initializing):
            hint = "请缓慢移动手机，识别周围环境"
        case .limited(.excessiveMotion):
            hint = "移动太快了，请放慢速度"
        case .limited(.insufficientFeatures):
            hint = "环境特征不足，请对准有细节的表面"
        case .limited(.relocalizing):
            hint = "正在恢复追踪…"
        @unknown default:
            hint = nil
        }
        DispatchQueue.main.async { self.trackingHint = hint }
    }

    func sessionWasInterrupted(_ session: ARSession) {
        DispatchQueue.main.async { self.trackingHint = "相机被中断，正在恢复…" }
    }

    func sessionInterruptionEnded(_ session: ARSession) {
        DispatchQueue.main.async { self.trackingHint = nil }
    }

    /// 每帧把标签转到正对相机的方向（只转水平角）。
    /// RealityKit 的场景操作必须在主线程做，这里节流后派发到主线程。
    /// 每帧把标签转到正对相机的方向（只转水平角）。
    /// RealityKit 场景操作必须在主线程：节流到 1/4 帧，派发主线程执行。
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard !labels.isEmpty else { return }
        frameTickCount += 1
        guard frameTickCount % 4 == 0 else { return }
        let yaw = frame.camera.eulerAngles.y
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.labels.isEmpty else { return }
            let q = simd_quatf(angle: yaw, axis: SIMD3<Float>(0, 1, 0))
            for label in self.labels.values {
                label.setOrientation(q, relativeTo: nil)
            }
        }
    }
}

/// 把 RealityKit 的 ARView 包一层给 SwiftUI 用
struct ARMeasureView: UIViewRepresentable {
    @ObservedObject var manager: MeasureSessionManager

    /// 视图真正挂到窗口后才启动 AR 会话（相机直通合成层需要窗口就绪）
    final class HostedARView: ARView {
        var onReady: ((ARView) -> Void)?
        private var started = false

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil, !started {
                started = true
                onReady?(self)
            }
        }
    }

    func makeUIView(context: Context) -> HostedARView {
        // 非零初始尺寸，避免合成层以 0 尺寸注册
        let view = HostedARView(frame: UIScreen.main.bounds)
        view.onReady = { arView in
            manager.attach(to: arView)
        }
        let tap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleTap(_:))
        )
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: HostedARView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(manager: manager) }

    final class Coordinator: NSObject {
        let manager: MeasureSessionManager
        init(manager: MeasureSessionManager) { self.manager = manager }

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)
            Task { @MainActor in
                manager.handleTap(at: location)
            }
        }
    }
}
