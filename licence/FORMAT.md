# leita licence line

This is the contract for a licence line the activation server mints and the
app verifies offline. It is byte-exact on purpose: two implementations that
follow it produce and accept the same line. The worked vectors at the end
were signed with the throwaway key in `licence/testdata/throwaway/`. That key
is a test fixture. It is not the release key, and a release build does not
embed it.

There is one line format. The prefix is `leita.` and the format version lives
in the payload as `v`. Draft prefixes `leita1.` and `leita2.` were never
issued to a customer. A verifier rejects them. An invalid, tampered, or
unverified line grants no Pro. Free use and records already on disk stay
available. Nothing in this file revokes a line that already verified.

## Line

A line is one line of ASCII:

```
leita.<payload-b64>.<sig-b64>
```

`leita.` is the format prefix, six bytes, including the dot. Exactly one
more dot follows, the separator before the signature. The payload and the
signature are standard base64 (below) and neither alphabet contains `.`, so
a line contains exactly two dots.

The signature is computed over the bytes of `leita.<payload-b64>`: everything
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
{"v":1,"id":"<id>","email":"<email>","scope":"<scope>","features":"<features>","paidThrough":"<paidThrough>","issued":"<issued>"}
```

`v` is the JSON number `1`: one byte, `0x31`, no sign, no fraction, no
exponent. Every other value is a JSON string. The characters allowed in those
strings cannot be `"` or `\`, so a canonical string is `"`, then the raw
bytes, then `"`. No `\u` escapes, no escaped solidus, no extra spaces around
`:` or `,`.

A verifier that parses JSON and then accepts the values is not enough. Decode
the payload and require the decoded bytes to equal the canonical encoding of
the fields, rebuilt in the form above. Key order, whitespace, escapes,
duplicate keys, and extra keys all fail that comparison. The signature can be
valid over a non-canonical payload; the verifier still rejects it. A payload
whose `v` is not `1` is rejected the same way. A later incompatible change
uses a higher `v`, which this verifier does not accept.

## Fields

| Key | JSON type | Meaning |
| --- | --- | --- |
| `v` | number `1` | Format version inside the payload. Any other value is rejected. |
| `id` | string | Licence id. 1 to 64 bytes from `A-Za-z0-9_-`. Opaque, stable, chosen by the server. Not a Polar product id. |
| `email` | string | Licensee email, as the buyer wrote it. No case folding, no Unicode normalisation. 3 to 254 bytes. Each byte is printable ASCII `0x21`–`0x7E` except `"` (`0x22`) and `\` (`0x5C`). Exactly one `@`, and it is neither the first nor the last byte. |
| `scope` | string | Permitted use. Exactly one of `personal`, `professional`, `organisation`. The spelling is `organisation`. |
| `features` | string | Feature set id. This format defines one id, `pro`: tracking, automation, and Pro report workflows. Any other value is rejected. Scope does not change the feature set. |
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

`paidThrough` is the end of the paid annual term the server will serve for
this key. A later settled term may move it forward. A full refund can move
that served instant earlier. A partial refund does not withdraw the line and
does not move the instant. How the server derives it from Polar is the
server's contract; the line carries the instant only. A line already on disk
stays valid offline until a later activation replaces it.

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
- Public key: 32 raw bytes. A build trusts one or more, compiled in as
  `LEITA_LICENCE_KEY`: 64 hex characters, either case, or several of those
  separated by commas. Spaces around a comma are ignored. An empty set, a
  blank entry, or a token that is not 64 hex characters is malformed, and a
  release build refuses it. There is no environment variable that replaces
  the set at run time. A line is valid when any trusted key verifies it.
  The vectors below use one lowercase key.
- Signature: 64 raw bytes, then standard base64. Not ASN.1.

The signed message is the exact ASCII bytes of `leita.` concatenated with
the payload's base64 text. Verify those bytes. Do not verify the decoded
JSON, and do not verify a buffer that still has the signature suffix.

A release build embeds the production public key set only. Sandbox lines are
signed with a different key, so they fail in a release build. A development
build compiled with the sandbox public key accepts them.
`LEITA_ACTIVATE_URL` for that build is
`https://mordaunt.dev/leita/sandbox/activate`.

