import AppKit
import ObjectiveC.runtime
import SwiftUI

/// Fixes two macOS 27 bugs in AppKit's `-[_NSScrollingRubberbandFilter addDelta:velocity:]`
/// that cause severe scroll position jumps and dead zones during elastic trackpad scrolling:
///
/// 1. **Upper-bound (`maxScrollX` / `maxScrollY`) overscroll teleport (`<+908>` / `<+952>`):**
///    When `_scrollPosition` reaches `maxScroll` on VBL tick `N` (`initialStretch == 0`
///    and `unstretchedDistance == 0`), AppKit checks `totalDelta > 0`
///    (`fcmp d10/d14, #0.0; cset w8/w10, gt`) instead of `fabs(totalDelta) > 0` to decide
///    whether to enter the rubber-band curve. When scrolling toward `maxScroll` in a
///    flipped vertical scroll view (or horizontally toward `maxScrollX`), `totalDelta < 0`,
///    so the check evaluates to `0`, bypassing the rubber-band curve (`cbz w8, <+2016>`)
///    and adding the raw unclamped trackpad delta directly onto `_scrollPosition`.
///
/// 2. **Un-stretching cross-zero damping & `13.3x` velocity jump (`<+1044>..<+1400>` and `<+1420>..<+1984>`):**
///    When stretched past `minScroll` or `maxScroll` and the user reverses direction back
///    toward the document, AppKit un-stretches along the inverse hyperbolic curve
///    (`_hyperbolicCoefficient = 0.075`, ~`13.3x` slower than 1:1 finger motion) and still
///    multiplies the boundary-crossing frame by `0.075` while discarding the remaining
///    swipe delta, before abruptly switching back to `1.0x` on the following VBL tick.
public enum ScrollRubberbandFix {
    /// Output of a single 1D rubber-band filter step along one axis (X or Y).
    public struct AxisStepResult: Sendable, Equatable {
        /// Updated scroll position (`_scrollPosition.x` or `_scrollPosition.y`).
        public let position: Double
        /// Position delta applied on this step (`newPosition - oldPosition`).
        public let appliedDelta: Double
        /// Updated sub-pixel overflow (`_overflow.x` or `_overflow.y`) in AppKit's raw-delta sign convention.
        public let overflow: Double
        /// Filtered velocity (`_filteredVelocity.x` or `_filteredVelocity.y`) in position-space sign convention.
        public let filteredVelocity: Double
        /// Whether this axis is currently stretched beyond `pointsPerPixel`.
        public let isStretched: Bool
    }

    /// Default AppKit hyperbolic rubber-band coefficient (`0.075`).
    public static let defaultHyperbolicCoefficient: Double = 0.075

    /// Whether the `-[_NSScrollingRubberbandFilter addDelta:velocity:]` fix has been installed.
    @MainActor public private(set) static var isInstalled: Bool = false

