import SpriteKit
import CoreMotion
import UIKit
import MultipeerConnectivity

/// Adventure mode: hand-built courses on a wooden desk. Tilt to roll the
/// ball from the start to the glowing goal hole, past everyday desk objects,
/// without dropping into a trap hole. Flick the phone up to hop over traps.
final class GameScene: SKScene {

    // MARK: - Level definitions

    /// A desk object sitting on the table that the ball bounces off.
    struct Prop {
        enum Kind { case pencil, eraser, domino, coin }
        let kind: Kind
        /// Position in normalized world coordinates (0...1 on each axis).
        let position: CGPoint
        let rotation: CGFloat
    }

    /// A hand-built course. Positions are normalized to the world size so
    /// the same course plays on any screen size.
    struct Level {
        let screensWide: Int
        let screensTall: Int
        let start: CGPoint
        let goal: CGPoint
        let traps: [CGPoint]
        let props: [Prop]
    }

    private static let levels: [Level] = [
        // Level 1 — a gentle climb: learn to steer past a pencil and hop traps.
        Level(
            screensWide: 1, screensTall: 2,
            start: CGPoint(x: 0.5, y: 0.10),
            goal: CGPoint(x: 0.5, y: 0.92),
            traps: [
                CGPoint(x: 0.35, y: 0.42),
                CGPoint(x: 0.68, y: 0.60),
            ],
            props: [
                Prop(kind: .pencil, position: CGPoint(x: 0.5, y: 0.28), rotation: 0.35),
                Prop(kind: .eraser, position: CGPoint(x: 0.22, y: 0.55), rotation: -0.4),
                Prop(kind: .domino, position: CGPoint(x: 0.78, y: 0.74), rotation: 0.9),
                Prop(kind: .coin, position: CGPoint(x: 0.28, y: 0.80), rotation: 0),
            ]
        ),
        // Level 2 — pencil chicanes; the goal is tucked behind a coin bumper.
        Level(
            screensWide: 1, screensTall: 2,
            start: CGPoint(x: 0.2, y: 0.08),
            goal: CGPoint(x: 0.8, y: 0.93),
            traps: [
                CGPoint(x: 0.5, y: 0.28),
                CGPoint(x: 0.25, y: 0.48),
                CGPoint(x: 0.75, y: 0.55),
                CGPoint(x: 0.5, y: 0.74),
            ],
            props: [
                Prop(kind: .pencil, position: CGPoint(x: 0.38, y: 0.2), rotation: 1.15),
                Prop(kind: .pencil, position: CGPoint(x: 0.68, y: 0.42), rotation: -0.85),
                Prop(kind: .eraser, position: CGPoint(x: 0.18, y: 0.66), rotation: 0.3),
                Prop(kind: .domino, position: CGPoint(x: 0.55, y: 0.6), rotation: 0.4),
                Prop(kind: .coin, position: CGPoint(x: 0.82, y: 0.8), rotation: 0),
                Prop(kind: .coin, position: CGPoint(x: 0.35, y: 0.86), rotation: 0),
            ]
        ),
        // Level 3 — a wide open desk, diagonal trek with plenty of hazards.
        Level(
            screensWide: 2, screensTall: 2,
            start: CGPoint(x: 0.08, y: 0.10),
            goal: CGPoint(x: 0.92, y: 0.90),
            traps: [
                CGPoint(x: 0.3, y: 0.25),
                CGPoint(x: 0.55, y: 0.4),
                CGPoint(x: 0.2, y: 0.55),
                CGPoint(x: 0.75, y: 0.6),
                CGPoint(x: 0.45, y: 0.72),
                CGPoint(x: 0.85, y: 0.78),
            ],
            props: [
                Prop(kind: .pencil, position: CGPoint(x: 0.4, y: 0.15), rotation: -0.3),
                Prop(kind: .pencil, position: CGPoint(x: 0.65, y: 0.5), rotation: 0.75),
                Prop(kind: .pencil, position: CGPoint(x: 0.25, y: 0.7), rotation: 1.35),
                Prop(kind: .eraser, position: CGPoint(x: 0.55, y: 0.28), rotation: 0.5),
                Prop(kind: .eraser, position: CGPoint(x: 0.8, y: 0.35), rotation: -0.7),
                Prop(kind: .domino, position: CGPoint(x: 0.15, y: 0.38), rotation: 0.2),
                Prop(kind: .domino, position: CGPoint(x: 0.6, y: 0.85), rotation: -0.5),
                Prop(kind: .coin, position: CGPoint(x: 0.35, y: 0.55), rotation: 0),
                Prop(kind: .coin, position: CGPoint(x: 0.7, y: 0.72), rotation: 0),
            ]
        ),
    ]

    // MARK: - Nodes & state

    private let motion = CMMotionManager()
    private let ball = SKShapeNode(circleOfRadius: GameScene.ballRadius)
    private let shadow = SKSpriteNode(texture: GameScene.softShadowTexture(radius: GameScene.ballRadius))
    /// Dot pattern inside the ball; scrolling it with the velocity makes the
    /// ball read as rolling when seen from above.
    private let dotPattern = SKNode()
    /// Follows the ball around the oversized world.
    private let cameraNode = SKCameraNode()
    private var lastUpdateTime: TimeInterval?

    /// The full playing field; larger than one screen.
    private var worldRect: CGRect = .zero
    private var levelIndex = 0
    private var startPosition = CGPoint.zero
    private var goalPosition = CGPoint.zero
    /// Trap holes currently on the floor.
    private var holes: [SKSpriteNode] = []

    /// True while the ball is in the air after a hop; tilt steering is
    /// suspended so the flight feels ballistic.
    private var isAirborne = false
    /// True while the ball is dropping into a hole / respawning.
    private var isFalling = false
    /// True during the goal celebration and level switch.
    private var isTransitioning = false
    /// When the last hop started; used to enforce a cooldown so the jolt of
    /// the hand catching the phone can't chain into an accidental re-hop.
    private var lastHopTime: TimeInterval = -.infinity

    /// Thump felt in the hand when the ball lands.
    private let landingHaptic = UIImpactFeedbackGenerator(style: .medium)
    /// Deep thud when the ball drops into a hole.
    private let fallHaptic = UIImpactFeedbackGenerator(style: .heavy)
    /// Fanfare buzz when a level is cleared.
    private let goalHaptic = UINotificationFeedbackGenerator()

    // MARK: Multipeer state

