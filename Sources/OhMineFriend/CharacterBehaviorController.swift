import AppKit
import CoreGraphics
import SceneKit

public enum BehaviorMode: String, CaseIterable {
    case autonomous = "자유 배회 (Autonomous)"
    case followCursor = "커서 따라가기 (Follow Cursor)"
    case chill = "멍때리기 (Stay & Chill)"
}

public final class CharacterBehaviorController {
    public enum State {
        case idle(timeLeft: TimeInterval)
        case lookAround(timeLeft: TimeInterval, targetYaw: CGFloat)
        case walk(direction: CGFloat, targetX: CGFloat, duration: TimeInterval, lastX: CGFloat, stuckTime: TimeInterval)
        case sit(timeLeft: TimeInterval)
        case poke(timeLeft: TimeInterval, label: String)
        case wave(timeLeft: TimeInterval)
        case sneakDance(repsLeft: Int, isDown: Bool, timer: TimeInterval)
        case placeAndMineBlock(timeLeft: TimeInterval, isMining: Bool)
        case eating(timeLeft: TimeInterval)
        case sleep(duration: TimeInterval, zzzTimer: TimeInterval)
        case backflip(progress: CGFloat)
        case tnt(timer: TimeInterval)
        case climb(phaseTimer: TimeInterval, isPlacing: Bool, isUp: Bool)
        case fall
        case dragged
        case landedCrouch(timeLeft: TimeInterval)
        case cheer(wpm: Double, timeLeft: TimeInterval, cheerCooldown: TimeInterval)
        case nag(timeLeft: TimeInterval, phraseTimer: TimeInterval, phraseIndex: Int)
        case squash(timeLeft: TimeInterval, windowPlatform: Platform)
        case fishing(timeLeft: TimeInterval, biteTime: TimeInterval, hasBitten: Bool)
        case throwTrident(timeLeft: TimeInterval)
        case jukebox(timeLeft: TimeInterval, beatTimer: TimeInterval)
        case drinkMilk(timeLeft: TimeInterval)
        case charge(targetX: CGFloat, speed: CGFloat, duration: TimeInterval)
        case emote(kind: CharacterEmote, timeLeft: TimeInterval)
    }

    public private(set) var state: State = .idle(timeLeft: 2.0)
    public var mode: BehaviorMode = .autonomous

    // Tuning parameters
    public var walkSpeed: CGFloat = 85.0 // points/sec
    private var wasAirborne: Bool = false

    // System Cursor Inactivity Tracking for Sleep
    private var lastCursorPos: CGPoint = .zero
    private var userIdleTime: TimeInterval = 0
    private let idleSleepThreshold: TimeInterval = 45.0 // Sleep after 45s of no mouse movement

    // Near Cursor Proximity Tracking for Wave
    private var cursorHoverTimer: TimeInterval = 0

    // TNT bookkeeping (설치 → 점화 → 도화선 → 폭발)
    private var tntFuse: TimeInterval = 4.0
    private var tntTarget: Platform?
    private var tntCompletion: ((Platform?) -> Void)?
    private var tntPlacedCallback: ((CGPoint) -> Void)?
    private var tntPlacedFired = false
    private var tntPlacementX: CGFloat = 0
    private var tntBackstepDir: CGFloat = 1
    private let tntEquipEnd: TimeInterval = 0.45
    private let tntPlaceEnd: TimeInterval = 0.95
    private let tntBackstepEnd: TimeInterval = 1.3

    // Ladder descent bookkeeping (사다리 타고 창문 내려가기)
    /// 오버레이 렌더용 등반 스냅샷 (등반 중이 아니면 nil)
    public struct ClimbSnapshot {
        public let ladderRect: CGRect // Cocoa 좌표 기준 사다리 전체 기둥 영역
        public let progress: CGFloat  // 0...1
    }

    /// 사다리를 걸 수 있는 발판인지: 창문이고 창 높이가 충분해야 한다
    public static let minimumLadderLength: CGFloat = 180.0
    public static func canDescend(from platform: Platform) -> Bool {
        guard case .window = platform.kind, let bottom = platform.yBottom else { return false }
        return (platform.yTop - bottom) >= minimumLadderLength
    }

    public private(set) var climbSnapshot: ClimbSnapshot?
    private(set) var ladderCooldown: TimeInterval = 0
    private var climbStartY: CGFloat = 0
    private var climbEndY: CGFloat = 0
    private var climbSource: Platform?
    private var climbIsUp = false
    private let climbSpeed: CGFloat = 220.0     // points / sec
    private let ladderPlaceDuration: TimeInterval = 0.55
    private let ladderCooldownDuration: TimeInterval = 12.0
    private let ladderHalfWidth: CGFloat = 22.0

    /// 이 속도 이하로 내려놓으면 '던지기'가 아니라 '놓기'로 본다
    public static let dropSnapSpeedLimit: CGFloat = 260.0

    public init() {}

    // MARK: - Direct Triggers (Called by View, Menu or Shortcuts)
    public func triggerBackflip(physics: PhysicsEngine, characterNode: MinecraftCharacterNode) {
        guard !isClimbing, !isTNTActive else { return }
        physics.jump(impulse: 560)
        SoundAndEffectsManager.shared.play(.jump)
        characterNode.showOverheadEmoji("🤸‍♂️", duration: 1.5)
        state = .backflip(progress: 0)
    }

    public func triggerSneakDance(characterNode: MinecraftCharacterNode) {
        guard !isClimbing, !isTNTActive else { return }
        characterNode.showOverheadEmoji("🕺", duration: 2.0)
        SoundAndEffectsManager.shared.play(.pop)
        state = .sneakDance(repsLeft: 4, isDown: true, timer: 0.15)
    }

    public func triggerWave(characterNode: MinecraftCharacterNode) {
        guard !isClimbing, !isTNTActive, !isEmoting else { return }
        characterNode.showOverheadEmoji("👋", duration: 2.0)
        SoundAndEffectsManager.shared.play(.heart)
        state = .wave(timeLeft: 2.5)
    }

    public func triggerSleep(characterNode: MinecraftCharacterNode) {
        guard !isClimbing, !isTNTActive else { return }
        characterNode.isSleeping = true
        characterNode.bedNode.isHidden = false
        characterNode.showOverheadEmoji("💤", duration: 2.5)
        SoundAndEffectsManager.shared.play(.pop)
        state = .sleep(duration: 35.0, zzzTimer: 1.2)
    }

    public func triggerEating(characterNode: MinecraftCharacterNode) {
        guard !isClimbing, !isTNTActive else { return }
        characterNode.showOverheadEmoji("🍎", duration: 2.5)
        state = .eating(timeLeft: 2.8)
    }

    public func triggerPlaceAndMine(characterNode: MinecraftCharacterNode) {
        guard !isClimbing, !isTNTActive else { return }
        AdvancementManager.shared.unlock(.firstMine)
        characterNode.showOverheadEmoji("⛏️", duration: 2.5)
        characterNode.placedBlockNode.isHidden = false
        SoundAndEffectsManager.shared.play(.pop)
        state = .placeAndMineBlock(timeLeft: 3.0, isMining: false)
    }


