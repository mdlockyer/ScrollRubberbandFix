import AppKit
import ObjectiveC.runtime
import Testing
@testable import ScrollRubberbandFix

@Suite("ScrollRubberbandFix Tests")
struct ScrollRubberbandFixTests {
    @Test("rubberband and inverseRubberband are exact inverses")
    func rubberbandInverseIdentity() {
        let dim = 300.0
        let coeff = ScrollRubberbandFix.defaultHyperbolicCoefficient
        for u in [0.0, 0.5, 5.0, 25.0, 100.0, 400.0, 1500.0] {
            let s = ScrollRubberbandFix.rubberband(u, dimension: dim, coefficient: coeff)
            let recovered = ScrollRubberbandFix.inverseRubberband(s, dimension: dim, coefficient: coeff)
            #expect(abs(recovered - u) < 1e-9)
            if u > 0 {
                #expect(s > 0 && s < dim)
                #expect(s < u)
            }
        }
    }

    @Test("Flipped vertical overscroll past maxScrollY is smoothly damped instead of teleporting")
    func flippedBottomOverscrollIsSmoothlyDamped() {
        let minY = 0.0
        let maxY = 130.0
        let clipH = 266.0
        let ppp = 0.5

        var pos = 0.0
        var ovf = 0.0
        let deltas: [Double] = [-15, -35, -55, -65, -50, -30, -10]
        var positions: [Double] = []

        for d in deltas {
            let step = ScrollRubberbandFix.stepAxis(
                position: pos,
                minPosition: minY,
                maxPosition: maxY,
                clipDimension: clipH,
                rawDelta: d,
                rawVelocity: d * 60.0,
                positionSign: -1.0,
                overflow: ovf,
                allowsRubberbanding: true,
                pointsPerPixel: ppp
            )
            pos = step.position
            ovf = step.overflow
            positions.append(pos)
        }

        // First 3 steps are in-bounds (15, 50, 105)
        #expect(positions[0] == 15.0)
        #expect(positions[1] == 50.0)
        #expect(positions[2] == 105.0)

        // Step 3 crosses maxY (105 + 65 = 170 -> 40pt raw overscroll -> ~2.5pt rubber-band stretch)
        #expect(positions[3] > maxY)
        #expect(positions[3] < maxY + 5.0)

        // Subsequent downward steps continue stretching monotonically with heavy damping (never jumping to 270+)
        for i in 4..<positions.count {
            #expect(positions[i] >= positions[i - 1])
            #expect(positions[i] < maxY + 15.0)
        }
    }

    @Test("Reversing direction from stretched state responds 1:1 immediately without a cross-zero jump")
    func directionReversalFromStretchHasZeroDeadZoneAndNoJump() {
        let minY = 0.0
        let maxY = 130.0
        let clipH = 266.0
        let ppp = 0.5

        // Start stretched at the bottom (139.0, 9pt past maxY = 130.0)
        let reverseStep1 = ScrollRubberbandFix.stepAxis(
            position: 139.0,
            minPosition: minY,
            maxPosition: maxY,
            clipDimension: clipH,
            rawDelta: 15.0,
            rawVelocity: 300.0,
            positionSign: -1.0,
            overflow: -6.2,
            allowsRubberbanding: true,
            pointsPerPixel: ppp
        )
        // Moves 1:1 by -15pt (139 -> 124), crossing maxY=130 smoothly with zero 0.075x crawl
        #expect(reverseStep1.position == 124.0)
        #expect(reverseStep1.appliedDelta == -15.0)
        #expect(reverseStep1.overflow == 0.0)
        #expect(reverseStep1.filteredVelocity == -300.0)

        // Next frame continues 1:1 at the exact same gain
        let reverseStep2 = ScrollRubberbandFix.stepAxis(
            position: reverseStep1.position,
            minPosition: minY,
            maxPosition: maxY,
            clipDimension: clipH,
            rawDelta: 15.0,
            rawVelocity: 300.0,
            positionSign: -1.0,
            overflow: reverseStep1.overflow,
            allowsRubberbanding: true,
            pointsPerPixel: ppp
        )
        #expect(reverseStep2.position == 109.0)
        #expect(reverseStep2.appliedDelta == -15.0)
    }

    @Test("Outward velocity is zeroed while stretched so release springs back immediately")
    func outwardVelocityZeroedWhenStretched() {
        let stepBottomOutward = ScrollRubberbandFix.stepAxis(
            position: 135.0,
            minPosition: 0.0,
            maxPosition: 130.0,
            clipDimension: 266.0,
            rawDelta: -20.0,
            rawVelocity: -500.0,
            positionSign: -1.0,
            overflow: 0.0,
            allowsRubberbanding: true,
            pointsPerPixel: 0.5
        )
        #expect(stepBottomOutward.position > 135.0)
        #expect(stepBottomOutward.filteredVelocity == 0.0)

        let stepTopOutward = ScrollRubberbandFix.stepAxis(
            position: -3.0,
            minPosition: 0.0,
            maxPosition: 130.0,
            clipDimension: 266.0,
            rawDelta: 20.0,
            rawVelocity: 500.0,
            positionSign: -1.0,
            overflow: 0.0,
            allowsRubberbanding: true,
            pointsPerPixel: 0.5
        )
        #expect(stepTopOutward.position < -3.0)
        #expect(stepTopOutward.filteredVelocity == 0.0)
    }

