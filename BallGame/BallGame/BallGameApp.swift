import SwiftUI
import SpriteKit
import SceneKit

@main
struct BallGameApp: App {
    var body: some Scene {
        WindowGroup {
            GameView()
        }
    }
}

struct GameView: View {
    // Created once and kept alive — recreating the scene on every SwiftUI
    // render would spawn a new motion manager each time and reset the game.
    @State private var scene: GameScene = {
        let scene = GameScene(size: UIScreen.main.bounds.size)
        scene.scaleMode = .resizeFill
        return scene
    }()

    @State private var showCustomizer = false
    @AppStorage("ballColor") private var ballColor = 0
    @AppStorage("ballPattern") private var ballPattern = 0
    /// Bumped every time the drawn skin is saved, so the scene restyles even
    /// though the pattern index itself didn't change.
    @AppStorage("skinVersion") private var skinVersion = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Note: the IOGPUMetal "background execution" console messages
            // are harmless (iOS refusing GPU work while backgrounded).
            SpriteView(scene: scene)
                .ignoresSafeArea()

            Button {
                showCustomizer = true
            } label: {
                Circle()
                    .fill(Color(GameScene.ballColors[
                        min(max(ballColor, 0), GameScene.ballColors.count - 1)
                    ]))
                    .frame(width: 34, height: 34)
                    .overlay {
                        if ballPattern == GameScene.BallPattern.custom.rawValue {
                            Image(systemName: "paintbrush.pointed.fill")
                                .font(.caption)
                                .foregroundStyle(.white)
                        }
                    }
                    .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
                    .shadow(radius: 3, y: 2)
            }
            .padding(.trailing, 20)
            .padding(.top, 8)
        }
        .statusBarHidden()
        .sheet(isPresented: $showCustomizer) {
            BallCustomizerView()
                .presentationDetents([.medium, .large])
        }
        .onChange(of: ballColor) { _ in scene.applyBallStyle() }
        .onChange(of: ballPattern) { _ in scene.applyBallStyle() }
        .onChange(of: skinVersion) { _ in scene.applyBallStyle() }
    }
}

/// Pick the ball's color and surface pattern, or paint a skin by hand.
/// Choices persist and apply to the running game instantly.
struct BallCustomizerView: View {
    @AppStorage("ballColor") private var ballColor = 0
    @AppStorage("ballPattern") private var ballPattern = 0
    @AppStorage("skinVersion") private var skinVersion = 0
    @Environment(\.dismiss) private var dismiss
    @State private var showDrawing = false

    private let patterns: [(name: String, icon: String)] = [
        ("ドット", "circle.grid.2x2.fill"),
        ("しま", "line.3.horizontal"),
        ("チェック", "squareshape.split.2x2"),
        ("むじ", "circle.fill"),
        ("お絵描き", "paintbrush.pointed.fill"),
    ]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Text("色")
                    .font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4),
                          spacing: 14) {
                    ForEach(GameScene.ballColors.indices, id: \.self) { index in
                        Button {
                            ballColor = index
                        } label: {
                            Circle()
                                .fill(Color(GameScene.ballColors[index]))
                                .frame(height: 48)
                                .overlay(
                                    Circle().stroke(
                                        ballColor == index ? Color.primary : .clear,
                                        lineWidth: 3
                                    )
                                )
                        }
                    }
                }

                Text("がら")
                    .font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5),
                          spacing: 10) {
                    ForEach(patterns.indices, id: \.self) { index in
                        Button {
                            ballPattern = index
                            // First time picking お絵描き with no skin yet:
                            // open the canvas right away.
                            if index == GameScene.BallPattern.custom.rawValue,
                               GameScene.loadCustomSkin() == nil {
                                showDrawing = true
                            }
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: patterns[index].icon)
                                    .font(.title3)
                                Text(patterns[index].name)
                                    .font(.caption2)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 9)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(ballPattern == index
                                          ? Color.accentColor.opacity(0.2)
                                          : Color.secondary.opacity(0.1))
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(ballPattern == index
                                            ? Color.accentColor : .clear,
                                            lineWidth: 2)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                if ballPattern == GameScene.BallPattern.custom.rawValue {
                    Button {
                        showDrawing = true
                    } label: {
                        Label("ボールに描く", systemImage: "paintbrush.pointed")
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                    }
                    .buttonStyle(.borderedProminent)
                }

                Spacer()
            }
            .padding(22)
            .navigationTitle("ボールをカスタマイズ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .sheet(isPresented: $showDrawing) {
                BallDrawingView {
                    skinVersion += 1
                    ballPattern = GameScene.BallPattern.custom.rawValue
                }
            }
        }
    }
}