    /// Connection to the neighboring phone (Milestone 3).
    private let multipeer = MultipeerManager()
    /// Holds the wall physics; side walls open while a peer is connected.
    private let wallsNode = SKNode()
    private var peerConnected = false
    /// False while the ball is visiting the other phone.
    private var ballIsHere = true
    private let connectionLabel = SKLabelNode()
    /// The style the ball is currently wearing. Travels with the ball, so a
    /// visiting ball keeps its owner's design.
    private var displayedColorIndex = 0
    private var displayedPatternIndex = 0
    private var displayedSkinData: Data?

    // MARK: - Tuning

    /// Bumped on every code change so a stale build is obvious on screen.
    private static let buildNumber = 26

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
    /// Grid spacing of the dots on the ball's surface.
    private static let dotSpacing: CGFloat = 19

    // MARK: - Scene lifecycle

    override func didMove(to view: SKView) {
        // The ball is driven by forces from the tilt sensor each frame, not by
        // world gravity — force application also wakes a resting body, which
        // gravity changes alone do not.
        physicsWorld.gravity = .zero

        // Device motion separates gravity from shakes, giving smooth tilt data.
        motion.deviceMotionUpdateInterval = 1.0 / 60.0
        motion.startDeviceMotionUpdates()
        motion.startAccelerometerUpdates() // fallback source

        buildBallIfNeeded()
        loadLevel(levelIndex)

        multipeer.onBallReceived = { [weak self] transfer in
            self?.receiveBall(transfer)
        }
        multipeer.start()
    }

    /// Tear down the old course and build the new one. The ball, shadow and
    /// camera are re-added each time; everything else is created fresh.
    private func loadLevel(_ index: Int) {
        removeAllActions()
        removeAllChildren()
        cameraNode.removeAllChildren()
        holes.removeAll()
        isAirborne = false
        isFalling = false
        isTransitioning = false
        lastUpdateTime = nil

        let level = GameScene.levels[index]
        worldRect = CGRect(
            x: 0, y: 0,
            width: size.width * CGFloat(level.screensWide),
            height: size.height * CGFloat(level.screensTall)
        )
        startPosition = denormalize(level.start)
        goalPosition = denormalize(level.goal)

        camera = cameraNode
        addChild(cameraNode)

        setUpBackground(level: level)

        addChild(wallsNode)
        rebuildWalls()

        for trap in level.traps {
            addTrap(at: denormalize(trap))
        }
        addGoal(at: goalPosition)
        for prop in level.props {
            addProp(prop)
        }

        // Ball and shadow return at the level's start.
        ballIsHere = true
        ball.isHidden = false
        shadow.isHidden = false
        ball.removeAllActions()
        ball.setScale(1)
        ball.alpha = 1
        ball.position = startPosition
        ball.physicsBody?.velocity = .zero
        addChild(ball)

        shadow.removeAllActions()
        shadow.setScale(1)
        shadow.alpha = 1
        shadow.zPosition = 5
        shadow.position = startPosition
        addChild(shadow)

        setUpHUD(levelNumber: index + 1)
        followBallWithCamera()
    }

    /// Solo play keeps a full wall loop; with a peer connected the left and
    /// right walls open so the ball can roll off to the neighboring phone.
    private func rebuildWalls() {
        wallsNode.removeAllChildren()

        func addWall(_ body: SKPhysicsBody) {
            body.friction = 0.1
            let node = SKNode()
            node.physicsBody = body
            wallsNode.addChild(node)
        }

        if peerConnected {
            addWall(SKPhysicsBody(
                edgeFrom: CGPoint(x: worldRect.minX, y: worldRect.minY),
                to: CGPoint(x: worldRect.maxX, y: worldRect.minY)
            ))
            addWall(SKPhysicsBody(
                edgeFrom: CGPoint(x: worldRect.minX, y: worldRect.maxY),
                to: CGPoint(x: worldRect.maxX, y: worldRect.maxY)
            ))
        } else {
            addWall(SKPhysicsBody(edgeLoopFrom: worldRect))
        }
    }

