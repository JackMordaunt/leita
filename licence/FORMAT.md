# leita licence line, format 2

This is the contract for a licence line the activation server mints and the
app verifies offline. It is byte-exact on purpose: two implementations that
follow it produce and accept the same line. The worked vectors at the end
were signed with the throwaway key in `licence/testdata/throwaway/`. That key
is a test fixture. It is not the release key, and a release build does not
embed it.

The server mints format 2 only. The app still verifies format 1 lines that
were already issued; see "Format 1" below. An invalid, tampered, or
unverified line grants no Pro. Free use and records already on disk stay
available. Nothing in this file revokes a line that already verified.

## Line

A format 2 line is one line of ASCII:

```
leita2.<payload-b64>.<sig-b64>
```

`leita2.` is the format prefix, seven bytes, including the dot. Exactly one
more dot follows, the separator before the signature. The payload and the
signature are standard base64 (below) and neither alphabet contains `.`, so
a line contains exactly two dots.

The signature is computed over the bytes of `leita2.<payload-b64>`: everything
before the second dot, and not over the raw payload. Those bytes are the
signed message.

A verifier ignores leading and trailing Unicode whitespace, the same set Go's
`strings.TrimSpace` and Odin's `strings.trim_space` remove. A file on disk is
the line plus one LF. Whitespace inside the trimmed line is malformed. The
trimmed line is what gets split and verified.

## Canonical payload

The payload is UTF-8 JSON with no BOM, no insignificant whitespace, and the
seven keys in this order, each exactly once:

```
{"v":2,"id":"<id>","email":"<email>","scope":"<scope>","features":"<features>","paidThrough":"<paidThrough>","issued":"<issued>"}
```

`v` is the JSON number `2`: one byte, `0x32`, no sign, no fraction, no
exponent. Every other value is a JSON string. The characters allowed in those
strings cannot be `"` or `\`, so a canonical string is `"`, then the raw
bytes, then `"`. No `\u` escapes, no escaped solidus, no extra spaces around
`:` or `,`.

A verifier that parses JSON and then accepts the values is not enough. Decode
the payload and require the decoded bytes to equal the canonical encoding of
the fields, rebuilt in the form above. Key order, whitespace, escapes,
duplicate keys, and extra keys all fail that comparison. The signature can be
valid over a non-canonical payload; the verifier still rejects it.

## Fields

