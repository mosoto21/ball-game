import SpriteKit
import CoreMotion
import UIKit
import MultipeerConnectivity
import NearbyInteraction
import simd

/// Device-language localization, the way international apps behave: a
/// phone set to Japanese shows Japanese, every other language falls back
/// to English. (iOS follows the device language, not the store country.)
enum L10n {
    static let isJapanese = Locale.preferredLanguages.first?.hasPrefix("ja") ?? false
    /// Pick the string for the device language.
    static func t(_ ja: String, _ en: String) -> String { isJapanese ? ja : en }
}

/// High-score mode: an endless climb up the deck. Tilt to roll, flick to
/// hop. Bands of obstacles are generated as you go — full-width hurdles
/// you must hop, round bumpers that fling the ball back, narrow bridges
/// over chasms where falling ends the run. Score is how far you climbed;
/// your best is saved. With a second phone, the ball still rolls across
/// side edges, and a phone held underneath can catch a ball that falls
/// into a chasm — the co-op safety net.
final class GameScene: SKScene {

    // MARK: - Endless course definitions

    /// One obstacle on the deck. Circles, bumpers, bars and hurdles are
    /// low — a hopping ball sails over them (hurdles span the whole screen,
    /// so hopping is the only way past). Walls are tall and can never be
    /// jumped. Bumpers fling the ball back hard.
    private enum Obstacle {
        case circle
        case bumper
        case bar(length: CGFloat)
        case hurdle(length: CGFloat)
        case wall(length: CGFloat)
    }

    /// A chasm band: everywhere inside `rect` is a deadly drop except the
    /// bridge strips crossing it.
    private struct VoidZone {
        let rect: CGRect
        let bridges: [CGRect]
        let nodes: [SKNode]
    }

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

    /// The full playing field; one screen wide, hundreds tall.
    private var worldRect: CGRect = .zero
    private var startPosition = CGPoint.zero
    /// Obstacles currently on the floor (used to keep drop landings clear).
    private var propNodes: [SKSpriteNode] = []
    /// Chasm bands currently active.
    private var voidZones: [VoidZone] = []
    /// Obstacle bands, tagged with the height above which they were
    /// spawned, so bands far below the ball can be torn down.
    private var bandNodes: [(maxY: CGFloat, nodes: [SKNode])] = []
    /// Where the next obstacle band will be generated.
    private var nextBandY: CGFloat = 0

    // Score: how high the ball has climbed this run.
    private var runStartY: CGFloat = 0
    private var maxHeight: CGFloat = 0
    private var bestScore = UserDefaults.standard.integer(forKey: "bestScore")
    private let scoreLabel = SKLabelNode()
    private let bestLabel = SKLabelNode()
    private var scoreMeters: Int {
        max(0, Int((maxHeight - runStartY) / GameScene.pointsPerMeter))
    }

    // Endless floor: a handful of tiles recycled as the camera climbs.
    private var floorTiles: [SKSpriteNode] = []
    private var floorTileHeight: CGFloat = 0
    private var floorMirrors = false

    // The collapse chasing the ball from below (the anti-stalling clock):
    // everything under chaseY has fallen away. Stop climbing and it
    // swallows the ball.
    private var chaseY: CGFloat = 0
    private let collapseNode = SKNode()

    // Physics categories: a hopping ball clears low garden objects but
    // never the tall fences or the world walls.
    private static let ballCategory: UInt32 = 1 << 0
    private static let lowPropCategory: UInt32 = 1 << 1
    private static let fenceCategory: UInt32 = 1 << 2
    private static let wallCategory: UInt32 = 1 << 3

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
    /// How this session is played, chosen on the menu. In multiplayer the
    /// physical arrangement is sensed live over UWB: side by side the ball
    /// passes across the open edges, stacked it drops through holes to the
    /// phone below. (Devices without UWB fall back to side-by-side play.)
    enum PlayMode {
        /// The classic climb, alone, with the collapse hunting from below.
        case solo
        /// Two phones, one shared ball, one shared score. No collapse.
        case coop
        /// Head-to-head (rules to be designed; not selectable yet).
        case versus
    }

    /// Where the other phone physically sits right now, from UWB direction
    /// crossed with gravity.
    enum PeerPlacement {
        case unknown, beside, below, above
    }

    private var playMode = PlayMode.solo
    private var multiplayerEnabled: Bool { playMode != .solo }
    private var isCoop: Bool { playMode == .coop }
    private var isVersus: Bool { playMode == .versus }

    // MARK: Versus state

    /// When the 60-second match clock started (first frame after both
    /// pressed READY). nil while waiting for an opponent.
    private var matchStartTime: TimeInterval?
    /// Seconds the ball has spent on THIS screen this match. Less is
    /// better — hot-potato rules.
    private var myHoldTime: TimeInterval = 0
    /// The clock ran out; the board is frozen while results settle.
    private var matchOver = false
    /// The hold time the opponent reported at match end.
    private var peerHoldReported: Double?
    private var versusResultShown = false
    /// True once the timer entered its final-10-seconds alarm look.
    private var versusTimerUrgent = false
    private let versusTimerLabel = SKLabelNode()
    private let versusHoldLabel = SKLabelNode()
    /// Maze bars and bumpers of the current versus board.
    private var versusObstacleNodes: [SKNode] = []

    /// Co-op, while the ball is on the other phone: the camera height the
    /// peer last reported, which this screen glides toward.
    private var remoteCameraTargetY: CGFloat?
    /// The peer camera's climb speed (points/s); advances the target
    /// between packets so the follow reads as one continuous glide.
    private var remoteCameraVelocityY: CGFloat = 0
    /// Seconds since the last coopSync packet. Dead reckoning only runs
    /// while this is fresh — extrapolating through a real packet drought
    /// would send the camera sailing off on its own.
    private var remoteSyncAge: TimeInterval = 0
    /// Last time a coopSync message went out (throttled to ~30 Hz).
    private var lastCoopSyncTime: TimeInterval = 0

    /// Floor holes sprinkled along the co-op climb. Strict setting: they
    /// only open when the friend's phone is physically underneath (UWB).
    /// Casual setting: the ball warps through them to the friend.
    private var coopHoles: [SKSpriteNode] = []
    /// Floor holes on the versus court; falling in pops the ball out of
    /// the same spot on the opponent's screen.
    private var versusHoles: [SKSpriteNode] = []

    /// Big center message while a multiplayer mode waits for the second
    /// phone — the game cannot start alone.
    private let waitingLabel = SKLabelNode()

    /// Co-op ready gate: a shared run only (re)starts after BOTH players
    /// press the button (READY on connect, TRY AGAIN after a game over).
    private var isHoldingForReady = false
    private var localReady = false
    private var peerReady = false
    private var peerConnected = false
    /// UWB ranging against the connected peer.
    private let nearby = NearbyPlacementManager()
    /// Placement shown in the HUD; refreshed when the classification flips.
    private var lastPlacement = PeerPlacement.unknown
    /// Whether the side walls are currently open for edge passing.
    private var sidePassOpen = false

    /// Classify the peer's position: the UWB direction vector and gravity
    /// both live in device coordinates, so their dot product says how far
    /// the peer sits toward "straight down" regardless of how this phone
    /// is being held.
    private var peerPlacement: PeerPlacement {
        guard let direction = nearby.direction,
              let gravity = motion.deviceMotion?.gravity else { return .unknown }
        let down = simd_normalize(simd_float3(Float(gravity.x),
                                              Float(gravity.y),
                                              Float(gravity.z)))
        let dot = simd_dot(direction, down)
        if dot > 0.6 { return .below }
        if dot < -0.6 { return .above }
        return .beside
    }
    /// False while the ball is visiting the other phone.
    private var ballIsHere = true
    /// True after dropping the ball through a hole, until the peer reports
    /// whether the catch underneath succeeded.
    private var awaitingDropResult = false
    /// True briefly after catching a dropped ball; holes don't swallow the
    /// ball while set (see catchGraceDuration).
    private var isDropGrace = false

    /// False while the START overlay is up: the course, ball and collapse
    /// are all drawn in place, but nothing moves until the player taps
    /// START. Controlled by GameView.
    var isGameStarted = false

    /// True while the game-over screen waits for TRY AGAIN to be tapped.
    private var awaitingRestart = false
    /// The tappable TRY AGAIN button on the game-over screen.
    private var tryAgainButton: SKNode?

    /// Called from the menu when a mode is picked (or when returning to
    /// the menu, with `.solo`, which also drops any live connection).
    func setPlayMode(_ mode: PlayMode) {
        playMode = mode
        if multiplayerEnabled {
            multipeer.start()
        } else {
            multipeer.stop()
            nearby.stop()
        }
        // The collapse only hunts in solo; play-together is a co-op sandbox.
        collapseNode.isHidden = multiplayerEnabled
        // The update loop isn't running while the menu is up; reset the
        // arrangement state here so walls start closed until UWB speaks.
        sidePassOpen = false
        lastPlacement = .unknown
        updateConnectionLabel()
        // Each mode has its own board (climb vs. walled court), so picking
        // one rebuilds the world from scratch.
        startRun()
    }
    private let connectionLabel = SKLabelNode()
    /// The style the ball is currently wearing. Travels with the ball, so a
    /// visiting ball keeps its owner's design.
    private var displayedColorIndex = 0
    private var displayedPatternIndex = 0
    private var displayedSkinData: Data?

    // MARK: - Tuning

    /// Bumped on every code change so a stale build is obvious on screen.
    private static let buildNumber = 53

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
    /// Time a dropped ball spends falling through the air between phones.
    /// Stacked phones sit a few centimeters apart, so the fall is near
    /// instant — the catcher must already be in position underneath.
    private static let dropFallDuration: TimeInterval = 0.12
    /// After landing from a drop, the ball can't fall into a hole for this
    /// long. Both phones show the same course, so the landing spot sits at
    /// the twin of the hole it just fell through — without a grace period
    /// it would fall forever between the two phones.
    private static let catchGraceDuration: TimeInterval = 0.8
    /// A drop only fires when UWB puts the peer below AND within arm's
    /// reach — a phone one floor down is below too, but no one catches
    /// through a ceiling.
    private static let maxDropDistance: Float = 0.7
    /// How level the catching phone must be at the moment of landing.
    /// Gravity along the screen normal is -1 G when perfectly face up.
    /// Strict (within ~30° of flat): the normal steering grip is tilted
    /// more than this, so a catch only happens when the player deliberately
    /// holds the phone flat like a tray underneath — not just because the
    /// phone happened to be roughly upright somewhere nearby.
    private static let catchLevelThreshold: Double = -0.85
    /// Give up on a drop and respawn if the peer never reports a result.
    private static let dropResultTimeout: TimeInterval = 4.0
    /// Grid spacing of the dots on the ball's surface.
    private static let dotSpacing: CGFloat = 19
    /// Points of climb per scored "meter".
    private static let pointsPerMeter: CGFloat = 60
    /// How tall the endless world is (screens). Practically unreachable.
    private static let worldScreens: CGFloat = 300
    /// Meters of climb over which the difficulty ramps from 0 to full.
    private static let difficultyRampMeters: CGFloat = 150
    /// The collapse's climb speed (points/s) at difficulty 0 and 1.
    /// The ball's own top speed is 1100 — at full difficulty the chase
    /// eats half of that, so climbing must be near constant.
    private static let chaseBaseSpeed: CGFloat = 130
    private static let chaseMaxSpeed: CGFloat = 400
    /// The collapse never falls further behind the ball than this many
    /// screens — being good buys breathing room, never a pause.
    private static let chaseMaxLag: CGFloat = 1.3
    /// Head start (screens below the start) before the collapse arrives.
    private static let chaseHeadStart: CGFloat = 1.1
    /// Length of a versus match.
    private static let versusMatchSeconds: TimeInterval = 60
    /// Half-width of a wall gap the ball can slip through (versus).
    private static let versusGapHalf: CGFloat = GameScene.ballRadius * 1.9

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
        startRun()

