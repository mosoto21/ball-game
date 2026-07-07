import SpriteKit
import CoreMotion

/// Milestone 1: a single ball on a single phone that rolls when you tilt the device.
final class GameScene: SKScene {

    private let motion = CMMotionManager()
    private let ball = SKShapeNode(circleOfRadius: GameScene.ballRadius)
    private let shadow = SKShapeNode(circleOfRadius: GameScene.ballRadius)
    /// True while the ball is in the air after a hop; tilt steering is
    /// suspended so the flight feels ballistic.
    private var isAirborne = false
    /// Dot pattern inside the ball; scrolling it with the velocity makes the
    /// ball read as rolling when seen from above.
    private let dotPattern = SKNode()
    private var lastUpdateTime: TimeInterval?

    /// Bumped on every code change so a stale build is obvious on screen.
    private static let buildNumber = 8

    private static let ballRadius: CGFloat = 26
    /// Kirby-style direct control: the tilt sets a target velocity and the
    /// ball chases it hard, so response is near-instant in both directions.
    /// Points per second of ball speed for each G of sideways tilt. A relaxed
    /// ~15° hand tilt gives a comfortable rolling pace; steep tilts get quick
    /// without becoming a blur.
    private static let speedPerTilt: CGFloat = 1500
    /// Hard cap so a vertical phone doesn't launch the ball into hyperspace.
    private static let maxSpeed: CGFloat = 1100
    /// How aggressively the velocity converges on the target, per second.
    /// Higher = snappier response but bounces die out faster.
    private static let responsiveness: CGFloat = 6.5
    /// Ignore tilt below this (in G) so the ball doesn't drift on a table.
    private static let deadZone: CGFloat = 0.02
    /// Upward jerk (in G, along the axis out of the screen) that triggers a
    /// hop — a quick upward pop of the phone, Kirby Tilt 'n' Tumble style.
    private static let hopThreshold: Double = 0.75
    /// Time the ball spends in the air.
    private static let hopDuration: TimeInterval = 0.55
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

        setUpShadow()
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
        ball.zPosition = 10
        addChild(ball)
    }

    /// Soft drop shadow on the "floor". It tracks the ball's position; during
    /// a hop the ball grows while the shadow shrinks, selling the height.
    private func setUpShadow() {
        shadow.fillColor = SKColor(white: 0, alpha: 0.35)
        shadow.strokeColor = .clear
        shadow.zPosition = 5
        shadow.position = CGPoint(x: frame.midX, y: frame.midY)
        addChild(shadow)
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

        // A sharp upward pop of the phone (acceleration out of the screen,
        // beyond gravity) launches the ball into a hop.
        if !isAirborne,
           let jerk = motion.deviceMotion?.userAcceleration.z,
           jerk > GameScene.hopThreshold {
            hop()
        }

        shadow.position = CGPoint(x: ball.position.x, y: ball.position.y - 4)

        // While airborne the ball keeps its launch velocity — you can't
        // steer a ball that isn't touching the ground.
        if !isAirborne, var tilt = currentTilt() {
            if abs(tilt.dx) < GameScene.deadZone { tilt.dx = 0 }
            if abs(tilt.dy) < GameScene.deadZone { tilt.dy = 0 }

            // In portrait, the device's x/y axes line up with the screen's
            // x/y axes, so the tilt maps directly to a screen-space target
            // velocity that the ball converges on.
            var target = CGVector(
                dx: tilt.dx * GameScene.speedPerTilt,
                dy: tilt.dy * GameScene.speedPerTilt
            )
            let speed = hypot(target.dx, target.dy)
            if speed > GameScene.maxSpeed {
                target.dx *= GameScene.maxSpeed / speed
                target.dy *= GameScene.maxSpeed / speed
            }

            let blend = min(1, GameScene.responsiveness * dt)
            body.velocity = CGVector(
                dx: body.velocity.dx + (target.dx - body.velocity.dx) * blend,
                dy: body.velocity.dy + (target.dy - body.velocity.dy) * blend
            )
        }

        scrollSurfacePattern(velocity: body.velocity, dt: dt)
    }

    /// Pop the ball into the air: it grows (closer to the viewer) while its
    /// shadow shrinks, then lands with a small squash.
    private func hop() {
        isAirborne = true
        let half = GameScene.hopDuration / 2

        let rise = SKAction.scale(to: 1.45, duration: half)
        rise.timingMode = .easeOut
        let fall = SKAction.scale(to: 1.0, duration: half)
        fall.timingMode = .easeIn
        let squash = SKAction.sequence([
            .scaleX(to: 1.12, y: 0.88, duration: 0.06),
            .scaleX(to: 1.0, y: 1.0, duration: 0.09),
        ])
        ball.run(.sequence([rise, fall, squash])) { [weak self] in
            self?.isAirborne = false
        }

        let shadowOut = SKAction.group([
            .scale(to: 0.55, duration: half),
            .fadeAlpha(to: 0.15, duration: half),
        ])
        shadowOut.timingMode = .easeOut
        let shadowIn = SKAction.group([
            .scale(to: 1.0, duration: half),
            .fadeAlpha(to: 1.0, duration: half),
        ])
        shadowIn.timingMode = .easeIn
        shadow.run(.sequence([shadowOut, shadowIn]))
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
