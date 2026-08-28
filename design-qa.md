# Notch Glass Fold Design QA

## Evidence

- Source visual truth: `/var/folders/3x/gfdfg2x14f7_vd12c62fx0t40000gn/T/codex-clipboard-5505bf91-1d0d-4aea-bb8f-f5898d62e6b8.png`
- Implementation screenshot: `/tmp/weclaw-fold-narrow-final.jpeg`
- Combined comparison: `/tmp/weclaw-fold-narrow-comparison.png`
- State: fixed immediate-send mode, three dragged items, ready to release
- Source pixels: 1740 × 904; generated concept without a measurable native point density
- Implementation pixels: 352 × 122; native panel 352 × 122 pt at capture density 1
- Implemented fold: approximately 145 × 40 pt on the QA MacBook display
- Focused source crop: 700 × 280 px, normalized beside the implementation in the combined comparison

## Full-view comparison evidence

The source establishes the attached fold geometry, green plane icon, and native Chinese action label. The implementation preserves that hierarchy while intentionally reducing the fold from the concept's oversized proportion to a menu-bar-scale component, adapting the glass to the desktop appearance, and omitting the item count after user feedback. The app screenshot is component-only because the nonactivating transparent panel capture excludes surrounding desktop chrome.

## Focused region comparison evidence

The combined comparison checks the entire visible fold in both artifacts. A tighter crop was not needed because the icon, typography, radius, material, and edge treatment are all readable at this scale.

## Required fidelity surfaces

- Fonts and typography: native system Chinese typography, semibold action label, and single-line copy match the intended hierarchy without truncation.
- Spacing and layout rhythm: the fold is centered, compact, top-attached, and uses bottom-only 12 pt continuous corners. Internal icon/text spacing remains optically balanced in direct and basket modes after removing the count.
- Colors and visual tokens: the plane uses `Brand.success`; the surface uses adaptive ultra-thin smoked glass, a 3% background correction, a 4.5% semantic state tint, and a short centered refraction line. No blue glow or opaque white card remains.
- Image quality and asset fidelity: the UI contains no raster assets. The standard paper-plane and tray icons use SF Symbols at native resolution, appropriate for this macOS control.
- Copy and content: `松手发送`, `松手加入文件篮`, the left/right hint, progress, success, and failure content all fit the compact surface. Project counts are not shown in any notch state; transfer progress percentage remains visible.

## Comparison history

### Iteration 1

- Finding: [P1] The 220 × 60 pt fold was too large for the real menu-bar context.
- Finding: [P1] Forced light appearance plus a 78% surface fill made the fold look like an opaque white panel instead of WeClaw glass.
- Evidence: user rejected the first implementation as too large, off-brand, and opaque.
- Fix: reduced the responsive fold to approximately 172 × 44 pt; changed to ultra-thin material with an 8% adaptive tint; reduced shadow opacity and radius; compacted feedback typography and progress layout.

### Iteration 2

- Post-fix evidence: `/tmp/weclaw-fold-direct-final.jpeg` and the separately observed basket and sending QA states.
- Result: no remaining actionable P0, P1, or P2 mismatch in the component state.

### Iteration 3

- Finding: [P2] The 172 × 44 pt fold still occupied too much width in the user's real Finder context, and its forced light material read as a uniform gray panel rather than atmospheric glass.
- Evidence: `/var/folders/3x/gfdfg2x14f7_vd12c62fx0t40000gn/T/codex-clipboard-57b77f3e-6056-4728-92b1-d60d31f42aeb.png`.
- Fix: reduced the responsive fold to approximately 145 × 40 pt; restored adaptive appearance; added only a low-opacity semantic tint, short centered refraction line, and state-tinted ambient shadow.
- Post-fix evidence: `/tmp/weclaw-fold-narrow-final.jpeg` and `/tmp/weclaw-fold-narrow-comparison.png`; basket and sending states were separately observed without truncation.
- Result: no remaining actionable P0, P1, or P2 mismatch in the refined component state.

### Iteration 4

- Finding: [P2] The item count added unnecessary visual weight to the compact action label and reappeared in preparing, sending, basket-success, and direct-success states.
- Fix: removed project-count copy from every notch state while retaining the internal count for queue tracking and the percentage for transfer progress.
- Post-fix evidence: direct, basket, sending, and success debug states were observed through the native macOS accessibility tree and component capture; no project count or stale spacing remained.
- Result: no remaining actionable P0, P1, or P2 mismatch after count removal.

## Findings

- No actionable P0, P1, or P2 findings remain.

## Open Questions

- None blocking. A real user drag after installation remains useful for subjective motion tuning, but geometry, state content, and reduced-motion behavior use the existing verified controller path.

## Implementation Checklist

- [x] Compact fold scale
- [x] Translucent app-aligned material
- [x] Direct, basket, and left/right selection states
- [x] Preparing, progress, success, and failure states
- [x] Native typography and SF Symbols
- [x] Reduced-motion compatibility

## Follow-up Polish

- [P3] If the unfolding spring feels too lively during a real drag, adjust only its response and damping after live use; no geometry change is required.

final result: passed