// MARK: - Painting on a real 3D sphere

/// Owns the strokes and the texture they're painted into. Strokes live in
/// the sphere's UV space (0...1 on both axes), so they stay put on the ball
/// no matter how it is rotated while painting.
final class SpherePainter: ObservableObject {
    struct SphereStroke {
        var uvPoints: [CGPoint]
        let color: UIColor
        let width: CGFloat // in texture pixels
    }

    static let textureSize: CGFloat = 512

    @Published var selectedColor = 1
    @Published var isEraser = false
    @Published var isRotateMode = false
    @Published var brushWidth: CGFloat = 12
    @Published private(set) var canUndo = false

    static let palette: [UIColor] = [
        .black, .systemRed, .systemOrange, .systemYellow, .systemGreen,
        .systemBlue, .systemPurple, .brown, .systemPink, .white,
    ]

    private(set) var strokes: [SphereStroke] = []
    private var currentStroke: SphereStroke?
    private(set) var textureImage: UIImage
    /// The sphere material to push texture updates into.
    weak var materialTarget: SCNMaterial?

    init() {
        textureImage = SpherePainter.render(strokes: [])
    }

    private var activeColor: UIColor {
        isEraser ? .white : SpherePainter.palette[selectedColor]
    }

    private var activeWidth: CGFloat {
        brushWidth * SpherePainter.textureSize / 300
    }

    func begin(at uv: CGPoint) {
        currentStroke = SphereStroke(uvPoints: [uv],
                                     color: activeColor,
                                     width: activeWidth)
        textureImage = SpherePainter.append(dot: uv,
                                            color: activeColor,
                                            width: activeWidth,
                                            to: textureImage)
        push()
    }

    func continueStroke(to uv: CGPoint) {
        guard var stroke = currentStroke, let last = stroke.uvPoints.last else {
            begin(at: uv)
            return
        }
        stroke.uvPoints.append(uv)
        currentStroke = stroke
        textureImage = SpherePainter.append(segmentFrom: last, to: uv,
                                            color: stroke.color,
                                            width: stroke.width,
                                            to: textureImage)
        push()
    }

    func endStroke() {
        if let stroke = currentStroke {
            strokes.append(stroke)
            canUndo = true
        }
        currentStroke = nil
    }

    func undo() {
        guard !strokes.isEmpty else { return }
        strokes.removeLast()
        canUndo = !strokes.isEmpty
        textureImage = SpherePainter.render(strokes: strokes)
        push()
    }

    func clear() {
        strokes.removeAll()
        canUndo = false
        textureImage = SpherePainter.render(strokes: strokes)
        push()
    }

    func saveSkin() {
        try? textureImage.pngData()?.write(to: GameScene.customSkinURL)
    }

    private func push() {
        materialTarget?.diffuse.contents = textureImage
    }

    // MARK: Texture rendering

    /// Draw one line segment in UV space onto `image`. Segments that cross
    /// the texture's left/right seam are drawn twice (shifted by ±1 in u)
    /// so lines stay continuous around the back of the sphere.
    private static func append(segmentFrom a: CGPoint, to b: CGPoint,
                               color: UIColor, width: CGFloat,
                               to image: UIImage) -> UIImage {
        redraw(image) { c in
            stroke(c, from: a, to: b, color: color, width: width)
        }
    }

    private static func append(dot uv: CGPoint, color: UIColor,
                               width: CGFloat, to image: UIImage) -> UIImage {
        redraw(image) { c in
            dot(c, at: uv, color: color, width: width)
        }
    }

