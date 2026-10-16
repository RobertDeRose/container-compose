# Logo: SVG version (work in progress)

The project icon is a raster illustration,
[`docs/assets/container-compose-icon.png`](../../docs/assets/container-compose-icon.png):
an apple built from shipping containers, some carrying the logos of apps people
run in containers. This folder holds an attempt to turn it into an SVG logo
that scales from a favicon to a hero image. The work is paused: the outline is
solved, but the fill does not yet look like a polished logo.

## The brief

These constraints came from the project owner and should carry forward:

- Keep the concept. An apple made of containers, with app logos on some of
  them, says exactly what the project is: Compose on Apple's runtime, running
  your apps. Abstract or unrelated marks were rejected.
- Match the original icon's own silhouette and colours, not Apple's logo. The
  original is rounder and has no bite, and reads less like Apple's mark.
- The outline must be smooth curves that hug the original's edge, including
  both leaf tips and the dips at the top and bottom of the body. Not jagged,
  not loose.
- App icons are generic hints of real projects, chosen because their logos are
  already mostly geometric: Ubuntu, Kubernetes, Fedora, Alpine, Redis, Arch,
  NGINX, Prometheus, MongoDB, and Nextcloud. They are simplified shapes in
  each project's colours, not the official artwork.

## What works

- **Outline.** `trace.py` traces the original's alpha channel, fills the small
  notches between edge containers, and fits smooth cubic Béziers within 1.5px
  of the edge, with the leaf tips and the body's top and bottom dips kept
  crisp. `overlay.svg` draws the result over the original; it matches.
- **Palette.** Sampled from the original: light grey `#cbd2d9`, dark grey
  `#5c6570`, coral `#f6574c`, sky blue `#2092f5`, and app-container white
  `#edf1f4`, in roughly the original's proportions (light grey most, then dark
  grey, coral, blue).
- **Structure.** Seven rows of containers in three widths (narrow door ends with
  lock bars, medium, and wide sides with ribs), app containers roughly square,
  and a leaf in four container panels like the original's.

## What does not work yet

- **It looks flat and mechanical.** The original's charm is its illustration:
  containers bulge with the apple's curve, have bevels, bolts, and highlights,
  and catch light. The SVG is evenly spaced flat rectangles clipped by the
  outline, which reads as a pattern rather than an object.
- **Edge containers are sliced, not shaped.** In the original, containers at
  the edge curve and shrink with the surface. Here the outline just cuts them.
- **App glyphs are rough.** Some read well (NGINX, Kubernetes, Redis, Arch);
  others are weak at small sizes.
- **Small sizes.** `apple-small.svg` drops the ribs and glyphs so it survives
  at 16 to 32px, but it has not been reviewed as a favicon.

Directions worth trying next: per-container gradients and a highlight edge for
depth; scaling and skewing containers toward the edge so the wall wraps the
apple; or treating `outline.json` as a clipping mask in a vector tool and
illustrating the fill by hand.

## Approaches already rejected

- Simple geometric marks (a three-container stack, container doors, a row of
  containers), isometric containers, and a corrugated "c" lettermark: they lost
  the apple-of-apps concept.
- Hand-drawn apple outlines: never matched the original's shape.
- A literal copy of Apple's logo silhouette, with bite: closer to Apple's mark
  than the original icon, which is not the goal.
- The exact pixel trace without smoothing: tight, but jagged at the edge.

## Files

| File | Purpose |
| --- | --- |
| `trace.py` | Traces the original icon into `outline.json`. |
| `outline.json` | Body and leaf outlines as SVG path data, in the logo's coordinate space. |
| `build.py` | Fills the outline and writes the SVGs below. Edit rows, colours, and glyphs here. |
| `apple-wall.svg` | Detailed logo, for 64px and up. |
| `apple-small.svg` | Simplified logo, for 32px and below. |
| `overlay.svg` | The outline over the original icon, for checking the trace. |

The coordinate space maps original-icon pixels with `x' = 6 + (x - 180) * 88/890`
and `y' = 24 + (y - 338) * 88/890`; both scripts use it, and the SVG viewBox is
`2 -6 96 113`.

## Running

From the repository root. `trace.py` needs a few imaging libraries, which `uv`
supplies without installing them globally; `build.py` needs only Python.

```bash
uv run --with numpy --with scipy --with scikit-image --with pillow python3 design/logo/trace.py
python3 design/logo/build.py
python3 -m http.server --directory design/logo
```

Then open `apple-wall.svg` or `overlay.svg` from the local server. Rerun
`trace.py` only when the original icon changes.
