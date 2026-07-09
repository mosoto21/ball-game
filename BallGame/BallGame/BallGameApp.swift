import SwiftUI
import SpriteKit

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

    @Environment(\.scenePhase) private var scenePhase
    @State private var showCustomizer = false
    @AppStorage("ballColor") private var ballColor = 0
    @AppStorage("ballPattern") private var ballPattern = 0
    /// Bumped every time the drawn skin is saved, so the scene restyles even
    /// though the pattern index itself didn't change.
    @AppStorage("skinVersion") private var skinVersion = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Pausing while inactive stops SpriteKit from submitting GPU work
            // in the background (silences the IOGPUMetal console errors).
            SpriteView(scene: scene, isPaused: scenePhase != .active)
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
                        Label("キャンバスで描く", systemImage: "paintbrush.pointed")
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

// MARK: - Drawing canvas

/// One continuous finger stroke on the canvas.
private struct Stroke {
    var points: [CGPoint]
    let color: Color
    let width: CGFloat
    let isEraser: Bool
}

/// A round canvas the user paints on; the result becomes the ball's skin.
struct BallDrawingView: View {
    @Environment(\.dismiss) private var dismiss
    var onSave: () -> Void

    @State private var strokes: [Stroke] = []
    @State private var currentStroke: Stroke?
    @State private var brushColor: Color = .red
    @State private var brushWidth: CGFloat = 12
    @State private var isEraser = false

    private let canvasSize: CGFloat = 300
    private let palette: [Color] = [
        .black, .red, .orange, .yellow, .green,
        .blue, .purple, .brown, .pink, .white,
    ]

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                canvas

                // Brush colors + eraser.
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6),
                          spacing: 10) {
                    ForEach(palette.indices, id: \.self) { index in
                        let color = palette[index]
                        Button {
                            brushColor = color
                            isEraser = false
                        } label: {
                            Circle()
                                .fill(color)
                                .frame(height: 36)
                                .overlay(Circle().stroke(
                                    Color.secondary.opacity(0.4), lineWidth: 1))
                                .overlay(Circle().stroke(
                                    (!isEraser && brushColor == color)
                                        ? Color.primary : .clear,
                                    lineWidth: 3))
                        }
                    }
                    Button {
                        isEraser = true
                    } label: {
                        Image(systemName: "eraser.fill")
                            .font(.title3)
                            .frame(maxWidth: .infinity, minHeight: 36)
                            .background(
                                Circle().fill(Color.secondary.opacity(0.15)))
                            .overlay(Circle().stroke(
                                isEraser ? Color.primary : .clear, lineWidth: 3))
                    }
                    .buttonStyle(.plain)
                }

                HStack(spacing: 12) {
                    Image(systemName: "scribble")
                        .font(.caption)
                    Slider(value: $brushWidth, in: 4...28)
                    Image(systemName: "scribble.variable")
                        .font(.title3)
                }

                HStack {
                    Button {
                        if !strokes.isEmpty { strokes.removeLast() }
                    } label: {
                        Label("もどす", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(strokes.isEmpty)

                    Spacer()

                    Button(role: .destructive) {
                        strokes.removeAll()
                    } label: {
                        Label("全部消す", systemImage: "trash")
                    }
                    .disabled(strokes.isEmpty)
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
                        saveSkin()
                        onSave()
                        dismiss()
                    }
                    .fontWeight(.bold)
                }
            }
        }
    }

    private var canvas: some View {
        Canvas { context, _ in
            for stroke in strokes + (currentStroke.map { [$0] } ?? []) {
                context.blendMode = stroke.isEraser ? .clear : .normal
                let color: Color = stroke.isEraser ? .black : stroke.color

                if stroke.points.count == 1, let point = stroke.points.first {
                    let r = stroke.width / 2
                    context.fill(
                        Path(ellipseIn: CGRect(x: point.x - r, y: point.y - r,
                                               width: r * 2, height: r * 2)),
                        with: .color(color)
                    )
                    continue
                }

                var path = Path()
                guard let first = stroke.points.first else { continue }
                path.move(to: first)
                for point in stroke.points.dropFirst() {
                    path.addLine(to: point)
                }
                context.stroke(
                    path,
                    with: .color(color),
                    style: StrokeStyle(lineWidth: stroke.width,
                                       lineCap: .round, lineJoin: .round)
                )
            }
        }
        .frame(width: canvasSize, height: canvasSize)
        .background(Circle().fill(.white))
        .clipShape(Circle())
        // Sphere shading (same light as the in-game ball) so it feels like
        // painting directly on the ball, not on a flat disc.
        .overlay(
            ZStack {
                RadialGradient(
                    gradient: Gradient(colors: [.clear, .black.opacity(0.30)]),
                    center: UnitPoint(x: 0.42, y: 0.40),
                    startRadius: canvasSize * 0.18,
                    endRadius: canvasSize * 0.72
                )
                RadialGradient(
                    gradient: Gradient(colors: [.white.opacity(0.5), .clear]),
                    center: UnitPoint(x: 0.34, y: 0.28),
                    startRadius: 2,
                    endRadius: canvasSize * 0.38
                )
            }
            .clipShape(Circle())
            .allowsHitTesting(false)
        )
        .overlay(Circle().stroke(Color.secondary.opacity(0.5), lineWidth: 2))
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if currentStroke == nil {
                        currentStroke = Stroke(points: [value.location],
                                               color: brushColor,
                                               width: brushWidth,
                                               isEraser: isEraser)
                    } else {
                        currentStroke?.points.append(value.location)
                    }
                }
                .onEnded { _ in
                    if let stroke = currentStroke { strokes.append(stroke) }
                    currentStroke = nil
                }
        )
    }

    /// Rasterize the strokes into a crisp square texture and store it where
    /// the game loads the ball skin from.
    private func saveSkin() {
        let output: CGFloat = 512
        let scale = output / canvasSize
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: output, height: output))
        let image = renderer.image { ctx in
            let c = ctx.cgContext
            c.addEllipse(in: CGRect(x: 0, y: 0, width: output, height: output))
            c.clip()
            UIColor.white.setFill()
            c.fill(CGRect(x: 0, y: 0, width: output, height: output))

            for stroke in strokes {
                c.setBlendMode(stroke.isEraser ? .clear : .normal)
                let uiColor = UIColor(stroke.isEraser ? .black : stroke.color)

                guard let first = stroke.points.first else { continue }
                if stroke.points.count == 1 {
                    let r = stroke.width * scale / 2
                    c.setFillColor(uiColor.cgColor)
                    c.fillEllipse(in: CGRect(x: first.x * scale - r,
                                             y: first.y * scale - r,
                                             width: r * 2, height: r * 2))
                    continue
                }

                c.setStrokeColor(uiColor.cgColor)
                c.setLineWidth(stroke.width * scale)
                c.setLineCap(.round)
                c.setLineJoin(.round)
                c.beginPath()
                c.move(to: CGPoint(x: first.x * scale, y: first.y * scale))
                for point in stroke.points.dropFirst() {
                    c.addLine(to: CGPoint(x: point.x * scale, y: point.y * scale))
                }
                c.strokePath()
            }
        }

        try? image.pngData()?.write(to: GameScene.customSkinURL)
    }
}
