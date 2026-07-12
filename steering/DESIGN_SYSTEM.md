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
| `voxiSuccess` / `voxiWarning` / `voxiDanger` | semantic status text/icons |
| `voxiStatus*Bg` + chip foregrounds | card status chips (mapping in `QueueView.swift`, unit-tested) |

## Rules

1. **New UI color = token first, never a literal.** No named SwiftUI colors (`.green`, `.orange`…), no hex, no `.black.opacity(…)` in views. If a token is missing, add a color set + Theme accessor in the same change.
2. **Butter is rationed.** Full `#FFEFB3` only via `voxiLive` (and the dark accent). Grounds use the near-cream/near-black tints. If a screen shows butter in three places, remove one.
3. **Separate by tone, not line.** Tonal step → hairline → never a border stack. `.shadow` exists only on the pill panel.
4. **Status colors belong to status.** The chip set and Success/Warning/Danger never get borrowed for emphasis.
5. **The pill is always Night Race.** `PillPanel` pins `NSAppearance(.darkAqua)`, so adaptive tokens resolve dark inside it in both system appearances. Consequence: colors in `PillView` must be adaptive tokens or fixed constants — reintroducing system materials/semantics (e.g. `.regularMaterial`, `.secondary`) silently breaks the pinned look in light mode.
6. **One British detail per surface**, each encoding real information: pill = coachline; queue = racing-number discs (`RacingNumberDisc`, display order, deliberately non-adaptive); onboarding = gauge-tick progress; Hub = plaque section headers (`Text.voxiPlaque()`); menu bar/app = the roundel. Two on one surface is a costume.
7. **Rows inside selectable `List`s keep the system text hierarchy** (`.primary`/`.secondary`), not ink tokens — the system flips those styles when a row is selected; fixed ink-on-accent is unreadable in light mode. Tokens resume outside the row. Exemplar: `HistoryRowView`.

## Asset generation

Image-model output (icons, artwork) often fakes transparency by painting a checkerboard into the pixels — check `sips -g hasAlpha` before trusting it. The fix that produced the current app icon: corner flood-fill on neutral (low-spread) pixels to real alpha, then emit the size ladder; brand cream `#FFEFB3` survives any tight neutrality test because of its 76-point red-blue spread. Script pattern: the CoreGraphics flood-mask used for `AppIcon.appiconset` (2026-07-12).

## Decisions (why it's built this way)

- **Hand-written token extensions, no codegen** — ~20 colors don't justify a SwiftGen dependency (`CODING_CONVENTIONS.md` dependency hygiene); the single-file extension is the drift guard.
- **Chip fills are dedicated `Bg` color sets with baked alpha**; chip foregrounds reuse semantic tokens (dispatched has its own text set). Change the mapping only in the `CardStatus` extension.
- **`voxiCommandTint` aliases `VoxiSuccess`** deliberately: under the pinned-dark pill it always resolves to mint `#7FD6B8`, distinguishing command mode from butter dictation without a new color set.
- **Sidebar exception:** `NavigationSplitView`'s sidebar keeps the system vibrancy material — it resists `.background` on macOS 14 (`.containerBackground` is 15+). Ground the detail pane only.
- **Window chrome** (transparent titlebar + Paper background) is set at window creation only; the one-window-per-lifetime invariants in `MACOS_PLATFORM.md` are untouched.

## Verification

Colors, appearance pinning, and window chrome are **not headlessly testable** — restyle changes carry the manual checklist in `TESTING_AND_VERIFICATION.md` style: both system appearances, pill over light and dark desktops, dark-mode log readability. Pure mappings (chips, device naming, tick geometry inputs) are unit-tested.