    private func denormalize(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: worldRect.minX + point.x * worldRect.width,
            y: worldRect.minY + point.y * worldRect.height
        )
    }

    // MARK: - Course construction

    /// The deck floor. Uses the real pallet photo (deck.png) rotated 90° so
    /// the slats run vertically, mirror-tiled across the world so the seams
    /// between repeats line up. Falls back to the code-drawn wood if the
    /// photo is missing from the bundle.
    private func setUpBackground(level: Level) {
        if let photo = UIImage(named: "deck") {
            tilePhotoBackground(photo)
        } else {
            tileProceduralBackground(level: level)
        }
    }

    private func tilePhotoBackground(_ photo: UIImage) {
        let texture = SKTexture(image: photo)
        // Rotated 90°, the photo's height becomes the on-screen width.
        // Scale so one tile spans exactly one screen width.
        let scale = size.width / photo.size.height
        let tileWidth = size.width
        let tileHeight = photo.size.width * scale

        let columns = Int(ceil(worldRect.width / tileWidth))
        let rows = Int(ceil(worldRect.height / tileHeight))
        for column in 0..<columns {
            for row in 0..<rows {
                let tile = SKSpriteNode(texture: texture)
                tile.zRotation = .pi / 2
                // Mirror alternate tiles so shared edges match seamlessly.
                // After the 90° rotation, the node's y axis lies along the
                // world's x axis and vice versa.
                tile.yScale = scale * (column % 2 == 0 ? 1 : -1)
                tile.xScale = scale * (row % 2 == 0 ? 1 : -1)
                tile.position = CGPoint(
                    x: tileWidth * (CGFloat(column) + 0.5),
                    y: tileHeight * (CGFloat(row) + 0.5)
                )
                tile.zPosition = 0
                addChild(tile)
            }
        }
    }

    private func tileProceduralBackground(level: Level) {
        let tileSize = size
        let texture = GameScene.woodTexture(size: tileSize)
        for column in 0..<level.screensWide {
            for row in 0..<level.screensTall {
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

    private func addTrap(at position: CGPoint) {
        let hole = SKSpriteNode(texture: GameScene.holeTexture(radius: GameScene.holeRadius))
        hole.position = position
        hole.zPosition = 2
        addChild(hole)
        holes.append(hole)
    }

    /// The goal: a hole ringed with pulsing golden light.
    private func addGoal(at position: CGPoint) {
        let hole = SKSpriteNode(texture: GameScene.holeTexture(radius: GameScene.holeRadius))
        hole.position = position
        hole.zPosition = 2
        addChild(hole)

        let glow = SKShapeNode(circleOfRadius: GameScene.holeRadius + 5)
        glow.fillColor = .clear
        glow.strokeColor = SKColor(red: 1.0, green: 0.82, blue: 0.35, alpha: 0.9)
        glow.lineWidth = 4
        glow.glowWidth = 6
        glow.position = position
        glow.zPosition = 3
        addChild(glow)

        let pulse = SKAction.sequence([
            .group([.scale(to: 1.12, duration: 0.7), .fadeAlpha(to: 0.55, duration: 0.7)]),
            .group([.scale(to: 1.0, duration: 0.7), .fadeAlpha(to: 0.9, duration: 0.7)]),
        ])
        pulse.timingMode = .easeInEaseOut
        glow.run(.repeatForever(pulse))
    }

    /// Place a desk object with its texture, silhouette shadow, and a static
    /// physics body so the ball bounces off it.
    private func addProp(_ prop: Prop) {
        let texture: SKTexture
        let body: SKPhysicsBody
        var restitution: CGFloat = 0.4

        switch prop.kind {
        case .pencil:
            texture = GameScene.pencilTexture()
            body = SKPhysicsBody(rectangleOf: texture.size())
            restitution = 0.45
        case .eraser:
            texture = GameScene.eraserTexture()
            body = SKPhysicsBody(rectangleOf: texture.size())
            restitution = 0.8 // rubber: bounciest wall on the desk
        case .domino:
            texture = GameScene.dominoTexture()
            body = SKPhysicsBody(rectangleOf: texture.size())
            restitution = 0.4
        case .coin:
            texture = GameScene.coinTexture()
            body = SKPhysicsBody(circleOfRadius: texture.size().width / 2)
            restitution = 0.85 // round bumper
        }

        let node = SKSpriteNode(texture: texture)
        node.position = denormalize(prop.position)
        node.zRotation = prop.rotation
        node.zPosition = 6

        // Silhouette drop shadow so the object sits above the table.
        let propShadow = SKSpriteNode(texture: texture)
        propShadow.color = .black
        propShadow.colorBlendFactor = 1
        propShadow.alpha = 0.25
        propShadow.position = CGPoint(x: 4, y: -5)
        propShadow.zPosition = -1
        node.addChild(propShadow)

        body.isDynamic = false
        body.restitution = restitution
        body.friction = 0.2
        node.physicsBody = body

        addChild(node)
    }

    private func setUpHUD(levelNumber: Int) {
        let levelLabel = SKLabelNode(text: "LEVEL \(levelNumber)")
        levelLabel.fontName = "AvenirNext-Bold"
        levelLabel.fontSize = 20
        levelLabel.fontColor = SKColor(red: 0.25, green: 0.15, blue: 0.08, alpha: 0.7)
        levelLabel.position = CGPoint(x: 0, y: size.height / 2 - 70)
        levelLabel.zPosition = 100
        cameraNode.addChild(levelLabel)

        let buildLabel = SKLabelNode(text: "build \(GameScene.buildNumber)")
        buildLabel.fontName = "Menlo"
        buildLabel.fontSize = 12
        buildLabel.fontColor = SKColor(red: 0.25, green: 0.15, blue: 0.08, alpha: 0.45)
        buildLabel.position = CGPoint(x: 0, y: -size.height / 2 + 40)
        buildLabel.zPosition = 100
        cameraNode.addChild(buildLabel)

        connectionLabel.fontName = "AvenirNext-DemiBold"
        connectionLabel.fontSize = 13
        connectionLabel.horizontalAlignmentMode = .left
        connectionLabel.position = CGPoint(x: -size.width / 2 + 16,
                                           y: size.height / 2 - 74)
        connectionLabel.zPosition = 100
        updateConnectionLabel()
        cameraNode.addChild(connectionLabel)
    }

    private func updateConnectionLabel() {
        if peerConnected {
            connectionLabel.text = "● \(multipeer.connectedPeerName ?? "つながった")"
            connectionLabel.fontColor = SKColor(red: 0.15, green: 0.6, blue: 0.25, alpha: 0.9)
        } else {
            connectionLabel.text = "○ 相手をさがしています…"
            connectionLabel.fontColor = SKColor(red: 0.25, green: 0.15, blue: 0.08, alpha: 0.5)
        }
    }

    // MARK: - Ball & custom styles

    /// The palette users pick the ball color from (must stay in sync with
    /// the customizer UI's swatches).
    static let ballColors: [UIColor] = [
        UIColor(red: 1.00, green: 0.45, blue: 0.25, alpha: 1), // orange
        UIColor(red: 0.86, green: 0.22, blue: 0.22, alpha: 1), // red
        UIColor(red: 0.25, green: 0.50, blue: 0.95, alpha: 1), // blue
        UIColor(red: 0.24, green: 0.70, blue: 0.40, alpha: 1), // green
        UIColor(red: 0.62, green: 0.38, blue: 0.90, alpha: 1), // purple
        UIColor(red: 0.95, green: 0.52, blue: 0.72, alpha: 1), // pink
        UIColor(red: 0.20, green: 0.70, blue: 0.72, alpha: 1), // teal
        UIColor(red: 0.95, green: 0.80, blue: 0.30, alpha: 1), // yellow
    ]

    enum BallPattern: Int, CaseIterable {
        case dots = 0, stripes, checker, plain
        /// A skin the user painted themselves on the drawing canvas.
        case custom = 4
    }

    /// Where the user's hand-drawn skin is stored.
    static var customSkinURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ballSkin.png")
    }

    static func loadCustomSkin() -> UIImage? {
        guard let data = try? Data(contentsOf: customSkinURL) else { return nil }
        return UIImage(data: data)
    }

    /// True when the ball wears a hand-drawn skin, which spins with motion
    /// instead of scrolling (a drawing can't tile seamlessly).
    private var isCustomSkin = false

    private func buildBallIfNeeded() {
        guard ball.physicsBody == nil else { return }

        ball.strokeColor = .clear

        let body = SKPhysicsBody(circleOfRadius: GameScene.ballRadius)
        body.restitution = 0.55   // bounce off walls
        body.friction = 0.15
        body.linearDamping = 0.12 // slight rolling resistance so it settles
        body.allowsRotation = false // rolling is drawn via the surface pattern
        ball.physicsBody = body

        let mask = SKShapeNode(circleOfRadius: GameScene.ballRadius - 1)
        mask.fillColor = .white
        mask.strokeColor = .clear
        let crop = SKCropNode()
        crop.maskNode = mask
        crop.addChild(dotPattern)
        ball.addChild(crop)

        ball.addChild(SKSpriteNode(texture: GameScene.ballGlossTexture(radius: GameScene.ballRadius)))
        ball.zPosition = 10

        applyBallStyle()
    }

    /// Read the saved color/pattern choice and restyle the ball. Called at
    /// launch and whenever the customizer changes a value.
    func applyBallStyle() {
        displayedColorIndex = UserDefaults.standard.integer(forKey: "ballColor")
        displayedPatternIndex = UserDefaults.standard.integer(forKey: "ballPattern")
        displayedSkinData =
            displayedPatternIndex == BallPattern.custom.rawValue
                ? try? Data(contentsOf: GameScene.customSkinURL) : nil
        applyDisplayedStyle()
    }

    /// Restyle the ball from the displayed-style state (either this player's
    /// saved choices, or the design that arrived with a visiting ball).
    private func applyDisplayedStyle() {
        let color = GameScene.ballColors[
            min(max(displayedColorIndex, 0), GameScene.ballColors.count - 1)
        ]
        let pattern = BallPattern(rawValue: displayedPatternIndex) ?? .dots

        dotPattern.position = .zero
        dotPattern.zRotation = 0

        if pattern == .custom, let data = displayedSkinData,
           let skin = UIImage(data: data) {
            isCustomSkin = true
            ball.fillColor = .white // shows through erased/transparent areas
            dotPattern.removeAllChildren()
            // Tile the drawing 3×3 with a period of one ball diameter, so the
            // scroller can wrap it like the dot pattern: the drawing slides
            // off one side and returns from the other — reads as the ball
            // rolling in any direction, vertical included.
            let texture = SKTexture(image: skin)
            let diameter = GameScene.ballRadius * 2
            for column in -1...1 {
                for row in -1...1 {
                    let sprite = SKSpriteNode(texture: texture)
                    sprite.size = CGSize(width: diameter, height: diameter)
                    sprite.position = CGPoint(x: CGFloat(column) * diameter,
                                              y: CGFloat(row) * diameter)
                    dotPattern.addChild(sprite)
                }
            }
            return
        }

        isCustomSkin = false
        ball.fillColor = color
        rebuildSurfacePattern(pattern, on: color)
    }

    /// A darker shade of the ball color for the surface pattern.
    private static func patternColor(for color: UIColor) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        return UIColor(red: r * 0.62, green: g * 0.62, blue: b * 0.62, alpha: 1)
    }

    /// Fill the scrolling pattern container. Every pattern must repeat with
    /// period `dotSpacing` on both axes, because the scroller wraps the
    /// container position by that spacing.
    private func rebuildSurfacePattern(_ pattern: BallPattern, on color: UIColor) {
        dotPattern.removeAllChildren()
        let spacing = GameScene.dotSpacing
        let dark = GameScene.patternColor(for: color)

        switch pattern {
        case .dots:
            var index = 0
            for x in stride(from: -spacing * 3, through: spacing * 3, by: spacing) {
                for y in stride(from: -spacing * 3, through: spacing * 3, by: spacing) {
                    let dot = SKShapeNode(circleOfRadius: 4.5)
                    dot.fillColor = dark
                    dot.strokeColor = .clear
                    // Offset every other row for a less grid-like look.
                    let stagger = (index % 2 == 0) ? spacing / 2 : 0
                    dot.position = CGPoint(x: x + stagger, y: y)
                    dotPattern.addChild(dot)
                    index += 1
                }
            }
        case .stripes:
            for y in stride(from: -spacing * 3, through: spacing * 3, by: spacing) {
                let stripe = SKShapeNode(rectOf: CGSize(width: spacing * 7, height: spacing * 0.42))
                stripe.fillColor = dark
                stripe.strokeColor = .clear
                stripe.position = CGPoint(x: 0, y: y)
                dotPattern.addChild(stripe)
            }
        case .checker:
            let square = spacing / 2
            for x in stride(from: -spacing * 3, through: spacing * 3, by: spacing) {
                for y in stride(from: -spacing * 3, through: spacing * 3, by: spacing) {
                    for offset in [CGPoint(x: 0, y: 0),
                                   CGPoint(x: square, y: square)] {
                        let cell = SKShapeNode(rectOf: CGSize(width: square, height: square))
                        cell.fillColor = dark
                        cell.strokeColor = .clear
                        cell.position = CGPoint(x: x + offset.x, y: y + offset.y)
                        dotPattern.addChild(cell)
                    }
                }
            }
        case .plain:
            break
        case .custom:
            // Handled in applyBallStyle (loads the drawn skin); nothing to
            // tile here. Reached only if the skin file is missing.
            break
        }
    }

    // MARK: - Game loop

    override func update(_ currentTime: TimeInterval) {
        let dt = min(currentTime - (lastUpdateTime ?? currentTime), 1.0 / 30.0)
        lastUpdateTime = currentTime

        guard let body = ball.physicsBody else { return }

        // Track the connection: open/close the side walls and, if the peer
        // vanished while holding the ball, bring it home.
        if multipeer.isConnected != peerConnected {
            peerConnected = multipeer.isConnected
            rebuildWalls()
            updateConnectionLabel()
            if !peerConnected, !ballIsHere {
                ballIsHere = true
                ball.isHidden = false
                shadow.isHidden = false
                ball.position = startPosition
                body.velocity = .zero
            }
        }

        guard ballIsHere else { return }

        // A sharp upward pop of the phone (acceleration out of the screen,
        // beyond gravity) launches the ball into a hop.
        if !isAirborne, !isFalling, !isTransitioning,
           currentTime - lastHopTime > GameScene.hopCooldown,
           let jerk = motion.deviceMotion?.userAcceleration.z,
           jerk > GameScene.hopThreshold {
            lastHopTime = currentTime
            hop()
        }

        shadow.position = CGPoint(x: ball.position.x, y: ball.position.y - 4)

        // The ball rolled past an open side edge: hand it to the other phone.
        if peerConnected, !isFalling, !isTransitioning,
           ball.position.x < worldRect.minX - GameScene.ballRadius
            || ball.position.x > worldRect.maxX + GameScene.ballRadius {
            sendBallToPeer()
            return
        }

        if !isAirborne, !isFalling, !isTransitioning {
            // Reaching the goal wins the level.
            let goalDistance = hypot(
                ball.position.x - goalPosition.x,
                ball.position.y - goalPosition.y
            )
            if goalDistance < GameScene.holeRadius * 0.8 {
                reachGoal()
            } else {
                // A grounded ball rolling over a trap falls in; a hopping
                // ball sails right over.
                for hole in holes {
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
        }

        // While airborne the ball keeps its launch velocity — you can't
        // steer a ball that isn't touching the ground.
        if !isAirborne, !isFalling, !isTransitioning, var tilt = currentTilt() {
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

    /// Seen from above, a rolling ball's top surface moves in the direction of
    /// travel — scroll the dots with the velocity and wrap them so the pattern
    /// never runs out.
    private func scrollSurfacePattern(velocity: CGVector, dt: CGFloat) {
        // Painted skins wrap with a period of one diameter (one full "turn");
        // the built-in patterns repeat every dotSpacing.
        let spacing = isCustomSkin ? GameScene.ballRadius * 2 : GameScene.dotSpacing
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

    // MARK: - Hop

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

    // MARK: - Falling & winning

    /// The ball rolled over a trap: suck it in, then restart the level.
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
            self.ball.position = self.startPosition
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

    // MARK: - Ball transfer between phones

    /// The ball left through an open side edge: ship its motion and style to
    /// the peer, then hide it here until it comes back.
    private func sendBallToPeer() {
        guard let body = ball.physicsBody else { return }

        let transfer = BallTransfer(
            yFraction: Double((ball.position.y - worldRect.minY) / worldRect.height),
            velocityDX: Double(body.velocity.dx),
            velocityDY: Double(body.velocity.dy),
            exitedRightEdge: ball.position.x > worldRect.midX,
            colorIndex: displayedColorIndex,
            patternIndex: displayedPatternIndex,
            skinPNG: displayedPatternIndex == BallPattern.custom.rawValue
                ? displayedSkinData : nil
        )
        multipeer.send(transfer)

        ballIsHere = false
        ball.isHidden = true
        shadow.isHidden = true
        body.velocity = .zero
        // Park the ball just inside the edge so the camera rests there.
        ball.position.x = min(max(ball.position.x, worldRect.minX + GameScene.ballRadius),
                              worldRect.maxX - GameScene.ballRadius)
    }

    /// A ball arrived from the other phone: it enters on the opposite side
    /// it left, keeping its speed and its owner's looks.
    private func receiveBall(_ transfer: BallTransfer) {
        guard let body = ball.physicsBody else { return }

        ballIsHere = true
        isFalling = false
        isAirborne = false
        ball.removeAllActions()
        shadow.removeAllActions()
        ball.setScale(1)
        ball.alpha = 1
        shadow.setScale(1)
        shadow.alpha = 1
        ball.isHidden = false
        shadow.isHidden = false

        displayedColorIndex = transfer.colorIndex
        displayedPatternIndex = transfer.patternIndex
        displayedSkinData = transfer.skinPNG
        applyDisplayedStyle()

        let x = transfer.exitedRightEdge
            ? worldRect.minX + GameScene.ballRadius
            : worldRect.maxX - GameScene.ballRadius
        let y = worldRect.minY + CGFloat(transfer.yFraction) * worldRect.height
        ball.position = CGPoint(x: x, y: min(max(y, worldRect.minY + GameScene.ballRadius),
                                             worldRect.maxY - GameScene.ballRadius))
        body.velocity = CGVector(dx: transfer.velocityDX, dy: transfer.velocityDY)
    }

    /// The ball reached the goal: celebrate, then move to the next level.
    private func reachGoal() {
        isTransitioning = true
        goalHaptic.notificationOccurred(.success)
        ball.physicsBody?.velocity = .zero

        let suck = SKAction.group([
            .move(to: goalPosition, duration: 0.12),
            .scale(to: 0.08, duration: 0.3),
            .fadeOut(withDuration: 0.3),
        ])
        suck.timingMode = .easeIn
        ball.run(suck)
        shadow.run(.fadeOut(withDuration: 0.2))

        // Golden burst from the goal.
        for _ in 0..<3 {
            let ring = SKShapeNode(circleOfRadius: GameScene.holeRadius)
            ring.position = goalPosition
            ring.zPosition = 8
            ring.fillColor = .clear
            ring.strokeColor = SKColor(red: 1.0, green: 0.82, blue: 0.35, alpha: 0.85)
            ring.lineWidth = 3
            ring.setScale(0.5)
            addChild(ring)
            let expand = SKAction.scale(to: CGFloat.random(in: 2.2...3.2),
                                        duration: TimeInterval.random(in: 0.5...0.8))
            expand.timingMode = .easeOut
            ring.run(.sequence([
                .group([expand, .fadeOut(withDuration: 0.7)]),
                .removeFromParent(),
            ]))
        }

        let isLastLevel = levelIndex == GameScene.levels.count - 1
        let banner = SKLabelNode(text: isLastLevel ? "ALL CLEAR!" : "LEVEL \(levelIndex + 1) CLEAR!")
        banner.fontName = "AvenirNext-Bold"
        banner.fontSize = 34
        banner.fontColor = SKColor(red: 0.25, green: 0.15, blue: 0.08, alpha: 1)
        banner.position = .zero
        banner.zPosition = 100
        banner.setScale(0.1)
        cameraNode.addChild(banner)
        let popIn = SKAction.scale(to: 1.0, duration: 0.3)
        popIn.timingMode = .easeOut
        banner.run(popIn)

        run(.sequence([
            .wait(forDuration: 1.8),
            .run { [weak self] in
                guard let self else { return }
                self.levelIndex = (self.levelIndex + 1) % GameScene.levels.count
                self.loadLevel(self.levelIndex)
            },
        ]))
    }

    // MARK: - Procedural textures (the "real world" look, drawn in code)

    /// Sun-bleached wooden pallet, vertical orientation: pale cream slats
    /// running top-to-bottom with narrow gaps, horizontal support battens
    /// and gray ground visible through the gaps, nail heads at each batten
    /// crossing, occasional knots and plank seams.
    private static func woodTexture(size: CGSize) -> SKTexture {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2 // wood is soft-detail; halves texture memory
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let c = ctx.cgContext

            // Ground under the pallet: light warm gray, in shadow.
            UIColor(red: 0.58, green: 0.56, blue: 0.52, alpha: 1).setFill()
            c.fill(CGRect(origin: .zero, size: size))
            for _ in 0..<10 {
                UIColor(white: 0, alpha: CGFloat.random(in: 0.04...0.09)).setFill()
                let w = CGFloat.random(in: 60...180)
                UIBezierPath(ovalIn: CGRect(
                    x: CGFloat.random(in: -40...size.width),
                    y: CGFloat.random(in: -40...size.height),
                    width: w, height: w * 0.6
                )).fill()
            }

            // Horizontal support battens under the slats. Spacing divides the
            // tile height so they line up when the tile repeats.
            let battenSpacing = size.height / 4
            let battenHeight: CGFloat = 30
            var battenYs: [CGFloat] = []
            var by: CGFloat = battenSpacing / 2
            while by < size.height {
                battenYs.append(by)
                let rect = CGRect(x: 0, y: by - battenHeight / 2,
                                  width: size.width, height: battenHeight)
                UIColor(red: 0.68, green: 0.58, blue: 0.45, alpha: 1).setFill()
                c.fill(rect)
                UIColor(white: 0, alpha: 0.25).setFill()
                c.fill(CGRect(x: 0, y: rect.maxY - 3, width: size.width, height: 3))
                by += battenSpacing
            }

            // Vertical slats. Width divides the tile width for seamless repeat.
            let slatWidth: CGFloat = size.width / 7
            let gap: CGFloat = 7
            var x: CGFloat = 0
            var column = 0
            while x < size.width {
                let slatRect = CGRect(x: x + gap / 2, y: 0,
                                      width: slatWidth - gap, height: size.height)

                // Some slats are two shorter planks with a seam.
                let seamY: CGFloat? = (column % 3 == 1)
                    ? size.height * CGFloat.random(in: 0.3...0.7) : nil
                let segments: [CGRect]
                if let seamY {
                    segments = [
                        CGRect(x: slatRect.minX, y: 0, width: slatRect.width, height: seamY),
                        CGRect(x: slatRect.minX, y: seamY,
                               width: slatRect.width, height: size.height - seamY),
                    ]
                } else {
                    segments = [slatRect]
                }

                for segment in segments {
                    // Pale bleached cream, each plank its own tint.
                    let shade = CGFloat.random(in: -0.04...0.04)
                    UIColor(
                        red: 0.87 + shade,
                        green: 0.80 + shade,
                        blue: 0.67 + shade * 0.9,
                        alpha: 1
                    ).setFill()
                    c.fill(segment)
                }

                // Fine vertical grain streaks.
                for _ in 0..<9 {
                    let grainX = slatRect.minX + CGFloat.random(in: 3...(slatRect.width - 3))
                    let path = UIBezierPath()
                    path.move(to: CGPoint(x: grainX, y: -10))
                    var gy: CGFloat = -10
                    var wobbleX = grainX
                    while gy < size.height + 10 {
                        let nextY = gy + CGFloat.random(in: 80...170)
                        let nextX = min(max(wobbleX + CGFloat.random(in: -4...4),
                                            slatRect.minX + 2), slatRect.maxX - 2)
                        path.addQuadCurve(
                            to: CGPoint(x: nextX, y: nextY),
                            controlPoint: CGPoint(x: wobbleX + CGFloat.random(in: -5...5),
                                                  y: (gy + nextY) / 2)
                        )
                        wobbleX = nextX
                        gy = nextY
                    }
                    UIColor(red: 0.62, green: 0.53, blue: 0.40,
                            alpha: CGFloat.random(in: 0.05...0.13)).setStroke()
                    path.lineWidth = CGFloat.random(in: 0.6...1.6)
                    path.stroke()
                }

                // Occasional knot.
                if column % 4 == 2 {
                    let knotCenter = CGPoint(
                        x: slatRect.midX + CGFloat.random(in: -8...8),
                        y: CGFloat.random(in: size.height * 0.15...size.height * 0.85)
                    )
                    UIColor(red: 0.55, green: 0.45, blue: 0.32, alpha: 0.9).setFill()
                    UIBezierPath(ovalIn: CGRect(x: knotCenter.x - 4, y: knotCenter.y - 6,
                                                width: 8, height: 12)).fill()
                    UIColor(red: 0.45, green: 0.36, blue: 0.25, alpha: 0.7).setStroke()
                    let ring = UIBezierPath(ovalIn: CGRect(x: knotCenter.x - 7, y: knotCenter.y - 10,
                                                           width: 14, height: 20))
                    ring.lineWidth = 1.2
                    ring.stroke()
                }

                // Seam between the two planks of a split slat.
                if let seamY {
                    UIColor(white: 0, alpha: 0.3).setFill()
                    c.fill(CGRect(x: slatRect.minX, y: seamY - 1.5,
                                  width: slatRect.width, height: 3))
                }

                // Slat edges: lit left edge, shadowed right edge.
                UIColor(white: 1, alpha: 0.16).setFill()
                c.fill(CGRect(x: slatRect.minX, y: 0, width: 2, height: size.height))
                UIColor(white: 0, alpha: 0.16).setFill()
                c.fill(CGRect(x: slatRect.maxX - 2, y: 0, width: 2, height: size.height))

                // Nail heads where the slat crosses each batten.
                for nailY in battenYs {
                    let nailX = slatRect.midX + CGFloat.random(in: -5...5)
                    UIColor(red: 0.42, green: 0.39, blue: 0.35, alpha: 1).setFill()
                    UIBezierPath(ovalIn: CGRect(x: nailX - 2.2, y: nailY - 2.2,
                                                width: 4.4, height: 4.4)).fill()
                    UIColor(white: 1, alpha: 0.4).setFill()
                    UIBezierPath(ovalIn: CGRect(x: nailX - 1.2, y: nailY - 1.2,
                                                width: 1.8, height: 1.8)).fill()
                }

                x += slatWidth
                column += 1
            }

            // Gentle outdoor light falloff.
            if let vignette = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor.clear.cgColor,
                         UIColor(white: 0, alpha: 0.12).cgColor] as CFArray,
                locations: [0, 1]
            ) {
                let center = CGPoint(x: size.width / 2, y: size.height / 2)
                c.drawRadialGradient(
                    vignette,
                    startCenter: center,
                    startRadius: min(size.width, size.height) * 0.4,
                    endCenter: center,
                    endRadius: hypot(size.width, size.height) * 0.6,
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

    /// A hole smashed through the deck: a jagged opening with splintered
    /// wood fibers poking into the darkness and hairline cracks running out
    /// into the surrounding slats.
    private static func holeTexture(radius: CGFloat) -> SKTexture {
        // Canvas is oversized so cracks and splinters can extend past the rim.
        let canvas = radius * 2.7
        let size = CGSize(width: canvas, height: canvas)
        let center = CGPoint(x: canvas / 2, y: canvas / 2)

        // Jagged rim: irregular radii around the circle.
        var rimPoints: [CGPoint] = []
        let segments = 15
        for i in 0..<segments {
            let angle = (CGFloat(i) / CGFloat(segments)) * 2 * .pi
                + CGFloat.random(in: -0.1...0.1)
            let r = radius * CGFloat.random(in: 0.74...1.02)
            rimPoints.append(CGPoint(
                x: center.x + cos(angle) * r,
                y: center.y + sin(angle) * r
            ))
        }

        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext

            // Hairline cracks radiating outward from the break.
            for _ in 0..<5 {
                let angle = CGFloat.random(in: 0..<(2 * .pi))
                let start = CGPoint(
                    x: center.x + cos(angle) * radius * 0.9,
                    y: center.y + sin(angle) * radius * 0.9
                )
                let end = CGPoint(
                    x: center.x + cos(angle + CGFloat.random(in: -0.25...0.25)) * radius * CGFloat.random(in: 1.15...1.32),
                    y: center.y + sin(angle + CGFloat.random(in: -0.25...0.25)) * radius * CGFloat.random(in: 1.15...1.32)
                )
                let crack = UIBezierPath()
                crack.move(to: start)
                crack.addQuadCurve(
                    to: end,
                    controlPoint: CGPoint(
                        x: (start.x + end.x) / 2 + CGFloat.random(in: -6...6),
                        y: (start.y + end.y) / 2 + CGFloat.random(in: -6...6)
                    )
                )
                UIColor(red: 0.12, green: 0.09, blue: 0.06,
                        alpha: CGFloat.random(in: 0.5...0.8)).setStroke()
                crack.lineWidth = CGFloat.random(in: 1.0...2.2)
                crack.stroke()
            }

            // The jagged opening itself.
            let rim = UIBezierPath()
            rim.move(to: rimPoints[0])
            for point in rimPoints.dropFirst() { rim.addLine(to: point) }
            rim.close()

            c.saveGState()
            rim.addClip()
            if let depth = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor(red: 0.02, green: 0.015, blue: 0.01, alpha: 1).cgColor,
                         UIColor(red: 0.13, green: 0.09, blue: 0.06, alpha: 1).cgColor] as CFArray,
                locations: [0, 1]
            ) {
                c.drawRadialGradient(
                    depth,
                    startCenter: center, startRadius: radius * 0.1,
                    endCenter: center, endRadius: radius,
                    options: .drawsAfterEndLocation
                )
            }

            // Splintered fibers poking into the opening from the rim.
            for i in 0..<10 {
                let angle = (CGFloat(i) / 10) * 2 * .pi + CGFloat.random(in: -0.2...0.2)
                let baseR = radius * CGFloat.random(in: 0.8...0.95)
                let tipR = baseR - CGFloat.random(in: 10...20)
                let spread = CGFloat.random(in: 0.06...0.12)
                let splinter = UIBezierPath()
                splinter.move(to: CGPoint(
                    x: center.x + cos(angle - spread) * baseR,
                    y: center.y + sin(angle - spread) * baseR
                ))
                splinter.addLine(to: CGPoint(
                    x: center.x + cos(angle + spread) * baseR,
                    y: center.y + sin(angle + spread) * baseR
                ))
                splinter.addLine(to: CGPoint(
                    x: center.x + cos(angle) * tipR,
                    y: center.y + sin(angle) * tipR
                ))
                splinter.close()
                UIColor(red: 0.84 + CGFloat.random(in: -0.05...0.05),
                        green: 0.76 + CGFloat.random(in: -0.05...0.05),
                        blue: 0.61,
                        alpha: 1).setFill()
                splinter.fill()
            }
            c.restoreGState()

            // Torn light edge where the wood snapped.
            UIColor(red: 0.93, green: 0.87, blue: 0.74, alpha: 0.6).setStroke()
            rim.lineWidth = 1.8
            rim.stroke()
        }
        return SKTexture(image: image)
    }

    /// A yellow pencil seen from above: painted body, sharpened wooden tip
    /// with graphite, and a pink eraser behind a metal ferrule.
    private static func pencilTexture() -> SKTexture {
        let size = CGSize(width: 190, height: 16)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext

            // Painted body.
            let bodyRect = CGRect(x: 26, y: 0, width: 138, height: 16)
            UIColor(red: 0.93, green: 0.72, blue: 0.18, alpha: 1).setFill()
            c.fill(bodyRect)
            // Facet shading lines along the body.
            UIColor(red: 0.78, green: 0.58, blue: 0.10, alpha: 1).setFill()
            c.fill(CGRect(x: 26, y: 0, width: 138, height: 3.5))
            UIColor(red: 1.0, green: 0.83, blue: 0.38, alpha: 1).setFill()
            c.fill(CGRect(x: 26, y: 5.5, width: 138, height: 3))

            // Sharpened wooden tip.
            let wood = UIBezierPath()
            wood.move(to: CGPoint(x: 26, y: 0))
            wood.addLine(to: CGPoint(x: 26, y: 16))
            wood.addLine(to: CGPoint(x: 6, y: 8))
            wood.close()
            UIColor(red: 0.87, green: 0.72, blue: 0.52, alpha: 1).setFill()
            wood.fill()
            // Graphite point.
            let graphite = UIBezierPath()
            graphite.move(to: CGPoint(x: 9, y: 6.5))
            graphite.addLine(to: CGPoint(x: 9, y: 9.5))
            graphite.addLine(to: CGPoint(x: 0, y: 8))
            graphite.close()
            UIColor(red: 0.25, green: 0.25, blue: 0.28, alpha: 1).setFill()
            graphite.fill()

            // Metal ferrule.
            UIColor(red: 0.75, green: 0.76, blue: 0.80, alpha: 1).setFill()
            c.fill(CGRect(x: 164, y: 0, width: 12, height: 16))
            UIColor(red: 0.55, green: 0.56, blue: 0.62, alpha: 1).setFill()
            c.fill(CGRect(x: 167, y: 0, width: 2, height: 16))
            c.fill(CGRect(x: 171, y: 0, width: 2, height: 16))

            // Pink eraser.
            let eraserRect = CGRect(x: 176, y: 0, width: 14, height: 16)
            UIColor(red: 0.94, green: 0.6, blue: 0.62, alpha: 1).setFill()
            UIBezierPath(roundedRect: eraserRect,
                         byRoundingCorners: [.topRight, .bottomRight],
                         cornerRadii: CGSize(width: 7, height: 7)).fill()
        }
        return SKTexture(image: image)
    }

    /// A white eraser in a blue paper sleeve.
    private static func eraserTexture() -> SKTexture {
        let size = CGSize(width: 76, height: 38)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext

            let body = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size),
                                    cornerRadius: 6)
            UIColor(red: 0.96, green: 0.96, blue: 0.94, alpha: 1).setFill()
            body.fill()
            // Subtle bottom shading for thickness.
            UIColor(red: 0.8, green: 0.8, blue: 0.78, alpha: 1).setFill()
            c.fill(CGRect(x: 3, y: 30, width: 70, height: 5))

            // Paper sleeve.
            UIColor(red: 0.20, green: 0.32, blue: 0.62, alpha: 1).setFill()
            c.fill(CGRect(x: 20, y: 0, width: 36, height: 38))
            UIColor(white: 1, alpha: 0.85).setFill()
            c.fill(CGRect(x: 24, y: 15, width: 28, height: 3))
            c.fill(CGRect(x: 28, y: 22, width: 20, height: 2))
        }
        return SKTexture(image: image)
    }

    /// A domino tile lying flat: ivory face, dividing line, 3|5 pips.
    private static func dominoTexture() -> SKTexture {
        let size = CGSize(width: 66, height: 34)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext

            let body = UIBezierPath(roundedRect: CGRect(origin: .zero, size: size),
                                    cornerRadius: 5)
            UIColor(red: 0.97, green: 0.95, blue: 0.90, alpha: 1).setFill()
            body.fill()
            UIColor(red: 0.75, green: 0.72, blue: 0.66, alpha: 1).setStroke()
            body.lineWidth = 1.5
            body.stroke()

            // Divider.
            UIColor(red: 0.55, green: 0.52, blue: 0.48, alpha: 1).setFill()
            c.fill(CGRect(x: 32, y: 4, width: 2, height: 26))

            func pip(_ x: CGFloat, _ y: CGFloat) {
                UIColor(red: 0.15, green: 0.17, blue: 0.3, alpha: 1).setFill()
                UIBezierPath(ovalIn: CGRect(x: x - 2.8, y: y - 2.8,
                                            width: 5.6, height: 5.6)).fill()
            }
            // Left: 3 pips.
            pip(9, 8); pip(16, 17); pip(23, 26)
            // Right: 5 pips.
            pip(42, 8); pip(58, 8); pip(50, 17); pip(42, 26); pip(58, 26)
        }
        return SKTexture(image: image)
    }

    /// A golden coin: rim, inner ring, and a bright crescent.
    private static func coinTexture() -> SKTexture {
        let diameter: CGFloat = 46
        let size = CGSize(width: diameter, height: diameter)
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            let c = ctx.cgContext
            let full = CGRect(origin: .zero, size: size)

            UIColor(red: 0.86, green: 0.68, blue: 0.24, alpha: 1).setFill()
            UIBezierPath(ovalIn: full).fill()

            // Milled rim.
            UIColor(red: 0.66, green: 0.50, blue: 0.14, alpha: 1).setStroke()
            let rim = UIBezierPath(ovalIn: full.insetBy(dx: 1.5, dy: 1.5))
            rim.lineWidth = 2.5
            rim.stroke()

            // Inner ring like an engraved face.
            UIColor(red: 0.72, green: 0.55, blue: 0.16, alpha: 1).setStroke()
            let inner = UIBezierPath(ovalIn: full.insetBy(dx: 8, dy: 8))
            inner.lineWidth = 1.8
            inner.stroke()

            // Crescent shine toward the light.
            if let sheen = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [UIColor(white: 1, alpha: 0.55).cgColor,
                         UIColor(white: 1, alpha: 0).cgColor] as CFArray,
                locations: [0, 1]
            ) {
                c.addEllipse(in: full.insetBy(dx: 2, dy: 2))
                c.clip()
                let lightCenter = CGPoint(x: diameter * 0.32, y: diameter * 0.3)
                c.drawRadialGradient(
                    sheen,
                    startCenter: lightCenter, startRadius: 0,
                    endCenter: lightCenter, endRadius: diameter * 0.45,
                    options: []
                )
            }
        }
        return SKTexture(image: image)
    }
}