    public func triggerSitOnMenuBar(physics: PhysicsEngine, characterNode: MinecraftCharacterNode) {
        guard !isClimbing, !isTNTActive else { return }
        let screen = ScreenEnvironment.shared.screen(for: physics.position)
        let menuBarY = screen.visibleFrame.maxY
        physics.position = CGPoint(x: physics.position.x, y: menuBarY)
        let menuBarPlatform = Platform(
            kind: .menuBar,
            xMin: screen.frame.minX,
            xMax: screen.frame.maxX,
            yTop: menuBarY,
            title: "메뉴바",
            yBottom: menuBarY - 24
        )
        physics.landOn(platform: menuBarPlatform)
        characterNode.showOverheadEmoji("🪑", duration: 2.0)
        SoundAndEffectsManager.shared.play(.pop)
        state = .sit(timeLeft: Double.random(in: 6.0...12.0))
    }

    public func triggerFishing(characterNode: MinecraftCharacterNode) {
        guard !isClimbing, !isTNTActive else { return }
        characterNode.currentHeldItem = .fishingRod
        characterNode.isFishing = true
        characterNode.isSitting = true
        characterNode.showOverheadEmoji("🎣 낚싯대 투척!", duration: 1.8)
        SoundAndEffectsManager.shared.play(.pop)
        state = .fishing(timeLeft: 4.5, biteTime: 1.8, hasBitten: false)
    }

    public func triggerCheer(characterNode: MinecraftCharacterNode) {
        guard !isClimbing, !isTNTActive else { return }
        characterNode.isCheering = true
        characterNode.showOverheadEmoji("🎉", duration: 2.0)
        SoundAndEffectsManager.shared.play(.heart)
        TypingActivityMonitor.shared.simulateKeystrokes(count: 15)
        state = .cheer(wpm: 65.0, timeLeft: 3.5, cheerCooldown: 1.0)
    }

    public func triggerNag(characterNode: MinecraftCharacterNode) {
        guard !isClimbing, !isTNTActive else { return }
        NotificationCenterMonitor.shared.triggerSimulatedNag()
        characterNode.isNagging = true
        SoundAndEffectsManager.shared.play(.alert)
        let phrases = [
            "알림 좀 확인해! 💢",
            "알림 쌓인 것 좀 봐... 📢",
            "안 읽을 거면 지우기라도 해! 🧹",
            "완전 읽씹 장인이네! 😤",
            "언제 읽을 거야?! 🔔"
        ]
        characterNode.showOverheadEmoji(phrases[0], duration: 2.0)
        state = .nag(timeLeft: 6.0, phraseTimer: 2.0, phraseIndex: 1)
    }
    public func handleCharacterClicked(physics: PhysicsEngine, characterNode: MinecraftCharacterNode) {
        SoundAndEffectsManager.shared.play(.heart)
        characterNode.showOverheadEmoji("❤️", duration: 1.8)

        if isClimbing {
            // 등반 중 클릭 → 사다리에서 손을 놓고 떨어진다
            releaseFromLadder(physics: physics, characterNode: characterNode)
        } else if case .sleep = state {
            // Wake up if sleeping
            wakeUp(characterNode: characterNode)
        } else {
            // Little playful hop
            triggerSneakDance(characterNode: characterNode)
        }
    }

    private func wakeUp(characterNode: MinecraftCharacterNode) {
        characterNode.isSleeping = false
        characterNode.bedNode.isHidden = true
        characterNode.showOverheadEmoji("❗", duration: 1.5)
        SoundAndEffectsManager.shared.play(.alert)
        state = .idle(timeLeft: 1.5)
    }

    public func wakeUpIfSleeping(characterNode: MinecraftCharacterNode, withEmoji emoji: String = "❗") {
        if case .sleep = state {
            characterNode.isSleeping = false
            characterNode.bedNode.isHidden = true
            characterNode.showOverheadEmoji(emoji, duration: 2.2)
            SoundAndEffectsManager.shared.play(.alert)
            state = .idle(timeLeft: 1.5)
        }
    }

    // MARK: - Window Squash & Minimize (창 압축 최소화)
    public func triggerThrowTrident(characterNode: MinecraftCharacterNode, isRiptide: Bool) {
        guard !isClimbing, !isTNTActive else { return }
        characterNode.currentHeldItem = .trident
        characterNode.showOverheadEmoji(isRiptide ? "🌊 급류 돌진-!" : "🔱 충성 삼지창! 돌아와-!", duration: 2.0)
        SoundAndEffectsManager.shared.play(.whoosh)
        state = .throwTrident(timeLeft: 1.6)
    }

    public func triggerJukeboxDance(characterNode: MinecraftCharacterNode) {
        guard !isClimbing, !isTNTActive else { return }
        characterNode.showOverheadEmoji("🎶 리듬 타는 중~", duration: 2.0)
        state = .jukebox(timeLeft: 8.0, beatTimer: 0.0)
    }

    public func triggerDrinkMilk(characterNode: MinecraftCharacterNode) {
        guard !isClimbing, !isTNTActive else { return }
        characterNode.currentHeldItem = .milkBucket
        characterNode.showOverheadEmoji("🥛 꿀꺽꿀꺽...", duration: 1.6)
        SoundAndEffectsManager.shared.play(.gulp)
        state = .drinkMilk(timeLeft: 1.8)
    }
    public func startSquashMinimize(
        on platform: Platform,
        duration: TimeInterval = 2.0,
        characterNode: MinecraftCharacterNode
    ) {
        guard !isClimbing, !isTNTActive else { return }
        characterNode.isPressingDown = true
        characterNode.showOverheadEmoji("🗜️ 압축 중...!", duration: duration)
        SoundAndEffectsManager.shared.play(.ignite)
        state = .squash(timeLeft: duration, windowPlatform: platform)
    }

    // MARK: - TNT (앱 창 폭파)
    public var isTNTActive: Bool {
        if case .tnt = state { return true }
        return false
    }

    // MARK: - 감정 표현 (Emote)
    /// 감정 표현 진행 중인지 (자세 감시·암시적 트리거 가드용)
    public var isEmoting: Bool {
        if case .emote = state { return true }
        return false
    }

    /// 장식 모션(감정 표현) 실행. 등반·TNT 중에는 무시된다.
    @discardableResult
    public func triggerEmote(_ kind: CharacterEmote, characterNode: MinecraftCharacterNode) -> Bool {
        guard !isClimbing, !isTNTActive else { return false }
        characterNode.emote = kind
        characterNode.showOverheadEmoji(kind.emoji, duration: min(kind.duration, 2.2))
        SoundAndEffectsManager.shared.play(kind.sound)
        state = .emote(kind: kind, timeLeft: kind.duration)
        return true
    }

    /// 도화선 진행 0...1 (점화 시점부터 폭발까지), TNT 연출 중이 아니면 nil
    public var tntProgress: CGFloat? {
        guard case let .tnt(timer) = state, tntFuse > 0 else { return nil }
        let fuseElapsed = timer - tntPlaceEnd
        return min(1, max(0, CGFloat(fuseElapsed / tntFuse)))
    }

    /// 폭발까지 남은 시간(초), TNT 연출 중이 아니면 nil
    public var tntFuseRemaining: TimeInterval? {
        guard case let .tnt(timer) = state, tntFuse > 0 else { return nil }
        return max(0, tntPlaceEnd + tntFuse - timer)
    }

