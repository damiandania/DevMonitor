import QuartzCore
import AppKit

/// A procedural, vector notch CAT — built the way Codrops' teardown of Claude's mascot describes
/// (rectangles only, behaviours as timelines of transforms + easings), but with feline anatomy:
/// ears that twitch, a tail that swishes, a nose + "ω" mouth, and cat-shaped behaviours
/// (prowling, pouncing, grooming, loafing).
///
/// Why layers and not SwiftUI/`NSImageView`: this lives in a never-key floating panel beside the
/// notch. AppKit view animations only run while their window is key; layer animations run on the
/// render server regardless — so the cat keeps moving even though the panel is pure decoration.
///
/// The cat is designed in a fixed 100×100 box (bottom-up, like the article's SVG but with AppKit's
/// Y axis) and scaled to the bar's height; the bar's LEFT strip is its stage. It lives at the
/// CENTRE of that stage — every animation starts and ends there — and the roaming vignettes sweep
/// both halves, growing with the stage width. Black-on-black: the WHOLE cat matches the notch bezel,
/// so all that shows is its face — white eyes, nose and mouth — plus whatever prop or event badge
/// the moment calls for. The invisible limbs still animate; their motion carries into the face,
/// which is all the viewer needs.
@MainActor
final class ClaudeMascot {
    /// What the cat is doing right now, chosen by `QuotaHUDController`. The first three are
    /// CONTINUOUS (they hold while their condition holds); the rest are transient EVENT animations
    /// the controller shows for ~3 seconds when something happens.
    enum Mood: Equatable {
        case idle         // baseline: rotates through cat vignettes (prowl, pounce, groom…)
        case working      // a build is running: hammering with an orange hammer
        case gearedUp     // event: a worker just started — hard hat drops on, determined nod
        case previewing   // CONTINUOUS while a preview serves — watching a little glowing screen
        case pressured    // machine under pressure: panting + sweat (outranks everything)
        case failed       // event: something failed — the eyes turn into red X's + a firm shake
        case launching    // CONTINUOUS while a server boots — a rocket vibrates beside the cat
        case completed    // event: a server came up — the rocket LIFTS OFF + green check eyes
        case exploded     // event: a server died mid-launch — the rocket EXPLODES + red X eyes
        case celebrating  // event: a build finished OK — check eyes, hops + confetti
        case caffeinated  // event: keep-awake switched on — a steaming coffee, a couple of sips
        case loved        // event: you CLICKED the cat — heart eyes + a shower of hearts float up
    }

    /// Add the cat's root layer to the host (the bar's left strip). Sizing happens in `layout`,
    /// which the controller calls once the bar frame is known and again on screen changes.
    let root = CALayer()

    // The cat, part by part — all rectangles, matching the article. Kept as stored properties so
    // each mood's timeline can target them by name.
    private let tail      = CALayer()   // added first so the body hides its base joint
    private let leftFoot  = CALayer()
    private let rightFoot = CALayer()
    private let body      = CALayer()
    private let leftEar   = CALayer()   // children of the body: they ride its arch/breath
    private let rightEar  = CALayer()
    private let leftEye   = CALayer()
    private let rightEye  = CALayer()
    private let leftArm   = CALayer()   // front paws; pivot at the shoulder
    private let rightArm  = CALayer()
    private let heldProp  = CALayer()   // mug / dumbbell — child of the right paw
    private let floatProp = CALayer()   // the doze vignette's Zzz — drifts up independently
    private let fx        = CALayer()   // sweat droplet
    private let confetti  = CALayer()   // celebration particles, above the head
    private let rocket    = CALayer()   // the launch rocket, parked beside the cat's right cheek
    private let rocketFlame = CALayer() // its engine flame — hidden until liftoff
    private let smoke     = CALayer()   // smoke/debris container: wisps, liftoff billow, explosion
    private let floorProp = CALayer()   // ground prop: the preview's little screen
    private let hat       = CALayer()   // the worker's hard hat, dropped on at worker start
    private let leftEyeFX  = CALayer()  // event eye overlays: red X (failure) / green check (success)
    private let rightEyeFX = CALayer()

    private var mood: Mood?
    private var backing: CGFloat = 2     // screen backing scale, for crisp corners
    private var homeX: CGFloat = 0       // resting position (points): the centre of the stage
    private var walkSpan: CGFloat = 0    // roaming room per side for the travelling vignettes

    /// Idle variety: every few seconds pick a different little scene, so "nothing happening" still
    /// feels alive. `.rest` is the sitting-cat baseline (slow blinks, glances).
    private enum Vignette: CaseIterable { case rest, prowl, pounce, groom, gym, doze, jam, stretch }
    private var idleTimer: Timer?
    private var lastVignette: Vignette = .rest

    // Palette (sRGB). A brown TABBY cat: a warm caramel coat with darker-brown stripes, a cream
    // muzzle, a pink nose and inner ears, and near-white whiskers — a proper cat on the black bar,
    // not a black blob. Event colours (red / amber / green) still swap in for failure / launch /
    // success on top of the face.
    // Minimal: only the WHITE face (eyes, nose, "ω" mouth, whiskers) shows on the black bar; the
    // body / limbs are invisible, so what reads is the notch itself come alive.
    private static let cBody = rgb(0x0A, 0x0A, 0x0A)       // (unused — head shape removed)
    private static let cLimb = rgb(0x0A, 0x0A, 0x0A)       // tail / feet — black, invisible on the bar
    private static let cEye  = rgb(0xF5, 0xF2, 0xEA)       // eyes + nose + mouth — warm white
    private static let cWhisker = rgb(0xF2, 0xEF, 0xE8)    // white whiskers
    private static let cClear = CGColor(gray: 0, alpha: 0) // invisible parts (head, ears, paws)
    private static let cCoral = rgb(0xD9, 0x77, 0x57)      // Claude's clay coral — props/confetti
    private static let cOrange = rgb(0xF0, 0x8A, 0x3C)     // the build hammer's head
    private static let cOrangeDark = rgb(0xB3, 0x5F, 0x26) // the build hammer's handle
    private static let cYellow = rgb(0xF2, 0xC9, 0x4C)     // pressure warning triangles
    private static let cSteel = rgb(0x9A, 0xA0, 0xA6)
    private static let cSlate = rgb(0x54, 0x50, 0x58)      // the rocket porthole's ring
    private static let cCream = rgb(0xED, 0xEA, 0xE2)
    private static let cWater = rgb(0x8F, 0xB7, 0xD9)
    private static let cRed   = rgb(0xE5, 0x4B, 0x42)      // failure flash
    private static let cAmber = rgb(0xE8, 0xA8, 0x4C)      // launching dots
    private static let cGreen = rgb(0x5F, 0xB8, 0x6E)      // success check
    private static let cHeart = rgb(0xE8, 0x6A, 0x8E)      // love-burst hearts + heart eyes (warm pink)

    init() {
        build()
    }

    // MARK: - Construction (design space: 100×100, origin bottom-left)

