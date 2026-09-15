import AppKit
import CoreGraphics
import SceneKit
import UniformTypeIdentifiers

public final class AppController: NSObject, CharacterViewDelegate, PetViewDelegate, CreeperViewDelegate, EndermanViewDelegate, SkeletonViewDelegate, SlimeWindowDelegate, FoxWindowDelegate, PhantomWindowDelegate, SpiderWindowDelegate, GhastWindowDelegate, ZombieWindowDelegate, SheepWindowDelegate, ChickenWindowDelegate, MooshroomWindowDelegate, TreeWindowDelegate, NSMenuDelegate {
    var window: CharacterWindow!
    private var physics: PhysicsEngine!
    var behavior = CharacterBehaviorController()
    var currentSkinType: BuiltinSkinType = .steve
    var currentCustomSkinName: String?

    private var statusItem: NSStatusItem?
    var statusMenuItem: NSMenuItem?

    private var gameTimer: Timer?
    private var scanCounter: Int = 0
    private var cachedPlatforms: [Platform] = []
    private var lastUpdateTime: TimeInterval = 0
    lazy var director = MobDirector(app: self)

    // Pickaxe attack (앱 창 부수기)
    var attackMenuItem: NSMenuItem?
    private var breakOverlays: [BlockBreakOverlayWindow] = []
    private var tntEntityWindow: TNTEntityWindow?
    private var tntPlacementPoint: CGPoint = .zero
    private var isBreakInProgress = false

    // Ladder descent (사다리 타고 창문 내려가기)
    var ladderMenuItem: NSMenuItem?

    // Typing cheer (⌨️ 타이핑 응원 — 설정 메뉴의 실시간 WPM 상태 줄)
    var typingStatusItem: NSMenuItem?
    private var ladderOverlay: LadderOverlayWindow?

    // Pet Companion (펫 동반자 시스템)
    private var petWindow: PetWindow?
    private var petPhysics: PhysicsEngine?
    private var petBehavior: PetBehaviorController?
    public private(set) var currentPetKind: PetKind? = nil

    // Creeper Entity (크리퍼 출현 & 퇴치)
    var creeperWindow: CreeperWindow?
    private var creeperPhysics: PhysicsEngine?
    private var creeperBehavior: CreeperBehaviorController?
    var isCreeperSpawnEnabled: Bool = true
    var creeperSpawnInterval: TimeInterval = 120.0 // Occasional spawn every ~2 min
    var preferredCreeperLegType: CreeperLegType? {
        get {
            guard let raw = UserDefaults.standard.string(forKey: "preferredCreeperLegType") else {
                return nil // 기본값: 무작위 (4족/2족 50:50)
            }
            if raw == "random" { return nil }
            return CreeperLegType(rawValue: raw)
        }
        set {
            if let val = newValue {
                UserDefaults.standard.set(val.rawValue, forKey: "preferredCreeperLegType")
            } else {
                UserDefaults.standard.set("random", forKey: "preferredCreeperLegType")
            }
        }
    }
    let player = PlayerState()

    // Enderman Entity (엔더맨 출현 & 시선 마주침)
    var endermanWindow: EndermanWindow?
    private var endermanPhysics: PhysicsEngine?
    private var endermanBehavior: EndermanBehaviorController?
    var isEndermanSpawnEnabled: Bool = true
    var endermanSpawnInterval: TimeInterval = 150.0

    // Skeleton Entity (스켈레톤 출현 & 활 쏘기)
    var skeletonWindow: SkeletonWindow?
    private var skeletonPhysics: PhysicsEngine?
    private var skeletonBehavior: SkeletonBehaviorController?
    var isSkeletonSpawnEnabled: Bool = true
    var skeletonSpawnInterval: TimeInterval = 140.0
    private var activeArrows: [ArrowEntityWindow] = []
    private var skeletonAggroTimer: TimeInterval = 0
    private var activeTridents: [TridentEntityWindow] = []

    // L2. Skin Filter & L3. Glint & L4. Battery
    private var baseSkinTexture: SkinTexture?
    var currentSkinFilterName: String = "원본 (Original)"
    var isBatteryHungerEnabled: Bool = true
    private var isBatteryAlertFired: Bool = false
    private var batteryCheckTimer: TimeInterval = 0
    var isPowerModeEnabled: Bool = true
    private var powerStagePollTimer: TimeInterval = 0

    public override init() {
        super.init()
    }

