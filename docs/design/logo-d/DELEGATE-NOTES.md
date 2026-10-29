# Strim logo direction notes (design only)

Status: proposal from design reasoning and the current tree (`Sources/StrimSite/Mark.swift`). No external research, competitor audit or user testing was done. No glyph was drawn or rasterized at 16px, so every size claim below is an estimate to check.

Constraints held: neutral surfaces, one accent (#7C7CF5 dark / #4F46E5 light), no gradients, no green, one flat color, legible at 16px.

## Positioning

A local LLM server on a Mac. It should look like a quiet, dependable utility that sits in the menu bar. Avoid chat bubbles, sparkles, brains, neural nodes, chips, Apple-logo riffs, terminal `>_` and waves. The one idea Strim owns is the stream: text arriving as discrete tokens.

## Recommendation 1 (best fit): capsule S, simplified

One lowercase-leaning S built from token capsules, which is the current mark's idea, reduced to one flat color.

Why it fits:
- It carries the name (S) and the product idea (tokens in a stream) in one silhouette.
- The mark already exists on the site, so this evolves it rather than restarting.
- Its shape is rounded-square, so it sits well in the macOS icon grid and the menu bar.
- It uses one color and needs no tile to be read.

Construction:
- Draw on a 64 grid with one stroke width and round caps. Use a single centerline path, then expand it to outlines for the final SVG.
- Use 3 capsules (top, middle, bottom) rather than 4. The current dash pattern (14.5 on, 11 off at 8.5 stroke) gives about 2.75 px gaps at 16 px, which is likely to blur.
- Keep gaps at 0.4 to 0.5 times the stroke width at minimum. Make the stroke at least 12% of the glyph height.
- Make the turns generous. Prefer one clear S curve over tight bends so the counters stay open.
- Optional accent detail: render the leading capsule (the end of the S) in the accent and the rest in text color. This is a two-tone variant. The one-color master must stand on its own.
- Provide three files: a full-color mark on a tile, a one-color mark with no tile, and a monochrome template for the menu bar (black on transparent, shape only).

Small-size risks:
- Gaps close at 16 px and the S reads as a blob or a "5". Fix by using fewer capsules and wider gaps, and by giving the 16 px size its own cut (heavier stroke, fewer segments) instead of scaling the master.
- Dashed rhythm shimmers on non-retina displays. Align the capsule edges to the pixel grid at 16 and 32.
- A tile with a hairline border disappears under 24 px. Drop the border below that size.

## Recommendation 2 (alternative): cursor s

A single-stroke lowercase s with a square-ended terminal block (a cursor or a token) at its end.

Why it might fit:
- It reads as "text in progress", which is a stream of output.
- The silhouette is a plain solid glyph, so it is very robust at 16 px.

Risks:
- A cursor block next to a letter can read as a terminal or editor mark and drift toward cliché. Keep the block the same width as the stroke so it stays part of the letter, not a separate symbol.
- It is less ownable than option 1, since a lowercase s with one cut is easy to confuse with other marks.

Pick this only if the capsule S fails the 16 px test after simplification.

## Wordmark

- Lowercase `strim`, set in the system sans (SF Pro Rounded or the current system stack is acceptable) at semibold, roughly weight 600.
- Tracking +1% to +2% for the lockup, wider at small sizes. No custom ligatures.
- Round the terminals only if the mark uses round caps, so the two share one stroke language. Do not mix a rounded mark with a sharp geometric wordmark.
- Color: text color for the wordmark and the mark's accent only on the mark. Never accent both.
- Lockup: mark height equals the x-height plus ascender of the wordmark, with a gap of about half the mark width. Offer a horizontal lockup and a mark-only version; skip a stacked lockup unless something needs it.
- Minimum sizes (to verify): mark-only 16 px, lockup 96 px wide.
- A custom-drawn wordmark is out of scope. Use a licensed or system font and check the license before putting it in any shipped asset (the site uses a system stack, so no font file is bundled today).

## Next checks (not done)

1. Draw both marks as outlined SVG and render at 16, 20, 32 and 64 px, light and dark, and 1x and 2x.
2. Test the template version in a real menu bar in light and dark appearance.
3. Check contrast of the accent against both surfaces. Do not assume #7C7CF5 or #4F46E5 passes for small text.
4. Compare the shortlist against the current mark side by side before replacing it.
