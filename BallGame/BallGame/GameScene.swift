import SpriteKit
import CoreMotion
import UIKit

/// Milestone 1: a single ball on a single phone that rolls when you tilt the device.
final class GameScene: SKScene {

    private let motion = CMMotionManager()
    private let ball = SKShapeNode(circleOfRadius: GameScene.ballRadius)
    private let shadow = SKSpriteNode(texture: GameScene.softShadowTexture(radius: GameScene.ballRadius))
    /// True while the ball is in the air after a hop; tilt steering is
    /// suspended so the flight feels ballistic.
    private var isAirborne = false
    /// When the last hop started; used to enforce a cooldown so the jolt of
    /// the hand catching the phone can't chain into an accidental re-hop.
    private var lastHopTime: TimeInterval = -.infinity
    /// Thump felt in the hand when the ball lands.
    private let landingHaptic = UIImpactFeedbackGenerator(style: .medium)
    /// Follows the ball around the oversized world.
    private let cameraNode = SKCameraNode()
    /// The full playing field; larger than one screen.
    private var worldRect: CGRect = .zero
    /// Deep thud when the ball drops into a hole.
    private let fallHaptic = UIImpactFeedbackGenerator(style: .heavy)
    /// Holes currently open on the floor.
    private var holes: [SKSpriteNode] = []
    /// True while the ball is dropping into a hole / respawning.
    private var isFalling = false
    /// Dot pattern inside the ball; scrolling it with the velocity makes the
    /// ball read as rolling when seen from above.
    private let dotPattern = SKNode()
    private var lastUpdateTime: TimeInterval?

    /// Bumped on every code change so a stale build is obvious on screen.
    private static let buildNumber = 14

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
    /// Ceiling on how fast the speed may change (points/s per second), so
    /// sharp reversals stay smooth instead of doubling the kick.
    private static let maxAcceleration: CGFloat = 3200
    /// Ignore tilt below this (in G) so the ball doesn't drift on a table.
    private static let deadZone: CGFloat = 0.02
    /// Upward jerk (in G, along the axis out of the screen) that triggers a
    /// hop — a quick upward pop of the phone, Kirby Tilt 'n' Tumble style.
    private static let hopThreshold: Double = 0.9
    /// Time the ball spends in the air.
    private static let hopDuration: TimeInterval = 0.55
    /// Quiet period after a hop starts before another may trigger, so the
    /// catch-jolt at the end of the flick doesn't fire a second hop.
    private static let hopCooldown: TimeInterval = 1.0
    /// Radius of a hole in the floor.
    private static let holeRadius: CGFloat = 34
    /// How long a hole stays fully open before closing again.
    private static let holeLifetime: TimeInterval = 6.0
    /// Average pause between hole spawns (varies ±3 s).
    private static let holeSpawnInterval: TimeInterval = 5.0
    /// Grid spacing of the dots on the ball's surface.
    private static let dotSpacing: CGFloat = 19

    override func didMove(to view: SKView) {
        // The playing field spans a 2×2 grid of screens; the camera follows
        // the ball around it.
        worldRect = CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2)
        camera = cameraNode
        addChild(cameraNode)

        setUpBackground()

        // The ball is driven by forces from the tilt sensor each frame, not by
        // world gravity — force application also wakes a resting body, which
        // gravity changes alone do not.
        physicsWorld.gravity = .zero

        // Walls around the world so the ball can't leave (until Milestone 3,
        // where an open edge lets it roll onto the neighboring phone).
        physicsBody = SKPhysicsBody(edgeLoopFrom: worldRect)
        physicsBody?.friction = 0.1

        setUpShadow()
        setUpBall()
        setUpObstacles()
        setUpBuildLabel()
        startSpawningHoles()

