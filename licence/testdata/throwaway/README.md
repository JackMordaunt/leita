# Throwaway Ed25519 key — test only

This key is not a release key and must never be passed as `LEITA_LICENCE_KEY`.
The seed is published on purpose so another implementation can reproduce the
vectors in `licence/FORMAT.md`. A release build refuses the justfile's separate
test key; it has no business trusting this one either.

- `ed25519.seed.hex` — 32-byte RFC 8032 seed, lowercase hex, one trailing LF.
- `ed25519.public.hex` — the matching 32-byte public key, same encoding.
- `vector-1.payload`, `vector-2.payload` — the canonical payload bytes, no trailing LF.
- `vector-1.line`, `vector-2.line` — the whole licence line, one trailing LF.
