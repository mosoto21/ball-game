import SpriteKit
import CoreMotion

/// Milestone 1: a single ball on a single phone that rolls when you tilt the device.
final class GameScene: SKScene {

    private let motion = CMMotionManager()
    private let ball = SKShapeNode(circleOfRadius: GameScene.ballRadius)

    private static let ballRadius: CGFloat = 26
    /// How strongly tilting maps to rolling force. Higher = faster/heavier feel.
    private static let tiltStrength: CGFloat = 40

    override func didMove(to view: SKView) {
        backgroundColor = SKColor(red: 0.07, green: 0.09, blue: 0.13, alpha: 1)

        // The ball is driven by forces from the tilt sensor each frame, not by
        // world gravity — force application also wakes a resting body, which
        // gravity changes alone do not.
        physicsWorld.gravity = .zero

        // Walls around the screen so the ball can't leave (until Milestone 3,
        // where an open edge lets it roll onto the neighboring phone).
        physicsBody = SKPhysicsBody(edgeLoopFrom: frame)
        physicsBody?.friction = 0.1

        setUpBall()
        setUpHintLabel()

        // Device motion separates gravity from shakes, giving smooth tilt data.
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates()
        motion.startAccelerometerUpdates() // fallback source
    }

    private func setUpBall() {
        ball.fillColor = SKColor(red: 1.0, green: 0.45, blue: 0.25, alpha: 1)
        ball.strokeColor = SKColor(white: 1, alpha: 0.85)
        ball.lineWidth = 2
        ball.position = CGPoint(x: frame.midX, y: frame.midY)

        let body = SKPhysicsBody(circleOfRadius: GameScene.ballRadius)
        body.restitution = 0.45   // bounce off walls
        body.friction = 0.15
        body.linearDamping = 0.3  // slight rolling resistance so it settles
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
        guard let body = ball.physicsBody, let tilt = currentTilt() else { return }

        // In portrait, the device's x/y axes line up with the screen's x/y
        // axes, so the gravity vector maps directly to a rolling force.
        // Scaling by mass makes the feel independent of the ball's size.
        body.applyForce(CGVector(
            dx: tilt.dx * body.mass * GameScene.tiltStrength,
            dy: tilt.dy * body.mass * GameScene.tiltStrength
        ))
    }

    /// The direction gravity pulls, in the device's frame, in G units.
    /// Prefers device motion (filtered, smooth); falls back to the raw
    /// accelerometer if device motion isn't available yet.
    private func currentTilt() -> CGVector? {
        if let gravity = motion.deviceMotion?.gravity {
            return CGVector(dx: gravity.x, dy: gravity.y)
        }
        if let acceleration = motion.accelerometerData?.acceleration {
            return CGVector(dx: acceleration.x, dy: acceleration.y)
        }
        return nil
    }
}
