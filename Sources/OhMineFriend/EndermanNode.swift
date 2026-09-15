import AppKit
import SceneKit
import CoreGraphics

public final class EndermanNode: SCNNode {
    // Joint Hierarchy
    public let modelRoot = SCNNode()
    public let bodyAnchor = SCNNode()
    public let headJoint = SCNNode()
    public let headMesh = SCNNode()
    public let jawNode = SCNNode() // Lower jaw that hinges open when staring/enraged

    public let armLeftJoint = SCNNode()
    public let armRightJoint = SCNNode()

    public let legLeftJoint = SCNNode()
    public let legRightJoint = SCNNode()

    // Carried Grass Block
    public let carriedBlockNode = SCNNode()

    // Overhead Emoji
    public let overheadEmojiNode = SCNNode()

    // Animation Properties
    public var walkSpeed: CGFloat = 0
    public var isStaring: Bool = false
    public var isEnraged: Bool = false
    public var isDying: Bool = false
    public var isCarryingBlock: Bool = true {
        didSet { carriedBlockNode.isHidden = !isCarryingBlock }
    }

    private var animTime: CGFloat = 0

    // Materials
    private let blackMat = SCNMaterial()
    private let purpleEyeMat = SCNMaterial()
    private let redHurtMat = SCNMaterial()
    private let dirtMat = SCNMaterial()
    private let grassTopMat = SCNMaterial()