| Key | JSON type | Meaning |
| --- | --- | --- |
| `v` | number `2` | Format version inside the payload. A prefix of `leita2.` with any other `v` is rejected. |
| `id` | string | Licence id. 1 to 64 bytes from `A-Za-z0-9_-`. Opaque, stable, chosen by the server. Not a Polar product id. |
| `email` | string | Licensee email, as the buyer wrote it. No case folding, no Unicode normalisation. 3 to 254 bytes. Each byte is printable ASCII `0x21`–`0x7E` except `"` (`0x22`) and `\` (`0x5C`). Exactly one `@`, and it is neither the first nor the last byte. |
| `scope` | string | Permitted use. Exactly one of `personal`, `professional`, `organisation`. The spelling is `organisation`. |
| `features` | string | Feature set id. Format 2 defines one id, `pro`: tracking, automation, and Pro report workflows. Any other value is rejected. Scope does not change the feature set. |
| `paidThrough` | string | Paid-through instant. The canonical UTC profile below. |
| `issued` | string | Instant the line was signed. The same profile. |

The canonical instant profile is a 20-byte subset of RFC 3339:

```
YYYY-MM-DDTHH:MM:SSZ
```

`T` and `Z` are uppercase. No fractional seconds, no lowercase `t` or `z`, no
numeric offset. Year is 2020 through 9999. Month, day, hour, minute, and
second are a real UTC civil time: hour `00`–`23`, minute and second `00`–`59`
(a leap second, second `60`, is rejected), and the day is valid for that
month, including 29 February only in a leap year.

`paidThrough` is the end of the paid annual term. A later settled term may
move it forward. It does not move backward. How the server derives it from
Polar is the server's contract; the line carries the instant only.

## Base64

RFC 4648 section 4, the standard alphabet `A-Za-z0-9+/`, with `=` padding so
the text length is a multiple of 4. No line breaks, no spaces, no URL-safe
alphabet (`-` and `_` are rejected).

Go: `base64.StdEncoding` (`EncodeToString` / `Strict` is not required for
padding, but the encoded text must round-trip and the length must be a
multiple of 4). Odin: `core:encoding/base64` with the default table.

The signature decodes to exactly 64 bytes. A payload that decodes to zero
bytes is rejected.

## Signature

Ed25519, RFC 8032. Pure Ed25519: no prehash, no context string. Not
Ed25519ph and not Ed25519ctx.

- Private key: the 32-byte seed. Go `ed25519.NewKeyFromSeed`. Not the
  64-byte expanded key, and not PKCS8 or PEM.
- Public key: 32 raw bytes. The release build takes it as 64 hex characters
  (`LEITA_LICENCE_KEY`), either case. The vectors below use lowercase hex.
- Signature: 64 raw bytes, then standard base64. Not ASN.1.

The signed message is the exact ASCII bytes of `leita2.` concatenated with
the payload's base64 text. Verify those bytes. Do not verify the decoded
JSON, and do not verify a buffer that still has the signature suffix.

## Verification

1. Trim leading and trailing Unicode whitespace.
2. Require the prefix `leita2.`. Another `leita<digit>.` prefix is a
   different format (format 1 is accepted by the app; anything else is an
   unknown format). A line that does not start with `leita` is malformed.
3. Split on the only remaining dot. Reject any other count.
4. Base64-decode the payload and the signature as above. The signature must
   be 64 bytes.
5. Verify Ed25519 over `leita2.<payload-b64>` with the build's public key.
   A bad signature stops here. The payload is not interpreted.
6. Require the decoded payload to be the canonical encoding, and each field
   to match the table. Failure here is a terms failure: signed, but not a
   grant this format accepts.

A line that fails any step grants no Pro. The app keeps Free and any records
already stored. A failed check does not delete a previously stored line of a
different build; that is the app's existing behaviour for a key mismatch.

## What Pro the line grants

The tier names a permitted use. All three scopes grant the same `pro` feature
set.

Compare instants, not local clocks, download dates, or the subscription's
current billing state. A release is Pro-eligible when its authenticated
release instant is less than or equal to `paidThrough`. Equal is eligible.
The release stays eligible offline after cancellation. A release whose
instant is later runs Free and still opens records. A build with no
authenticated release instant is not eligible under a format 2 line.

The release instant is the 20-byte profile, once, for that release:

- `released.txt` in the release directory is that instant plus one LF
  (`0x0A`), 21 bytes, no CR.
- `sha256sums.txt` lists it in GNU `sha256sum` form: 64 lowercase hex
  digits, two spaces, `released.txt`, LF. The hash is SHA-256 of the 21
  file bytes.
- When the release is signed, `sha256sums.txt.sig` is the 64-byte Ed25519
  signature of the exact bytes of `sha256sums.txt`. The timestamp is
  authenticated only when that signature verifies and the hash line matches
  `released.txt`. An unsigned or altered stamp does not make a release
  eligible.
- The same instant is compiled into that release as
  `-define:LEITA_RELEASED=<instant>`. Offline, the running build uses that
  embedded instant. It is the copy of `released.txt` from the release that
  built it.

Format 1 has no `paidThrough`. A format 1 line that verifies keeps the rights
it already had, on every build, with no cutoff.

## Format 1

Already issued lines stay valid. The server does not mint new ones.

```
leita1.<payload-b64>.<sig-b64>
```

The signed message is `leita1.<payload-b64>`, same splitting and Ed25519
rules as format 2. The payload is JSON, standard base64, but it is not
canonical: the signature covers whatever bytes the original issuer encoded,
and the verifier does not rebuild them. The object carries these strings:

| Key | Meaning |
| --- | --- |
| `licensee` | Who it was sold to, after trimming surrounding whitespace. Empty is rejected. |
| `tier` | Exactly one of `supporter`, `office`, `team`, `site`, `multi_site`. |
| `order` | The seller's order id. Empty is rejected. |
| `issued` | The day it was signed, kept as text. Historical lines use `YYYY-MM-DD`. |

No `paidThrough`, no feature set, no format version field. The prefix is the
version. Unknown tier names are rejected. A format 1 line does not become a
format 2 line and is not rewritten on activation.

## Activation

The app exchanges a licence key for a line. It sends nothing else about the
person or the machine, and it does not ask again once the line verifies and
is stored.

```
POST /leita/activate
```

The production URL is `https://mordaunt.dev/leita/activate`.
`LEITA_ACTIVATE_URL`, when set to a non-empty string, replaces that URL
entirely, including the path. It is how the sandbox is pointed at another
host. An explicit URL the app was given outranks the variable, and the
variable outranks the production URL.

Request headers:

```
Content-Type: application/json
Accept: application/json
User-Agent: leita/<version>
```

No cookies, no authorization header. The body is JSON, UTF-8. The app sends
this compact object and no other fields:

```
{"key":"<key>"}
```

The server accepts insignificant JSON whitespace. `key` is a string of 1 to
128 bytes with no ASCII whitespace (`0x20`, `0x09`, `0x0A`, `0x0D`). A missing
key, an empty key, a longer key, whitespace inside it, or a body that is not
a JSON object is `malformed`.

Response `Content-Type` is `application/json`. The body is at most 64 KiB.
The app waits 30 seconds.

Success, HTTP 200:

```
{"licence":"<line>"}
```

`<line>` is a format 2 line, JSON-string-escaped per RFC 8259. Format 2's
alphabet needs no escapes. The app verifies the line offline against the
public key it was built with. A 200 whose body is not this object, or whose
line does not verify, grants nothing.

The same key returns the same stored line. A line already issued is still
returned after cancellation or a refund: cancellation stops renewal, and a
refund does not remotely disable a copy. Neither deletes the line.

Errors, JSON:

```
{"error":"<code>","message":"<short english>"}
```

`message` may be omitted or empty. The app shows `message` when it is
non-empty, otherwise its own sentence. It shows at most the first line, cut
at 200 bytes.