    /// Installs the once-per-process `-[_NSScrollingRubberbandFilter addDelta:velocity:]` fix.
    ///
    /// Safe to call multiple times; subsequent calls are no-ops and return `true` if installed.
    @MainActor
    @discardableResult
    public static func install() -> Bool {
        if isInstalled { return true }
        _ = NSScrollView.self

        guard let filterClass = NSClassFromString("_NSScrollingRubberbandFilter") else {
            return false
        }
        let selector = NSSelectorFromString("addDelta:velocity:")
        guard let method = class_getInstanceMethod(filterClass, selector) else {
            return false
        }

        func ivarOffset(_ name: String) -> Int? {
            guard let ivar = class_getInstanceVariable(filterClass, name) else { return nil }
            return ivar_getOffset(ivar)
        }

        guard
            let clipSizeOff = ivarOffset("_clippingSize"),
            let docFrameOff = ivarOffset("_documentFrame"),
            let pppOff = ivarOffset("_pointsPerPixel"),
            let transformOff = ivarOffset("_affineTransformOfContent"),
            let coeffOff = ivarOffset("_hyperbolicCoefficient"),
            let flags1Off = ivarOffset("_flags1"),
            let flags2Off = ivarOffset("_flags2"),
            let posOff = ivarOffset("_scrollPosition"),
            let filteredDeltaOff = ivarOffset("_filteredDelta"),
            let filteredVelOff = ivarOffset("_filteredVelocity"),
            let overflowOff = ivarOffset("_overflow")
        else {
            return false
        }

        let block: @convention(block) (AnyObject, CGPoint, CGPoint) -> Void = { obj, delta, velocity in
            let ptr = Unmanaged.passUnretained(obj).toOpaque()

            let flags1 = ptr.advanced(by: flags1Off).loadUnaligned(as: UInt32.self)
            let isFlipped = (flags1 & 1) != 0
            let allowsH = (flags1 & 2) != 0
            let allowsV = (flags1 & 4) != 0

            let a = ptr.advanced(by: transformOff).loadUnaligned(as: Double.self)
            let b = ptr.advanced(by: transformOff + 8).loadUnaligned(as: Double.self)
            let c = ptr.advanced(by: transformOff + 16).loadUnaligned(as: Double.self)
            let dMat = ptr.advanced(by: transformOff + 24).loadUnaligned(as: Double.self)

            let clipW = ptr.advanced(by: clipSizeOff).loadUnaligned(as: Double.self)
            let clipH = ptr.advanced(by: clipSizeOff + 8).loadUnaligned(as: Double.self)
            let docX = ptr.advanced(by: docFrameOff).loadUnaligned(as: Double.self)
            let docY = ptr.advanced(by: docFrameOff + 8).loadUnaligned(as: Double.self)
            let docW = ptr.advanced(by: docFrameOff + 16).loadUnaligned(as: Double.self)
            let docH = ptr.advanced(by: docFrameOff + 24).loadUnaligned(as: Double.self)

            let ppp = max(ptr.advanced(by: pppOff).loadUnaligned(as: Double.self), 0.25)
            let rawCoeff = ptr.advanced(by: coeffOff).loadUnaligned(as: Double.self)
            let coeff = rawCoeff > 0 ? rawCoeff : defaultHyperbolicCoefficient

            let posX = ptr.advanced(by: posOff).loadUnaligned(as: Double.self)
            let posY = ptr.advanced(by: posOff + 8).loadUnaligned(as: Double.self)
            let prevFdX = ptr.advanced(by: filteredDeltaOff).loadUnaligned(as: Double.self)
            let prevFdY = ptr.advanced(by: filteredDeltaOff + 8).loadUnaligned(as: Double.self)
            let overflowX = ptr.advanced(by: overflowOff).loadUnaligned(as: Double.self)
            let overflowY = ptr.advanced(by: overflowOff + 8).loadUnaligned(as: Double.self)

            // Apply _affineTransformOfContent to delta and velocity (matching <+80>..<+116> and <+2028>..<+2096>)
            let transDeltaX = a * delta.x + c * delta.y
            let transDeltaY = b * delta.x + dMat * delta.y
            let transVelX = a * velocity.x + c * velocity.y
            let transVelY = b * velocity.x + dMat * velocity.y

            let minX = docX
            let maxX = max(minX, docX + docW - clipW)
            let minY = docY
            let maxY = max(minY, docY + docH - clipH)

            let stepX = stepAxis(
                position: posX,
                minPosition: minX,
                maxPosition: maxX,
                clipDimension: clipW,
                rawDelta: transDeltaX,
                rawVelocity: transVelX,
                positionSign: -1.0,
                overflow: overflowX,
                allowsRubberbanding: allowsH,
                pointsPerPixel: ppp,
                coefficient: coeff
            )

            let stepY = stepAxis(
                position: posY,
                minPosition: minY,
                maxPosition: maxY,
                clipDimension: clipH,
                rawDelta: transDeltaY,
                rawVelocity: transVelY,
                positionSign: isFlipped ? -1.0 : 1.0,
                overflow: overflowY,
                allowsRubberbanding: allowsV,
                pointsPerPixel: ppp,
                coefficient: coeff
            )

            let oldFlags2 = ptr.advanced(by: flags2Off).loadUnaligned(as: UInt32.self)
            let stretchedBit: UInt32 = (stepX.isStretched || stepY.isStretched) ? 1 : 0
            let newFlags2 = (oldFlags2 & ~1) | stretchedBit
            ptr.advanced(by: flags2Off).storeBytes(of: newFlags2, as: UInt32.self)
            ptr.advanced(by: posOff).storeBytes(of: stepX.position, as: Double.self)
            ptr.advanced(by: posOff + 8).storeBytes(of: stepY.position, as: Double.self)
            ptr.advanced(by: filteredDeltaOff).storeBytes(of: prevFdX + stepX.appliedDelta, as: Double.self)
            ptr.advanced(by: filteredDeltaOff + 8).storeBytes(of: prevFdY + stepY.appliedDelta, as: Double.self)
            ptr.advanced(by: filteredVelOff).storeBytes(of: stepX.filteredVelocity, as: Double.self)
            ptr.advanced(by: filteredVelOff + 8).storeBytes(of: stepY.filteredVelocity, as: Double.self)
            ptr.advanced(by: overflowOff).storeBytes(of: stepX.overflow, as: Double.self)
            ptr.advanced(by: overflowOff + 8).storeBytes(of: stepY.overflow, as: Double.self)
        }

        _ = method_setImplementation(method, imp_implementationWithBlock(block))
        isInstalled = true
        return true
    }