        multipeer.onMessage = { [weak self] message in
            switch message {
            case .sideTransfer(let transfer): self?.receiveBall(transfer)
            case .drop(let drop): self?.receiveFallingBall(drop)
            case .dropResult(let caught): self?.handleDropResult(caught: caught)
            case .uwbToken(let data): self?.nearby.receivePeerToken(data)
            case .coopSync(let offset, let velocity, let score):
                self?.receiveCoopSync(heightOffset: offset,
                                      heightVelocity: velocity,
                                      scoreMeters: score)
            case .runOver(let score): self?.receivePeerRunOver(scoreMeters: score)
            case .readyToStart: self?.receivePeerReady()
            case .versusTransfer(let transfer): self?.receiveVersusBall(transfer)
            case .versusResult(let hold): self?.receiveVersusResult(holdSeconds: hold)
            case .coopWarp(let drop): self?.receiveCoopWarp(drop)
            case .versusHoleDrop(let drop): self?.receiveVersusHoleDrop(drop)
            }
        }
        nearby.onTokenReady = { [weak self] data in
            self?.multipeer.send(.uwbToken(data))
        }
        if multiplayerEnabled {
            multipeer.start()
        }
    }

    /// Tear down everything and start a fresh run from height zero. The
    /// obstacle course is generated randomly as the ball climbs, so every
    /// run — and every phone — gets its own layout.
    private func startRun() {
        if isVersus {
            startVersusRound()
            return
        }
        removeAllActions()
        removeAllChildren()
        cameraNode.removeAllChildren()
        scoreLabel.removeFromParent()
        bestLabel.removeFromParent()
        propNodes.removeAll()
        voidZones.removeAll()
        bandNodes.removeAll()
        floorTiles.removeAll()
        coopHoles.removeAll()
        isAirborne = false
        isFalling = false
        isTransitioning = false
        awaitingDropResult = false
        isDropGrace = false
        awaitingRestart = false
        tryAgainButton = nil
        remoteCameraTargetY = nil
        remoteCameraVelocityY = 0
        isHoldingForReady = false
        lastUpdateTime = nil

        worldRect = CGRect(x: 0, y: 0, width: size.width,
                           height: size.height * GameScene.worldScreens)
        runStartY = size.height * 0.3
        maxHeight = runStartY
        startPosition = CGPoint(x: worldRect.midX, y: runStartY)
        nextBandY = runStartY + size.height * 0.55
        chaseY = runStartY - size.height * GameScene.chaseHeadStart

        camera = cameraNode
        addChild(cameraNode)

        addChild(wallsNode)
        rebuildWalls()
        setUpFloor()
        setUpCollapse()

        // Ball and shadow return at the bottom. Co-op shares ONE ball:
        // while connected, only the primary phone (decided by the same
        // name comparison that drives the connection) starts with it —
        // the other screen waits until the ball rolls or drops over.
        ballIsHere = !(isCoop && peerConnected && !multipeer.isPrimary)
        ball.isHidden = !ballIsHere
        shadow.isHidden = !ballIsHere
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

        setUpHUD()
        followBallWithCamera(snap: true)
        layoutFloorTiles()
        generateBands(upTo: cameraNode.position.y + size.height * 1.8)
    }

    /// A full wall loop normally; with a peer connected side by side the
    /// left and right walls open so the ball can roll off to the
    /// neighboring phone. Stacked phones keep the loop closed — the ball
    /// leaves through holes, not edges.
    private func rebuildWalls() {
        wallsNode.removeAllChildren()

        func addWall(_ body: SKPhysicsBody) {
            body.friction = 0.1
            body.categoryBitMask = GameScene.wallCategory
            let node = SKNode()
            node.physicsBody = body
            wallsNode.addChild(node)
        }

        if sidePassOpen {
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

    // MARK: - Endless floor & obstacle generation

    /// The deck floor: a few tiles (the real deck.png photo when present,
    /// otherwise code-drawn wood) recycled vertically as the camera climbs,
    /// so an endless world never needs more than a handful of nodes.
    private func setUpFloor() {
        if let photo = UIImage(named: "deck") {
            let texture = SKTexture(image: photo)
            // Rotated 90°, the photo's height becomes the on-screen width.
            let scale = size.width / photo.size.height
            floorTileHeight = photo.size.width * scale
            floorMirrors = true
            let count = Int(ceil(size.height / floorTileHeight)) + 3
            for _ in 0..<count {
                let tile = SKSpriteNode(texture: texture)
                tile.zRotation = .pi / 2
                tile.yScale = scale
                tile.xScale = scale
                tile.zPosition = 0
                addChild(tile)
                floorTiles.append(tile)
            }
        } else {
            let texture = GameScene.woodTexture(size: size)
            floorTileHeight = size.height
            floorMirrors = false
            for _ in 0..<3 {
                let tile = SKSpriteNode(texture: texture)
                tile.zPosition = 0
                addChild(tile)
                floorTiles.append(tile)
            }
        }
        layoutFloorTiles()
    }

    /// Slide the floor tiles to the rows around the camera. Alternate rows
    /// of the photo are mirrored so the seams line up.
    private func layoutFloorTiles() {
        guard floorTileHeight > 0 else { return }
        let firstRow = Int(floor(
            (cameraNode.position.y - size.height) / floorTileHeight))
        for (offset, tile) in floorTiles.enumerated() {
            let row = firstRow + offset
            tile.position = CGPoint(
                x: size.width / 2,
                y: (CGFloat(row) + 0.5) * floorTileHeight
            )
            if floorMirrors {
                let magnitude = abs(tile.xScale)
                let even = ((row % 2) + 2) % 2 == 0
                tile.xScale = even ? magnitude : -magnitude
            }
        }
    }

    /// The collapsed zone: darkness with a glowing crumble edge, sitting
    /// above the floor and obstacles (they have fallen away underneath).
    private func setUpCollapse() {
        collapseNode.removeAllChildren()
        collapseNode.zPosition = 7

        let dark = SKSpriteNode(
            color: SKColor(red: 0.05, green: 0.03, blue: 0.04, alpha: 1),
            size: CGSize(width: size.width, height: size.height * 2.2)
        )
        dark.anchorPoint = CGPoint(x: 0.5, y: 1) // top edge at chaseY
        collapseNode.addChild(dark)

        let glow = SKSpriteNode(
            color: SKColor(red: 0.90, green: 0.35, blue: 0.12, alpha: 0.5),
            size: CGSize(width: size.width, height: 14)
        )
        glow.position = CGPoint(x: 0, y: -4)
        collapseNode.addChild(glow)

        let edge = SKSpriteNode(
            color: SKColor(red: 1.0, green: 0.62, blue: 0.18, alpha: 0.95),
            size: CGSize(width: size.width, height: 5)
        )
        edge.position = CGPoint(x: 0, y: -1)
        collapseNode.addChild(edge)

        collapseNode.position = CGPoint(x: size.width / 2, y: chaseY)
        // Play-together is co-op: no collapse chasing from below.
        collapseNode.isHidden = multiplayerEnabled
        addChild(collapseNode)
    }

    /// Place one obstacle, with its silhouette shadow and a static physics
    /// body. Low obstacles live in lowPropCategory (a hop clears them);
    /// walls are fenceCategory and can never be jumped.
    @discardableResult
    private func spawnObstacle(_ kind: Obstacle, at point: CGPoint,
                               rotation: CGFloat = 0) -> SKSpriteNode {
        let texture: SKTexture
        let body: SKPhysicsBody
        var restitution: CGFloat = 0.4
        var category = GameScene.lowPropCategory

        switch kind {
        case .circle:
            texture = GameScene.stoneTexture()
            body = SKPhysicsBody(circleOfRadius: texture.size().width * 0.46)
            restitution = 0.3 // dead stop: kills most of the bounce
        case .bumper:
            texture = GameScene.mushroomTexture()
            body = SKPhysicsBody(circleOfRadius: texture.size().width * 0.46)
            restitution = 1.5 // pinball kicker: adds energy on impact
        case .bar(let length):
            texture = GameScene.barTexture(length: length)
            body = SKPhysicsBody(rectangleOf: CGSize(
                width: length * 0.96,
                height: texture.size().height * 0.7
            ))
            restitution = 0.45
        case .hurdle(let length):
            texture = GameScene.hurdleTexture(length: length)
            body = SKPhysicsBody(rectangleOf: CGSize(
                width: length,
                height: texture.size().height * 0.7
            ))
            restitution = 0.5
        case .wall(let length):
            texture = GameScene.fenceTexture(length: length)
            body = SKPhysicsBody(rectangleOf: texture.size())
            restitution = 0.35
            category = GameScene.fenceCategory
        }

        let node = SKSpriteNode(texture: texture)
        node.position = point
        node.zRotation = rotation
        node.zPosition = 6

        // Silhouette drop shadow so the object sits above the deck.
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
        body.categoryBitMask = category
        node.physicsBody = body

        addChild(node)
        propNodes.append(node)
        return node
    }

    /// How hard the course is at the current generation height: 0 at the
    /// start, 1 after difficultyRampMeters of climb. Everything scales
    /// with it — band spacing, bridge width, chasm depth, obstacle count.
    private var difficulty: CGFloat {
        let climbed = (nextBandY - runStartY) / GameScene.pointsPerMeter
        return min(1, max(0, climbed / GameScene.difficultyRampMeters))
    }

    private func lerp(_ from: CGFloat, _ to: CGFloat,
                      _ t: CGFloat) -> CGFloat {
        from + (to - from) * t
    }

    /// Generate obstacle bands up to the given height. Band types are
    /// weighted by difficulty: the early climb is mostly hurdles and
    /// loose bumpers, the high climb leans on chasms and walls, packed
    /// tighter, with guards on the openings.
    private func generateBands(upTo targetY: CGFloat) {
        while nextBandY < min(targetY, worldRect.maxY - size.height) {
            let y = nextBandY
            let d = difficulty
            var bandTop = y
            var nodes: [SKNode] = []

            // Weighted band pick: chasms and walls grow more common as
            // the climb gets higher.
            let weights: [(kind: Int, weight: CGFloat)] = [
                (0, 1.0),            // hurdle
                (1, 1.0),            // bumpers
                (2, 0.4 + 0.9 * d),  // chasm
                (3, 0.6 + 0.7 * d),  // wall
            ]
            var roll = CGFloat.random(
                in: 0..<weights.reduce(0) { $0 + $1.weight })
            var kind = weights[0].kind
            for entry in weights {
                if roll < entry.weight { kind = entry.kind; break }
                roll -= entry.weight
            }

            switch kind {
            case 0:
                nodes.append(spawnObstacle(
                    .hurdle(length: size.width * 1.02),
                    at: CGPoint(x: worldRect.midX, y: y)
                ))
                // Higher up, a bumper lurks behind the hurdle to punish
                // blind full-speed hops.
                if d > 0.4, CGFloat.random(in: 0...1) < 0.45 {
                    nodes.append(spawnObstacle(.bumper, at: CGPoint(
                        x: CGFloat.random(in: 0.25...0.75) * size.width,
                        y: y + size.height * 0.12
                    )))
                }
            case 1:
                let count = 2 + Int((d * 2.49).rounded(.down))
                for _ in 0..<count {
                    nodes.append(spawnObstacle(.bumper, at: CGPoint(
                        x: CGFloat.random(in: 0.12...0.88) * size.width,
                        y: y + CGFloat.random(in: -0.14...0.14) * size.height
                    )))
                }
            case 2:
                bandTop = y + spawnChasm(at: y, difficulty: d)
            default:
                let gapOnLeft = Bool.random()
                let wallLength = size.width * CGFloat.random(
                    in: lerp(0.40, 0.60, d)...lerp(0.50, 0.72, d))
                let wallX = gapOnLeft
                    ? size.width - wallLength / 2 - 4
                    : wallLength / 2 + 4
                nodes.append(spawnObstacle(
                    .wall(length: wallLength),
                    at: CGPoint(x: wallX, y: y)
                ))
                // A bumper guards the gap; a circle litters the approach.
                nodes.append(spawnObstacle(.bumper, at: CGPoint(
                    x: gapOnLeft ? size.width * 0.16 : size.width * 0.84,
                    y: y + size.height * 0.08
                )))
                nodes.append(spawnObstacle(.circle, at: CGPoint(
                    x: CGFloat.random(in: 0.25...0.75) * size.width,
                    y: y - size.height * 0.12
                )))
                // High up, a second wall on the other side turns the gap
                // into a chicane.
                if d > 0.5, CGFloat.random(in: 0...1) < 0.5 {
                    let secondLength = size.width * CGFloat.random(in: 0.45...0.6)
                    let secondX = gapOnLeft
                        ? secondLength / 2 + 4
                        : size.width - secondLength / 2 - 4
                    let second = spawnObstacle(
                        .wall(length: secondLength),
                        at: CGPoint(x: secondX, y: y + size.height * 0.16)
                    )
                    nodes.append(second)
                    bandTop = y + size.height * 0.16
                }
            }

            if !nodes.isEmpty {
                bandNodes.append((maxY: bandTop + 60, nodes: nodes))
            }

            // Co-op: sprinkle a floor hole between bands now and then —
            // the doorway down to the friend's phone.
            if isCoop, CGFloat.random(in: 0...1) < 0.45 {
                let hole = SKSpriteNode(
                    texture: GameScene.holeTexture(radius: GameScene.holeRadius))
                hole.position = CGPoint(
                    x: CGFloat.random(in: 0.15...0.85) * size.width,
                    y: bandTop + size.height * CGFloat.random(in: 0.16...0.30)
                )
                hole.zPosition = 2
                addChild(hole)
                coopHoles.append(hole)
            }

            nextBandY = bandTop + size.height * CGFloat.random(
                in: lerp(0.55, 0.32, d)...lerp(0.75, 0.46, d))
        }
    }

    private func pruneCoopHoles(below y: CGFloat) {
        for hole in coopHoles where hole.position.y < y {
            hole.removeFromParent()
        }
        coopHoles.removeAll { $0.position.y < y }
    }

    /// A chasm across the whole screen with one narrow bridge — narrower
    /// and deeper the higher you climb, sometimes with a bumper standing
    /// guard at the far end. Rolling off the bridge (while grounded) ends
    /// the run — unless a friend's phone waits underneath to catch the
    /// ball. Returns the chasm's height.
    private func spawnChasm(at y: CGFloat, difficulty d: CGFloat) -> CGFloat {
        let voidHeight = size.height * CGFloat.random(
            in: lerp(0.20, 0.30, d)...lerp(0.26, 0.38, d))
        let rect = CGRect(x: 0, y: y, width: worldRect.width, height: voidHeight)
        let bridgeWidth = GameScene.ballRadius * CGFloat.random(
            in: lerp(3.8, 2.2, d)...lerp(4.4, 2.8, d))
        let bridgeX = CGFloat.random(in: 0.18...0.82) * size.width
        let bridgeRect = CGRect(x: bridgeX - bridgeWidth / 2, y: rect.minY,
                                width: bridgeWidth, height: voidHeight)

        var nodes: [SKNode] = []

        // The dark drop.
        let chasm = SKShapeNode(rect: rect)
        chasm.fillColor = SKColor(red: 0.05, green: 0.04, blue: 0.05, alpha: 1)
        chasm.strokeColor = SKColor(red: 0.16, green: 0.12, blue: 0.10, alpha: 1)
        chasm.lineWidth = 3
        chasm.zPosition = 2
        addChild(chasm)
        nodes.append(chasm)

        // The bridge plank.
        let plank = SKShapeNode(rect: bridgeRect.insetBy(dx: 2, dy: 0),
                                cornerRadius: 6)
        plank.fillColor = SKColor(red: 0.80, green: 0.66, blue: 0.46, alpha: 1)
        plank.strokeColor = SKColor(red: 0.55, green: 0.42, blue: 0.28, alpha: 1)
        plank.lineWidth = 3
        plank.zPosition = 3
        addChild(plank)
        nodes.append(plank)

        // A guard at the bridge exit, high up.
        if d > 0.6, CGFloat.random(in: 0...1) < 0.4 {
            let guardOffset = bridgeX < size.width / 2 ? 60.0 : -60.0
            nodes.append(spawnObstacle(.bumper, at: CGPoint(
                x: min(max(bridgeX + guardOffset, 30), size.width - 30),
                y: rect.maxY + size.height * 0.06
            )))
        }

        voidZones.append(VoidZone(rect: rect,
                                  bridges: [bridgeRect],
                                  nodes: nodes))
        return voidHeight
    }

    /// Tear down bands and chasms that have fallen far below the ball.
    private func pruneBands(below y: CGFloat) {
        bandNodes.removeAll { band in
            guard band.maxY < y else { return false }
            band.nodes.forEach { $0.removeFromParent() }
            return true
        }
        voidZones.removeAll { zone in
            guard zone.rect.maxY < y else { return false }
            zone.nodes.forEach { $0.removeFromParent() }
            return true
        }
        propNodes.removeAll { $0.parent == nil }
    }

    private func setUpHUD() {
        scoreLabel.text = "0 m"
        scoreLabel.fontName = "AvenirNext-Bold"
        scoreLabel.fontSize = 30
        scoreLabel.fontColor = SKColor(red: 0.25, green: 0.15, blue: 0.08, alpha: 0.85)
        scoreLabel.position = CGPoint(x: 0, y: size.height / 2 - 70)
        scoreLabel.zPosition = 100
        cameraNode.addChild(scoreLabel)

        bestLabel.text = L10n.t("ベスト \(bestScore) m", "BEST \(bestScore) m")
        bestLabel.fontName = "AvenirNext-DemiBold"
        bestLabel.fontSize = 14
        bestLabel.fontColor = SKColor(red: 0.25, green: 0.15, blue: 0.08, alpha: 0.55)
        bestLabel.position = CGPoint(x: 0, y: size.height / 2 - 92)
        bestLabel.zPosition = 100
        cameraNode.addChild(bestLabel)

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

        attachWaitingLabel()
    }

    /// The frozen-board notice for multiplayer modes: nothing starts
    /// until the second phone connects.
    private func attachWaitingLabel() {
        waitingLabel.text = L10n.t("あいてのiPhoneをさがしています…\nつながったらスタート！",
                                   "Looking for the other iPhone…\nThe game starts once it connects!")
        waitingLabel.numberOfLines = 0
        waitingLabel.fontName = "AvenirNext-Bold"
        waitingLabel.fontSize = 21
        waitingLabel.fontColor = SKColor(red: 0.25, green: 0.15, blue: 0.08, alpha: 0.95)
        waitingLabel.horizontalAlignmentMode = .center
        waitingLabel.verticalAlignmentMode = .center
        waitingLabel.position = .zero
        waitingLabel.zPosition = 100
        waitingLabel.isHidden = !(multiplayerEnabled && !peerConnected)
        waitingLabel.removeFromParent()
        cameraNode.addChild(waitingLabel)
    }

    private func updateConnectionLabel() {
        guard multiplayerEnabled else {
            connectionLabel.text = ""
            return
        }
        if peerConnected {
            let name = multipeer.connectedPeerName ?? L10n.t("つながった", "Connected")
            connectionLabel.text = "● \(name)\(placementSuffix())"
            connectionLabel.fontColor = SKColor(red: 0.15, green: 0.6, blue: 0.25, alpha: 0.9)
        } else {
            connectionLabel.text = L10n.t("○ 相手をさがしています…", "○ Looking for a nearby iPhone…")
            connectionLabel.fontColor = SKColor(red: 0.25, green: 0.15, blue: 0.08, alpha: 0.5)
        }
    }

    /// Live arrangement readout so players can see what UWB thinks.
    private func placementSuffix() -> String {
        guard NearbyPlacementManager.isSupported else {
            return L10n.t("（UWBなし・よこパスのみ）", " (no UWB: side pass only)")
        }
        switch lastPlacement {
        case .below: return L10n.t(" ↓ したにいる", " ↓ below you")
        case .above: return L10n.t(" ↑ うえにいる", " ↑ above you")
        case .beside: return L10n.t(" ↔ よこにいる", " ↔ beside you")
        case .unknown: return ""
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
    /// Accumulated 3D orientation of the skin sphere; the shader applies
    /// its inverse to look up the texture, so the picture rolls around the
    /// ball in whatever direction the ball travels.
    private var skinRotation = simd_quatf(angle: 0, axis: simd_float3(0, 0, 1))
    private var skinRotationUniform: SKUniform?

    /// Orthographic sphere shader: each pixel of the ball face becomes a
    /// point on a 3D sphere, rotated by u_rot, then mapped to the skin
    /// texture with an equirectangular projection — the same projection
    /// the painting canvas uses on its SceneKit sphere.
    private static let sphereSkinShaderSource = """
    void main() {
        vec2 p = v_tex_coord * 2.0 - 1.0;
        float r2 = dot(p, p);
        if (r2 > 1.0) {
            gl_FragColor = vec4(0.0);
        } else {
            vec3 n = vec3(p.x, p.y, sqrt(1.0 - r2));
            vec3 d = u_rot * n;
            float uu = atan(d.x, d.z) / 6.28318530718 + 0.5;
            float vv = 0.5 + asin(clamp(d.y, -1.0, 1.0)) / 3.14159265359;
            gl_FragColor = texture2D(u_texture, vec2(uu, vv));
        }
    }
    """

    private func buildBallIfNeeded() {
        guard ball.physicsBody == nil else { return }

        ball.strokeColor = .clear

        let body = SKPhysicsBody(circleOfRadius: GameScene.ballRadius)
        body.restitution = 0.55   // bounce off walls
        body.friction = 0.15
        body.linearDamping = 0.12 // slight rolling resistance so it settles
        body.allowsRotation = false // rolling is drawn via the surface pattern
        body.categoryBitMask = GameScene.ballCategory
        body.collisionBitMask = GameScene.lowPropCategory
            | GameScene.fenceCategory | GameScene.wallCategory
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
            // The picture is wrapped around a 3D sphere in a fragment
            // shader and rolled by the ball's motion (scrollSurfacePattern
            // spins skinRotation). Facing forward it reads clearly; rolling
            // it tumbles in any direction — vertical included — like a
            // real printed ball.
            let sprite = SKSpriteNode(texture: SKTexture(image: skin))
            let diameter = GameScene.ballRadius * 2
            sprite.size = CGSize(width: diameter, height: diameter)
            skinRotation = simd_quatf(angle: 0, axis: simd_float3(0, 0, 1))
            let uniform = SKUniform(name: "u_rot",
                                    matrixFloat3x3: matrix_identity_float3x3)
            sprite.shader = SKShader(source: GameScene.sphereSkinShaderSource,
                                     uniforms: [uniform])
            skinRotationUniform = uniform
            dotPattern.addChild(sprite)
            return
        }

        isCustomSkin = false
        skinRotationUniform = nil
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

        // Waiting on the START overlay: the world renders as-is behind the
        // button, but the ball and the collapse stay frozen.
        guard isGameStarted else {
            body.velocity = .zero
            shadow.position = CGPoint(x: ball.position.x, y: ball.position.y - 4)
            return
        }

        // Track the connection: start/stop UWB ranging. Losing the peer
        // while the ball is visiting starts a fresh run.
        if multipeer.isConnected != peerConnected {
            peerConnected = multipeer.isConnected
            if peerConnected {
                nearby.prepare()
            } else {
                nearby.stop()
            }
            removeAction(forKey: "dropTimeout")
            updateConnectionLabel()
            // Co-op/versus: the peer left — dissolve any ready gate and
            // carry on alone with the ball back on this screen.
            if multiplayerEnabled, !peerConnected {
                clearReadyGate()
                startRun()
                return
            }
            if !peerConnected, !ballIsHere {
                startRun()
                return
            }
            // Co-op/versus: on connect, build the fresh shared board (one
            // ball, on the primary phone) but hold it frozen behind a
            // READY button until both players have pressed theirs.
            if peerConnected, multiplayerEnabled {
                startRun()
                presentReadyGate()
                return
            }
        }

        // Multiplayer never starts alone: until the second phone connects,
        // the board sits frozen behind a "looking for…" message.
        if multiplayerEnabled, !peerConnected {
            waitingLabel.isHidden = false
            body.velocity = .zero
            return
        }
        waitingLabel.isHidden = true

        // The arrangement is live: follow it frame to frame. Side passing
        // opens the walls unless UWB says the phones are stacked.
        let placement = peerPlacement
        if placement != lastPlacement {
            lastPlacement = placement
            updateConnectionLabel()
        }
        // Versus never opens the side walls — the only way out is a gap.
        let wantSidePass = isCoop && peerConnected
            && placement != .below && placement != .above
        if wantSidePass != sidePassOpen {
            sidePassOpen = wantSidePass
            rebuildWalls()
        }

        // Co-op, ball on the other phone: this camera glides to the height
        // the friend's screen reports, so both players watch the same
        // stretch of the climb. The course keeps generating under the
        // borrowed camera so there's something to look at (and to land on).
        if isCoop, !ballIsHere, let target = remoteCameraTargetY {
            // Dead-reckon: glide the target forward at the reported climb
            // speed so the picture keeps moving smoothly between packets —
            // but only while packets are fresh. During a drought the
            // target holds still instead of sailing away on stale speed.
            remoteSyncAge += TimeInterval(dt)
            let predicted = remoteSyncAge < 0.3
                ? target + remoteCameraVelocityY * dt
                : target
            remoteCameraTargetY = predicted
            let halfHeight = size.height / 2
            let clamped = min(max(predicted, worldRect.minY + halfHeight),
                              worldRect.maxY - halfHeight)
            let blend = min(1, 6 * dt)
            var step = (clamped - cameraNode.position.y) * blend
            // Never sweep faster than a real climb could move the camera,
            // so a corrected target is caught with a quick glide, not a yank.
            let maxStep = 1500 * dt
            step = min(max(step, -maxStep), maxStep)
            cameraNode.position.y += step
            generateBands(upTo: cameraNode.position.y + size.height * 1.8)
            pruneBands(below: cameraNode.position.y - size.height * 2)
            pruneCoopHoles(below: cameraNode.position.y - size.height * 2)
            layoutFloorTiles()
        }

        // Ready gate up: the world is on show but frozen until both sides
        // have pressed READY.
        if isHoldingForReady {
            body.velocity = .zero
            return
        }

        // Versus runs its own compact loop (fixed camera, match clock,
        // hot-potato scoring) instead of the climb logic below.
        if isVersus {
            updateVersus(currentTime: currentTime, dt: dt, body: body)
            return
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
        if sidePassOpen, !isFalling, !isTransitioning,
           ball.position.x < worldRect.minX - GameScene.ballRadius
            || ball.position.x > worldRect.maxX + GameScene.ballRadius {
            sendBallToPeer()
            return
        }

        // Keep the endless course rolling: build ahead of the camera,
        // tear down what has fallen far behind.
        generateBands(upTo: cameraNode.position.y + size.height * 1.8)
        pruneBands(below: ball.position.y - size.height * 2)
        pruneCoopHoles(below: ball.position.y - size.height * 2)

        // Co-op floor holes. Strict: only a friend physically underneath
        // opens the floor (the ball rolls straight over otherwise).
        // Casual: the hole warps the ball to the friend, wherever they are.
        if isCoop, peerConnected, !isAirborne, !isFalling, !isTransitioning,
           !isDropGrace {
            for hole in coopHoles {
                let distance = hypot(ball.position.x - hole.position.x,
                                     ball.position.y - hole.position.y)
                guard distance < GameScene.holeRadius * 0.8 else { continue }
                if UserDefaults.standard.bool(forKey: "coopHoleStrict") {
                    if peerPlacement == .below,
                       (nearby.distance ?? .greatestFiniteMagnitude)
                           < GameScene.maxDropDistance {
                        dropBallToPeer(at: ball.position)
                    }
                } else {
                    warpBallToPeer(at: hole.position)
                }
                break
            }
        }

        // Score is the highest point reached this run.
        if ball.position.y > maxHeight {
            maxHeight = ball.position.y
            scoreLabel.text = "\(scoreMeters) m"
        }

        // The floor collapses from below, faster the higher you are, and
        // never drops more than a couple of screens behind — stalling is
        // not a strategy. Swallowed means the run ends (or the phone
        // underneath catches the falling ball). Solo only: play-together
        // has no collapse, so friends can take their time.
        if !isTransitioning, !multiplayerEnabled {
            let chaseDifficulty = min(1, max(0,
                (ball.position.y - runStartY) / GameScene.pointsPerMeter
                    / GameScene.difficultyRampMeters))
            chaseY += (GameScene.chaseBaseSpeed
                + (GameScene.chaseMaxSpeed - GameScene.chaseBaseSpeed)
                    * chaseDifficulty) * dt
            chaseY = max(chaseY,
                         ball.position.y - size.height * GameScene.chaseMaxLag)
            collapseNode.position = CGPoint(x: size.width / 2, y: chaseY)

            if !isAirborne, !isFalling,
               ball.position.y < chaseY + GameScene.ballRadius {
                fallIntoVoid()
            }
        }

        // Over a chasm with no bridge under the ball: it falls. A hop
        // clears a chasm; right after a catch there's a moment of grace.
        if !isAirborne, !isFalling, !isTransitioning, !isDropGrace,
           let zone = voidZones.first(where: { $0.rect.contains(ball.position) }),
           !zone.bridges.contains(where: {
               $0.insetBy(dx: -6, dy: -6).contains(ball.position)
           }) {
            fallIntoVoid()
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
        layoutFloorTiles()

        // Co-op: stream this camera's height, climb speed and the shared
        // score to the watching phone, ~30 times a second.
        if isCoop, peerConnected,
           currentTime - lastCoopSyncTime > 0.033 {
            lastCoopSyncTime = currentTime
            multipeer.send(.coopSync(
                heightOffset: Double(cameraNode.position.y - runStartY),
                heightVelocity: Double(body.velocity.dy),
                scoreMeters: scoreMeters
            ), reliable: false)
        }
    }

    /// Keep the ball in view, clamping so the camera never shows past the
    /// edge of the world. The follow is lightly smoothed so a ball that
    /// teleports in (a transfer from the other phone) is caught with a
    /// quick glide instead of a hard cut; `snap` skips the smoothing for
    /// fresh runs.
    private func followBallWithCamera(snap: Bool = false) {
        let halfWidth = size.width / 2
        let halfHeight = size.height / 2
        let target = CGPoint(
            x: min(max(ball.position.x, worldRect.minX + halfWidth), worldRect.maxX - halfWidth),
            y: min(max(ball.position.y, worldRect.minY + halfHeight), worldRect.maxY - halfHeight)
        )
        if snap {
            cameraNode.position = target
            return
        }
        let blend: CGFloat = 0.35
        cameraNode.position = CGPoint(
            x: cameraNode.position.x + (target.x - cameraNode.position.x) * blend,
            y: cameraNode.position.y + (target.y - cameraNode.position.y) * blend
        )
    }

    /// Seen from above, a rolling ball's top surface moves in the direction
    /// of travel — scroll the dots with the velocity and wrap them so the
    /// pattern never runs out. A custom skin instead rolls a real sphere:
    /// the angular velocity of a ball rolling with velocity v is
    /// ω = (-vy, vx, 0) / r, so the picture tumbles vertically,
    /// horizontally, or diagonally exactly as the ball moves.
    private func scrollSurfacePattern(velocity: CGVector, dt: CGFloat) {
        if isCustomSkin {
            let wx = Float(-velocity.dy * dt / GameScene.ballRadius)
            let wy = Float(velocity.dx * dt / GameScene.ballRadius)
            let angle = sqrt(wx * wx + wy * wy)
            if angle > 0.0001, let uniform = skinRotationUniform {
                let axis = simd_normalize(simd_float3(wx, wy, 0))
                skinRotation = simd_quatf(angle: angle, axis: axis)
                    * skinRotation
                // The shader maps a screen point back into the picture, so
                // it needs the inverse of the sphere's orientation.
                uniform.matrixFloat3x3Value =
                    simd_float3x3(skinRotation.inverse)
            }
            return
        }
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

    // MARK: - Hop

    /// Pop the ball into the air: it grows (closer to the viewer) while its
    /// shadow shrinks, then lands with a small squash. Airborne, the ball
    /// sails over stones, branches and mushrooms — but not the tall fences.
    private func hop() {
        isAirborne = true
        ball.physicsBody?.collisionBitMask =
            GameScene.fenceCategory | GameScene.wallCategory
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
        ball.physicsBody?.collisionBitMask = GameScene.lowPropCategory
            | GameScene.fenceCategory | GameScene.wallCategory
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

    // MARK: - Falling & run over

    /// The ball rolled off a bridge. When UWB says the other phone is
    /// physically below this one right now, the ball falls *through* the
    /// deck toward it — the co-op rescue; otherwise the run ends.
    private func fallIntoVoid() {
        if peerConnected, peerPlacement == .below,
           nearby.distance ?? 0 < GameScene.maxDropDistance {
            dropBallToPeer(at: ball.position)
        } else {
            endRun()
        }
    }

    /// Game over: sink into the dark, show the score, save the best, and
    /// wait for TRY AGAIN. In co-op the run is shared, so the other phone
    /// is told to show the same screen.
    private func endRun() {
        isTransitioning = true
        isFalling = true
        fallHaptic.impactOccurred()
        ball.physicsBody?.velocity = .zero

        if isCoop, peerConnected {
            multipeer.send(.runOver(scoreMeters: scoreMeters))
        }

        let sink = SKAction.group([
            .scale(to: 0.08, duration: 0.35),
            .fadeOut(withDuration: 0.35),
        ])
        sink.timingMode = .easeIn
        ball.run(sink)
        shadow.run(.fadeOut(withDuration: 0.2))

        showGameOver(finalScore: scoreMeters)
    }

    /// The score banner and TRY AGAIN button, shown on both phones in
    /// co-op — whoever taps the button restarts the run for everyone.
    private func showGameOver(finalScore: Int) {
        let isNewBest = finalScore > bestScore
        if isNewBest {
            bestScore = finalScore
            UserDefaults.standard.set(bestScore, forKey: "bestScore")
        }

        let banner = SKLabelNode(
            text: L10n.t("スコア \(finalScore) m", "SCORE \(finalScore) m"))
        banner.fontName = "AvenirNext-Bold"
        banner.fontSize = 34
        banner.fontColor = SKColor(red: 0.25, green: 0.15, blue: 0.08, alpha: 1)
        banner.position = CGPoint(x: 0, y: 20)
        banner.zPosition = 100
        banner.setScale(0.1)
        cameraNode.addChild(banner)
        let popIn = SKAction.scale(to: 1.0, duration: 0.3)
        popIn.timingMode = .easeOut
        banner.run(popIn)

        let sub = SKLabelNode(text: isNewBest
            ? L10n.t("じこベストこうしん！", "NEW BEST!")
            : L10n.t("ベスト \(bestScore) m", "BEST \(bestScore) m"))
        sub.fontName = "AvenirNext-DemiBold"
        sub.fontSize = 18
        sub.fontColor = isNewBest
            ? SKColor(red: 0.85, green: 0.55, blue: 0.10, alpha: 1)
            : SKColor(red: 0.25, green: 0.15, blue: 0.08, alpha: 0.7)
        sub.position = CGPoint(x: 0, y: -14)
        sub.zPosition = 100
        cameraNode.addChild(sub)

        // The run only restarts when the player taps TRY AGAIN (both
        // players, in co-op).
        let button = makeGateButton(text: L10n.t("もういちど", "TRY AGAIN"))
        cameraNode.addChild(button)
        tryAgainButton = button
        awaitingRestart = true
    }

    /// The big orange pill used for TRY AGAIN and the co-op READY gate.
    private func makeGateButton(text: String) -> SKShapeNode {
        let button = SKShapeNode(rectOf: CGSize(width: 230, height: 62),
                                 cornerRadius: 31)
        button.fillColor = SKColor(red: 1.0, green: 0.45, blue: 0.25, alpha: 1)
        button.strokeColor = SKColor(white: 1, alpha: 0.85)
        button.lineWidth = 3
        button.position = CGPoint(x: 0, y: -78)
        button.zPosition = 100

        let label = SKLabelNode(text: text)
        label.fontName = "AvenirNext-Heavy"
        label.fontSize = 24
        label.fontColor = .white
        label.verticalAlignmentMode = .center
        button.addChild(label)

        button.setScale(0.1)
        let pop = SKAction.scale(to: 1.0, duration: 0.3)
        pop.timingMode = .easeOut
        button.run(.sequence([.wait(forDuration: 0.4), pop]))
        return button
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard awaitingRestart, let touch = touches.first,
              let button = tryAgainButton else { return }
        let location = touch.location(in: cameraNode)
        // A roomy hit box — mid-game-over is no time for precision tapping.
        guard button.frame.insetBy(dx: -20, dy: -20).contains(location) else { return }
        if multiplayerEnabled, peerConnected {
            // Shared rounds wait for BOTH players' buttons.
            handleLocalReadyTap(on: button)
        } else {
            awaitingRestart = false
            tryAgainButton = nil
            startRun()
        }
    }

    // MARK: - Co-op shared run (one ball, one camera, one score)

    /// The phone holding the ball reported its camera height and score.
    private func receiveCoopSync(heightOffset: Double, heightVelocity: Double,
                                 scoreMeters score: Int) {
        guard isCoop else { return }
        remoteCameraTargetY = runStartY + CGFloat(heightOffset)
        remoteCameraVelocityY = CGFloat(heightVelocity)
        remoteSyncAge = 0
        // The score is shared: never let the display fall behind the peer.
        let sharedHeight = runStartY + CGFloat(score) * GameScene.pointsPerMeter
        if sharedHeight > maxHeight {
            maxHeight = sharedHeight
            scoreLabel.text = "\(score) m"
        }
    }

    /// The shared run ended on the other phone: freeze and show the same
    /// game-over screen here.
    private func receivePeerRunOver(scoreMeters score: Int) {
        guard isCoop, !awaitingRestart else { return }
        isTransitioning = true
        isFalling = true
        fallHaptic.impactOccurred()
        ball.physicsBody?.velocity = .zero
        if ballIsHere {
            // Rare crossfire (both phones ended at once): sink this ball too.
            let sink = SKAction.group([
                .scale(to: 0.08, duration: 0.35),
                .fadeOut(withDuration: 0.35),
            ])
            sink.timingMode = .easeIn
            ball.run(sink)
            shadow.run(.fadeOut(withDuration: 0.2))
        }
        showGameOver(finalScore: max(score, scoreMeters))
    }

    /// The other player pressed READY / TRY AGAIN.
    private func receivePeerReady() {
        guard multiplayerEnabled else { return }
        peerReady = true
        maybeBeginCoopRun()
    }

    /// Once BOTH players have pressed their button, the shared run
    /// (re)starts on this phone. The peer runs the same check when our
    /// readyToStart reaches them, so the two starts happen together.
    private func maybeBeginCoopRun() {
        guard localReady, peerReady else { return }
        clearReadyGate()
        startRun()
    }

    /// Freeze the freshly built world behind a READY button (shown right
    /// after the two phones connect).
    private func presentReadyGate() {
        isHoldingForReady = true
        localReady = false
        peerReady = false
        awaitingRestart = true
        let button = makeGateButton(text: L10n.t("じゅんびOK！", "READY!"))
        cameraNode.addChild(button)
        tryAgainButton = button
    }

    private func clearReadyGate() {
        isHoldingForReady = false
        localReady = false
        peerReady = false
        awaitingRestart = false
        tryAgainButton?.removeFromParent()
        tryAgainButton = nil
    }

    /// The local player pressed their gate button: mark ready, tell the
    /// peer, and turn the button into a "waiting" state.
    private func handleLocalReadyTap(on button: SKNode) {
        awaitingRestart = false
        localReady = true
        multipeer.send(.readyToStart)
        button.alpha = 0.7
        if let label = button.children.compactMap({ $0 as? SKLabelNode }).first {
            label.text = L10n.t("あいてをまってるよ…", "Waiting for your friend…")
            label.fontSize = 15
        }
        maybeBeginCoopRun()
    }

    // MARK: - Versus mode (hot potato: hold the ball LESS to win)

    /// One fixed screen: a walled court with 1–2 gaps, maze bars and
    /// bumpers in the way. Push the ball out through a gap and it lands on
    /// the opponent's screen. After 60 seconds, whoever held the ball the
    /// shorter time wins.
    private func startVersusRound() {
        removeAllActions()
        removeAllChildren()
        cameraNode.removeAllChildren()
        floorTiles.removeAll()
        versusObstacleNodes.removeAll()
        versusHoles.removeAll()
        propNodes.removeAll()
        isAirborne = false
        isFalling = false
        isTransitioning = false
        awaitingRestart = false
        tryAgainButton = nil
        isHoldingForReady = false
        lastUpdateTime = nil
        matchStartTime = nil
        myHoldTime = 0
        matchOver = false
        peerHoldReported = nil
        versusResultShown = false

        worldRect = CGRect(origin: .zero, size: size)
        startPosition = CGPoint(x: worldRect.midX, y: worldRect.midY)

        camera = cameraNode
        addChild(cameraNode)
        cameraNode.position = startPosition

        setUpFloor()
        addChild(wallsNode)
        regenerateVersusLayout(clearPoint: nil)

        ballIsHere = !(peerConnected && !multipeer.isPrimary)
        ball.isHidden = !ballIsHere
        shadow.isHidden = !ballIsHere
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

        setUpVersusHUD()
    }

    private func setUpVersusHUD() {
        versusTimerUrgent = false
        versusTimerLabel.removeAllActions()
        versusTimerLabel.setScale(1)
        versusTimerLabel.text = L10n.t("のこり \(Int(GameScene.versusMatchSeconds))秒",
                                       "\(Int(GameScene.versusMatchSeconds))s left")
        versusTimerLabel.fontName = "AvenirNext-Heavy"
        versusTimerLabel.fontSize = 38
        versusTimerLabel.fontColor = SKColor(red: 0.25, green: 0.15, blue: 0.08, alpha: 0.9)
        versusTimerLabel.position = CGPoint(x: 0, y: size.height / 2 - 74)
        versusTimerLabel.zPosition = 100
        versusTimerLabel.removeFromParent()
        cameraNode.addChild(versusTimerLabel)

        versusHoldLabel.text = ""
        versusHoldLabel.fontName = "AvenirNext-DemiBold"
        versusHoldLabel.fontSize = 14
        versusHoldLabel.fontColor = SKColor(red: 0.25, green: 0.15, blue: 0.08, alpha: 0.7)
        versusHoldLabel.position = CGPoint(x: 0, y: size.height / 2 - 92)
        versusHoldLabel.zPosition = 100
        versusHoldLabel.removeFromParent()
        cameraNode.addChild(versusHoldLabel)

        let buildLabel = SKLabelNode(text: "build \(GameScene.buildNumber)")
        buildLabel.fontName = "Menlo"
        buildLabel.fontSize = 12
        buildLabel.fontColor = SKColor(red: 0.25, green: 0.15, blue: 0.08, alpha: 0.45)
        buildLabel.position = CGPoint(x: 0, y: -size.height / 2 + 40)
        buildLabel.zPosition = 100
        cameraNode.addChild(buildLabel)

        connectionLabel.removeFromParent()
        connectionLabel.fontName = "AvenirNext-DemiBold"
        connectionLabel.fontSize = 13
        connectionLabel.horizontalAlignmentMode = .left
        connectionLabel.position = CGPoint(x: -size.width / 2 + 16,
                                           y: size.height / 2 - 74)
        connectionLabel.zPosition = 100
        updateConnectionLabel()
        cameraNode.addChild(connectionLabel)

        attachWaitingLabel()
    }

    /// Build (or rebuild) the court: perimeter walls with 1–2 ball-sized
    /// gaps, a couple of maze bars, and bouncy bumpers. Called at round
    /// start and again after every transfer, so the escape route keeps
    /// changing. `clearPoint` (the incoming ball's entry spot) is kept
    /// free of obstacles.
    private func regenerateVersusLayout(clearPoint: CGPoint?) {
        wallsNode.removeAllChildren()
        for node in versusObstacleNodes {
            node.removeFromParent()
            if let sprite = node as? SKSpriteNode,
               let index = propNodes.firstIndex(of: sprite) {
                propNodes.remove(at: index)
            }
        }
        versusObstacleNodes.removeAll()

        // 1–2 gaps on distinct edges. On the top edge the middle is out of
        // bounds — the speaker/Dynamic Island hides it, so a gap there
        // would be invisible.
        var gaps: [(edge: Int, range: ClosedRange<CGFloat>)] = []
        var edges = [0, 1, 2, 3].shuffled()
        for _ in 0..<Int.random(in: 1...2) {
            let edge = edges.removeFirst()
            let length = edge >= 2 ? worldRect.width : worldRect.height
            let fraction: CGFloat
            if edge == 2 {
                fraction = Bool.random()
                    ? CGFloat.random(in: 0.15...0.30)
                    : CGFloat.random(in: 0.70...0.85)
            } else {
                fraction = CGFloat.random(in: 0.22...0.78)
            }
            let center = fraction * length
            let lower = center - GameScene.versusGapHalf
            let upper = center + GameScene.versusGapHalf
            gaps.append((edge, lower...upper))
        }

        let wallColor = SKColor(red: 1.0, green: 0.45, blue: 0.25, alpha: 1)
        for edge in 0...3 {
            let horizontal = edge >= 2
            let length = horizontal ? worldRect.width : worldRect.height
            // Wall segments = the edge minus its gaps.
            var segments: [(CGFloat, CGFloat)] = []
            var cursor: CGFloat = 0
            for gap in gaps.filter({ $0.edge == edge })
                .sorted(by: { $0.range.lowerBound < $1.range.lowerBound }) {
                if gap.range.lowerBound > cursor {
                    segments.append((cursor, gap.range.lowerBound))
                }
                cursor = gap.range.upperBound
            }
            if cursor < length { segments.append((cursor, length)) }

            for (a, b) in segments {
                let from: CGPoint
                let to: CGPoint
                switch edge {
                case 0:
                    from = CGPoint(x: worldRect.minX, y: a)
                    to = CGPoint(x: worldRect.minX, y: b)
                case 1:
                    from = CGPoint(x: worldRect.maxX, y: a)
                    to = CGPoint(x: worldRect.maxX, y: b)
                case 2:
                    from = CGPoint(x: a, y: worldRect.maxY)
                    to = CGPoint(x: b, y: worldRect.maxY)
                default:
                    from = CGPoint(x: a, y: worldRect.minY)
                    to = CGPoint(x: b, y: worldRect.minY)
                }
                let body = SKPhysicsBody(edgeFrom: from, to: to)
                body.friction = 0.1
                body.restitution = 0.6
                let node = SKNode()
                node.physicsBody = body
                wallsNode.addChild(node)

                // Visible wall bar: bright orange with a white edge and a
                // soft glow, so the border (and its missing pieces) pop.
                let thickness: CGFloat = 14
                let barSize = horizontal
                    ? CGSize(width: b - a, height: thickness)
                    : CGSize(width: thickness, height: b - a)
                let bar = SKShapeNode(rectOf: barSize, cornerRadius: 4)
                bar.fillColor = wallColor
                bar.strokeColor = SKColor(white: 1, alpha: 0.9)
                bar.lineWidth = 2
                bar.glowWidth = 3
                let inset = thickness / 2
                switch edge {
                case 0: bar.position = CGPoint(x: worldRect.minX + inset, y: (a + b) / 2)
                case 1: bar.position = CGPoint(x: worldRect.maxX - inset, y: (a + b) / 2)
                case 2: bar.position = CGPoint(x: (a + b) / 2, y: worldRect.maxY - inset)
                default: bar.position = CGPoint(x: (a + b) / 2, y: worldRect.minY + inset)
                }
                bar.zPosition = 6
                wallsNode.addChild(bar)
            }
        }

        // A pulsing golden glow in each gap: THIS is the way out.
        for gap in gaps {
            let horizontal = gap.edge >= 2
            let length = gap.range.upperBound - gap.range.lowerBound
            let mid = (gap.range.lowerBound + gap.range.upperBound) / 2
            let marker = SKShapeNode(
                rectOf: horizontal
                    ? CGSize(width: length, height: 18)
                    : CGSize(width: 18, height: length),
                cornerRadius: 9
            )
            marker.fillColor = SKColor(red: 1.0, green: 0.82, blue: 0.35, alpha: 0.35)
            marker.strokeColor = SKColor(red: 1.0, green: 0.82, blue: 0.35, alpha: 0.95)
            marker.lineWidth = 3
            marker.glowWidth = 7
            switch gap.edge {
            case 0: marker.position = CGPoint(x: worldRect.minX + 9, y: mid)
            case 1: marker.position = CGPoint(x: worldRect.maxX - 9, y: mid)
            case 2: marker.position = CGPoint(x: mid, y: worldRect.maxY - 9)
            default: marker.position = CGPoint(x: mid, y: worldRect.minY + 9)
            }
            marker.zPosition = 7
            let pulse = SKAction.sequence([
                .group([.scale(to: 1.15, duration: 0.5),
                        .fadeAlpha(to: 0.55, duration: 0.5)]),
                .group([.scale(to: 1.0, duration: 0.5),
                        .fadeAlpha(to: 1.0, duration: 0.5)]),
            ])
            pulse.timingMode = .easeInEaseOut
            marker.run(.repeatForever(pulse))
            wallsNode.addChild(marker)
        }

        // A comb maze fills the court: full-width walls with a single
        // doorway each, so reaching the exit means weaving through the
        // right doors instead of rolling across open floor.
        let mazeThickness: CGFloat = 13
        let doorWidth = GameScene.ballRadius * 3.4
        let rowFractions: [CGFloat] = [0.26, 0.44, 0.62, 0.80]
        let rowYs = rowFractions.map { worldRect.height * $0 }

        func addMazeBar(center: CGPoint, size barSize: CGSize) {
            let bar = SKShapeNode(rectOf: barSize, cornerRadius: 4)
            bar.fillColor = wallColor
            bar.strokeColor = SKColor(white: 1, alpha: 0.65)
            bar.lineWidth = 1.5
            bar.position = center
            bar.zPosition = 6
            let body = SKPhysicsBody(rectangleOf: barSize)
            body.isDynamic = false
            body.restitution = 0.5
            body.friction = 0.2
            bar.physicsBody = body
            addChild(bar)
            versusObstacleNodes.append(bar)
        }

        for y in rowYs {
            // One doorway per row, plus safe openings wherever the ball
            // spawn or the incoming entry point sits on the row.
            var openings: [ClosedRange<CGFloat>] = []
            let doorCenter = CGFloat.random(in: 0.16...0.84) * worldRect.width
            openings.append((doorCenter - doorWidth / 2)...(doorCenter + doorWidth / 2))
            for special in [startPosition, clearPoint].compactMap({ $0 })
            where abs(special.y - y) < 80 {
                openings.append((special.x - doorWidth / 2)...(special.x + doorWidth / 2))
            }

            var cursor: CGFloat = 0
            for opening in openings.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                let end = min(max(opening.lowerBound, 0), worldRect.width)
                if end - cursor > 34 {
                    addMazeBar(
                        center: CGPoint(x: (cursor + end) / 2, y: y),
                        size: CGSize(width: end - cursor, height: mazeThickness)
                    )
                }
                cursor = max(cursor, opening.upperBound)
            }
            if worldRect.width - cursor > 34 {
                addMazeBar(
                    center: CGPoint(x: (cursor + worldRect.width) / 2, y: y),
                    size: CGSize(width: worldRect.width - cursor, height: mazeThickness)
                )
            }
        }

        // Somewhere free of the ball spawn, the entry point, and the maze
        // rows, so props sit in the corridors instead of inside walls.
        func freeSpot() -> CGPoint {
            for _ in 0..<32 {
                let p = CGPoint(
                    x: worldRect.width * CGFloat.random(in: 0.12...0.88),
                    y: worldRect.height * CGFloat.random(in: 0.14...0.86)
                )
                let clearOfStart = hypot(p.x - startPosition.x,
                                         p.y - startPosition.y) > 110
                let clearOfEntry = clearPoint.map {
                    hypot(p.x - $0.x, p.y - $0.y) > 110
                } ?? true
                let clearOfRows = rowYs.allSatisfy { abs(p.y - $0) > 48 }
                if clearOfStart, clearOfEntry, clearOfRows { return p }
            }
            return CGPoint(x: worldRect.width * 0.25, y: worldRect.height * 0.72)
        }

        // Vertical spurs between the rows turn corridors into dead ends.
        for _ in 0..<4 {
            addMazeBar(
                center: freeSpot(),
                size: CGSize(width: mazeThickness,
                             height: CGFloat.random(in: 90...130))
            )
        }

        // Mushroom bumpers (same pinball kick as the climb) guarding the
        // corridors.
        for _ in 0..<5 {
            let bumper = spawnObstacle(.bumper, at: freeSpot())
            versusObstacleNodes.append(bumper)
        }

        // Floor holes: falling in pops the ball out of the same spot on
        // the opponent's court — another way to pass the hot potato.
        for hole in versusHoles { hole.removeFromParent() }
        versusHoles.removeAll()
        for _ in 0..<Int.random(in: 1...2) {
            let hole = SKSpriteNode(
                texture: GameScene.holeTexture(radius: GameScene.holeRadius))
            hole.position = freeSpot()
            hole.zPosition = 2
            addChild(hole)
            versusHoles.append(hole)
        }
    }

    /// The versus frame: match clock, hot-potato accounting, steering,
    /// hop, and escape detection.
    private func updateVersus(currentTime: TimeInterval, dt: CGFloat,
                              body: SKPhysicsBody) {
        shadow.position = CGPoint(x: ball.position.x, y: ball.position.y - 4)

        if matchOver {
            body.velocity = .zero
            return
        }

        // The clock only runs against a live opponent; alone it's practice.
        if peerConnected, matchStartTime == nil {
            matchStartTime = currentTime
        }
        let elapsed = matchStartTime.map { currentTime - $0 } ?? 0
        if peerConnected, ballIsHere {
            myHoldTime += TimeInterval(dt)
        }

        let remaining = max(0, GameScene.versusMatchSeconds - elapsed)
        let remainingSeconds = Int(ceil(remaining))
        versusTimerLabel.text = L10n.t("のこり \(remainingSeconds)秒",
                                       "\(remainingSeconds)s left")
        // Final 10 seconds: the timer turns alarm-red and pulses.
        if peerConnected, remaining <= 10, !versusTimerUrgent {
            versusTimerUrgent = true
            versusTimerLabel.fontColor = SKColor(red: 0.90, green: 0.15,
                                                 blue: 0.10, alpha: 1)
            let pulse = SKAction.sequence([
                .scale(to: 1.22, duration: 0.25),
                .scale(to: 1.0, duration: 0.25),
            ])
            pulse.timingMode = .easeInEaseOut
            versusTimerLabel.run(.repeatForever(pulse), withKey: "timerPulse")
        }
        if peerConnected {
            let theirHold = max(0, elapsed - myHoldTime)
            versusHoldLabel.text = L10n.t(
                String(format: "もってた時間  きみ %.1f ・ あいて %.1f（少ないほうが勝ち）",
                       myHoldTime, theirHold),
                String(format: "Held  you %.1f ・ them %.1f (less wins)",
                       myHoldTime, theirHold)
            )
        } else {
            versusHoldLabel.text = L10n.t("れんしゅう中（あいてをさがしています）",
                                          "Practice (looking for an opponent)")
        }

        if peerConnected, elapsed >= GameScene.versusMatchSeconds {
            finishVersusMatch()
            return
        }

        guard ballIsHere else { return }

        // Hop over a bumper with a quick upward pop of the phone.
        if !isAirborne, !isFalling,
           currentTime - lastHopTime > GameScene.hopCooldown,
           let jerk = motion.deviceMotion?.userAcceleration.z,
           jerk > GameScene.hopThreshold {
            lastHopTime = currentTime
            hop()
        }

        // Escaped through a gap: the ball is the opponent's problem now.
        let r = GameScene.ballRadius
        var exitEdge: Int?
        var fraction: CGFloat = 0
        if ball.position.x < worldRect.minX - r {
            exitEdge = 0
            fraction = (ball.position.y - worldRect.minY) / worldRect.height
        } else if ball.position.x > worldRect.maxX + r {
            exitEdge = 1
            fraction = (ball.position.y - worldRect.minY) / worldRect.height
        } else if ball.position.y > worldRect.maxY + r {
            exitEdge = 2
            fraction = (ball.position.x - worldRect.minX) / worldRect.width
        } else if ball.position.y < worldRect.minY - r {
            exitEdge = 3
            fraction = (ball.position.x - worldRect.minX) / worldRect.width
        }
        if let edge = exitEdge {
            if peerConnected {
                sendVersusBall(edge: edge, fraction: fraction, body: body)
            } else {
                // Practice: bring it back to the middle.
                ball.position = startPosition
                body.velocity = .zero
            }
            return
        }

        // A grounded ball over a floor hole drops through — and pops out
        // of the same spot on the opponent's court. Hop to clear one.
        if !isAirborne, !isFalling {
            for hole in versusHoles {
                let distance = hypot(ball.position.x - hole.position.x,
                                     ball.position.y - hole.position.y)
                guard distance < GameScene.holeRadius * 0.8 else { continue }
                if peerConnected {
                    sendVersusHole(from: hole)
                } else {
                    ball.position = startPosition
                    body.velocity = .zero
                }
                return
            }
        }

        // Tilt steering, same feel as the climb.
        if !isAirborne, !isFalling, var tilt = currentTilt() {
            if abs(tilt.dx) < GameScene.deadZone { tilt.dx = 0 }
            if abs(tilt.dy) < GameScene.deadZone { tilt.dy = 0 }

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
    }

    /// Ship the escaped ball to the opponent and reshuffle this court.
    private func sendVersusBall(edge: Int, fraction: CGFloat,
                                body: SKPhysicsBody) {
        let transfer = VersusTransfer(
            edge: edge,
            fraction: Double(min(max(fraction, 0), 1)),
            velocityDX: Double(body.velocity.dx),
            velocityDY: Double(body.velocity.dy),
            colorIndex: displayedColorIndex,
            patternIndex: displayedPatternIndex,
            skinPNG: displayedPatternIndex == BallPattern.custom.rawValue
                ? displayedSkinData : nil
        )
        multipeer.send(.versusTransfer(transfer))

        ballIsHere = false
        ball.isHidden = true
        shadow.isHidden = true
        body.velocity = .zero
        ball.position = startPosition

        // The escape route moves every time the ball changes screens.
        regenerateVersusLayout(clearPoint: nil)
    }

    /// The opponent pushed the ball through: it enters on the mirrored
    /// edge with its speed intact, onto a freshly shuffled court.
    private func receiveVersusBall(_ transfer: VersusTransfer) {
        guard isVersus, !matchOver else { return }

        let margin = GameScene.ballRadius * 1.6
        let f = CGFloat(min(max(transfer.fraction, 0), 1))
        let entry: CGPoint
        switch transfer.edge {
        case 0: // left exit → right entry
            entry = CGPoint(x: worldRect.maxX - margin,
                            y: worldRect.minY + f * worldRect.height)
        case 1:
            entry = CGPoint(x: worldRect.minX + margin,
                            y: worldRect.minY + f * worldRect.height)
        case 2: // top exit → bottom entry
            entry = CGPoint(x: worldRect.minX + f * worldRect.width,
                            y: worldRect.minY + margin)
        default:
            entry = CGPoint(x: worldRect.minX + f * worldRect.width,
                            y: worldRect.maxY - margin)
        }

        regenerateVersusLayout(clearPoint: entry)

        displayedColorIndex = transfer.colorIndex
        displayedPatternIndex = transfer.patternIndex
        displayedSkinData = transfer.skinPNG
        applyDisplayedStyle()

        ballIsHere = true
        isAirborne = false
        isFalling = false
        ball.removeAllActions()
        shadow.removeAllActions()
        ball.setScale(1)
        ball.alpha = 1
        shadow.setScale(1)
        shadow.alpha = 1
        ball.isHidden = false
        shadow.isHidden = false
        ball.position = entry
        ball.physicsBody?.velocity = CGVector(dx: transfer.velocityDX,
                                              dy: transfer.velocityDY)
    }

    /// Time! Freeze, swap hold times, and settle the winner.
    private func finishVersusMatch() {
        matchOver = true
        ball.physicsBody?.velocity = .zero
        multipeer.send(.versusResult(holdSeconds: myHoldTime))

        if let theirs = peerHoldReported {
            showVersusResult(theirHold: theirs)
        } else {
            // If the peer's number never arrives, fall back to our own
            // bookkeeping (their hold ≈ the rest of the match).
            run(.sequence([
                .wait(forDuration: 2.5),
                .run { [weak self] in
                    guard let self, !self.versusResultShown else { return }
                    self.showVersusResult(theirHold:
                        max(0, GameScene.versusMatchSeconds - self.myHoldTime))
                },
            ]), withKey: "versusResultTimeout")
        }
    }

    private func receiveVersusResult(holdSeconds: Double) {
        guard isVersus else { return }
        peerHoldReported = holdSeconds
        if matchOver, !versusResultShown {
            showVersusResult(theirHold: holdSeconds)
        }
    }

    /// The ball dropped into a floor hole: sink, then pop out of the same
    /// spot over there. This court reshuffles like any other transfer.
    private func sendVersusHole(from hole: SKSpriteNode) {
        guard let body = ball.physicsBody else { return }
        isFalling = true
        fallHaptic.impactOccurred()
        let exitVelocity = body.velocity
        body.velocity = .zero

        let drop = BallDrop(
            xOffsetPoints: Double(hole.position.x - cameraNode.position.x),
            yOffsetPoints: Double(hole.position.y - cameraNode.position.y),
            velocityDX: Double(exitVelocity.dx),
            velocityDY: Double(exitVelocity.dy),
            colorIndex: displayedColorIndex,
            patternIndex: displayedPatternIndex,
            skinPNG: displayedPatternIndex == BallPattern.custom.rawValue
                ? displayedSkinData : nil
        )
        multipeer.send(.versusHoleDrop(drop))

        let suck = SKAction.group([
            .move(to: hole.position, duration: 0.12),
            .scale(to: 0.08, duration: 0.3),
            .fadeOut(withDuration: 0.3),
        ])
        suck.timingMode = .easeIn
        shadow.run(.fadeOut(withDuration: 0.2))
        ball.run(.sequence([suck, .run { [weak self] in
            guard let self else { return }
            self.ball.isHidden = true
            self.ballIsHere = false
            self.isFalling = false
            self.ball.setScale(1)
            self.ball.alpha = 1
            self.shadow.isHidden = true
            self.shadow.alpha = 1
            self.regenerateVersusLayout(clearPoint: nil)
        }]))
    }

    /// The opponent's ball fell through a hole: it pops out of the same
    /// screen spot here, arriving from above.
    private func receiveVersusHoleDrop(_ drop: BallDrop) {
        guard isVersus, !matchOver else { return }

        let margin = GameScene.ballRadius * 2
        var entry = CGPoint(
            x: cameraNode.position.x + CGFloat(drop.xOffsetPoints),
            y: cameraNode.position.y + CGFloat(drop.yOffsetPoints)
        )
        entry.x = min(max(entry.x, worldRect.minX + margin), worldRect.maxX - margin)
        entry.y = min(max(entry.y, worldRect.minY + margin), worldRect.maxY - margin)

        regenerateVersusLayout(clearPoint: entry)

        displayedColorIndex = drop.colorIndex
        displayedPatternIndex = drop.patternIndex
        displayedSkinData = drop.skinPNG
        applyDisplayedStyle()

        ballIsHere = true
        isAirborne = false
        isFalling = false
        ball.removeAllActions()
        shadow.removeAllActions()
        ball.isHidden = false
        ball.alpha = 1
        ball.position = entry
        ball.setScale(1.6) // arrives from above and settles
        ball.physicsBody?.velocity = CGVector(dx: drop.velocityDX,
                                              dy: drop.velocityDY)
        shadow.isHidden = false
        shadow.alpha = 1
        shadow.setScale(1)
        shadow.position = entry

        landingHaptic.impactOccurred()
        let settle = SKAction.scale(to: 1.0, duration: 0.14)
        settle.timingMode = .easeIn
        ball.run(settle)
    }

    private func showVersusResult(theirHold: Double) {
        versusResultShown = true
        removeAction(forKey: "versusResultTimeout")
        goalHaptic.notificationOccurred(.success)

        let mine = myHoldTime
        let title: String
        let color: SKColor
        if abs(mine - theirHold) < 0.3 {
            title = L10n.t("ひきわけ！", "DRAW!")
            color = SKColor(red: 0.25, green: 0.15, blue: 0.08, alpha: 1)
        } else if mine < theirHold {
            title = L10n.t("きみのかち！", "YOU WIN!")
            color = SKColor(red: 0.85, green: 0.55, blue: 0.10, alpha: 1)
        } else {
            title = L10n.t("まけちゃった…", "YOU LOSE…")
            color = SKColor(red: 0.45, green: 0.30, blue: 0.25, alpha: 1)
        }

        let banner = SKLabelNode(text: title)
        banner.fontName = "AvenirNext-Bold"
        banner.fontSize = 38
        banner.fontColor = color
        banner.position = CGPoint(x: 0, y: 20)
        banner.zPosition = 100
        banner.setScale(0.1)
        cameraNode.addChild(banner)
        let popIn = SKAction.scale(to: 1.0, duration: 0.3)
        popIn.timingMode = .easeOut
        banner.run(popIn)

        let sub = SKLabelNode(text: L10n.t(
            String(format: "きみ %.1f秒 ・ あいて %.1f秒", mine, theirHold),
            String(format: "You %.1fs ・ Them %.1fs", mine, theirHold)
        ))
        sub.fontName = "AvenirNext-DemiBold"
        sub.fontSize = 17
        sub.fontColor = SKColor(red: 0.25, green: 0.15, blue: 0.08, alpha: 0.75)
        sub.position = CGPoint(x: 0, y: -14)
        sub.zPosition = 100
        cameraNode.addChild(sub)

        let button = makeGateButton(text: L10n.t("もういちど", "REMATCH"))
        cameraNode.addChild(button)
        tryAgainButton = button
        awaitingRestart = true
    }

    // MARK: - Vertical drop between phones (Milestone 4)

    /// The ball fell into a chasm with a peer connected below: it keeps
    /// falling through real space toward the phone underneath. Ship it to
    /// the peer and wait to hear whether they caught it.
    private func dropBallToPeer(at point: CGPoint) {
        isFalling = true
        awaitingDropResult = true
        fallHaptic.impactOccurred()
        let exitVelocity = ball.physicsBody?.velocity ?? .zero
        ball.physicsBody?.velocity = .zero

        // Send the fall's spot as a point offset from the screen center:
        // the catching phone sits physically underneath, so the same spot
        // on its screen is where the ball should land.
        let drop = BallDrop(
            xOffsetPoints: Double(point.x - cameraNode.position.x),
            yOffsetPoints: Double(point.y - cameraNode.position.y),
            velocityDX: Double(exitVelocity.dx),
            velocityDY: Double(exitVelocity.dy),
            colorIndex: displayedColorIndex,
            patternIndex: displayedPatternIndex,
            skinPNG: displayedPatternIndex == BallPattern.custom.rawValue
                ? displayedSkinData : nil
        )
        multipeer.send(.drop(drop))

        let suck = SKAction.group([
            .scale(to: 0.08, duration: 0.3),
            .fadeOut(withDuration: 0.3),
        ])
        suck.timingMode = .easeIn
        shadow.run(.fadeOut(withDuration: 0.2))
        ball.run(.sequence([suck, .run { [weak self] in
            self?.ball.isHidden = true
            self?.ballIsHere = false
        }]))

        // If the peer never answers (disconnected mid-fall), bring it home.
        run(.sequence([
            .wait(forDuration: GameScene.dropResultTimeout),
            .run { [weak self] in
                guard let self, self.awaitingDropResult else { return }
                self.awaitingDropResult = false
                self.respawnBall()
            },
        ]), withKey: "dropTimeout")
    }

    /// The peer reported whether the ball dropped from here was caught.
    private func handleDropResult(caught: Bool) {
        guard awaitingDropResult else { return }
        awaitingDropResult = false
        removeAction(forKey: "dropTimeout")

        if caught {
            // The ball lives on the other phone now.
            isFalling = false
            showToast(L10n.t("ナイスキャッチ！", "Nice catch!"))
        } else {
            showToast(L10n.t("キャッチミス！ボールがもどってきた", "Missed! The ball came back"))
            respawnBall()
        }
    }

    /// Bring the ball back after a missed drop or a timeout — near where
    /// it fell (the run continues; losing all progress would be brutal).
    private func respawnBall() {
        ballIsHere = true
        ball.removeAllActions()
        ball.isHidden = false
        ball.alpha = 0
        ball.setScale(0.3)
        ball.position = clampToWorld(safeLandingPoint(CGPoint(
            x: worldRect.midX, y: cameraNode.position.y
        )))
        ball.physicsBody?.velocity = .zero
        ball.run(.group([
            .scale(to: 1.0, duration: 0.25),
            .fadeIn(withDuration: 0.2),
        ])) { self.isFalling = false }
        shadow.removeAllActions()
        shadow.isHidden = false
        shadow.run(.fadeIn(withDuration: 0.2))
    }

    /// A ball is falling from the phone held above: its shadow swells on the
    /// floor and, if this phone is held level when it arrives, the ball
    /// lands here and play continues on this screen.
    private func receiveFallingBall(_ drop: BallDrop) {
        // The incoming ball replaces whatever this screen was doing.
        ball.removeAllActions()
        shadow.removeAllActions()
        removeAction(forKey: "dropTimeout")
        isFalling = false
        isAirborne = false
        awaitingDropResult = false
        ballIsHere = false
        ball.isHidden = true
        shadow.isHidden = true
        ball.physicsBody?.velocity = .zero

        displayedColorIndex = drop.colorIndex
        displayedPatternIndex = drop.patternIndex
        displayedSkinData = drop.skinPNG
        applyDisplayedStyle()

        // Map the sender's screen spot onto the part of the world this
        // camera is showing — stacked phones share the same physical spot —
        // then shift onto safe ground, because this course is generated
        // independently of the one the ball fell from.
        let landing = CGPoint(
            x: cameraNode.position.x + CGFloat(drop.xOffsetPoints),
            y: cameraNode.position.y + CGFloat(drop.yOffsetPoints)
        )
        let clamped = clampToWorld(safeLandingPoint(clampToWorld(landing)))

        landingHaptic.prepare()

        // The ball closing in from above, seen as its growing shadow.
        let dropShadow = SKSpriteNode(
            texture: GameScene.softShadowTexture(radius: GameScene.ballRadius))
        dropShadow.position = clamped
        dropShadow.zPosition = 5
        dropShadow.setScale(0.2)
        dropShadow.alpha = 0.2
        addChild(dropShadow)

        let swell = SKAction.group([
            .scale(to: 1.35, duration: GameScene.dropFallDuration),
            .fadeAlpha(to: 1.0, duration: GameScene.dropFallDuration),
        ])
        swell.timingMode = .easeIn
        let velocity = CGVector(dx: drop.velocityDX, dy: drop.velocityDY)
        dropShadow.run(.sequence([
            swell,
            .run { [weak self] in
                self?.resolveDropLanding(at: clamped, velocity: velocity)
            },
            .removeFromParent(),
        ]))
    }

    private func clampToWorld(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, worldRect.minX + GameScene.ballRadius),
                   worldRect.maxX - GameScene.ballRadius),
            y: min(max(point.y, worldRect.minY + GameScene.ballRadius),
                   worldRect.maxY - GameScene.ballRadius)
        )
    }

    /// Push a landing point onto safe ground: out of any chasm (onto its
    /// bridge when one is near, otherwise past the chasm's edge) and out
    /// of any obstacle it would materialize inside. The two phones run
    /// different random courses, so the spot that was plain floor
    /// upstairs can be anything down here.
    private func safeLandingPoint(_ point: CGPoint) -> CGPoint {
        var point = point
        // Above the collapse edge, always.
        point.y = max(point.y, chaseY + GameScene.ballRadius * 3)
        for zone in voidZones where zone.rect.contains(point) {
            if let bridge = zone.bridges.min(by: {
                abs($0.midX - point.x) < abs($1.midX - point.x)
            }), abs(bridge.midX - point.x) < size.width * 0.2 {
                point.x = bridge.midX
            } else {
                let below = zone.rect.minY - GameScene.ballRadius - 4
                let above = zone.rect.maxY + GameScene.ballRadius + 4
                point.y = abs(point.y - below) < abs(point.y - above)
                    ? below : above
            }
        }

        // Out of obstacles: shift past the nearest edge of any prop whose
        // (rotation-aware) frame the point falls inside.
        for prop in propNodes {
            let zone = prop.frame.insetBy(dx: -GameScene.ballRadius,
                                          dy: -GameScene.ballRadius)
            guard zone.contains(point) else { continue }
            // Cheapest escape among the four sides.
            let pushes = [
                CGPoint(x: zone.minX - 1, y: point.y),
                CGPoint(x: zone.maxX + 1, y: point.y),
                CGPoint(x: point.x, y: zone.minY - 1),
                CGPoint(x: point.x, y: zone.maxY + 1),
            ]
            point = pushes.min(by: {
                hypot($0.x - point.x, $0.y - point.y)
                    < hypot($1.x - point.x, $1.y - point.y)
            }) ?? point
        }
        return point
    }

    /// The falling ball reached this phone's plane. In stacked play the
    /// players have physically placed this phone underneath, so the only
    /// requirement is that it's face up (resting on a surface is fine);
    /// tipped over or face down, the ball whiffs past and the thrower
    /// gets it back.
    private func resolveDropLanding(at point: CGPoint, velocity: CGVector) {
        let gravityZ = motion.deviceMotion?.gravity.z ?? -1
        let caught = gravityZ < GameScene.catchLevelThreshold
        multipeer.send(.dropResult(caught: caught))

        guard caught else {
            fallHaptic.impactOccurred()
            showToast(L10n.t("ミス！画面を上に向けて！", "Miss! Keep the screen facing up!"))
            return
        }

        ballIsHere = true
        ball.isHidden = false
        ball.alpha = 1
        ball.position = point
        // Arrives from above: starts big (close to the viewer) and settles.
        ball.setScale(1.6)
        ball.physicsBody?.velocity = velocity
        shadow.isHidden = false
        shadow.alpha = 1
        shadow.setScale(1)
        shadow.position = point

        // Immunity so the landing spot's own hole can't swallow it back.
        isDropGrace = true
        run(.sequence([
            .wait(forDuration: GameScene.catchGraceDuration),
            .run { [weak self] in self?.isDropGrace = false },
        ]), withKey: "dropGrace")

        let settle = SKAction.scale(to: 1.0, duration: 0.14)
        settle.timingMode = .easeIn
        let squash = SKAction.sequence([
            .scaleX(to: 1.22, y: 0.78, duration: 0.07),
            .scaleX(to: 0.94, y: 1.06, duration: 0.08),
            .scaleX(to: 1.0, y: 1.0, duration: 0.07),
        ])
        ball.run(.sequence([
            settle,
            .run { [weak self] in self?.didLand() },
            squash,
        ]))
        showToast(L10n.t("キャッチ！", "Catch!"))
    }

    // MARK: - Casual hole warp (co-op, "position doesn't matter" setting)

    /// The ball fell into a casual co-op hole: sink into it, then teleport
    /// to the friend's phone — no stacking, no catch check.
    private func warpBallToPeer(at point: CGPoint) {
        guard let body = ball.physicsBody else { return }
        isFalling = true
        fallHaptic.impactOccurred()
        let exitVelocity = body.velocity
        body.velocity = .zero

        let drop = BallDrop(
            xOffsetPoints: Double(point.x - cameraNode.position.x),
            yOffsetPoints: Double(point.y - cameraNode.position.y),
            velocityDX: Double(exitVelocity.dx),
            velocityDY: Double(exitVelocity.dy),
            colorIndex: displayedColorIndex,
            patternIndex: displayedPatternIndex,
            skinPNG: displayedPatternIndex == BallPattern.custom.rawValue
                ? displayedSkinData : nil
        )
        multipeer.send(.coopWarp(drop))

        let suck = SKAction.group([
            .move(to: point, duration: 0.12),
            .scale(to: 0.08, duration: 0.3),
            .fadeOut(withDuration: 0.3),
        ])
        suck.timingMode = .easeIn
        shadow.run(.fadeOut(withDuration: 0.2))
        ball.run(.sequence([suck, .run { [weak self] in
            guard let self else { return }
            self.ball.isHidden = true
            self.ballIsHere = false
            self.isFalling = false
            self.ball.setScale(1)
            self.ball.alpha = 1
            self.shadow.isHidden = true
            self.shadow.alpha = 1
        }]))
    }

    /// A warped ball arrives: swelling shadow, then it always lands —
    /// this is the casual setting, no catch requirements.
    private func receiveCoopWarp(_ drop: BallDrop) {
        guard isCoop else { return }
        ball.removeAllActions()
        shadow.removeAllActions()
        removeAction(forKey: "dropTimeout")
        isFalling = false
        isAirborne = false
        awaitingDropResult = false
        ballIsHere = false
        ball.isHidden = true
        shadow.isHidden = true
        ball.physicsBody?.velocity = .zero

        displayedColorIndex = drop.colorIndex
        displayedPatternIndex = drop.patternIndex
        displayedSkinData = drop.skinPNG
        applyDisplayedStyle()

        let landing = CGPoint(
            x: cameraNode.position.x + CGFloat(drop.xOffsetPoints),
            y: cameraNode.position.y + CGFloat(drop.yOffsetPoints)
        )
        let clamped = clampToWorld(safeLandingPoint(clampToWorld(landing)))

        landingHaptic.prepare()
        let dropShadow = SKSpriteNode(
            texture: GameScene.softShadowTexture(radius: GameScene.ballRadius))
        dropShadow.position = clamped
        dropShadow.zPosition = 5
        dropShadow.setScale(0.2)
        dropShadow.alpha = 0.2
        addChild(dropShadow)

        let swell = SKAction.group([
            .scale(to: 1.35, duration: GameScene.dropFallDuration),
            .fadeAlpha(to: 1.0, duration: GameScene.dropFallDuration),
        ])
        swell.timingMode = .easeIn
        let velocity = CGVector(dx: drop.velocityDX, dy: drop.velocityDY)
        dropShadow.run(.sequence([
            swell,
            .run { [weak self] in
                self?.landWarpedBall(at: clamped, velocity: velocity)
            },
            .removeFromParent(),
        ]))
    }

    /// Place the warped ball on this screen with the arrival squash.
    private func landWarpedBall(at point: CGPoint, velocity: CGVector) {
        ballIsHere = true
        ball.isHidden = false
        ball.alpha = 1
        ball.position = point
        ball.setScale(1.6)
        ball.physicsBody?.velocity = velocity
        shadow.isHidden = false
        shadow.alpha = 1
        shadow.setScale(1)
        shadow.position = point

        // Immunity so the landing spot's own hole can't swallow it back.
        isDropGrace = true
        run(.sequence([
            .wait(forDuration: GameScene.catchGraceDuration),
            .run { [weak self] in self?.isDropGrace = false },
        ]), withKey: "dropGrace")

        let settle = SKAction.scale(to: 1.0, duration: 0.14)
        settle.timingMode = .easeIn
        let squash = SKAction.sequence([
            .scaleX(to: 1.22, y: 0.78, duration: 0.07),
            .scaleX(to: 0.94, y: 1.06, duration: 0.08),
            .scaleX(to: 1.0, y: 1.0, duration: 0.07),
        ])
        ball.run(.sequence([
            settle,
            .run { [weak self] in self?.didLand() },
            squash,
        ]))
        showToast(L10n.t("ワープしてきた！", "Warped in!"))
    }

    /// A short message that pops in under the level label and fades away.
    private func showToast(_ text: String) {
        cameraNode.childNode(withName: "toast")?.removeFromParent()
        let label = SKLabelNode(text: text)
        label.name = "toast"
        label.fontName = "AvenirNext-Bold"
        label.fontSize = 17
        label.fontColor = SKColor(red: 0.25, green: 0.15, blue: 0.08, alpha: 0.9)
        label.position = CGPoint(x: 0, y: size.height / 2 - 100)
        label.zPosition = 100
        label.setScale(0.5)
        cameraNode.addChild(label)

        let pop = SKAction.scale(to: 1.0, duration: 0.15)
        pop.timingMode = .easeOut
        label.run(.sequence([
            pop,
            .wait(forDuration: 1.6),
            .fadeOut(withDuration: 0.3),
            .removeFromParent(),
        ]))
    }

    // MARK: - Ball transfer between phones

    /// The ball left through an open side edge: ship its motion and style to
    /// the peer, then hide it here until it comes back.
    private func sendBallToPeer() {
        guard let body = ball.physicsBody else { return }

        let transfer = BallTransfer(
            yOffsetPoints: Double(ball.position.y - cameraNode.position.y),
            velocityDX: Double(body.velocity.dx),
            velocityDY: Double(body.velocity.dy),
            exitedRightEdge: ball.position.x > worldRect.midX,
            colorIndex: displayedColorIndex,
            patternIndex: displayedPatternIndex,
            skinPNG: displayedPatternIndex == BallPattern.custom.rawValue
                ? displayedSkinData : nil
        )
        multipeer.send(.sideTransfer(transfer))

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
        awaitingDropResult = false
        removeAction(forKey: "dropTimeout")
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
        let y = cameraNode.position.y + CGFloat(transfer.yOffsetPoints)
        // This course is different from the sender's: shift the entry off
        // chasms and obstacles so the ball arrives on solid ground.
        ball.position = clampToWorld(safeLandingPoint(CGPoint(x: x, y: y)))
        body.velocity = CGVector(dx: transfer.velocityDX, dy: transfer.velocityDY)
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

    // MARK: Obstacle textures — geometric placeholders
    //
    // Flat geometric shapes for now; each one checks the asset bundle
    // first, so dropping images named "prop_stone", "prop_branch",
    // "prop_mushroom" or "prop_fence" into the project swaps the art
    // without touching code (same trick as deck.png for the floor).

    /// Bundle override: draw the image into the placeholder's canvas so
    /// sizes and physics stay identical whichever art is active.
    private static func propTexture(named name: String, size: CGSize,
                                    fallback: (CGContext) -> Void) -> SKTexture {
        let image = UIGraphicsImageRenderer(size: size).image { ctx in
            if let art = UIImage(named: name) {
                art.draw(in: CGRect(origin: .zero, size: size))
            } else {
                fallback(ctx.cgContext)
            }
        }
        return SKTexture(image: image)
    }

    /// Low obstacle: a flat slate circle with a darker ring.
    private static func stoneTexture() -> SKTexture {
        let diameter: CGFloat = 52
        let size = CGSize(width: diameter, height: diameter)
        return propTexture(named: "prop_stone", size: size) { _ in
            let full = CGRect(origin: .zero, size: size)
            UIColor(red: 0.45, green: 0.49, blue: 0.55, alpha: 1).setFill()
            UIBezierPath(ovalIn: full.insetBy(dx: 1, dy: 1)).fill()
            UIColor(red: 0.30, green: 0.34, blue: 0.40, alpha: 1).setStroke()
            let ring = UIBezierPath(ovalIn: full.insetBy(dx: 4, dy: 4))
            ring.lineWidth = 4
            ring.stroke()
            UIColor(white: 1, alpha: 0.25).setFill()
            UIBezierPath(ovalIn: CGRect(x: diameter * 0.22, y: diameter * 0.18,
                                        width: diameter * 0.2,
                                        height: diameter * 0.2)).fill()
        }
    }

    /// Low obstacle: a rounded teal bar.
    private static func barTexture(length: CGFloat = 150) -> SKTexture {
        let size = CGSize(width: max(length, 40), height: 24)
        return propTexture(named: "prop_branch", size: size) { _ in
            let full = CGRect(origin: .zero, size: size)
            let bar = UIBezierPath(roundedRect: full.insetBy(dx: 1, dy: 1),
                                   cornerRadius: 11)
            UIColor(red: 0.22, green: 0.55, blue: 0.55, alpha: 1).setFill()
            bar.fill()
            UIColor(red: 0.14, green: 0.38, blue: 0.38, alpha: 1).setStroke()
            bar.lineWidth = 3
            bar.stroke()
            UIColor(white: 1, alpha: 0.25).setFill()
            UIBezierPath(roundedRect: CGRect(x: 10, y: 5,
                                             width: size.width - 20, height: 4),
                         cornerRadius: 2).fill()
        }
    }

    /// Bouncy obstacle: a coral circle with a bold double ring, so it
    /// reads as "bumper" at a glance.
    private static func mushroomTexture() -> SKTexture {
        let diameter: CGFloat = 50
        let size = CGSize(width: diameter, height: diameter)
        return propTexture(named: "prop_mushroom", size: size) { _ in
            let full = CGRect(origin: .zero, size: size)
            UIColor(red: 0.95, green: 0.45, blue: 0.35, alpha: 1).setFill()
            UIBezierPath(ovalIn: full.insetBy(dx: 1, dy: 1)).fill()
            UIColor(white: 1, alpha: 0.9).setStroke()
            let ring = UIBezierPath(ovalIn: full.insetBy(dx: 7, dy: 7))
            ring.lineWidth = 3
            ring.stroke()
            UIColor(red: 0.72, green: 0.28, blue: 0.20, alpha: 1).setFill()
            UIBezierPath(ovalIn: full.insetBy(dx: 17, dy: 17)).fill()
        }
    }

    /// Full-width low hurdle: an amber bar with white chevrons pointing
    /// up — "hop me". Low enough to jump, wide enough that you must.
    private static func hurdleTexture(length: CGFloat) -> SKTexture {
        let height: CGFloat = 22
        let size = CGSize(width: max(length, 60), height: height)
        return propTexture(named: "prop_hurdle", size: size) { _ in
            let full = CGRect(origin: .zero, size: size)
            let bar = UIBezierPath(roundedRect: full.insetBy(dx: 1, dy: 1),
                                   cornerRadius: 8)
            UIColor(red: 0.95, green: 0.68, blue: 0.20, alpha: 1).setFill()
            bar.fill()
            UIColor(red: 0.72, green: 0.48, blue: 0.10, alpha: 1).setStroke()
            bar.lineWidth = 3
            bar.stroke()
            // Upward chevrons along the bar.
            UIColor(white: 1, alpha: 0.9).setFill()
            var x: CGFloat = 16
            while x < size.width - 16 {
                let chevron = UIBezierPath()
                chevron.move(to: CGPoint(x: x - 6, y: height - 7))
                chevron.addLine(to: CGPoint(x: x, y: 6))
                chevron.addLine(to: CGPoint(x: x + 6, y: height - 7))
                chevron.addLine(to: CGPoint(x: x, y: height - 12))
                chevron.close()
                chevron.fill()
                x += 42
            }
        }
    }

    /// Tall obstacle: a charcoal wall with hazard notches at both ends —
    /// visually heavier than the low shapes, since it can't be jumped.
    private static func fenceTexture(length: CGFloat) -> SKTexture {
        let height: CGFloat = 26
        let size = CGSize(width: max(length, 60), height: height)
        return propTexture(named: "prop_fence", size: size) { _ in
            let full = CGRect(origin: .zero, size: size)
            let wall = UIBezierPath(roundedRect: full.insetBy(dx: 1, dy: 1),
                                    cornerRadius: 6)
            UIColor(red: 0.22, green: 0.24, blue: 0.28, alpha: 1).setFill()
            wall.fill()
            UIColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1).setStroke()
            wall.lineWidth = 3
            wall.stroke()
            // Diagonal notches so the wall reads as "solid, keep out".
            UIColor(red: 0.95, green: 0.75, blue: 0.25, alpha: 0.9).setFill()
            var x: CGFloat = 8
            while x < size.width - 14 {
                let stripe = UIBezierPath()
                stripe.move(to: CGPoint(x: x, y: 6))
                stripe.addLine(to: CGPoint(x: x + 7, y: 6))
                stripe.addLine(to: CGPoint(x: x + 13, y: height - 6))
                stripe.addLine(to: CGPoint(x: x + 6, y: height - 6))
                stripe.close()
                stripe.fill()
                x += 34
            }
        }
    }
}

// MARK: - UWB placement sensing (Nearby Interaction)

/// Measures the real physical arrangement of the two phones with the UWB
/// chip: distance in meters plus — while the peer sits inside the antenna's
/// field of view (a cone around the rear camera's axis) — a direction
/// vector in device coordinates (+x right, +y top of phone, +z out of the
/// screen). Discovery tokens travel over the existing Multipeer link.
final class NearbyPlacementManager: NSObject, NISessionDelegate {
    private var session: NISession?
    /// Kept so ranging can restart after timeouts and suspensions.
    private var peerToken: NIDiscoveryToken?
    /// False after stop(); blocks delegate-driven resurrection.
    private var shouldRun = false

    private(set) var distance: Float?
    private(set) var direction: simd_float3?

    /// Ships a freshly minted local discovery token to the peer.
    var onTokenReady: ((Data) -> Void)?

    static var isSupported: Bool {
        NISession.deviceCapabilities.supportsPreciseDistanceMeasurement
    }

    /// Create the session and publish our token. Safe to call repeatedly.
    func prepare() {
        guard NearbyPlacementManager.isSupported, session == nil else { return }
        shouldRun = true
        let session = NISession()
        session.delegate = self
        self.session = session
        if let token = session.discoveryToken,
           let data = try? NSKeyedArchiver.archivedData(withRootObject: token,
                                                        requiringSecureCoding: true) {
            onTokenReady?(data)
        }
    }

    /// The peer's token arrived: start (or restart) ranging against it.
    func receivePeerToken(_ data: Data) {
        prepare() // in case the token beat our own connection bookkeeping
        guard let session,
              let token = try? NSKeyedUnarchiver.unarchivedObject(
                ofClass: NIDiscoveryToken.self, from: data) else { return }
        peerToken = token
        session.run(NINearbyPeerConfiguration(peerToken: token))
    }

    func stop() {
        shouldRun = false
        session?.invalidate()
        session = nil
        peerToken = nil
        distance = nil
        direction = nil
    }

    // MARK: NISessionDelegate (delivered on the main queue)

    func session(_ session: NISession, didUpdate nearbyObjects: [NINearbyObject]) {
        guard let object = nearbyObjects.first else { return }
        if let measured = object.distance { distance = measured }
        direction = object.direction // nil while out of the antenna's FoV
    }

    func session(_ session: NISession, didRemove nearbyObjects: [NINearbyObject],
                 reason: NINearbyObject.RemovalReason) {
        distance = nil
        direction = nil
        // Peer timed out (screen off, out of range): keep listening.
        if shouldRun, let peerToken {
            session.run(NINearbyPeerConfiguration(peerToken: peerToken))
        }
    }

    func sessionSuspensionEnded(_ session: NISession) {
        if shouldRun, let peerToken {
            session.run(NINearbyPeerConfiguration(peerToken: peerToken))
        }
    }

    func session(_ session: NISession, didInvalidateWith error: Error) {
        self.session = nil
        distance = nil
        direction = nil
        guard shouldRun else { return }
        // Tokens die with their session: mint a new one, resend it, and
        // resume against the peer's (still valid) token.
        prepare()
        if let peerToken {
            self.session?.run(NINearbyPeerConfiguration(peerToken: peerToken))
        }
    }
}

// MARK: - Phone-to-phone ball transfer (Milestones 3 & 4)

/// Everything that can travel between the two phones.
enum PeerMessage: Codable {
    /// The ball rolled off a side edge onto the neighboring phone.
    case sideTransfer(BallTransfer)
    /// The ball fell through a hole toward the phone held underneath.
    case drop(BallDrop)
    /// Whether the phone underneath caught the dropped ball.
    case dropResult(caught: Bool)
    /// An NIDiscoveryToken (archived) so the two phones can range each
    /// other over UWB and learn their physical arrangement.
    case uwbToken(Data)
    /// Co-op: the phone holding the ball streams its camera height (as an
    /// offset from the run start), the ball's vertical speed (so the
    /// watching screen can predict between packets), and the shared score.
    case coopSync(heightOffset: Double, heightVelocity: Double, scoreMeters: Int)
    /// Co-op: the shared run ended on the sender's screen.
    case runOver(scoreMeters: Int)
    /// Co-op/versus: this player pressed READY / TRY AGAIN. The round
    /// (re)starts once both phones have sent one.
    case readyToStart
    /// Versus: the ball slipped through a wall gap onto the opponent's
    /// screen.
    case versusTransfer(VersusTransfer)
    /// Versus: the sender's 60-second clock ran out; here is how long they
    /// held the ball. Each phone compares the two numbers to pick a winner.
    case versusResult(holdSeconds: Double)
    /// Co-op, casual holes: the ball fell into a floor hole and warps to
    /// the other phone — no physical stacking required, it always lands.
    case coopWarp(BallDrop)
    /// Versus: the ball fell into a floor hole and pops out of the same
    /// spot on the opponent's court.
    case versusHoleDrop(BallDrop)
}

/// Everything the ball carries when it escapes to the opponent's screen.
struct VersusTransfer: Codable {
    /// The edge it left through: 0 left, 1 right, 2 top, 3 bottom. It
    /// enters the opponent's screen on the mirrored edge.
    let edge: Int
    /// Position along that edge (0...1).
    let fraction: Double
    let velocityDX: Double
    let velocityDY: Double
    let colorIndex: Int
    let patternIndex: Int
    let skinPNG: Data?
}

/// Everything the ball carries when it rolls to the neighboring phone.
struct BallTransfer: Codable {
    /// Height at the moment of exit, as a point offset from the sender's
    /// screen center — phones sitting side by side share the same physical
    /// height, whatever their screens or scroll positions.
    let yOffsetPoints: Double
    let velocityDX: Double
    let velocityDY: Double
    /// True if it left through the right edge (so it enters on the left).
    let exitedRightEdge: Bool
    let colorIndex: Int
    let patternIndex: Int
    let skinPNG: Data?
}

/// Everything the ball carries when it falls through a hole toward the
/// phone held underneath.
struct BallDrop: Codable {
    /// Where the hole sat on the sender's screen, as an offset in points
    /// from the screen center. Points are close to the same physical size
    /// on every iPhone, so with the two phones stacked center-on-center
    /// the ball lands at (nearly) the same real-world spot — unlike screen
    /// fractions, which drift when the screens are different sizes.
    let xOffsetPoints: Double
    let yOffsetPoints: Double
    /// The roll it fell in with; the landing keeps this momentum so the
    /// ball feels like it passed straight through the hole.
    let velocityDX: Double
    let velocityDY: Double
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
    private var isRunning = false
    /// Deterministic role split without negotiation: the lexicographically
    /// smaller display name plays course A, the other course B. (The same
    /// comparison already decides who sends the connection invitation.)
    var isPrimary: Bool {
        guard let peer = connectedPeerName else { return true }
        return peerID.displayName < peer
    }
    /// Called on the main thread when a message arrives from the peer.
    var onMessage: ((PeerMessage) -> Void)?

    func start() {
        guard !isRunning else { return }
        isRunning = true
        advertiser.delegate = self
        browser.delegate = self
        advertiser.startAdvertisingPeer()
        browser.startBrowsingForPeers()
    }

    /// Stop looking for peers and drop any live connection (solo play).
    func stop() {
        guard isRunning else { return }
        isRunning = false
        advertiser.stopAdvertisingPeer()
        browser.stopBrowsingForPeers()
        session.disconnect()
        isConnected = false
        connectedPeerName = nil
    }

    func send(_ message: PeerMessage, reliable: Bool = true) {
        guard !session.connectedPeers.isEmpty,
              let data = try? JSONEncoder().encode(message) else { return }
        // High-rate streams (camera sync) go unreliable: a lost frame is
        // replaced by the next one 100 ms later anyway.
        try? session.send(data, toPeers: session.connectedPeers,
                          with: reliable ? .reliable : .unreliable)
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
        guard let message = try? JSONDecoder().decode(PeerMessage.self,
                                                      from: data) else { return }
        DispatchQueue.main.async {
            self.onMessage?(message)
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
                 fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
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
