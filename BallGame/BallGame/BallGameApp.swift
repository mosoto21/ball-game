import SwiftUI
import SpriteKit
import SceneKit
import PhotosUI

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

    /// nil while the menu is showing.
    @State private var mode: GameScene.PlayMode?
    /// False until the player taps START on the pre-game overlay; the scene
    /// stays paused so the ball and the collapse wait for the tap.
    @State private var started = false
    @State private var showCustomizer = false
    @AppStorage("ballColor") private var ballColor = 0
    @AppStorage("ballPattern") private var ballPattern = 0
    /// Bumped every time the drawn skin is saved, so the scene restyles even
    /// though the pattern index itself didn't change.
    @AppStorage("skinVersion") private var skinVersion = 0

    var body: some View {
        Group {
            if mode == nil {
                MenuView { selected in
                    scene.setPlayMode(selected)
                    started = false
                    mode = selected
                }
            } else {
                gameBody
            }
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

    private var gameBody: some View {
        ZStack(alignment: .top) {
            // Note: the IOGPUMetal "background execution" console messages
            // are harmless (iOS refusing GPU work while backgrounded).
            // Paused until START is tapped, so nothing moves prematurely.
            SpriteView(scene: scene, isPaused: !started)
                .ignoresSafeArea()

            if !started {
                startOverlay
            }

            HStack {
                Button {
                    // Back to the menu; the mode is picked fresh there.
                    scene.setPlayMode(.solo)
                    mode = nil
                    started = false
                } label: {
                    Image(systemName: "house.fill")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.black.opacity(0.35)))
                        .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
                        .shadow(radius: 3, y: 2)
                }

                Spacer()

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
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
        }
    }

    /// Dimmed cover over the frozen game with one big START button; the
    /// scene unpauses when it is tapped.
    private var startOverlay: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Text(L10n.t("じゅんびはいい？", "Ready?"))
                    .font(.system(.title2, design: .rounded))
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .shadow(radius: 4)

                Button {
                    withAnimation(.easeOut(duration: 0.25)) {
                        started = true
                    }
                } label: {
                    Text("START")
                        .font(.system(size: 30, weight: .heavy, design: .rounded))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 56)
                        .padding(.vertical, 18)
                        .background(
                            Capsule().fill(Color(red: 1.0, green: 0.45, blue: 0.25))
                        )
                        .overlay(Capsule().stroke(.white.opacity(0.85), lineWidth: 3))
                        .shadow(color: .black.opacity(0.3), radius: 8, y: 4)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .transition(.opacity)
    }
}