| HTTP | `error` | When |
| --- | --- | --- |
| 400 | `malformed` | Body or key does not match the request rules. |
| 404 | `unknown` | No line is stored for this key. |
| 409 | `unsettled` | The key is known and the order is not a settled paid order, so no line exists yet. |
| 423 | `held` | A paid order would change the permitted-use scope of an existing licence and is waiting for a decision. No line is minted for it. |
| 500 | `unavailable` | The store or the signing key failed. The client may retry. |

Any other status, or a body that is not JSON, grants nothing. The app does
not mint a line itself.

## Test vectors

Throwaway seed (32 bytes, hex):

```
d7fa090966bc4a00debc5365a7c9912d550e45d14137e277a2a421e13922d2a8
```

Throwaway public key (32 bytes, hex):

```
4f70cb9a239d6203d71e4cd11c877128157b8673ed90a20c82569f7344f12182
```

Both files, plus the payload and line bytes, are under
`licence/testdata/throwaway/`. The seed file and the public file have one
trailing LF. The payload files have none. The line files have one trailing LF.

### Vector 1

Payload, 160 bytes:

```
{"v":2,"id":"lic_7f3a9c2e1b","email":"ada@example.com","scope":"personal","features":"pro","paidThrough":"2027-10-19T00:00:00Z","issued":"2026-10-19T12:00:00Z"}
```

Payload base64:

```
eyJ2IjoyLCJpZCI6ImxpY183ZjNhOWMyZTFiIiwiZW1haWwiOiJhZGFAZXhhbXBsZS5jb20iLCJzY29wZSI6InBlcnNvbmFsIiwiZmVhdHVyZXMiOiJwcm8iLCJwYWlkVGhyb3VnaCI6IjIwMjctMTAtMTlUMDA6MDA6MDBaIiwiaXNzdWVkIjoiMjAyNi0xMC0xOVQxMjowMDowMFoifQ==
```

Signature, 64 bytes, hex:

```
54337fdfce114b44fcbd11b508611cfd829080679e3a3e808c769187edd6465e13fb620eb4ff6c40c09f75f25d7b0d7fe0bdbd1ebaf0e138a2a03d8e11e8bd09
```

Line:

```
leita2.eyJ2IjoyLCJpZCI6ImxpY183ZjNhOWMyZTFiIiwiZW1haWwiOiJhZGFAZXhhbXBsZS5jb20iLCJzY29wZSI6InBlcnNvbmFsIiwiZmVhdHVyZXMiOiJwcm8iLCJwYWlkVGhyb3VnaCI6IjIwMjctMTAtMTlUMDA6MDA6MDBaIiwiaXNzdWVkIjoiMjAyNi0xMC0xOVQxMjowMDowMFoifQ==.VDN/384RS0T8vRG1CGEc/YKQgGeeOj6AjHaRh+3WRl4T+2IOtP9sQMCfdfJdew1/4L29Hrrw4TiioD2OEei9CQ==
```

`paidThrough` is `2027-10-19T00:00:00Z`. A release stamped at that instant is
eligible. A release stamped `2027-10-19T00:00:01Z` is not.

### Vector 2

Payload, 168 bytes:

```
{"v":2,"id":"lic_org_4401","email":"ops@northwind.example","scope":"organisation","features":"pro","paidThrough":"2028-01-01T00:00:00Z","issued":"2027-01-01T00:00:00Z"}
```

Payload base64:

```
eyJ2IjoyLCJpZCI6ImxpY19vcmdfNDQwMSIsImVtYWlsIjoib3BzQG5vcnRod2luZC5leGFtcGxlIiwic2NvcGUiOiJvcmdhbmlzYXRpb24iLCJmZWF0dXJlcyI6InBybyIsInBhaWRUaHJvdWdoIjoiMjAyOC0wMS0wMVQwMDowMDowMFoiLCJpc3N1ZWQiOiIyMDI3LTAxLTAxVDAwOjAwOjAwWiJ9
```

Signature, 64 bytes, hex:

```
6c8cfd804dae96505dc7ca03231b7c59eecff49232371d21689e3a05a1d7748a010afe5033b25042c580be719b679cf9a0494b304223b7753a39bfb0e052340a
```

Line:

```
leita2.eyJ2IjoyLCJpZCI6ImxpY19vcmdfNDQwMSIsImVtYWlsIjoib3BzQG5vcnRod2luZC5leGFtcGxlIiwic2NvcGUiOiJvcmdhbmlzYXRpb24iLCJmZWF0dXJlcyI6InBybyIsInBhaWRUaHJvdWdoIjoiMjAyOC0wMS0wMVQwMDowMDowMFoiLCJpc3N1ZWQiOiIyMDI3LTAxLTAxVDAwOjAwOjAwWiJ9.bIz9gE2ullBdx8oDIxt8We7P9JIyNx0haJ46BaHXdIoBCv5QM7JQQsWAvnGbZ5z5oElLMEIjt3U6Ob+w4FI0Cg==
```

`scope` is `organisation`. The same encoding with `scope` set to
`professional`, and a new signature over the new payload, is the professional
line. Vector 2 is not that line.
