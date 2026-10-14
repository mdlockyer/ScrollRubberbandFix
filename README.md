# ScrollRubberbandFix

Fixes two macOS 27 AppKit bugs in `-[_NSScrollingRubberbandFilter addDelta:velocity:]` that cause severe scroll position jumps, off-screen overscroll teleports, and sluggish direction-reversal dead zones in SwiftUI `ScrollView` (`HostingScrollView`) and AppKit `NSScrollView`.

## What It Fixes

Disassembling `-[_NSScrollingRubberbandFilter addDelta:velocity:]` in macOS 27 reveals two arithmetic bugs in AppKit's VBL trackpad rubber-band filter:

1. **Upper-bound (`maxScrollX` / `maxScrollY`) overscroll teleport (`<+908>` / `<+952>`):**
   When `_scrollPosition` reaches `maxScroll` on VBL tick $N$ (`initialStretch == 0` and `unstretchedDistance == 0`), AppKit checks `totalDelta > 0` (`fcmp d10/d14, #0.0; cset w8/w10, gt`) instead of `fabs(totalDelta) > 0` to decide whether to enter the hyperbolic rubber-band curve:
   ```asm
   AppKit`-[_NSScrollingRubberbandFilter addDelta:velocity:]:
   <+952>: fcmp d14, #0.0
   <+956>: cset w8, gt
   ...
   <+1416>: cbz  w8, <+2016>
   ```
   When scrolling down at the bottom of a flipped scroll view (or right at `maxScrollX`), `totalDelta < 0`, so `w8` evaluates to `0`, skipping the rubber-band curve and adding the **raw unclamped trackpad delta** directly onto `_scrollPosition` (teleporting content hundreds of points past `maxScroll` in a single frame).

2. **Un-stretching cross-zero damping & `13.3x` velocity jump (`<+1044>..<+1400>` and `<+1420>..<+1984>`):**
   When stretched past `minScroll` or `maxScroll` and the user reverses direction back into the document, AppKit un-stretches along the inverse hyperbolic curve (`_hyperbolicCoefficient = 0.075`, ~`13.3x` slower than 1:1 finger motion), and on the frame that crosses back into `[minScroll, maxScroll]`, it still multiplies the in-bounds movement by `0.075` while discarding the remaining swipe delta — before abruptly switching back to `1.0x` on the following VBL tick (`50–140 pt` single-frame jump).

## Installation

Add `ScrollRubberbandFix` to your `Package.swift`:

```swift
dependencies: [
    .package(path: "../ScrollRubberbandFix") // or git URL
]
```

And add `"ScrollRubberbandFix"` to your target's dependencies.

## Usage

### Option 1: Install once at app launch (covers all `ScrollView` / `NSScrollView` instances)

```swift
import ScrollRubberbandFix

@main
struct MyApp: App {
    init() {
        ScrollRubberbandFix.install()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
```

### Option 2: SwiftUI View Modifier

```swift
import ScrollRubberbandFix
import SwiftUI

ScrollView {
    ContentView()
        .scrollRubberbandFix()
}
```