    /// TNT를 내려놓고 점화한다.
    /// `onPlaced`는 TNT가 창 표면에 놓이는 순간(화면 좌표), `completion`은 폭발(대상 플랫폼) 또는 중단(nil) 시점에 한 번 호출된다.
    @discardableResult
    public func startTNTPlacement(
        on platform: Platform,
        fuse: TimeInterval = 4.0,
        onPlaced: @escaping (CGPoint) -> Void,
        completion: @escaping (Platform?) -> Void
    ) -> Bool {
        guard !isTNTActive, !isClimbing else { return false }
        tntFuse = fuse
        tntTarget = platform
        tntCompletion = completion
        tntPlacedCallback = onPlaced
        tntPlacedFired = false
        tntPlacementX = 0
        tntBackstepDir = 1
        state = .tnt(timer: 0)
        return true
    }

    // MARK: - Ladder Climb (사다리 타고 창문 오르내리기)
    public var isClimbing: Bool {
        if case .climb = state { return true }
        return false
    }

    /// 창문 발판에 사다리를 걸고 창 아래 끝까지 내려간다. 시작할 수 없으면 false.
    @discardableResult
    public func startLadderDescent(
        physics: PhysicsEngine,
        characterNode: MinecraftCharacterNode,
        from platform: Platform
    ) -> Bool {
        guard !isClimbing, !isTNTActive, physics.currentPlatform != nil,
              let bottom = platform.yBottom, Self.canDescend(from: platform)
        else { return false }

        beginLadderClimb(
            physics: physics,
            characterNode: characterNode,
            source: platform,
            startY: physics.position.y,
            endY: bottom,
            isUp: false
        )
        return true
    }

    /// 드래그로 창문 안에 내려놓았을 때: **놓인 자리에서 그 창문 위쪽 끝까지** 사다리를 걸고 올라간다.
    /// - Returns: 놓인 자리에 창문이 없으면 false (기존 던지기/낙하 동작 유지)
    @discardableResult
    public func climbUpFromDrop(
        physics: PhysicsEngine,
        characterNode: MinecraftCharacterNode,
        platforms: [Platform]
    ) -> Bool {
        guard !isClimbing, !isTNTActive else { return false }

        let point = physics.position

        // 1. 메뉴바 바로 위/근처에 놓인 경우: 메뉴바 위에 즉시 착지하여 걸터앉기
        if let menuBar = platforms.first(where: { $0.kind == .menuBar }) {
            if abs(point.y - menuBar.yTop) <= 25 {
                physics.landOn(platform: menuBar)
                characterNode.showOverheadEmoji("🪑", duration: 1.8)
                SoundAndEffectsManager.shared.play(.pop)
                state = .sit(timeLeft: Double.random(in: 6.0...12.0))
                return true
            } else if point.y >= (menuBar.yTop - 140) && point.y < menuBar.yTop {
                // 메뉴바 바로 아래 구간: 메뉴바까지 사다리를 타고 올라간다
                beginLadderClimb(
                    physics: physics,
                    characterNode: characterNode,
                    source: menuBar,
                    startY: physics.position.y,
                    endY: menuBar.yTop,
                    isUp: true
                )
                return true
            }
        }

        // 놓은 지점을 담고 있는 창문 중 가장 앞에 있는(가장 위에 떠 있는) 창문을 고른다
        guard let window = platforms.first(where: { platform in
            guard case .window = platform.kind, let bottom = platform.yBottom else { return false }
            return point.x >= platform.xMin && point.x <= platform.xMax
                && point.y >= bottom && point.y < platform.yTop
        }) else { return false }

        beginLadderClimb(
            physics: physics,
            characterNode: characterNode,
            source: window,
            startY: physics.position.y,
            endY: window.yTop,
            isUp: true
        )
        return true
    }

    /// 하강/상승 공통 세팅: 등반 상태로 들어가고 사다리 설치 모션을 시작한다
    private func beginLadderClimb(
        physics: PhysicsEngine,
        characterNode: MinecraftCharacterNode,
        source: Platform,
        startY: CGFloat,
        endY: CGFloat,
        isUp: Bool
    ) {
        climbStartY = startY
        climbEndY = endY
        climbSource = source
        climbIsUp = isUp
        climbSnapshot = nil
        ladderCooldown = ladderCooldownDuration
        // 드래그로 공중에 떠 있던 상태에서 바로 등반으로 넘어오므로, 착지 판정이
        // 등반 상태를 landedCrouch로 덮어쓰지 않도록 낙하 플래그를 내린다.
        wasAirborne = false

        physics.beginClimb()
        SoundAndEffectsManager.shared.play(.pop)
        characterNode.showOverheadEmoji("🪜", duration: 1.6)
        characterNode.climbUp = isUp
        state = .climb(phaseTimer: ladderPlaceDuration, isPlacing: true, isUp: isUp)
    }

    /// 등반 중단 (드래그/낙하로 상태가 덮어써질 때)
    private func cancelClimbIfActive() {
        guard isClimbing else { return }
        climbSnapshot = nil
        climbSource = nil
    }

    /// 사다리에서 손을 놓고 그대로 낙하 (클릭 / 사다리 끝 도달 / 창이 닫힘)
    private func releaseFromLadder(physics: PhysicsEngine, characterNode: MinecraftCharacterNode) {
        guard isClimbing else { return }
        cancelClimbIfActive()
        characterNode.isClimbing = false
        characterNode.climbProgress = 0
        physics.releaseClimb()
        state = .fall
    }

    /// 창문 위쪽 끝까지 올라왔다: 창문 위(타이틀바)에 올라선다
    private func finishClimbUp(on platform: Platform, physics: PhysicsEngine, characterNode: MinecraftCharacterNode) {
        climbSnapshot = nil
        climbSource = nil
        characterNode.isClimbing = false
        characterNode.climbProgress = 1
        physics.endClimb(on: platform)
        SoundAndEffectsManager.shared.play(.land)
        state = .idle(timeLeft: 1.2)
    }

    private func makeClimbSnapshot(physics: PhysicsEngine) -> ClimbSnapshot {
        let total = max(1, abs(climbEndY - climbStartY))
        let progressed = climbIsUp ? (physics.position.y - climbStartY) : (climbStartY - physics.position.y)
        let progress = min(1, max(0, progressed / total))

        // 사다리는 창문 면을 따라 생성된다: 내려갈 때는 창 하단까지, 올라갈 때는 놓인 자리부터 창 상단까지
        let bottom = climbIsUp ? climbStartY - 12 : climbEndY
        let top = climbIsUp ? climbEndY + 4 : climbStartY + 4
        let rect = CGRect(
            x: physics.position.x - ladderHalfWidth,
            y: bottom,
            width: ladderHalfWidth * 2,
            height: max(1, top - bottom)
        )
        return ClimbSnapshot(ladderRect: rect, progress: progress)
    }

