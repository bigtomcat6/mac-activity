# Power flow animation correction — 2026-10-02

The current user request supersedes the earlier static-glow constraint. The
previous six-second blue/mint breathing animation misidentified the motion.

## Reference observation

Captured AlDente 1.35.1's already-open dashboard through the computer-use API
for 10 seconds: 127 timestamped screenshots, about 79 ms between samples.
These are sampled frames, not every display refresh. The visible state was
external power supplying the Mac with battery charging paused.

All 127 frames were examined in chronological contact sheets. Comparing the
middle-region color profiles across successive passes gave approximately
3.60 seconds per cycle. The visible sequence is:

1. The source plug becomes yellow before color appears in the track.
2. A blurred yellow leading edge travels left to right. Its fading tail grows
   from the left edge; it does not reverse direction.
3. The same wash transitions through a muted intermediate color into blue.
4. The destination laptop turns blue only when the front reaches the right.
5. The track fades first, the laptop fades later, then both rest briefly.

The watts update separately from this repeating sequence. Exact internal
AlDente timing functions are not available; the implementation fits these
visible samples. Other power topologies were not observed in AlDente.

## Implementation

`PowerFlowDiagramMotion` defines a 3.6-second timeline with separate travel,
color, opacity and endpoint stages. `PowerFlowDiagramGlow` renders one growing
linear-gradient wash with a blurred front. Horizontal blur scales with track
width; vertical blur stays proportional to card height. The wash is clipped
to the middle segment. Endpoint glyphs receive their source/destination cue
without coloring the surrounding tiles or missing-data glyphs.

The visible dashboard uses a 30 Hz SwiftUI timeline. Hidden, terminal and
Reduce Motion states keep the existing static rendering path. Measurement
collection and power calculations are unchanged.

## Verification

- Regression tests first failed against the previous cycle and color path.
- `swift test --disable-sandbox --filter PowerFlow`: 146 tests executed,
  4 conditional skips, zero failures. The opt-in motion exporter was enabled.
- Exported 108 production SwiftUI panel frames at 30 fps for a complete cycle.
- Compared normalized middle-region frames and endpoint timing with the
  timestamped reference; created a synchronized 10-second comparison GIF.
- `git diff --check` passed.

The exporter uses a fixed matte reference surface to isolate motion. Its
images do not establish native WindowServer glass equivalence or constitute
a live Energy-page capture. The whole application suite was not rerun for
this correction.

Local evidence directory:
`/Users/how/.codex/visualizations/2026/10/02/01a0fc83-d612-7d32-a31e-6537a84e9e97/powerflow-motion/`

The directory contains `comparison.gif`, `keyframes.png`, `timestamps.json`,
and the 127 cropped reference frames. Re-export production frames with:

```sh
MACACTIVITY_POWER_FLOW_MOTION_OUTPUT=/private/tmp/macactivity-powerflow-motion \
CLANG_MODULE_CACHE_PATH=/private/tmp/macactivity-clang-cache \
SWIFTPM_MODULECACHE_OVERRIDE=/private/tmp/macactivity-swiftpm-module-cache \
swift test --disable-sandbox \
  --filter PowerFlowDiagramVisualValidationTests/testExportMotionFramesWhenExplicitlyRequested
```