## Verification

1. Trim leading and trailing Unicode whitespace.
2. Require the prefix `leita.`. Any other prefix that starts with `leita`
   and contains a dot (`leita1.`, `leita2.`, a later `leita<digit>.`) is an
   unknown format. A line that does not start with `leita` is malformed.
3. Split on the only remaining dot. Reject any other count.
4. Base64-decode the payload and the signature as above. The signature must
   be 64 bytes.
5. Verify Ed25519 over `leita.<payload-b64>` with each public key the build
   trusts, until one holds. A bad signature on every key stops here. The
   payload is not interpreted.
6. Require the decoded payload to be the canonical encoding, and each field
   to match the table. Failure here is a terms failure: signed, but not a
   grant this format accepts.

A line that fails any step grants no Pro. The app keeps Free and any records
already stored. A failed check does not delete a previously stored line of a
different build; that is the app's existing behaviour for a key mismatch.

## What Pro the line grants

The scope names a permitted use. All three scopes grant the same `pro`
feature set.

Compare instants, not local clocks, download dates, or the subscription's
current billing state. A release is Pro-eligible when its authenticated
release instant is less than or equal to `paidThrough`. Equal is eligible.
The release stays eligible offline after cancellation. A full refund can
make the server serve an earlier instant, or no line; the copy already on
disk is unchanged until activation replaces it, and it stays eligible
offline for a release at or before the instant it carries. A release whose
instant is later runs Free and still opens records. A build with no
authenticated release instant is not eligible.

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

## Activation

The app exchanges a licence key for a line. It sends nothing else about the
person or the machine. It does not ask again while the stored line verifies.
When the stored line does not verify and the receipt key was kept beside it,
it exchanges that key once.

```
POST /leita/activate
```

The production URL is `https://mordaunt.dev/leita/activate`.
`LEITA_ACTIVATE_URL`, when set to a non-empty string, replaces that URL
entirely, including the path. The sandbox URL is
`https://mordaunt.dev/leita/sandbox/activate`. An explicit URL the app was
given outranks the variable, and the variable outranks the production URL.

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

`<line>` is a licence line, JSON-string-escaped per RFC 8259. This format's
alphabet needs no escapes. The app verifies the line offline against the
public keys it was built with. A 200 whose body is not this object, or whose
line does not verify, grants nothing.

Cancellation stops renewal. The server still returns the line already
issued. A full refund can move the served `paidThrough` earlier; activation
returns that line, or 404 when no line remains for the key. A partial refund
does not withdraw the line. A line already on disk stays valid offline. The
server does not disable it.

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

## Key rotation

The server signs with one current seed. A build trusts a set, so a line an
older key in that set signed still verifies. Planned rotation:

1. Mint the next seed and leave the current one signing.
2. Ship a build whose `LEITA_LICENCE_KEY` is the current public key and the
   next one, comma-separated. Release that build before the server changes.
3. Switch the server to the next seed. It re-signs stored lines. Keep the
   old public key in later builds, so a line already on a machine keeps
   verifying. After the switch, activation returns a line the new key signed.

The app stores the licence key from the receipt beside the line, with the
line's file permissions. When a stored line fails verification and that key
is present, the app exchanges it once. A line that verifies replaces the
stored line. No network, or HTTP 404, leaves the copy Free and says so. The
previous line stays on disk.