    // MARK: - Main Update Loop
    public func update(
        deltaTime dt: TimeInterval,
        physics: PhysicsEngine,
        characterNode: MinecraftCharacterNode,
        platforms: [Platform],
        screen: NSScreen,
        cursorPos: CGPoint
    ) {
        let charPos = physics.position
        let currentPlatform = physics.currentPlatform

        ladderCooldown = max(0, ladderCooldown - dt)

        // 1. Mouse Activity & Proximity Tracking
        let cursorDelta = hypot(cursorPos.x - lastCursorPos.x, cursorPos.y - lastCursorPos.y)
        if cursorDelta > 2.0 {
            userIdleTime = 0
            // If sleeping and user moves mouse significantly, wake up!
            if case .sleep = state {
                wakeUp(characterNode: characterNode)
            }
        } else if TypingActivityMonitor.shared.currentWPM >= TypingActivityMonitor.cheerThreshold {
            // 타이핑 중이면 유휴로 보지 않는다: 키보드로 열심히 코딩하는데
            // 마우스가 가만하다고 45초마다 낮잠에 빠지면 응원이 끊긴다.
            userIdleTime = 0
        } else {
            userIdleTime += dt
        }
        lastCursorPos = cursorPos

        // Automatic Nap after long inactivity
        if userIdleTime >= idleSleepThreshold {
            if case .sleep = state {
                // already sleeping
            } else if case .onGround = physics.state {
                triggerSleep(characterNode: characterNode)
                userIdleTime = 0
            }
        }

        // Proximity detection for greeting wave (within 45pt of head)
        let headScreenPos = CGPoint(x: charPos.x, y: charPos.y + 65)
        let distToHead = hypot(cursorPos.x - headScreenPos.x, cursorPos.y - headScreenPos.y)
        if distToHead < 48.0 && !characterNode.isSleeping && !characterNode.isBeingDragged && !isClimbing {
            cursorHoverTimer += dt
            if cursorHoverTimer > 0.6 {
                cursorHoverTimer = 0
                if case .wave = state {} else {
                    triggerWave(characterNode: characterNode)
                }
            }
        } else {
            cursorHoverTimer = 0
        }

        // 2. Head Orientation
        updateHeadLookAt(
            charPos: charPos,
            cursorPos: cursorPos,
            characterNode: characterNode
        )

        // 3. Physics Overrides (Dragged / Airborne)
        if case .dragged = physics.state {
            interruptTNTIfActive()
            cancelClimbIfActive()
            characterNode.emote = nil
            state = .dragged
            characterNode.isBeingDragged = true
            characterNode.isClimbing = false
            characterNode.isFalling = false
            characterNode.isSitting = false
            characterNode.isPoking = false
            characterNode.isWaving = false
            characterNode.isSneaking = false
            characterNode.isSleeping = false
            characterNode.isBackflipping = false
            characterNode.isEating = false
            characterNode.placedBlockNode.isHidden = true
            characterNode.isHoldingTNT = false
            characterNode.isPlacingTNT = false
            characterNode.walkSpeed = 0
            wasAirborne = true
            characterNode.isGliding = false
            physics.isGliding = false
            return
        }

        if case .airborne = physics.state {
            interruptTNTIfActive()
            cancelClimbIfActive()
            characterNode.emote = nil

            // 겉날개 활공: 겉날개 착용 중이고 낙하 중이면 활공 모드 돌입!
            if characterNode.isElytraEquipped && physics.velocity.y < -80 {
                characterNode.isGliding = true
                physics.isGliding = true
            }

            if case .backflip(var progress) = state {
                // Keep backflip rotating
                progress += CGFloat(dt) * 4.2
                characterNode.backflipAngle = -progress * CGFloat.pi * 2.0
                characterNode.isBackflipping = true
                characterNode.isFalling = false
                state = .backflip(progress: progress)
                wasAirborne = true
                return
            }
            state = .fall
            characterNode.isBeingDragged = false
            characterNode.isClimbing = false
            characterNode.isFalling = true
            characterNode.isSitting = false
            characterNode.isPoking = false
            characterNode.isWaving = false
            characterNode.isSneaking = false
            characterNode.isSleeping = false
            characterNode.isBackflipping = false
            characterNode.isEating = false
            characterNode.placedBlockNode.isHidden = true
            characterNode.isHoldingTNT = false
            characterNode.isPlacingTNT = false
            characterNode.walkSpeed = 0
            wasAirborne = true
            return
        }

        // Just landed!
        if wasAirborne {
            characterNode.isGliding = false
            physics.isGliding = false
            wasAirborne = false
            state = .landedCrouch(timeLeft: 0.35)
            characterNode.isFalling = false
            characterNode.isBackflipping = false
            characterNode.isHoldingTNT = false
            characterNode.isPlacingTNT = false
            characterNode.walkSpeed = 0
            SoundAndEffectsManager.shared.play(.land)
        }

        // 4. Reset general flags
        characterNode.isBeingDragged = false
        characterNode.isClimbing = false
        characterNode.isFalling = false
        characterNode.isHoldingTNT = false
        characterNode.isPlacingTNT = false


        // 4.5. Typing WPM Check & Cheering Mode
        // 잠들어 있을 때 타이핑이 감지되면 깨우고 응원으로 이어진다.
        // 낮잠이 45초 무입력 타이머 기반이라, 타이핑 중인데 낮잠에 빠지면
        // 마우스 움직임 없이는 영영 못 깨어나 응원 조건식에도 못 닿는다.
        let currentWpm = TypingActivityMonitor.shared.currentWPM
        if currentWpm >= TypingActivityMonitor.cheerThreshold && !isClimbing && !isTNTActive {
            wakeUpIfSleeping(characterNode: characterNode, withEmoji: "🎉 코딩 중이네!")
        }
        let wokeWpm = TypingActivityMonitor.shared.currentWPM
        if wokeWpm >= TypingActivityMonitor.cheerThreshold && !isClimbing && !isTNTActive {
            switch state {
            case .idle, .walk, .sit, .lookAround, .wave:
                characterNode.isCheering = true
                characterNode.showOverheadEmoji("🔥", duration: 1.5)
                SoundAndEffectsManager.shared.play(.heart)
                state = .cheer(wpm: wokeWpm, timeLeft: 2.2, cheerCooldown: 0)
            case .cheer(_, _, var cooldown):
                characterNode.isCheering = true
                cooldown -= dt
                if cooldown <= 0 {
                    cooldown = 1.1
                    let cheerEmojis = ["🔥", "⚡", "👏", "🎉", "💯"]
                    characterNode.showOverheadEmoji(cheerEmojis.randomElement() ?? "🔥", duration: 1.2)
                }
                state = .cheer(wpm: wokeWpm, timeLeft: 2.2, cheerCooldown: cooldown)
            default:
                break
            }
        }

        // 4.6. Notification Nag Check
        let nagStatus = NotificationCenterMonitor.shared.checkNagStatus(screen: screen)
        if nagStatus.shouldNag && !isClimbing && !isTNTActive {
            switch state {
            case .idle, .walk, .sit, .lookAround:
                characterNode.isNagging = true
                SoundAndEffectsManager.shared.play(.alert)
                let phrases = [
                    "알림 좀 확인해! 💢",
                    "알림 쌓인 것 좀 봐... 📢",
                    "안 읽을 거면 지우기라도 해! 🧹",
                    "완전 읽씹 장인이네! 😤",
                    "언제 읽을 거야?! 🔔"
                ]
                characterNode.showOverheadEmoji(phrases[0], duration: 2.0)
                state = .nag(timeLeft: 6.0, phraseTimer: 2.0, phraseIndex: 1)
            default:
                break
            }
        }
        // 5. Finite State Machine
        // TNT 진행 중 상태가 폭발/중단 콜백 없이 다른 상태로 덮어써졌는지 감시한다.
        let wasTNTActive = isTNTActive
        switch state {
        case .squash(var timeLeft, let platform):
            timeLeft -= dt
            characterNode.walkSpeed = 0
            characterNode.isPressingDown = true
            characterNode.isSitting = false
            characterNode.isSleeping = false
            characterNode.isNagging = false
            characterNode.isCheering = false
            characterNode.isWaving = false

            if timeLeft <= 0 {
                characterNode.isPressingDown = false
                physics.releaseClimb()
                state = .fall
            } else {
                state = .squash(timeLeft: timeLeft, windowPlatform: platform)
            }

        case .fishing(var timeLeft, let biteTime, var hasBitten):
            timeLeft -= dt
            characterNode.walkSpeed = 0
            characterNode.isSitting = true
            characterNode.isFishing = true
            characterNode.isPressingDown = false
            characterNode.isSleeping = false

            if !hasBitten && timeLeft <= biteTime {
                hasBitten = true
                characterNode.showOverheadEmoji("💦 퐁당! 입질 왔다!", duration: 1.5)
                SoundAndEffectsManager.shared.play(.pop)
            }

            if timeLeft <= 0 {
                characterNode.isFishing = false
                let loot = FishingLoot.roll()
                AdvancementManager.shared.unlock(.fishingLoot)
                characterNode.showOverheadEmoji("\(loot.emoji) \(loot.name)", duration: 2.8)
                SoundAndEffectsManager.shared.play(.heart)
                state = .sit(timeLeft: 4.0)
            } else {
                state = .fishing(timeLeft: timeLeft, biteTime: biteTime, hasBitten: hasBitten)
            }

        case .throwTrident(var timeLeft):
            timeLeft -= dt
            characterNode.walkSpeed = 0
            characterNode.isThrowingTrident = true
            characterNode.isAttackingWeapon = true
            if timeLeft <= 0 {
                characterNode.isThrowingTrident = false
                characterNode.isAttackingWeapon = false
                chooseNextState(physics: physics, platforms: platforms, screen: screen, cursorPos: cursorPos, characterNode: characterNode)
            } else {
                state = .throwTrident(timeLeft: timeLeft)
            }

        case .jukebox(var timeLeft, var beatTimer):
            timeLeft -= dt
            beatTimer -= dt
            characterNode.walkSpeed = 0
            characterNode.isJukeboxDancing = true
            if beatTimer <= 0 {
                beatTimer = 0.45
                SoundAndEffectsManager.shared.play(.chime)
            }
            if timeLeft <= 0 {
                characterNode.isJukeboxDancing = false
                chooseNextState(physics: physics, platforms: platforms, screen: screen, cursorPos: cursorPos, characterNode: characterNode)
            } else {
                state = .jukebox(timeLeft: timeLeft, beatTimer: beatTimer)
            }

        case .drinkMilk(var timeLeft):
            timeLeft -= dt
            characterNode.walkSpeed = 0
            characterNode.isEating = true
            if timeLeft <= 0 {
                characterNode.isEating = false
                characterNode.currentHeldItem = .emptyBucket
                characterNode.showOverheadEmoji("🥛✨ 깔끔하게 정화!", duration: 2.2)
                SoundAndEffectsManager.shared.play(.gulp)
                chooseNextState(physics: physics, platforms: platforms, screen: screen, cursorPos: cursorPos, characterNode: characterNode)
            } else {
                state = .drinkMilk(timeLeft: timeLeft)
            }

        case .emote(let kind, var timeLeft):
            timeLeft -= dt
            characterNode.walkSpeed = 0
            characterNode.emote = kind // 매 프레임 재지정: 같은 값이라 재생 시간은 이어진다
            characterNode.isSitting = false
            characterNode.isPoking = false
            characterNode.isWaving = false
            characterNode.isSneaking = false
            characterNode.isSleeping = false
            characterNode.isEating = false
            characterNode.isCheering = false
            characterNode.isNagging = false

            if timeLeft <= 0 {
                characterNode.emote = nil
                chooseNextState(physics: physics, platforms: platforms, screen: screen, cursorPos: cursorPos, characterNode: characterNode)
            } else {
                state = .emote(kind: kind, timeLeft: timeLeft)
            }

        case .charge(let targetX, let speed, var duration):
            characterNode.isSitting = false
            characterNode.isPoking = false
            characterNode.isWaving = false
            characterNode.isSneaking = false
            characterNode.isSleeping = false
            characterNode.isEating = false
            characterNode.walkSpeed = 1.6

            let dx = targetX - physics.position.x
            let dir: CGFloat = dx >= 0 ? 1.0 : -1.0
            let targetBodyYaw: CGFloat = dir > 0 ? (CGFloat.pi / 2.0) : (-CGFloat.pi / 2.0)
            characterNode.modelRoot.eulerAngles.y = targetBodyYaw

            let step = dir * speed * CGFloat(dt)
            physics.position.x += step
            duration -= dt

            let reached = dir > 0 ? (physics.position.x >= targetX) : (physics.position.x <= targetX)
            if reached || duration <= 0 {
                chooseNextState(physics: physics, platforms: platforms, screen: screen, cursorPos: cursorPos, characterNode: characterNode)
            } else {
                state = .charge(targetX: targetX, speed: speed, duration: duration)
            }

        case .nag(var timeLeft, var phraseTimer, var phraseIndex):
            timeLeft -= dt
            phraseTimer -= dt
            characterNode.walkSpeed = 0
            characterNode.isNagging = true
            characterNode.isCheering = false
            characterNode.isSitting = false
            characterNode.isSleeping = false
            characterNode.isWaving = false
            characterNode.isEating = false
            characterNode.isPoking = false

            if phraseTimer <= 0 {
                phraseTimer = 2.0
                let phrases = [
                    "알림 좀 확인해! 💢",
                    "알림 쌓인 것 좀 봐... 📢",
                    "안 읽을 거면 지우기라도 해! 🧹",
                    "완전 읽씹 장인이네! 😤",
                    "언제 읽을 거야?! 🔔"
                ]
                let text = phrases[phraseIndex % phrases.count]
                phraseIndex += 1
                characterNode.showOverheadEmoji(text, duration: 1.8)
                SoundAndEffectsManager.shared.play(.pop)
            }

            if timeLeft <= 0 {
                characterNode.isNagging = false
                NotificationCenterMonitor.shared.resetNagTrigger()
                chooseNextState(physics: physics, platforms: platforms, screen: screen, cursorPos: cursorPos, characterNode: characterNode)
            } else {
                state = .nag(timeLeft: timeLeft, phraseTimer: phraseTimer, phraseIndex: phraseIndex)
            }

        case .cheer(let currentWpm, var timeLeft, let cooldown):
            timeLeft -= dt
            characterNode.walkSpeed = 0
            characterNode.isCheering = true
            characterNode.isSitting = false
            characterNode.isSleeping = false
            characterNode.isWaving = false
            characterNode.isEating = false
            characterNode.isPoking = false

            if timeLeft <= 0 {
                characterNode.isCheering = false
                chooseNextState(physics: physics, platforms: platforms, screen: screen, cursorPos: cursorPos, characterNode: characterNode)
            } else {
                state = .cheer(wpm: currentWpm, timeLeft: timeLeft, cheerCooldown: cooldown)
            }

        case .landedCrouch(var timeLeft):
            timeLeft -= dt
            characterNode.walkSpeed = 0
            characterNode.isSitting = true
            characterNode.isPoking = false
            characterNode.isWaving = false
            characterNode.isSneaking = false
            characterNode.isSleeping = false
            characterNode.isEating = false
            if timeLeft <= 0 {
                characterNode.isSitting = false
                chooseNextState(physics: physics, platforms: platforms, screen: screen, cursorPos: cursorPos, characterNode: characterNode)
            } else {
                state = .landedCrouch(timeLeft: timeLeft)
            }

        case .idle(var timeLeft):
            timeLeft -= dt
            characterNode.walkSpeed = 0
            characterNode.isSitting = false
            characterNode.isPoking = false
            characterNode.isWaving = false
            characterNode.isSneaking = false
            characterNode.isSleeping = false
            characterNode.isEating = false

            if timeLeft <= 0 {
                chooseNextState(physics: physics, platforms: platforms, screen: screen, cursorPos: cursorPos, characterNode: characterNode)
            } else {
                state = .idle(timeLeft: timeLeft)
            }

        case .lookAround(var timeLeft, let targetYaw):
            timeLeft -= dt
            characterNode.walkSpeed = 0
            characterNode.isSitting = false
            characterNode.isPoking = false
            characterNode.isWaving = false
            characterNode.isSneaking = false
            characterNode.isSleeping = false
            characterNode.isEating = false
            characterNode.targetHeadYaw = targetYaw

            if timeLeft <= 0 {
                chooseNextState(physics: physics, platforms: platforms, screen: screen, cursorPos: cursorPos, characterNode: characterNode)
            } else {
                state = .lookAround(timeLeft: timeLeft, targetYaw: targetYaw)
            }

        case .wave(var timeLeft):
            timeLeft -= dt
            characterNode.walkSpeed = 0
            characterNode.isWaving = true
            characterNode.isPoking = false
            characterNode.isSneaking = false

            if timeLeft <= 0 {
                characterNode.isWaving = false
                chooseNextState(physics: physics, platforms: platforms, screen: screen, cursorPos: cursorPos, characterNode: characterNode)
            } else {
                state = .wave(timeLeft: timeLeft)
            }

        case .sneakDance(var repsLeft, var isDown, var timer):
            timer -= dt
            characterNode.walkSpeed = 0
            characterNode.isSneaking = isDown

            if timer <= 0 {
                if isDown {
                    isDown = false
                    timer = 0.15
                } else {
                    repsLeft -= 1
                    isDown = true
                    timer = 0.15
                    SoundAndEffectsManager.shared.play(.pop)
                }

                if repsLeft <= 0 {
                    characterNode.isSneaking = false
                    chooseNextState(physics: physics, platforms: platforms, screen: screen, cursorPos: cursorPos, characterNode: characterNode)
                    return
                }
            }
            state = .sneakDance(repsLeft: repsLeft, isDown: isDown, timer: timer)

        case .eating(var timeLeft):
            timeLeft -= dt
            characterNode.walkSpeed = 0
            characterNode.isEating = true

            if timeLeft <= 0 {
                characterNode.isEating = false
                characterNode.showOverheadEmoji("😋", duration: 1.5)
                chooseNextState(physics: physics, platforms: platforms, screen: screen, cursorPos: cursorPos, characterNode: characterNode)
            } else {
                state = .eating(timeLeft: timeLeft)
            }

        case .placeAndMineBlock(var timeLeft, var isMining):
            timeLeft -= dt
            characterNode.walkSpeed = 0
            characterNode.isPoking = isMining

            if timeLeft < 2.0 && !isMining {
                isMining = true
                SoundAndEffectsManager.shared.play(.pop)
            }

            if timeLeft <= 0 {
                characterNode.placedBlockNode.isHidden = true
                characterNode.isPoking = false
                SoundAndEffectsManager.shared.play(.pop)
                characterNode.showOverheadEmoji("✨", duration: 1.5)
                chooseNextState(physics: physics, platforms: platforms, screen: screen, cursorPos: cursorPos, characterNode: characterNode)
            } else {
                state = .placeAndMineBlock(timeLeft: timeLeft, isMining: isMining)
            }

        case .sleep(var duration, var zzzTimer):
            duration -= dt
            zzzTimer -= dt
            characterNode.walkSpeed = 0
            characterNode.isSleeping = true

            if zzzTimer <= 0 {
                zzzTimer = 2.0
                characterNode.showOverheadEmoji("💤", duration: 1.8)
            }

            if duration <= 0 {
                wakeUp(characterNode: characterNode)
            } else {
                state = .sleep(duration: duration, zzzTimer: zzzTimer)
            }

        case .backflip:
            break

        case .walk(let direction, let targetX, var duration, _, var stuckTime):
            characterNode.isSitting = false
            characterNode.isPoking = false
            characterNode.isWaving = false
            characterNode.isSneaking = false
            characterNode.isSleeping = false
            characterNode.isEating = false
            characterNode.walkSpeed = 1.0

            let targetBodyYaw: CGFloat = direction > 0 ? (CGFloat.pi / 2.0) : (-CGFloat.pi / 2.0)
            characterNode.modelRoot.eulerAngles.y = targetBodyYaw

            let prevX = physics.position.x
            let step = direction * walkSpeed * CGFloat(dt)
            physics.position.x += step

            duration += dt

            let actualMove = abs(physics.position.x - prevX)
            if actualMove < 0.2 {
                stuckTime += dt
            } else {
                stuckTime = 0
            }

            let canPassLeft = ScreenEnvironment.shared.hasAdjacentScreen(from: screen, onLeft: true, atY: physics.position.y)
            let canPassRight = ScreenEnvironment.shared.hasAdjacentScreen(from: screen, onLeft: false, atY: physics.position.y)

            let screenMinX = screen.frame.minX + 35.0
            let screenMaxX = screen.frame.maxX - 35.0
            let hitScreenLeft = (physics.position.x <= screenMinX) && (direction < 0) && !canPassLeft
            let hitScreenRight = (physics.position.x >= screenMaxX) && (direction > 0) && !canPassRight
            var hitPlatformLeft = false
            var hitPlatformRight = false
            if let p = currentPlatform {
                hitPlatformLeft = (physics.position.x <= p.xMin + 30.0) && (direction < 0)
                hitPlatformRight = (physics.position.x >= p.xMax - 30.0) && (direction > 0)
            }

            let reachedTarget = direction > 0 ? (physics.position.x >= targetX) : (physics.position.x <= targetX)
            let isStuck = stuckTime > 0.6 || duration > 6.0

            if hitScreenLeft || hitPlatformLeft {
                handleReachedEdge(
                    isLeft: true,
                    platform: currentPlatform,
                    screen: screen,
                    characterNode: characterNode,
                    physics: physics
                )
            } else if hitScreenRight || hitPlatformRight {
                handleReachedEdge(
                    isLeft: false,
                    platform: currentPlatform,
                    screen: screen,
                    characterNode: characterNode,
                    physics: physics
                )
            } else if reachedTarget || isStuck {
                chooseNextState(physics: physics, platforms: platforms, screen: screen, cursorPos: cursorPos, characterNode: characterNode)
            } else {
                state = .walk(
                    direction: direction,
                    targetX: targetX,
                    duration: duration,
                    lastX: physics.position.x,
                    stuckTime: stuckTime
                )
            }

        case .sit(var timeLeft):
            timeLeft -= dt
            characterNode.walkSpeed = 0
            characterNode.isSitting = true
            characterNode.isPoking = false
            characterNode.isSleeping = false

            characterNode.modelRoot.eulerAngles.y = 0

            if timeLeft <= 0 {
                characterNode.isSitting = false
                chooseNextState(physics: physics, platforms: platforms, screen: screen, cursorPos: cursorPos, characterNode: characterNode)
            } else {
                state = .sit(timeLeft: timeLeft)
            }

        case .poke(var timeLeft, _):
            timeLeft -= dt
            characterNode.walkSpeed = 0
            characterNode.isPoking = true

            if timeLeft <= 0 {
                characterNode.isPoking = false
                chooseNextState(physics: physics, platforms: platforms, screen: screen, cursorPos: cursorPos, characterNode: characterNode)
            } else {
                state = .poke(timeLeft: timeLeft, label: "")
            }

        case .tnt(var timer):
            timer += dt
            characterNode.walkSpeed = 0
            characterNode.isSitting = false
            characterNode.isPoking = false

            if timer < tntEquipEnd {
                // 1) TNT를 꺼내 머리 위로 치켜든다
                characterNode.isHoldingTNT = true
                characterNode.isPlacingTNT = false
            } else if timer < tntPlaceEnd {
                // 2) 앉아서 발밑(창 표면)에 내려놓는다
                characterNode.isHoldingTNT = false
                characterNode.isPlacingTNT = true
            } else {
                // 3) 점화 완료 — TNT는 화면 공간에 놓이고 캐릭터는 뒤로 물러난다
                characterNode.isHoldingTNT = false
                characterNode.isPlacingTNT = false

                if !tntPlacedFired {
                    tntPlacedFired = true
                    tntPlacementX = physics.position.x
                    if let target = tntTarget {
                        let center = (target.xMin + target.xMax) / 2
                        tntBackstepDir = center >= physics.position.x ? 1 : -1
                    }
                    tntPlacedCallback?(CGPoint(x: tntPlacementX, y: tntTarget?.yTop ?? physics.position.y))
                    SoundAndEffectsManager.shared.play(.ignite)
                }

                // 도화선이 타는 동안 살금살금 뒤로 (플랫폼 밖으로는 못 나감)
                if timer < tntBackstepEnd, let target = tntTarget {
                    let step = 130 * CGFloat(dt) * tntBackstepDir
                    physics.position.x = min(target.xMax - 14, max(target.xMin + 14, physics.position.x + step))
                }

                if timer >= tntPlaceEnd + tntFuse {
                    // 4) 폭발! 캐릭터는 폭풍에 날아가고 연출은 콜백으로 넘긴다
                    let away = -tntBackstepDir
                    physics.launch(vx: away * 380, vy: 560)
                    finishTNT(platform: tntTarget)
                    state = .fall
                    return
                }
            }
            state = .tnt(timer: timer)

        case .climb(var phaseTimer, var isPlacing, let isUp):
            characterNode.walkSpeed = 0
            characterNode.isSitting = false
            characterNode.isPoking = false
            characterNode.isWaving = false
            characterNode.isSneaking = false
            characterNode.isSleeping = false
            characterNode.isEating = false
            characterNode.isClimbing = true
            characterNode.climbUp = isUp

            // 사다리를 건 창문을 매 프레임 재조회 (창이 움직이면 사다리도 따라가고, 닫히면 낙하)
            let liveSource = climbSource.flatMap { source in
                platforms.first { $0.kind == source.kind }
            }
            if let liveSource = liveSource {
                climbEndY = isUp ? liveSource.yTop : (liveSource.yBottom ?? climbEndY)
            }

            if liveSource == nil {
                // 창문이 닫힘 → 사다리도 사라지고 그대로 떨어진다
                releaseFromLadder(physics: physics, characterNode: characterNode)
            } else if isPlacing {
                phaseTimer -= dt
                if phaseTimer <= 0 {
                    isPlacing = false
                    SoundAndEffectsManager.shared.play(.pop) // 사다리 설치 완료
                }
                state = .climb(phaseTimer: max(0, phaseTimer), isPlacing: isPlacing, isUp: isUp)
            } else if isUp {
                physics.position.y += climbSpeed * CGFloat(dt)

                if physics.position.y >= climbEndY, let target = liveSource {
                    // 창문 위쪽 끝 도달 → 창문 위에 올라선다
                    finishClimbUp(on: target, physics: physics, characterNode: characterNode)
                } else {
                    state = .climb(phaseTimer: 0, isPlacing: false, isUp: true)
                }
            } else {
                physics.position.y -= climbSpeed * CGFloat(dt)

                if physics.position.y <= climbEndY {
                    // 사다리 끝(창 아래 끝) 도달 → 남은 높이는 그냥 떨어진다
                    releaseFromLadder(physics: physics, characterNode: characterNode)
                } else {
                    state = .climb(phaseTimer: 0, isPlacing: false, isUp: false)
                }
            }

            if isClimbing {
                let snapshot = makeClimbSnapshot(physics: physics)
                climbSnapshot = snapshot
                characterNode.climbProgress = snapshot.progress
            }

        case .fall, .dragged:
            break
        }

        // TNT 연출이 콜백(폭발/중단) 없이 다른 상태로 덮어써졌다면 연출을 정리한다.
        // 이 정리 없이 상태만 바뀌면 도화선 패널이 하얗게 멈춘 채 닫히지 않고,
        // AppController.isBreakInProgress 가 계속 true 로 남아 이후 TNT 메뉴가 영영 무반응이 된다.
        if wasTNTActive && !isTNTActive && tntCompletion != nil {
            finishTNT(platform: nil)
        }

        // 감정 표현 자세도 같은 불변식을 지킨다: FSM이 .emote 를 벗어났는데 노드에 자세가 남아 있으면
        // 노드가 자세 분기에서 조기 반환해 이후의 걷기·낙하·수면이 영영 그려지지 않는다.
        if characterNode.emote != nil && !isEmoting {
            characterNode.emote = nil
        }
    }

