# branding

estoile's mark and the hero lockup, each in a light and a dark version.
`just branding` regenerates them from `tools/logo`, which draws the mark from
the same geometry the window does (`gui/mark`).

| file | what it is |
|------|------------|
| `mark-{light,dark}.{svg,png}` | the star of cells mark alone, transparent, 1024 px PNG |
| `hero-{light,dark}.{svg,png}` | mark and the estoile wordmark, for the README |

Ink is `#1c1b1a` on light, `#f0eee8` on dark; the lit cell is sea, `#0e7490`,
in both. The wordmark is JetBrains Mono Bold, named rather than embedded, so a
renderer without it falls back to its own monospace.
