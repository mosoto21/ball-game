import SpriteKit
import CoreMotion

/// Milestone 1: a single ball on a single phone that rolls when you tilt the device.
final class GameScene: SKScene {

    private let motion = CMMotionManager()
    private let ball = SKShapeNode(circleOfRadius: GameScene.ballRadius)
    /// Dot pattern inside the ball; scrolling it with the velocity makes the
    /// ball read as rolling when seen from above.
    private let dotPattern = SKNode()
    private var lastUpdateTime: TimeInterval?

    /// Bumped on every code change so a stale build is obvious on screen.
    private static let buildNumber = 4

    private static let ballRadius: CGFloat = 26
    /// How strongly tilting maps to rolling force. Higher = faster/heavier feel.
    private static let tiltStrength: CGFloat = 130
    /// Grid spacing of the dots on the ball's surface.
    private static let dotSpacing: CGFloat = 19

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
        setUpBuildLabel()

        // Device motion separates gravity from shakes, giving smooth tilt data.
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates()
        motion.startAccelerometerUpdates() // fallback source
    }

    private func setUpBall() {
        ball.fillColor = SKColor(red: 1.0, green: 0.45, blue: 0.25, alpha: 1)
        ball.strokeColor = .clear
        ball.position = CGPoint(x: frame.midX, y: frame.midY)

        let body = SKPhysicsBody(circleOfRadius: GameScene.ballRadius)
        body.restitution = 0.55   // bounce off walls
        body.friction = 0.15
        body.linearDamping = 0.12 // slight rolling resistance so it settles
        body.allowsRotation = false // rolling is drawn via the surface pattern
        ball.physicsBody = body

        ball.addChild(makeSurfacePattern())
        ball.addChild(makeShading())
        addChild(ball)
    }

    /// Darker dots clipped to the ball's circle. Scrolled every frame to fake
    /// the surface texture of a rolling sphere.
    private func makeSurfacePattern() -> SKNode {
        let spacing = GameScene.dotSpacing
        var index = 0
        for x in stride(from: -spacing * 3, through: spacing * 3, by: spacing) {
            for y in stride(from: -spacing * 3, through: spacing * 3, by: spacing) {
                let dot = SKShapeNode(circleOfRadius: 4.5)
                dot.fillColor = SKColor(red: 0.75, green: 0.22, blue: 0.10, alpha: 1)
                dot.strokeColor = .clear
                // Offset every other row for a less grid-like look.
                let stagger = (index % 2 == 0) ? spacing / 2 : 0
                dot.position = CGPoint(x: x + stagger, y: y)
                dotPattern.addChild(dot)
                index += 1
            }
        }

        let mask = SKShapeNode(circleOfRadius: GameScene.ballRadius - 1)
        mask.fillColor = .white
        mask.strokeColor = .clear

        let crop = SKCropNode()
        crop.maskNode = mask
        crop.addChild(dotPattern)
        return crop
    }

    /// A fixed highlight and rim shadow that don't move with the surface,
    /// selling the illusion of a lit 3D sphere.
    private func makeShading() -> SKNode {
        let shading = SKNode()

        let rim = SKShapeNode(circleOfRadius: GameScene.ballRadius - 1)
        rim.fillColor = .clear
        rim.strokeColor = SKColor(red: 0.4, green: 0.1, blue: 0.0, alpha: 0.55)
        rim.lineWidth = 5
        shading.addChild(rim)

        let highlight = SKShapeNode(circleOfRadius: 8)
        highlight.fillColor = SKColor(white: 1, alpha: 0.5)
        highlight.strokeColor = .clear
        highlight.position = CGPoint(x: -9, y: 10)
        highlight.setScale(1.2)
        shading.addChild(highlight)

        return shading
    }

    private func setUpBuildLabel() {
        let label = SKLabelNode(text: "build \(GameScene.buildNumber)")
        label.fontName = "Menlo"
        label.fontSize = 12
        label.fontColor = SKColor(white: 1, alpha: 0.25)
        label.position = CGPoint(x: frame.midX, y: frame.minY + 40)
        addChild(label)
    }

    override func update(_ currentTime: TimeInterval) {
        let dt = min(currentTime - (lastUpdateTime ?? currentTime), 1.0 / 30.0)
        lastUpdateTime = currentTime

        guard let body = ball.physicsBody else { return }

        if let tilt = currentTilt() {
            // In portrait, the device's x/y axes line up with the screen's x/y
            // axes, so the gravity vector maps directly to a rolling force.
            // Scaling by mass makes the feel independent of the ball's size.
            body.applyForce(CGVector(
                dx: tilt.dx * body.mass * GameScene.tiltStrength,
                dy: tilt.dy * body.mass * GameScene.tiltStrength
            ))
        }

        scrollSurfacePattern(velocity: body.velocity, dt: dt)
    }

    /// Seen from above, a rolling ball's top surface moves in the direction of
    /// travel — scroll the dots with the velocity and wrap them so the pattern
    /// never runs out.
    private func scrollSurfacePattern(velocity: CGVector, dt: CGFloat) {
        let spacing = GameScene.dotSpacing
        var position = dotPattern.position
        position.x += velocity.dx * dt * 0.8
        position.y += velocity.dy * dt * 0.8
        position.x = position.x.truncatingRemainder(dividingBy: spacing)
        position.y = position.y.truncatingRemainder(dividingBy: spacing)
        dotPattern.position = position
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