    // MARK: - Pure Rubber-Band Math

    /// Maps an unstretched overscroll distance `u >= 0` to a stretched display displacement
    /// using AppKit's hyperbolic curve `d * (1 - 1 / (1 + c * u / d))`.
    @inlinable
    public static func rubberband(
        _ unstretchedDistance: Double,
        dimension: Double,
        coefficient: Double = defaultHyperbolicCoefficient
    ) -> Double {
        guard unstretchedDistance > 0 else { return 0 }
        guard dimension > 0, coefficient > 0 else { return unstretchedDistance / 20.0 }
        let x = coefficient * unstretchedDistance / dimension
        return dimension * (1.0 - 1.0 / (1.0 + x))
    }

    /// Maps a stretched display displacement `s >= 0` back to the unstretched overscroll
    /// distance `u` using the exact inverse hyperbolic curve `(d / c) * (r / (1 - r))`.
    @inlinable
    public static func inverseRubberband(
        _ stretchedDistance: Double,
        dimension: Double,
        coefficient: Double = defaultHyperbolicCoefficient
    ) -> Double {
        guard stretchedDistance > 0 else { return 0 }
        guard dimension > 0, coefficient > 0 else { return stretchedDistance * 20.0 }
        let ratio = min(stretchedDistance / dimension, 0.999999)
        return (dimension / coefficient) * (ratio / (1.0 - ratio))
    }

