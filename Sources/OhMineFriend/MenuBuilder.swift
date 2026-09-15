import AppKit
import CoreGraphics

public struct ExtraMenuEntry {
    public let title: () -> String
    public let run: () -> Void
    public let keyEquivalent: String
    public let isEnabled: () -> Bool
    public init(
        _ title: @escaping () -> String,
        _ run: @escaping () -> Void,
        keyEquivalent: String = "",
        isEnabled: @escaping () -> Bool = { true }
    ) {
        self.title = title
        self.run = run
        self.keyEquivalent = keyEquivalent
        self.isEnabled = isEnabled
    }
}

public final class ClosureMenuItem: NSMenuItem {
    private let run: () -> Void
    public init(title: String, run: @escaping () -> Void, keyEquivalent: String = "", isEnabled: Bool = true) {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        self.target = self
        self.isEnabled = isEnabled
    }
    public convenience init(_ entry: ExtraMenuEntry) {
        self.init(title: entry.title(), run: entry.run, keyEquivalent: entry.keyEquivalent, isEnabled: entry.isEnabled())
    }
    public required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func fire() { run() }
}

// 메뉴 구축 전담 빌더: AppController.buildContextMenu() 본문을 그대로 옮긴 것이다.
// 게임 로직(didSelect/didToggle/물리/엔티티)은 AppController에 두고, 메뉴 조립만 담당한다.
struct MenuBuilder {
    unowned let app: AppController