        // Device motion separates gravity from shakes, giving smooth tilt data.
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates()
        motion.startAccelerometerUpdates() // fallback source
    }

    private func setUpBall() {
        ball.fillColor = SKColor(red: 1.0, green: 0.45, blue: 0.25, alpha: 1)
        ball.strokeColor = .clear
        ball.position = CGPoint(x: worldRect.midX, y: worldRect.midY)

        let body = SKPhysicsBody(circleOfRadius: GameScene.ballRadius)
        body.restitution = 0.55   // bounce off walls
        body.friction = 0.15
        body.linearDamping = 0.12 // slight rolling resistance so it settles
        body.allowsRotation = false // rolling is drawn via the surface pattern
        ball.physicsBody = body

        ball.addChild(makeSurfacePattern())
        ball.addChild(SKSpriteNode(texture: GameScene.ballGlossTexture(radius: GameScene.ballRadius)))
        ball.zPosition = 10
        addChild(ball)
    }

    /// Soft drop shadow on the "floor". It tracks the ball's position; during
    /// a hop the ball grows while the shadow shrinks, selling the height.
    private func setUpShadow() {
        shadow.zPosition = 5
        shadow.position = CGPoint(x: worldRect.midX, y: worldRect.midY)
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

    // MARK: - Procedural textures (the "real world" look, drawn in code)

    /// Warm wooden tabletop covering the whole world: one screen-sized tile
    /// (planks sized to line up at tile edges) repeated over the 2×2 field.
    private func setUpBackground() {
        let tileSize = size
        let texture = GameScene.woodTexture(size: tileSize)
        for column in 0..<2 {
            for row in 0..<2 {
                let tile = SKSpriteNode(texture: texture)
                tile.position = CGPoint(
                    x: tileSize.width * (CGFloat(column) + 0.5),
                    y: tileSize.height * (CGFloat(row) + 0.5)
                )
                tile.zPosition = 0
                addChild(tile)
            }
        }
    }

    /// Wooden blocks scattered around the field for the ball to bounce off.
    private func setUpObstacles() {
        let safeRadius: CGFloat = 170 // keep the spawn point clear
        let center = CGPoint(x: worldRect.midX, y: worldRect.midY)

        for _ in 0..<14 {
            let blockSize = CGSize(
                width: CGFloat.random(in: 70...150),
                height: CGFloat.random(in: 26...42)
            )
            var position = CGPoint.zero
            var attempts = 0
            repeat {
                position = CGPoint(
                    x: CGFloat.random(in: (worldRect.minX + 90)...(worldRect.maxX - 90)),
                    y: CGFloat.random(in: (worldRect.minY + 90)...(worldRect.maxY - 90))
                )
                attempts += 1
            } while hypot(position.x - center.x, position.y - center.y) < safeRadius
                && attempts < 12

            let block = SKShapeNode(rectOf: blockSize, cornerRadius: 7)
            block.fillColor = SKColor(red: 0.42, green: 0.28, blue: 0.16, alpha: 1)
            block.strokeColor = SKColor(red: 0.25, green: 0.15, blue: 0.08, alpha: 1)
            block.lineWidth = 2
            block.position = position
            block.zRotation = CGFloat.random(in: 0..<(2 * .pi))
            block.zPosition = 6

            // Drop shadow so the block sits above the table like the ball.
            let blockShadow = SKShapeNode(rectOf: blockSize, cornerRadius: 7)
            blockShadow.fillColor = SKColor(white: 0, alpha: 0.28)
            blockShadow.strokeColor = .clear
            blockShadow.position = CGPoint(x: 4, y: -5)
            blockShadow.zPosition = -1
            block.addChild(blockShadow)

            let body = SKPhysicsBody(rectangleOf: blockSize)
            body.isDynamic = false
            body.restitution = 0.5
            body.friction = 0.2
            block.physicsBody = body

            addChild(block)
        }
    }

    private static func woodTexture(size: CGSize) -> SKTexture {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2 // wood is soft-detail; halves texture memory
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext

            // Divides evenly into the tile width so planks line up when the
            // tile repeats across the world.
            let plankWidth: CGFloat = size.width / 4
            var x: CGFloat = 0
            while x < size.width {
                // Each plank gets its own slight tint.
                let shade = CGFloat.random(in: -0.045...0.045)
                UIColor(
                    red: 0.74 + shade,
                    green: 0.56 + shade * 0.9,
                    blue: 0.38 + shade * 0.8,
                    alpha: 1
                ).setFill()
                c.fill(CGRect(x: x, y: 0, width: plankWidth, height: size.height))

                // Wavy grain lines running down the plank.
                for _ in 0..<16 {
                    let grainX = x + CGFloat.random(in: 6...(plankWidth - 6))
                    let path = UIBezierPath()
                    path.move(to: CGPoint(x: grainX, y: -10))
                    var y: CGFloat = -10
                    var wobbleX = grainX
                    while y < size.height + 10 {
                        let nextY = y + CGFloat.random(in: 60...140)
                        let nextX = min(max(wobbleX + CGFloat.random(in: -7...7), x + 3),
                                        x + plankWidth - 3)
                        path.addQuadCurve(
                            to: CGPoint(x: nextX, y: nextY),
                            controlPoint: CGPoint(x: wobbleX + CGFloat.random(in: -8...8),
                                                  y: (y + nextY) / 2)
                        )
                        wobbleX = nextX
                        y = nextY
                    }
                    UIColor(red: 0.45, green: 0.32, blue: 0.20,
                            alpha: CGFloat.random(in: 0.05...0.14)).setStroke()
                    path.lineWidth = CGFloat.random(in: 0.8...2.2)
                    path.stroke()
                }

                // Seam between planks.
                UIColor(white: 0, alpha: 0.22).setFill()
                c.fill(CGRect(x: x + plankWidth - 1.5, y: 0, width: 1.5, height: size.height))
                x += plankWidth
            }

            // Vignette so the edges recede like a lit tabletop.
            if let vignette = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor.clear.cgColor,
                         UIColor(white: 0, alpha: 0.30).cgColor] as CFArray,
                locations: [0, 1]
            ) {
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                c.drawRadialGradient(
                    vignette,
                    startCenter: center,
                    startRadius: min(size.width, size.height) * 0.35,
                    endCenter: center,
                    endRadius: hypot(size.width, size.height) * 0.55,
                    options: .drawsAfterEndLocation
                )
            }
        }
        return SKTexture(image: image)
    }

    /// Sphere shading: a bright sheen toward the light and a soft falloff
    /// into shadow on the far side, overlaid on the flat ball color.
    private static func ballGlossTexture(radius: CGFloat) -> SKTexture {
        let diameter = radius * 2
        let size = CGSize(width: diameter, height: diameter)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            c.addEllipse(in: CGRect(origin: .zero, size: size))
            c.clip()

            if let shade = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor.clear.cgColor,
                         UIColor(red: 0.25, green: 0.05, blue: 0, alpha: 0.5).cgColor] as CFArray,
                locations: [0, 1]
            ) {
                c.drawRadialGradient(
                    shade,
                    startCenter: CGPoint(x: diameter * 0.38, y: diameter * 0.34),
                    startRadius: radius * 0.25,
                    endCenter: CGPoint(x: diameter * 0.5, y: diameter * 0.55),
                    endRadius: radius * 1.45,
                    options: .drawsAfterEndLocation
                )
            }

            if let sheen = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor(white: 1, alpha: 0.7).cgColor,
                         UIColor(white: 1, alpha: 0).cgColor] as CFArray,
                locations: [0, 1]
            ) {
                let lightCenter = CGPoint(x: diameter * 0.34, y: diameter * 0.28)
                c.drawRadialGradient(
                    sheen,
                    startCenter: lightCenter, startRadius: 0,
                    endCenter: lightCenter, endRadius: radius * 0.8,
                    options: []
                )
            }
        }
        return SKTexture(image: image)
    }

    /// Soft-edged drop shadow, like light diffusing under a real ball.
    private static func softShadowTexture(radius: CGFloat) -> SKTexture {
        let diameter = radius * 2.7
        let size = CGSize(width: diameter, height: diameter)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor(white: 0, alpha: 0.42).cgColor,
                         UIColor(white: 0, alpha: 0).cgColor] as CFArray,
                locations: [0, 1]
            ) {
                let center = CGPoint(x: diameter / 2, y: diameter / 2)
                ctx.cgContext.drawRadialGradient(
                    gradient,
                    startCenter: center, startRadius: radius * 0.3,
                    endCenter: center, endRadius: diameter / 2,
                    options: []
                )
            }
        }
        return SKTexture(image: image)
    }

    /// A hole bored into the wood: deep dark center, warm walls near the
    /// rim, and a faint lit inner wall opposite the light.
    private static func holeTexture(radius: CGFloat) -> SKTexture {
        let diameter = radius * 2
        let size = CGSize(width: diameter, height: diameter)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            c.addEllipse(in: CGRect(origin: .zero, size: size))
            c.clip()

            if let depth = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor(red: 0.02, green: 0.015, blue: 0.01, alpha: 1).cgColor,
                         UIColor(red: 0.18, green: 0.12, blue: 0.07, alpha: 1).cgColor] as CFArray,
                locations: [0, 1]
            ) {
                let center = CGPoint(x: diameter / 2, y: diameter / 2)
                c.drawRadialGradient(
                    depth,
                    startCenter: center, startRadius: radius * 0.15,
                    endCenter: center, endRadius: radius,
                    options: []
                )
            }

            // Inner wall catching a little light at the bottom edge.
            let lit = UIBezierPath(
                arcCenter: CGPoint(x: diameter / 2, y: diameter / 2),
                radius: radius - 2.5,
                startAngle: .pi * 0.15, endAngle: .pi * 0.85, clockwise: true
            )
            UIColor(red: 0.55, green: 0.4, blue: 0.25, alpha: 0.35).setStroke()
            lit.lineWidth = 2.5
            lit.stroke()
        }
        return SKTexture(image: image)
    }

    private func setUpBuildLabel() {
        let label = SKLabelNode(text: "build \(GameScene.buildNumber)")
        label.fontName = "Menlo"
        label.fontSize = 12
        label.fontColor = SKColor(red: 0.25, green: 0.15, blue: 0.08, alpha: 0.45)
        // HUD: pinned to the camera so it stays on screen while the world scrolls.
        label.position = CGPoint(x: 0, y: -size.height / 2 + 40)
        label.zPosition = 100
        cameraNode.addChild(label)
    }

    override func update(_ currentTime: TimeInterval) {
        let dt = min(currentTime - (lastUpdateTime ?? currentTime), 1.0 / 30.0)
        lastUpdateTime = currentTime

        guard let body = ball.physicsBody else { return }

        // A sharp upward pop of the phone (acceleration out of the screen,
        // beyond gravity) launches the ball into a hop.
        if !isAirborne, !isFalling,
           currentTime - lastHopTime > GameScene.hopCooldown,
           let jerk = motion.deviceMotion?.userAcceleration.z,
           jerk > GameScene.hopThreshold {
            lastHopTime = currentTime
            hop()
        }

        shadow.position = CGPoint(x: ball.position.x, y: ball.position.y - 4)

        // A grounded ball rolling over an open hole falls in; a hopping ball
        // sails right over it.
        if !isAirborne, !isFalling {
            for hole in holes where hole.xScale > 0.9 {
                let distance = hypot(
                    ball.position.x - hole.position.x,
                    ball.position.y - hole.position.y
                )
                if distance < GameScene.holeRadius * 0.8 {
                    fall(into: hole)
                    break
                }
            }
        }

        // While airborne the ball keeps its launch velocity — you can't
        // steer a ball that isn't touching the ground.
        if !isAirborne, !isFalling, var tilt = currentTilt() {
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
            var deltaX = (target.dx - body.velocity.dx) * blend
            var deltaY = (target.dy - body.velocity.dy) * blend

            // Cap the per-frame speed change so reversing direction ramps up
            // like starting from rest instead of whipping around at double
            // the usual acceleration.
            let maxDelta = GameScene.maxAcceleration * dt
            let delta = hypot(deltaX, deltaY)
            if delta > maxDelta, delta > 0 {
                deltaX *= maxDelta / delta
                deltaY *= maxDelta / delta
            }

            body.velocity = CGVector(
                dx: body.velocity.dx + deltaX,
                dy: body.velocity.dy + deltaY
            )
        }

        scrollSurfacePattern(velocity: body.velocity, dt: dt)
        followBallWithCamera()
    }

    /// Keep the ball in view, clamping so the camera never shows past the
    /// edge of the world.
    private func followBallWithCamera() {
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        cameraNode.position = CGPoint(
            x: min(max(ball.position.x, worldRect.minX + halfWidth), worldRect.maxX - halfWidth),
            y: min(max(ball.position.y, worldRect.minY + halfHeight), worldRect.maxY - halfHeight)
        )
    }

    /// Pop the ball into the air: it grows (closer to the viewer) while its
    /// shadow shrinks, then lands with a small squash.
    private func hop() {
        isAirborne = true
        let half = GameScene.hopDuration / 2

        landingHaptic.prepare()

        let rise = SKAction.scale(to: 1.45, duration: half)
        rise.timingMode = .easeOut
        let fall = SKAction.scale(to: 1.0, duration: half)
        fall.timingMode = .easeIn
        let land = SKAction.run { [weak self] in
            self?.didLand()
        }
        let squash = SKAction.sequence([
            .scaleX(to: 1.22, y: 0.78, duration: 0.07),
            .scaleX(to: 0.94, y: 1.06, duration: 0.08),
            .scaleX(to: 1.0, y: 1.0, duration: 0.07),
        ])
        // Steering returns at touchdown (in didLand); the squash afterwards
        // is purely cosmetic.
        ball.run(.sequence([rise, fall, land, squash]))

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

    // MARK: - Holes

    private func startSpawningHoles() {
        run(.repeatForever(.sequence([
            .wait(forDuration: GameScene.holeSpawnInterval, withRange: 6.0),
            .run { [weak self] in self?.spawnHole() },
        ])))
    }

    /// Open a hole at a random spot (never right under the ball), let it
    /// linger, then close it.
    private func spawnHole() {
        let inset = GameScene.holeRadius + 30
        var position = CGPoint.zero
        for _ in 0..<12 {
            position = CGPoint(
                x: CGFloat.random(in: (worldRect.minX + inset)...(worldRect.maxX - inset)),
                y: CGFloat.random(in: (worldRect.minY + inset)...(worldRect.maxY - inset))
            )
            if hypot(position.x - ball.position.x, position.y - ball.position.y) > 140 {
                break
            }
        }

        let hole = SKSpriteNode(texture: GameScene.holeTexture(radius: GameScene.holeRadius))
        hole.position = position
        hole.zPosition = 2
        hole.setScale(0)
        addChild(hole)
        holes.append(hole)

        let open = SKAction.scale(to: 1.0, duration: 0.25)
        open.timingMode = .easeOut
        let close = SKAction.scale(to: 0, duration: 0.25)
        close.timingMode = .easeIn
        hole.run(.sequence([
            open,
            .wait(forDuration: GameScene.holeLifetime),
            close,
            .run { [weak self, weak hole] in
                if let hole { self?.holes.removeAll { $0 === hole } }
            },
            .removeFromParent(),
        ]))
    }

    /// The ball got over an open hole: suck it in, then respawn at center.
    private func fall(into hole: SKSpriteNode) {
        isFalling = true
        fallHaptic.impactOccurred()
        ball.physicsBody?.velocity = .zero

        let suck = SKAction.group([
            .move(to: hole.position, duration: 0.12),
            .scale(to: 0.08, duration: 0.3),
            .fadeOut(withDuration: 0.3),
        ])
        suck.timingMode = .easeIn

        let respawn = SKAction.run { [weak self] in
            guard let self else { return }
            self.ball.position = CGPoint(x: self.worldRect.midX, y: self.worldRect.midY)
            self.ball.setScale(0.3)
            self.ball.run(.group([
                .scale(to: 1.0, duration: 0.25),
                .fadeIn(withDuration: 0.2),
            ])) { self.isFalling = false }
            self.shadow.run(.fadeIn(withDuration: 0.2))
        }

        shadow.run(.fadeOut(withDuration: 0.2))
        ball.run(.sequence([suck, .wait(forDuration: 0.6), respawn]))
    }

    /// Landing impact: haptic thump and a dust-ring shockwave rippling out
    /// across the floor from the touchdown point.
    private func didLand() {
        isAirborne = false
        landingHaptic.impactOccurred()

        let ring = SKShapeNode(circleOfRadius: GameScene.ballRadius)
        ring.position = ball.position
        ring.zPosition = 4
        ring.fillColor = .clear
        ring.strokeColor = SKColor(red: 0.93, green: 0.86, blue: 0.72, alpha: 0.65)
        ring.lineWidth = 3
        ring.setScale(0.6)
        addChild(ring)

        let expand = SKAction.scale(to: 2.1, duration: 0.35)
        expand.timingMode = .easeOut
        ring.run(.sequence([
            .group([expand, .fadeOut(withDuration: 0.35)]),
            .removeFromParent(),
        ]))

        // A few dust specks kicked out from under the ball.
        for _ in 0..<8 {
            let speck = SKShapeNode(circleOfRadius: CGFloat.random(in: 1.5...3))
            speck.fillColor = SKColor(red: 0.93, green: 0.86, blue: 0.72, alpha: 0.55)
            speck.strokeColor = .clear
            speck.position = ball.position
            speck.zPosition = 4
            addChild(speck)

            let angle = CGFloat.random(in: 0..<(2 * .pi))
            let distance = CGFloat.random(in: 28...55)
            let drift = SKAction.moveBy(
                x: cos(angle) * distance,
                y: sin(angle) * distance,
                duration: 0.3
            )
            drift.timingMode = .easeOut
            speck.run(.sequence([
                .group([drift, .fadeOut(withDuration: 0.3)]),
                .removeFromParent(),
            ]))
        }
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