/// The title screen: play alone or together — in multiplayer the phones
/// sense their physical arrangement themselves over UWB.
struct MenuView: View {
    let onSelect: (GameScene.PlayMode) -> Void
    @AppStorage("ballColor") private var ballColor = 0

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.96, green: 0.90, blue: 0.78),
                    Color(red: 0.87, green: 0.76, blue: 0.58),
                ],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()

            VStack(spacing: 44) {
                VStack(spacing: 14) {
                    Circle()
                        .fill(Color(GameScene.ballColors[
                            min(max(ballColor, 0), GameScene.ballColors.count - 1)
                        ]))
                        .frame(width: 88, height: 88)
                        .overlay(
                            Circle()
                                .fill(.white.opacity(0.45))
                                .frame(width: 26, height: 26)
                                .offset(x: -18, y: -20)
                        )
                        .shadow(color: .black.opacity(0.3), radius: 10, y: 8)

                    Text(L10n.t("ボールゲーム", "Ball Game"))
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .foregroundStyle(Color(red: 0.25, green: 0.15, blue: 0.08))
                    Text(L10n.t("かたむけてころがそう", "Tilt your phone to roll"))
                        .font(.system(.subheadline, design: .rounded))
                        .foregroundStyle(Color(red: 0.25, green: 0.15, blue: 0.08).opacity(0.6))
                }

                VStack(spacing: 16) {
                    modeButton(
                        title: L10n.t("ひとりであそぶ", "Play Solo"),
                        subtitle: L10n.t("どこまで登れる？ハイスコアにちょうせん",
                                          "How far can you climb? Chase the high score"),
                        icon: "person.fill"
                    ) { onSelect(.solo) }

                    modeButton(
                        title: L10n.t("ふたりであそぶ", "Play Together"),
                        subtitle: L10n.t("近くのiPhoneと自動でつながる\nよこにならべると はしからパス\nしたにかまえると 落ちたボールをキャッチ",
                                          "Auto-connects to a nearby iPhone\nSide by side: pass across the edges\nHold one underneath: catch a falling ball"),
                        icon: "person.2.fill"
                    ) { onSelect(.multiplayer) }
                }
                .padding(.horizontal, 32)
            }
        }
    }

    private func modeButton(title: String, subtitle: String, icon: String,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 40)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(.title3, design: .rounded))
                        .fontWeight(.bold)
                    Text(subtitle)
                        .font(.system(.caption, design: .rounded))
                        .multilineTextAlignment(.leading)
                        .opacity(0.75)
                }
                Spacer()
            }
            .foregroundStyle(Color(red: 0.25, green: 0.15, blue: 0.08))
            .padding(.vertical, 16)
            .padding(.horizontal, 18)
            .background(
                RoundedRectangle(cornerRadius: 18)
                    .fill(.white.opacity(0.75))
                    .shadow(color: .black.opacity(0.12), radius: 6, y: 4)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Pick the ball's color and surface pattern, paint a skin by hand, or
/// wrap a photo around the ball. Choices persist and apply to the running
/// game instantly.
struct BallCustomizerView: View {
    @AppStorage("ballColor") private var ballColor = 0
    @AppStorage("ballPattern") private var ballPattern = 0
    @AppStorage("skinVersion") private var skinVersion = 0
    @Environment(\.dismiss) private var dismiss
    @State private var showDrawing = false
    @State private var photoItem: PhotosPickerItem?

    private let patterns: [(name: String, icon: String)] = [
        (L10n.t("ドット", "Dots"), "circle.grid.2x2.fill"),
        (L10n.t("しま", "Stripes"), "line.3.horizontal"),
        (L10n.t("チェック", "Checker"), "squareshape.split.2x2"),
        (L10n.t("むじ", "Plain"), "circle.fill"),
        (L10n.t("カスタム", "Custom"), "paintbrush.pointed.fill"),
    ]

    /// Square-crop, downscale and save a picked photo as the ball skin —
    /// the same file the drawing canvas writes, so it scrolls with the
    /// roll and travels to the other phone exactly like a painted skin.
    private func applyPhotoSkin(_ data: Data) {
        guard let image = UIImage(data: data) else { return }
        let side = SpherePainter.textureSize
        let scale = max(side / image.size.width, side / image.size.height)
        let drawSize = CGSize(width: image.size.width * scale,
                              height: image.size.height * scale)
        let origin = CGPoint(x: (side - drawSize.width) / 2,
                             y: (side - drawSize.height) / 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let skin = UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side), format: format
        ).image { _ in
            image.draw(in: CGRect(origin: origin, size: drawSize))
        }
        try? skin.pngData()?.write(to: GameScene.customSkinURL)
        ballPattern = GameScene.BallPattern.custom.rawValue
        skinVersion += 1
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 22) {
                Text(L10n.t("色", "Color"))
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

                Text(L10n.t("がら", "Pattern"))
                    .font(.headline)
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5),
                          spacing: 10) {
                    ForEach(patterns.indices, id: \.self) { index in
                        Button {
                            ballPattern = index
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
                    HStack(spacing: 12) {
                        Button {
                            showDrawing = true
                        } label: {
                            Label(L10n.t("ボールに描く", "Paint"), systemImage: "paintbrush.pointed")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.borderedProminent)

                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label(L10n.t("写真をはる", "Use Photo"), systemImage: "photo")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 12)
                        }
                        .buttonStyle(.bordered)
                    }
                }

                Spacer()
            }
            .padding(22)
            .navigationTitle(L10n.t("ボールをカスタマイズ", "Customize Ball"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("完了", "Done")) { dismiss() }
                }
            }
            .sheet(isPresented: $showDrawing) {
                BallDrawingView {
                    skinVersion += 1
                    ballPattern = GameScene.BallPattern.custom.rawValue
                }
            }
            .onChange(of: photoItem) { item in
                guard let item else { return }
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        await MainActor.run { applyPhotoSkin(data) }
                    }
                    await MainActor.run { photoItem = nil }
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

        // Higher key/ambient contrast makes the sphere read as a lit object.
        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 950
        key.eulerAngles = SCNVector3(-0.55, -0.45, 0)
        scene.rootNode.addChildNode(key)

        let ambient = SCNNode()
        ambient.light = SCNLight()
        ambient.light?.type = .ambient
        ambient.light?.intensity = 380
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

        /// Decided where the finger lands: on the ball paints, around it
        /// rotates. Fixed for the whole drag so strokes that slip off the
        /// edge don't suddenly start spinning the ball.
        private enum DragMode { case none, paint, rotate }
        private var dragMode: DragMode = .none

        init(painter: SpherePainter) {
            self.painter = painter
        }

        private func uv(at point: CGPoint, in view: SCNView) -> CGPoint? {
            guard let hit = view.hitTest(point, options: nil).first,
                  hit.node === sphereNode else { return nil }
            return hit.textureCoordinates(withMappingChannel: 0)
        }

        @objc func pan(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view as? SCNView else { return }

            switch gesture.state {
            case .began:
                if let uv = uv(at: gesture.location(in: view), in: view) {
                    dragMode = .paint
                    painter.begin(at: uv)
                } else {
                    dragMode = .rotate
                    gesture.setTranslation(.zero, in: view)
                }
            case .changed:
                switch dragMode {
                case .paint:
                    if let uv = uv(at: gesture.location(in: view), in: view) {
                        painter.continueStroke(to: uv)
                    } else {
                        // Finger slid off the sphere: close the stroke (a
                        // new one starts if it slides back on).
                        painter.endStroke()
                    }
                case .rotate:
                    let translation = gesture.translation(in: view)
                    gesture.setTranslation(.zero, in: view)
                    guard let node = sphereNode else { return }
                    // Spin around the world axes so it follows the finger.
                    let yaw = SCNMatrix4MakeRotation(Float(translation.x) * 0.012, 0, 1, 0)
                    let pitch = SCNMatrix4MakeRotation(Float(translation.y) * 0.012, 1, 0, 0)
                    node.transform = SCNMatrix4Mult(node.transform,
                                                    SCNMatrix4Mult(yaw, pitch))
                case .none:
                    break
                }
            default:
                if dragMode == .paint { painter.endStroke() }
                dragMode = .none
            }
        }

        @objc func tap(_ gesture: UITapGestureRecognizer) {
            guard let view = gesture.view as? SCNView,
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
                ZStack {
                    // Soft floor shadow so the ball reads as a floating sphere.
                    Ellipse()
                        .fill(Color.black.opacity(0.32))
                        .frame(width: 175, height: 34)
                        .blur(radius: 12)
                        .offset(y: 128)
                    SphereCanvasView(painter: painter)
                        .frame(height: 320)
                }

                Text(L10n.t("ボールの上をなぞって描く ・ まわりをドラッグして回す",
                            "Draw on the ball ・ drag around it to spin"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
                        Label(L10n.t("もどす", "Undo"), systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!painter.canUndo)

                    Spacer()

                    Button(role: .destructive) {
                        painter.clear()
                    } label: {
                        Label(L10n.t("全部消す", "Clear all"), systemImage: "trash")
                    }
                    .disabled(!painter.canUndo)
                }
            }
            .padding(20)
            .navigationTitle(L10n.t("ボールに描く", "Paint the Ball"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L10n.t("キャンセル", "Cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L10n.t("保存", "Save")) {
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