    public func start() {
        // 1. Initial Skin
        let skinImage = BuiltinSkinGenerator.makeSkin(type: currentSkinType)
        guard let skin = SkinTexture(image: skinImage) else {
            fatalError("Failed to create default skin")
        }
        self.baseSkinTexture = skin

        // 2. Determine initial position (above Dock or floor)
        let mainScreen = NSScreen.main ?? NSScreen.screens[0]
        let platforms = ScreenEnvironment.shared.scanPlatforms(for: mainScreen)
        self.cachedPlatforms = platforms

        let initialY = mainScreen.visibleFrame.minY + 20
        let initialX = mainScreen.frame.midX
        let initialPos = CGPoint(x: initialX, y: initialY)

        // 3. Physics & Window Setup
        self.physics = PhysicsEngine(initialPosition: initialPos)
        self.window = CharacterWindow(skin: skin)
        self.window.characterView.characterDelegate = self
        self.window.setFeetPosition(x: initialPos.x, y: initialPos.y)
        self.window.orderFrontRegardless()

        // 4. Status Bar Menu Setup
        setupStatusBar()

        // 5. Start 60 FPS Game Loop
        self.lastUpdateTime = ProcessInfo.processInfo.systemUptime
        self.gameTimer = Timer.scheduledTimer(
            timeInterval: 1.0 / 60.0,
            target: self,
            selector: #selector(gameLoopTick),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(self.gameTimer!, forMode: .common)

        // 6. Default companion: tuxedo cat on every launch
        summonPet(kind: .cat)

        // 7. Background Auto-Update Check (앱 시작 3초 후 조용히 확인)
        UpdateManager.shared.onUpdateStatusChanged = { [weak self] release in
            DispatchQueue.main.async {
                self?.rebuildContextMenu()
                if let r = release {
                    self?.window.characterView.characterNode.showOverheadEmoji("🚀 새 버전(v\(r.version)) 출시!", duration: 3.5)
                }
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) {
            UpdateManager.shared.checkForUpdates(manual: false)
        }
    }

    // MARK: - Game Loop
    @objc private func gameLoopTick() {
        let now = ProcessInfo.processInfo.systemUptime
        var dt = now - lastUpdateTime
        lastUpdateTime = now

        // Clamp dt to avoid huge jumps if app pauses
        if dt > 0.1 { dt = 0.1 }
        if dt <= 0 { dt = 1.0 / 60.0 }

        let screen = ScreenEnvironment.shared.screen(for: physics.position)

        // Periodic Platform Rescan (every ~30 frames = 0.5s)
        scanCounter += 1
        if scanCounter >= 30 {
            scanCounter = 0
            cachedPlatforms = ScreenEnvironment.shared.scanPlatforms(for: screen)
        }

        let cursorPos = NSEvent.mouseLocation

        // 타이핑 감지: 전역 keyDown 카운터 증가분을 적립(프레임당 정확히 1회)
        TypingActivityMonitor.shared.poll(now: now)

        // 1. Behavior AI Decision
        behavior.update(
            deltaTime: dt,
            physics: physics,
            characterNode: window.characterView.characterNode,
            platforms: cachedPlatforms,
            screen: screen,
            cursorPos: cursorPos
        )

        // 1.5. TNT: 도화선 점멸 동기화
        syncTNT()

        // 1.6. Ladder descent: sync ladder overlay with climb progress
        syncLadderOverlay()

        // 2. Physics Update
        physics.update(
            deltaTime: CGFloat(dt),
            platforms: cachedPlatforms,
            screen: screen
        )

        // 3. 3D Character Node Animation Update
        window.characterView.characterNode.update(deltaTime: CGFloat(dt))

        // 4. Sync Window Position with Feet
        window.setFeetPosition(x: physics.position.x, y: physics.position.y)


        // 4.5. Update Pet Companion
        if let pw = petWindow, let pPhys = petPhysics, let pBehav = petBehavior {
            let playerDir = window.characterView.characterNode.modelRoot.eulerAngles.y
            let playerSitting = window.characterView.characterNode.isSitting
            let playerSleeping = window.characterView.characterNode.isSleeping
            pBehav.update(
                deltaTime: CGFloat(dt),
                petPhysics: pPhys,
                petNode: pw.petView.petNode,
                playerPos: physics.position,
                playerIsSitting: playerSitting,
                playerIsSleeping: playerSleeping,
                playerDirection: playerDir,
                screen: screen,
                platforms: cachedPlatforms
            )
            pPhys.update(deltaTime: CGFloat(dt), platforms: cachedPlatforms, screen: screen)
            pw.petView.petNode.update(deltaTime: CGFloat(dt))
            pw.setFeetPosition(x: pPhys.position.x, y: pPhys.position.y)
        }

        // 4.6. Update Creeper Entity
        if let cw = creeperWindow, let cPhys = creeperPhysics, let cBehav = creeperBehavior {
            let catPos: CGPoint?
            if currentPetKind == .cat, let pPhys = petPhysics {
                catPos = pPhys.position
            } else {
                catPos = nil
            }

            cBehav.update(
                deltaTime: CGFloat(dt),
                creeperPhysics: cPhys,
                creeperNode: cw.creeperView.creeperNode,
                playerPos: physics.position,
                catPos: catPos,
                onExplode: { [weak self] blastPos in
                    self?.handleCreeperExploded(at: blastPos)
                },
                onDefeated: { [weak self] in
                    let currentWeapon = self?.window.characterView.characterNode.currentHeldItem ?? .none
                    self?.handleCreeperDefeated(with: currentWeapon)
                }
            )
            cPhys.update(deltaTime: CGFloat(dt), platforms: cachedPlatforms, screen: screen)
            cw.creeperView.creeperNode.update(deltaTime: CGFloat(dt))
            cw.setFeetPosition(x: cPhys.position.x, y: cPhys.position.y)

            // Solid collision & Hostile engagement (크리퍼 충돌·밀침 및 무기/도주 반응)
            let dist = hypot(cPhys.position.x - physics.position.x, cPhys.position.y - physics.position.y)
            let dy = abs(physics.position.y - cPhys.position.y)
            let dx = physics.position.x - cPhys.position.x
            let solidRadius: CGFloat = 52.0

            if dy < 45.0 && abs(dx) < solidRadius && cBehav.isAlive {
                let overlap = solidRadius - abs(dx)
                let pushDir: CGFloat = dx >= 0 ? 1.0 : -1.0
                physics.position.x += pushDir * (overlap * 0.5)
                cPhys.position.x -= pushDir * (overlap * 0.5)

                let currentWeapon = window.characterView.characterNode.currentHeldItem
                let isWeapon = (currentWeapon == .diamondSword || currentWeapon == .axe || currentWeapon == .trident || currentWeapon == .diamondPickaxe || currentWeapon == .bow)

                if isWeapon && player.playerAttackTimer <= 0 {
                    attackCreeperWithCurrentWeapon()
                } else if !isWeapon {
                    behavior.recoilFromHostile(awayFrom: cPhys.position.x, physics: physics, characterNode: window.characterView.characterNode)
                    window.characterView.characterNode.showOverheadEmoji("😱 으악! 크리퍼다!", duration: 1.2)
                }
            } else if dist < 100.0 && cBehav.isAlive && player.playerAttackTimer <= 0 {
                let currentWeapon = window.characterView.characterNode.currentHeldItem
                let isWeapon = (currentWeapon == .diamondSword || currentWeapon == .axe || currentWeapon == .trident || currentWeapon == .diamondPickaxe || currentWeapon == .bow)
                if isWeapon {
                    attackCreeperWithCurrentWeapon()
                }
            }
        }

        // Player attack animation timer
        if player.playerAttackTimer > 0 {
            player.playerAttackTimer -= dt
            if player.playerAttackTimer <= 0 {
                window.characterView.characterNode.isAttackingWeapon = false
            }
        }

        // Ambient mob auto-spawn: MobDirector에 위임 (조건·주기·확률 원본 동일)
        director.update(dt: dt)

        // L4. Battery Hunger Check (every ~5.0s, L2 우유 정화 중에는 억제)
        if player.milkCleanseTimer > 0 {
            player.milkCleanseTimer -= dt
        }
        if isBatteryHungerEnabled && player.milkCleanseTimer <= 0 {
            batteryCheckTimer += dt
            if batteryCheckTimer >= 5.0 {
                batteryCheckTimer = 0
                let bInfo = BatteryStatusMonitor.shared.getBatteryInfo()
                if bInfo.hasBattery {
                    if !bInfo.isCharging && bInfo.percent <= 20 {
                        if !isBatteryAlertFired {
                            isBatteryAlertFired = true
                            window.characterView.characterNode.showOverheadEmoji("🍗 배고파... 꼬르륵 (배터리 \(bInfo.percent)%)", duration: 3.0)
                            SoundAndEffectsManager.shared.play(.alert)
                        }
                    } else if bInfo.isCharging && isBatteryAlertFired {
                        isBatteryAlertFired = false
                        window.characterView.characterNode.showOverheadEmoji("⚡ 충전기 연결! 힘이 솟는다!", duration: 2.5)
                        SoundAndEffectsManager.shared.play(.heart)
                    }
                }
            }
        }

        // CPU Power Mode Poll (every 3.0s, accumulated dt — no extra threads)
        if isPowerModeEnabled {
            powerStagePollTimer += dt
            if powerStagePollTimer >= 3.0 {
                powerStagePollTimer = 0
                PowerStageManager.shared.update(characterNode: window.characterView.characterNode)
            }
        }

        // 4.7. Update Enderman Entity
        if let ew = endermanWindow, let ePhys = endermanPhysics, let eBehav = endermanBehavior {
            eBehav.update(
                deltaTime: CGFloat(dt),
                endermanPhysics: ePhys,
                endermanNode: ew.endermanView.endermanNode,
                playerPos: physics.position,
                cursorPos: cursorPos,
                screen: screen,
                onDefeated: { [weak self] in
                    self?.handleEndermanDefeated()
                }
            )
            ePhys.update(deltaTime: CGFloat(dt), platforms: cachedPlatforms, screen: screen)
            ew.endermanView.endermanNode.update(deltaTime: CGFloat(dt))
            ew.setFeetPosition(x: ePhys.position.x, y: ePhys.position.y)

            // Auto-attack if player has weapon and Enderman charges dangerously close
            let dist = hypot(ePhys.position.x - physics.position.x, ePhys.position.y - physics.position.y)
            if dist < 110.0 && eBehav.isAlive && eBehav.isEnraged && player.playerAttackTimer <= 0 {
                attackEndermanWithCurrentWeapon()
            }
        }

        // 4.8. Update Skeleton Entity
        if let sw = skeletonWindow, let sPhys = skeletonPhysics, let sBehav = skeletonBehavior {
            let skelScreen = ScreenEnvironment.shared.screen(for: sPhys.position)
            sBehav.update(
                deltaTime: CGFloat(dt),
                skeletonPhysics: sPhys,
                skeletonNode: sw.skeletonView.skeletonNode,
                playerPos: physics.position,
                platforms: cachedPlatforms,
                screen: skelScreen,
                onShootArrow: { [weak self] startPos, targetPos in
                    self?.launchArrowFromSkeleton(from: startPos, to: targetPos)
                },
                onDefeated: { [weak self] in
                    self?.handleSkeletonDefeated()
                }
            )
            sPhys.update(deltaTime: CGFloat(dt), platforms: cachedPlatforms, screen: skelScreen)
            sw.skeletonView.skeletonNode.update(deltaTime: CGFloat(dt))
            sw.setFeetPosition(x: sPhys.position.x, y: sPhys.position.y)

            // Solid collision & Hostile engagement (스켈레톤 충돌·밀침 및 무기/도주 반응)
            let dist = hypot(sPhys.position.x - physics.position.x, sPhys.position.y - physics.position.y)
            let dy = abs(physics.position.y - sPhys.position.y)
            let dx = physics.position.x - sPhys.position.x
            let solidRadius: CGFloat = 52.0

            // 🏹 스켈레톤 화살 피격 시 적극적 공격/추격 모드 (Aggro)
            if skeletonAggroTimer > 0 && sBehav.isAlive {
                skeletonAggroTimer -= dt

                let char = window.characterView.characterNode
                let currentWeapon = char.currentHeldItem
                let isWeapon = (currentWeapon == .diamondSword || currentWeapon == .axe || currentWeapon == .trident || currentWeapon == .diamondPickaxe || currentWeapon == .bow)
                if !isWeapon {
                    char.currentHeldItem = .diamondSword
                }

                // 스켈레톤을 향해 빠른 속도(220pt/s)로 맹렬히 돌격
                if abs(dx) > 35.0 {
                    behavior.chargeAt(targetX: sPhys.position.x, speed: 220.0, duration: 0.3, physics: physics, characterNode: char)
                }

                // 스켈레톤이 높은 곳에 있으면 점프 돌격
                if sPhys.position.y > physics.position.y + 25.0 {
                    physics.jump(impulse: 380)
                }

                // 사정거리(110pt) 내 진입 시 빠른 연속 타격 (쿨다운 0.22초)
                if dist < 110.0 && player.playerAttackTimer <= 0 {
                    attackSkeletonWithCurrentWeapon()
                    player.playerAttackTimer = 0.22
                }
            } else if !sBehav.isAlive && skeletonAggroTimer > 0 {
                skeletonAggroTimer = 0
                behavior.stopCharging()
            } else if dy < 45.0 && abs(dx) < solidRadius && sBehav.isAlive {
                let overlap = solidRadius - abs(dx)
                let pushDir: CGFloat = dx >= 0 ? 1.0 : -1.0
                physics.position.x += pushDir * (overlap * 0.5)
                sPhys.position.x -= pushDir * (overlap * 0.5)

                let currentWeapon = window.characterView.characterNode.currentHeldItem
                let isWeapon = (currentWeapon == .diamondSword || currentWeapon == .axe || currentWeapon == .trident || currentWeapon == .diamondPickaxe || currentWeapon == .bow)

                if isWeapon && player.playerAttackTimer <= 0 {
                    attackSkeletonWithCurrentWeapon()
                } else if !isWeapon {
                    behavior.recoilFromHostile(awayFrom: sPhys.position.x, physics: physics, characterNode: window.characterView.characterNode)
                    window.characterView.characterNode.showOverheadEmoji("💀 으악! 스켈레톤이다!", duration: 1.2)
                }
            } else if dist < 100.0 && sBehav.isAlive && player.playerAttackTimer <= 0 {
                let currentWeapon = window.characterView.characterNode.currentHeldItem
                let isWeapon = (currentWeapon == .diamondSword || currentWeapon == .axe || currentWeapon == .trident || currentWeapon == .diamondPickaxe || currentWeapon == .bow)
                if isWeapon {
                    attackSkeletonWithCurrentWeapon()
                }
            }
        }

        // M3. Slime proximity auto-attack + active hunting
        for slime in slimeWindows {
            let dx = slime.position.x - physics.position.x
            let dy = abs(slime.position.y - physics.position.y)
            let dist = hypot(dx, dy)
            if dist < 90.0 && player.playerAttackTimer <= 0 {
                attackSlime(slime)
            } else if dist < 220.0 && dy < 45.0 && skeletonAggroTimer <= 0 && creeperWindow == nil {
                let char = window.characterView.characterNode
                if char.currentHeldItem == .none {
                    char.currentHeldItem = .diamondSword
                }
                behavior.chargeAt(targetX: slime.position.x, speed: 140.0, duration: 0.3, physics: physics, characterNode: char)
            }
        }
        // L3. Nether portal entry check + M4 baby pet follow
        checkPortalEntry()
        updateBabyPet(dt: dt)
        updateWildWolf(dt: dt)
        updateWildHorse(dt: dt)
        updateHorseRide(dt: dt)
        updateWeather(dt: dt, screen: screen)
        updateBees()
        updateBalloonFall()
        updateBuddies(dt: dt, screen: screen, cursorPos: cursorPos)
        updatePotions(dt: dt)
        updateMinecart(dt: dt)
        updateGoat()
        updatePhantom(dt: dt)
        updateSpider()
        updateGhast()
        updateSiege(dt: dt)
        updateAxolotl()
        updateGolemAnchor()
        updateWitch()
        updateCampfire(dt: dt)
        updateCropsAutoHarvest(dt: dt)

        // H4. Day/Night cycle (every ~5s)
        dayNightTimer += dt
        if dayNightTimer >= 5.0 {
            dayNightTimer = 0
            DayNightCycleManager.shared.refresh()
            let isNight = DayNightCycleManager.shared.isNight
            if isNight != wasNight {
                wasNight = isNight
                let charNode = window.characterView.characterNode
                if isNight {
                    if charNode.currentHeldItem == .none {
                        charNode.currentHeldItem = .torch
                        didAutoEquipTorch = true
                    }
                    charNode.showOverheadEmoji("🌙 밤이 됐네... 횃불 켜자! 🔥", duration: 2.5)
                    SoundAndEffectsManager.shared.play(.ignite)
                } else {
                    if didAutoEquipTorch && charNode.currentHeldItem == .torch {
                        charNode.currentHeldItem = .none
                    }
                    didAutoEquipTorch = false
                    charNode.showOverheadEmoji("☀️ 좋은 아침!", duration: 2.0)
                }
            }
        }

        // Night skip: 밤에 전원(플레이어+펫)이 6초 이상 쿨쿨 자면 아침으로 스킵
        let playerSleeping = window.characterView.characterNode.isSleeping
        let petSleeping = petBehavior == nil || petBehavior?.isSleeping == true
        if DayNightCycleManager.shared.isNight && playerSleeping && petSleeping {
            sleepSkipTimer += dt
            if sleepSkipTimer >= 6.0 {
                sleepSkipTimer = 0
                DayNightCycleManager.shared.skipToMorning()
                AdvancementManager.shared.unlock(.nightSkip)
                behavior.wakeUpIfSleeping(
                    characterNode: window.characterView.characterNode,
                    withEmoji: "☀️ 푹 잤다! 아침이다!"
                )
                if petBehavior != nil {
                    petBehavior?.isSleeping = false
                    petWindow?.petView.petNode.isSleeping = false
                }
                wasNight = false
                if didAutoEquipTorch && window.characterView.characterNode.currentHeldItem == .torch {
                    window.characterView.characterNode.currentHeldItem = .none
                }
                didAutoEquipTorch = false
            }
        } else {
            sleepSkipTimer = 0
        }
        // 5. Update Status Menu Text
        updateStatusMenuItemText()
    }

    private func updateStatusMenuItemText() {
        guard let item = statusMenuItem else { return }

        let desc: String
        switch behavior.state {
        case .idle:
            if let p = physics.currentPlatform {
                desc = "휴식 중 (\(p.title) 위)"
            } else {
                desc = "휴식 중"
            }
        case .lookAround:
            desc = "주변 둘러보는 중 👀"
        case .walk:
            if let p = physics.currentPlatform {
                desc = "산책 중 (\(p.title))"
            } else {
                desc = "걷는 중"
            }
        case .sit:
            if let p = physics.currentPlatform {
                if p.kind == .menuBar {
                    desc = "상단 메뉴바에 걸터앉아 쉬는 중 🪑"
                } else {
                    desc = "\(p.title)에 걸터앉아 쉬는 중 🪑"
                }
            } else {
                desc = "걸터앉아 다리 흔들기"
            }
        case .poke(_, let label):
            desc = label.isEmpty ? "툭툭 건드려보기 ⛏️" : "\(label) ⛏️"
        case .wave:
            desc = "반갑게 손 흔드는 중 👋"
        case .sneakDance:
            desc = "마인크래프트 쉬프트 댄스 🕺"
        case .eating:
            desc = "우물우물 사과 먹는 중 🍎"
        case .placeAndMineBlock:
            desc = "블록 캐는 중 ⛏️"
        case .sleep:
            desc = "쿨쿨 낮잠 자는 중... 💤"
        case .backflip:
            desc = "공중제비 도는 중! 🤸‍♂️"
        case .cheer(let wpm, _, _):
            desc = "코딩 신나게 응원 중! 🔥 (WPM: \(Int(wpm)))"
        case .nag:
            desc = "쌓인 알림 안 읽는다고 구박하는 중! 💢"
        case .tnt:
            if let remain = behavior.tntFuseRemaining {
                desc = String(format: "🧨 TNT 폭발까지 %.1f초!", remain)
            } else {
                desc = "🧨 TNT 설치하는 중..."
            }
        case .squash:
            desc = "창을 압축해서 Dock으로 치우는 중! 🗜️"
        case .fishing:
            desc = "물가에 낚싯대 드리우고 낚시 중 🎣"
        case .throwTrident:
            desc = "충성 삼지창 투척! 돌아와-! 🔱"
        case .jukebox:
            desc = "주크박스 리듬 타며 댄스 중 🎶"
        case .drinkMilk:
            desc = "우유 꿀꺽 정화 중 🥛"
        case .charge:
            desc = "적대적 몹을 향해 맹렬히 돌격 중! ⚔️"
        case .emote(let kind, _):
            desc = "\(kind.name) 중 \(kind.emoji)"
        case .climb(_, _, let isUp):
            desc = isUp ? "🪜 사다리 타고 창문 올라가는 중" : "🪜 사다리 타고 창문 내려가는 중"
        case .fall:
            desc = "으악! 떨어지는 중! 🪂"
        case .dragged:
            desc = "사용자에게 잡혀 버둥거리는 중 ✋"
        case .landedCrouch:
            desc = "착지! 쿵 💥"
        }

        item.title = "현재 상태: \(desc)"
    }

    // MARK: - CharacterViewDelegate
    private func triple(for view: CharacterView) -> (PhysicsEngine, CharacterBehaviorController, MinecraftCharacterNode) {
        for i in buddyWindows.indices where view === buddyWindows[i].characterView {
            return (buddyPhysics[i], buddyBehaviors[i], buddyWindows[i].characterView.characterNode)
        }
        return (physics, behavior, window.characterView.characterNode)
    }

    public func characterViewDidStartDrag(_ view: CharacterView, at screenPoint: CGPoint) {
        triple(for: view).0.setDragged(at: screenPoint)
    }

    public func characterViewDidDrag(_ view: CharacterView, to screenPoint: CGPoint) {
        triple(for: view).0.setDragged(at: screenPoint)
    }

    public func characterViewDidEndDrag(_ view: CharacterView, throwVelocity: CGPoint) {
        let t = triple(for: view)
        t.0.releaseDrag(throwVelocity: throwVelocity)

        // 놓는 순간의 위치 기준으로 발판을 즉시 다시 스캔한다.
        // 게임 루프의 0.5초 주기 스캔은 '직전에 캐릭터가 있던 화면' 기준이라, 다른 모니터의 창문 위로
        // 빠르게(0.5초 안에) 끌어다 놓으면 이전 화면의 발판 목록이 그대로 남아 있다.
        // 그 상태로는 창문을 못 찾아 사다리 등반도 착지도 실패하고, 캐릭터가 창문을 뚫고 이전 화면 바닥까지 떨어진다.
        cachedPlatforms = ScreenEnvironment.shared.scanPlatforms(for: ScreenEnvironment.shared.screen(for: t.0.position))

        // 약하게 놓았고 그 자리가 창문 안이면, 놓인 자리에서 그 창문 위쪽 끝까지 사다리를 걸고 올라간다.
        // 세게 던진 경우(throwVelocity 큼)는 기존처럼 그대로 날아간다.
        if hypot(throwVelocity.x, throwVelocity.y) <= CharacterBehaviorController.dropSnapSpeedLimit {
            behavior.climbUpFromDrop(
                physics: t.0,
                characterNode: t.2,
                platforms: cachedPlatforms
            )
        }
    }

    public func characterViewDidRequestMenu(_ view: CharacterView, at event: NSEvent) {
        let menu = buildContextMenu()
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
    public func characterViewDidLoadSkinFile(_ view: CharacterView, url: URL) {
        loadCustomSkin(from: url)
    }

    // MARK: - L1 Multi-Character (친구 소환)
    var buddyWindows: [CharacterWindow] = []
    private var buddyPhysics: [PhysicsEngine] = []
    private var buddyBehaviors: [CharacterBehaviorController] = []

    @objc func didSelectSummonBuddy() {
        guard buddyWindows.count < 2 else {
            window.characterView.characterNode.showOverheadEmoji("👥 꽉 찼어! (최대 3명)", duration: 1.8)
            return
        }
        let type: BuiltinSkinType = buddyWindows.isEmpty ? .alex : .zombie
        guard let skin = SkinTexture(image: BuiltinSkinGenerator.makeSkin(type: type)) else { return }
        let bw = CharacterWindow(skin: skin)
        bw.characterView.characterDelegate = self
        let spawn = CGPoint(x: physics.position.x + (buddyWindows.isEmpty ? -90 : 90), y: physics.position.y + 30)
        let bp = PhysicsEngine(initialPosition: spawn)
        buddyPhysics.append(bp)
        buddyBehaviors.append(CharacterBehaviorController())
        buddyWindows.append(bw)
        AdvancementManager.shared.unlock(.buddySummon)
        bw.setFeetPosition(x: spawn.x, y: spawn.y)
        bw.orderFrontRegardless()
        bw.characterView.characterNode.showOverheadEmoji("👋 같이 놀자!", duration: 2.2)
        SoundAndEffectsManager.shared.play(.heart)
        statusItem?.menu = buildContextMenu()
    }

    @objc func didSelectDismissBuddies() {
        for bw in buddyWindows { bw.close() }
        buddyWindows = []
        buddyPhysics = []
        buddyBehaviors = []
        statusItem?.menu = buildContextMenu()
    }

    private func updateBuddies(dt: TimeInterval, screen: NSScreen, cursorPos: CGPoint) {
        for i in buddyWindows.indices {
            let bw = buddyWindows[i]
            let bp = buddyPhysics[i]
            let bb = buddyBehaviors[i]
            bb.update(
                deltaTime: dt,
                physics: bp,
                characterNode: bw.characterView.characterNode,
                platforms: cachedPlatforms,
                screen: screen,
                cursorPos: cursorPos
            )
            bp.update(deltaTime: CGFloat(dt), platforms: cachedPlatforms, screen: screen)
            bw.characterView.characterNode.update(deltaTime: CGFloat(dt))
            bw.setFeetPosition(x: bp.position.x, y: bp.position.y)
        }
    }

    public func characterViewDidClick(_ view: CharacterView) {
        let t = triple(for: view)
        if t.2.isGliding {
            let facingDir = t.2.modelRoot.eulerAngles.y
            t.0.fireworkRocketBoost(facingDir: facingDir)
            t.2.showOverheadEmoji("🚀 슈우웅!", duration: 1.5)
            SoundAndEffectsManager.shared.play(.ignite)
            return
        }
        t.1.handleCharacterClicked(physics: t.0, characterNode: t.2)
    }

    public func characterViewDidDoubleClick(_ view: CharacterView) {
        let t = triple(for: view)
        t.1.triggerBackflip(physics: t.0, characterNode: t.2)
    }

    // MARK: - NSMenuDelegate
    public func menuNeedsUpdate(_ menu: NSMenu) {
        attackMenuItem?.isEnabled = canStartTNTBreak()
        ladderMenuItem?.isEnabled = canStartLadderDescent()
        // 감지가 살아 있는지 사용자가 바로 확인할 수 있게, 메뉴를 열 때마다 현재 WPM 으로 갱신
        typingStatusItem?.title = typingStatusTitle()
    }

    /// 설정 메뉴의 타이핑 감지 상태 줄. 응원 기준(35 WPM)과 현재 속도를 함께 보여준다.
    func typingStatusTitle() -> String {
        guard TypingActivityMonitor.shared.isEnabled else { return "  ⌨️ 타이핑 응원 모드 꺼짐" }
        let wpm = Int(TypingActivityMonitor.shared.currentWPM)
        let threshold = Int(TypingActivityMonitor.cheerThreshold)
        return wpm > 0
            ? "  ⌨️ 지금 \(wpm) WPM 감지 중 (\(threshold) WPM 이상이면 응원)"
            : "  ⌨️ 타이핑 대기 중 (\(threshold) WPM 이상이면 응원)"
    }

    func didToggleTotemFromMenu() {
        didToggleTotem(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
    }

    func didToggleDefenseModeFromMenu() {
        didToggleDefenseMode(NSMenuItem(title: "", action: nil, keyEquivalent: ""))
    }
    // MARK: - Status Bar & Menus
    private func setupStatusBar() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = item

        if let button = item.button {
            button.image = makeMiniSteveIcon()
            button.toolTip = "마인크래프트 데스크톱 친구 (Oh Mine Friend)"
        }

        item.menu = buildContextMenu()
    }

    private func buildContextMenu() -> NSMenu {
        MenuBuilder(app: self).build()
    }

    // MARK: - Actions
    @objc func didSelectBuiltinSkin(_ sender: NSMenuItem) {
        guard let skinType = sender.representedObject as? BuiltinSkinType else { return }
        self.currentSkinType = skinType
        self.currentCustomSkinName = nil
        let img = BuiltinSkinGenerator.makeSkin(type: skinType)
        if let skin = SkinTexture(image: img) {
            self.baseSkinTexture = skin
            self.currentSkinFilterName = "원본 (Original)"
            window.characterView.characterNode.applySkin(skin)
        }
        statusItem?.menu = buildContextMenu()
    }

    @objc func didSelectOpenCustomSkin() {
        let openPanel = NSOpenPanel()
        openPanel.allowedContentTypes = [.png]
        openPanel.allowsMultipleSelection = false
        openPanel.canChooseDirectories = false
        openPanel.message = "마인크래프트 64x64 스킨 PNG 파일을 선택하세요"

        if openPanel.runModal() == .OK, let url = openPanel.url {
            loadCustomSkin(from: url)
        }
    }

    private func loadCustomSkin(from url: URL) {
        if let skin = SkinTexture.load(from: url) {
            applyCustomSkin(skin, name: url.deletingPathExtension().lastPathComponent)
        }
    }
    @objc func didSelectOpenSkinGallery() {
        SkinGalleryWindowController.shared.show(
            currentScale: window.currentScale,
            onApply: { [weak self] skin, name in
                self?.applyCustomSkin(skin, name: name)
            },
            onScaleChange: { [weak self] newScale in
                self?.window.setScale(newScale)
                self?.statusItem?.menu = self?.buildContextMenu()
            }
        )
    }

    private func applyCustomSkin(_ skin: SkinTexture, name: String) {
        self.currentCustomSkinName = name
        self.baseSkinTexture = skin
        self.currentSkinFilterName = "원본 (Original)"
        window.characterView.characterNode.applySkin(skin)
        statusItem?.menu = buildContextMenu()
    }


    // MARK: - Skin Filter Action
    @objc func didSelectSkinFilter(_ sender: NSMenuItem) {
        guard let filterName = sender.representedObject as? String else { return }
        guard let base = baseSkinTexture else { return }
        self.currentSkinFilterName = filterName

        var adjusted: SkinTexture?
        switch filterName {
        case "🌈 색조 회전 +90°":
            adjusted = base.withColorAdjustment(hueAngle: CGFloat.pi / 2.0)
        case "🌈 색조 반전 +180°":
            adjusted = base.withColorAdjustment(hueAngle: CGFloat.pi)
        case "🌈 네온 틴트 +270°":
            adjusted = base.withColorAdjustment(hueAngle: CGFloat.pi * 1.5, saturation: 1.3, brightness: 0.04)
        case "⬛ 흑백 레트로 (Grayscale)":
            adjusted = base.withColorAdjustment(saturation: 0.0)
        case "✨ 선명한 비비드 (Vivid)":
            adjusted = base.withColorAdjustment(saturation: 1.8, brightness: 0.02)
        default:
            adjusted = base
        }

        if let finalSkin = adjusted {
            window.characterView.characterNode.applySkin(finalSkin)
            SoundAndEffectsManager.shared.play(.pop)
        }
        statusItem?.menu = buildContextMenu()
    }

    @objc func didToggleEnchantmentGlint(_ sender: NSMenuItem) {
        window.characterView.characterNode.isEnchantedGlintEnabled.toggle()
        sender.state = window.characterView.characterNode.isEnchantedGlintEnabled ? .on : .off
        statusItem?.menu = buildContextMenu()
        SoundAndEffectsManager.shared.play(.heart)
    }

    @objc func didToggleBatteryHunger(_ sender: NSMenuItem) {
        isBatteryHungerEnabled.toggle()
        sender.state = isBatteryHungerEnabled ? .on : .off
        statusItem?.menu = buildContextMenu()
        SoundAndEffectsManager.shared.play(.pop)
    }

    @objc func didTogglePowerMode(_ sender: NSMenuItem) {
        isPowerModeEnabled.toggle()
        sender.state = isPowerModeEnabled ? .on : .off
        if !isPowerModeEnabled {
            window.characterView.characterNode.applyPowerStage(0)
        }
        statusItem?.menu = buildContextMenu()
        SoundAndEffectsManager.shared.play(.pop)
    }

    @objc func didSelectBrightnessLevel(_ sender: NSMenuItem) {
        if let lvl = sender.representedObject as? Double {
            setStageBrightness(lvl, sender: sender)
        }
    }

    @objc func didSetBrightnessDark(_ sender: NSMenuItem) {
        setStageBrightness(StageBrightness.dark, sender: sender)
    }

    @objc func didSetBrightnessNormal(_ sender: NSMenuItem) {
        setStageBrightness(StageBrightness.normal, sender: sender)
    }

    @objc func didSetBrightnessBright(_ sender: NSMenuItem) {
        setStageBrightness(StageBrightness.bright, sender: sender)
    }

    private func setStageBrightness(_ preset: Double, sender: NSMenuItem) {
        StageBrightness.level = preset
        sender.state = .on
        statusItem?.menu = buildContextMenu()
        SoundAndEffectsManager.shared.play(.pop)
        applyStageBrightnessToAllViews()
    }

    @objc func didToggleLightingEffect(_ sender: NSMenuItem) {
        StageBrightness.isLightingEffectEnabled.toggle()
        sender.state = StageBrightness.isLightingEffectEnabled ? .on : .off
        statusItem?.menu = buildContextMenu()
        SoundAndEffectsManager.shared.play(.pop)
        applyStageBrightnessToAllViews()
        let desc = StageBrightness.isLightingEffectEnabled ? "✨ 3D 입체 광원 효과 켜짐" : "🧱 클래식 복셀 광원 (기본)"
        window.characterView.characterNode.showOverheadEmoji(desc, duration: 2.0)
    }

    private func applyStageBrightnessToAllViews() {
        if let scene = window.characterView.scene {
            StageBrightness.apply(to: scene)
        }
        for buddy in buddyWindows {
            if let scene = buddy.characterView.scene {
                StageBrightness.apply(to: scene)
            }
        }
        if let scene = petWindow?.petView.scene {
            StageBrightness.apply(to: scene)
        }
        if let scene = wildWolfWindow?.petView.scene {
            StageBrightness.apply(to: scene)
        }
        if let scene = wildHorseWindow?.petView.scene {
            StageBrightness.apply(to: scene)
        }
        if let scene = babyPetWindow?.petView.scene {
            StageBrightness.apply(to: scene)
        }
        if let scene = creeperWindow?.creeperView.scene {
            StageBrightness.apply(to: scene)
        }
        if let scene = endermanWindow?.endermanView.scene {
            StageBrightness.apply(to: scene)
        }
        if let scene = skeletonWindow?.skeletonView.scene {
            StageBrightness.apply(to: scene)
        }
        StageBrightness.applyToAll()
    }
    @objc func didSelectBehaviorMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? BehaviorMode else { return }
        behavior.mode = mode
        statusItem?.menu = buildContextMenu()
    }

    @objc func didSelectScale(_ sender: NSMenuItem) {
        guard let scale = sender.representedObject as? CGFloat else { return }
        window.setScale(scale)
        statusItem?.menu = buildContextMenu()
    }

    @objc func didSelectCustomScale() {
        let alert = NSAlert()
        alert.messageText = "캐릭터 크기 직접 입력"
        alert.informativeText = "원하는 크기 배율을 퍼센트(%) 단위의 숫자로 입력하세요.\n(추천 범위: 30% ~ 300%)"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "적용")
        alert.addButton(withTitle: "취소")

        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 24))
        let currentPct = Int(round(window.currentScale * 100))
        input.stringValue = "\(currentPct)"
        input.placeholderString = "예: 120"
        alert.accessoryView = input

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            let rawText = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "%", with: "")
            if let num = Double(rawText), num > 0 {
                let clamped = max(20.0, min(400.0, num))
                let scale = CGFloat(clamped / 100.0)
                window.setScale(scale)
                statusItem?.menu = buildContextMenu()
            }
        }
    }

    @objc func didSelectJump() {
        physics.jump(impulse: 500)
    }

    // MARK: - TNT (앱 창 폭파)
    func canStartTNTBreak() -> Bool {
        guard !isBreakInProgress,
              let platform = physics?.currentPlatform,
              case .window(_, _, let ownerPid) = platform.kind,
              ownerPid != getpid() else { return false }
        return true
    }

    @objc func didSelectTNTBreak() {
        guard canStartTNTBreak(),
              let platform = physics.currentPlatform,
              case .window(let windowID, _, let ownerPid) = platform.kind else { return }

        // 1. 대상 앱의 모든 창 수집 (캐릭터가 서 있는 창 포함)
        var windows = ScreenEnvironment.shared.windowsForApp(pid: ownerPid)
        guard !windows.isEmpty else { return }
        if !windows.contains(where: { $0.id == windowID }),
           let targetFrame = ScreenEnvironment.shared.windowCocoaFrame(windowID: windowID) {
            windows.insert((windowID, targetFrame), at: 0)
        }
        if windows.count > 12 {
            // 창이 너무 많으면 12개까지만 (캐릭터가 서 있는 창 우선)
            windows = Array(windows.prefix(12))
            if !windows.contains(where: { $0.id == windowID }),
               let targetFrame = ScreenEnvironment.shared.windowCocoaFrame(windowID: windowID) {
                windows[windows.count - 1] = (windowID, targetFrame)
            }
        }
        let screen = ScreenEnvironment.shared.screen(for: physics.position)

        // 2. 모든 창 위에 폭파 연출 오버레이 생성
        //    동시에 폭발하는 창들이 파편 예산을 나눠 쓴다 (파편 수 = 프레임당 그리기 비용)
        let debrisShare = max(BlockBreakOverlayWindow.minimumDebrisPerWindow,
                              BlockBreakOverlayWindow.debrisBudgetTotal / max(1, windows.count))
        var overlays: [BlockBreakOverlayWindow] = []
        for info in windows {
            let overlay = BlockBreakOverlayWindow(over: info.frame, on: screen, debrisBudget: debrisShare)
            overlay.onBreakFinished = { [weak self, weak overlay] in
                guard let self = self else { return }
                self.breakOverlays.removeAll { $0 === overlay }
                if self.breakOverlays.isEmpty {
                    self.isBreakInProgress = false
                }
            }
            overlay.orderFrontRegardless()
            overlays.append(overlay)
        }
        breakOverlays = overlays
        isBreakInProgress = true

        // 3. TNT 설치 → 점화 → 도화선 4초(마인크래프트 표준) → 전 창 동시 폭발
        let started = behavior.startTNTPlacement(
            on: platform,
            fuse: 4.0,
            onPlaced: { [weak self] point in
                // 창 표면에 놓인 TNT 블록을 화면 공간에 표시
                guard let self = self else { return }
                self.tntPlacementPoint = point
                let entity = TNTEntityWindow(at: point)
                entity.orderFrontRegardless()
                self.tntEntityWindow = entity
            },
            completion: { [weak self] endedOn in
                guard let self = self else { return }
                self.tntEntityWindow?.close()
                self.tntEntityWindow = nil

                if endedOn != nil {
                    // 4. 폭발! 대상 앱 종료 + 폭발음 + 모든 창이 동시에 블록 파편으로 비산
                    if let app = NSRunningApplication(processIdentifier: ownerPid) {
                        app.terminate()
                    }
                    SoundAndEffectsManager.shared.play(.explode)
                    for overlay in self.breakOverlays {
                        overlay.explode(at: self.tntPlacementPoint)
                    }
                } else {
                    // 중단(드래그/낙하) → 연출 취소
                    for overlay in self.breakOverlays {
                        overlay.cancel()
                    }
                    self.breakOverlays = []
                    self.isBreakInProgress = false
                }
            }
        )
        if !started {
            for overlay in breakOverlays {
                overlay.cancel()
            }
            breakOverlays = []
            isBreakInProgress = false
        }
    }

    private func syncTNT() {
        guard let progress = behavior.tntProgress else { return }
        for overlay in breakOverlays {
            overlay.showFuse(progress: progress)
        }
        tntEntityWindow?.setFuseProgress(progress)
    }

    /// 등반 스냅샷에 맞춰 사다리 오버레이를 생성/갱신/정리한다
    private func syncLadderOverlay() {
        guard let snapshot = behavior.climbSnapshot else {
            if let overlay = ladderOverlay {
                overlay.retire()
                ladderOverlay = nil
            }
            return
        }

        if let overlay = ladderOverlay {
            overlay.update(ladderRect: snapshot.ladderRect)
        } else {
            let overlay = LadderOverlayWindow(ladderRect: snapshot.ladderRect)
            overlay.update(ladderRect: snapshot.ladderRect)
            overlay.orderFrontRegardless()
            ladderOverlay = overlay
        }
    }

    @objc func didSelectResetFloor() {
        let mainScreen = NSScreen.main ?? NSScreen.screens[0]
        physics.position = CGPoint(
            x: mainScreen.frame.midX,
            y: mainScreen.visibleFrame.minY + 20
        )
        physics.velocity = .zero
    }

    @objc func didSelectCheckForUpdates() {
        UpdateManager.shared.checkForUpdates(manual: true)
    }

    public func rebuildContextMenu() {
        self.statusItem?.menu = buildContextMenu()
    }

    @objc func didSelectQuit() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Mini Steve Pixel Icon for Status Bar
    private func makeMiniSteveIcon() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()

        // 8x8 Steve face scaled into 16x16 with 1pt border
        let facePixels: [[UInt32]] = [
            // Hair row 1
            [0x452A14, 0x452A14, 0x452A14, 0x452A14, 0x452A14, 0x452A14, 0x452A14, 0x452A14],
            // Hair row 2
            [0x452A14, 0x452A14, 0x452A14, 0x452A14, 0x452A14, 0x452A14, 0x452A14, 0x452A14],
            // Forehead
            [0x452A14, 0xC48E6C, 0xC48E6C, 0xC48E6C, 0xC48E6C, 0xC48E6C, 0xC48E6C, 0x452A14],
            // Eyes
            [0xC48E6C, 0xFFFFFF, 0x3B43A3, 0xC48E6C, 0xC48E6C, 0x3B43A3, 0xFFFFFF, 0xC48E6C],
            // Nose
            [0xC48E6C, 0xC48E6C, 0xC48E6C, 0x9E6E53, 0x9E6E53, 0xC48E6C, 0xC48E6C, 0xC48E6C],
            // Mouth / Beard
            [0xC48E6C, 0xC48E6C, 0x452A14, 0x452A14, 0x452A14, 0x452A14, 0xC48E6C, 0xC48E6C],
            // Chin
            [0xC48E6C, 0x452A14, 0xC48E6C, 0xC48E6C, 0xC48E6C, 0xC48E6C, 0x452A14, 0xC48E6C],
            // Neck
            [0x452A14, 0x452A14, 0xC48E6C, 0xC48E6C, 0xC48E6C, 0xC48E6C, 0x452A14, 0x452A14],
        ]

        let pixelSize: CGFloat = 2.0
        let startX: CGFloat = 1.0
        let startY: CGFloat = 1.0

        for row in 0..<8 {
            for col in 0..<8 {
                let hex = facePixels[7 - row][col]
                let r = CGFloat((hex >> 16) & 0xFF) / 255.0
                let g = CGFloat((hex >> 8) & 0xFF) / 255.0
                let b = CGFloat(hex & 0xFF) / 255.0
                let color = NSColor(red: r, green: g, blue: b, alpha: 1.0)
                color.setFill()

                let rect = NSRect(
                    x: startX + CGFloat(col) * pixelSize,
                    y: startY + CGFloat(row) * pixelSize,
                    width: pixelSize,
                    height: pixelSize
                )
                rect.fill()
            }
        }

        img.unlockFocus()
        img.isTemplate = false
        return img
    }

    // MARK: - New Interaction Action Handlers
    @objc func didSelectHeldItem(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? HeldItem else { return }
        window.characterView.characterNode.currentHeldItem = item
        statusItem?.menu = buildContextMenu()
        SoundAndEffectsManager.shared.play(.pop)
    }

    @objc func didSelectDayNightMode(_ sender: NSMenuItem) {
        guard let mode = sender.representedObject as? DayNightMode else { return }
        DayNightCycleManager.shared.mode = mode
        DayNightCycleManager.shared.refresh()
        statusItem?.menu = buildContextMenu()
    }

    @objc func didToggleSoundSFX(_ sender: NSMenuItem) {        SoundAndEffectsManager.shared.isSoundEnabled.toggle()
        sender.state = SoundAndEffectsManager.shared.isSoundEnabled ? .on : .off
        statusItem?.menu = buildContextMenu()
    }

    @objc func didSelectBackflip() {
        behavior.triggerBackflip(physics: physics, characterNode: window.characterView.characterNode)
    }

    @objc func didSelectSneakDance() {
        behavior.triggerSneakDance(characterNode: window.characterView.characterNode)
    }

    @objc func didSelectWave() {
        behavior.triggerWave(characterNode: window.characterView.characterNode)
    }

    @objc func didSelectPlaceAndMine() {
        behavior.triggerPlaceAndMine(characterNode: window.characterView.characterNode)
    }

    @objc func didSelectEating() {
        behavior.triggerEating(characterNode: window.characterView.characterNode)
    }

    @objc func didSelectSleep() {
        behavior.triggerSleep(characterNode: window.characterView.characterNode)
    }

    @objc func didSelectSitOnMenuBar() {
        behavior.triggerSitOnMenuBar(physics: physics, characterNode: window.characterView.characterNode)
    }

    @objc func didSelectCheer() {
        behavior.triggerCheer(characterNode: window.characterView.characterNode)
    }

    @objc func didToggleTypingCheer(_ sender: NSMenuItem) {
        TypingActivityMonitor.shared.isEnabled.toggle()
        sender.state = TypingActivityMonitor.shared.isEnabled ? .on : .off
        statusItem?.menu = buildContextMenu()
    }

    @objc func didSelectNag() {
        behavior.triggerNag(characterNode: window.characterView.characterNode)
    }

    /// 감정 표현(장식 모션) 실행 — 메뉴·자율 행동이 공유하는 단일 진입점
    public func runEmote(_ kind: CharacterEmote) {
        behavior.triggerEmote(kind, characterNode: window.characterView.characterNode)
    }

    @objc func didToggleNotificationNag(_ sender: NSMenuItem) {
        NotificationCenterMonitor.shared.isEnabled.toggle()
        sender.state = NotificationCenterMonitor.shared.isEnabled ? .on : .off
        statusItem?.menu = buildContextMenu()
    }


    // MARK: - Pet Companion (펫 동반자 시스템)
    public func summonPet(kind: PetKind) {
        self.currentPetKind = kind
        if petWindow == nil {
            let pw = PetWindow(kind: kind)
            pw.petView.petDelegate = self
            self.petWindow = pw
            let spawnX = physics.position.x - 70
            let pPhys = PhysicsEngine(initialPosition: CGPoint(x: spawnX, y: physics.position.y))
            self.petPhysics = pPhys
            self.petBehavior = PetBehaviorController()
            pw.setFeetPosition(x: spawnX, y: physics.position.y)
            pw.orderFrontRegardless()
        } else {
            petWindow?.petView.petNode.setKind(kind)
        }
        petWindow?.petView.petNode.showOverheadEmoji("✨", duration: 1.8)
        SoundAndEffectsManager.shared.play(.heart)
    }

    public func dismissPet() {
        self.currentPetKind = nil
        petWindow?.orderOut(nil)
        petWindow = nil
        petPhysics = nil
        petBehavior = nil
        SoundAndEffectsManager.shared.play(.pop)
    }

    @objc func didSelectPetKind(_ sender: NSMenuItem) {
        guard let kind = sender.representedObject as? PetKind else { return }
        summonPet(kind: kind)
        statusItem?.menu = buildContextMenu()
    }

    @objc func didSelectDismissPet() {
        dismissPet()
        statusItem?.menu = buildContextMenu()
    }

    @objc func didSelectFeedPet() {
        guard let pw = petWindow else { return }
        if window.characterView.characterNode.currentHeldItem == .wheat {
            feedWheatToPet()
            return
        }
        pw.petView.petNode.feed()
        window.characterView.characterNode.showOverheadEmoji("🦴 냠냠 맛있게 먹어!", duration: 2.0)
    }

    private var wheatFeedCount: Int = 0
    private var babyPetWindow: PetWindow?
    private var babyGrowTimer: TimeInterval = 0

    private func feedWheatToPet() {
        guard let pw = petWindow, let kind = currentPetKind else { return }
        wheatFeedCount += 1
        pw.petView.petNode.showOverheadEmoji("💕🌾", duration: 1.6)
        SoundAndEffectsManager.shared.play(.heart)
        if wheatFeedCount >= 2 {
            wheatFeedCount = 0
            spawnBabyPet(kind: kind)
        } else {
            window.characterView.characterNode.showOverheadEmoji("🌾 한 번 더 먹이자!", duration: 1.8)
        }
    }

    private func spawnBabyPet(kind: PetKind) {
        guard babyPetWindow == nil, let screen = NSScreen.main else { return }
        let bw = PetWindow(kind: kind)
        bw.setScale(0.5)
        bw.setFeetPosition(x: physics.position.x - 40, y: physics.position.y)
        bw.orderFrontRegardless()
        babyPetWindow = bw
        babyGrowTimer = 60.0
        bw.petView.petNode.showOverheadEmoji("🍼 아기가 태어났다!", duration: 2.5)
        window.characterView.characterNode.showOverheadEmoji("🍼 아기가 태어났다!", duration: 2.5)
        SoundAndEffectsManager.shared.play(.heart)
    }

    private func updateBabyPet(dt: TimeInterval) {
        guard let bw = babyPetWindow else { return }
        babyGrowTimer -= dt
        bw.setFeetPosition(x: physics.position.x - 40, y: physics.position.y)
        if babyGrowTimer <= 0 {
            bw.setScale(1.0)
            bw.petView.petNode.showOverheadEmoji("🎉 쑥쑥 성장!", duration: 2.0)
            babyGrowTimer = -3.0
        } else if babyGrowTimer < -3.0 {
            bw.close()
            babyPetWindow = nil
        }
    }

    // MARK: - PetViewDelegate
    public func petViewDidClick(_ view: PetView) {
        if let ww = wildWolfWindow, view === ww.petView {
            handleWildWolfClicked(view)
            return
        }
        if let wh = wildHorseWindow, view === wh.petView {
            handleWildHorseClicked(view)
            return
        }
        if window.characterView.characterNode.currentHeldItem == .wheat {
            feedWheatToPet()
            return
        }
        if window.characterView.characterNode.currentHeldItem == .bone || view.petNode.wolfHealth < 0.95 {
            view.petNode.feed()
            window.characterView.characterNode.showOverheadEmoji("🦴 냠냠!", duration: 1.8)
            return
        }
        petBehavior?.handlePetClicked(petNode: view.petNode)
    }

    public func petViewDidStartDrag(_ view: PetView, at screenPoint: CGPoint) {
        petPhysics?.setDragged(at: screenPoint)
    }

    public func petViewDidDrag(_ view: PetView, to screenPoint: CGPoint) {
        petPhysics?.setDragged(at: screenPoint)
    }

    public func petViewDidEndDrag(_ view: PetView, throwVelocity: CGPoint) {
        petPhysics?.releaseDrag(throwVelocity: throwVelocity)
    }

    // MARK: - Creeper Combat & Spawning (크리퍼 전투 및 소환)
    public func spawnCreeper(legType requestedType: CreeperLegType? = nil) {
        if creeperWindow != nil {
            despawnCreeper()
        }
        let resolvedType: CreeperLegType = requestedType ?? preferredCreeperLegType ?? (Bool.random() ? .quadruped : .biped)
        let cw = CreeperWindow(legType: resolvedType)
        cw.creeperView.creeperDelegate = self
        self.creeperWindow = cw

        // Spawn on the current platform or ~260pt away
        let spawnDir: CGFloat = Bool.random() ? 1.0 : -1.0
        let spawnX = physics.position.x + (spawnDir * 260.0)
        let cPhys = PhysicsEngine(initialPosition: CGPoint(x: spawnX, y: physics.position.y))
        self.creeperPhysics = cPhys
        self.creeperBehavior = CreeperBehaviorController()

        cw.setFeetPosition(x: spawnX, y: physics.position.y)
        cw.orderFrontRegardless()

        if resolvedType == .biped {
            cw.creeperView.creeperNode.showOverheadEmoji("👾 2족 크리퍼 출현!", duration: 1.8)
        } else {
            cw.creeperView.creeperNode.showOverheadEmoji("👾 나타났다!", duration: 1.8)
        }
        SoundAndEffectsManager.shared.play(.alert)

        // 플레이어 살기 감지 대사 출력
        let warningQuotes: [String]
        if resolvedType == .biped {
            warningQuotes = [
                "저 크리퍼... 왜 두 발로 걷고 있어?! 😱",
                "2족 보행 크리퍼다! 뭔가 기괴해! 💥",
                "두 발로 성큼성큼 다가온다! 조심해! 👀",
                "저주받은 2족 크리퍼 출현?! 무기 들어! ⚔️"
            ]
        } else {
            warningQuotes = [
                "등골이 서늘한데...? 살기가 느껴져! 😨",
                "불길한 기운이 감돈다... 크리퍼인가?! ⚠️",
                "뒤에서 바스락거리는 소리가 들렸어! 💢",
                "크리퍼 냄새가 나는데... 어디지?! 👃",
                "잠깐... 불길한 시선이 느껴져! 👀",
                "살기 감지! 무기 들 준비 해! ⚔️"
            ]
        }
        let quote = warningQuotes.randomElement() ?? warningQuotes[0]
        window.characterView.characterNode.showOverheadEmoji(quote, duration: 3.0)

        // 소환된 펫이 있다면 펫도 위협을 감지하고 반응!
        if let petNode = petWindow?.petView.petNode {
            let petReaction: String
            switch petNode.kind {
            case .wolf: petReaction = "으르렁...! 🐺"
            case .cat: petReaction = "하악질! 😾"
            case .parrot: petReaction = "비상! 비상! 🦜"
            case .pig: petReaction = "꿀꿀?! 🐷"
            case .horse: petReaction = "푸르릉! 🐴"
            }
            petNode.showOverheadEmoji(petReaction, duration: 2.5)
        }
    }

    public func despawnCreeper() {
        creeperWindow?.orderOut(nil)
        creeperWindow = nil
        creeperPhysics = nil
        creeperBehavior = nil
    }

    public func attackCreeperWithCurrentWeapon() {
        guard let cw = creeperWindow,
              let cPhys = creeperPhysics,
              let cBehav = creeperBehavior,
              cBehav.isAlive else { return }

        // Face towards Creeper
        let dx = cPhys.position.x - physics.position.x
        window.characterView.characterNode.modelRoot.eulerAngles.y = dx >= 0 ? (CGFloat.pi / 2.0) : (-CGFloat.pi / 2.0)

        // Trigger attack animation on player
        window.characterView.characterNode.isAttackingWeapon = true
        player.playerAttackTimer = 0.35

        let weapon = window.characterView.characterNode.currentHeldItem
        let weaponSpec = MinecraftCharacterNode.spec(for: weapon)
        var damage = weaponSpec.damage
        var playerEmoji = weaponSpec.hitEmoji

        if weapon == .diamondSword && player.swordSharpness > 0 {
            damage += min(player.swordSharpness, 3)
            playerEmoji += " ✨날카로움!"
        }
        if weapon == .diamondPickaxe && player.pickaxeEfficiency > 0 {
            damage += min(player.pickaxeEfficiency, 2)
            playerEmoji += " ✨효율!"
        }
        if player.strengthTimer > 0 {
            damage += 2
            playerEmoji += " 💪힘!"
        }
        if axolotlWindow != nil {
            damage += 1
            playerEmoji += " 🦎엄호!"
            axolotlAssist()
        }

        window.characterView.characterNode.showOverheadEmoji(playerEmoji, duration: 1.2)

        cBehav.applyDamage(
            damage,
            fromPlayerAt: physics.position,
            weapon: weapon,
            creeperPhysics: cPhys,
            creeperNode: cw.creeperView.creeperNode,
            onDefeated: { [weak self] in
                self?.handleCreeperDefeated(with: weapon)
            }
        )

        if !cBehav.isAlive {
            window.characterView.characterNode.isAttackingWeapon = false
        }
    }

    private func handleCreeperExploded(at blastPos: CGPoint) {
        let charNode = window.characterView.characterNode
        let isGuarding = charNode.isShieldEquipped && (charNode.isSneaking || charNode.isGuarding)

        if isGuarding {
            // 원작 고증: 방패로 가드 시 100% 폭발 피해 및 넉백 완벽 방어!
            charNode.showOverheadEmoji("🛡️ 챙-! 완벽 방어!", duration: 2.5)
            SoundAndEffectsManager.shared.play(.pop)
        } else if consumeTotemIfEquipped() {
            // M2: 불사의 토템이 치명타를 대신 받고 부활 (넉백 취소)
        } else {
            let dx = physics.position.x - blastPos.x
            let blastDir: CGFloat = dx >= 0 ? 1.0 : -1.0
            if creeperCharged {
                physics.launch(vx: blastDir * 880.0, vy: 590.0)
                charNode.showOverheadEmoji("⚡💥 충전 폭발!", duration: 2.2)
            } else {
                physics.launch(vx: blastDir * 550.0, vy: 420.0)
                charNode.showOverheadEmoji("💥 으악!", duration: 2.0)
            }
        }
        creeperCharged = false

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            self?.despawnCreeper()
        }
    }

    private func handleCreeperDefeated(with weapon: HeldItem) {
        let quotes = MinecraftCharacterNode.spec(for: weapon).victoryQuotes ?? [
            "이 구역의 평화는 내가 지킨다! 🛡️",
            "어딜 감히 내 데스크톱에 얼씬거려! 👊",
            "휴, 터지기 전에 컷! 나 좀 멋진 듯? 😎"
        ]
        let victoryQuote = quotes.randomElement() ?? quotes[0]

        // 승리의 포즈 및 멋진 대사 출력
        player.playerXP += 5
        AdvancementManager.shared.unlock(.creeperKill)
        window.characterView.characterNode.showOverheadEmoji("\(victoryQuote) +5XP!", duration: 3.2)
        SoundAndEffectsManager.shared.play(.heart)

        // 승리의 기쁨 점프
        physics.jump(impulse: 340)

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.despawnCreeper()
        }
    }

    @objc func didSelectSpawnCreeper() {
        spawnCreeper()
    }

    @objc func didSelectSpawnQuadCreeper() {
        spawnCreeper(legType: .quadruped)
    }

    @objc func didSelectSpawnBipedCreeper() {
        spawnCreeper(legType: .biped)
    }

    @objc func didSelectCreeperLegPreference(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String {
            if raw == "random" {
                preferredCreeperLegType = nil
            } else if let type = CreeperLegType(rawValue: raw) {
                preferredCreeperLegType = type
            }
        }
        statusItem?.menu = buildContextMenu()
    }

    @objc func didToggleCreeperSpawn(_ sender: NSMenuItem) {
        isCreeperSpawnEnabled.toggle()
        sender.state = isCreeperSpawnEnabled ? .on : .off
        statusItem?.menu = buildContextMenu()
    }

    @objc func didToggleElytra(_ sender: NSMenuItem) {
        window.characterView.characterNode.isElytraEquipped.toggle()
        sender.state = window.characterView.characterNode.isElytraEquipped ? .on : .off
        statusItem?.menu = buildContextMenu()
        SoundAndEffectsManager.shared.play(.pop)
    }

    // MARK: - CreeperViewDelegate
    public func creeperViewDidClick(_ view: CreeperView) {
        attackCreeperWithCurrentWeapon()
    }

    public func creeperViewDidStartDrag(_ view: CreeperView, at screenPoint: CGPoint) {
        creeperPhysics?.setDragged(at: screenPoint)
    }

    public func creeperViewDidDrag(_ view: CreeperView, to screenPoint: CGPoint) {
        creeperPhysics?.setDragged(at: screenPoint)
    }

    public func creeperViewDidEndDrag(_ view: CreeperView, throwVelocity: CGPoint) {
        creeperPhysics?.releaseDrag(throwVelocity: throwVelocity)
    }

    // MARK: - Enderman Combat & Spawning (엔더맨 시선 마주침 & 소환)
    public func spawnEnderman() {
        guard endermanWindow == nil else { return }
        let ew = EndermanWindow()
        ew.endermanView.endermanDelegate = self
        self.endermanWindow = ew

        let spawnDir: CGFloat = Bool.random() ? 1.0 : -1.0
        let spawnX = physics.position.x + (spawnDir * 280.0)
        let ePhys = PhysicsEngine(initialPosition: CGPoint(x: spawnX, y: physics.position.y))
        self.endermanPhysics = ePhys
        self.endermanBehavior = EndermanBehaviorController()

        ew.setFeetPosition(x: spawnX, y: physics.position.y)
        ew.orderFrontRegardless()
        ew.endermanView.endermanNode.showOverheadEmoji("👁️ 블록 들고 배회 중...", duration: 2.0)
        SoundAndEffectsManager.shared.play(.pop)
    }

    public func despawnEnderman() {
        endermanWindow?.orderOut(nil)
        endermanWindow = nil
        endermanPhysics = nil
        endermanBehavior = nil
    }

    public func attackEndermanWithCurrentWeapon() {
        guard let ew = endermanWindow,
              let ePhys = endermanPhysics,
              let eBehav = endermanBehavior,
              eBehav.isAlive else { return }

        let screen = ScreenEnvironment.shared.screen(for: physics.position)
        let dx = ePhys.position.x - physics.position.x
        window.characterView.characterNode.modelRoot.eulerAngles.y = dx >= 0 ? (CGFloat.pi / 2.0) : (-CGFloat.pi / 2.0)

        window.characterView.characterNode.isAttackingWeapon = true
        player.playerAttackTimer = 0.35

        let weapon = window.characterView.characterNode.currentHeldItem
        var damage = weapon == .diamondSword ? 3 : (weapon == .diamondPickaxe ? 2 : 1)
        if axolotlWindow != nil {
            damage += 1
            axolotlAssist()
        }
        window.characterView.characterNode.showOverheadEmoji("⚔️ 엔더맨 타격!", duration: 1.2)

        eBehav.applyDamage(
            damage,
            fromPlayerAt: physics.position,
            weapon: weapon,
            endermanPhysics: ePhys,
            endermanNode: ew.endermanView.endermanNode,
            screen: screen,
            onDefeated: { [weak self] in
                self?.handleEndermanDefeated()
            }
        )

        if !eBehav.isAlive {
            window.characterView.characterNode.isAttackingWeapon = false
        }
    }

    // MARK: - Skeleton Archer & Combat (스켈레톤 활 쏘기 & 전투)
    public func spawnSkeleton() {
        guard skeletonWindow == nil else { return }
        let sw = SkeletonWindow()
        sw.skeletonView.skeletonDelegate = self
        self.skeletonWindow = sw

        let spawnDir: CGFloat = Bool.random() ? 1.0 : -1.0
        let spawnX = physics.position.x + (spawnDir * 290.0)
        let sPhys = PhysicsEngine(initialPosition: CGPoint(x: spawnX, y: physics.position.y))
        self.skeletonPhysics = sPhys
        self.skeletonBehavior = SkeletonBehaviorController()

        sw.setFeetPosition(x: spawnX, y: physics.position.y)
        sw.orderFrontRegardless()
        sw.skeletonView.skeletonNode.showOverheadEmoji("🏹 딸깍딸깍...", duration: 1.8)
        SoundAndEffectsManager.shared.play(.alert)
    }

    public func despawnSkeleton() {
        skeletonAggroTimer = 0
        skeletonWindow?.orderOut(nil)
        skeletonWindow = nil
        skeletonPhysics = nil
        skeletonBehavior = nil
    }

    private func launchArrowFromSkeleton(from startPos: CGPoint, to targetPos: CGPoint) {
        let arrow = ArrowEntityWindow(
            startPos: startPos,
            targetPos: targetPos,
            checkGuarding: { [weak self] in
                guard let self = self else { return false }
                let char = self.window.characterView.characterNode
                return char.isShieldEquipped && (char.isSneaking || char.isGuarding)
            },
            onHit: { [weak self] isDeflected in
                guard let self = self else { return }
                let char = self.window.characterView.characterNode
                if isDeflected {
                    char.showOverheadEmoji("🛡️ 챙-! 화살 방어! 돌격-! ⚔️", duration: 1.8)
                    SoundAndEffectsManager.shared.play(.pop)
                } else {
                    char.showOverheadEmoji("💢 감히 날 쏴?! 돌격-! ⚔️", duration: 1.8)
                    self.physics.launch(vx: (self.physics.position.x >= startPos.x ? 70 : -70), vy: 40)
                }

                // 화살 피격 시 적극적 공격/추격 모드 발동
                self.triggerAggressiveSkeletonAttack()
            }
        )
        activeArrows.append(arrow)
        arrow.launch()
    }

    /// 스켈레톤 화살 피격 시 다이아몬드 검 장착 및 고속 돌격 개시
    private func triggerAggressiveSkeletonAttack() {
        guard let sPhys = skeletonPhysics, let sBehav = skeletonBehavior, sBehav.isAlive else { return }

        let char = window.characterView.characterNode
        // 1. 비무장 시 다이아몬드 검 즉시 발도
        let currentWeapon = char.currentHeldItem
        let isWeapon = (currentWeapon == .diamondSword || currentWeapon == .axe || currentWeapon == .trident || currentWeapon == .diamondPickaxe || currentWeapon == .bow)
        if !isWeapon {
            char.currentHeldItem = .diamondSword
        }

        // 2. 적극적 공격 타이머 활성화 (8초 동안 맹렬히 추격)
        skeletonAggroTimer = 8.0
        SoundAndEffectsManager.shared.play(.whoosh)

        // 3. 즉시 스켈레톤 방향으로 돌격 개시
        behavior.chargeAt(targetX: sPhys.position.x, speed: 220.0, duration: 0.8, physics: physics, characterNode: char)
    }

    public func attackSkeletonWithCurrentWeapon() {
        guard let sw = skeletonWindow,
              let sPhys = skeletonPhysics,
              let sBehav = skeletonBehavior,
              sBehav.isAlive else { return }

        let dx = sPhys.position.x - physics.position.x
        window.characterView.characterNode.modelRoot.eulerAngles.y = dx >= 0 ? (CGFloat.pi / 2.0) : (-CGFloat.pi / 2.0)

        window.characterView.characterNode.isAttackingWeapon = true
        player.playerAttackTimer = 0.35

        let weapon = window.characterView.characterNode.currentHeldItem
        var damage = weapon == .diamondSword ? 3 : (weapon == .diamondPickaxe ? 2 : 1)
        if axolotlWindow != nil {
            damage += 1
            axolotlAssist()
        }
        window.characterView.characterNode.showOverheadEmoji("⚔️ 스켈레톤 타격!", duration: 1.2)

        sBehav.applyDamage(
            damage,
            fromPlayerAt: physics.position,
            weapon: weapon,
            skeletonPhysics: sPhys,
            skeletonNode: sw.skeletonView.skeletonNode,
            onDefeated: { [weak self] in
                self?.handleSkeletonDefeated()
            }
        )

        // 스켈레톤이 이번 타격으로 쓰러진 경우 즉시 공격 및 추격 상태 중단
        if !sBehav.isAlive {
            skeletonAggroTimer = 0
            window.characterView.characterNode.isAttackingWeapon = false
            behavior.stopCharging()
        }
    }

    private func handleSkeletonDefeated() {
        skeletonAggroTimer = 0
        player.playerXP += 5
        player.playerEmeralds += 1
        AdvancementManager.shared.unlock(.skeletonKill)
        if isDefenseMode {
            defenseKills += 1
            let needed = 2 + defenseWave
            if defenseKills >= needed {
                defenseKills = 0
                defenseWave += 1
                let bonus = 10 * defenseWave
                player.playerXP += bonus
                window.characterView.characterNode.showOverheadEmoji("🏆 웨이브 \(defenseWave - 1) 격퇴! +\(bonus)XP!", duration: 3.2)
                SoundAndEffectsManager.shared.play(.chime)
                physics.jump(impulse: 420)
            } else {
                window.characterView.characterNode.showOverheadEmoji("🏹 격퇴! (웨이브 \(defenseWave): \(defenseKills)/\(needed)) +5XP!", duration: 3.0)
                SoundAndEffectsManager.shared.play(.heart)
                physics.jump(impulse: 340)
            }
        } else {
            window.characterView.characterNode.showOverheadEmoji("🏹 스켈레톤 컷! +5XP! 🦴", duration: 3.2)
            SoundAndEffectsManager.shared.play(.heart)
            physics.jump(impulse: 340)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.despawnSkeleton()
        }
    }

    // MARK: - Defense (밤 웨이브 디펜스전)
    var isDefenseMode: Bool = false
    var defenseWave: Int = 1
    private var defenseKills: Int = 0

    @objc func didToggleDefenseMode(_ sender: NSMenuItem) {
        isDefenseMode.toggle()
        if isDefenseMode {
            defenseWave = 1
            defenseKills = 0
            window.characterView.characterNode.showOverheadEmoji("🏹 밤을 사수하라! 웨이브 1!", duration: 2.5)
            SoundAndEffectsManager.shared.play(.alert)
        }
        sender.state = isDefenseMode ? .on : .off
        statusItem?.menu = buildContextMenu()
    }

    @objc func didSelectSpawnSkeleton() {
        spawnSkeleton()
    }

    @objc func didToggleSkeletonSpawn(_ sender: NSMenuItem) {
        isSkeletonSpawnEnabled.toggle()
        sender.state = isSkeletonSpawnEnabled ? .on : .off
        statusItem?.menu = buildContextMenu()
    }

    // MARK: - SkeletonViewDelegate
    public func skeletonViewDidClick(_ view: SkeletonView) {
        attackSkeletonWithCurrentWeapon()
    }

    public func skeletonViewDidStartDrag(_ view: SkeletonView, at screenPoint: CGPoint) {
        skeletonPhysics?.setDragged(at: screenPoint)
    }

    public func skeletonViewDidDrag(_ view: SkeletonView, to screenPoint: CGPoint) {
        skeletonPhysics?.setDragged(at: screenPoint)
    }

    public func skeletonViewDidEndDrag(_ view: SkeletonView, throwVelocity: CGPoint) {
        skeletonPhysics?.releaseDrag(throwVelocity: throwVelocity)
    }

    private func handleEndermanDefeated() {
        player.playerXP += 8
        AdvancementManager.shared.unlock(.endermanKill)
        window.characterView.characterNode.showOverheadEmoji("🔮 엔더 진주 +8XP! 대박!", duration: 3.2)
        SoundAndEffectsManager.shared.play(.heart)
        physics.jump(impulse: 340)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.despawnEnderman()
        }
    }

    @objc func didSelectSpawnEnderman() {
        spawnEnderman()
    }

    @objc func didToggleEndermanSpawn(_ sender: NSMenuItem) {
        isEndermanSpawnEnabled.toggle()
        sender.state = isEndermanSpawnEnabled ? .on : .off
        statusItem?.menu = buildContextMenu()
    }

    // MARK: - EndermanViewDelegate
    public func endermanViewDidClick(_ view: EndermanView) {
        attackEndermanWithCurrentWeapon()
    }

    public func endermanViewDidStartDrag(_ view: EndermanView, at screenPoint: CGPoint) {
        endermanPhysics?.setDragged(at: screenPoint)
    }

    public func endermanViewDidDrag(_ view: EndermanView, to screenPoint: CGPoint) {
        endermanPhysics?.setDragged(at: screenPoint)
    }

    public func endermanViewDidEndDrag(_ view: EndermanView, throwVelocity: CGPoint) {
        endermanPhysics?.releaseDrag(throwVelocity: throwVelocity)
    }

    // MARK: - Farming (밀 농사)
    private var cropWindows: [CropEntityWindow] = []
    @objc func didSelectPlantCrop() {
        guard cropWindows.count < 4 else {
            window.characterView.characterNode.showOverheadEmoji("🌱 밭이 꽉 찼어!", duration: 1.6)
            return
        }
        let pos = CGPoint(x: physics.position.x + 70, y: physics.position.y)
        var crop: CropEntityWindow?
        crop = CropEntityWindow(plantPos: pos) { [weak self, weak crop] in
            guard let self = self else { return }
            AdvancementManager.shared.unlock(.firstHarvest)
            if let crop = crop {
                self.cropWindows.removeAll { $0 === crop }
            }
            self.window.characterView.characterNode.currentHeldItem = .wheat
            self.player.playerWheat += 1
            self.window.characterView.characterNode.showOverheadEmoji("🌾 수확! 밀 획득! (밀: \(self.player.playerWheat))", duration: 2.2)
            SoundAndEffectsManager.shared.play(.heart)
        }
        cropWindows.append(crop!)
        crop!.plant()
        window.characterView.characterNode.showOverheadEmoji("🌱 밀 심기!", duration: 1.6)
    }

    private var cropHarvestCooldown: TimeInterval = 0
    private func updateCropsAutoHarvest(dt: TimeInterval) {
        if cropHarvestCooldown > 0 {
            cropHarvestCooldown -= dt
            return
        }
        guard skeletonAggroTimer <= 0, creeperWindow == nil, !behavior.isClimbing else { return }

        // 밀 성숙 확인
        if let matureCrop = cropWindows.first(where: { $0.isMature && $0.isVisible }) {
            handleAutoHarvest(targetPos: matureCrop.plantPos) { matureCrop.harvest() }
            return
        }
        // 감자 성숙 확인
        if let maturePotato = potatoWindows.first(where: { $0.isMature && $0.isVisible }) {
            handleAutoHarvest(targetPos: maturePotato.plantPos) { maturePotato.harvest() }
            return
        }
        // 수박 성숙 확인
        if let matureMelon = melonWindows.first(where: { $0.isMature && $0.isVisible }) {
            handleAutoHarvest(targetPos: matureMelon.plantPos) { matureMelon.harvest() }
            return
        }
        // 호박 성숙 확인
        if let maturePumpkin = pumpkinWindows.first(where: { $0.isMature && $0.isVisible }) {
            handleAutoHarvest(targetPos: maturePumpkin.plantPos) { maturePumpkin.harvest() }
            return
        }
    }

    private func handleAutoHarvest(targetPos: CGPoint, onArrivalHarvest: @escaping () -> Void) {
        let dx = targetPos.x - physics.position.x
        let dy = abs(targetPos.y - physics.position.y)
        let dist = hypot(dx, dy)
        guard dist < 240.0 && dy < 45.0 else { return }

        let char = window.characterView.characterNode
        if dist < 48.0 {
            cropHarvestCooldown = 2.0
            let dir: CGFloat = dx >= 0 ? 1.0 : -1.0
            char.modelRoot.eulerAngles.y = dir > 0 ? (CGFloat.pi / 2.0) : (-CGFloat.pi / 2.0)
            char.isAttackingWeapon = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak char] in
                char?.isAttackingWeapon = false
            }
            onArrivalHarvest()
        } else {
            behavior.chargeAt(targetX: targetPos.x - (dx >= 0 ? 32 : -32), speed: 120.0, duration: 0.3, physics: physics, characterNode: char)
        }
    }

    // MARK: - Taming (야생 늑대 길들이기)
    private var wildWolfWindow: PetWindow?
    private var wildWolfDir: CGFloat = 1
    private var wildWolfFlipTimer: TimeInterval = 0
    @objc func didSelectSpawnWildWolf() {
        if wildWolfWindow != nil { return }
        let ww = PetWindow(kind: .wolf)
        ww.setFeetPosition(x: physics.position.x + 220, y: physics.position.y)
        ww.orderFrontRegardless()
        ww.petView.petDelegate = self
        wildWolfWindow = ww
        wildWolfFlipTimer = 2.0
        ww.petView.petNode.showOverheadEmoji("❓ 야생 늑대다...!", duration: 2.2)
        SoundAndEffectsManager.shared.play(.alert)
    }

    private func updateWildWolf(dt: TimeInterval) {
        guard let ww = wildWolfWindow else { return }
        wildWolfFlipTimer -= dt
        if wildWolfFlipTimer <= 0 {
            wildWolfFlipTimer = Double.random(in: 2.0...4.0)
            wildWolfDir = Bool.random() ? 1 : -1
        }
        let node = ww.petView.petNode
        node.modelRoot.eulerAngles.y = wildWolfDir > 0 ? (CGFloat.pi / 2.0) : (-CGFloat.pi / 2.0)
        node.walkSpeed = 45
        node.isRunning = false
        node.update(deltaTime: CGFloat(dt))
        var frame = ww.frame
        frame.origin.x += wildWolfDir * 45.0 * CGFloat(dt)
        ww.setFrameOrigin(frame.origin)
    }

    private func handleWildWolfClicked(_ view: PetView) {
        guard let ww = wildWolfWindow, view === ww.petView else { return }
        if window.characterView.characterNode.currentHeldItem == .bone {
            window.characterView.characterNode.currentHeldItem = .none
            view.petNode.showOverheadEmoji("❤️❤️❤️ 길들였다!", duration: 2.5)
            AdvancementManager.shared.unlock(.wolfTame)
            SoundAndEffectsManager.shared.play(.heart)
            ww.close()
            wildWolfWindow = nil
            summonPet(kind: .wolf)
            petWindow?.petView.petNode.wolfHealth = 1.0
            window.characterView.characterNode.showOverheadEmoji("🐺 새 가족이다!", duration: 2.2)
            statusItem?.menu = buildContextMenu()
        } else {
            view.petNode.showOverheadEmoji("으르렁! 🐺 (뼈다귀를 들어봐)", duration: 2.0)
            SoundAndEffectsManager.shared.play(.alert)
            wildWolfDir *= -1
        }
    }

    // MARK: - Bees (벌·꿀)
    private var beehiveWindow: BeehiveEntityWindow?
    private var beeWindows: [BeeEntityWindow] = []
    @objc func didSelectBeehive() {
        if let hive = beehiveWindow {
            hive.close()
            beehiveWindow = nil
            for bee in beeWindows { bee.close() }
            beeWindows = []
            return
        }
        let pos = CGPoint(x: physics.position.x - 110, y: physics.position.y)
        let hive = BeehiveEntityWindow(floorPos: pos) { [weak self] in
            guard let self = self else { return }
            self.window.characterView.characterNode.showOverheadEmoji("🍯 달콤해!", duration: 2.2)
            SoundAndEffectsManager.shared.play(.gulp)
        }
        beehiveWindow = hive
        hive.place()
        let offsets = [CGPoint(x: -50, y: 60), CGPoint(x: 10, y: 80), CGPoint(x: 60, y: 55)]
        for offset in offsets {
            let bee = BeeEntityWindow(startPos: CGPoint(x: pos.x + offset.x, y: pos.y + offset.y))
            bee.followOffset = offset
            bee.orderFrontRegardless()
            beeWindows.append(bee)
        }
        window.characterView.characterNode.currentHeldItem = .flower
        window.characterView.characterNode.showOverheadEmoji("🐝 꽃 향기에 벌이 모여든다!", duration: 2.2)
        SoundAndEffectsManager.shared.play(.heart)
    }

    private func updateBees() {
        if let hive = beehiveWindow, !hive.isVisible {
            for bee in beeWindows { bee.close() }
            beeWindows = []
            beehiveWindow = nil
            return
        }
        guard !beeWindows.isEmpty else { return }
        let excited = window.characterView.characterNode.currentHeldItem == .flower
        for bee in beeWindows {
            bee.follow(target: physics.position, excited: excited)
        }
    }

    // MARK: - Horse (야생마 길들이기 & 승마)
    private var wildHorseWindow: PetWindow?
    private var wildHorseDir: CGFloat = 1
    private var wildHorseFlipTimer: TimeInterval = 0
    private var isRidingHorse: Bool = false
    private var rideTimer: TimeInterval = 0
    private var rideDir: CGFloat = 1

    @objc func didSelectSpawnWildHorse() {
        if wildHorseWindow != nil { return }
        let wh = PetWindow(kind: .horse)
        wh.setFeetPosition(x: physics.position.x - 240, y: physics.position.y)
        wh.orderFrontRegardless()
        wh.petView.petDelegate = self
        wildHorseWindow = wh
        wildHorseFlipTimer = 2.5
        wh.petView.petNode.showOverheadEmoji("❓ 야생마다...!", duration: 2.2)
        SoundAndEffectsManager.shared.play(.alert)
    }

    @objc func didToggleHorseRide() {
        if isRidingHorse {
            dismountHorse()
            statusItem?.menu = buildContextMenu()
            return
        }
        guard currentPetKind == .horse, petPhysics != nil else { return }
        isRidingHorse = true
        AdvancementManager.shared.unlock(.horseRide)
        rideTimer = 14.0
        rideDir = window.characterView.characterNode.modelRoot.eulerAngles.y >= 0 ? 1 : -1
        window.characterView.characterNode.isSitting = true
        window.characterView.characterNode.showOverheadEmoji("🐎 히히힝! 달려-!", duration: 2.2)
        SoundAndEffectsManager.shared.play(.jump)
    }

    private func dismountHorse() {
        isRidingHorse = false
        window.characterView.characterNode.isSitting = false
        petBehavior?.speedMultiplier = 1.0
        window.characterView.characterNode.showOverheadEmoji("🐴 잘 달렸다!", duration: 1.8)
    }

    private func updateWildHorse(dt: TimeInterval) {
        guard let wh = wildHorseWindow else { return }
        wildHorseFlipTimer -= dt
        if wildHorseFlipTimer <= 0 {
            wildHorseFlipTimer = Double.random(in: 2.5...5.0)
            wildHorseDir = Bool.random() ? 1 : -1
        }
        let node = wh.petView.petNode
        node.modelRoot.eulerAngles.y = wildHorseDir > 0 ? (CGFloat.pi / 2.0) : (-CGFloat.pi / 2.0)
        node.walkSpeed = 55
        node.isRunning = false
        node.update(deltaTime: CGFloat(dt))
        var frame = wh.frame
        frame.origin.x += wildHorseDir * 55.0 * CGFloat(dt)
        wh.setFrameOrigin(frame.origin)
    }

    private func handleWildHorseClicked(_ view: PetView) {
        guard let wh = wildHorseWindow, view === wh.petView else { return }
        if window.characterView.characterNode.currentHeldItem == .goldenApple {
            window.characterView.characterNode.currentHeldItem = .none
            view.petNode.showOverheadEmoji("❤️❤️❤️ 길들였다!", duration: 2.5)
            AdvancementManager.shared.unlock(.horseTame)
            SoundAndEffectsManager.shared.play(.heart)
            wh.close()
            wildHorseWindow = nil
            summonPet(kind: .horse)
            window.characterView.characterNode.showOverheadEmoji("🐴 새 가족이다!", duration: 2.2)
            statusItem?.menu = buildContextMenu()
        } else {
            view.petNode.showOverheadEmoji("푸르릉! 🐴 (황금사과를 들어봐)", duration: 2.0)
            SoundAndEffectsManager.shared.play(.alert)
            wildHorseDir *= -1
        }
    }

    private func updateHorseRide(dt: TimeInterval) {
        guard isRidingHorse, let pPhys = petPhysics else { return }
        rideTimer -= dt
        if rideTimer <= 0 {
            dismountHorse()
            statusItem?.menu = buildContextMenu()
            return
        }
        let screen = ScreenEnvironment.shared.screen(for: pPhys.position)
        let margin: CGFloat = 60
        if pPhys.position.x > screen.frame.maxX - margin {
            rideDir = -1
        } else if pPhys.position.x < screen.frame.minX + margin {
            rideDir = 1
        }
        pPhys.position.x += rideDir * 260.0 * CGFloat(dt)
        pPhys.velocity = .zero
        let horseNode = petWindow?.petView.petNode
        horseNode?.modelRoot.eulerAngles.y = rideDir > 0 ? (CGFloat.pi / 2.0) : (-CGFloat.pi / 2.0)
        horseNode?.walkSpeed = 260
        horseNode?.isRunning = true
        physics.position = CGPoint(x: pPhys.position.x, y: pPhys.position.y + 34)
        physics.velocity = .zero
        window.characterView.characterNode.walkSpeed = 0
    }

    // MARK: - Enchanting (경험치 & 인챈트 테이블)
    private var enchantTableWindow: EnchantTableWindow?

    @objc func didSelectEnchantTable() {
        if let table = enchantTableWindow {
            table.close()
            enchantTableWindow = nil
            return
        }
        let pos = CGPoint(x: physics.position.x - 110, y: physics.position.y)
        let table = EnchantTableWindow(floorPos: pos) { [weak self] in
            self?.tryEnchantHeldWeapon()
        }
        enchantTableWindow = table
        table.place()
        window.characterView.characterNode.showOverheadEmoji("📖 인챈트 테이블! (XP: \(player.playerXP))", duration: 2.2)
    }

    private func tryEnchantHeldWeapon() {
        let charNode = window.characterView.characterNode
        let weapon = charNode.currentHeldItem
        guard weapon == .diamondSword || weapon == .diamondPickaxe else {
            charNode.showOverheadEmoji("📖 검/곡괭이를 들어봐! (XP: \(player.playerXP))", duration: 2.0)
            return
        }
        guard player.playerXP >= 10 else {
            charNode.showOverheadEmoji("📖 XP 부족! (필요 10, 보유 \(player.playerXP))", duration: 2.0)
            SoundAndEffectsManager.shared.play(.pop)
            return
        }
        player.playerXP -= 10
        if weapon == .diamondSword {
            player.swordSharpness += 1
            AdvancementManager.shared.unlock(.enchanting)
            charNode.showOverheadEmoji("📖 날카로움 \(player.swordSharpness)! ✨", duration: 2.5)
        } else {
            player.pickaxeEfficiency += 1
            AdvancementManager.shared.unlock(.enchanting)
            charNode.showOverheadEmoji("📖 효율 \(player.pickaxeEfficiency)! ✨", duration: 2.5)
        }
        charNode.isEnchantedGlintEnabled = true
        SoundAndEffectsManager.shared.play(.chime)
    }

    private func gainXP(_ amount: Int, reason: String) {
        player.playerXP += amount
        window.characterView.characterNode.showOverheadEmoji("🟢 +\(amount)XP! (\(reason) 총 \(player.playerXP))", duration: 2.0)
        SoundAndEffectsManager.shared.play(.heart)
    }

    // MARK: - Balloon (풍선 저속낙하)
    private var wasAirborneLastTick: Bool = false

    private func updateBalloonFall() {
        let charNode = window.characterView.characterNode
        let holdingBalloon = charNode.currentHeldItem == .balloon
        physics.isSlowFalling = holdingBalloon
        let onGround = physics.currentPlatform != nil
        if holdingBalloon && wasAirborneLastTick && onGround {
            charNode.showOverheadEmoji("💨 퐁신 착지! 🎈", duration: 1.8)
            SoundAndEffectsManager.shared.play(.pop)
        }
        wasAirborneLastTick = !onGround
    }

    // MARK: - Brewing (양조·물약)
    private var brewStandWindow: BrewStandWindow?

    @objc func didSelectBrewStand() {
        if let stand = brewStandWindow {
            stand.close()
            brewStandWindow = nil
            return
        }
        let pos = CGPoint(x: physics.position.x - 110, y: physics.position.y)
        let stand = BrewStandWindow(floorPos: pos) { [weak self] in
            self?.tryBrewPotion()
        }
        brewStandWindow = stand
        stand.place()
        window.characterView.characterNode.showOverheadEmoji("🧪 양조기! 재료(🍎/🌺/🦴)를 들어봐!", duration: 2.5)
    }

    private func tryBrewPotion() {
        let charNode = window.characterView.characterNode
        let glisterBoost = player.hasGlisteringMelon
        guard let brew = MinecraftCharacterNode.spec(for: charNode.currentHeldItem).brew else {
            charNode.showOverheadEmoji("🧪 사과·꽃·뼈다귀를 들어봐!", duration: 2.0)
            SoundAndEffectsManager.shared.play(.pop)
            return
        }
        charNode.currentHeldItem = .none
        player.hasGlisteringMelon = false
        AdvancementManager.shared.unlock(.brewing)
        let boost: TimeInterval = glisterBoost ? 1.5 : 1.0
        switch brew {
        case .swift:
            player.swiftTimer = 90.0 * boost
            charNode.showOverheadEmoji(glisterBoost ? "⚡✨ 초신속 물약! 반짝임 증폭!" : "⚡ 신속 물약! 빨라졌다!", duration: 2.2)
        case .invis:
            player.invisTimer = 60.0 * boost
            charNode.showOverheadEmoji(glisterBoost ? "👻✨ 초투명 물약! 반짝임 증폭!" : "👻 투명 물약! 안 보여!", duration: 2.2)
        case .strength:
            player.strengthTimer = 90.0 * boost
            charNode.showOverheadEmoji(glisterBoost ? "💪✨ 초힘 물약! 반짝임 증폭!" : "💪 힘 물약! 세졌다!", duration: 2.2)
        }
        SoundAndEffectsManager.shared.play(.gulp)
    }

    private func updatePotions(dt: TimeInterval) {
        let charNode = window.characterView.characterNode
        if player.witchSlowTimer > 0 {
            player.witchSlowTimer -= dt
            if player.witchSlowTimer <= 0 && player.swiftTimer <= 0 {
                behavior.walkSpeed = 85.0
                charNode.showOverheadEmoji("✨ 어지럼 끝!", duration: 1.5)
            }
        }
        if player.swiftTimer > 0 {
            player.swiftTimer -= dt
            behavior.walkSpeed = 170.0
            if player.swiftTimer <= 0 {
                behavior.walkSpeed = 85.0
                charNode.showOverheadEmoji("⚡ 신속 끝!", duration: 1.5)
            }
        }
        if player.invisTimer > 0 {
            player.invisTimer -= dt
            window.alphaValue = 0.35
            if player.invisTimer <= 0 {
                window.alphaValue = 1.0
                charNode.showOverheadEmoji("👻 다시 보였다!", duration: 1.5)
            }
        }
        if player.strengthTimer > 0 {
            player.strengthTimer -= dt
            if player.strengthTimer <= 0 {
                charNode.showOverheadEmoji("💪 힘 끝!", duration: 1.5)
            }
        }
    }

    // MARK: - Trading (주민 거래)

    @objc func didSelectTrade() {
        guard let platform = physics.currentPlatform,
              case let .window(_, appName, ownerPid) = platform.kind,
              ownerPid != getpid() else {
            window.characterView.characterNode.showOverheadEmoji("🧑‍🌾 창문 위에서 불러봐!", duration: 2.0)
            return
        }
        let alert = NSAlert()
        alert.messageText = "🧑‍🌾 \(appName) 주민과의 거래"
        alert.informativeText = "보유 에메랄드: \(player.playerEmeralds)개\n흡! 좋은 물건 있어!"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "🗡️ 다이아 검 (3)")
        alert.addButton(withTitle: "🍎 황금사과 (2)")
        alert.addButton(withTitle: "✨ 토템 (5)")
        alert.addButton(withTitle: "취소")
        NSApp.activate(ignoringOtherApps: true)
        let choice = alert.runModal()
        let charNode = window.characterView.characterNode
        switch choice {
        case .alertFirstButtonReturn:
            guard player.playerEmeralds >= 3 else {
                charNode.showOverheadEmoji("🧑‍🌾 에메랄드가 모자라! 흡!", duration: 2.0)
                return
            }
            player.playerEmeralds -= 3
            charNode.currentHeldItem = .diamondSword
            AdvancementManager.shared.unlock(.trading)
            charNode.showOverheadEmoji("🗡️ 거래 성사! 흡!", duration: 2.2)
            SoundAndEffectsManager.shared.play(.heart)
        case .alertSecondButtonReturn:
            guard player.playerEmeralds >= 2 else {
                charNode.showOverheadEmoji("🧑‍🌾 에메랄드가 모자라! 흡!", duration: 2.0)
                return
            }
            player.playerEmeralds -= 2
            charNode.currentHeldItem = .goldenApple
            AdvancementManager.shared.unlock(.trading)
            charNode.showOverheadEmoji("🍎 거래 성사! 흡!", duration: 2.2)
            SoundAndEffectsManager.shared.play(.heart)
        case .alertThirdButtonReturn:
            guard player.playerEmeralds >= 5 else {
                charNode.showOverheadEmoji("🧑‍🌾 에메랄드가 모자라! 흡!", duration: 2.0)
                return
            }
            player.playerEmeralds -= 5
            charNode.isTotemEquipped = true
            AdvancementManager.shared.unlock(.trading)
            charNode.showOverheadEmoji("✨ 토템 거래 성사! 흡!", duration: 2.2)
            SoundAndEffectsManager.shared.play(.chime)
        default:
            break
        }
        statusItem?.menu = buildContextMenu()
    }

    // MARK: - Fox (여우 장난)
    var foxWindow: FoxWindow?
    private var foxStolenItem: HeldItem = .none
    var foxSpawnInterval: TimeInterval = 150.0

    @objc func didSelectSpawnFox() {
        spawnFox()
    }

    func spawnFox() {
        guard foxWindow == nil else { return }
        let charNode = window.characterView.characterNode
        let startPos = CGPoint(x: physics.position.x + 200, y: physics.position.y)
        let fox = FoxWindow(startPos: startPos, delegate: self)
        foxWindow = fox
        if charNode.currentHeldItem != .none {
            foxStolenItem = charNode.currentHeldItem
            charNode.currentHeldItem = .none
            fox.carriedEmoji = "🎁"
            charNode.showOverheadEmoji("🦊 앗! 내 아이템!", duration: 2.0)
        } else {
            foxStolenItem = .none
            charNode.showOverheadEmoji("🦊 여우다! (잡아봐!)", duration: 2.0)
        }
        SoundAndEffectsManager.shared.play(.alert)
        fox.spawn()
    }

    public func foxWindowDidClick(_ window: FoxWindow) {
        let charNode = self.window.characterView.characterNode
        if foxStolenItem != .none {
            charNode.currentHeldItem = foxStolenItem
            charNode.showOverheadEmoji("🦊 돌려받았다!", duration: 2.0)
            foxStolenItem = .none
        } else {
            charNode.showOverheadEmoji("🦊 휴! 놀랐네!", duration: 1.6)
        }
        SoundAndEffectsManager.shared.play(.heart)
        foxWindow = nil
        window.disappear(escaped: false)
    }

    public func foxWindowDidEscape(_ window: FoxWindow) {
        if foxStolenItem != .none {
            self.window.characterView.characterNode.showOverheadEmoji("🦊 가져갔어... ㅠ", duration: 2.0)
            foxStolenItem = .none
        }
        foxWindow = nil
    }

    // MARK: - Minecart (Dock 광산 수레)
    private var isCartRiding: Bool = false
    private var cartTimer: TimeInterval = 0
    private var cartDir: CGFloat = 1
    private var cartClackTimer: TimeInterval = 0

    @objc func didSelectMinecart() {
        if isCartRiding {
            stopMinecart()
            return
        }
        guard let platform = physics.currentPlatform, case .dock = platform.kind else {
            window.characterView.characterNode.showOverheadEmoji("🛒 Dock 위에서 타봐!", duration: 2.0)
            return
        }
        isCartRiding = true
        cartTimer = 10.0
        cartClackTimer = 0
        cartDir = window.characterView.characterNode.modelRoot.eulerAngles.y >= 0 ? 1 : -1
        window.characterView.characterNode.isSitting = true
        window.characterView.characterNode.showOverheadEmoji("🛒 덜컹덜컹 출발!", duration: 2.0)
        SoundAndEffectsManager.shared.play(.jump)
    }

    private func stopMinecart() {
        isCartRiding = false
        window.characterView.characterNode.isSitting = false
    }

    private func updateMinecart(dt: TimeInterval) {
        guard isCartRiding else { return }
        cartTimer -= dt
        cartClackTimer -= dt
        if cartTimer <= 0 {
            stopMinecart()
            window.characterView.characterNode.showOverheadEmoji("🛒 종점 도착!", duration: 1.8)
            return
        }
        guard let platform = physics.currentPlatform, case .dock = platform.kind else {
            stopMinecart()
            return
        }
        if physics.position.x > platform.xMax - 40 {
            cartDir = -1
        } else if physics.position.x < platform.xMin + 40 {
            cartDir = 1
        }
        physics.position.x += cartDir * 300.0 * CGFloat(dt)
        physics.position.y = platform.yTop
        physics.velocity = .zero
        window.characterView.characterNode.modelRoot.eulerAngles.y = cartDir > 0 ? (CGFloat.pi / 2.0) : (-CGFloat.pi / 2.0)
        window.characterView.characterNode.walkSpeed = 0
        if cartClackTimer <= 0 {
            cartClackTimer = 0.5
            SoundAndEffectsManager.shared.play(.pop)
        }
    }

    // MARK: - Goat (염소 돌진·우유 짜기)
    private var goatWindow: GoatWindow?

    @objc func didSelectSpawnGoat() {
        if goatWindow != nil {
            goatWindow?.close()
            goatWindow = nil
            return
        }
        let pos = CGPoint(x: physics.position.x + 220, y: physics.position.y)
        let goat = GoatWindow(
            startPos: pos,
            onRam: { [weak self] in
                guard let self = self else { return }
                let dir: CGFloat = self.physics.position.x >= pos.x ? 1 : -1
                self.physics.launch(vx: dir * 380.0, vy: 260.0)
                self.window.characterView.characterNode.showOverheadEmoji("🐐 쿵! 받혔다!", duration: 2.0)
                SoundAndEffectsManager.shared.play(.land)
                if Double.random(in: 0...1) < 0.4 {
                    self.player.playerHorns += 1
                    self.window.characterView.characterNode.showOverheadEmoji("🎺 뿔 획득! (총 \(self.player.playerHorns)개)", duration: 2.2)
                    SoundAndEffectsManager.shared.play(.heart)
                    self.statusItem?.menu = self.buildContextMenu()
                }
            },
            onMilk: { [weak self] in
                guard let self = self else { return }
                let charNode = self.window.characterView.characterNode
                if charNode.currentHeldItem == .emptyBucket {
                    charNode.currentHeldItem = .milkBucket
                    charNode.showOverheadEmoji("🐐 신선한 우유! 🥛", duration: 2.2)
                    SoundAndEffectsManager.shared.play(.gulp)
                } else {
                    charNode.showOverheadEmoji("메에에! 🐐 (빈 양동이를 들어봐)", duration: 1.8)
                    SoundAndEffectsManager.shared.play(.pop)
                }
            }
        )
        goatWindow = goat
        goat.spawn()
        window.characterView.characterNode.showOverheadEmoji("🐐 염소다! 조심해!", duration: 2.0)
    }

    private func updateGoat() {
        if let g = goatWindow, !g.isVisible {
            goatWindow = nil
        }
        goatWindow?.targetX = physics.position.x
    }

    // MARK: - Advancements (발전 과제)
    private var advancementListWindow: AdvancementListWindow?

    @objc func didSelectAdvancements() {
        if let w = advancementListWindow {
            w.close()
            advancementListWindow = nil
            return
        }
        let w = AdvancementListWindow()
        advancementListWindow = w
        w.orderFrontRegardless()
    }

    // MARK: - Phantom (팬텀 야습)
    private var phantomWindow: PhantomWindow?
    private var phantomCheckTimer: TimeInterval = 0

    @objc func didSelectSpawnPhantom() {
        spawnPhantom()
    }

    private func spawnPhantom() {
        guard phantomWindow == nil else { return }
        let startPos = CGPoint(x: physics.position.x, y: physics.position.y + 260)
        let phantom = PhantomWindow(startPos: startPos, delegate: self)
        phantomWindow = phantom
        phantom.anchor = physics.position
        phantom.start()
        window.characterView.characterNode.showOverheadEmoji("👻 섬뜩한 기척...!", duration: 2.2)
        SoundAndEffectsManager.shared.play(.alert)
    }

    public func phantomWindowDidClick(_ window: PhantomWindow) {
        attackPhantom(window)
    }

    public func phantomWindowDidLeave(_ window: PhantomWindow) {
        phantomWindow = nil
    }

    public func phantomWindowDidDefeat(_ window: PhantomWindow) {
        phantomWindow = nil
        player.playerXP += 6
        self.window.characterView.characterNode.showOverheadEmoji("👻 격퇴! 막 +6XP!", duration: 2.2)
        SoundAndEffectsManager.shared.play(.heart)
    }

    private func updatePhantom(dt: TimeInterval) {
        guard let phantom = phantomWindow else {
            let hour = Calendar.current.component(.hour, from: Date())
            let deepNight = (hour >= 0 && hour < 5)
            if deepNight || DayNightCycleManager.shared.mode == .forceNight {
                phantomCheckTimer += dt
                if phantomCheckTimer >= 45.0 {
                    phantomCheckTimer = 0
                    if Bool.random() {
                        spawnPhantom()
                    }
                }
            } else {
                phantomCheckTimer = 0
            }
            return
        }
        phantom.anchor = physics.position
        let dist = hypot(phantom.position.x - physics.position.x, phantom.position.y - physics.position.y)
        if dist < 70 && player.playerAttackTimer <= 0 {
            let charNode = window.characterView.characterNode
            let guarded = charNode.isShieldEquipped && (charNode.isSneaking || charNode.isGuarding)
            if guarded {
                charNode.showOverheadEmoji("🛡️ 챙-! 팬텀 방어!", duration: 1.6)
                SoundAndEffectsManager.shared.play(.pop)
            } else if consumeTotemIfEquipped() {
            } else {
                physics.launch(vx: (physics.position.x >= phantom.position.x ? 200 : -200), vy: 200)
                charNode.showOverheadEmoji("👻 할퀴었다!", duration: 1.6)
            }
            player.playerAttackTimer = 1.0
        }
        if dist < 90 && player.playerAttackTimer <= 0 {
            attackPhantom(phantom)
        }
    }

    private func attackPhantom(_ phantom: PhantomWindow) {
        let charNode = window.characterView.characterNode
        charNode.isAttackingWeapon = true
        player.playerAttackTimer = 0.5
        charNode.showOverheadEmoji("🗡️ 에잇!", duration: 1.0)
        SoundAndEffectsManager.shared.play(.splash)
        phantom.takeHit()
    }

    // MARK: - Spider (거미 창문 등반)
    private var spiderWindow: SpiderWindow?

    @objc func didSelectSpawnSpider() {
        spawnSpider()
    }

    private func spawnSpider() {
        guard spiderWindow == nil else { return }
        if let platform = physics.currentPlatform, case .window = platform.kind {
            let top = platform.yTop
            let bottom = platform.yBottom ?? (top - 300)
            let spider = SpiderWindow(
                startPos: CGPoint(x: physics.position.x + 80, y: (top + bottom) / 2),
                surfaceTop: top - 10,
                surfaceBottom: bottom,
                delegate: self
            )
            spiderWindow = spider
            spider.start()
            window.characterView.characterNode.showOverheadEmoji("🕷️ 창문을 기어올라!", duration: 2.0)
            SoundAndEffectsManager.shared.play(.alert)
        } else {
            let pos = CGPoint(x: physics.position.x + 140, y: physics.position.y)
            let spider = SpiderWindow(startPos: pos, surfaceTop: pos.y + 200, surfaceBottom: pos.y - 40, delegate: self)
            spiderWindow = spider
            spider.start()
            window.characterView.characterNode.showOverheadEmoji("🕷️ 거미다!", duration: 2.0)
        }
    }

    public func spiderWindowDidClick(_ window: SpiderWindow) {
        if DayNightCycleManager.shared.isNight {
            attackSpider(window)
        } else {
            self.window.characterView.characterNode.showOverheadEmoji("🕷️ 낮엔 얌전하네...", duration: 1.6)
            SoundAndEffectsManager.shared.play(.pop)
        }
    }

    public func spiderWindowDidLeave(_ window: SpiderWindow) {
        if spiderWindow === window {
            spiderWindow = nil
            player.playerXP += 4
            self.window.characterView.characterNode.showOverheadEmoji("🕷️ 격퇴! 실 +4XP!", duration: 2.0)
            SoundAndEffectsManager.shared.play(.heart)
        }
    }

    private func attackSpider(_ spider: SpiderWindow) {
        let charNode = window.characterView.characterNode
        charNode.isAttackingWeapon = true
        player.playerAttackTimer = 0.5
        charNode.showOverheadEmoji("🗡️ 에잇!", duration: 1.0)
        SoundAndEffectsManager.shared.play(.splash)
        spider.takeHit()
    }

    private func updateSpider() {
        guard let spider = spiderWindow else { return }
        let dist = hypot(spider.position.x - physics.position.x, spider.position.y - physics.position.y)
        if DayNightCycleManager.shared.isNight && dist < 110 && player.playerAttackTimer <= 0 {
            attackSpider(spider)
        }
    }

    // MARK: - Ghast (가스트 화염탄 테니스)
    private var ghastWindow: GhastWindow?
    private var fireballs: [FireballWindow] = []

    @objc func didSelectSpawnGhast() {
        spawnGhast()
    }

    private func spawnGhast() {
        guard ghastWindow == nil else { return }
        let base: CGPoint
        if let portal = portalOverlay {
            base = CGPoint(x: portal.floorPos.x, y: portal.floorPos.y + 200)
        } else {
            base = CGPoint(x: physics.position.x - 200, y: physics.position.y + 200)
        }
        let ghast = GhastWindow(startPos: base, delegate: self) { [weak self] from in
            self?.launchFireball(from: from)
        }
        ghastWindow = ghast
        ghast.start()
        window.characterView.characterNode.showOverheadEmoji("🔥 우우... 가스트다!", duration: 2.2)
    }

    private func launchFireball(from: CGPoint) {
        let fireball = FireballWindow(from: from, target: physics.position) { [weak self] reached in
            guard let self = self else { return }
            if reached {
                let charNode = self.window.characterView.characterNode
                let guarded = charNode.isShieldEquipped && (charNode.isSneaking || charNode.isGuarding)
                if guarded {
                    charNode.showOverheadEmoji("🛡️ 챙-! 화염탄 방어!", duration: 1.8)
                    SoundAndEffectsManager.shared.play(.pop)
                } else if self.consumeTotemIfEquipped() {
                } else {
                    self.physics.launch(vx: (self.physics.position.x >= from.x ? 260 : -260), vy: 260)
                    charNode.showOverheadEmoji("🔥 화염탄 직격!", duration: 1.8)
                    SoundAndEffectsManager.shared.play(.explode)
                }
            } else {
                self.deflectFireballAtGhast()
            }
        }
        fireballs.append(fireball)
        fireball.launch()
    }

    private func deflectFireballAtGhast() {
        guard let ghast = ghastWindow else { return }
        window.characterView.characterNode.showOverheadEmoji("🎾 쳐냈다!", duration: 1.6)
        SoundAndEffectsManager.shared.play(.whoosh)
        ghast.disappear(defeated: true)
    }

    public func ghastDidDefeat(_ window: GhastWindow) {
        ghastWindow = nil
        player.playerXP += 8
        self.window.characterView.characterNode.showOverheadEmoji("🔥 가스트 격추! 눈물 +8XP!", duration: 2.5)
        SoundAndEffectsManager.shared.play(.heart)
    }

    public func ghastDidLeave(_ window: GhastWindow) {
        ghastWindow = nil
    }

    private func updateGhast() {
        if let ghast = ghastWindow, !ghast.isVisible {
            ghastWindow = nil
        }
        guard let ghast = ghastWindow else { return }
        ghast.anchor = CGPoint(x: physics.position.x - 160, y: physics.position.y + 60)
        fireballs.removeAll { !$0.isVisible }
    }

    // MARK: - Siege (자정 좀비 공성전)
    private var zombieWindows: [ZombieWindow] = []
    private var siegeCheckTimer: TimeInterval = 0
    private var siegeActive: Bool = false

    @objc func didSelectSpawnSiege() {
        startSiege()
    }

    private func startSiege() {
        guard zombieWindows.isEmpty else { return }
        siegeActive = true
        for i in 0..<3 {
            let pos = CGPoint(
                x: physics.position.x + (i == 0 ? -220 : (i == 1 ? 220 : -160)),
                y: physics.position.y
            )
            let zombie = ZombieWindow(startPos: pos, delegate: self)
            zombieWindows.append(zombie)
            zombie.start()
        }
        window.characterView.characterNode.showOverheadEmoji("🧟 좀비 무리다! 횃불 들어!", duration: 2.5)
        SoundAndEffectsManager.shared.play(.alert)
    }

    public func zombieWindowDidClick(_ window: ZombieWindow) {
        let charNode = self.window.characterView.characterNode
        charNode.isAttackingWeapon = true
        player.playerAttackTimer = 0.4
        if charNode.currentHeldItem == .torch {
            charNode.showOverheadEmoji("🔥 불태워라!", duration: 1.4)
            window.takeHit()
            window.takeHit()
        } else {
            charNode.showOverheadEmoji("🗡️ 에잇!", duration: 1.2)
            window.takeHit()
        }
        SoundAndEffectsManager.shared.play(.splash)
    }

    public func zombieWindowDidDefeat(_ window: ZombieWindow) {
        zombieWindows.removeAll { $0 === window }
        player.playerXP += 3
        self.window.characterView.characterNode.showOverheadEmoji("🧟 격퇴! +3XP!", duration: 1.8)
        SoundAndEffectsManager.shared.play(.heart)
        if siegeActive && zombieWindows.isEmpty {
            siegeActive = false
            player.playerXP += 6
            self.window.characterView.characterNode.showOverheadEmoji("🏆 공성전 승리! +6XP!", duration: 3.0)
            SoundAndEffectsManager.shared.play(.chime)
            physics.jump(impulse: 380)
        }
    }

    private func updateSiege(dt: TimeInterval) {
        for zombie in zombieWindows {
            zombie.target = physics.position
            let dist = abs(zombie.position.x - physics.position.x)
            if dist < 70 && player.playerAttackTimer <= 0 {
                zombieWindowDidClick(zombie)
            }
        }
        guard zombieWindows.isEmpty && !siegeActive else { return }
        let hour = Calendar.current.component(.hour, from: Date())
        if hour >= 0 && hour < 1 {
            siegeCheckTimer += dt
            if siegeCheckTimer >= 30.0 {
                siegeCheckTimer = 0
                if Bool.random() {
                    startSiege()
                }
            }
        } else {
            siegeCheckTimer = 0
        }
    }

    // MARK: - Axolotl (아홀로틀 어깨 동료)
    private var axolotlWindow: AxolotlWindow?

    @objc func didSelectAxolotl() {
        if let ax = axolotlWindow {
            ax.close()
            axolotlWindow = nil
            return
        }
        guard window.characterView.characterNode.currentHeldItem == .emptyBucket else {
            window.characterView.characterNode.showOverheadEmoji("🦎 빈 양동이를 들어봐!", duration: 2.0)
            return
        }
        window.characterView.characterNode.currentHeldItem = .none
        let ax = AxolotlWindow()
        axolotlWindow = ax
        ax.perch()
        window.characterView.characterNode.showOverheadEmoji("🦎 아홀로틀이 어깨에!", duration: 2.2)
        SoundAndEffectsManager.shared.play(.heart)
    }

    private func updateAxolotl() {
        if let ax = axolotlWindow, !ax.isVisible {
            axolotlWindow = nil
            return
        }
        guard let ax = axolotlWindow else { return }
        let facing = window.characterView.characterNode.modelRoot.eulerAngles.y >= 0
        ax.moveToShoulder(playerPos: physics.position, facingRight: facing)
    }

    private func axolotlAssist() {
        guard axolotlWindow != nil else { return }
        window.characterView.characterNode.showOverheadEmoji("🦎 앙!", duration: 1.0)
        SoundAndEffectsManager.shared.play(.splash)
    }

    // MARK: - Sheep (양털 깎기)
    private var sheepWindow: SheepWindow?

    @objc func didSelectSpawnSheep() {
        if sheepWindow != nil {
            sheepWindow?.close()
            sheepWindow = nil
            return
        }
        let pos = CGPoint(x: physics.position.x + 150, y: physics.position.y)
        let sheep = SheepWindow(startPos: pos, delegate: self)
        sheepWindow = sheep
        sheep.start()
        window.characterView.characterNode.showOverheadEmoji("🐑 메에! 양이다!", duration: 2.0)
    }

    public func sheepWindowDidClick(_ window: SheepWindow) {
        let charNode = self.window.characterView.characterNode
        if charNode.currentHeldItem == .shears && window.hasWool {
            window.shear()
            player.playerXP += 2
            charNode.showOverheadEmoji("✂️ 양털 득템! +2XP!", duration: 2.0)
            SoundAndEffectsManager.shared.play(.heart)
        } else if !window.hasWool {
            charNode.showOverheadEmoji("🐑 털 자라는 중...", duration: 1.5)
            SoundAndEffectsManager.shared.play(.pop)
        } else {
            charNode.showOverheadEmoji("🐑 가위를 들어봐! ✂️", duration: 1.8)
            SoundAndEffectsManager.shared.play(.pop)
        }
    }

    // MARK: - Snow Golem (눈 골렘 수호자)
    private var golemWindow: GolemWindow?

    @objc func didSelectBuildGolem() {
        if let golem = golemWindow {
            golem.close()
            golemWindow = nil
            return
        }
        let pos = CGPoint(x: physics.position.x - 100, y: physics.position.y)
        let golem = GolemWindow(startPos: pos) { [weak self] from in
            self?.golemThrowSnowball(from: from)
        }
        golemWindow = golem
        golem.start()
        if PumpkinWard.shared.hasPumpkin {
            window.characterView.characterNode.showOverheadEmoji("🎃 잭오랜턴 골렘! 지켜줘!", duration: 2.2)
        } else {
            window.characterView.characterNode.showOverheadEmoji("⛄ 골렘 조립! 지켜줘!", duration: 2.2)
        }
        SoundAndEffectsManager.shared.play(.heart)
    }

    private func golemThrowSnowball(from: CGPoint) {
        struct Target {
            let pos: CGPoint
            let hit: () -> Void
            let name: String
        }
        var targets: [Target] = []
        if let cPhys = creeperPhysics, creeperWindow != nil {
            targets.append(Target(pos: cPhys.position, hit: { [weak self] in
                self?.attackCreeperWithCurrentWeapon()
            }, name: "크리퍼"))
        }
        if let sPhys = skeletonPhysics, skeletonWindow != nil {
            targets.append(Target(pos: sPhys.position, hit: { [weak self] in
                self?.attackSkeletonWithCurrentWeapon()
            }, name: "스켈레톤"))
        }
        for zombie in zombieWindows {
            targets.append(Target(pos: zombie.position, hit: { [weak self] in
                zombie.takeHit()
                self?.window.characterView.characterNode.showOverheadEmoji("⛄ 눈덩이 퍽!", duration: 1.2)
            }, name: "좀비"))
        }
        if let spider = spiderWindow {
            targets.append(Target(pos: spider.position, hit: { [weak self] in
                self?.attackSpider(spider)
            }, name: "거미"))
        }
        let near = targets
            .map { (t: $0, d: hypot($0.pos.x - from.x, $0.pos.y - from.y)) }
            .filter { $0.d < 420 }
            .min { $0.d < $1.d }
        guard let best = near else { return }
        window.characterView.characterNode.showOverheadEmoji("⛄ \(best.t.name)에 눈덩이!", duration: 1.4)
        SoundAndEffectsManager.shared.play(.splash)
        best.t.hit()
    }

    private func updateGolemAnchor() {
        golemWindow?.anchor = CGPoint(x: physics.position.x - 100, y: physics.position.y)
    }

    // MARK: - Goat Horn (염소 뿔피리)

    @objc func didSelectBlowHorn() {
        guard player.playerHorns > 0 else {
            window.characterView.characterNode.showOverheadEmoji("🎺 뿔이 없어! (염소 돌진 시 확률 드롭)", duration: 2.2)
            return
        }
        player.playerHorns -= 1
        window.characterView.characterNode.showOverheadEmoji("🎺 부우우-! 물러가라!", duration: 2.5)
        SoundAndEffectsManager.shared.play(.alert)
        if creeperWindow != nil {
            creeperWindow?.creeperView.creeperNode.showOverheadEmoji("😱 뿔피리다!", duration: 1.5)
            despawnCreeper()
        }
        if skeletonWindow != nil {
            skeletonWindow?.skeletonView.skeletonNode.showOverheadEmoji("😱 뿔피리다!", duration: 1.5)
            despawnSkeleton()
        }
        if spiderWindow != nil {
            spiderWindow?.close()
            spiderWindow = nil
        }
        if !zombieWindows.isEmpty {
            for zombie in zombieWindows { zombie.dismiss() }
            zombieWindows = []
        }
        if phantomWindow != nil {
            phantomWindow?.disappear(left: true)
        }
        if ghastWindow != nil {
            ghastWindow?.disappear(defeated: false)
        }
        statusItem?.menu = buildContextMenu()
    }

    // MARK: - Bell (종 소집)
    @objc func didSelectRingBell() {
        window.characterView.characterNode.showOverheadEmoji("🔔 땡땡땡! 모여라!", duration: 2.2)
        SoundAndEffectsManager.shared.play(.chime)
        if let pPhys = petPhysics, let pBehav = petBehavior, let pw = petWindow {
            pBehav.teleport(
                to: physics.position,
                playerDirection: window.characterView.characterNode.modelRoot.eulerAngles.y,
                petPhysics: pPhys,
                petNode: pw.petView.petNode
            )
        }
        for i in buddyPhysics.indices {
            buddyPhysics[i].position = CGPoint(
                x: physics.position.x + (i == 0 ? -70 : 70),
                y: physics.position.y
            )
            buddyPhysics[i].velocity = .zero
        }
        if babyPetWindow != nil {
            babyGrowTimer = min(babyGrowTimer, 30.0)
        }
    }

    // MARK: - Cake (케이크 파티)
    private var cakeWindow: CakeWindow?

    @objc func didSelectCake() {
        if let cake = cakeWindow {
            cake.close()
            cakeWindow = nil
            return
        }
        let dir: CGFloat = 1.0
        let pos = CGPoint(x: physics.position.x + dir * 85, y: physics.position.y)
        let cake = CakeWindow(floorPos: pos) { [weak self] in
            guard let self = self else { return }
            self.window.characterView.characterNode.showOverheadEmoji("🍰 냠냠! 달콤해!", duration: 1.6)
            SoundAndEffectsManager.shared.play(.gulp)
            if let petNode = self.petWindow?.petView.petNode, Bool.random() {
                petNode.showOverheadEmoji("🍰 냠!", duration: 1.4)
            }
        }
        cakeWindow = cake
        cake.place()
        let char = window.characterView.characterNode
        char.showOverheadEmoji("🎂 케이크 발견!", duration: 1.6)

        // 캐릭터가 케이크로 다가가서 냠냠 먹는 인터랙션
        let targetX = pos.x - 32.0
        behavior.chargeAt(targetX: targetX, speed: 110.0, duration: 0.8, physics: physics, characterNode: char)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak cake] in
            guard let self = self, let cake = cake, cake.isVisible else { return }
            char.isEating = true
            cake.eatSlice()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak char] in
                char?.isEating = false
            }
        }
    }

    // MARK: - Witch (마녀 투척)
    private var witchWindow: WitchWindow?

    @objc func didSelectSpawnWitch() {
        spawnWitch()
    }

    private func spawnWitch() {
        guard witchWindow == nil else { return }
        let pos = CGPoint(x: physics.position.x + 200, y: physics.position.y)
        let witch = WitchWindow(
            startPos: pos,
            onThrow: { [weak self] in
                guard let self = self else { return }
                self.player.witchSlowTimer = 5.0
                self.window.characterView.characterNode.showOverheadEmoji("🧙‍♀️ 어지러워...! (우유 마셔!)", duration: 2.0)
                SoundAndEffectsManager.shared.play(.splash)
            },
            onDefeat: { [weak self] in
                guard let self = self else { return }
                self.witchWindow = nil
                self.player.playerXP += 6
                self.window.characterView.characterNode.showOverheadEmoji("🧙‍♀️ 격퇴! +6XP!", duration: 2.2)
                SoundAndEffectsManager.shared.play(.heart)
            }
        )
        witchWindow = witch
        witch.anchor = pos
        witch.start()
        window.characterView.characterNode.showOverheadEmoji("🧙‍♀️ 킥킥... 마녀다!", duration: 2.2)
    }

    private func updateWitch() {
        if let w = witchWindow, !w.isVisible {
            witchWindow = nil
        }
        witchWindow?.anchor = CGPoint(x: physics.position.x + 200, y: physics.position.y)
        if player.witchSlowTimer > 0 {
            behavior.walkSpeed = 40.0
        }
    }

    // MARK: - Campfire (캠프파이어 휴식)
    private var campfireWindow: CampfireWindow?
    private var campfirePos: CGPoint = .zero
    private var campfireAuraTimer: TimeInterval = 0

    @objc func didSelectCampfire() {
        if let fire = campfireWindow {
            fire.close()
            campfireWindow = nil
            return
        }
        let pos = CGPoint(x: physics.position.x - 90, y: physics.position.y)
        let fire = CampfireWindow(floorPos: pos)
        campfireWindow = fire
        campfirePos = pos
        fire.place()
        window.characterView.characterNode.showOverheadEmoji("🔥 모닥불 피웠다!", duration: 2.0)
    }

    private func updateCampfire(dt: TimeInterval) {
        if let fire = campfireWindow, !fire.isVisible {
            campfireWindow = nil
            return
        }
        guard campfireWindow != nil else { return }
        campfireAuraTimer += dt
        if campfireAuraTimer < 5.0 { return }
        campfireAuraTimer = 0
        let charNode = window.characterView.characterNode
        if charNode.isSitting && abs(physics.position.x - campfirePos.x) < 170 {
            player.playerXP += 1
            charNode.showOverheadEmoji("🔥 휴식 중... +1XP", duration: 1.6)
        }
        if let petNode = petWindow?.petView.petNode, petNode.isSitting {
            petNode.feed()
        }
    }

    // MARK: - Archery (양궁 과녁)
    var targetWindow: TargetWindow?
    var archeryScore: Int = 0

    @objc func didSelectPlaceTarget() {
        if let target = targetWindow, target.isVisible {
            target.close()
            targetWindow = nil
            return
        }
        targetWindow = nil
        let pos = CGPoint(x: physics.position.x + 260, y: physics.position.y + 40)
        let target = TargetWindow(centerPos: pos)
        targetWindow = target
        target.place()
        window.characterView.characterNode.showOverheadEmoji("🎯 과녁 설치! 활을 들어봐!", duration: 2.2)
    }

    @objc func didSelectShootTarget() {
        guard let target = targetWindow else {
            window.characterView.characterNode.showOverheadEmoji("🎯 과녁부터 놓자!", duration: 1.8)
            return
        }
        let charNode = window.characterView.characterNode
        if charNode.currentHeldItem != .bow {
            charNode.currentHeldItem = .bow
        }

        // 과녁을 향해 캐릭터 몸통 회전 및 조준
        let aimDir: CGFloat = target.centerPos.x >= physics.position.x ? 1.0 : -1.0
        charNode.modelRoot.eulerAngles.y = aimDir > 0 ? (CGFloat.pi / 2.0) : (-CGFloat.pi / 2.0)
        charNode.isAttackingWeapon = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak charNode] in
            charNode?.isAttackingWeapon = false
        }

        let angle = Double.random(in: 0...(Double.pi * 2))
        let miss = Double.random(in: 0...38)
        let hit = CGPoint(
            x: target.centerPos.x + CGFloat(cos(angle) * miss),
            y: target.centerPos.y + CGFloat(sin(angle) * miss)
        )
        let score: Int
        let label: String
        switch miss {
        case 0..<6:
            score = 10
            label = "🎯 정중앙! 10점!"
        case 6..<14:
            score = 7
            label = "🔴 7점!"
        case 14..<23:
            score = 5
            label = "🔵 5점!"
        case 23..<32:
            score = 3
            label = "⚫ 3점!"
        default:
            score = 1
            label = "⚪ 1점..."
        }
        let arrowStart = CGPoint(x: physics.position.x + aimDir * 24.0, y: physics.position.y + 35.0)
        let arrow = ArrowEntityWindow(
            startPos: arrowStart,
            targetPos: hit,
            checkGuarding: { false },
            onHit: { [weak self, weak target] _ in
                guard let self = self else { return }
                target?.shake()
                self.archeryScore += score
                self.player.playerXP += score / 5
                self.window.characterView.characterNode.showOverheadEmoji(
                    "\(label) (합계 \(self.archeryScore))", duration: 2.2
                )
                SoundAndEffectsManager.shared.play(score >= 7 ? .chime : .heart)
                self.statusItem?.menu = self.buildContextMenu()
            }
        )
        activeArrows.append(arrow)
        arrow.launch()
        SoundAndEffectsManager.shared.play(.whoosh)
    }


    // MARK: - 고증 7차: 닭·달걀 (Chicken & Eggs)
    private var chickenWindows: [ChickenWindow] = []

    @objc func didSelectSpawnChicken() {
        if let first = chickenWindows.first {
            for c in chickenWindows { c.close() }
            chickenWindows = []
            _ = first
            window.characterView.characterNode.showOverheadEmoji("🐔 닭 보내기!", duration: 1.6)
            return
        }
        let pos = CGPoint(x: physics.position.x + 150, y: physics.position.y)
        let chicken = ChickenWindow(startPos: pos, delegate: self)
        chickenWindows.append(chicken)
        chicken.start()
        window.characterView.characterNode.showOverheadEmoji("🐔 꼬꼬댁! 닭이다!", duration: 2.0)
    }

    public func chickenWindowDidClick(_ window: ChickenWindow) {
        window.layEgg()
        self.window.characterView.characterNode.showOverheadEmoji("🥚 알 낳기!", duration: 1.4)
        SoundAndEffectsManager.shared.play(.pop)
    }

    public func chickenWindowDidHatchChick(_ parent: ChickenWindow, chick: ChickenWindow) {
        chickenWindows.append(chick)
        self.window.characterView.characterNode.showOverheadEmoji("🐣 병아리 부화!", duration: 2.0)
        SoundAndEffectsManager.shared.play(.heart)
    }

    // MARK: - 고증 7차: 무쉬룸 스튜 (Mooshroom)
    private var mooshroomWindow: MooshroomWindow?

    @objc func didSelectSpawnMooshroom() {
        if let m = mooshroomWindow {
            m.close()
            mooshroomWindow = nil
            return
        }
        let pos = CGPoint(x: physics.position.x - 150, y: physics.position.y)
        let moo = MooshroomWindow(startPos: pos, delegate: self)
        mooshroomWindow = moo
        moo.start()
        window.characterView.characterNode.showOverheadEmoji("🍄 무쉬룸이다!", duration: 2.0)
    }

    public func mooshroomWindowDidClick(_ window: MooshroomWindow) {
        let charNode = self.window.characterView.characterNode
        if charNode.currentHeldItem == .emptyBucket {
            window.collectStew()
            charNode.showOverheadEmoji("🍲 버섯 스튜 완성! 냠!", duration: 2.2)
            player.playerXP += 2
            statusItem?.menu = buildContextMenu()
        } else {
            charNode.showOverheadEmoji("🍄 빈 양동이를 들어봐! 🪣", duration: 1.8)
            SoundAndEffectsManager.shared.play(.pop)
        }
    }

    // MARK: - 고증 7차: 리드줄 (Lead)
    @objc func didSelectToggleLead() {
        if LeadManager.shared.isTied {
            LeadManager.shared.untie()
            window.characterView.characterNode.showOverheadEmoji("🧶 리드줄 풀기!", duration: 1.6)
            SoundAndEffectsManager.shared.play(.pop)
            return
        }
        guard petWindow != nil, petPhysics != nil else {
            window.characterView.characterNode.showOverheadEmoji("🧶 묶을 펫이 없어!", duration: 1.8)
            SoundAndEffectsManager.shared.play(.pop)
            return
        }
        let petPos = petWindow!.frame.origin
        let anchor = physics.position
        LeadManager.shared.tie(petPos: petPos, anchorPos: anchor)
        window.characterView.characterNode.currentHeldItem = .lead
        window.characterView.characterNode.showOverheadEmoji("🧶 펫을 묶었다!", duration: 2.0)
        SoundAndEffectsManager.shared.play(.heart)
        statusItem?.menu = buildContextMenu()
    }


    // MARK: - 고증 7차: 스폰 나침반 (Compass)
    @objc func didSelectCompass() {
        if SpawnCompass.shared.spawnPoint == nil {
            SpawnCompass.shared.setSpawn(physics.position)
            let toast = CompassToastWindow(message: "🧭 스폰 저장!", at: physics.position)
            toast.show()
            window.characterView.characterNode.showOverheadEmoji("🧭 스폰 저장!", duration: 2.0)
            SoundAndEffectsManager.shared.play(.chime)
            return
        }
        let home = SpawnCompass.shared.spawnPoint!
        var petCount = 0
        var buddyCount = 0
        if let pPhys = petPhysics, let pBehav = petBehavior, let pw = petWindow {
            pBehav.teleport(
                to: home,
                playerDirection: window.characterView.characterNode.modelRoot.eulerAngles.y,
                petPhysics: pPhys,
                petNode: pw.petView.petNode
            )
            petCount = 1
        }
        for i in buddyPhysics.indices {
            buddyPhysics[i].position = CGPoint(
                x: home.x + (i == 0 ? -70 : 70),
                y: home.y
            )
            buddyPhysics[i].velocity = .zero
            buddyCount += 1
        }
        let msg = SpawnCompass.shared.recallMessage(petCount: petCount, buddyCount: buddyCount)
        let toast = CompassToastWindow(message: msg, at: physics.position)
        toast.show()
        window.characterView.characterNode.showOverheadEmoji(msg, duration: 2.2)
        SoundAndEffectsManager.shared.play(.chime)
    }

    // MARK: - 고증 8차: 감자 (Potato)
    private var potatoWindows: [PotatoWindow] = []
    @objc func didSelectPlantPotato() {
        if let first = potatoWindows.first, potatoWindows.count >= 2 {
            for p in potatoWindows { p.close() }
            potatoWindows = []
            _ = first
            window.characterView.characterNode.showOverheadEmoji("🥔 감자밭 정리!", duration: 1.6)
            return
        }
        let pos = CGPoint(x: physics.position.x - 70, y: physics.position.y)
        var patch: PotatoWindow?
        patch = PotatoWindow(plantPos: pos) { [weak self, weak patch] isRotten in
            guard let self = self else { return }
            if let patch = patch {
                self.potatoWindows.removeAll { $0 === patch }
            }
            self.harvestPotato(isRotten: isRotten)
        }
        potatoWindows.append(patch!)
        patch!.plant()
        window.characterView.characterNode.showOverheadEmoji("🥔 감자 심기!", duration: 1.6)
    }

    private func harvestPotato(isRotten: Bool) {
        if isRotten {
            window.characterView.characterNode.showOverheadEmoji("🤢 썩은감자! 꽝!", duration: 2.2)
            SoundAndEffectsManager.shared.play(.splash)
            return
        }
        if campfireWindow != nil {
            player.playerXP += 3
            window.characterView.characterNode.showOverheadEmoji("🥔🔥 구운감자! 고소해! +3XP", duration: 2.2)
            SoundAndEffectsManager.shared.play(.gulp)
        } else {
            player.playerXP += 1
            window.characterView.characterNode.showOverheadEmoji("🥔 감자 수확! +1XP", duration: 2.0)
            SoundAndEffectsManager.shared.play(.heart)
        }
        statusItem?.menu = buildContextMenu()
    }

    // MARK: - 고증 8차: 수박 (Melon)
    private var melonWindows: [MelonWindow] = []
    @objc func didSelectPlantMelon() {
        if melonWindows.count >= 2 {
            for m in melonWindows { m.close() }
            melonWindows = []
            window.characterView.characterNode.showOverheadEmoji("🍉 수박밭 정리!", duration: 1.6)
            return
        }
        let pos = CGPoint(x: physics.position.x + 90, y: physics.position.y)
        var patch: MelonWindow?
        patch = MelonWindow(plantPos: pos) { [weak self, weak patch] isGlistering in
            guard let self = self else { return }
            if let patch = patch {
                self.melonWindows.removeAll { $0 === patch }
            }
            self.sliceMelon(isGlistering: isGlistering)
        }
        melonWindows.append(patch!)
        patch!.plant()
        window.characterView.characterNode.showOverheadEmoji("🍉 수박 심기!", duration: 1.6)
    }

    private func sliceMelon(isGlistering: Bool) {
        if isGlistering {
            player.hasGlisteringMelon = true
            player.playerXP += 4
            window.characterView.characterNode.showOverheadEmoji("🍉✨ 반짝이는 수박! 양조 재료! +4XP", duration: 2.5)
            SoundAndEffectsManager.shared.play(.chime)
        } else {
            let slices = Int.random(in: 3...5)
            player.playerXP += slices
            window.characterView.characterNode.showOverheadEmoji("🍉 슬라이스 파티! \(slices)조각! +\(slices)XP", duration: 2.2)
            SoundAndEffectsManager.shared.play(.gulp)
        }
        statusItem?.menu = buildContextMenu()
    }

    // MARK: - 고증 8차: 호박 (Pumpkin)
    private var pumpkinWindows: [PumpkinWindow] = []
    @objc func didSelectPumpkin() {
        if PumpkinWard.shared.isWorn {
            PumpkinWard.shared.isWorn = false
            window.characterView.characterNode.showOverheadEmoji("🎃 호박 벗기!", duration: 1.6)
            SoundAndEffectsManager.shared.play(.pop)
            statusItem?.menu = buildContextMenu()
            return
        }
        if PumpkinWard.shared.hasPumpkin {
            PumpkinWard.shared.isWorn = true
            window.characterView.characterNode.showOverheadEmoji("🎃 호박 쓰기! 엔더맨 면역!", duration: 2.2)
            SoundAndEffectsManager.shared.play(.heart)
            statusItem?.menu = buildContextMenu()
            return
        }
        if pumpkinWindows.count >= 2 {
            for p in pumpkinWindows { p.close() }
            pumpkinWindows = []
            window.characterView.characterNode.showOverheadEmoji("🎃 호박밭 정리!", duration: 1.6)
            return
        }
        let pos = CGPoint(x: physics.position.x - 90, y: physics.position.y)
        var patch: PumpkinWindow?
        patch = PumpkinWindow(plantPos: pos) { [weak self, weak patch] in
            guard let self = self else { return }
            if let patch = patch {
                self.pumpkinWindows.removeAll { $0 === patch }
            }
            PumpkinWard.shared.hasPumpkin = true
            self.player.playerXP += 2
            self.window.characterView.characterNode.showOverheadEmoji("🎃 호박 수확! 써봐! +2XP", duration: 2.2)
            SoundAndEffectsManager.shared.play(.heart)
            self.statusItem?.menu = self.buildContextMenu()
        }
        pumpkinWindows.append(patch!)
        patch!.plant()
        window.characterView.characterNode.showOverheadEmoji("🎃 호박 심기!", duration: 1.6)
    }

    // MARK: - 고증 8차: 사과나무 (Tree)
    private var treeWindow: TreeWindow?
    @objc func didSelectPlantTree() {
        if let tree = treeWindow {
            if window.characterView.characterNode.currentHeldItem == .axe && tree.isMature {
                tree.chop()
                return
            }
            if window.characterView.characterNode.currentHeldItem == .axe {
                window.characterView.characterNode.showOverheadEmoji("🌳 아직 덜 자랐어!", duration: 1.6)
                return
            }
            tree.close()
            treeWindow = nil
            window.characterView.characterNode.showOverheadEmoji("🌳 나무 치우기!", duration: 1.6)
            return
        }
        let pos = CGPoint(x: physics.position.x + 130, y: physics.position.y)
        let tree = TreeWindow(plantPos: pos, delegate: self)
        treeWindow = tree
        tree.start()
        window.characterView.characterNode.showOverheadEmoji("🌱 묘목 심기!", duration: 1.6)
    }

    public func treeWindowDidEatApple() {
        player.playerXP += 2
        window.characterView.characterNode.showOverheadEmoji("🍎 아삭! +2XP", duration: 1.6)
        SoundAndEffectsManager.shared.play(.gulp)
    }

    public func treeWindowDidChop(logs: Int, apples: Int) {
        treeWindow = nil
        player.playerXP += 3 + apples
        window.characterView.characterNode.showOverheadEmoji("🪓 벌목! 원목 \(logs)+사과 \(apples)! +\(3 + apples)XP", duration: 2.2)
        SoundAndEffectsManager.shared.play(.splash)
        statusItem?.menu = buildContextMenu()
    }

    // MARK: - 고증 8차: 빵 굽기 (Bread)
    private var breadWindow: BreadWindow?
    @objc func didSelectBakeBread() {
        if breadWindow != nil { return }
        guard campfireWindow != nil else {
            window.characterView.characterNode.showOverheadEmoji("🔥 캠프파이어가 필요해!", duration: 2.0)
            SoundAndEffectsManager.shared.play(.pop)
            return
        }
        guard player.playerWheat >= 3 else {
            window.characterView.characterNode.showOverheadEmoji("🌾 밀이 3개 필요해! (\(player.playerWheat)/3)", duration: 2.0)
            SoundAndEffectsManager.shared.play(.pop)
            return
        }
        player.playerWheat -= 3
        let isPie = PumpkinWard.shared.hasPumpkin && !PumpkinWard.shared.isWorn
        if isPie {
            PumpkinWard.shared.hasPumpkin = false
        }
        let firePos = campfireWindow!.frame.origin
        let pos = CGPoint(x: firePos.x + 60, y: firePos.y)
        var bread: BreadWindow?
        bread = BreadWindow(floorPos: pos, isPumpkinPie: isPie) { [weak self, weak bread] wasPie in
            guard let self = self else { return }
            if let bread = bread, self.breadWindow === bread {
                self.breadWindow = nil
            }
            if wasPie {
                self.player.playerXP += 6
                self.window.characterView.characterNode.showOverheadEmoji("🎃 호박 파이! +6XP", duration: 2.2)
            } else {
                self.player.playerXP += 4
                self.window.characterView.characterNode.showOverheadEmoji("🍞 갓 구운 빵! +4XP", duration: 2.2)
            }
            SoundAndEffectsManager.shared.play(.gulp)
            self.statusItem?.menu = self.buildContextMenu()
        }
        breadWindow = bread
        bread!.bake()
        window.characterView.characterNode.showOverheadEmoji(isPie ? "🎃 호박 파이 굽기!" : "🍞 빵 굽기! (밀 -3)", duration: 2.0)
        statusItem?.menu = buildContextMenu()
    }

    // MARK: - Fishing (낚시)
    @objc func didSelectFishing() {
        behavior.triggerFishing(characterNode: window.characterView.characterNode)
    }

    // MARK: - H2 Trident (삼지창 충성 & 급류)
    @objc func didSelectThrowTrident() {
        let charNode = window.characterView.characterNode
        let isRiptide = charNode.isSneaking
        behavior.triggerThrowTrident(characterNode: charNode, isRiptide: isRiptide)
        let startPos = physics.position
        let facing: CGFloat = charNode.modelRoot.eulerAngles.y >= 0 ? 1 : -1
        let targetPos = CGPoint(x: startPos.x + facing * 320, y: startPos.y + 70)
        if isRiptide {
            physics.launch(vx: facing * 420, vy: 160)
            charNode.showOverheadEmoji("🌊 급류 돌진-!", duration: 2.0)
        }
        charNode.currentHeldItem = .none
        let trident = TridentEntityWindow(startPos: startPos, targetPos: targetPos) { [weak self] in
            guard let self = self else { return }
            self.window.characterView.characterNode.currentHeldItem = .trident
            self.window.characterView.characterNode.showOverheadEmoji("🔱 촥-! 복귀!", duration: 1.6)
            SoundAndEffectsManager.shared.play(.pop)
        }
        activeTridents.append(trident)
        trident.launch()
    }

    // MARK: - H3 Jukebox (주크박스 & 리듬 댄스)
    private var jukeboxWindow: JukeboxEntityWindow?
    @objc func didSelectJukebox() {
        if jukeboxWindow != nil {
            jukeboxWindow?.close()
            jukeboxWindow = nil
            return
        }
        let pos = CGPoint(x: physics.position.x + 90, y: physics.position.y)
        let jukebox = JukeboxEntityWindow(floorPos: pos) { [weak self] in
            self?.jukeboxWindow = nil
        }
        jukeboxWindow = jukebox
        jukebox.place()
        behavior.triggerJukeboxDance(characterNode: window.characterView.characterNode)
        petBehavior?.startDancing()
    }

    // MARK: - M1 Chest (보물 상자)
    private var chestWindow: ChestEntityWindow?
    @objc func didSelectChest() {
        if chestWindow != nil { return }
        let pos = CGPoint(x: physics.position.x + 85, y: physics.position.y)
        let chest = ChestEntityWindow(floorPos: pos) { [weak self] in
            guard let self = self else { return }
            self.chestWindow = nil
            self.player.playerEmeralds += 2
            self.window.characterView.characterNode.showOverheadEmoji("💎 대박! +에메랄드 2!", duration: 2.5)
            SoundAndEffectsManager.shared.play(.heart)
            self.physics.jump(impulse: 320)
        }
        chestWindow = chest
        chest.spawn()
        let char = window.characterView.characterNode
        char.showOverheadEmoji("📦 오! 보물상자다!", duration: 1.6)

        // 캐릭터가 상자로 다가가서 뚜껑을 여는 상호작용
        let targetX = pos.x - 34.0
        behavior.chargeAt(targetX: targetX, speed: 110.0, duration: 0.8, physics: physics, characterNode: char)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self, weak chest] in
            guard let self = self, let chest = chest, chest.isVisible else { return }
            char.isPoking = true
            chest.openChest()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak char] in
                char?.isPoking = false
            }
        }
    }

    // MARK: - M2 Totem (불사의 토템)
    @objc func didToggleTotem(_ sender: NSMenuItem) {
        let charNode = window.characterView.characterNode
        charNode.isTotemEquipped.toggle()
        sender.state = charNode.isTotemEquipped ? .on : .off
        if charNode.isTotemEquipped {
            charNode.showOverheadEmoji("✨ 불사의 토템 장착!", duration: 2.0)
            SoundAndEffectsManager.shared.play(.chime)
        }
        statusItem?.menu = buildContextMenu()
    }

    public func consumeTotemIfEquipped() -> Bool {
        let charNode = window.characterView.characterNode
        guard charNode.isTotemEquipped else { return false }
        charNode.isTotemEquipped = false
        charNode.isReviving = true
        charNode.showOverheadEmoji("✨ 죽음은 아직이다!", duration: 2.5)
        SoundAndEffectsManager.shared.play(.chime)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            charNode.isReviving = false
        }
        statusItem?.menu = buildContextMenu()
        return true
    }

    // MARK: - M3 Slime (슬라임 분열 몹)
    // 소환은 수동(메뉴 "🟢 슬라임 소환")만 — 자동 출현 타이머는 두지 않는다.
    var slimeWindows: [SlimeWindow] = []

    // MARK: - H4 Day/Night (낮밤 사이클)
    private var dayNightTimer: TimeInterval = 0
    private var wasNight: Bool = false
    private var didAutoEquipTorch: Bool = false
    private var sleepSkipTimer: TimeInterval = 0

    // MARK: - Weather (비·뇌우·번개)
    private var rainOverlay: RainOverlayWindow?
    private var weatherWasRaining: Bool = false
    private var creeperCharged: Bool = false

    @objc func didToggleWeather(_ sender: NSMenuItem) {
        WeatherManager.shared.isEnabled.toggle()
        sender.state = WeatherManager.shared.isEnabled ? .on : .off
        if !WeatherManager.shared.isEnabled {
            rainOverlay?.hide()
            rainOverlay = nil
            weatherWasRaining = false
        }
        statusItem?.menu = buildContextMenu()
    }

    private func updateWeather(dt: TimeInterval, screen: NSScreen) {
        WeatherManager.shared.update(dt: dt)
        let raining = WeatherManager.shared.isEnabled && WeatherManager.shared.isRaining
        if raining != weatherWasRaining {
            weatherWasRaining = raining
            if raining {
                let overlay = RainOverlayWindow(screen: screen)
                rainOverlay = overlay
                overlay.show()
                window.characterView.characterNode.showOverheadEmoji(
                    WeatherManager.shared.isThunder ? "⛈️ 우르릉! 뇌우다!" : "🌧️ 비가 오네...",
                    duration: 2.5
                )
            } else {
                rainOverlay?.hide()
                rainOverlay = nil
            }
        }
        if WeatherManager.shared.consumeStrike() {
            rainOverlay?.flashLightning()
            let strikeX = physics.position.x + CGFloat.random(in: -260...260)
            if abs(strikeX - physics.position.x) < 200 {
                window.characterView.characterNode.showOverheadEmoji("⚡ 꽈광! 깜짝이야!", duration: 2.0)
            }
        }
        if WeatherManager.shared.isThunder && creeperWindow != nil && !creeperCharged {
            creeperCharged = true
            creeperWindow?.creeperView.creeperNode.showOverheadEmoji("⚡ 충전 크리퍼!!", duration: 2.5)
            SoundAndEffectsManager.shared.play(.alert)
        }
    }
    @objc func didSelectSpawnSlime() {
        spawnSlime(size: .big, at: nil)
    }

    public func spawnSlime(size: SlimeSize, at pos: CGPoint?) {
        guard slimeWindows.count < 8 else { return }
        let spawnPos = pos ?? CGPoint(x: physics.position.x - 160, y: physics.position.y + 40)
        let slime = SlimeWindow(size: size, startPos: spawnPos, delegate: self)
        slimeWindows.append(slime)
        slime.spawn()
        if size == .big {
            window.characterView.characterNode.showOverheadEmoji("🟢 끈적한 손님이다!", duration: 2.0)
        }
    }

    public func slimeWindowDidSplit(_ window: SlimeWindow, size: SlimeSize, at pos: CGPoint) {
        slimeWindows.removeAll { $0 === window }
        guard size.smaller() != nil else { return }
        spawnSlime(size: size.smaller()!, at: CGPoint(x: pos.x - 30, y: pos.y))
        spawnSlime(size: size.smaller()!, at: CGPoint(x: pos.x + 30, y: pos.y))
        SoundAndEffectsManager.shared.play(.splash)
    }

    public func slimeWindowDidDespawn(_ window: SlimeWindow) {
        slimeWindows.removeAll { $0 === window }
        player.playerXP += 3
        player.playerEmeralds += 1
        AdvancementManager.shared.unlock(.slimeKill)
        self.window.characterView.characterNode.showOverheadEmoji("🟢 슬라임볼 +3XP +1에메!", duration: 2.0)
        SoundAndEffectsManager.shared.play(.pop)
    }

    public func attackSlime(_ slime: SlimeWindow) {
        let charNode = window.characterView.characterNode
        let dir: CGFloat = slime.position.x >= physics.position.x ? 1.0 : -1.0
        charNode.modelRoot.eulerAngles.y = dir > 0 ? (CGFloat.pi / 2.0) : (-CGFloat.pi / 2.0)
        charNode.isAttackingWeapon = true
        player.playerAttackTimer = 0.35
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak charNode] in
            charNode?.isAttackingWeapon = false
        }
        charNode.showOverheadEmoji("🗡️ 퐁!", duration: 1.2)
        SoundAndEffectsManager.shared.play(.splash)
        slime.takeHit()
    }

    // MARK: - M4 Wheat (밀 유혹 & 번식)
    @objc func didSelectWheat() {
        let charNode = window.characterView.characterNode
        charNode.currentHeldItem = .wheat
        charNode.showOverheadEmoji("🌾 밀 있다! 모여라~", duration: 2.2)
        SoundAndEffectsManager.shared.play(.pop)
        petBehavior?.enticeWithWheat()
    }

    // MARK: - L2 Milk (우유 정화)
    @objc func didSelectDrinkMilk() {
        behavior.triggerDrinkMilk(characterNode: window.characterView.characterNode)
        isBatteryAlertFired = false
        player.milkCleanseTimer = 60.0
        if player.witchSlowTimer > 0 {
            player.witchSlowTimer = 0
            behavior.walkSpeed = player.swiftTimer > 0 ? 170.0 : 85.0
        }
    }

    // MARK: - L3 Nether Portal (지옥문)
    private var portalOverlay: NetherPortalOverlayWindow?
    private var isInNether: Bool = false
    @objc func didSelectPortal() {
        if portalOverlay != nil {
            portalOverlay?.close()
            portalOverlay = nil
            return
        }
        let pos = CGPoint(x: physics.position.x + 130, y: physics.position.y)
        let portal = NetherPortalOverlayWindow(floorPos: pos)
        portalOverlay = portal
        portal.open()
        window.characterView.characterNode.showOverheadEmoji("🟣 지옥문이다...!", duration: 2.0)
        SoundAndEffectsManager.shared.play(.portal)
    }

    public func checkPortalEntry() {
        if let portal = portalOverlay, !portal.isVisible {
            portalOverlay = nil
            return
        }
        guard let portal = portalOverlay, !portal.hasEntered else { return }
        let dx = abs(physics.position.x - portal.floorPos.x)
        if dx < 45 && abs(physics.position.y - portal.floorPos.y) < 60 {
            portal.markEntered()
            isInNether.toggle()
            AdvancementManager.shared.unlock(.portalTrip)
            let charNode = window.characterView.characterNode
            if isInNether {
                charNode.showOverheadEmoji("🔥 여기가 지옥인가...!", duration: 2.5)
            } else {
                charNode.showOverheadEmoji("🌿 집으로 복귀!", duration: 2.0)
            }
            SoundAndEffectsManager.shared.play(.portal)
        }
    }

    // MARK: - Window Squash & Minimize (창 압축 최소화)
    private var squashOverlay: WindowSquashOverlayWindow?

    func canStartSquashMinimize() -> Bool {

        guard let p = physics?.currentPlatform, case .window = p.kind else { return false }
        return !behavior.isClimbing && !behavior.isTNTActive && squashOverlay == nil
    }

    @objc func didSelectSquashMinimize() {
        guard let p = physics.currentPlatform, case let .window(winID, _, pid) = p.kind else { return }
        guard let targetFrame = ScreenEnvironment.shared.windowCocoaFrame(windowID: winID) else { return }

        let overlay = WindowSquashOverlayWindow(targetFrame: targetFrame, duration: 2.0) { [weak self] in
            WindowMinimizer.shared.minimize(windowID: winID, pid: pid)
            self?.squashOverlay = nil
        }
        self.squashOverlay = overlay
        overlay.start()
        behavior.startSquashMinimize(on: p, duration: 2.0, characterNode: window.characterView.characterNode)
    }
    // MARK: - Ladder Descent (사다리 타고 창문 내려가기)
    func canStartLadderDescent() -> Bool {
        guard !behavior.isClimbing,
              let platform = physics?.currentPlatform else { return false }
        return CharacterBehaviorController.canDescend(from: platform)
    }

    @objc func didToggleShield(_ sender: NSMenuItem) {
        window.characterView.characterNode.isShieldEquipped.toggle()
        sender.state = window.characterView.characterNode.isShieldEquipped ? .on : .off
        statusItem?.menu = buildContextMenu()
        SoundAndEffectsManager.shared.play(.pop)
    }

    @objc func didSelectLadderDescent() {
        guard canStartLadderDescent(), let platform = physics.currentPlatform else { return }
        behavior.startLadderDescent(
            physics: physics,
            characterNode: window.characterView.characterNode,
            from: platform
        )
    }
}
