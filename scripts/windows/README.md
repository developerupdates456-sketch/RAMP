# Windows scripts (legacy)

These are the **original Windows / Docker Desktop** operational scripts, kept for
reference and for anyone who still runs the old Windows deployment. They are not
used by the Linux deployment and are not exercised by CI.

| File | Purpose | Linux equivalent |
|---|---|---|
| `run-setup.bat` | one-command bootstrap (registers a boot scheduled task) | `../run-setup.sh` |
| `install‑bootstrap.ps1` | first-time install | `../setup-production.sh` |
| `setup.bat` / `setup-production.ps1` | full install and configuration | `../setup-production.sh` |
| `Start-TeamPresence-Production.ps1` | start an existing deployment | `../start-production.sh` |
| `update-production.ps1` | pull images and restart | `../update-production.sh` |
| `TeamPresence-Safe-Update.ps1` | update with backup + health gate | `../update-production.sh` |
| `TeamPresence-Rollback.ps1` | roll back to the previous image | `../rollback.sh` |
| `TeamPresence-Docker-Diagnostics.ps1` | collect diagnostics | `../diagnostics.sh` |
| `TeamPresence-Docker-Repair.ps1` | repair a broken stack | *(no Linux equivalent)* |
| `health-check.bat` | health probe | `../health-check.sh` |
| `backup.bat` | file backup | `../db-backup.sh` |
| `deploy.bat` | build and deploy | `../build-images.sh` |
| `build-images.ps1` | build images locally | `../build-images.sh` |
| `domain-ssl-*.ps1` | TLS apply / backup / reload / rollback / validate | `../domain-ssl-*.sh` |

## Why they were moved

These scripts hard-code Windows concepts that do not exist on the target
platform: `C:\docker\oem` paths, `%~dp0` and `.\` relative resolution, `schtasks`
scheduled tasks, `powershell -ExecutionPolicy Bypass`, and the Docker Desktop
service model. Mixing them with the Linux scripts made it ambiguous which entry
point was current.

They reference each other with `.\name.ps1`, which is why they were moved as a
group — that keeps those relative links working within this folder.

## Status

**Frozen.** No changes are being made to these files. They are not tested.

If you are deploying on Linux, use `scripts/*.sh`. See `DEPLOYMENT.md` for the
runbook and `scripts/run-setup.sh` for the single-command entry point.

If you find a behaviour here that is missing from the Linux scripts, it is worth
porting — `TeamPresence-Docker-Repair.ps1` is the one with no equivalent yet.