    private func interruptTNTIfActive() {
        if case .tnt = state {
            finishTNT(platform: nil)
        }
    }

    private func finishTNT(platform: Platform?) {
        guard case .tnt = state else { return }
        state = .idle(timeLeft: 0.4)
        tntTarget = nil
        tntPlacedCallback = nil
        tntPlacedFired = false
        let completion = tntCompletion
        tntCompletion = nil
        completion?(platform)
    }

    private func chooseNextState(
        physics: PhysicsEngine,
        platforms: [Platform],
        screen: NSScreen,
        cursorPos: CGPoint,
        characterNode: MinecraftCharacterNode
    ) {
        guard let platform = physics.currentPlatform else {
            state = .idle(timeLeft: 1.5)
            return
        }

        switch mode {
        case .chill:
            state = .idle(timeLeft: Double.random(in: 3.0...6.0))
            return

        case .followCursor:
            let dist = cursorPos.x - physics.position.x
            if abs(dist) > 40 {
                let dir: CGFloat = dist > 0 ? 1.0 : -1.0
                let canPassLeft = ScreenEnvironment.shared.hasAdjacentScreen(from: screen, onLeft: true, atY: physics.position.y)
                let canPassRight = ScreenEnvironment.shared.hasAdjacentScreen(from: screen, onLeft: false, atY: physics.position.y)
                let desktopBounds = ScreenEnvironment.shared.totalDesktopBounds
                let screenMinX = canPassLeft ? (desktopBounds.minX + 35) : (screen.frame.minX + 45)
                let screenMaxX = canPassRight ? (desktopBounds.maxX - 35) : (screen.frame.maxX - 45)
                let minBound = max(platform.xMin + 35, screenMinX)
                let maxBound = min(platform.xMax - 35, screenMaxX)
                let targetX = min(maxBound, max(minBound, cursorPos.x))
                state = .walk(direction: dir, targetX: targetX, duration: 0, lastX: physics.position.x, stuckTime: 0)
            } else {
                state = .idle(timeLeft: 1.5)
            }
            return

        case .autonomous:
            break
        }

        // Autonomous Decisions (Rich Variety!)
        let roll = Double.random(in: 0...100)

        let canPassLeft = ScreenEnvironment.shared.hasAdjacentScreen(from: screen, onLeft: true, atY: physics.position.y)
        let canPassRight = ScreenEnvironment.shared.hasAdjacentScreen(from: screen, onLeft: false, atY: physics.position.y)
        var minX = max(platform.xMin + 35, screen.frame.minX + 45)
        var maxX = min(platform.xMax - 35, screen.frame.maxX - 45)
        if platform.kind == .floor || platform.kind == .dock {
            if canPassLeft { minX = screen.frame.minX - 80 }
            if canPassRight { maxX = screen.frame.maxX + 80 }
        }

        let canDescend = ladderCooldown <= 0 && Self.canDescend(from: platform)

        if canDescend && roll < 8 {
            // Ladder descent (사다리 타고 창문 내려가기)
            startLadderDescent(
                physics: physics,
                characterNode: characterNode,
                from: platform
            )
        } else if roll < 14 {
            // Place and mine a block!
            triggerPlaceAndMine(characterNode: characterNode)
        } else if roll < 24 {
            // Eat snack / apple
            triggerEating(characterNode: characterNode)
        } else if roll < 34 {
            // Minecraft Sneak Twerk Dance!
            triggerSneakDance(characterNode: characterNode)
        } else if roll < 46 {
            // 감정 표현 (박수·기지개·명상 등 장식 모션)
            if let emote = CharacterEmote.allCases.randomElement() {
                triggerEmote(emote, characterNode: characterNode)
            }
        } else if roll < 58 {
            // Poke Dock or window
            let label = (platform.kind == .dock) ? "Dock 아이콘 툭툭 건드리기" : "창문 노크하기"
            state = .poke(timeLeft: Double.random(in: 1.5...3.0), label: label)
        } else if roll < 70 {
            // Sit down and rest
            state = .sit(timeLeft: Double.random(in: 3.5...7.0))
        } else if roll < 84 {
            // Look around
            let randomYaw = CGFloat.random(in: -0.8...0.8)
            state = .lookAround(timeLeft: Double.random(in: 1.5...3.0), targetYaw: randomYaw)
        } else {
            // Walk
            if maxX > minX {
                let destX = CGFloat.random(in: minX...maxX)
                let dir: CGFloat = destX > physics.position.x ? 1.0 : -1.0
                state = .walk(direction: dir, targetX: destX, duration: 0, lastX: physics.position.x, stuckTime: 0)
            } else {
                state = .idle(timeLeft: 2.0)
            }
        }
    }

