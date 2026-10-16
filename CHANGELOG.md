# Changelog

Changes to browsermaze, newest first. The current version lives in `VERSION`. A release is the git tag `v<VERSION>`.

## 0.4.0 — 2026-10-16
- First public release.
- `setup.sh` installs the browser pool on Ubuntu 24.04 or 26.04 (x86_64 or arm64) and the `browsermaze` command on your Mac or Linux desktop. `--role pool|login` (env `BROWSERMAZE_ROLE`) picks which; Linux defaults to the pool and macOS to the command. On Linux the command finds Chrome from `CHROME`, else `google-chrome`, `google-chrome-stable`, `chromium` or `chromium-browser` on PATH. It asks each question once, takes every answer from a flag or an environment variable, and ends with a checklist that names a fix for each failure.
- The CDP bind address, the slot count and the caller login live in one config file, `/etc/browsermaze/config`, which the pool program and the systemd units read.
- One command on every machine: `browsermaze <subcommand>`. `browsermaze login` runs on your desktop; `lease`, `release`, `record`, `status`, `logins` and `golden` run on the pool, as `ssh <user>@<host> browsermaze lease`; `browsermaze version` works everywhere. This replaces the pool program called `browserpool` in 0.3.x: `setup.sh` removes its `/usr/local/bin/browserpool` and its sudo rule `/etc/sudoers.d/browserpool`, and the new sudo rule names `/usr/local/lib/browsermaze/browsermaze-pool`.
- `setup.sh --version` and `browsermaze version` print the version.
