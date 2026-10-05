# 0033: OmacVM.app updates itself (own updater, signed feed, rollback)

Status: accepted, built and tested end to end (branch `app-self-update`).
Live from the first release that carries `src/lib/release-key.pub`: who
holds the private key is the user's decision (needs-user, shared with
[0032](0032-per-feature-update-manifest.md)).

## Context

People who use only OmacVM.app never open a terminal, so `omacvm update`
does not reach them. The app should update itself, on by default, checking
once a week, with one switch that silences it completely (no checks, no
messages), shared with the control centre in Omarchy. It must never break a
working install:

- only OmacVM's own builds: a signed feed, a checksum, OmacVM's Developer ID
  (team 722686Y34B) on the new app;
- never replace the bundle while a VM's QEMU runs from it (STANDARDS 20);
- if the new version does not start, the old one comes back by itself; the
  previous version stays for one step back.

Things that shape the choice: the app is built with SwiftPM and scripts (no
Xcode project); people install it under a name they pick, and a renamed
copy is signed again ad hoc (`Installer`, `omacvm update`); the VM's QEMU
lives inside the bundle; releases are not notarized yet.

## Options

1. **Sparkle 2.** The standard, well reviewed, with its UI and delta
   updates. Here: a framework with XPC services to embed and sign in a
   bundle assembled by a script. It checks the new app against the
   *installed* app's signature, which for a renamed ad hoc copy is just the
   bundle id; there is no hook to check the unpacked app against our team
   before it is installed. A renamed copy would get the release's name
   back. No rollback. Its settings are its own defaults, not the shared
   switch. About half of what follows would be ours anyway.
2. **A small updater of our own on Sparkle's model**: signed feed, download,
   verify, swap by a helper after the app quits; plus what OmacVM needs.
   About 600 lines of Swift and 130 of bash, no dependency, unit tests
   without Xcode.
3. **Only `omacvm update`** (exists): needs a terminal; no weekly check.

## Decision

Option 2.

**Feed.** Each GitHub release gets `OmacVM-appcast.json` (version, zip URL,
length, SHA-256, minimum macOS, notes URL) and `OmacVM-appcast.json.sig`
(Ed25519 over the exact bytes, base64), made by `app/scripts/appcast.sh`
from `package-release.sh`. The app fetches both from
`releases/latest/download/` and checks the signature with CryptoKit against
`src/lib/release-key.pub` inside its signed bundle before it reads a field.
Fields are strict (types, version form, 64 hex, https or a test feed on
127.0.0.1); feed 64 KB and zip 2 GB at most. Only a version newer than the
running one is offered, so an old signed feed cannot downgrade.

**When.** 20 s after launch and hourly while the app runs, a check is made
when the last one is a week old (or in the future: the clock went back),
never while `update_checks` is false in
`~/Library/Application Support/omacvm/settings.json` (the control centre's
file). Automatic checks stay off metered and Low Data networks. "Check for
Updates…" in the app menu always works. A server answer, even a 404, starts
the week again, so there is no hourly retry while no release has a feed.

**Download and checks.** The zip goes to
`~/Library/Application Support/OmacVM/Updates/<bundle id>/staged/`: size and
SHA-256 from the feed, then unpacked: exactly one app, our bundle id, the
version the feed named, `codesign --verify --deep --strict` with OmacVM's
Developer ID requirement on the app and on its QEMU (the part with the
Hypervisor entitlement), all with Security.framework. Anything off: deleted,
logged, nothing offered.

**Offer.** The window shows "OmacVM X is ready to install" with What's New,
Skip This Version and Update and Relaunch. With checks off nothing is shown.
While a VM runs the launcher has no window: the offer waits for the next
time the window opens. An update asked for while a VM runs or is being
built (`--update-now`, a script or later the control centre) waits and goes
in when the VM has shut down.

**Swap and rollback.** `update-swap.sh` runs from a copy outside the bundle
(bash reads scripts as it runs). It waits for the app to quit, refuses while
any process runs from inside the bundle, moves the app to `previous/` and the
new one into its place (renames on one volume), and starts it with
`--update-check TOKEN`. The new app starts its QEMU with `--version` (that
loads every library) and writes `launch-TOKEN`: "ok", or "fail" and exits.
Without "ok" within 60 s the script stops whatever runs from the bundle, puts
the old app back, and the old app skips that version. The version kept from
before stays aside until the new one has started. `previous/` gives one step
back (app menu: Go Back to X), with the same script and checks. A copy
installed under its own name keeps it: the new app gets the name and is
signed again ad hoc, as the installer does (checked before that, as
downloaded).

**Notarization** is not available yet. The app downloads with URLSession,
which sets no quarantine flag, so Gatekeeper does not assess the new app at
its first start (as with `omacvm update`'s curl). The trust comes from two
independent keys: the release key signs the feed, the Developer ID signs the
app. A stolen release key alone cannot ship code, a stolen Developer ID alone
cannot get into the feed. Once releases are notarized, a stapled-ticket check
becomes required from the version that adds it: a constant in the app, never
a field in the feed.

**Release key** (proposal for both feeds, needs-user): one Ed25519 key for the
app feed and the control centre's manifest. The private half only on the
user's Mac, in the login Keychain (`org.omacvm.release-key`), plus one offline
backup; the release step signs locally, where the Developer ID already lives.
Not a GitHub Actions secret: anyone who can change a workflow could then sign
a manifest that makes Macs check out another commit (0032), where the release
key is the only guard. Rotation: the release that brings a new public key is
signed with the old one. A lost key means one manual update for everyone.

**Release channel.** A release is published as a pre-release first and its
zip tried by hand; installed apps see it only once it is marked latest.
Release builds ignore `OMACVM_APPCAST_URL` (see test hooks below), so the
update path itself is tested with test builds.

## Consequences

- The app updates only itself. Existing VMs keep their VM side until
  `omacvm update` or the control centre installs it; Mac helpers likewise.
  New VMs get the new app's copy.
- `omacvm update` still replaces the app when it is closed (same checks, no
  rollback). Both paths keep working side by side.
- Test hooks: `OMACVM_APPCAST_URL`, `OMACVM_APPCAST_KEY` (a test key),
  `OMACVM_SETTINGS_DIR`, `OMACVM_COCOA_HIDDEN`; `build-app.sh --id` makes test
  builds that share nothing with an installed OmacVM. Only test builds read
  the first three: a build with the release id `org.omacvm.app` ignores them
  and `update-swap.sh` does not pass them on to it. Otherwise a process that
  can `launchctl setenv` could point the app at its own feed, and every local
  build is signed with the same Developer ID as a release.
- Tests: `swift run update-tests` (CI) and `app/scripts/dev/self-update-test.sh`
  (this Mac: weekly schedule, switch off, held back while a VM runs and
  applied after, rollback of two broken builds, one step back, a renamed
  copy).
- Not covered: delta updates (a full zip, about 13 MB, at most once a week),
  an install that needs an administrator (the app only updates where it can
  write, as it installs itself), copies run from a translocated or read-only
  place (it says so).