    /// Advances a single scroll axis by one VBL tick.
    ///
    /// - Parameters:
    ///   - position: Current `_scrollPosition` coordinate on the axis.
    ///   - minPosition: Minimum in-bounds scroll position (`_documentFrame.origin`).
    ///   - maxPosition: Maximum in-bounds scroll position (`max(minPosition, docOrigin + docSize - clipSize)`).
    ///   - clipDimension: Viewport size along the axis (`_clippingBounds.size`).
    ///   - rawDelta: Transformed trackpad delta along the axis.
    ///   - rawVelocity: Transformed trackpad velocity along the axis.
    ///   - positionSign: `-1.0` when a positive `rawDelta` decreases `position` (X axis, and flipped Y axis),
    ///     or `+1.0` when a positive `rawDelta` increases `position` (non-flipped Y axis).
    ///   - overflow: Previous sub-pixel `_overflow` in AppKit's `rawDelta` sign convention.
    ///   - allowsRubberbanding: Whether rubber-band stretching is enabled on this axis.
    ///   - pointsPerPixel: Pixel quantization step (`_pointsPerPixel`, e.g. `0.5` on 2x Retina).
    ///   - coefficient: Hyperbolic rubber-band coefficient (`_hyperbolicCoefficient`, default `0.075`).
    public static func stepAxis(
        position: Double,
        minPosition: Double,
        maxPosition: Double,
        clipDimension: Double,
        rawDelta: Double,
        rawVelocity: Double,
        positionSign: Double,
        overflow: Double,
        allowsRubberbanding: Bool,
        pointsPerPixel: Double,
        coefficient: Double = defaultHyperbolicCoefficient
    ) -> AxisStepResult {
        let sign: Double = positionSign < 0 ? -1.0 : 1.0
        let ppp = max(pointsPerPixel, 0.25)
        let minPos = minPosition
        let maxPos = max(minPosition, maxPosition)

        // Convert raw delta and overflow into position-space (positive = toward +infinity / maxPos).
        let dPos = sign * rawDelta
        let ovfPos = sign * overflow

        guard allowsRubberbanding else {
            let targetPos = position + dPos + ovfPos
            let clampedPos = min(max(targetPos, minPos), maxPos)
            let applied = clampedPos - position
            let vel = (applied == 0 && rawVelocity == 0) ? 0.0 : sign * rawVelocity
            return AxisStepResult(
                position: clampedPos,
                appliedDelta: applied,
                overflow: 0.0,
                filteredVelocity: vel,
                isStretched: false
            )
        }

        let stretch0: Double
        if position < minPos - 1e-6 {
            stretch0 = position - minPos
        } else if position > maxPos + 1e-6 {
            stretch0 = position - maxPos
        } else {
            stretch0 = 0
        }

        let newPos: Double
        let newOvfPos: Double

        if stretch0 > 0 {
            if dPos >= 0 {
                // Pulling further past maxPos (upper rubber-band)
                let u0 = inverseRubberband(stretch0, dimension: clipDimension, coefficient: coefficient)
                let u1 = max(0, u0 + dPos + ovfPos)
                let s1 = rubberband(u1, dimension: clipDimension, coefficient: coefficient)
                let s1Rounded = (s1 / ppp).rounded(.towardZero) * ppp
                let nextStretch = max(stretch0, s1Rounded)
                newPos = maxPos + nextStretch
                newOvfPos = u1 - inverseRubberband(nextStretch, dimension: clipDimension, coefficient: coefficient)
            } else {
                // Reversing back toward the document (1:1 immediate response)
                let targetPos = position + dPos
                if targetPos >= minPos {
                    newPos = targetPos
                    newOvfPos = 0
                } else {
                    let u1 = minPos - targetPos
                    let s1 = (rubberband(u1, dimension: clipDimension, coefficient: coefficient) / ppp).rounded(.towardZero) * ppp
                    newPos = minPos - s1
                    newOvfPos = -(u1 - inverseRubberband(s1, dimension: clipDimension, coefficient: coefficient))
                }
            }
        } else if stretch0 < 0 {
            if dPos <= 0 {
                // Pulling further past minPos (lower rubber-band)
                let u0 = inverseRubberband(-stretch0, dimension: clipDimension, coefficient: coefficient)
                let u1 = max(0, u0 - (dPos + ovfPos))
                let s1 = rubberband(u1, dimension: clipDimension, coefficient: coefficient)
                let s1Rounded = (s1 / ppp).rounded(.towardZero) * ppp
                let nextStretch = max(-stretch0, s1Rounded)
                newPos = minPos - nextStretch
                newOvfPos = -(u1 - inverseRubberband(nextStretch, dimension: clipDimension, coefficient: coefficient))
            } else {
                // Reversing back toward the document (1:1 immediate response)
                let targetPos = position + dPos
                if targetPos <= maxPos {
                    newPos = targetPos
                    newOvfPos = 0
                } else {
                    let u1 = targetPos - maxPos
                    let s1 = (rubberband(u1, dimension: clipDimension, coefficient: coefficient) / ppp).rounded(.towardZero) * ppp
                    newPos = maxPos + s1
                    newOvfPos = u1 - inverseRubberband(s1, dimension: clipDimension, coefficient: coefficient)
                }
            }
        } else {
            // Starting in-bounds (minPos ... maxPos)
            let targetPos = position + dPos + ovfPos
            if targetPos >= minPos && targetPos <= maxPos {
                newPos = targetPos
                newOvfPos = 0
            } else if targetPos > maxPos {
                let u1 = targetPos - maxPos
                let s1 = (rubberband(u1, dimension: clipDimension, coefficient: coefficient) / ppp).rounded(.towardZero) * ppp
                newPos = maxPos + s1
                newOvfPos = u1 - inverseRubberband(s1, dimension: clipDimension, coefficient: coefficient)
            } else {
                let u1 = minPos - targetPos
                let s1 = (rubberband(u1, dimension: clipDimension, coefficient: coefficient) / ppp).rounded(.towardZero) * ppp
                newPos = minPos - s1
                newOvfPos = -(u1 - inverseRubberband(s1, dimension: clipDimension, coefficient: coefficient))
            }
        }

        let appliedDelta = newPos - position
        let isStretched = (newPos < minPos - ppp) || (newPos > maxPos + ppp)
        let posVel = sign * rawVelocity
        let pullingFurtherIntoStretch = (newPos > maxPos && posVel > 0) || (newPos < minPos && posVel < 0)
        let filteredVelocity: Double
        if pullingFurtherIntoStretch || (appliedDelta == 0 && rawVelocity == 0) {
            filteredVelocity = 0.0
        } else {
            filteredVelocity = posVel
        }

        return AxisStepResult(
            position: newPos,
            appliedDelta: appliedDelta,
            overflow: sign * newOvfPos,
            filteredVelocity: filteredVelocity,
            isStretched: isStretched
        )
    }
}

