# VoxChord App Store Connect metadata

This tool is intentionally limited to App **6829771739**, bundle ID
`art.malette.imic.app`, and the first iOS release **1.4.9**. It reads the bilingual
copy directly from `docs/appstore/listing.md`, review notes from `review.md`, and
six numbered PNGs per locale from `docs/appstore/screenshots/`.

Requirements: macOS, Xcode command-line tools/CryptoKit, Python 3.9+ (standard
library only), and the owner's individual ASC key at the path specified in the
task. No package installation is needed. Run from any directory:

```sh
python3 tools/asc/metadata.py --dry-run
python3 tools/asc/metadata.py --apply
python3 tools/asc/metadata.py --dry-run
python3 tools/asc/metadata.py --verify --json-report docs/appstore/asc-report/verification.json
python3 -m unittest discover -s tools/asc -p 'test_*.py'
```

`--dry-run` and `--verify` issue only GET requests to ASC. Dry-run prints every
field's current and desired value; strings longer than 40 characters are
abbreviated with their full length. Verify fails if any applicable field differs,
if an asset's MD5/order/status differs, or if either language lacks six screenshots.
There is no arbitrary App ID, credential path, endpoint, or payload CLI option.
Do not use Python optimization (`-O` / `PYTHONOPTIMIZE`); the tool refuses it so
that assertions protecting writes cannot be disabled.

`request.swift` compiles into a fresh private temporary directory each run. It
loads the private key only inside the credential process, creates a ten-minute
ES256 JWT with `sub=user`, `aud=appstoreconnect-v1` and **no issuer**, then performs
the HTTPS request. The Python process receives response data only; neither the
key nor JWT leaves the credential process or appears in logs. Redirects are
refused. The credential process never interpolates signing errors into output.
Do not invoke the helper directly or enable network/header debug logging.

Every mutation is checked against an endpoint allowlist and a graph of resources
read under the fixed App. The script re-reads the App and verifies its bundle ID
immediately before each API write and screenshot storage PUT. It has no DELETE
operation, submission operation, or account/provisioning/TestFlight management
operation. Unknown Apple errors stop the run, including agreements or decisions
requiring the owner. Only name collisions (the documented alternatives) and
first-release rejection of `whatsNew` have narrow recovery paths. The latter is
recorded, with Apple's error, in `docs/appstore/asc-report/exceptions.json` so
subsequent runs report the skip consistently. Review notes always use
`API key for review: <TO BE ADDED BY OWNER>`.

Requests have timeouts, with at most four attempts and exponential backoff for
429/5xx. Other HTTP errors stop immediately, printing Apple's code/title/detail.
Before replaying a POST after a server error, the script reads the parent to
recover an already-created matching resource. Ambiguous transport failures stop
instead of replaying a write; run dry-run to reconcile before resuming. Each
localization/version/set uses its existing resource. Screenshots reuse the same
filename and verify its MD5, resume unfinished uploads, and never replace unknown
assets. A mismatching checksum or duplicate filename stops without deleting data.

The script reuses an editable iOS version, updating its version string to `VERSION`,
and selects the latest processed, unexpired, App Store eligible matching iOS
build. No build is uploaded. An absent price plan is initialized at USD 0 in USA;
an existing non-free plan stops instead of being replaced. All manual and
automatic price points are read back. Availability enables every returned
territory except CHN, and automatic inclusion of new territories. Screenshots use
Apple's current API enum `APP_IPHONE_67` for its 6.9-inch slot (1320×2868).

The owner still completes App Privacy, review service key, demo video and actual
submission on the website. The notes are preserved exactly from the requested
source, including its sentence referring to an attached demo video; attach the
video before submitting. Export compliance is read from the selected build and
is not changed by this tool.

API references consulted (Apple OpenAPI 4.6.1):

- [API / OpenAPI download](https://developer.apple.com/app-store-connect/api/)
- [Individual-key JWT](https://developer.apple.com/documentation/appstoreconnectapi/generating-tokens-for-api-requests)
- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
- [App availability](https://developer.apple.com/documentation/appstoreconnectapi/appavailabilityv2)