    private static func redraw(_ image: UIImage,
                               _ operations: (CGContext) -> Void) -> UIImage {
        let side = textureSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side),
                                       format: format).image { ctx in
            image.draw(in: CGRect(x: 0, y: 0, width: side, height: side))
            operations(ctx.cgContext)
        }
    }

    /// Full re-render (used by undo/clear): white base plus every stroke.
    private static func render(strokes: [SphereStroke]) -> UIImage {
        let side = textureSize
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: side, height: side),
                                       format: format).image { ctx in
            let c = ctx.cgContext
            UIColor.white.setFill()
            c.fill(CGRect(x: 0, y: 0, width: side, height: side))
            for stroke in strokes {
                guard let first = stroke.uvPoints.first else { continue }
                if stroke.uvPoints.count == 1 {
                    dot(c, at: first, color: stroke.color, width: stroke.width)
                    continue
                }
                for (a, b) in zip(stroke.uvPoints, stroke.uvPoints.dropFirst()) {
                    stroke2(c, from: a, to: b, color: stroke.color, width: stroke.width)
                }
            }
        }
    }

    private static func dot(_ c: CGContext, at uv: CGPoint,
                            color: UIColor, width: CGFloat) {
        let side = textureSize
        let r = width / 2
        c.setFillColor(color.cgColor)
        c.fillEllipse(in: CGRect(x: uv.x * side - r, y: uv.y * side - r,
                                 width: r * 2, height: r * 2))
    }

    private static func stroke(_ c: CGContext, from a: CGPoint, to b: CGPoint,
                               color: UIColor, width: CGFloat) {
        stroke2(c, from: a, to: b, color: color, width: width)
    }

    private static func stroke2(_ c: CGContext, from a: CGPoint, to b: CGPoint,
                                color: UIColor, width: CGFloat) {
        let side = textureSize
        c.setStrokeColor(color.cgColor)
        c.setLineWidth(width)
        c.setLineCap(.round)

        func line(_ ax: CGFloat, _ bx: CGFloat) {
            c.beginPath()
            c.move(to: CGPoint(x: ax * side, y: a.y * side))
            c.addLine(to: CGPoint(x: bx * side, y: b.y * side))
            c.strokePath()
        }

        if abs(b.x - a.x) <= 0.5 {
            line(a.x, b.x)
        } else if b.x > a.x {
            // Crossed the seam going left: draw both wrapped halves.
            line(a.x, b.x - 1)
            line(a.x + 1, b.x)
        } else {
            line(a.x, b.x + 1)
            line(a.x - 1, b.x)
        }
    }
}

/// The 3D sphere you paint on. One-finger drag paints at the touched spot
/// (via hit-tested texture coordinates); in rotate mode the same drag spins
/// the ball so you can reach its back.
struct SphereCanvasView: UIViewRepresentable {
    @ObservedObject var painter: SpherePainter

    func makeCoordinator() -> Coordinator {
        Coordinator(painter: painter)
    }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X

        let scene = SCNScene()

        let sphere = SCNSphere(radius: 1)
        sphere.segmentCount = 72
        let material = SCNMaterial()
        material.diffuse.contents = painter.textureImage
        material.specular.contents = UIColor(white: 1, alpha: 0.6)
        material.shininess = 18
        sphere.materials = [material]
        let sphereNode = SCNNode(geometry: sphere)
        scene.rootNode.addChildNode(sphereNode)

        let cameraNode = SCNNode()
        cameraNode.camera = SCNCamera()
        cameraNode.position = SCNVector3(0, 0, 2.7)
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 750
        key.eulerAngles = SCNVector3(-0.5, -0.4, 0)
        scene.rootNode.addChildNode(key)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 550
        scene.rootNode.addChildNode(ambient)

        view.scene = scene
        painter.materialTarget = material
        context.coordinator.sphereNode = sphereNode

