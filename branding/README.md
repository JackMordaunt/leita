# branding

leita's mark and the hero lockup, each in a light and a dark version, exported
from the logo tool, which keeps the candidates the found cell was chosen from.
The window draws the same mark from `gui/mark`.

| file | what it is |
|------|------------|
| `mark-{light,dark}.{svg,png}` | the found cell alone: the sunburst with the find lit, transparent, 1024 px PNG |
| `hero-{light,dark}.{svg,png}` | mark and the leita wordmark, for the README |

Ink is `#1c1b1a` on light, `#f0eee8` on dark; the find is sea, `#0e7490`, in
both. The wordmark is JetBrains Mono Bold, named rather than embedded, so a
renderer without it falls back to its own monospace.