    private func build() {
        root.masksToBounds = false

        // Tail: anchored at its base (left end), sticking out the cat's right side. Added before the
        // body so the joint hides behind it. Rotation about the base is the swish.
        tail.bounds = CGRect(x: 0, y: 0, width: 24, height: 6)
        tail.anchorPoint = CGPoint(x: 0, y: 0.5)
        tail.position = CGPoint(x: 74, y: 14)
        tail.backgroundColor = Self.cLimb
        tail.cornerRadius = 3
        root.addSublayer(tail)

        // Hind feet: little stubs peeking from under the body's bottom edge; they patter on walks.
        configure(leftFoot,  x: 40, y: 27, w: 11, h: 9, color: Self.cLimb, radius: 4, anchor: CGPoint(x: 0.5, y: 1))
        configure(rightFoot, x: 54, y: 27, w: 11, h: 9, color: Self.cLimb, radius: 4, anchor: CGPoint(x: 0.5, y: 1))

        // No head shape at all — just an invisible box that holds the features and drives the
        // breathing / blink / mood animations. Only the white face below is drawn.
        configure(body, x: 50, y: 22, w: 62, h: 46, color: Self.cClear, radius: 0, anchor: CGPoint(x: 0.5, y: 0))

        // Ears kept as INVISIBLE layers so the ear animations (twitch, flatten) still have something
        // to drive — nothing is drawn.
        configureChild(leftEar,  in: body, cx: 18, cy: 44, w: 12, h: 13, color: Self.cClear, radius: 4,
                       anchor: CGPoint(x: 0.5, y: 0))
        configureChild(rightEar, in: body, cx: 44, cy: 44, w: 12, h: 13, color: Self.cClear, radius: 4,
                       anchor: CGPoint(x: 0.5, y: 0))
        leftEar.transform  = CATransform3DMakeRotation(-0.1, 0, 0, 1)
        rightEar.transform = CATransform3DMakeRotation(0.1, 0, 0, 1)

        // The whole visible cat: two white eyes over a white nose and a thin white "ω" mouth.
        configureChild(leftEye,  in: body, cx: 20, cy: 28.5, w: 6, h: 7.5, color: Self.cEye, radius: 3)
        configureChild(rightEye, in: body, cx: 42, cy: 28.5, w: 6, h: 7.5, color: Self.cEye, radius: 3)
        addRect(to: body, x: 28.25, y: 20.5, w: 5.5, h: 4, color: Self.cEye, radius: 2)     // nose
        let mouth = CAShapeLayer()
        mouth.frame = CGRect(x: 0, y: 0, width: 62, height: 46)   // body-local coords
        let m = CGMutablePath()
        m.move(to: CGPoint(x: 31, y: 20.5))
        m.addQuadCurve(to: CGPoint(x: 25.5, y: 19), control: CGPoint(x: 27.8, y: 15.8))    // left hook
        m.move(to: CGPoint(x: 31, y: 20.5))
        m.addQuadCurve(to: CGPoint(x: 36.5, y: 19), control: CGPoint(x: 34.2, y: 15.8))    // right hook
        mouth.path = m
        mouth.strokeColor = Self.cEye
        mouth.fillColor = nil
        mouth.lineWidth = 1.2
        mouth.lineCap = .round
        mouth.contentsScale = backing
        body.addSublayer(mouth)
        // White whiskers, three per side, beside the muzzle and fanning outward.
        for (y, rot) in [(19.5, 0.22), (16.0, 0.02), (12.5, -0.2)] {
            let l = addRect(to: body, x: 8, y: y, w: 7.5, h: 1.1, color: Self.cWhisker, radius: 0.55)
            l.transform = CATransform3DMakeRotation(rot, 0, 0, 1)
            l.zPosition = 20
            let r = addRect(to: body, x: 46.5, y: y, w: 7.5, h: 1.1, color: Self.cWhisker, radius: 0.55)
            r.transform = CATransform3DMakeRotation(-rot, 0, 0, 1)
            r.zPosition = 20
        }

        // Front paws: kept as INVISIBLE pivots (no visible hands, per request) — they still carry
        // the held prop (hammer / mug / dumbbell) and drive its swing, they just aren't drawn.
        configureChild(leftArm,  in: body, cx: 3,  cy: 26, w: 9, h: 18, color: Self.cClear, radius: 4.5,
                       anchor: CGPoint(x: 0.5, y: 1))
        configureChild(rightArm, in: body, cx: 59, cy: 26, w: 9, h: 18, color: Self.cClear, radius: 4.5,
                       anchor: CGPoint(x: 0.5, y: 1))

        // A prop held in the right paw: its BASE sits at the paw and it extends UPWARD, so the
        // hammer's head rides high (visible in the face band) and traces the widest arc when the
        // arm swings — the top does the swinging, not the handle.
        heldProp.bounds = CGRect(x: 0, y: 0, width: 24, height: 26)
        heldProp.anchorPoint = CGPoint(x: 0.5, y: 0)
        heldProp.position = CGPoint(x: 4.5, y: 2)
        heldProp.isHidden = true
        rightArm.addSublayer(heldProp)

        floatProp.bounds = CGRect(x: 0, y: 0, width: 16, height: 20)
        floatProp.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        floatProp.position = CGPoint(x: 88, y: 52)   // beside the head, inside the face band
        floatProp.isHidden = true
        root.addSublayer(floatProp)

        fx.bounds = CGRect(x: 0, y: 0, width: 8, height: 11)
        fx.anchorPoint = CGPoint(x: 0.5, y: 1)
        fx.isHidden = true
        root.addSublayer(fx)

        confetti.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        confetti.position = CGPoint(x: 50, y: 50)
        confetti.isHidden = true
        root.addSublayer(confetti)

        // Overlays live in the FACE BAND (see layout()): the rocket stands just to the cat's right
        // (the stage is wider than the design box); the smoke container follows the rocket.
        rocket.bounds = CGRect(x: 0, y: 0, width: 20, height: 30)
        rocket.anchorPoint = CGPoint(x: 0.5, y: 0)   // stands on its base
        rocket.position = CGPoint(x: 94, y: 35)
        rocket.isHidden = true
        root.addSublayer(rocket)

        smoke.bounds = CGRect(x: 0, y: 0, width: 40, height: 20)
        smoke.position = CGPoint(x: 94, y: 33)
        smoke.isHidden = true
        root.addSublayer(smoke)

        floorProp.bounds = CGRect(x: 0, y: 0, width: 20, height: 12)
        floorProp.anchorPoint = CGPoint(x: 0.5, y: 0)   // squashes from the ground up
        floorProp.isHidden = true
        root.addSublayer(floorProp)

        hat.bounds = CGRect(x: 0, y: 0, width: 32, height: 10)
        hat.position = CGPoint(x: 50, y: 58)            // on the forehead, inside the face band
        hat.isHidden = true
        root.addSublayer(hat)

        // Event overlays for the eyes: red X's on failure, green checks on success. Hidden until an
        // event swaps them in for the real eyes (children of the body, so they ride its motion).
        for (fx, cx) in [(leftEyeFX, CGFloat(20)), (rightEyeFX, CGFloat(42))] {
            fx.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
            fx.position = CGPoint(x: cx, y: 28.5)   // matches the eye centres
            fx.isHidden = true
            body.addSublayer(fx)
        }
    }

    /// Position a top-level part in design space.
    private func configure(_ layer: CALayer, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                           color: CGColor, radius: CGFloat, anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        layer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        layer.anchorPoint = anchor
        layer.position = CGPoint(x: x, y: y)
        layer.backgroundColor = color
        layer.cornerRadius = radius
        root.addSublayer(layer)
    }

    /// Position a part inside `parent`'s coordinate space (given by the child's *centre* cx/cy, since
    /// that's how the anatomy reads).
    private func configureChild(_ layer: CALayer, in parent: CALayer, cx: CGFloat, cy: CGFloat,
                                w: CGFloat, h: CGFloat, color: CGColor, radius: CGFloat,
                                anchor: CGPoint = CGPoint(x: 0.5, y: 0.5)) {
        layer.bounds = CGRect(x: 0, y: 0, width: w, height: h)
        layer.anchorPoint = anchor
        // Convert the wanted centre into a position for this anchor.
        layer.position = CGPoint(x: cx + w * (anchor.x - 0.5), y: cy + h * (anchor.y - 0.5))
        layer.backgroundColor = color
        layer.cornerRadius = radius
        parent.addSublayer(layer)
    }

    // MARK: - Sizing

    /// How much of the 100-unit design box maps to a point, via a scale on `root`. Below 1 the cat
    /// shrinks and MORE of the bar is free around it — headroom for the props and travelling
    /// animations. Safe to set on `root.transform` because `clearAnimations` no longer resets it.
    private static let bodyScale: CGFloat = 0.82

    /// Park the cat at the CENTRE of the stage — every animation plays from there (roaming
    /// vignettes go out and always come back to centre).
    ///
    /// The box is much taller than the bar, so only the FACE BAND shows — a big cat peeking through
    /// a letterbox — but `bodyScale` shrinks it so the face sits smaller with room to spare. The
    /// overlay contract is unchanged: keep props inside the face band or beside the head; because
    /// they're children of `root` they scale and reposition with the cat for free.
    func layout(width: CGFloat, height: CGFloat, backing: CGFloat) {
        self.backing = backing
        homeX = width / 2
        // Keep the (scaled) face clear of the stage edges as it roams.
        walkSpan = max(0, width / 2 - 40 * Self.bodyScale)
        root.bounds = CGRect(x: 0, y: 0, width: 100, height: 100)
        root.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        root.position = CGPoint(x: homeX, y: height / 2)
        root.transform = CATransform3DMakeScale(Self.bodyScale, Self.bodyScale, 1)
        applyContentsScale(backing, to: root)

        if let mood { install(mood) }
    }

    private func applyContentsScale(_ cs: CGFloat, to layer: CALayer) {
        layer.contentsScale = cs
        layer.sublayers?.forEach { applyContentsScale(cs, to: $0) }
    }

    // MARK: - Mood switching

    func set(_ newMood: Mood) {
        guard newMood != mood else { return }
        install(newMood)
    }

    /// Force-(re)play a mood even if it's already the current one — the click heart-burst uses this
    /// so every click re-triggers the shower, where `set` would no-op on the repeat.
    func poke(_ newMood: Mood) {
        install(newMood)
    }

    private func install(_ newMood: Mood) {
        mood = newMood
        reset()
        switch newMood {
        case .idle:        idle()
        case .working:     working()
        case .gearedUp:    gearedUp()
        case .previewing:  previewing()
        case .pressured:   pressured()
        case .failed:      failed()
        case .launching:   launching()
        case .completed:   completed()
        case .exploded:    exploded()
        case .celebrating: celebrating()
        case .caffeinated: caffeinated()
        case .loved:       loved()
        }
    }

    /// Wipe every running animation, return every part to a neutral pose and stop the idle rotation.
    /// Each mood then layers its own timeline on top of this clean slate.
    private func reset() {
        idleTimer?.invalidate()
        idleTimer = nil
        clearAnimations()
    }

