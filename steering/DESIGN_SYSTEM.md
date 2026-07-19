# Design System — "Racing Green & Cream"

Prescriptive standard for all Voxi UI. Brand constants: **Racing `#013E37`** and **Butter `#FFEFB3`**. Two appearances from one token set: **Paddock** (light) and **Night Race** (dark). Reference board (visual): the artifact linked in `plans/2026-07-12-racing-green-restyle/plan.md`.

## Tokens

All colors live as asset-catalog color sets (light + explicit dark variant each) and are accessed **only** through the `Color`/`NSColor` extensions in `Sources/Voxi/DesignSystem/Theme.swift` — asset-name strings appear once, there. Radii (`Theme.Radius`: control 8 / card 12 / panel 18; chips and the pill are Capsules) and spacing (`Theme.Space`: 4/8/12/16/24) come from the same file.

| Token | Role |
|---|---|
| `voxiPaper` / `voxiCard` / `voxiInset` | ground → card → well; separation is these tonal steps |
| `voxiHairline` | last-resort separator/stroke when a tonal step can't work |
| `voxiInk` / `voxiInk2` / `voxiInk3` | text tiers (use instead of `.primary/.secondary/.tertiary` on branded surfaces) |
| `AccentColor` (`.tint`) | Racing light / Butter dark — global; buttons, selection, focus |
| `voxiLive` | full-strength Butter: waveform bars, recording dot — the live layer only |
| `voxiCoachline` | the pill's inset keyline — used nowhere else |
| `voxiRacing` | Pit Wall rail ground (Hub sidebar) — racing green in BOTH appearances |
| `voxiRailSelection` | rail selected-item fill, baked-alpha butter (14%) — used nowhere else |
| `voxiSuccess` / `voxiWarning` / `voxiDanger` | semantic status text/icons |
| `voxiStatus*Bg` + chip foregrounds | card status chips (mapping in `QueueView.swift`, unit-tested) |

## Rules

1. **New UI color = token first, never a literal.** No named SwiftUI colors (`.green`, `.orange`…), no hex, no `.black.opacity(…)` in views. If a token is missing, add a color set + Theme accessor in the same change.
2. **Butter is rationed.** Full `#FFEFB3` only via `voxiLive` (and the dark accent). Grounds use the near-cream/near-black tints. If a screen shows butter in three places, remove one.
3. **Separate by tone, not line.** Tonal step → hairline → never a border stack. `.shadow` exists only on the pill panel.
4. **Status colors belong to status.** The chip set and Success/Warning/Danger never get borrowed for emphasis.
5. **The pill and the Hub rail are always Night Race.** `PillPanel` pins `NSAppearance(.darkAqua)` at the panel; `HubRailView` pins `.environment(\.colorScheme, .dark)` on its subtree. Same consequence for both: colors inside must be adaptive tokens or fixed constants — system materials/semantics (e.g. `.regularMaterial`, `.secondary`) silently break the pinned look in light mode. The rail additionally must stay pure SwiftUI: AppKit-hosted controls ignore the SwiftUI pin.
6. **One British detail per surface**, each encoding real information: pill = coachline; queue = racing-number discs (`RacingNumberDisc`, display order, deliberately non-adaptive); onboarding = gauge-tick progress; Hub = the Pit Wall rail (racing ground, roundel, butter selection) with plaques (`Text.voxiPlaque()`) demoted to supporting captions inside panes; menu bar/app = the roundel. Two on one surface is a costume.
7. **Rows inside selectable `List`s keep the system text hierarchy** (`.primary`/`.secondary`), not ink tokens — the system flips those styles when a row is selected; fixed ink-on-accent is unreadable in light mode. Tokens resume outside the row. Exemplar: `DictionaryRowView`. (History's ledger cards are not List rows — they sit on Paper and use ink tokens.)

## Asset generation

Image-model output (icons, artwork) often fakes transparency by painting a checkerboard into the pixels — check `sips -g hasAlpha` before trusting it. The fix that produced the current app icon: corner flood-fill on neutral (low-spread) pixels to real alpha, then emit the size ladder; brand cream `#FFEFB3` survives any tight neutrality test because of its 76-point red-blue spread. Script pattern: the CoreGraphics flood-mask used for `AppIcon.appiconset` (2026-07-12).

## Decisions (why it's built this way)

- **Hand-written token extensions, no codegen** — ~20 colors don't justify a SwiftGen dependency (`CODING_CONVENTIONS.md` dependency hygiene); the single-file extension is the drift guard.
- **Chip fills are dedicated `Bg` color sets with baked alpha**; chip foregrounds reuse semantic tokens (dispatched has its own text set). Change the mapping only in the `CardStatus` extension.
- **`voxiCommandTint` is the dedicated `VoxiCommand` signal red** (dark `#E4574A`, light `#C6473C`; 2026-07-19 — previously an alias of `VoxiSuccess` mint, which proved too subtle to notice). It is command mode's identity color: pill waveform, dot, and coachline keyline while recording a command. It is not `voxiDanger` and must not be — status colors belong to status.
- **Pit Wall rail (2026-07-18):** the Hub's `NavigationSplitView` sidebar is replaced by a custom fixed-width rail (`HubRailView`), which sidesteps the macOS-14 "sidebar resists `.background`" limitation entirely. The Hub window uses `.windowStyle(.hiddenTitleBar)` — traffic lights overlay the rail (40 pt top padding clears them); each pane opens with a `HubPaneHeader` hosting the controls the system toolbar used to (search, Clear All, Add Term). Min window width 820 = rail 196 + History split minimums.
- **Window chrome** (transparent titlebar + Paper background) is set at window creation only; the one-window-per-lifetime invariants in `MACOS_PLATFORM.md` are untouched.

## Verification

Colors, appearance pinning, and window chrome are **not headlessly testable** — restyle changes carry the manual checklist in `TESTING_AND_VERIFICATION.md` style: both system appearances, pill over light and dark desktops, dark-mode log readability. Pure mappings (chips, device naming, tick geometry inputs) are unit-tested.
