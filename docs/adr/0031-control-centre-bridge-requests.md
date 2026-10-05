# 0031: Mac-side actions from the VM: a fixed list of Bridge requests

Status: accepted, built (round 1). Branch `control-centre`. Needs a
security review before merge.

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
  The guest never names a VM.
- Strict JSON (≤ 4 KB, unknown keys rejected); feature names must be in the
  Mac's own `features.tsv`.
- The CLI runs by posix_spawn with a fixed argv, no shell; its path comes
  from a file `src/mac/install.sh` writes, checked for owner and mode.
- One job per VM, 20 per hour; every request logged.
- Toggles only when the Mac's and the VM's OmacVM versions match; otherwise
  the only action is `update`, which installs the version the Mac fetched
  and verified itself (ADR 0032), never one the guest names.
- Every job runs `omacvm apply --transaction`: on failure the saved feature
  set is applied again and the job ends `rolled-back`.
- Protocol number in `hello` and the `X-OmacVM-Proto` header; an older Mac
  (404) makes the control centre read-only with the command to update the
  Mac.
- OmacVM.app's VMs use a virtio-serial port, `org.omacvm.control`, with the
  same JSON; the Bridge keeps refusing 127.0.0.1.

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
- Identity is the VM's address on its network. A guest that takes another
  VM's address could ask in that VM's name; the Bridge only maps an address
  whose remembered SSH host key answered there in the last minute, and every
  job reaches the VM over SSH with that key, so it acts only on the real VM.
  Per-VM tokens would close this fully: a follow-up.
- From 127.0.0.1 and the Mac's own addresses only `hello` is answered (Mac
  programs, and OmacVM.app's VMs until the app's control port).