    /// The animation-clearing half of `reset()` — also used between idle vignettes, where the idle
    /// timer must keep running.
    ///
    /// The whole sweep runs with implicit actions DISABLED, as one atomic cut. Without this,
    /// removing a fill-forwards animation (the rocket's liftoff) snaps the layer back to its model
    /// pose and the subsequent `isHidden = true` runs as an implicit 0.25 s fade — the rocket
    /// ghosts back onto the pad for a frame before vanishing.
    private func clearAnimations() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        // The root only sheds its animations (the roaming position.x trips) — its transform and
        // position are LAYOUT state, never per-mood state. Resetting root.transform here is what
        // silently unscaled the whole cat for weeks.
        root.removeAllAnimations()
        for l in [tail, leftFoot, rightFoot, body, leftEar, rightEar, leftEye, rightEye,
                  leftArm, rightArm, heldProp, floatProp, fx, confetti, rocket, rocketFlame,
                  smoke, floorProp, hat, leftEyeFX, rightEyeFX] {
            l.removeAllAnimations()
            l.transform = CATransform3DIdentity
        }
        // The ears' neutral pose is a slight outward tilt, not identity.
        leftEar.transform  = CATransform3DMakeRotation(-0.1, 0, 0, 1)
        rightEar.transform = CATransform3DMakeRotation(0.1, 0, 0, 1)
        // Events swap the eyes for X/check marks; restore the real eyes.
        leftEye.isHidden = false
        rightEye.isHidden = false
        leftEyeFX.isHidden = true
        rightEyeFX.isHidden = true
        fx.speed = 1
        heldProp.isHidden = true
        floatProp.isHidden = true
        fx.isHidden = true
        confetti.isHidden = true
        rocket.isHidden = true
        rocket.opacity = 1
        smoke.isHidden = true
        floorProp.isHidden = true
        hat.isHidden = true
        hat.opacity = 1
    }

    // MARK: - Moods (each is a small "GSAP timeline" of layer animations)

    /// Resting — but never boring: play a vignette now, then rotate to a different one every few
    /// seconds. The pick avoids repeating the previous vignette so the cat doesn't do the same
    /// trick twice in a row.
    private func idle() {
        playVignette(.rest)
        idleTimer = Timer.scheduledTimer(withTimeInterval: 11, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.nextVignette() }
        }
    }

    private func nextVignette() {
        guard mood == .idle else { return }
        let pick = Vignette.allCases.filter { $0 != lastVignette }.randomElement() ?? .rest
        clearAnimations()
        playVignette(pick)
    }

    private func playVignette(_ v: Vignette) {
        lastVignette = v
        switch v {
        case .rest:      sit()
        case .prowl:     prowl()
        case .pounce:    pounce()
        case .groom:     groom()
        case .gym:       gym()
        case .doze:      doze()
        case .jam:       jam()
        case .stretch:   stretch()
        }
    }

    /// The sitting-cat baseline: calm breath, slow cat-blinks, tail-tip flicks, and each ear
    /// twitching on its own clock (the desync is what makes it feel alive, not mechanical).
    private func sit() {
        breathe(period: 3.2, amount: 0.03)
        blink(period: 5.0, open: 1)
        glance(period: 8.5, amount: 2)
        tailFlick(period: 4.0, from: 0.12, to: 0.4)
        earTwitch(leftEar, base: -0.1, period: 6.7)
        earTwitch(rightEar, base: 0.1, period: 9.3)
    }

    /// Prowl the strip: pad out, pause mid-way (ears perk — heard something), continue to the far
    /// end, then amble home. Feet patter, tail sways, torso bobs. One-shot; the timer rotates on.
    private func prowl() {
        breathe(period: 2.8, amount: 0.02)
        blink(period: 5.0, open: 1)
        guard walkSpan > 12 else { sit(); return }    // no room to roam (fallback layout)
        // Anticipation: a quick "gather" squash right before setting off — the cat loads its weight,
        // THEN walks. Without it the departure reads as teleport-start.
        let gather = keyframe("transform.scale.y", values: [1, 0.94, 1.02, 1, 1],
                              times: [0, 0.02, 0.045, 0.06, 1],
                              duration: 10.5, easings: [.easeOut, .easeInOut, .easeInOut, .linear],
                              repeats: 1)
        body.add(gather, forKey: "gather")
        // From the centre: wander to the left end, pause (heard something), cross the whole strip to
        // the right end, pause, and amble back to centre.
        let trip = keyframe("position.x",
                            values: [homeX, homeX - walkSpan, homeX - walkSpan,
                                     homeX + walkSpan, homeX + walkSpan, homeX, homeX],
                            times:  [0, 0.2, 0.32, 0.56, 0.68, 0.92, 1],
                            duration: 10.5,
                            easings: [.easeInOut, .linear, .easeInOut, .linear, .easeInOut, .linear],
                            repeats: 1)
        root.add(trip, forKey: "trip")
        // Ears perk upright during the first pause (snap out, ease back), then relax.
        let perkL = keyframe("transform.rotation.z", values: [-0.1, -0.1, 0.05, 0.05, -0.1, -0.1],
                             times: [0, 0.2, 0.24, 0.32, 0.36, 1], duration: 10.5,
                             easings: [.linear, .easeOut, .linear, .easeInOut, .linear], repeats: 1)
        let perkR = keyframe("transform.rotation.z", values: [0.1, 0.1, -0.05, -0.05, 0.1, 0.1],
                             times: [0, 0.2, 0.24, 0.32, 0.36, 1], duration: 10.5,
                             easings: [.linear, .easeOut, .linear, .easeInOut, .linear], repeats: 1)
        leftEar.add(perkL, forKey: "perk")
        rightEar.add(perkR, forKey: "perk")
        // Pad cycle: feet patter in antiphase, light bounce, tail sways with the gait.
        leftFoot.add(basic("transform.translation.y", from: 0, to: 2, duration: 0.28), forKey: "pad")
        let padR = basic("transform.translation.y", from: 2, to: 0, duration: 0.28)
        rightFoot.add(padR, forKey: "pad")
        body.add(basic("transform.translation.y", from: 0, to: 1.2, duration: 0.28), forKey: "bob")
        tail.add(basic("transform.rotation.z", from: 0.15, to: 0.5, duration: 0.6), forKey: "sway")
    }

    /// The hunt: crouch low, butt-wiggle to charge the spring, LEAP across the stage (sine up,
    /// sharper landing — the article's jump-arc recipe), then trot back home all innocent.
    private func pounce() {
        blink(period: 6.0, open: 1)
        let leap = min(70, walkSpan)
        guard leap > 20 else { sit(); return }
        let dur = 9.0
        // Crouch → hold → stretch on takeoff → SQUASH on landing → overshoot settle (follow-through:
        // the cat doesn't stop dead, it lands, compresses and springs back to shape).
        let crouch = keyframe("transform.scale.y", values: [1, 0.8, 0.8, 1.1, 1, 0.88, 1.04, 1],
                              times: [0, 0.1, 0.3, 0.36, 0.41, 0.44, 0.48, 1],
                              duration: dur, easings: [.easeInOut, .linear, .easeOut, .easeIn,
                                                       .easeIn, .easeOutBack, .easeInOut],
                              repeats: 1)
        body.add(crouch, forKey: "crouch")
        // The butt-wiggle: tiny fast lean oscillation while crouched.
        let wiggle = keyframe("transform.rotation.z",
                              values: [0, 0.05, -0.05, 0.05, -0.05, 0.05, 0, 0],
                              times:  [0, 0.13, 0.16, 0.19, 0.22, 0.25, 0.29, 1],
                              duration: dur, easings: nil, repeats: 1)
        body.add(wiggle, forKey: "wiggle")
        // Tail low and twitchy while stalking, up on the leap.
        let tailArc = keyframe("transform.rotation.z", values: [0.15, -0.1, -0.1, 0.7, 0.2, 0.15],
                               times: [0, 0.1, 0.3, 0.4, 0.55, 1], duration: dur,
                               easings: [.easeInOut, .linear, .easeOut, .easeInOut, .easeInOut],
                               repeats: 1)
        tail.add(tailArc, forKey: "arc")
        // Secondary narrative in the ears: pinned back while stalking, perked upright on landing.
        let earsL = keyframe("transform.rotation.z", values: [-0.1, -0.5, -0.5, 0.05, -0.1, -0.1],
                             times: [0, 0.1, 0.36, 0.46, 0.6, 1], duration: dur,
                             easings: [.easeInOut, .linear, .easeOut, .easeInOut, .linear], repeats: 1)
        let earsR = keyframe("transform.rotation.z", values: [0.1, 0.5, 0.5, -0.05, 0.1, 0.1],
                             times: [0, 0.1, 0.36, 0.46, 0.6, 1], duration: dur,
                             easings: [.easeInOut, .linear, .easeOut, .easeInOut, .linear], repeats: 1)
        leftEar.add(earsL, forKey: "stalk")
        rightEar.add(earsR, forKey: "stalk")
        // The leap itself: travel + arc, then a pause to look around, then amble home.
        let travel = keyframe("position.x",
                              values: [homeX, homeX, homeX - leap, homeX - leap, homeX, homeX],
                              times:  [0, 0.3, 0.42, 0.62, 0.95, 1],
                              duration: dur, easings: [.linear, .easeOut, .linear, .easeInOut, .linear],
                              repeats: 1)
        root.add(travel, forKey: "travel")
        let arc = keyframe("transform.translation.y", values: [0, 0, 9, 0, 0],
                           times: [0, 0.3, 0.36, 0.42, 1],
                           duration: dur, easings: [.linear, .easeOut, .easeIn, .linear], repeats: 1)
        root.add(arc, forKey: "arc")
    }

    /// Wash time: eyes blissfully shut, head tilted, one paw dabbing the face over and over, tail
    /// curled around the front.
    private func groom() {
        breathe(period: 3.0, amount: 0.03)
        leftEye.transform = CATransform3DMakeScale(1, 0.12, 1)
        rightEye.transform = CATransform3DMakeScale(1, 0.12, 1)
        body.transform = CATransform3DMakeRotation(0.05, 0, 0, 1)
        tail.transform = CATransform3DMakeRotation(-0.45, 0, 0, 1)
        let dab = keyframe("transform.rotation.z",
                           values: [0, -1.7, -1.5, -1.7, -1.5, -1.7, 0, 0],
                           times:  [0, 0.15, 0.27, 0.39, 0.51, 0.63, 0.85, 1],
                           duration: 6.5,
                           easings: [.easeInOut, .easeInOut, .easeInOut, .easeInOut,
                                     .easeInOut, .easeInOut, .linear],
                           repeats: 1)
        rightArm.add(dab, forKey: "dab")
        // Overlapping action: the head rocks INTO each dab, a beat behind the paw, at a fraction of
        // its amplitude — the wash reads through the whole body, not just one limb.
        let rock = keyframe("transform.rotation.z",
                            values: [0.05, 0.08, 0.05, 0.08, 0.05, 0.08, 0.05, 0.05],
                            times:  [0, 0.18, 0.3, 0.42, 0.54, 0.66, 0.85, 1],
                            duration: 6.5,
                            easings: [.easeInOut, .easeInOut, .easeInOut, .easeInOut,
                                      .easeInOut, .easeInOut, .linear],
                            repeats: 1)
        body.add(rock, forKey: "rock")
    }

    /// Dumbbell curls, article-style "not every frame plays at the same speed": the lift holds at the
    /// top, dips halfway, pumps again — effort you can read in the timing alone. Gym cat.
    private func gym() {
        configureDumbbell()
        breathe(period: 2.2, amount: 0.03)
        leftEye.transform = CATransform3DMakeScale(1, 0.7, 1)    // effort squint
        rightEye.transform = CATransform3DMakeScale(1, 0.7, 1)
        leftArm.transform = CATransform3DMakeRotation(0.3, 0, 0, 1)   // braced
        tailFlick(period: 3.0, from: 0.1, to: 0.3)
        let curl = keyframe("transform.rotation.z",
                            values: [0, 2.35, 2.35, 1.1, 2.35, 2.35, 0, 0],
                            times:  [0, 0.16, 0.3, 0.42, 0.54, 0.74, 0.9, 1],
                            duration: 8, easings: [.easeInOut, .linear, .easeInOut, .easeInOut,
                                                   .linear, .easeInOut, .linear],
                            repeats: 1)
        rightArm.add(curl, forKey: "curl")
        body.add(basic("transform.rotation.z", from: 0.0, to: 0.05, duration: 2.0), forKey: "lean")
    }

    /// Loaf mode: squash into a bread shape, eyes shut, tail wrapped around the front, slow deep
    /// breaths, a Zzz drifting up. The machine is idle; so is the cat.
    private func doze() {
        configureZzz()
        breathe(period: 4.4, amount: 0.05)
        body.transform = CATransform3DConcat(CATransform3DMakeScale(1.06, 0.88, 1),
                                             CATransform3DMakeRotation(-0.03, 0, 0, 1))
        leftEye.transform = CATransform3DMakeScale(1, 0.12, 1)
        rightEye.transform = CATransform3DMakeScale(1, 0.12, 1)
        leftEar.transform  = CATransform3DMakeRotation(-0.35, 0, 0, 1)   // ears at half mast
        rightEar.transform = CATransform3DMakeRotation(0.35, 0, 0, 1)
        tail.transform = CATransform3DMakeRotation(-0.5, 0, 0, 1)        // wrapped low
        // Ambient: the tail tip stirs faintly with the breath — asleep, not switched off.
        tail.add(basic("transform.rotation.z", from: -0.55, to: -0.45, duration: 2.2), forKey: "stir")
    }

    /// Vibing to music: eyes half-lidded and blissed-out, the head nodding to a two-step beat with a
    /// little side groove, ears flicking on the downbeat, the tail tapping time, and musical notes
    /// drifting up beside the head. The cat's got its own soundtrack.
    private func jam() {
        configureNotes()
        breathe(period: 2.4, amount: 0.03)
        leftEye.transform = CATransform3DMakeScale(1, 0.5, 1)            // half-lidded, into it
        rightEye.transform = CATransform3DMakeScale(1, 0.5, 1)
        let beat = 1.4
        // Head bob: dip on the beat, lift on the off-beat — nods twice per bar, not a metronome.
        let bob = keyframe("transform.translation.y", values: [0, -2.6, 0.4, -2.6, 0],
                           times: [0, 0.25, 0.5, 0.75, 1], duration: beat,
                           easings: [.easeIn, .easeOut, .easeIn, .easeOut])
        body.add(bob, forKey: "bob")
        // A slow side-to-side sway underneath, one full swing per two beats — that's the groove.
        let sway = keyframe("transform.rotation.z", values: [-0.035, 0.035, -0.035], times: [0, 0.5, 1],
                            duration: beat * 2, easings: [.easeInOut, .easeInOut])
        body.add(sway, forKey: "sway")
        // Ears flick on the downbeat (mirrored, so they snap in sync with the nod).
        leftEar.add(keyframe("transform.rotation.z", values: [-0.1, 0.14, -0.1], times: [0, 0.25, 0.6],
                             duration: beat, easings: [.easeOut, .easeInOut]), forKey: "flick")
        rightEar.add(keyframe("transform.rotation.z", values: [0.1, -0.14, 0.1], times: [0, 0.25, 0.6],
                              duration: beat, easings: [.easeOut, .easeInOut]), forKey: "flick")
        tail.add(basic("transform.rotation.z", from: 0.1, to: 0.5, duration: beat / 2), forKey: "tap")
    }

    /// A big satisfying stretch: the cat elongates into a long, low sprawl (front paws reaching,
    /// back dropping), holds the strain a beat with eyes screwed shut and ears flattened, then
    /// springs back upright with the signature overshoot — the classic cat wake-up.
    private func stretch() {
        // The stretch itself IS the body motion, so no breathe() (it fights on the same scale keys).
        let t: [Double] = [0, 0.22, 0.55, 0.72, 1]
        // Long and low: widen out and flatten down, hold, then overshoot back to normal shape.
        body.add(keyframe("transform.scale.x", values: [1, 1.22, 1.22, 0.97, 1], times: t,
                          duration: 6.0, easings: [.easeOut, .linear, .easeInOut, .easeOutBack]), forKey: "stretchX")
        body.add(keyframe("transform.scale.y", values: [1, 0.8, 0.8, 1.04, 1], times: t,
                          duration: 6.0, easings: [.easeOut, .linear, .easeInOut, .easeOutBack]), forKey: "stretchY")
        // Eyes screw shut through the strain, blink open on the release.
        let squint = keyframe("transform.scale.y", values: [1, 0.12, 0.12, 1, 1], times: t,
                              duration: 6.0, easings: [.easeInOut, .linear, .easeOut, .linear])
        leftEye.add(squint, forKey: "squint")
        rightEye.add(squint, forKey: "squint")
        // Ears flatten back with the effort, perk up again at the finish.
        leftEar.add(keyframe("transform.rotation.z", values: [-0.1, -0.42, -0.42, 0.05, -0.1], times: t,
                             duration: 6.0, easings: [.easeOut, .linear, .easeInOut, .easeInOut]), forKey: "flat")
        rightEar.add(keyframe("transform.rotation.z", values: [0.1, 0.42, 0.42, -0.05, 0.1], times: t,
                              duration: 6.0, easings: [.easeOut, .linear, .easeInOut, .easeInOut]), forKey: "flat")
        // Tail lifts and quivers at the peak of the stretch, then settles.
        tail.add(keyframe("transform.rotation.z", values: [0.1, 0.55, 0.55, 0.15, 0.1], times: t,
                          duration: 6.0, easings: [.easeOut, .linear, .easeInOut, .easeInOut]), forKey: "lift")
    }

    /// A build is running: hammering to the RIGHT. The swing lives on the PROP, anchored at its
    /// base in the paw — so the paw barely moves and the HEAD does all the travelling: a slow
    /// wind-up leaning left (anticipation), then it whips clockwise and slams down on the right,
    /// the body dipping on every hit.
    private func working() {
        configureHammer()
        leftEye.transform = CATransform3DMakeScale(1, 0.75, 1)           // focus squint
        rightEye.transform = CATransform3DMakeScale(1, 0.75, 1)
        // No hands now — so float the hammer BESIDE the cat, off its right side (clear of the face),
        // where it hammers down like a tool working next to it.
        rightArm.transform = CATransform3DMakeTranslation(9, -11, 0)
        // Wind up (head tips back) → STRIKE down → recover.
        let swing = keyframe("transform.rotation.z",
                             values: [0.3, 0.95, -0.5, 0.3],
                             times:  [0, 0.42, 0.6, 1],
                             duration: 0.72, easings: [.easeInOut, .easeIn, .easeInOut])
        heldProp.add(swing, forKey: "swing")
        // Body squashes on the strike (~t=0.6) and springs back.
        let impact = keyframe("transform.scale.y",
                              values: [1, 1, 0.93, 1.01, 1],
                              times:  [0, 0.5, 0.62, 0.8, 1],
                              duration: 0.72, easings: [.easeIn, .easeOut, .easeOut, .easeInOut])
        body.add(impact, forKey: "impact")
        // Secondary: the eyes flick down-and-RIGHT with each strike, following the head.
        let trackY = keyframe("transform.translation.y", values: [0, 0, -0.8, 0, 0],
                              times: [0, 0.45, 0.62, 0.8, 1], duration: 0.72,
                              easings: [.linear, .easeOut, .easeOut, .easeInOut])
        let trackX = keyframe("transform.translation.x", values: [0, 0, 1.4, 0, 0],
                              times: [0, 0.45, 0.62, 0.8, 1], duration: 0.72,
                              easings: [.linear, .easeOut, .easeOut, .easeInOut])
        leftEye.add(trackY, forKey: "trackY")
        rightEye.add(trackY, forKey: "trackY")
        leftEye.add(trackX, forKey: "trackX")
        rightEye.add(trackX, forKey: "trackX")
        tailFlick(period: 1.6, from: 0.1, to: 0.45)
        earTwitch(leftEar, base: -0.1, period: 4.1)
    }

    /// 3-second "on the job": a WORKER just started — a yellow hard hat drops onto the forehead,
    /// bounces to a settle (signature overshoot), and the cat gives ONE firm, determined nod. Then
    /// business as usual while the worker hums in the background.
    private func gearedUp() {
        configureHardHat()
        // The hat drops in from above and settles.
        let drop = keyframe("transform.translation.y", values: [14, 0], times: [0, 1],
                            duration: 0.4, easings: [.easeOutBack], repeats: 1)
        hat.add(drop, forKey: "drop")
        let fadeIn = keyframe("opacity", values: [0, 1, 1], times: [0, 0.3, 1],
                              duration: 0.4, easings: nil, repeats: 1)
        fadeIn.fillMode = .forwards
        fadeIn.isRemovedOnCompletion = false
        hat.add(fadeIn, forKey: "in")

        leftEye.transform = CATransform3DMakeScale(1, 0.7, 1)            // determined
        rightEye.transform = CATransform3DMakeScale(1, 0.7, 1)
        // A little squash when the hat lands (~t 0.13 of 3 s), then the nod dips the body once.
        let squash = keyframe("transform.scale.y", values: [1, 1, 0.95, 1, 1, 0.96, 1, 1],
                              times: [0, 0.12, 0.16, 0.23, 0.45, 0.55, 0.68, 1],
                              duration: 3, easings: nil, repeats: 1)
        body.add(squash, forKey: "hatSquash")
        // Eyes dip with the nod.
        let nod = keyframe("transform.translation.y", values: [0, 0, -1.6, 0, 0],
                           times: [0, 0.45, 0.55, 0.68, 1], duration: 3, easings: nil, repeats: 1)
        leftEye.add(nod, forKey: "nod")
        rightEye.add(nod, forKey: "nod")
        tailFlick(period: 1.5, from: 0.1, to: 0.4)
    }

    /// CONTINUOUS while a production preview serves: sitting in front of a little glowing screen,
    /// leaning in, ears tipped forward, eyes scanning side to side as if reading the page.
    private func previewing() {
        configureScreen()
        breathe(period: 3.0, amount: 0.03)
        blink(period: 5.4, open: 1)
        leftEar.transform = CATransform3DMakeRotation(0.02, 0, 0, 1)     // tipped forward, attentive
        rightEar.transform = CATransform3DMakeRotation(-0.02, 0, 0, 1)
        body.transform = CATransform3DMakeRotation(0.04, 0, 0, 1)        // leaning toward the screen
        leftEye.transform = CATransform3DMakeTranslation(-1.5, -1, 0)    // gaze down at it
        rightEye.transform = CATransform3DMakeTranslation(-1.5, -1, 0)
        glance(period: 3.2, amount: 1.6)                                 // reading, line by line
        tailFlick(period: 5.0, from: 0.1, to: 0.3)
    }

    /// A build just succeeded: happy hops, tail held high and wagging, ears perked, confetti raining.
    private func celebrating() {
        configureConfetti()
        showEyeMarks(.check)                                     // success = green check eyes
        leftEar.transform = CATransform3DMakeRotation(0.05, 0, 0, 1)     // perked upright
        rightEar.transform = CATransform3DMakeRotation(-0.05, 0, 0, 1)

        let hop = keyframe("transform.translation.y", values: [0, 9, 0], times: [0, 0.45, 1],
                           duration: 0.62, easings: [.easeOut, .easeIn])
        body.add(hop, forKey: "hop")
        hopSquash(duration: 0.62, intensity: 0.1)
        // Paws up, waving in antiphase; tail high, wagging hard.
        leftArm.transform = CATransform3DMakeRotation(2.5, 0, 0, 1)
        rightArm.transform = CATransform3DMakeRotation(-2.5, 0, 0, 1)
        leftArm.add(basic("transform.rotation.z", from: 2.2, to: 2.8, duration: 0.31), forKey: "wave")
        let waveR = basic("transform.rotation.z", from: -2.8, to: -2.2, duration: 0.31)
        waveR.timeOffset = 0.15
        rightArm.add(waveR, forKey: "wave")
        tail.add(basic("transform.rotation.z", from: 0.6, to: 1.15, duration: 0.31), forKey: "wag")
    }

    /// 3-second "staying up": keep-awake just switched on — a steaming mug of coffee held up by the
    /// muzzle, the cat taking a couple of content little sips (eyes dipping shut). Then gone.
    private func caffeinated() {
        configureMug()
        breathe(period: 2.0, amount: 0.02)
        body.transform = CATransform3DMakeRotation(0.03, 0, 0, 1)        // slight lean toward the cup
        leftEye.transform = CATransform3DMakeScale(1, 0.55, 1)           // content
        rightEye.transform = CATransform3DMakeScale(1, 0.55, 1)
        // Two sips: the eyes dip fully shut for a beat each.
        let sip = keyframe("transform.scale.y",
                           values: [0.55, 0.55, 0.1, 0.55, 0.55, 0.1, 0.55, 0.55],
                           times:  [0, 0.18, 0.26, 0.42, 0.58, 0.66, 0.82, 1],
                           duration: 3, easings: nil, repeats: 1)
        leftEye.add(sip, forKey: "sip")
        rightEye.add(sip, forKey: "sip")
        tailFlick(period: 2.2, from: 0.1, to: 0.3)
    }

    /// 3-second "aww": you CLICKED the cat — its eyes turn into pink hearts (popping in with the
    /// signature overshoot) while a shower of hearts floats up and out the top, and the whole cat
    /// does a bashful side-to-side squirm with a little bounce. The reward for petting it.
    private func loved() {
        configureHearts()
        showEyeMarks(.heart)
        leftEar.transform = CATransform3DMakeRotation(0.06, 0, 0, 1)     // ears perk, pleased
        rightEar.transform = CATransform3DMakeRotation(-0.06, 0, 0, 1)
        // A happy squirm: the body sways a couple of times, softening as it settles.
        let squirm = keyframe("transform.rotation.z",
                              values: [0, 0.07, -0.07, 0.05, -0.04, 0.02, 0],
                              times:  [0, 0.13, 0.3, 0.47, 0.64, 0.8, 1],
                              duration: 1.5,
                              easings: [.easeInOut, .easeInOut, .easeInOut, .easeInOut, .easeInOut, .easeInOut])
        body.add(squirm, forKey: "squirm")
        // …lifting a touch with each sway — the joy lifts the whole cat.
        let bounce = keyframe("transform.translation.y", values: [0, 3, 0, 2.4, 0],
                              times: [0, 0.22, 0.45, 0.68, 0.92], duration: 1.5,
                              easings: [.easeOut, .easeIn, .easeOut, .easeIn])
        body.add(bounce, forKey: "bounce")
        tailFlick(period: 1.1, from: 0.15, to: 0.55)
    }

    /// 3-second alarm: something FAILED — the eyes themselves turn into red X's, and the body gives
    /// one firm shake burst. Unmissable from across the room, then gone.
    private func failed() {
        showEyeMarks(.cross)
        // Error shake per the book: ONE burst of ~3 oscillations with sharp stops, then firm
        // stillness — errors feel firm, not jittery. The red X eyes carry the rest of the 3 seconds.
        let shake = keyframe("transform.translation.x", values: [0, -2, 2, -1.5, 1.5, 0],
                             times: [0, 0.15, 0.35, 0.55, 0.75, 1], duration: 0.4,
                             easings: [.easeInOut, .easeInOut, .easeInOut, .easeInOut, .easeInOut],
                             repeats: 1)
        body.add(shake, forKey: "shake")
    }

    /// CONTINUOUS while a server boots: the rocket stands right beside the cat, engine warming —
    /// vibrating on the pad with little smoke wisps rising off its base — while the cat leans in,
    /// eyes locked on it. `completed` lifts it off; `exploded` blows it up.
    private func launching() {
        configureRocket(flame: false)
        configureWisps()
        breathe(period: 2.0, amount: 0.03)
        blink(period: 5.0, open: 1)
        // The cat WATCHES the rocket to its right: eyes cut hard toward it (and a hair down, it sits
        // near eye level), head leaning in, the near ear swivelled toward it.
        leftEye.transform = CATransform3DMakeTranslation(3.6, -0.5, 0)
        rightEye.transform = CATransform3DMakeTranslation(3.6, -0.5, 0)
        body.transform = CATransform3DMakeRotation(-0.06, 0, 0, 1)   // leaning toward it
        rightEar.transform = CATransform3DMakeRotation(-0.22, 0, 0, 1)   // near ear perked at it
        // The gaze quivers in sympathy with the shaking rocket — nervously watching it rattle.
        leftEye.add(basic("transform.translation.x", from: 3.3, to: 3.9, duration: 0.09), forKey: "watch")
        rightEye.add(basic("transform.translation.x", from: 3.3, to: 3.9, duration: 0.09), forKey: "watch")
        tailFlick(period: 2.2, from: 0.1, to: 0.4)                   // anticipation ticking
        // The vibrate: tight x jitter plus a whisker of rattle.
        rocket.add(basic("transform.translation.x", from: -0.9, to: 0.9, duration: 0.05), forKey: "vibrate")
        rocket.add(basic("transform.rotation.z", from: -0.02, to: 0.02, duration: 0.07), forKey: "rattle")
    }

    /// 3-second "up!": LIFTOFF — the rocket ignites and accelerates out through the top of the bar
    /// on a billow of smoke, while the cat celebrates with green check eyes and happy hops.
    private func completed() {
        showEyeMarks(.check)
        configureRocket(flame: true)
        configureLiftoffSmoke()
        let up = CABasicAnimation(keyPath: "transform.translation.y")
        up.fromValue = 0; up.toValue = 60
        up.duration = 1.1
        up.timingFunction = timing(.easeIn)          // engines spool up, then it RIPS
        up.fillMode = .forwards
        up.isRemovedOnCompletion = false             // stays gone for the rest of the event
        rocket.add(up, forKey: "liftoff")
        rocket.add(basic("transform.rotation.z", from: -0.03, to: 0.03, duration: 0.08), forKey: "rattle")

        let hop = keyframe("transform.translation.y", values: [0, 6, 0], times: [0, 0.45, 1],
                           duration: 0.55, easings: [.easeOut, .easeIn])
        body.add(hop, forKey: "hop")
        hopSquash(duration: 0.55, intensity: 0.07)
    }

    /// 3-second catastrophe: the launch FAILED — the rocket rattles violently, then blows apart in
    /// a burst of debris while the cat gets the red X eyes and a firm shake.
    private func exploded() {
        showEyeMarks(.cross)
        configureRocket(flame: false)
        // Violent rattle for ~0.3s…
        let rattle = basic("transform.translation.x", from: -1.8, to: 1.8, duration: 0.04)
        rattle.repeatCount = 4
        rocket.add(rattle, forKey: "rattle")
        // …then the bang: the rocket vanishes as the debris flies (see configureExplosion).
        let vanish = keyframe("opacity", values: [1, 1, 0, 0], times: [0, 0.115, 0.12, 1],
                              duration: 3, easings: nil, repeats: 1)
        vanish.fillMode = .forwards
        vanish.isRemovedOnCompletion = false
        rocket.add(vanish, forKey: "vanish")
        configureExplosion()

        let shake = keyframe("transform.translation.x", values: [0, -2, 2, -1.5, 1.5, 0],
                             times: [0, 0.15, 0.35, 0.55, 0.75, 1], duration: 0.4,
                             easings: [.easeInOut, .easeInOut, .easeInOut, .easeInOut, .easeInOut],
                             repeats: 1)
        shake.beginTime = CACurrentMediaTime() + 0.35   // the shockwave hits as the rocket blows
        body.add(shake, forKey: "shake")
    }

    /// What the event eyes show instead of the white eyes.
    private enum EyeMark { case cross, check, warning, heart }

    /// Swap the white eyes for event marks — red X's (failure), green checks (success) or yellow
    /// warning triangles (pressure) — popping in with the signature overshoot. `clearAnimations`
    /// restores the real eyes afterwards.
    private func showEyeMarks(_ mark: EyeMark) {
        leftEye.isHidden = true
        rightEye.isHidden = true
        for fx in [leftEyeFX, rightEyeFX] {
            fx.sublayers?.forEach { $0.removeFromSuperlayer() }
            fx.isHidden = false
            switch mark {
            case .check:
                addRect(to: fx, x: 1, y: 5, w: 6, h: 2.6, color: Self.cGreen, radius: 1.3)
                    .transform = CATransform3DMakeRotation(-0.65, 0, 0, 1)
                addRect(to: fx, x: 5, y: 6, w: 9, h: 2.6, color: Self.cGreen, radius: 1.3)
                    .transform = CATransform3DMakeRotation(0.7, 0, 0, 1)
            case .cross:
                addRect(to: fx, x: 0, y: 5.4, w: 14, h: 3.2, color: Self.cRed, radius: 1.6)
                    .transform = CATransform3DMakeRotation(0.785, 0, 0, 1)
                addRect(to: fx, x: 0, y: 5.4, w: 14, h: 3.2, color: Self.cRed, radius: 1.6)
                    .transform = CATransform3DMakeRotation(-0.785, 0, 0, 1)
            case .warning:
                // A rounded warning triangle (the fat stroke with round joins is what rounds the
                // corners) with a dark "!" punched into it.
                let tri = CAShapeLayer()
                tri.frame = fx.bounds
                let p = CGMutablePath()
                p.move(to: CGPoint(x: 7, y: 12))
                p.addLine(to: CGPoint(x: 1.5, y: 2.5))
                p.addLine(to: CGPoint(x: 12.5, y: 2.5))
                p.closeSubpath()
                tri.path = p
                tri.fillColor = Self.cYellow
                tri.strokeColor = Self.cYellow
                tri.lineWidth = 2.5
                tri.lineJoin = .round
                tri.contentsScale = backing
                fx.addSublayer(tri)
                addRect(to: fx, x: 6.15, y: 5.2, w: 1.7, h: 3.8, color: Self.cBody, radius: 0.85)
                addRect(to: fx, x: 6.15, y: 2.8, w: 1.7, h: 1.7, color: Self.cBody, radius: 0.85)
            case .heart:
                let heart = CAShapeLayer()
                heart.frame = fx.bounds
                heart.path = Self.heartPath(w: 12, h: 11, ox: 1, oy: 1.5)
                heart.fillColor = Self.cHeart
                heart.contentsScale = backing
                fx.addSublayer(heart)
            }
            fx.add(keyframe("transform.scale", values: [0.3, 1], times: [0, 1], duration: 0.28,
                            easings: [.easeOutBack], repeats: 1), forKey: "pop")
        }
    }

    /// The machine is under pressure: panting flat-out, ears half back, tail whipping in short
    /// irritated flicks, sweat coming fast. Outranks everything else, per policy.
    private func pressured() {
        configureSweat()
        fx.speed = 1.6                        // the sweat comes fast
        body.transform = CATransform3DMakeRotation(-0.04, 0, 0, 1)       // slump
        body.add(basic("transform.scale.y", from: 1, to: 1.06, duration: 0.45), forKey: "pant")
        leftEar.transform  = CATransform3DMakeRotation(-0.45, 0, 0, 1)   // ears back
        rightEar.transform = CATransform3DMakeRotation(0.45, 0, 0, 1)
        tail.add(basic("transform.rotation.z", from: 0.1, to: 0.45, duration: 0.25), forKey: "whip")

        // The eyes ARE the warning: yellow triangles with a soft attention throb.
        showEyeMarks(.warning)
        leftEyeFX.add(basic("opacity", from: 0.7, to: 1, duration: 0.6), forKey: "throb")
        rightEyeFX.add(basic("opacity", from: 0.7, to: 1, duration: 0.6), forKey: "throb")

        // Wipe the brow: paw up to the forehead, two dabs, back down.
        let wipe = keyframe("transform.rotation.z",
                            values: [0, 2.5, 2.1, 2.5, 0, 0],
                            times:  [0, 0.25, 0.38, 0.5, 0.75, 1],
                            duration: 2.8, easings: [.easeInOut, .easeInOut, .easeInOut, .easeInOut, .linear])
        rightArm.add(wipe, forKey: "wipe")
    }

    // MARK: - Reusable motions

    /// Squash & stretch synced to a hop loop (Disney #1): anticipation squash on takeoff, stretch
    /// in the air, a landing squash — with X countering Y so the volume reads as preserved.
    private func hopSquash(duration: Double, intensity: CGFloat) {
        let t: [Double] = [0, 0.12, 0.45, 0.88, 1]
        body.add(keyframe("transform.scale.y",
                          values: [1, 1 - intensity, 1 + intensity, 1 - intensity * 0.6, 1],
                          times: t, duration: duration, easings: nil), forKey: "squashY")
        body.add(keyframe("transform.scale.x",
                          values: [1, 1 + intensity * 0.7, 1 - intensity * 0.7, 1 + intensity * 0.4, 1],
                          times: t, duration: duration, easings: nil), forKey: "squashX")
    }

    /// Breath: a gentle vertical squash-and-stretch from the ground, with a slight horizontal give.
    private func breathe(period: Double, amount: CGFloat) {
        body.add(basic("transform.scale.y", from: 1, to: 1 + amount, duration: period), forKey: "breatheY")
        body.add(basic("transform.scale.x", from: 1, to: 1 - amount * 0.5, duration: period), forKey: "breatheX")
    }

    /// Blink: eyes hold open, then close and reopen — slower than a human blink, the way cats do it.
    /// `open` lets a mood that already squints the eyes (grooving) blink from its own baseline.
    private func blink(period: Double, open: CGFloat) {
        let a = keyframe("transform.scale.y",
                         values: [open, open, open * 0.1, open, open],
                         times:  [0, 0.86, 0.92, 0.97, 1],
                         duration: period, easings: [.linear, .easeInOut, .easeInOut, .linear])
        leftEye.add(a, forKey: "blink")
        rightEye.add(a, forKey: "blink")
    }

    /// An idle glance: eyes slide left, pause, slide right, pause, recentre. Eased slides — linear
    /// eye movement is the fastest way to make a face read robotic.
    private func glance(period: Double, amount: CGFloat) {
        let a = keyframe("transform.translation.x",
                         values: [0, 0, -amount, -amount, 0, amount, amount, 0],
                         times:  [0, 0.14, 0.24, 0.42, 0.52, 0.62, 0.82, 1],
                         duration: period,
                         easings: [.linear, .easeInOut, .linear, .easeInOut,
                                   .easeInOut, .linear, .easeInOut])
        leftEye.add(a, forKey: "glance")
        rightEye.add(a, forKey: "glance")
    }

    /// The resting tail: mostly still, then a quick flick of the tip — the cat's idle tell.
    private func tailFlick(period: Double, from: CGFloat, to: CGFloat) {
        let a = keyframe("transform.rotation.z",
                         values: [from, from, to, from * 0.8, from],
                         times:  [0, 0.55, 0.66, 0.8, 1],
                         duration: period, easings: [.linear, .easeOut, .easeInOut, .easeInOut])
        tail.add(a, forKey: "flick")
    }

    /// A single quick ear twitch on a long loop. Give each ear a different period so they desync.
    /// Fast eased snap out, softer return — a twitch, not a metronome.
    private func earTwitch(_ ear: CALayer, base: CGFloat, period: Double) {
        let a = keyframe("transform.rotation.z",
                         values: [base, base, base + 0.3, base, base],
                         times:  [0, 0.55, 0.6, 0.66, 1],
                         duration: period, easings: [.linear, .easeOut, .easeInOut, .linear])
        ear.add(a, forKey: "twitch")
    }

    // MARK: - Props (also all rectangles)

    private func configureDumbbell() {
        rebuildProp(heldProp)
        addRect(to: heldProp, x: 4,  y: 8, w: 16, h: 3, color: Self.cSteel, radius: 1.5)   // bar
        addRect(to: heldProp, x: 1,  y: 5, w: 5,  h: 9, color: Self.cCoral, radius: 2)     // weights
        addRect(to: heldProp, x: 18, y: 5, w: 5,  h: 9, color: Self.cCoral, radius: 2)
    }

    /// A steaming coffee mug held up by the muzzle for the keep-awake sip. A fixed prop (not on the
    /// swinging arm) so the cup stays upright and the steam rises true; the steam wisps loop.
    private func configureMug() {
        floorProp.sublayers?.forEach { $0.removeFromSuperlayer() }
        floorProp.isHidden = false
        floorProp.position = CGPoint(x: 60, y: 33)      // just right of the muzzle, chin height
        addRect(to: floorProp, x: 3,   y: 0,   w: 10,  h: 9,   color: Self.cCream, radius: 2.5)  // cup
        addRect(to: floorProp, x: 4.5, y: 5.5, w: 7,   h: 2.5, color: Self.rgb(0x5A, 0x3B, 0x22), radius: 1)  // coffee
        addRect(to: floorProp, x: 12,  y: 2,   w: 3.5, h: 5,   color: Self.cCream, radius: 2)    // handle
        for (dx, off) in [(-1.5, 0.0), (2.0, 0.75)] {
            let s = CALayer()
            s.bounds = CGRect(x: 0, y: 0, width: 2.2, height: 2.2)
            s.cornerRadius = 1.1
            s.position = CGPoint(x: 8 + dx, y: 10)
            s.backgroundColor = Self.cCream
            s.opacity = 0
            s.contentsScale = backing
            floorProp.addSublayer(s)
            let rise = keyframe("transform.translation.y", values: [0, 6], times: [0, 1],
                                duration: 1.5, easings: [.easeOut])
            rise.timeOffset = off
            let fade = keyframe("opacity", values: [0, 0.6, 0], times: [0, 0.3, 1],
                                duration: 1.5, easings: nil)
            fade.timeOffset = off
            s.add(rise, forKey: "rise")
            s.add(fade, forKey: "fade")
        }
    }

    /// The worker's yellow hard hat: domed crown, wide brim, a ridge on top — parked on the
    /// forehead, just above the eyes.
    private func configureHardHat() {
        hat.sublayers?.forEach { $0.removeFromSuperlayer() }
        hat.isHidden = false
        hat.opacity = 0                              // the drop fades it in
        addRect(to: hat, x: 0,  y: 0,   w: 32, h: 3,   color: Self.cYellow, radius: 1.5)   // brim
        addRect(to: hat, x: 3,  y: 2,   w: 26, h: 7.5, color: Self.cYellow, radius: 3.75)  // crown
        addRect(to: hat, x: 13, y: 4.5, w: 6,  h: 5.5, color: Self.cAmber,  radius: 2)     // ridge
    }

    /// The preview's little monitor on the ground in front of the cat, its screen glowing softly.
    private func configureScreen() {
        rebuildFloorProp()
        floorProp.position = CGPoint(x: 0, y: 35)    // left of the face, inside the band
        addRect(to: floorProp, x: 2, y: 0, w: 16, h: 11, color: Self.cSteel, radius: 2)          // bezel
        let screen = addRect(to: floorProp, x: 3.5, y: 1.5, w: 13, h: 8, color: Self.cCream, radius: 1)
        screen.add(basic("opacity", from: 0.65, to: 1, duration: 1.4), forKey: "glow")
    }

    private func rebuildFloorProp() {
        floorProp.sublayers?.forEach { $0.removeFromSuperlayer() }
        floorProp.isHidden = false
    }

    /// The build hammer — orange, held head-up in the right paw.
    private func configureHammer() {
        rebuildProp(heldProp)
        addRect(to: heldProp, x: 10, y: 0,  w: 4,  h: 20, color: Self.cOrangeDark, radius: 2)   // handle
        addRect(to: heldProp, x: 4,  y: 18, w: 16, h: 7,  color: Self.cOrange, radius: 2)       // head
    }

    /// Real letter Z's — a classic sleep trail of three (small → large), climbing up-and-right in
    /// a staggered loop while the cat dozes. Text layers, not bars: a drawn Z never quite connects
    /// at this size.
    private func configureZzz() {
        floatProp.sublayers?.forEach { $0.removeFromSuperlayer() }
        floatProp.isHidden = false
        for (i, size) in [7.0, 9.5, 12.0].enumerated() {
            let z = CATextLayer()
            z.string = "Z"
            z.font = NSFont.systemFont(ofSize: size, weight: .heavy)
            z.fontSize = size
            z.foregroundColor = Self.cCream
            z.alignmentMode = .center
            z.frame = CGRect(x: CGFloat(i) * 7 - 4, y: CGFloat(i) * 4, width: 14, height: size * 1.4)
            z.contentsScale = backing * 2   // glyphs need extra sharpness this small
            z.opacity = 0
            floatProp.addSublayer(z)
            let rise = keyframe("transform.translation.y", values: [0, 10], times: [0, 1],
                                duration: 2.6, easings: [.easeOut])
            rise.timeOffset = Double(i) * 0.55
            let fade = keyframe("opacity", values: [0, 0.9, 0.9, 0], times: [0, 0.2, 0.6, 1],
                                duration: 2.6, easings: nil)
            fade.timeOffset = Double(i) * 0.55
            z.add(rise, forKey: "rise")
            z.add(fade, forKey: "fade")
        }
    }

    /// A dozen tiny coloured rectangles bursting up from behind the head, each on its own arc, spin
    /// and fade, staggered so the celebration rains continuously (the article's confetti, procedural).
    private func configureConfetti() {
        confetti.sublayers?.forEach { $0.removeFromSuperlayer() }
        confetti.isHidden = false
        let colors = [Self.cCoral, Self.cCream, Self.cWater, Self.cSteel]
        for i in 0..<12 {
            let p = CALayer()
            p.bounds = CGRect(x: 0, y: 0, width: 3, height: 5)
            p.position = CGPoint(x: 50, y: 56)   // bursts from between the eyes, inside the band
            p.backgroundColor = colors[i % colors.count]
            p.cornerRadius = 1
            p.contentsScale = backing
            confetti.addSublayer(p)

            let dx = CGFloat.random(in: -34...34)
            let up = CGFloat.random(in: 6...12)
            let dur = Double.random(in: 1.1...1.7)

            let tx = CABasicAnimation(keyPath: "transform.translation.x")
            tx.fromValue = 0; tx.toValue = dx
            tx.timingFunction = timing(.easeOut)
            let ty = keyframe("transform.translation.y", values: [0, up, -26], times: [0, 0.38, 1],
                              duration: dur, easings: [.easeOut, .easeIn])
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0; spin.toValue = CGFloat.random(in: -5...5)
            let fade = keyframe("opacity", values: [1, 1, 0], times: [0, 0.65, 1],
                                duration: dur, easings: nil)

            let group = CAAnimationGroup()
            group.animations = [tx, ty, spin, fade]
            group.duration = dur
            group.repeatCount = .infinity
            group.timeOffset = Double.random(in: 0..<dur)   // stagger the bursts
            p.add(group, forKey: "burst")
        }
    }

    /// A light-blue sweat bead near the head, sliding down and fading on a loop.
    private func configureSweat() {
        fx.sublayers?.forEach { $0.removeFromSuperlayer() }
        fx.isHidden = false
        fx.removeAllAnimations()
        fx.speed = 1
        fx.position = CGPoint(x: 68, y: 60)
        addRect(to: fx, x: 2, y: 0, w: 4, h: 7, color: Self.cWater, radius: 2)
        let drop = keyframe("transform.translation.y", values: [4, 4, -10], times: [0, 0.3, 1],
                            duration: 1.1, easings: [.linear, .easeIn])
        let fade = keyframe("opacity", values: [0, 1, 1, 0], times: [0, 0.3, 0.75, 1],
                            duration: 1.1, easings: nil)
        fx.add(drop, forKey: "drop")
        fx.add(fade, forKey: "fade")
    }

    /// A continuous shower of little hearts rising from the cat's chest, fanning out, tilting and
    /// shrinking away as they climb past the face — the click "love" burst. Reuses the confetti
    /// container (cleared/hidden by `clearAnimations` when the event ends).
    private func configureHearts() {
        confetti.sublayers?.forEach { $0.removeFromSuperlayer() }
        confetti.isHidden = false
        for i in 0..<9 {
            let heart = CAShapeLayer()
            heart.bounds = CGRect(x: 0, y: 0, width: 12, height: 11)
            heart.path = Self.heartPath(w: 12, h: 11)
            heart.fillColor = (i % 3 == 0) ? Self.cCream : Self.cHeart
            heart.position = CGPoint(x: 50, y: 42)       // from the chest, up through the face band
            heart.opacity = 0
            heart.contentsScale = backing
            confetti.addSublayer(heart)

            let dx = CGFloat.random(in: -22...22)
            let dur = Double.random(in: 1.3...2.0)
            let rise = keyframe("transform.translation.y", values: [0, 34], times: [0, 1],
                                duration: dur, easings: [.easeOut])
            let drift = keyframe("transform.translation.x", values: [0, dx * 0.45, dx], times: [0, 0.5, 1],
                                 duration: dur, easings: [.easeInOut, .easeInOut])
            let pop = keyframe("transform.scale", values: [0.2, 1.15, 0.9, 0.45], times: [0, 0.2, 0.5, 1],
                              duration: dur, easings: [.easeOutBack, .easeInOut, .easeIn])
            let tilt = keyframe("transform.rotation.z", values: [0, 0.22, -0.22, 0.1], times: [0, 0.33, 0.66, 1],
                                duration: dur, easings: nil)
            let fade = keyframe("opacity", values: [0, 1, 1, 0], times: [0, 0.18, 0.6, 1],
                                duration: dur, easings: nil)
            let group = CAAnimationGroup()
            group.animations = [rise, drift, pop, tilt, fade]
            group.duration = dur
            group.repeatCount = .infinity
            group.timeOffset = Double(i) * dur / 9        // even stagger so the shower is continuous
            heart.add(group, forKey: "float")
        }
    }

    /// Musical notes drifting up and fading beside the head while the cat vibes to its music, each
    /// sashaying side to side as it climbs. Real note glyphs (text layers) on a staggered loop.
    private func configureNotes() {
        floatProp.sublayers?.forEach { $0.removeFromSuperlayer() }
        floatProp.isHidden = false
        floatProp.position = CGPoint(x: 86, y: 50)       // off the right cheek, inside the face band
        let glyphs = ["♪", "♫", "♩"]
        for (i, g) in glyphs.enumerated() {
            let note = CATextLayer()
            note.string = g
            note.font = NSFont.systemFont(ofSize: 12, weight: .bold)
            note.fontSize = 11 + CGFloat(i)
            note.foregroundColor = (i == 1) ? Self.cCoral : Self.cCream
            note.alignmentMode = .center
            note.frame = CGRect(x: CGFloat(i) * 6 - 6, y: 0, width: 16, height: 16)
            note.contentsScale = backing * 2             // glyphs need extra sharpness this small
            note.opacity = 0
            floatProp.addSublayer(note)
            let dur = 2.4
            let off = Double(i) * 0.7
            let rise = keyframe("transform.translation.y", values: [0, 17], times: [0, 1],
                                duration: dur, easings: [.easeOut])
            rise.timeOffset = off
            let sway = keyframe("transform.translation.x", values: [0, 3, -3, 2], times: [0, 0.33, 0.66, 1],
                                duration: dur, easings: [.easeInOut, .easeInOut, .easeInOut])
            sway.timeOffset = off
            let fade = keyframe("opacity", values: [0, 0.95, 0.95, 0], times: [0, 0.2, 0.6, 1],
                                duration: dur, easings: nil)
            fade.timeOffset = off
            note.add(rise, forKey: "rise")
            note.add(sway, forKey: "sway")
            note.add(fade, forKey: "fade")
        }
    }

    // MARK: - The launch rocket (launching / completed / exploded)

    /// The launch rocket, cartoon-classic (per the reference): an amber teardrop fuselage that
    /// TAPERS to the tip, a red nose cone, a big slate-ringed porthole with sky-blue glass, and
    /// red fins flaring out diagonally at the base. The taper and the flare are what keep the
    /// silhouette reading "rocket".
    private func configureRocket(flame: Bool) {
        rocket.sublayers?.forEach { $0.removeFromSuperlayer() }
        rocket.isHidden = false
        rocket.opacity = 1

        // Fins first, flared out-and-down, so the fuselage overlaps their roots.
        for (cx, rot) in [(3.0, 0.5), (17.0, -0.5)] {
            let fin = CALayer()
            fin.bounds = CGRect(x: 0, y: 0, width: 5.5, height: 10)
            fin.position = CGPoint(x: cx, y: 6)
            fin.backgroundColor = Self.cRed
            fin.cornerRadius = 2
            fin.contentsScale = backing
            fin.transform = CATransform3DMakeRotation(CGFloat(rot), 0, 0, 1)
            rocket.addSublayer(fin)
        }

        // Fuselage: a teardrop narrowing to the apex — a shape, since rectangles can't taper.
        let fuselage = CAShapeLayer()
        fuselage.frame = CGRect(x: 0, y: 0, width: 20, height: 30)
        let f = CGMutablePath()
        f.move(to: CGPoint(x: 4.5, y: 2))
        f.addQuadCurve(to: CGPoint(x: 10, y: 29.5), control: CGPoint(x: 3.5, y: 21))
        f.addQuadCurve(to: CGPoint(x: 15.5, y: 2), control: CGPoint(x: 16.5, y: 21))
        f.closeSubpath()
        fuselage.path = f
        fuselage.fillColor = Self.cAmber
        fuselage.contentsScale = backing
        rocket.addSublayer(fuselage)

        // Red nose cone capping the tip, its base matching the fuselage width at that height.
        let cone = CAShapeLayer()
        cone.frame = CGRect(x: 0, y: 0, width: 20, height: 30)
        let c = CGMutablePath()
        c.move(to: CGPoint(x: 6.4, y: 22.5))
        c.addQuadCurve(to: CGPoint(x: 10, y: 29.5), control: CGPoint(x: 7.4, y: 27.2))
        c.addQuadCurve(to: CGPoint(x: 13.6, y: 22.5), control: CGPoint(x: 12.6, y: 27.2))
        c.closeSubpath()
        cone.path = c
        cone.fillColor = Self.cRed
        cone.contentsScale = backing
        rocket.addSublayer(cone)

        // The porthole: slate ring, sky-blue glass — big, like the reference.
        addRect(to: rocket, x: 5.5, y: 11, w: 9, h: 9, color: Self.cSlate, radius: 4.5)
        addRect(to: rocket, x: 7,   y: 12.5, w: 6, h: 6, color: Self.cWater, radius: 3)

        rocketFlame.frame = CGRect(x: 7, y: -5, width: 6, height: 7)
        rocketFlame.backgroundColor = Self.cAmber
        rocketFlame.cornerRadius = 3
        rocketFlame.contentsScale = backing
        rocketFlame.isHidden = !flame
        rocket.addSublayer(rocketFlame)
        if flame {
            rocketFlame.add(basic("transform.scale.y", from: 0.7, to: 1.3, duration: 0.1), forKey: "flicker")
        }
    }

    /// Gentle engine-warming wisps rising off the rocket's base while it vibrates on the pad.
    private func configureWisps() {
        smoke.sublayers?.forEach { $0.removeFromSuperlayer() }
        smoke.isHidden = false
        smoke.position = CGPoint(x: 94, y: 33)
        // A steady billow off the pad: eight puffs on a tight stagger (~0.22 s apart, each living
        // 1.8 s) so there's always a full column of smoke rising, swelling and fading — engine
        // warming up hard, not a lone wisp.
        let puffs: [(dx: CGFloat, off: Double, size: CGFloat)] = [
            (-8, 0.0, 5.5), (8, 0.22, 5), (-4, 0.45, 4.5), (5, 0.68, 5),
            (-1, 0.9, 4.5), (3, 1.12, 5.5), (-6, 1.35, 4.5), (7, 1.58, 5),
        ]
        for p in puffs {
            let puff = CALayer()
            puff.bounds = CGRect(x: 0, y: 0, width: p.size, height: p.size)
            puff.position = CGPoint(x: 20 + p.dx, y: 8)
            puff.cornerRadius = p.size / 2
            puff.backgroundColor = Self.cCream
            puff.opacity = 0
            puff.contentsScale = backing
            smoke.addSublayer(puff)
            let rise = keyframe("transform.translation.y", values: [0, 9], times: [0, 1],
                                duration: 1.8, easings: [.easeOut])
            rise.timeOffset = p.off
            let grow = keyframe("transform.scale", values: [0.6, 1.5], times: [0, 1],
                                duration: 1.8, easings: [.easeOut])
            grow.timeOffset = p.off
            let fade = keyframe("opacity", values: [0, 0.7, 0], times: [0, 0.3, 1],
                                duration: 1.8, easings: nil)
            fade.timeOffset = p.off
            puff.add(rise, forKey: "rise")
            puff.add(grow, forKey: "grow")
            puff.add(fade, forKey: "fade")
        }
    }

    /// The liftoff billow: fat puffs bursting sideways off the pad while the rocket rips upward.
    private func configureLiftoffSmoke() {
        smoke.sublayers?.forEach { $0.removeFromSuperlayer() }
        smoke.isHidden = false
        smoke.position = CGPoint(x: 94, y: 33)
        // A big blast on liftoff: eight fat puffs bursting out both ways (and a couple straight
        // down) so the pad disappears in smoke as the rocket rips upward.
        let puffs: [(dx: CGFloat, dy: CGFloat, off: Double)] = [
            (-10, 1, 0.0), (-6, -2, 0.06), (-3, 2, 0.12), (0, -1, 0.18),
            (3, 2, 0.24), (6, -2, 0.3), (10, 1, 0.36), (0, 3, 0.14),
        ]
        for p in puffs {
            let puff = CALayer()
            puff.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)
            puff.position = CGPoint(x: 20, y: 8)
            puff.cornerRadius = 3.5
            puff.backgroundColor = Self.cCream
            puff.opacity = 0
            puff.contentsScale = backing
            smoke.addSublayer(puff)
            let dx = keyframe("transform.translation.x", values: [0, p.dx * 1.8], times: [0, 1],
                              duration: 1.1, easings: [.easeOut])
            dx.timeOffset = p.off
            let dy = keyframe("transform.translation.y", values: [0, p.dy * 1.8], times: [0, 1],
                              duration: 1.1, easings: [.easeOut])
            dy.timeOffset = p.off
            let grow = keyframe("transform.scale", values: [0.5, 2.0], times: [0, 1],
                                duration: 1.1, easings: [.easeOut])
            grow.timeOffset = p.off
            let fade = keyframe("opacity", values: [0, 0.9, 0], times: [0, 0.25, 1],
                                duration: 1.1, easings: nil)
            fade.timeOffset = p.off
            puff.add(dx, forKey: "dx")
            puff.add(dy, forKey: "dy")
            puff.add(grow, forKey: "grow")
            puff.add(fade, forKey: "fade")
        }
    }

    /// The bang: debris flying radially out of the rocket's spot, timed to land right as its
    /// violent rattle ends (~0.35 s into the 3-second event).
    private func configureExplosion() {
        smoke.sublayers?.forEach { $0.removeFromSuperlayer() }
        smoke.isHidden = false
        smoke.position = CGPoint(x: 94, y: 48)
        let colors = [Self.cOrange, Self.cRed, Self.cAmber, Self.cSteel]
        let t0 = 0.117                        // 0.35 s of the 3 s timeline
        for i in 0..<10 {
            let debris = CALayer()
            debris.bounds = CGRect(x: 0, y: 0, width: 4, height: 4)
            debris.position = CGPoint(x: 20, y: 10)
            debris.cornerRadius = 2
            debris.backgroundColor = colors[i % colors.count]
            debris.opacity = 0
            debris.contentsScale = backing
            smoke.addSublayer(debris)
            let angle = Double(i) / 10 * 2 * Double.pi
            let radius = CGFloat.random(in: 12...22)
            let dx = radius * CGFloat(cos(angle))
            let dy = radius * CGFloat(sin(angle))
            debris.add(keyframe("transform.translation.x", values: [0, 0, dx, dx],
                                times: [0, t0, t0 + 0.18, 1], duration: 3,
                                easings: [.linear, .easeOut, .linear], repeats: 1), forKey: "dx")
            debris.add(keyframe("transform.translation.y", values: [0, 0, dy, dy],
                                times: [0, t0, t0 + 0.18, 1], duration: 3,
                                easings: [.linear, .easeOut, .linear], repeats: 1), forKey: "dy")
            debris.add(keyframe("opacity", values: [0, 0, 1, 1, 0, 0],
                                times: [0, t0, t0 + 0.01, t0 + 0.12, t0 + 0.25, 1],
                                duration: 3, easings: nil, repeats: 1), forKey: "flash")
        }
    }

    private func rebuildProp(_ prop: CALayer) {
        prop.sublayers?.forEach { $0.removeFromSuperlayer() }
        prop.isHidden = false
    }

    @discardableResult
    private func addRect(to parent: CALayer, x: CGFloat, y: CGFloat, w: CGFloat, h: CGFloat,
                         color: CGColor, radius: CGFloat) -> CALayer {
        let l = CALayer()
        l.frame = CGRect(x: x, y: y, width: w, height: h)
        l.backgroundColor = color
        l.cornerRadius = radius
        l.contentsScale = backing
        parent.addSublayer(l)
        return l
    }

    /// A symmetric heart in a `w`×`h` box offset by (ox, oy), drawn y-up (two lobes at the top, the
    /// point at the bottom) — used for the love-burst hearts and the heart eyes. Two mirrored cubic
    /// curves: tip → left lobe → top dip → right lobe → tip.
    private static func heartPath(w: CGFloat, h: CGFloat, ox: CGFloat = 0, oy: CGFloat = 0) -> CGPath {
        let p = CGMutablePath()
        let cx = ox + w / 2
        let tip = CGPoint(x: cx, y: oy + h * 0.06)
        let dip = CGPoint(x: cx, y: oy + h * 0.60)
        p.move(to: tip)
        p.addCurve(to: dip,                                                   // up the left lobe
                   control1: CGPoint(x: ox + w * 0.02, y: oy + h * 0.32),
                   control2: CGPoint(x: ox + w * 0.06, y: oy + h * 0.96))
        p.addCurve(to: tip,                                                   // down the right lobe
                   control1: CGPoint(x: ox + w * 0.94, y: oy + h * 0.96),
                   control2: CGPoint(x: ox + w * 0.98, y: oy + h * 0.32))
        p.closeSubpath()
        return p
    }

    // MARK: - Animation builders

    private enum Ease { case linear, easeIn, easeOut, easeInOut, easeOutBack }

    private func timing(_ e: Ease) -> CAMediaTimingFunction {
        switch e {
        case .linear:    return CAMediaTimingFunction(name: .linear)
        case .easeIn:    return CAMediaTimingFunction(name: .easeIn)
        case .easeOut:   return CAMediaTimingFunction(name: .easeOut)
        case .easeInOut: return CAMediaTimingFunction(name: .easeInEaseOut)
        // The mascot's SIGNATURE curve (Playful archetype): decelerates past the target and settles
        // back — the standard "bounce settle" bezier. Used for entrances/pops.
        case .easeOutBack: return CAMediaTimingFunction(controlPoints: 0.175, 0.885, 0.32, 1.275)
        }
    }

    /// An autoreversing, forever-repeating tween — the workhorse for breath/sway/taps.
    private func basic(_ keyPath: String, from: CGFloat, to: CGFloat, duration: Double) -> CABasicAnimation {
        let a = CABasicAnimation(keyPath: keyPath)
        a.fromValue = from
        a.toValue = to
        a.duration = duration
        a.autoreverses = true
        a.repeatCount = .infinity
        a.timingFunction = timing(.easeInOut)
        return a
    }

    /// A multi-stop keyframe animation. `easings`, if given, is one function per segment
    /// (values.count − 1); pass nil for linear throughout. Loops forever by default; one-shot
    /// vignettes pass `repeats: 1` and snap back to the model pose when done.
    private func keyframe(_ keyPath: String, values: [CGFloat], times: [Double], duration: Double,
                          easings: [Ease]?, repeats: Float = .infinity) -> CAKeyframeAnimation {
        let a = CAKeyframeAnimation(keyPath: keyPath)
        a.values = values
        a.keyTimes = times.map { NSNumber(value: $0) }
        a.duration = duration
        a.repeatCount = repeats
        if let easings { a.timingFunctions = easings.map { timing($0) } }
        return a
    }

    private static func rgb(_ r: Int, _ g: Int, _ b: Int) -> CGColor {
        CGColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
    }
}