        let pan = UIPanGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.pan(_:)))
        pan.maximumNumberOfTouches = 1
        view.addGestureRecognizer(pan)
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.tap(_:)))
        view.addGestureRecognizer(tap)

        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {}

    final class Coordinator: NSObject {
        let painter: SpherePainter
        var sphereNode: SCNNode?

        init(painter: SpherePainter) {
            self.painter = painter
        }

        private func uv(at point: CGPoint, in view: SCNView) -> CGPoint? {
            guard let hit = view.hitTest(point, options: nil).first,
                  hit.node === sphereNode else { return nil }
            let coords = hit.textureCoordinates(withMappingChannel: 0)
            return coords
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? SCNView else { return }

            if painter.isRotateMode {
                let translation = gesture.translation(in: view)
                gesture.setTranslation(.zero, in: view)
                guard let node = sphereNode else { return }
                // Spin around the world axes so it always follows the finger.
                let yaw = SCNMatrix4MakeRotation(Float(translation.x) * 0.012, 0, 1, 0)
                let pitch = SCNMatrix4MakeRotation(Float(translation.y) * 0.012, 1, 0, 0)
                node.transform = SCNMatrix4Mult(node.transform,
                                                SCNMatrix4Mult(yaw, pitch))
                return
            }

            switch gesture.state {
            case .began:
                if let uv = uv(at: gesture.location(in: view), in: view) {
                    painter.begin(at: uv)
                }
            case .changed:
                if let uv = uv(at: gesture.location(in: view), in: view) {
                    painter.continueStroke(to: uv)
                } else {
                    // Finger slid off the sphere: close the stroke.
                    painter.endStroke()
                }
            default:
                painter.endStroke()
            }
        }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard !painter.isRotateMode,
                  let view = gesture.view as? SCNView,
                  let uv = uv(at: gesture.location(in: view), in: view) else { return }
            painter.begin(at: uv)
            painter.endStroke()
        }
    }
}

/// The full drawing screen: 3D ball, paint/rotate mode switch, palette,
/// brush size, undo/clear, save.
struct BallDrawingView: View {
    @Environment(\.dismiss) private var dismiss
    var onSave: () -> Void

    @StateObject private var painter = SpherePainter()

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                SphereCanvasView(painter: painter)
                    .frame(height: 320)

                Picker("モード", selection: $painter.isRotateMode) {
                    Label("描く", systemImage: "paintbrush.pointed.fill").tag(false)
                    Label("回す", systemImage: "rotate.3d").tag(true)
                }
                .pickerStyle(.segmented)

                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6),
                          spacing: 10) {
                    ForEach(SpherePainter.palette.indices, id: \.self) { index in
                        Button {
                            painter.selectedColor = index
                            painter.isEraser = false
                        } label: {
                            Circle()
                                .fill(Color(SpherePainter.palette[index]))
                                .frame(height: 34)
                                .overlay(Circle().stroke(
                                    Color.secondary.opacity(0.4), lineWidth: 1))
                                .overlay(Circle().stroke(
                                    (!painter.isEraser && painter.selectedColor == index)
                                        ? Color.primary : .clear,
                                    lineWidth: 3))
                        }
                    }
                    Button {
                        painter.isEraser = true
                    } label: {
                        Image(systemName: "eraser.fill")
                            .font(.callout)
                            .frame(maxWidth: .infinity, minHeight: 34)
                            .background(Circle().fill(Color.secondary.opacity(0.15)))
                            .overlay(Circle().stroke(
                                painter.isEraser ? Color.primary : .clear,
                                lineWidth: 3))
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 12) {
                    Image(systemName: "scribble")
                        .font(.caption)
                    Slider(value: $painter.brushWidth, in: 4...28)
                    Image(systemName: "scribble.variable")
                        .font(.title3)
                }

                HStack {
                    Button {
                        painter.undo()
                    } label: {
                        Label("もどす", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!painter.canUndo)

                    Spacer()

                    Button(role: .destructive) {
                        painter.clear()
                    } label: {
                        Label("全部消す", systemImage: "trash")
                    }
                    .disabled(!painter.canUndo)
                }
            }
            .padding(20)
            .navigationTitle("ボールに描く")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        painter.saveSkin()
                        onSave()
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }
}