    /// 적대적 몹(크리퍼, 스켈레톤 등)과 근접 충돌 시 반대 방향으로 즉시 후퇴
    public func recoilFromHostile(awayFrom hostileX: CGFloat, physics: PhysicsEngine, characterNode: MinecraftCharacterNode) {
        let fleeDir: CGFloat = physics.position.x >= hostileX ? 1.0 : -1.0
        let targetX = physics.position.x + fleeDir * 120.0
        state = .walk(
            direction: fleeDir,
            targetX: targetX,
            duration: 0,
            lastX: physics.position.x,
            stuckTime: 0
        )
        characterNode.modelRoot.eulerAngles.y = fleeDir > 0 ? (CGFloat.pi / 2.0) : (-CGFloat.pi / 2.0)
    }

    /// 적대적 몹을 향해 빠른 속도로 돌격
    public func chargeAt(targetX: CGFloat, speed: CGFloat = 220.0, duration: TimeInterval = 0.5, physics: PhysicsEngine, characterNode: MinecraftCharacterNode) {
        state = .charge(targetX: targetX, speed: speed, duration: duration)
        let dir: CGFloat = targetX >= physics.position.x ? 1.0 : -1.0
        characterNode.modelRoot.eulerAngles.y = dir > 0 ? (CGFloat.pi / 2.0) : (-CGFloat.pi / 2.0)
        characterNode.walkSpeed = 1.6
    }