// MARK: - Phone-to-phone ball transfer (Milestone 3)

/// Everything the ball carries when it hops to the neighboring phone.
struct BallTransfer: Codable {
    /// Vertical position at the moment of exit, as a 0...1 fraction of the
    /// world height, so different screen sizes line up sensibly.
    let yFraction: Double
    let velocityDX: Double
    let velocityDY: Double
    /// True if it left through the right edge (so it enters on the left).
    let exitedRightEdge: Bool
    let colorIndex: Int
    let patternIndex: Int
    let skinPNG: Data?
}

/// Finds the nearby phone running the game (Multipeer Connectivity works
/// over Bluetooth and local Wi-Fi, no server needed), auto-connects, and
/// ferries the ball back and forth.
final class MultipeerManager: NSObject {
    private static let serviceType = "kkk-ball"

    // iOS reports a generic device name for privacy, so both phones could be
    // called "iPhone" — the random suffix keeps the tie-break working.
    private let peerID = MCPeerID(
        displayName: "\(UIDevice.current.name)-\(Int.random(in: 100...999))"
    )

    private lazy var session: MCSession = {
        let session = MCSession(peer: peerID,
                                securityIdentity: nil,
                                encryptionPreference: .required)
        session.delegate = self
        return session
    }()
    private lazy var advertiser = MCNearbyServiceAdvertiser(
        peer: peerID, discoveryInfo: nil, serviceType: Self.serviceType)
    private lazy var browser = MCNearbyServiceBrowser(
        peer: peerID, serviceType: Self.serviceType)

