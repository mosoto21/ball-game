import SpriteKit
import CoreMotion

/// Milestone 1: a single ball on a single phone that rolls when you tilt the device.
final class GameScene: SKScene {

    private let motion = CMMotionManager()
    private let ball = SKShapeNode(circleOfRadius: GameScene.ballRadius)

    private static let ballRadius: CGFloat = 26
    /// How strongly tilting maps to gravity. Higher = ball feels heavier/faster.
    private static let tiltStrength: Double = 18

    override func didMove(to view: SKView) {
        backgroundColor = SKColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1)

        // Walls around the screen so the ball can't leave (until Milestone 3,
        // where an open edge lets it roll onto the neighboring phone).
        physicsBody = SKPhysicsBody(edgeLoopFrom: frame)
        physicsBody?.friction = 0.1

        setUpBall()
        setUpHintLabel()

        motion.startAccelerometerUpdates()
    }

    private func setUpBall() {
        ball.fillColor = SKColor(red: 1.0, green: 0.45, blue: 0.25, alpha: 1)
        ball.strokeColor = SKColor(white: 1, alpha: 0.85)
        ball.lineWidth = 2
        ball.position = CGPoint(x: frame.midX, y: frame.midY)

        let body = SKPhysicsBody(circleOfRadius: GameScene.ballRadius)
        body.restitution = 0.45   // bounce off walls
        body.friction = 0.15
        body.linearDamping = 0.2  // slight rolling resistance so it settles
        body.allowsRotation = true
        ball.physicsBody = body

        addChild(ball)
    }

    private func setUpHintLabel() {
        let label = SKLabelNode(text: "Tilt the phone")
        label.fontName = "AvenirNext-DemiBold"
        label.fontSize = 22
        label.fontColor = SKColor(white: 1, alpha: 0.35)
        label.position = CGPoint(x: frame.midX, y: frame.maxY - 90)
        addChild(label)

        label.run(.sequence([
            .wait(forDuration: 4),
            .fadeOut(withDuration: 1),
            .removeFromParent(),
        ]))
    }

    override func update(_ currentTime: TimeInterval) {
        // Map device tilt to the scene's gravity. In portrait, the
        // accelerometer's x/y axes line up with the screen's x/y axes.
        guard let data = motion.accelerometerData else { return }
        physicsWorld.gravity = CGVector(
            dx: data.acceleration.x * GameScene.tiltStrength,
            dy: data.acceleration.y * GameScene.tiltStrength
        )
    }
}
