# Design QA

**Source visual truth**

- `/var/folders/3x/gfdfg2x14f7_vd12c62fx0t40000gn/T/codex-clipboard-7cd99f40-c66b-4a42-a3f8-4002c3053c1c.png` — Dropover context menu, 728 × 1122 px
- `/var/folders/3x/gfdfg2x14f7_vd12c62fx0t40000gn/T/codex-clipboard-5ad4f84d-9fe5-47d9-92f7-3b590e065cf9.png` — Dropover collapsed image stack, 396 × 414 px
- `/var/folders/3x/gfdfg2x14f7_vd12c62fx0t40000gn/T/codex-clipboard-511dae35-594e-422d-8002-f031ad7be45c.png` — Dropover expanded file view, 800 × 620 px

**Implementation evidence**

- Intended app viewport: 340 × 340 pt expanded file basket, native macOS density.
- Implementation screenshot: unavailable.
- State intended for comparison: expanded basket containing several images and mixed file types, default grid mode, no selection; secondary states are list mode, multi-selection and collapsed stack.
- Density normalization: not performed because a rendered implementation screenshot could not be captured.

**Findings**

- [P1] Rendered app comparison is blocked.
  Location: installed WeClaw Send file basket.
  Evidence: the source Dropover screenshots are available, but the environment rejected the permission request needed to replace and launch `~/Applications/WeClaw Send.app`. A clean package build is additionally blocked by an inconsistent local Command Line Tools installation (Swift 6.2.4 with a macOS 26.2 SDK built by Swift 6.2.3), so there is no current-build implementation screenshot to combine with the source images. The changed `ShelfView.swift` and selection sources did compile before the unrelated module emission failure.
  Impact: thumbnail crop, header density, three-column spacing, typography and interaction states cannot be visually approved from code alone.
  Fix: align the active Swift toolchain and SDK, approve and run `./scripts/install.sh`, open a basket with representative images/documents/videos, capture the 340 × 340 pt window, then compare it with the Dropover expanded and collapsed references in one combined visual.

**Required fidelity surfaces**

- Fonts and typography: implemented with macOS system font, 13 pt title, 11.5 pt item names and 9.5–10.5 pt metadata; rendered weights, truncation and antialiasing remain unverified.
- Spacing and layout rhythm: implemented as a 340 × 340 pt window with adaptive three-column grid, 8 pt gaps and 10 pt cards; rendered header crowding and grid rhythm remain unverified.
- Colors and visual tokens: uses existing app/system colors and system accent selection; rendered contrast remains unverified.
- Image quality and asset fidelity: uses Quick Look thumbnails with high interpolation and system file-icon fallback; crop, sharpness and first-page/frame coverage remain unverified.
- Copy and content: Chinese labels, item count/size summary, filenames and file-size metadata are implemented; rendered truncation remains unverified.

**Full-view comparison evidence**

Blocked: no rendered current-build implementation screenshot is available.

**Focused region comparison evidence**

Blocked for the same reason. The first focused comparison should cover the header Grid/List control; the second should cover one image tile, one document/video tile and a multi-selected tile group.

**Comparison history**

- Iteration 1: blocked before visual comparison because the current build could not be cleanly packaged and installed/launched by the tool environment. No visual fixes were made from an unverified screenshot.

**Implementation checklist**

- Align the local Swift compiler and macOS SDK, then install and launch the current build.
- Populate one basket with representative image, video, PDF/document and folder items.
- Capture default grid, list, multi-selected and collapsed states.
- Combine source and implementation captures, fix any P0/P1/P2 drift, and repeat comparison.
- Exercise box selection and drag all selected URLs into Finder.

final result: blocked