    private(set) var isConnected = false
    private(set) var connectedPeerName: String?
    /// Called on the main thread when a ball arrives from the peer.
    var onBallReceived: ((BallTransfer) -> Void)?

    func start() {
        advertiser.delegate = self
        browser.delegate = self
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    func send(_ transfer: BallTransfer) {
        guard !session.connectedPeers.isEmpty,
              let data = try? JSONEncoder().encode(transfer) else { return }
        try? session.send(data, toPeers: session.connectedPeers, with: .reliable)
    }
}

extension MultipeerManager: MCSessionDelegate {
    func session(_ session: MCSession, peer peerID: MCPeerID,
                 didChange state: MCSessionState) {
        DispatchQueue.main.async {
            self.isConnected = !session.connectedPeers.isEmpty
            self.connectedPeerName = session.connectedPeers.first?.displayName
        }
    }

    func session(_ session: MCSession, didReceive data: Data,
                 fromPeer peerID: MCPeerID) {
        guard let transfer = try? JSONDecoder().decode(BallTransfer.self,
                                                       from: data) else { return }
        DispatchQueue.main.async {
            self.onBallReceived?(transfer)
        }
    }

    // Unused stream/resource channels.
    func session(_ session: MCSession, didReceive stream: InputStream,
                 withName streamName: String, fromPeer peerID: MCPeerID) {}
    func session(_ session: MCSession,
                 didStartReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, with progress: Progress) {}
    func session(_ session: MCSession,
                 didFinishReceivingResourceWithName resourceName: String,
                 fromPeer peerID: MCPeerID, at localURL: URL?, error: Error?) {}
}

extension MultipeerManager: MCNearbyServiceAdvertiserDelegate {
    func advertiser(_ advertiser: MCNearbyServiceAdvertiser,
                    didReceiveInvitationFromPeer peerID: MCPeerID,
                    withContext context: Data?,
                    invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        invitationHandler(true, session)
    }
}

extension MultipeerManager: MCNearbyServiceBrowserDelegate {
    func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                 withDiscoveryInfo info: [String: String]?) {
        // Only the lexicographically smaller name sends the invitation, so
        // the two phones don't both invite each other at once.
        if self.peerID.displayName < peerID.displayName {
            browser.invitePeer(peerID, to: session, withContext: nil, timeout: 15)
        }
    }

    func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}
}
