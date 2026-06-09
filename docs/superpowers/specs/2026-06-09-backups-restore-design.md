# AmneziaWG backups & restore — design

- **Date:** 2026-06-09
- **Status:** approved-for-implementation
- **Builds on:** the single-host appliance spec (2026-06-05). `manage_amneziawg.sh`
  already provides `backup` (tar.gz in `/root/awg/backups/`, rotation 10, contains
  server+client keys/configs/expiry) and `restore <file>` (tar validation +
  pre-restore snapshot + rollback). This spec wraps those for off-host storage
  and fresh-host recovery.

## Decisions (2026-06-09)
1. **Off-host copy:** Ansible **fetches** the newest backup to the control
   machine into a gitignored repo dir (`backups/<host>/`). No remote/cloud.
2. **Encryption:** **age**, asymmetric. Encrypt on the host to a public
   recipient key; the private identity lives only on the control machine, so the
   server can create backups it cannot itself decrypt.
3. **Schedule:** **manual** — run via playbook/`make`. No systemd timer.
4. **Status metric:** write `awg_backup_last_success_timestamp_seconds` and
   `awg_backup_last_status` into the node_exporter textfile dir on each backup
   run (visible in Grafana). No staleness alert (would be noise with manual runs).

## Backup flow (`playbooks/backup.yml` → role `backups`)
1. Ensure `age` is installed on the host (apt, universe).
2. `manage_amneziawg.sh backup` → newest `/root/awg/backups/awg_backup_*.tar.gz`.
3. `age -r {{ backup_age_recipient }} -o <file>.age <file>` on the host
   (recipient = public key; host has no private key).
4. `fetch` the `.age` to `{{ backup_local_dir }}/<inventory_hostname>/`.
5. Write the backup status metric to the textfile collector.
6. Remove the host-side `.age` after a successful fetch (plain tar.gz stays under
   manage's rotation).

## Restore flow (`playbooks/restore.yml`, driven by `-e backup_file=...`)
Brings a fresh OR existing host up from an encrypted backup (migration / DR):
1. `common` + `amneziawg` (install) — so the kernel module, `awg`/manage script,
   `awg_common.sh`, and `awg-quick@awg0` unit exist (installer generates fresh
   keys; restore overwrites them). **`awg_clients` is NOT run** — clients come
   from the backup.
2. Decrypt locally: `age -d -i {{ backup_age_identity }} -o <tmp>.tar.gz
   {{ backup_file }}` (on the control machine; private key never leaves it).
3. Upload the plaintext tar to the host, `manage_amneziawg.sh restore <file>`
   (non-interactive: file arg required; confirm auto-yes without a tty).
4. Verify `awg show awg0` + `manage check`. Clean up temp plaintext on both ends.
5. Then bring up observability (`node_exporter`, exporters, `monitoring_stack`)
   so the restored host is fully equipped — i.e. restore.yml runs the full role
   set except `awg_clients`, with the restore step between `amneziawg` and the
   exporters.

Because the backup contains the server's private key, the restored host keeps the
**same public key** → existing clients reconnect with no reissue (with a domain
endpoint, just repoint DNS).

## Variables
```yaml
backup_local_dir: "{{ playbook_dir }}/../../backups"   # gitignored
backup_age_recipient: ""        # age1... public key (required for backup)
backup_age_identity: "~/.config/awg-backup/age.key"    # control-machine private key (restore)
backup_file: ""                 # path to a .age archive (required for restore)
```

## Prerequisites (operator, one-time)
- Control machine: `age` installed (`brew install age`).
- `age-keygen -o ~/.config/awg-backup/age.key` → put the `# public key: age1...`
  into `backup_age_recipient`. **Back up that private key off-machine** — without
  it the encrypted archives are unrecoverable.

## Make targets
- `make backup` → `ansible-playbook -i inventory.yml playbooks/backup.yml`
- `make restore BACKUP=backups/<host>/awg_backup_*.tar.gz.age` →
  `ansible-playbook -i inventory.yml playbooks/restore.yml -e backup_file=$(BACKUP)`

## Out of scope
Remote/cloud storage, scheduled timers, staleness alerting (all easy follow-ons
once the manual fetch+encrypt flow is proven).

## Verification
- `make backup` → `.age` appears under `backups/<host>/`; metric updates; decrypt
  locally with the identity key and `tar tzf` lists server/client files.
- Restore onto a scratch host with `make restore BACKUP=...` → `awg show awg0`
  shows the SAME public key as the source; declared peers present; services up.
