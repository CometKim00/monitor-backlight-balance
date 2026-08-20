# Calibration Guide

The shipped values are tuned for one specific panel. This guide walks through retuning them for yours. Budget about ten minutes.

You only ever edit the block marked **(1) TUNING** at the top of the script.

---

## Step 1 — Photograph your panel

1. Open a full-screen pure white image (or [this test page](https://screendetect.com/tests/backlight-bleed-test) set to white).
2. Turn the room lights **off**. Ambient light on the bezel will fool you.
3. Set the monitor to the brightness you actually use day to day.
4. Stand directly in front, centered, and take a photo with your phone. Don't shoot at an angle — the falloff you see off-axis isn't the defect.

Now look at the photo, not the screen. A camera flattens your eye's auto-adaptation and makes the stain obvious.

---

## Step 2 — Find the boundary

Identify the region that is **dim and/or yellow**. That region will receive *no* correction — it's the reference everything else gets matched down to.

Trace the line where that region ends. In this project's coordinate system:

- `x` runs `0.0` (left edge) → `1.0` (right edge)
- `y` runs `0.0` (top edge) → `1.0` (bottom edge)

Pick four to six points along that line and write them into `gradPoints`, ordered left to right:

```autohotkey
gradPoints := [
    {x: 0.00, y: 0.88},
    {x: 0.15, y: 0.94},
    {x: 0.35, y: 0.96},
    {x: 0.55, y: 0.89},
    {x: 0.75, y: 0.79},
    {x: 1.00, y: 0.72}
]
```

Everything **below** this line is left alone. Everything **above** it is progressively dimmed.

### Two things that trip people up

**Your defect may not span the full width.** If the stain only exists on the right half, the left half should have *no* untouched zone at all. Push those `y` values past `1.0` — a value of `1.20` means "the boundary is below the bottom of the screen here", so that whole column gets corrected.

**Panel edges are often already dim.** Most LCDs vignette slightly at the far left and right. If the far edge looks too dark after correcting, *lower* the `y` at `x: 0.00` — less correction there, not more. That's why the sample above dips to `0.88` at the left edge before rising to `0.96`.

---

## Step 3 — Set the strength

```autohotkey
maxAlpha := 70
```

This is the alpha (0–255) applied at maximum. Start at 45 and work up.

Toggle with `Ctrl+Alt+O` while watching a white window. You want the healthy area to drop until it *matches* the stain — not until it looks dark. If you overshoot, the previously-healthy region starts looking dirtier than the defect.

```autohotkey
falloffDepth := 0.80
```

How far the ramp travels, measured in screen heights, before hitting `maxAlpha`. Larger = wider and gentler. If you see a hard edge where correction begins, raise this. If the correction never reaches full strength before the top of the screen, lower it.

```autohotkey
minAlpha := 7
```

A floor applied everywhere, including inside the stain. Useful when the stain still reads slightly brighter than you'd like. Set to `0` to leave the defect completely untouched.

---

## Step 4 — Cancel the yellow cast

```autohotkey
yellowFix := 8
```

Dead backlight regions usually shift **yellow**, not just dark. This subtracts extra red and green in those regions while leaving blue alone, which pulls the color back toward neutral.

- Effect scales inversely with `alpha` — strongest inside the stain, zero where the overlay is already at full strength, so your global color balance is untouched.
- Range 0–40. Start at 8. Above ~20 the blue becomes obvious.
- Set to `0` to disable.

**Cost:** neutralizing yellow means cutting red and green further, so that region gets slightly dimmer. On black content it also picks up a faint blue tint (about RGB 0,0,8 at `yellowFix := 8`).

---

## Step 5 — Smoothness

```autohotkey
gradScale := 5
dither    := true
```

`gradScale` divides screen resolution for the alpha computation, then the result is scaled back up.

| `gradScale` | Grid (on 3440×1440) | Startup cost |
|---|---|---|
| 10 | 344 × 144 | ~0.3 s |
| 6 | 573 × 240 | ~1.1 s |
| 5 | 688 × 288 | ~1.4 s |
| 4 | 860 × 360 | ~2.3 s |

Cost is one-time at launch; there's zero runtime overhead once the bitmap is built.

`dither` is worth keeping on. Alpha is an 8-bit integer, so a 7→70 ramp over a 1440px screen gives each step about 23 pixels of height — plainly visible as bands. A 4×4 Bayer offset scatters the transitions and the banding disappears.

---

## Iterating efficiently

Re-tuning by eye is slow. What actually worked while building this:

1. Screenshot the overlay itself (`PrtSc` on a white background).
2. Draw on the screenshot — mark regions still too bright in one color, the actual defect in another.
3. Read the marked coordinates back as `x`/`y` fractions and translate them into `gradPoints`.

Marking up an image is far more precise than trying to describe "the bit on the lower left" in words, and it gives you numbers you can type straight into the config.

---

## Troubleshooting

**Nothing appears to change.** Confirm the process is running (tray icon present). Verify `maxAlpha` isn't near 0. Note that 45/255 is genuinely subtle — toggle with `Ctrl+Alt+O` to A/B it rather than judging from a static view.

**A visible arc or blob edge.** Your boundary points are too aggressively curved, or `falloffDepth` is too small. Boundary shapes that enclose a region (rather than spanning left to right) tend to produce a visible rim.

**The correction is on the wrong side.** The gradient darkens *above* the boundary line. If your defect is at the top of the panel, the sign of the comparison in `BuildGradientBitmap` needs flipping (`v < bV` → `v > bV`), and the falloff direction along with it.

**Full-screen games cover it.** Exclusive fullscreen bypasses layered windows. Use borderless windowed mode.