/// An invisible `NSViewRepresentable` anchor that ensures `ScrollRubberbandFix.install()`
/// is active and optionally configures its enclosing `NSScrollView`'s elasticity.
public struct ScrollRubberbandFixer: NSViewRepresentable {
    private let verticalElasticity: NSScrollView.Elasticity
    private let horizontalElasticity: NSScrollView.Elasticity?

    public init(
        verticalElasticity: NSScrollView.Elasticity = .allowed,
        horizontalElasticity: NSScrollView.Elasticity? = nil
    ) {
        self.verticalElasticity = verticalElasticity
        self.horizontalElasticity = horizontalElasticity
    }

    public func makeNSView(context: Context) -> NSView {
        ScrollRubberbandFix.install()
        let view = AnchorView()
        view.verticalElasticity = verticalElasticity
        view.horizontalElasticity = horizontalElasticity
        return view
    }

    public func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? AnchorView else { return }
        view.verticalElasticity = verticalElasticity
        view.horizontalElasticity = horizontalElasticity
        view.applyElasticity()
    }

    private final class AnchorView: NSView {
        var verticalElasticity: NSScrollView.Elasticity = .allowed
        var horizontalElasticity: NSScrollView.Elasticity?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            applyElasticity()
        }

        func applyElasticity() {
            if let scrollView = enclosingScrollView {
                configure(scrollView)
            } else if let root = superview?.superview ?? superview {
                configureDescendantScrollViews(in: root)
            }
        }

        private func configure(_ scrollView: NSScrollView) {
            scrollView.verticalScrollElasticity = verticalElasticity
            if let horizontalElasticity {
                scrollView.horizontalScrollElasticity = horizontalElasticity
            }
        }

        private func configureDescendantScrollViews(in view: NSView) {
            for subview in view.subviews where subview !== self {
                if let scrollView = subview as? NSScrollView {
                    configure(scrollView)
                } else {
                    configureDescendantScrollViews(in: subview)
                }
            }
        }
    }
}

public extension View {
    /// Installs `ScrollRubberbandFix` and ensures the enclosing `ScrollView` uses the
    /// specified rubber-band elasticity.
    func scrollRubberbandFix(
        verticalElasticity: NSScrollView.Elasticity = .allowed,
        horizontalElasticity: NSScrollView.Elasticity? = nil
    ) -> some View {
        background(
            ScrollRubberbandFixer(
                verticalElasticity: verticalElasticity,
                horizontalElasticity: horizontalElasticity
            )
        )
    }
}
