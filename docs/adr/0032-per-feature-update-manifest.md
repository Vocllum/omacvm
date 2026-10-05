# 0032: Updates: one signed manifest per release, digests per part

Status: accepted; tooling and checks built (round 1). Branch
`control-centre`. Shares the release key question with the app self-update;
until a key is in `src/lib/release-key.pub` the Bridge reports "no release
key yet" and offers nothing.

## Context

The control centre shows which features an update changes and installs only
what changed. Today `omacvm update` pulls main and reapplies everything; no
release says what changed per feature, and nothing is signed.

## Options

1. A hand-kept version number per feature in `features.tsv`. Gets forgotten.
2. Content digests per part, computed at release time, in one signed
   manifest per release.
3. Separate packages per feature (pacman repo). Much more machinery than the
   project needs.

## Decision

Option 2. Each release `v<version>` carries `omacvm-manifest.json` and an
Ed25519 signature `omacvm-manifest.json.sig` (public key in
`src/lib/release-key.pub`, checked with CryptoKit on the Mac before any field
is used). `parts` maps each feature (plus `core` and `app`) to a sha256
digest over its paths (`src/release/parts.tsv`; CI fails on a file in no
part or in two) and the release where that digest last changed. The manifest
pins the release commit; the Mac checks out that commit.

`omacvm apply` records the installed digests in the VM
(`/etc/omacvm/installed.json`). A part has an update when the digests
differ. An update is still one version for everything (consistent Mac and
VM); only changed parts are reinstalled or restarted.

The Mac checks weekly (one fetch for the Mac and all VMs), never when update
checks are off; that one setting is shared with the app self-update and
settable from the control centre.

## Consequences

- No version bumps by hand; the per-feature "2.8.0 → 2.9.1" comes from the
  digests.
- Release scripts gain a manifest step and need the private key: who holds
  it (the user's Mac or a CI secret) is the user's call.
- Tests use `OMACVM_FEED_URL` and `OMACVM_FEED_KEY` (a test key) in the
  Bridge's environment.
- Round 1 installs an update as one `omacvm update` (Mac and that VM); the
  list shows only the changed parts, and parts that did not change are left
  as they are where the installers already keep stamps (the Mac apps,
  Omanotch). Restarting only what changed everywhere is a follow-up.
- Still to wire: the release step that runs `manifest.py build` against the
  previous release's manifest, signs it and attaches both files.
