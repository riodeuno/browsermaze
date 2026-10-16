# How browsermaze works

This page explains the parts inside the pool. You do not need it to install or use browsermaze; see the [README](../README.md) for that.

## What `setup.sh` installs on the pool

It installs Chrome stable from Google's apt repository, Xvfb, x11vnc, ffmpeg, socat, rsync and python3-websockets; the `browser` service account; `/srv/browsers`; the `browsermaze` command, the pool program behind it, and the systemd units; the caller login with the `sudo` rule that lets it run the pool program, `/usr/local/lib/browsermaze/browsermaze-pool`, as root and nothing else; and the config file. Then it leases a slot, fetches `http://<address>:<port>/json/version` and releases the slot. Each step prints `installed`, `unchanged` or `FAILED`. The last output is a checklist with a `fix:` line for each failure, and the exit status is non-zero when anything failed. Running it again changes nothing that is already in place. It needs an SSH server on the machine for agents and your Mac or Linux desktop to log in.

The order of precedence for an answer is flag, environment variable, the answer saved in the config file, a question on a terminal, the default.

## Slots, leases and the golden profile

- **The golden profile** is one Chrome user-data folder, `/srv/browsers/golden`. The import writes cookies and site storage into it through CDP. A Mac profile folder cannot be copied instead: macOS Chrome encrypts cookies with a Keychain key the pool never has.
- **A slot** is one Chrome on its own virtual display `:N` at 1920×1080, with a window rather than headless, so ffmpeg can record what it draws. `lease` copies the golden folder into the slot first. Chrome serves CDP on `127.0.0.1:920N` only, and `socat` forwards `POOL_BIND:930N` to it.
- **A lease** is a lock file per slot. `lease` takes the first free slot. A lease older than 2 hours counts as free, because an agent that crashes never releases its slot.
- **Logins that expire** die with the slot and never reach the golden profile. Log in again through `browsermaze`.

## Logging in on the pool through VNC

The import cannot carry tokens kept in IndexedDB, or sessions a service binds to one device or IP address. For a service that rejects imported logins, log in on the pool through VNC. The VNC server listens on the pool's loopback address only:

```
ssh -L 5900:127.0.0.1:5900 alice@192.0.2.7 browsermaze golden start
open vnc://localhost:5900
```

The password is in `/srv/browsers/vnc-password.txt`, readable by root. Run `browsermaze golden stop` when done. Chrome locks the golden profile while it runs, so `lease` refuses until it stops.

## Config files

The pool reads `/etc/browsermaze/config`, which `setup.sh` writes. The pool program and the systemd units read it. To change a value, run `setup.sh` again with the matching flag.

| Key | Meaning |
|---|---|
| `POOL_BIND` | The address the CDP ports listen on. `browsermaze lease` prints it |
| `POOL_SLOTS` | The number of slots |
| `POOL_CALLER` | The login that leases slots |

`browsermaze login` on your Mac or Linux desktop reads `~/.config/browsermaze/config` (or the path in `BROWSERMAZE_CONFIG`). It holds `POOL_SSH` and, when set, `POOL_SSH_KEY`.

## Versions

`VERSION` holds the version. `setup.sh --version` and `browsermaze version` print it. On the pool, `browsermaze` is a copy that `setup.sh` installed in `/usr/local/lib/browsermaze`, so it shows what is installed even after the checkout moves on. Releases are git tags `v<VERSION>`, and `CHANGELOG.md` lists the changes.

## Test

`./test_setup.sh` checks the syntax of the shell files, the answers `setup.sh` accepts, the role flag, the Chrome lookup, the config file, and the whole login role against a throwaway home folder. The Linux role installs system files, so run it in a VM.