    @Test("Non-elastic axis clamps strictly to bounds")
    func nonElasticAxisClampsToBounds() {
        let stepPastMax = ScrollRubberbandFix.stepAxis(
            position: 110.0,
            minPosition: 0.0,
            maxPosition: 130.0,
            clipDimension: 266.0,
            rawDelta: -50.0,
            rawVelocity: -400.0,
            positionSign: -1.0,
            overflow: 0.0,
            allowsRubberbanding: false,
            pointsPerPixel: 0.5
        )
        #expect(stepPastMax.position == 130.0)
        #expect(stepPastMax.appliedDelta == 20.0)
        #expect(!stepPastMax.isStretched)
    }

    @Test("Live AppKit _NSScrollingRubberbandFilter integration")
    @MainActor
    func liveAppKitRubberbandFilterIntegration() throws {
        let installed = ScrollRubberbandFix.install()
        #expect(installed)
        #expect(ScrollRubberbandFix.isInstalled)

        let filterClass: AnyClass = try #require(NSClassFromString("_NSScrollingRubberbandFilter"))
        let addDeltaSel = NSSelectorFromString("addDelta:velocity:")
        let addDeltaMethod = try #require(class_getInstanceMethod(filterClass, addDeltaSel))

        func ivarOffset(_ name: String) throws -> Int {
            let ivar = try #require(class_getInstanceVariable(filterClass, name))
            return ivar_getOffset(ivar)
        }

        let clipSizeOff = try ivarOffset("_clippingSize")
        let docFrameOff = try ivarOffset("_documentFrame")
        let pppOff = try ivarOffset("_pointsPerPixel")
        let transformOff = try ivarOffset("_affineTransformOfContent")
        let coeffOff = try ivarOffset("_hyperbolicCoefficient")
        let flags1Off = try ivarOffset("_flags1")
        let posOff = try ivarOffset("_scrollPosition")

        let filter: AnyObject = try #require(class_createInstance(filterClass, 0) as AnyObject?)
        let ptr = Unmanaged.passUnretained(filter).toOpaque()

        // Configure viewport (564 x 266) and document (564 x 396 -> maxScrollY = 130.0)
        ptr.advanced(by: clipSizeOff).storeBytes(of: 564.0, as: Double.self)
        ptr.advanced(by: clipSizeOff + 8).storeBytes(of: 266.0, as: Double.self)
        ptr.advanced(by: docFrameOff).storeBytes(of: 0.0, as: Double.self)
        ptr.advanced(by: docFrameOff + 8).storeBytes(of: 0.0, as: Double.self)
        ptr.advanced(by: docFrameOff + 16).storeBytes(of: 564.0, as: Double.self)
        ptr.advanced(by: docFrameOff + 24).storeBytes(of: 396.0, as: Double.self)
        ptr.advanced(by: pppOff).storeBytes(of: 0.5, as: Double.self)
        ptr.advanced(by: transformOff).storeBytes(of: 1.0, as: Double.self)
        ptr.advanced(by: transformOff + 8).storeBytes(of: 0.0, as: Double.self)
        ptr.advanced(by: transformOff + 16).storeBytes(of: 0.0, as: Double.self)
        ptr.advanced(by: transformOff + 24).storeBytes(of: 1.0, as: Double.self)
        ptr.advanced(by: coeffOff).storeBytes(of: 0.075, as: Double.self)
        // flipped = 1 (bit 0), allowsHorizontalRubberbanding = 0 (bit 1), allowsVerticalRubberbanding = 1 (bit 2) -> 0x5
        ptr.advanced(by: flags1Off).storeBytes(of: UInt32(0x5), as: UInt32.self)

        typealias AddDeltaFn = @convention(c) (AnyObject, Selector, CGPoint, CGPoint) -> Void
        let addDelta = unsafeBitCast(method_getImplementation(addDeltaMethod), to: AddDeltaFn.self)

        let deltas: [Double] = [-15, -35, -55, -65, -50, -30, -10, 15, 40, 60, 50, 25]
        var recordedY: [Double] = []
        for d in deltas {
            addDelta(filter, addDeltaSel, CGPoint(x: 0, y: d), CGPoint(x: 0, y: d * 60))
            let y = ptr.advanced(by: posOff + 8).loadUnaligned(as: Double.self)
            recordedY.append(y)
        }

        #expect(recordedY == [15.0, 50.0, 105.0, 132.5, 136.5, 138.5, 139.0, 124.0, 84.0, 24.0, -1.5, -3.5])
    }
}
