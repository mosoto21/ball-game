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

    @State private var showCustomizer = false
    @AppStorage("ballColor") private var ballColor = 0
    @AppStorage("ballPattern") private var ballPattern = 0

    var body: some View {
        ZStack(alignment: .topTrailing) {
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
                    .overlay(Circle().stroke(.white.opacity(0.8), lineWidth: 2))
                    .shadow(radius: 3, y: 2)
            }
            .padding(.trailing, 20)
            .padding(.top, 8)
        }
        .statusBarHidden()
        .sheet(isPresented: $showCustomizer) {
            BallCustomizerView()
                .presentationDetents([.medium])
        }
        .onChange(of: ballColor) { _ in scene.applyBallStyle() }
        .onChange(of: ballPattern) { _ in scene.applyBallStyle() }
    }
}

/// Pick the ball's color and surface pattern. Choices persist and apply to
/// the running game instantly.
struct BallCustomizerView: View {
    @AppStorage("ballColor") private var ballColor = 0
    @AppStorage("ballPattern") private var ballPattern = 0
    @Environment(\.dismiss) private var dismiss

    private let patterns: [(name: String, icon: String)] = [
        ("ドット", "circle.grid.2x2.fill"),
        ("しま", "line.3.horizontal"),
        ("チェック", "squareshape.split.2x2"),
        ("むじ", "circle.fill"),
    ]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
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
                                .frame(height: 52)
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
                HStack(spacing: 12) {
                    ForEach(patterns.indices, id: \.self) { index in
                        Button {
                            ballPattern = index
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: patterns[index].icon)
                                    .font(.title2)
                                Text(patterns[index].name)
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
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

                Spacer()
            }
            .padding(24)
            .navigationTitle("ボールをカスタマイズ")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
    }
}
