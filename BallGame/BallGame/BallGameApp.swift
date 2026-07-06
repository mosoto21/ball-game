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
    var body: some View {
        GeometryReader { proxy in
            SpriteView(scene: makeScene(size: proxy.size))
        }
        .ignoresSafeArea()
        .statusBarHidden()
    }

    private func makeScene(size: CGSize) -> SKScene {
        let scene = GameScene()
        scene.size = UIScreen.main.bounds.size
        scene.scaleMode = .resizeFill
        return scene
    }
}