    public override init() {
        super.init()
        setupMaterials()
        setupHierarchy()
        setupModel()
        setupCarriedBlock()
        setupEmojiBillboard()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupMaterials() {
        let enderBase = NSColor(red: 0.08, green: 0.08, blue: 0.08, alpha: 1.0)
        let grainMat = MobTexture.material(width: 16, height: 16, seed: 13) { _, _, r in
            r < 0.12 ? MobTexture.shade(color: enderBase, by: 1.7) : enderBase
        }
        blackMat.diffuse.contents = grainMat.diffuse.contents
        blackMat.diffuse.magnificationFilter = .nearest
        blackMat.diffuse.minificationFilter = .nearest
        blackMat.lightingModel = .physicallyBased
        blackMat.roughness.contents = 0.95
        blackMat.metalness.contents = 0.0

        purpleEyeMat.diffuse.contents = NSColor(red: 0.85, green: 0.20, blue: 0.95, alpha: 1.0) // Glowing purple eyes
        purpleEyeMat.lightingModel = .constant

        redHurtMat.diffuse.contents = NSColor(red: 0.90, green: 0.15, blue: 0.15, alpha: 1.0)
        redHurtMat.lightingModel = .physicallyBased
        redHurtMat.roughness.contents = 0.85
        redHurtMat.metalness.contents = 0.0

        dirtMat.diffuse.contents = NSColor(red: 0.48, green: 0.32, blue: 0.18, alpha: 1.0)
        dirtMat.lightingModel = .physicallyBased
        dirtMat.roughness.contents = 1.0
        dirtMat.metalness.contents = 0.0

        grassTopMat.diffuse.contents = NSColor(red: 0.32, green: 0.65, blue: 0.22, alpha: 1.0)
        grassTopMat.lightingModel = .physicallyBased
        grassTopMat.roughness.contents = 0.95
        grassTopMat.metalness.contents = 0.0
    }

    private func setupHierarchy() {
        addChildNode(modelRoot)
        modelRoot.addChildNode(bodyAnchor)

        bodyAnchor.addChildNode(headJoint)
        headJoint.addChildNode(headMesh)
        headJoint.addChildNode(jawNode)

        bodyAnchor.addChildNode(armLeftJoint)
        bodyAnchor.addChildNode(armRightJoint)
        bodyAnchor.addChildNode(legLeftJoint)
        bodyAnchor.addChildNode(legRightJoint)

        bodyAnchor.addChildNode(carriedBlockNode)
    }

    private func setupEmojiBillboard() {
        overheadEmojiNode.position = SCNVector3(0, 3.2, 0)
        overheadEmojiNode.isHidden = true
        overheadEmojiNode.constraints = [SCNBillboardConstraint()]
        bodyAnchor.addChildNode(overheadEmojiNode)
    }

    public func showOverheadEmoji(_ emoji: String, duration: TimeInterval = 1.8) {
        overheadEmojiNode.childNodes.forEach { $0.removeFromParentNode() }

        let bubble = EmojiBubble.node(for: emoji, worldHeight: emoji.count > 6 ? 0.4 : 0.55)
        overheadEmojiNode.addChildNode(bubble)
        overheadEmojiNode.isHidden = false
        overheadEmojiNode.opacity = 1.0
        overheadEmojiNode.position.y = 3.0

        SCNTransaction.begin()
        SCNTransaction.animationDuration = duration
        overheadEmojiNode.position.y = 3.5
        overheadEmojiNode.opacity = 0.0
        SCNTransaction.commit()
    }

    // MARK: - 3D Enderman Model Builder
    private func setupModel() {
        // 1. Torso: Tall and thin (W=0.35, H=0.85, L=0.22) at Y=1.70
        let torsoBox = SCNBox(width: 0.35, height: 0.85, length: 0.22, chamferRadius: 0)
        torsoBox.materials = [blackMat]
        bodyAnchor.geometry = torsoBox
        bodyAnchor.position = SCNVector3(0, 1.70, 0)

        // 2. Head Joint at Y=0.55 relative to torso
        headJoint.position = SCNVector3(0, 0.55, 0)

        // Upper Head: W=0.45, H=0.32, L=0.45
        let upperHeadBox = SCNBox(width: 0.45, height: 0.32, length: 0.45, chamferRadius: 0)
        upperHeadBox.materials = [blackMat]
        headMesh.geometry = upperHeadBox
        headMesh.position = SCNVector3(0, 0.16, 0)

        // Glowing Purple Eyes (2 blocks, larger for readability at distance)
        let eyeBox = SCNBox(width: 0.13, height: 0.08, length: 0.02, chamferRadius: 0)
        eyeBox.materials = [purpleEyeMat]
        let eyeL = SCNNode(geometry: eyeBox)
        eyeL.position = SCNVector3(-0.11, 0.02, 0.23)
        let eyeR = SCNNode(geometry: eyeBox)
        eyeR.position = SCNVector3(0.11, 0.02, 0.23)
        headMesh.addChildNode(eyeL)
        headMesh.addChildNode(eyeR)

        // Lower Jaw (Hinges downwards when enraged/staring!): W=0.44, H=0.14, L=0.44
        let jawBox = SCNBox(width: 0.44, height: 0.14, length: 0.44, chamferRadius: 0)
        jawBox.materials = [blackMat]
        jawNode.geometry = jawBox
        jawNode.position = SCNVector3(0, -0.07, 0)

        // 3. Long Slender Arms (W=0.10, H=1.35, L=0.10)
        let armBox = SCNBox(width: 0.10, height: 1.35, length: 0.10, chamferRadius: 0)
        armBox.materials = [blackMat]

        armLeftJoint.position = SCNVector3(-0.28, 0.35, 0)
        let armLMesh = SCNNode(geometry: armBox)
        armLMesh.position = SCNVector3(0, -0.60, 0)
        armLeftJoint.addChildNode(armLMesh)

        armRightJoint.position = SCNVector3(0.28, 0.35, 0)
        let armRMesh = SCNNode(geometry: armBox)
        armRMesh.position = SCNVector3(0, -0.60, 0)
        armRightJoint.addChildNode(armRMesh)

        // 4. Long Slender Legs (W=0.10, H=1.45, L=0.10)
        let legBox = SCNBox(width: 0.10, height: 1.45, length: 0.10, chamferRadius: 0)
        legBox.materials = [blackMat]

        legLeftJoint.position = SCNVector3(-0.10, -0.42, 0)
        let legLMesh = SCNNode(geometry: legBox)
        legLMesh.position = SCNVector3(0, -0.68, 0)
        legLeftJoint.addChildNode(legLMesh)

        legRightJoint.position = SCNVector3(0.10, -0.42, 0)
        let legRMesh = SCNNode(geometry: legBox)
        legRMesh.position = SCNVector3(0, -0.68, 0)
        legRightJoint.addChildNode(legRMesh)
    }

    private func setupCarriedBlock() {
        // Authentic Minecraft Grass Block held in hands (W=0.50, H=0.50, L=0.50)
        let blockGeom = SCNBox(width: 0.50, height: 0.50, length: 0.50, chamferRadius: 0)
        // Materials: [Front, Right, Back, Left, Top, Bottom]
        blockGeom.materials = [dirtMat, dirtMat, dirtMat, dirtMat, grassTopMat, dirtMat]
        carriedBlockNode.geometry = blockGeom
        // 손 높이(엉덩이 앞)에 매달려 있다 — 팔(관절 x ±0.28)이 상자 옆면을 잡는다.
        // 상자를 가슴 앞·더 넓게(0.55) 두면 정면에서 팔이 상자에 완전히 가려졌다
        // (왼팔 바깥 모서리 0.062 대 상자 끝 0.275 → 노출 0).
        carriedBlockNode.position = SCNVector3(0, -0.82, 0.60)
    }

    // MARK: - Animation Loop
    public func update(deltaTime dt: CGFloat) {
        animTime += dt

        // 1. Dying Animation
        if isDying {
            modelRoot.eulerAngles.z = min(CGFloat.pi / 2.0, modelRoot.eulerAngles.z + dt * 4.0)
            bodyAnchor.position.y = max(0.4, bodyAnchor.position.y - dt * 2.0)
            return
        }

        // 2. Staring / Enraged unhinged jaw & angry shaking
        if isStaring || isEnraged {
            // Unhinge jaw downwards! (Iconic terrifying Enderman face)
            let openAmount: CGFloat = isEnraged ? 0.32 : 0.22
            jawNode.position.y = -0.07 - openAmount

            // Head and jaw tremble with wrath
            let tremble = sin(animTime * 35.0) * 0.05
            headJoint.eulerAngles.x = isEnraged ? (-0.25 + tremble) : (-0.10 + tremble)
            headJoint.eulerAngles.z = sin(animTime * 28.0) * 0.04

            // Arms flail or point forward aggressively
            if isEnraged {
                let flail = sin(animTime * 20.0) * 0.5
                armLeftJoint.eulerAngles = SCNVector3(-1.8 + flail, 0, -0.2)
                armRightJoint.eulerAngles = SCNVector3(-1.8 - flail, 0, 0.2)
            }
        } else {
            // Closed jaw
            jawNode.position.y = -0.07
            headJoint.eulerAngles = SCNVector3Zero
        }

        // 3. Carrying Block Arm Posture
        // 팔을 상자 *옆*에 세워 든다: 상자(x ±0.25)보다 바깥(x ±0.28)에 팔이 있어야
        // 정면에서 팔이 보인다. 앞으로 크게 젖히면(-0.95) 손이 상자 앞·아래로 빠져
        // 팔 몸통이 상자를 관통했다(중심선 46%가 상자 내부).
        if isCarryingBlock && !isEnraged {
            armLeftJoint.eulerAngles = SCNVector3(-0.45, 0, 0)
            armRightJoint.eulerAngles = SCNVector3(-0.45, 0, 0)
        }

        // 4. Stride / Walking Animation
        let isMoving = abs(walkSpeed) > 5.0
        if isMoving {
            let speedMult: CGFloat = isEnraged ? 18.0 : 8.0
            let strideAmp: CGFloat = isEnraged ? 0.65 : 0.40
            let cycle = sin(animTime * speedMult)
            legLeftJoint.eulerAngles.x = cycle * strideAmp
            legRightJoint.eulerAngles.x = -cycle * strideAmp

            if !isCarryingBlock && !isEnraged {
                armLeftJoint.eulerAngles.x = -cycle * strideAmp
                armRightJoint.eulerAngles.x = cycle * strideAmp
            }
        } else {
            legLeftJoint.eulerAngles.x = 0
            legRightJoint.eulerAngles.x = 0
        }
    }
}