To drop a compromised key, ship a build that omits it. In that build, old
lines fail verification and the app re-activates once, as above. A build
that still contains the key keeps trusting it. That limit is accepted.

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
{"v":1,"id":"lic_7f3a9c2e1b","email":"ada@example.com","scope":"personal","features":"pro","paidThrough":"2027-10-19T00:00:00Z","issued":"2026-10-19T12:00:00Z"}
```

Payload base64:

```
eyJ2IjoxLCJpZCI6ImxpY183ZjNhOWMyZTFiIiwiZW1haWwiOiJhZGFAZXhhbXBsZS5jb20iLCJzY29wZSI6InBlcnNvbmFsIiwiZmVhdHVyZXMiOiJwcm8iLCJwYWlkVGhyb3VnaCI6IjIwMjctMTAtMTlUMDA6MDA6MDBaIiwiaXNzdWVkIjoiMjAyNi0xMC0xOVQxMjowMDowMFoifQ==
```

Signature, 64 bytes, hex:

```
fceceee1c8f94636822903a9707a2fdce17b7031bfe9cd48bc4ec2f5888f7027d0cdc70a26f2f0f967666111ec43a23d832abfed0027de83e20be844169f360a
```

Line:

```
leita.eyJ2IjoxLCJpZCI6ImxpY183ZjNhOWMyZTFiIiwiZW1haWwiOiJhZGFAZXhhbXBsZS5jb20iLCJzY29wZSI6InBlcnNvbmFsIiwiZmVhdHVyZXMiOiJwcm8iLCJwYWlkVGhyb3VnaCI6IjIwMjctMTAtMTlUMDA6MDA6MDBaIiwiaXNzdWVkIjoiMjAyNi0xMC0xOVQxMjowMDowMFoifQ==./Ozu4cj5RjaCKQOpcHov3OF7cDG/6c1IvE7C9YiPcCfQzccKJvLw+WdmYRHsQ6I9gyq/7QAn3oPiC+hEFp82Cg==
```

`paidThrough` is `2027-10-19T00:00:00Z`. A release stamped at that instant is
eligible. A release stamped `2027-10-19T00:00:01Z` is not.

### Vector 2

Payload, 168 bytes:

```
{"v":1,"id":"lic_org_4401","email":"ops@northwind.example","scope":"organisation","features":"pro","paidThrough":"2028-01-01T00:00:00Z","issued":"2027-01-01T00:00:00Z"}
```

Payload base64:

```
eyJ2IjoxLCJpZCI6ImxpY19vcmdfNDQwMSIsImVtYWlsIjoib3BzQG5vcnRod2luZC5leGFtcGxlIiwic2NvcGUiOiJvcmdhbmlzYXRpb24iLCJmZWF0dXJlcyI6InBybyIsInBhaWRUaHJvdWdoIjoiMjAyOC0wMS0wMVQwMDowMDowMFoiLCJpc3N1ZWQiOiIyMDI3LTAxLTAxVDAwOjAwOjAwWiJ9
```

Signature, 64 bytes, hex:

```
fdd5c5d652f9d0d92bd35f9ab57f119be4f5a583d9e06af2be3bf3e644bb054b1e763126d8f02917f61e59f1ce544927c38302eb9161d92bf4bf08f934112308
```

Line:

```
leita.eyJ2IjoxLCJpZCI6ImxpY19vcmdfNDQwMSIsImVtYWlsIjoib3BzQG5vcnRod2luZC5leGFtcGxlIiwic2NvcGUiOiJvcmdhbmlzYXRpb24iLCJmZWF0dXJlcyI6InBybyIsInBhaWRUaHJvdWdoIjoiMjAyOC0wMS0wMVQwMDowMDowMFoiLCJpc3N1ZWQiOiIyMDI3LTAxLTAxVDAwOjAwOjAwWiJ9./dXF1lL50Nkr01+atX8Rm+T1pYPZ4Gryvjvz5kS7BUsedjEm2PApF/YeWfHOVEknw4MC65Fh2Sv0vwj5NBEjCA==
```

`scope` is `organisation`. The same encoding with `scope` set to
`professional`, and a new signature over the new payload, is the professional
line. Vector 2 is not that line.
