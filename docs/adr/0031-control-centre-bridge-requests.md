# 0031: Mac-side actions from the VM: a fixed list of Bridge requests

Status: accepted, built (rounds 1 and 2). Branch `control-centre`.

## Context

Switching a feature changes both sides: the Mac installs or stops helpers,
then installs into the VM over SSH (`omacvm apply`). From inside the VM the
control centre has to ask the Mac to do that. The guest is untrusted
(STANDARDS 4): whatever it sends must not let it run anything else on the Mac.

## Options

1. Give the guest a way to run `omacvm` on the Mac (SSH back to the Mac, a
   generic "run" request). Simple, and a hole: any guest process with the
   token runs commands on the Mac.
2. A fixed set of requests on the existing Bridge (token + proof as today),
   each mapped by the Mac to one fixed `omacvm` invocation for the VM the
   request came from.
3. Do everything on the Mac only; the VM shows state and the command to type.
   Safe, but not the "in Omarchy" control centre that was asked for.

## Decision

Option 2. Requests under `/omacvm/`: `hello`, `status`, `updates`,
`updates/check`, `settings/update-checks`, `jobs` (actions `enable`,
`disable`, `reinstall`, `update`) and `jobs/<id>`. Nothing else.

- The Mac decides which VM: the peer address must match exactly one running
  VM that OmacVM set up (pinned host key); otherwise 409 and nothing runs.
  The guest never names a VM. The request must also carry that VM's own key
  (`X-OmacVM-VM-Key`, made by `omacvm apply`, kept on the Mac in
  `omacvm/vm-keys/` and in the VM in `~/.config/omacvm-bridge/vm-key`): a
  VM that takes another VM's address cannot act for it. Everything except
  `hello` needs this, also the Mac-wide update settings.
- Strict JSON (≤ 4 KB, unknown keys rejected); feature names must be in the
  Mac's own `features.tsv`.
- The CLI runs by posix_spawn with a fixed argv, no shell; its path comes
  from a file `src/mac/install.sh` writes, checked for owner and mode.
- One job per VM, 20 per hour; every request logged.
- Toggles only when the Mac's and the VM's OmacVM versions match; otherwise
  the only action is `update`, which installs the version the Mac fetched
  and verified itself (ADR 0032), never one the guest names.
- Every job runs `omacvm apply --transaction`: the new OmacVM is unpacked
  beside the VM's old one and swapped in; on failure (also a part that would
  only be logged otherwise) the old one and the saved feature set come back,
  and apply ends with exit code 4, which the job shows as `rolled-back`
  (the exit code alone decides, never the output). `reinstall` repairs only
  the named features (`apply --reinstall F`). Progress comes as JSON lines
  (`OMACVM_PROGRESS=json`): step n of m.
- With update checks off, `update` installs only from a check made in the
  last hour (409 `stale-update`).
- Protocol number in `hello` and the `X-OmacVM-Proto` header; an older Mac
  (404) makes the control centre read-only with the command to update the
  Mac.
- OmacVM.app's VMs use a virtio-serial port, `org.omacvm.control`: one JSON
  line per request (`{"id", "method", "path", "body", "proto", "version"}`)
  and per answer (`{"id", "status", "body"}`). The app passes each request
  on to the Bridge on 127.0.0.1 with the relay key (`omacvm-bridge/relay-key`,
  never given to a VM) and the VM's name, which only the app knows. The
  Bridge applies the same list; without the relay key 127.0.0.1 still gets
  `hello` only (the app's guests reach the Mac from there too).

## Consequences

- A hostile guest can switch its own VM's features and trigger an update to
  a signed release. It cannot reach other VMs, pass arguments, pick a version
  or get a shell.
- macOS permission prompts still appear on the Mac.
- The Bridge app stays installed while control-centre is on, also with the
  bridge feature off (as for the camera).

## Found while building

- macOS's Local Network privacy counts a child of an app as the app: the
  CLI's ssh to the VM was refused when the Bridge ran it (every check failed
  on SSH). The Bridge spawns the CLI with its responsibility disclaimed
  (`responsibility_spawnattrs_setdisclaim`, looked up at run time; Terminal
  does the same for its shells), so the CLI answers for itself.
- A job can outlive the Bridge: an update reinstalls the Bridge, which stops
  it mid-job. Jobs run in their own session and write their output and exit
  code to `omacvm-bridge/jobs/`; a restarted Bridge reports them from there
  and still refuses a second job for that VM while one runs.
- Identity was the VM's address on its network alone in round 1: a guest
  that took another VM's address could ask in that VM's name. Round 2 adds
  the per-VM key above.
- From 127.0.0.1 and the Mac's own addresses only `hello` is answered,
  unless OmacVM.app relays it with the relay key.