    func build() -> NSMenu {
        let app = self.app
        let menu = NSMenu()
        menu.delegate = app

        // 자동 활성화 검증을 끈다. 기본값(true)에서는 AppKit이 항목을 열 때마다 '타깃이 selector에 응답하는가'만
        // 보고 활성 상태를 덮어써서, `isEnabled = canStartTNTBreak()` 같은 명시적 비활성화가 무시됐다.
        // (창문 위에 서 있지 않아 TNT를 쓸 수 없어도 항목이 활성으로 보여, 눌러도 아무 반응이 없는 상태가 됐다)
        menu.autoenablesItems = false

        // 1. Status Display
        let status = NSMenuItem(title: "마인크래프트 친구", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        app.statusMenuItem = status

        menu.addItem(NSMenuItem.separator())

        // 2. Skin Selection Submenu
        // 2. Skin Gallery & Selection
        let galleryItem = NSMenuItem(
            title: "🌐 스킨 갤러리 & 다운로더...",
            action: #selector(AppController.didSelectOpenSkinGallery),
            keyEquivalent: "g"
        )
        galleryItem.target = app
        menu.addItem(galleryItem)

        // 👕 외형 꾸미기 부모: 기본 스킨·색조 필터·크기·손 아이템을 한데 모은다.
        // 부모를 루트에 먼저 두면 이후 섹션에서 내용을 채워도 실시간 반영된다.
        let lookMenu = NSMenu()
        lookMenu.autoenablesItems = false
        let lookSubmenuItem = NSMenuItem(title: "👕 외형 꾸미기", action: nil, keyEquivalent: "")
        lookSubmenuItem.submenu = lookMenu
        menu.addItem(lookSubmenuItem)

        let skinMenu = NSMenu()
        for skin in BuiltinSkinType.allCases {
            let item = NSMenuItem(
                title: skin.displayName,
                action: #selector(AppController.didSelectBuiltinSkin(_:)),
                keyEquivalent: ""
            )
            item.target = app
            item.representedObject = skin
            if app.currentCustomSkinName == nil && skin == app.currentSkinType {
                item.state = .on
            }
            skinMenu.addItem(item)
        }

        if let customName = app.currentCustomSkinName {
            skinMenu.addItem(NSMenuItem.separator())
            let currentCustomItem = NSMenuItem(
                title: "현재 착용: \(customName)",
                action: nil,
                keyEquivalent: ""
            )
            currentCustomItem.state = .on
            currentCustomItem.isEnabled = false
            skinMenu.addItem(currentCustomItem)
        }

        skinMenu.addItem(NSMenuItem.separator())
        let customSkinItem = NSMenuItem(
            title: "📁 로컬 스킨 파일(PNG) 열기...",
            action: #selector(AppController.didSelectOpenCustomSkin),
            keyEquivalent: "o"
        )
        customSkinItem.target = app
        skinMenu.addItem(customSkinItem)

        let skinSubmenuItem = NSMenuItem(title: "👕 기본 스킨 빠른 선택", action: nil, keyEquivalent: "")
        skinSubmenuItem.submenu = skinMenu
        lookMenu.addItem(skinSubmenuItem)

        // L2. Skin Color / Hue Filter Submenu
        let filterMenu = NSMenu()
        let filters: [(name: String, hue: CGFloat, sat: CGFloat, bri: CGFloat)] = [
            ("원본 (Original)", 0.0, 1.0, 0.0),
            ("🌈 색조 회전 +90°", CGFloat.pi / 2.0, 1.0, 0.0),
            ("🌈 색조 반전 +180°", CGFloat.pi, 1.0, 0.0),
            ("🌈 네온 틴트 +270°", CGFloat.pi * 1.5, 1.3, 0.04),
            ("⬛ 흑백 레트로 (Grayscale)", 0.0, 0.0, 0.0),
            ("✨ 선명한 비비드 (Vivid)", 0.0, 1.8, 0.02)
        ]
        for f in filters {
            let fItem = NSMenuItem(
                title: f.name,
                action: #selector(AppController.didSelectSkinFilter(_:)),
                keyEquivalent: ""
            )
            fItem.target = app
            fItem.representedObject = f.name
            if app.currentSkinFilterName == f.name {
                fItem.state = .on
            }
            filterMenu.addItem(fItem)
        }
        let filterSubmenuItem = NSMenuItem(title: "🎨 스킨 색조/필터 조절", action: nil, keyEquivalent: "")
        filterSubmenuItem.submenu = filterMenu
        lookMenu.addItem(filterSubmenuItem)

        // ⚙️ 설정 부모: 루트 추가는 extra2 뒤에서, 내용은 여기서부터 채운다.
        let settingsMenu = NSMenu()
        settingsMenu.autoenablesItems = false
        let settingsSubmenuItem = NSMenuItem(title: "⚙️ 설정", action: nil, keyEquivalent: "")
        settingsSubmenuItem.submenu = settingsMenu

        // 3. Behavior Mode Submenu
        let modeMenu = NSMenu()
        for mode in BehaviorMode.allCases {
            let item = NSMenuItem(
                title: mode.rawValue,
                action: #selector(AppController.didSelectBehaviorMode(_:)),
                keyEquivalent: ""
            )
            item.target = app
            item.representedObject = mode
            if mode == app.behavior.mode {
                item.state = .on
            }
            modeMenu.addItem(item)
        }
        let modeSubmenuItem = NSMenuItem(title: "🎭 행동 모드", action: nil, keyEquivalent: "")
        modeSubmenuItem.submenu = modeMenu

        settingsMenu.addItem(modeSubmenuItem)

        // 4. Held Item Submenu
        let itemMenu = NSMenu()
        for item in HeldItem.allCases {
            let mItem = NSMenuItem(
                title: item.rawValue,
                action: #selector(AppController.didSelectHeldItem(_:)),
                keyEquivalent: ""
            )
            mItem.target = app
            mItem.representedObject = item
            if app.window.characterView.characterNode.currentHeldItem == item {
                mItem.state = .on
            }
            itemMenu.addItem(mItem)
        }
        let itemSubmenuItem = NSMenuItem(title: "🗡️ 손에 아이템 들기", action: nil, keyEquivalent: "")
        itemSubmenuItem.submenu = itemMenu
        lookMenu.addItem(itemSubmenuItem)

        // Off-hand Shield Toggle
        let shieldItem = NSMenuItem(
            title: "🛡️ 왼손에 방패 착용 (Off-hand Shield)",
            action: #selector(AppController.didToggleShield(_:)),
            keyEquivalent: ""
        )
        shieldItem.target = app
        shieldItem.state = app.window.characterView.characterNode.isShieldEquipped ? .on : .off
        lookMenu.addItem(shieldItem)

        // Elytra Toggle
        let elytraItem = NSMenuItem(
            title: "🪽 겉날개 착용 (Equip Elytra)",
            action: #selector(AppController.didToggleElytra(_:)),
            keyEquivalent: ""
        )
        elytraItem.target = app
        elytraItem.state = app.window.characterView.characterNode.isElytraEquipped ? .on : .off
        lookMenu.addItem(elytraItem)

        // L3. Enchantment Glint Toggle
        let glintItem = NSMenuItem(
            title: "🔮 무기 인챈트 광택 (Enchantment Glint)",
            action: #selector(AppController.didToggleEnchantmentGlint(_:)),
            keyEquivalent: ""
        )
        glintItem.target = app
        glintItem.state = app.window.characterView.characterNode.isEnchantedGlintEnabled ? .on : .off
        lookMenu.addItem(glintItem)
        // Pet Companion Submenu
        let petMenu = NSMenu()
        for kind in PetKind.allCases {
            let item = NSMenuItem(
                title: kind.displayName,
                action: #selector(AppController.didSelectPetKind(_:)),
                keyEquivalent: ""
            )
            item.target = app
            item.representedObject = kind
            if app.currentPetKind == kind {
                item.state = .on
            }
            petMenu.addItem(item)
        }
        petMenu.addItem(NSMenuItem.separator())
        let feedItem = NSMenuItem(
            title: "🦴 펫에게 간식/먹이 주기 (Feed)",
            action: #selector(AppController.didSelectFeedPet),
            keyEquivalent: ""
        )
        feedItem.target = app
        feedItem.isEnabled = (app.currentPetKind != nil)
        petMenu.addItem(feedItem)

        let dismissItem = NSMenuItem(
            title: "❌ 펫 소환 해제 (Dismiss)",
            action: #selector(AppController.didSelectDismissPet),
            keyEquivalent: ""
        )
        dismissItem.target = app
        if app.currentPetKind == nil {
            dismissItem.state = .on
        }
        petMenu.addItem(dismissItem)

        let petSubmenuItem = NSMenuItem(title: "🐾 펫 동반자 (Pet Companion)", action: nil, keyEquivalent: "")
        petSubmenuItem.submenu = petMenu
        menu.addItem(petSubmenuItem)

        // 5. Fun Interactions Submenu: 주제별 5개 그룹(몹 13 + 농장 15 + 펫 12 + 액션 15 + 전투 8 = 63).
        let mobEntries: [ExtraMenuEntry] = [
            ExtraMenuEntry({ "🏹 스켈레톤 소환 (Spawn Skeleton)" }, { [weak app] in app?.didSelectSpawnSkeleton() }),
            ExtraMenuEntry({ "💥 4족 크리퍼 소환 (4-Legged)" }, { [weak app] in app?.didSelectSpawnQuadCreeper() }, keyEquivalent: "k"),
            ExtraMenuEntry({ "💥 2족 크리퍼 소환 (2-Legged)" }, { [weak app] in app?.didSelectSpawnBipedCreeper() }),
            ExtraMenuEntry({ "👁️ 엔더맨 소환 (Spawn Enderman)" }, { [weak app] in app?.didSelectSpawnEnderman() }, keyEquivalent: "e"),
            ExtraMenuEntry({ "🟢 슬라임 소환 (Spawn Slime)" }, { [weak app] in app?.didSelectSpawnSlime() }),
            ExtraMenuEntry({ "🐺 야생 늑대 부르기 (Wild Wolf)" }, { [weak app] in app?.didSelectSpawnWildWolf() }),
            ExtraMenuEntry({ "🐴 야생마 부르기 (Wild Horse)" }, { [weak app] in app?.didSelectSpawnWildHorse() }),
            ExtraMenuEntry({ "🦊 여우 소환 (Spawn Fox)" }, { [weak app] in app?.didSelectSpawnFox() }),
            ExtraMenuEntry({ "🐐 염소 소환 (Spawn Goat)" }, { [weak app] in app?.didSelectSpawnGoat() }),
            ExtraMenuEntry({ "👻 팬텀 소환 (Spawn Phantom)" }, { [weak app] in app?.didSelectSpawnPhantom() }),
            ExtraMenuEntry({ "🕷️ 거미 소환 (Spawn Spider)" }, { [weak app] in app?.didSelectSpawnSpider() }),
            ExtraMenuEntry({ "🔥 가스트 소환 (Spawn Ghast)" }, { [weak app] in app?.didSelectSpawnGhast() }),
            ExtraMenuEntry({ "🧟 좀비 공성전 (Siege)" }, { [weak app] in app?.didSelectSpawnSiege() }),
            ExtraMenuEntry({ "🧙‍♀️ 마녀 소환 (Spawn Witch)" }, { [weak app] in app?.didSelectSpawnWitch() }),
        ]
        let farmEntries: [ExtraMenuEntry] = [
            ExtraMenuEntry({ "🍎 사과 냠냠 먹기" }, { [weak app] in app?.didSelectEating() }),
            ExtraMenuEntry({ "🎣 모서리 낚시하기 (Go Fishing)" }, { [weak app] in app?.didSelectFishing() }, keyEquivalent: "f"),
            ExtraMenuEntry({ "🌾 밀 들기 (Hold Wheat)" }, { [weak app] in app?.didSelectWheat() }),
            ExtraMenuEntry({ "🥛 우유 마시기 (Drink Milk)" }, { [weak app] in app?.didSelectDrinkMilk() }),
            ExtraMenuEntry({ "🌱 밀 심기 (Plant Wheat)" }, { [weak app] in app?.didSelectPlantCrop() }),
            ExtraMenuEntry({ "🐝 벌집 설치 (Beehive)" }, { [weak app] in app?.didSelectBeehive() }),
            ExtraMenuEntry({ "🧪 양조기 설치 (Brewing)" }, { [weak app] in app?.didSelectBrewStand() }),
            ExtraMenuEntry({ [weak app] in "🧑‍🌾 주민 거래 (에메랄드: \(app?.player.playerEmeralds ?? 0))" }, { [weak app] in app?.didSelectTrade() }),
            ExtraMenuEntry({ "🎂 케이크 놓기 (Cake)" }, { [weak app] in app?.didSelectCake() }),
            ExtraMenuEntry({ "🔥 캠프파이어 (Campfire)" }, { [weak app] in app?.didSelectCampfire() }),
            ExtraMenuEntry({ "🥔 감자 심기 (Potato)" }, { [weak app] in app?.didSelectPlantPotato() }),
            ExtraMenuEntry({ "🍉 수박 심기 (Melon)" }, { [weak app] in app?.didSelectPlantMelon() }),
            ExtraMenuEntry({ "🎃 호박 (심기/쓰기)" }, { [weak app] in app?.didSelectPumpkin() }),
            ExtraMenuEntry({ "🌳 사과나무 심기 (Tree)" }, { [weak app] in app?.didSelectPlantTree() }),
            ExtraMenuEntry({ [weak app] in "🍞 빵 굽기 (밀: \(app?.player.playerWheat ?? 0)/3)" }, { [weak app] in app?.didSelectBakeBread() }),
        ]
        let petActionEntries: [ExtraMenuEntry] = [
            ExtraMenuEntry({ "🐎 말 타기/내리기 (Ride)" }, { [weak app] in app?.didToggleHorseRide() }, isEnabled: { [weak app] in app?.currentPetKind == .horse }),
            ExtraMenuEntry({ "👥 친구 소환 (Summon Buddy)" }, { [weak app] in app?.didSelectSummonBuddy() }, isEnabled: { [weak app] in (app?.buddyWindows.count ?? 0) < 2 }),
            ExtraMenuEntry({ "👋 친구 보내기 (Dismiss Buddies)" }, { [weak app] in app?.didSelectDismissBuddies() }, isEnabled: { [weak app] in !(app?.buddyWindows.isEmpty ?? true) }),
            ExtraMenuEntry({ "🦎 아홀로틀 데려오기 (Axolotl)" }, { [weak app] in app?.didSelectAxolotl() }),
            ExtraMenuEntry({ "🐑 양 소환 (Spawn Sheep)" }, { [weak app] in app?.didSelectSpawnSheep() }),
            ExtraMenuEntry({ "🔔 종 울리기 (Bell)" }, { [weak app] in app?.didSelectRingBell() }),
            ExtraMenuEntry({ "🐔 닭 소환 (Chicken)" }, { [weak app] in app?.didSelectSpawnChicken() }),
            ExtraMenuEntry({ "🍄 무쉬룸 소환 (Mooshroom)" }, { [weak app] in app?.didSelectSpawnMooshroom() }),
            ExtraMenuEntry({ "🧶 리드줄 묶기/풀기 (Lead)" }, { [weak app] in app?.didSelectToggleLead() }),
            ExtraMenuEntry({ "🧭 스폰 나침반 (Compass)" }, { [weak app] in app?.didSelectCompass() }),
        ]
        let moveEntries: [ExtraMenuEntry] = [
            ExtraMenuEntry({ "🤸‍♂️ 공중제비 (Backflip)" }, { [weak app] in app?.didSelectBackflip() }, keyEquivalent: "b"),
            ExtraMenuEntry({ "🕺 쉬프트 댄스 (Sneak Dance)" }, { [weak app] in app?.didSelectSneakDance() }, keyEquivalent: "t"),
            ExtraMenuEntry({ "👋 손 흔들기 (Wave)" }, { [weak app] in app?.didSelectWave() }, keyEquivalent: "w"),
            ExtraMenuEntry({ "⛏️ 블록 설치하고 캐기" }, { [weak app] in app?.didSelectPlaceAndMine() }),
            ExtraMenuEntry({ "💤 지금 낮잠자기 (Sleep)" }, { [weak app] in app?.didSelectSleep() }, keyEquivalent: "z"),
            ExtraMenuEntry({ "🪜 사다리 타고 창문 내려가기 (Ladder Descent)" }, { [weak app] in app?.didSelectLadderDescent() }, keyEquivalent: "l", isEnabled: { [weak app] in app?.canStartLadderDescent() ?? false }),
            ExtraMenuEntry({ "🪑 상단 메뉴바에 걸터앉기" }, { [weak app] in app?.didSelectSitOnMenuBar() }, keyEquivalent: "m"),
            ExtraMenuEntry({ "🎉 코딩 신나게 응원하기 (Cheer)" }, { [weak app] in app?.didSelectCheer() }, keyEquivalent: "c"),
            ExtraMenuEntry({ "💢 알림 안 읽는다고 구박하기 (Nag)" }, { [weak app] in app?.didSelectNag() }, keyEquivalent: "n"),
            ExtraMenuEntry({ "🎶 주크박스 틀기 (Jukebox)" }, { [weak app] in app?.didSelectJukebox() }),
            ExtraMenuEntry({ "📦 보물상자 소환 (Chest)" }, { [weak app] in app?.didSelectChest() }),
            ExtraMenuEntry({ "🟣 지옥문 열기 (Nether Portal)" }, { [weak app] in app?.didSelectPortal() }),
            ExtraMenuEntry({ "🛒 광산 수레 타기 (Minecart)" }, { [weak app] in app?.didSelectMinecart() }),
            ExtraMenuEntry({ "🏆 발전 과제 (\(AdvancementManager.shared.unlockedCount)/\(AdvancementID.allCases.count))" }, { [weak app] in app?.didSelectAdvancements() }),
        ]
        let combatEntries: [ExtraMenuEntry] = [
            ExtraMenuEntry({ "🔱 삼지창 던지기 (Throw Trident)" }, { [weak app] in app?.didSelectThrowTrident() }),
            ExtraMenuEntry({ "✨ 불사의 토템 들기 (Totem)" }, { [weak app] in app?.didToggleTotemFromMenu() }),
            ExtraMenuEntry({ [weak app] in "📖 인챈트 테이블 (XP: \(app?.player.playerXP ?? 0))" }, { [weak app] in app?.didSelectEnchantTable() }),
            ExtraMenuEntry({ [weak app] in (app?.isDefenseMode == true) ? "🏹 디펜스전 모드 (웨이브 \(app?.defenseWave ?? 1))" : "🏹 디펜스전 모드" }, { [weak app] in app?.didToggleDefenseModeFromMenu() }),
            ExtraMenuEntry({ "⛄ 눈 골렘 조립 (Snow Golem)" }, { [weak app] in app?.didSelectBuildGolem() }),
            ExtraMenuEntry({ [weak app] in "🎺 뿔피리 불기 (뿔: \(app?.player.playerHorns ?? 0))" }, { [weak app] in app?.didSelectBlowHorn() }),
            ExtraMenuEntry({ "🎯 과녁 설치 (Target)" }, { [weak app] in app?.didSelectPlaceTarget() }),
            ExtraMenuEntry({ [weak app] in "🏹 과녁 쏘기 (점수: \(app?.archeryScore ?? 0))" }, { [weak app] in app?.didSelectShootTarget() }, isEnabled: { [weak app] in app?.targetWindow != nil }),
        ]
        let emoteEntries: [ExtraMenuEntry] = CharacterEmote.allCases.map { emote in
            ExtraMenuEntry({ emote.menuTitle }, { [weak app] in app?.runEmote(emote) })
        }
        let actSubmenuItem = makeSearchableMenu(title: "✨ 재미있는 모션 실행", groups: [
            ("👾 몹 소환", mobEntries),
            ("🌾 농장·음식", farmEntries),
            ("🐾 펫·동물", petActionEntries),
            ("🤸 액션·이동", moveEntries),
            ("🙌 감정 표현", emoteEntries),
            ("⚔️ 전투·도구", combatEntries),
        ])
        menu.addItem(actSubmenuItem)
        func findActItem(in rootMenu: NSMenu?, matching predicate: (String) -> Bool) -> NSMenuItem? {
            guard let rootMenu = rootMenu else { return nil }
            for item in rootMenu.items {
                if predicate(item.title) { return item }
                if let found = findActItem(in: item.submenu, matching: predicate) { return found }
            }
            return nil
        }
        app.ladderMenuItem = findActItem(in: actSubmenuItem.submenu, matching: { $0 == "🪜 사다리 타고 창문 내려가기 (Ladder Descent)" })
        if app.window.characterView.characterNode.isTotemEquipped {
            findActItem(in: actSubmenuItem.submenu, matching: { $0 == "✨ 불사의 토템 들기 (Totem)" })?.state = .on
        }
        if app.isDefenseMode {
            findActItem(in: actSubmenuItem.submenu, matching: { $0.hasPrefix("🏹 디펜스전 모드") })?.state = .on
        }

        // 4. Scale Submenu
        let scaleMenu = NSMenu()
        let scales: [(String, CGFloat)] = [
            ("아주 작게 (50%)", 0.5),
            ("작게 (70%)", 0.7),
            ("약간 작게 (85%)", 0.85),
            ("기본 (100%)", 1.0),
            ("약간 크게 (125%)", 1.25),
            ("크게 (150%)", 1.5),
            ("매우 크게 (175%)", 1.75),
            ("거대하게 (200%)", 2.0),
            ("초거대 (250%)", 2.5)
        ]

        var matchedPreset = false
        for (name, scaleVal) in scales {
            let item = NSMenuItem(
                title: name,
                action: #selector(AppController.didSelectScale(_:)),
                keyEquivalent: ""
            )
            item.target = app
            item.representedObject = scaleVal
            if abs(app.window.currentScale - scaleVal) < 0.02 {
                item.state = .on
                matchedPreset = true
            }
            scaleMenu.addItem(item)
        }

        scaleMenu.addItem(NSMenuItem.separator())

        if !matchedPreset {
            let currentPct = Int(round(app.window.currentScale * 100))
            let customCurrentItem = NSMenuItem(
                title: "현재 지정: \(currentPct)%",
                action: nil,
                keyEquivalent: ""
            )
            customCurrentItem.state = .on
            customCurrentItem.isEnabled = false
            scaleMenu.addItem(customCurrentItem)
            scaleMenu.addItem(NSMenuItem.separator())
        }

        let customScaleItem = NSMenuItem(
            title: "✏️ 크기 직접 입력 (Custom Size)...",
            action: #selector(AppController.didSelectCustomScale),
            keyEquivalent: "s"
        )
        customScaleItem.target = app
        scaleMenu.addItem(customScaleItem)
        let scaleSubmenuItem = NSMenuItem(title: "📏 캐릭터 크기", action: nil, keyEquivalent: "")
        scaleSubmenuItem.submenu = scaleMenu
        lookMenu.addItem(scaleSubmenuItem)

        menu.addItem(NSMenuItem.separator())

        // 🛠️ 고급 부모: 루트에 설정 다음으로 둔다. 내용은 여기서부터 채운다.
        let advancedMenu = NSMenu()
        advancedMenu.autoenablesItems = false
        let advancedSubmenuItem = NSMenuItem(title: "🛠️ 고급", action: nil, keyEquivalent: "")
        advancedSubmenuItem.submenu = advancedMenu
        menu.addItem(settingsSubmenuItem)
        menu.addItem(advancedSubmenuItem)

        // 5. Actions
        let jumpItem = NSMenuItem(
            title: "🦘 폴짝 뛰기 (Jump)",
            action: #selector(AppController.didSelectJump),
            keyEquivalent: "j"
        )
        jumpItem.target = app
        advancedMenu.addItem(jumpItem)

        let resetItem = NSMenuItem(
            title: "🪟 바닥으로 소환 (Reset to Floor)",
            action: #selector(AppController.didSelectResetFloor),
            keyEquivalent: "r"
        )
        resetItem.target = app
        advancedMenu.addItem(resetItem)

        // Sound SFX Toggle
        let soundItem = NSMenuItem(
            title: "🔊 효과음 (Sound SFX)",
            action: #selector(AppController.didToggleSoundSFX(_:)),
            keyEquivalent: ""
        )
        soundItem.target = app
        soundItem.state = SoundAndEffectsManager.shared.isSoundEnabled ? .on : .off
        settingsMenu.addItem(soundItem)

        // H4. Day/Night Mode Submenu
        let dayNightMenu = NSMenu()
        for mode in DayNightMode.allCases {
            let item = NSMenuItem(
                title: mode.rawValue,
                action: #selector(AppController.didSelectDayNightMode(_:)),
                keyEquivalent: ""
            )
            item.target = app
            item.representedObject = mode
            if DayNightCycleManager.shared.mode == mode {
                item.state = .on
            }
            dayNightMenu.addItem(item)
        }
        let dayNightSubmenuItem = NSMenuItem(title: "☀️/🌙 낮밤 모드 (Day/Night)", action: nil, keyEquivalent: "")
        dayNightSubmenuItem.submenu = dayNightMenu
        settingsMenu.addItem(dayNightSubmenuItem)

        // Weather Toggle
        let weatherItem = NSMenuItem(
            title: "🌧️ 날씨 모드 (비·뇌우)",
            action: #selector(AppController.didToggleWeather(_:)),
            keyEquivalent: ""
        )
        weatherItem.target = app
        weatherItem.state = WeatherManager.shared.isEnabled ? .on : .off
        settingsMenu.addItem(weatherItem)

        // Creeper Form Submenu
        let creeperFormMenu = NSMenu()
        let quadItem = NSMenuItem(
            title: "4족 크리퍼 (원작)",
            action: #selector(AppController.didSelectCreeperLegPreference(_:)),
            keyEquivalent: ""
        )
        quadItem.target = app
        quadItem.representedObject = CreeperLegType.quadruped.rawValue
        if app.preferredCreeperLegType == .quadruped {
            quadItem.state = .on
        }
        creeperFormMenu.addItem(quadItem)

        let bipedItem = NSMenuItem(
            title: "2족 크리퍼 (직립)",
            action: #selector(AppController.didSelectCreeperLegPreference(_:)),
            keyEquivalent: ""
        )
        bipedItem.target = app
        bipedItem.representedObject = CreeperLegType.biped.rawValue
        if app.preferredCreeperLegType == .biped {
            bipedItem.state = .on
        }
        creeperFormMenu.addItem(bipedItem)

        let randomItem = NSMenuItem(
            title: "🎲 무작위 (50:50 Random)",
            action: #selector(AppController.didSelectCreeperLegPreference(_:)),
            keyEquivalent: ""
        )
        randomItem.target = app
        randomItem.representedObject = "random"
        if app.preferredCreeperLegType == nil {
            randomItem.state = .on
        }
        creeperFormMenu.addItem(randomItem)

        let creeperFormSubmenuItem = NSMenuItem(title: "💥 크리퍼 형태 선택", action: nil, keyEquivalent: "")
        creeperFormSubmenuItem.submenu = creeperFormMenu
        settingsMenu.addItem(creeperFormSubmenuItem)


        // Skeleton Spawning Toggle
        let skelToggleItem = NSMenuItem(
            title: "👾 가끔 스켈레톤 출현 모드",
            action: #selector(AppController.didToggleSkeletonSpawn(_:)),
            keyEquivalent: ""
        )
        skelToggleItem.target = app
        skelToggleItem.state = app.isSkeletonSpawnEnabled ? .on : .off
        advancedMenu.addItem(skelToggleItem)
        // Typing Cheer Toggle
        let typingCheerItem = NSMenuItem(
            title: "⌨️ 타이핑 응원 모드 (WPM 감지)",
            action: #selector(AppController.didToggleTypingCheer(_:)),
            keyEquivalent: ""
        )
        typingCheerItem.target = app
        typingCheerItem.state = TypingActivityMonitor.shared.isEnabled ? .on : .off
        settingsMenu.addItem(typingCheerItem)

        // 타이핑 감지 상태 줄 — 메뉴를 열 때마다 AppController.menuNeedsUpdate 가 현재 WPM 으로 갱신한다
        let typingStatusItem = NSMenuItem(title: app.typingStatusTitle(), action: nil, keyEquivalent: "")
        typingStatusItem.isEnabled = false
        app.typingStatusItem = typingStatusItem
        settingsMenu.addItem(typingStatusItem)

        // Notification Nag Toggle
        let nagToggleItem = NSMenuItem(
            title: "🔔 쌓인 알림 잔소리/구박 모드",
            action: #selector(AppController.didToggleNotificationNag(_:)),
            keyEquivalent: ""
        )
        nagToggleItem.target = app


        // CPU Power Mode Toggle
        let powerModeItem = NSMenuItem(
            title: "⚡ CPU 파워 모드",
            action: #selector(AppController.didTogglePowerMode(_:)),
            keyEquivalent: ""
        )
        powerModeItem.target = app
        powerModeItem.state = app.isPowerModeEnabled ? .on : .off
        settingsMenu.addItem(powerModeItem)

        // Granular Brightness Submenu
        let brightnessMenu = NSMenu()
        for preset in StageBrightness.presets {
            let bItem = NSMenuItem(
                title: preset.title,
                action: #selector(AppController.didSelectBrightnessLevel(_:)),
                keyEquivalent: ""
            )
            bItem.target = app
            bItem.representedObject = preset.level
            if abs(StageBrightness.level - preset.level) < 0.01 {
                bItem.state = .on
            }
            brightnessMenu.addItem(bItem)
        }
        let brightnessSubmenuItem = NSMenuItem(title: "💡 화면 밝기 조절 (Brightness)", action: nil, keyEquivalent: "")
        brightnessSubmenuItem.submenu = brightnessMenu
        settingsMenu.addItem(brightnessSubmenuItem)

        // 3D Lighting Effect Toggle (기본값: OFF)
        let lightingToggleItem = NSMenuItem(
            title: "✨ 3D 입체 광원 효과",
            action: #selector(AppController.didToggleLightingEffect(_:)),
            keyEquivalent: ""
        )
        lightingToggleItem.target = app
        lightingToggleItem.state = StageBrightness.isLightingEffectEnabled ? .on : .off
        settingsMenu.addItem(lightingToggleItem)

        // L4. Battery Hunger Toggle
        let batteryToggleItem = NSMenuItem(
            title: "🍗 맥북 배터리 연동 허기 모드",
            action: #selector(AppController.didToggleBatteryHunger(_:)),
            keyEquivalent: ""
        )
        batteryToggleItem.target = app
        batteryToggleItem.state = app.isBatteryHungerEnabled ? .on : .off
        settingsMenu.addItem(batteryToggleItem)
        nagToggleItem.state = NotificationCenterMonitor.shared.isEnabled ? .on : .off
        settingsMenu.addItem(nagToggleItem)

        // Update Check in Settings Menu
        settingsMenu.addItem(NSMenuItem.separator())
        let updateTitle: String
        if let update = UpdateManager.shared.availableUpdate {
            updateTitle = "🚀 새 버전(v\(update.version)) 업데이트 가능!"
        } else {
            updateTitle = "🔄 업데이트 확인 (v\(UpdateManager.currentVersion))..."
        }
        let settingsUpdateItem = NSMenuItem(
            title: updateTitle,
            action: #selector(AppController.didSelectCheckForUpdates),
            keyEquivalent: ""
        )
        settingsUpdateItem.target = app
        settingsMenu.addItem(settingsUpdateItem)

        // Creeper Spawning Toggle
        let creeperToggleItem = NSMenuItem(
            title: "👾 가끔 크리퍼 출현 모드",
            action: #selector(AppController.didToggleCreeperSpawn(_:)),
            keyEquivalent: ""
        )

        // Enderman Spawning Toggle
        let endermanToggleItem = NSMenuItem(
            title: "👾 가끔 엔더맨 출현 모드",
            action: #selector(AppController.didToggleEndermanSpawn(_:)),
            keyEquivalent: ""
        )
        endermanToggleItem.target = app
        endermanToggleItem.state = app.isEndermanSpawnEnabled ? .on : .off
        advancedMenu.addItem(endermanToggleItem)
        creeperToggleItem.target = app
        creeperToggleItem.state = app.isCreeperSpawnEnabled ? .on : .off
        advancedMenu.addItem(creeperToggleItem)


        let squashItem = NSMenuItem(
            title: "🗜️ 이 창 압축해서 Dock으로 치우기",
            action: #selector(AppController.didSelectSquashMinimize),
            keyEquivalent: ""
        )
        squashItem.target = app
        squashItem.isEnabled = app.canStartSquashMinimize()
        advancedMenu.addItem(squashItem)
        let attackItem = NSMenuItem(
            title: "🧨 TNT로 창 부수기",
            action: #selector(AppController.didSelectTNTBreak),
            keyEquivalent: ""
        )
        attackItem.target = app
        attackItem.isEnabled = app.canStartTNTBreak()
        app.attackMenuItem = attackItem
        advancedMenu.addItem(attackItem)
        menu.addItem(NSMenuItem.separator())

        // 5. Update Check in Root Menu
        let rootUpdateItem = NSMenuItem(
            title: updateTitle,
            action: #selector(AppController.didSelectCheckForUpdates),
            keyEquivalent: "u"
        )
        rootUpdateItem.target = app
        menu.addItem(rootUpdateItem)

        // 6. Quit
        let quitItem = NSMenuItem(
            title: "종료 (Quit)",
            action: #selector(AppController.didSelectQuit),
            keyEquivalent: "q"
        )
        quitItem.target = app
        menu.addItem(quitItem)

        return menu
    }
}