    /// 돌격 중단 및 기본 대기 상태로 복귀
    public func stopCharging() {
        if case .charge = state {
            state = .idle(timeLeft: 0.8)
        }
    }

    private func handleReachedEdge(
        isLeft: Bool,
        platform: Platform?,
        screen: NSScreen,
        characterNode: MinecraftCharacterNode,
        physics: PhysicsEngine
    ) {
        let roll = Double.random(in: 0...100)

        // 1. 45% chance: Sit down and relax (dangle legs)
        if roll < 45 {
            state = .sit(timeLeft: Double.random(in: 4.0...8.0))
            return
        }

        // 2. 40% chance: Turn around and walk back towards screen center!
        if roll < 85 {
            let turnDirection: CGFloat = isLeft ? 1.0 : -1.0
            let screenMidX = screen.frame.midX
            let safeTargetX: CGFloat
            if let p = platform {
                let pMid = (p.xMin + p.xMax) / 2.0
                safeTargetX = isLeft ? min(screenMidX, pMid + 80) : max(screenMidX, pMid - 80)
            } else {
                safeTargetX = isLeft ? (physics.position.x + 150) : (physics.position.x - 150)
            }

            state = .walk(
                direction: turnDirection,
                targetX: safeTargetX,
                duration: 0,
                lastX: physics.position.x,
                stuckTime: 0
            )
            return
        }

        // 3. 15% chance: Stand and look around or peek over cliff
        if let p = platform, p.kind != .floor && p.kind != .dock {
            let label = (p.kind == .menuBar) ? "화면 아래 내려다보기" : "아래 내려다보기"
            state = .poke(timeLeft: 2.5, label: label)
        } else {
            let lookAway = isLeft ? CGFloat(0.7) : CGFloat(-0.7)
            state = .lookAround(timeLeft: 2.5, targetYaw: lookAway)
        }
    }

    private func updateHeadLookAt(
        charPos: CGPoint,
        cursorPos: CGPoint,
        characterNode: MinecraftCharacterNode
    ) {
        let headScreenPos = CGPoint(x: charPos.x, y: charPos.y + 65)
        let dx = cursorPos.x - headScreenPos.x
        let dy = cursorPos.y - headScreenPos.y
        let distance = hypot(dx, dy)

        if distance < 1000 && distance > 10 {
            let bodyYaw = characterNode.modelRoot.eulerAngles.y
            var rawYaw = CGFloat(atan2(dx, 150)) - bodyYaw
            rawYaw = max(-1.2, min(1.2, rawYaw))
            characterNode.targetHeadYaw = rawYaw

            var rawPitch = CGFloat(-atan2(dy, 150))
            rawPitch = max(-0.8, min(0.8, rawPitch))
            characterNode.targetHeadPitch = rawPitch
        } else {
            characterNode.targetHeadYaw = 0
            characterNode.targetHeadPitch = 0
        }
    }
}
