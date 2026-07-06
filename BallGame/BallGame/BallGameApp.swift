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

    var body: some View {
        SpriteView(scene: scene)
            .ignoresSafeArea()
            .statusBarHidden()
    }
}
