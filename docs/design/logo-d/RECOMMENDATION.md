# Recommendation

## Choose mark A + wordmark 4

Use the single, heavy, round-ended s (candidate A) as the master mark. It reads immediately at 16 px, reverses cleanly, and connects the product name to a stream without adding a second metaphor. Pair it with outlined wordmark 4: lowercase geometric strim, medium weight, compact tracking, and one vertical indigo capsule over the i. It gives the name a deliberate detail while keeping the rest of the lockup neutral.

The 24, 48, and 120 px comparisons show the s remains open and the capsule dot stays distinct. The wordmark is custom SVG path geometry, so it has no font dependency. Keep the 16 px variant mark-only; do not force the full lockup into favicon or menu-bar space.

### Keep and drop

- **Keep:** candidate A and wordmark 4 as the primary direction. Retain D (cut ribbon) and F (lowercase s plus token) as alternates.
- **Drop:** B's three bars, which read as an equals/list glyph at 16 px; C's prompt box, which becomes a generic window/cursor; and E's stepped S, which is legible but too mechanical to distinguish from A.
- **Replace:** the four glowing token capsules, pink/indigo gradient, dark bordered tile, and Space Grotesk wordmark treatment. Do not carry over the glow, extra pink, gradient, or decorative border.

## Construction rules

- **Dark accent:** #7C7CF5.
- **Light accent:** #4F46E5.
- **Neutrals:** near-black #1C1C22, white #FFFFFF, and soft light icon field #F3F4F6. No green, gradient, or glow.
- **Clear space:** around a standalone mark, leave at least one quarter of its visible height on every side. In a horizontal lockup, keep the gap between mark and wordmark at least one half of the mark's visible width. Keep other copy and edges outside that zone.
- **Minimum size:** mark-only 16 px; menu-bar template 18 pt; wordmark or full lockup 24 px high. If a smaller slot is unavoidable, use the mark alone and inspect the export at its real pixel size.
- **1024 px app icon:** use a 1024 × 1024 flat square source and let macOS apply its squircle mask. The preview construction uses a 229.07 px corner radius (22.37%), #1C1C22 dark / #F3F4F6 light field, and a centered mark at 95% scale with translation (25.6, 10) in the 1024 grid. The resulting mark bounds are approximately x=221–803 and y=206–821, leaving about 20% optical padding. Set the mark to #7C7CF5 on dark and #4F46E5 on light.
- **18 pt menu-bar template:** make an 18 × 18 pt transparent SVG/PDF with only the black alpha silhouette. For A, use the round S path at roughly 12 × 13 px, centered with about 2.5 px clear on each edge; the menu bar supplies the displayed tint. No background tile, accent, state dot, or stroke effect.

## Files to change when the direction is approved

These are the current source and generated surfaces found in the repository. They are listed for a future implementation only; none of them were changed for this exploration.

- site/assets/logo.svg
- site/assets/favicon.svg
- site/assets/favicon-32.png
- site/assets/apple-touch-icon.png
- site/assets/app-icon.svg
- site/assets/banner.svg
- Sources/StrimSite/Mark.swift — mark and banner/OG image SVG construction
- Sources/StrimSite/Charts.swift — writes logo.svg, favicon.svg, app-icon.svg, and banner.svg
- packaging/app/icon/icon-1024.png — app packaging source image
- Sources/StrimAppCore/Theme.swift — native mark and menu-bar template glyph
