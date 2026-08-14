# PostHog on Hetzner — deploy runbook

Self-hosted PostHog on a single Hetzner Robot dedicated server, sized for a steady
~150-200M events/month plus session replay. Everything needed to deploy/operate this
lives under this directory and in `.github/workflows/hetzner-deploy.yml`, on the
`hetzner-deploy` branch of this repo — deliberately *not* on `master`, since `master`
tracks upstream PostHog and something else keeps it in sync; committing here instead
means an upstream sync can never collide with or overwrite this branch. When you want
to pick up upstream fixes, merge/rebase `master` into `hetzner-deploy` intentionally.

**Hardware note:** the box being ordered (a Hetzner **Server Auction** listing, see §1)
is smaller on CPU than the original AX162-R sizing target (48c/96t, 256GB RAM, 4×NVMe
RAID10), but matches or beats it on RAM and disk. Several build-to-order options
(AX102-1, EX131, EX63, plus a couple of weaker/smaller auction listings) were
considered and rejected along the way — see git history of this file if you need the
comparison again. Re-check headroom (RAM, disk, Kafka partition count) against real
traffic volume once it's live, same as with any of the other options — this one just
starts from a more comfortable place than the others did.

## What's here

| File | What it does | Who runs it |
|---|---|---|
| `bootstrap.sh` | OS hardening, sysctl/ulimit tuning, Docker + local-persist install | CI, every deploy (idempotent) |
| `firewall-baseline.sh` | One-time Hetzner Robot Firewall setup (80/443 open, 22 only from VPN IP) | You, once, from your own machine |
| `deploy.sh` | Clones this repo, stages compose files, generates/preserves secrets, `docker compose up`, health-check + rollback | CI, every deploy |
| `docker-compose.pin.yml` | Sizing/tuning overlay + digest-pins for floating `:master` images | n/a (consumed by deploy.sh) |
| `compose/{start,wait,temporal-django-worker}` | Static copies of the entrypoint scripts `bin/deploy-hobby` normally generates | n/a |
| `monitoring/` | Optional promtail + node-exporter → existing org Loki, not started automatically | You, manually, if wanted |

## 1. Order the hardware (manual — Hetzner Robot console)

**EX131** — Intel Xeon Gold 6731P (32c/64t, 2.5GHz base / 4.1GHz turbo, Granite
Rapids), base config **128GB DDR5 ECC reg. RAM, 2×1.92TB NVMe DC-Edition**, 1 Gbit/s
guaranteed/unlimited. Deliberately smaller than the original AX162-R plan (48c/96t,
256GB, 4×NVMe RAID10) — chosen as a cheaper starting point that may or may not stay as
the permanent production box; see the hardware note above before treating it as a done
deal for the full ~150-200M events/month target.

Only 2 disks → **RAID1**, not RAID10: ~1.92TB usable. At the sizing estimate used
throughout this deploy (~1-2TB/year from events alone, plus unpredictable
session-replay growth), this is a noticeably tighter runway than a 4-disk RAID10 plan
would give — watch disk usage from day one. EX131's own configurator offers scaling up
to **4×7.68TB NVMe** at order time if more headroom is wanted later (confirmed on
Hetzner's EX131 page — unlike AX102, this model's storage options are explicit).

RAM headroom, if that becomes the bottleneck before disk does: EX131 goes up to
**256GB** as a configurator option over the 128GB base — cheaper lever to pull than a
full hardware migration if `docker-compose.pin.yml`'s per-service limits start getting
tight.

### If disk headroom runs out later: add a second array, don't grow the first

Converting the boot RAID1 into a bigger array in place (e.g. RAID1→RAID10 by adding
drives to the same `mdadm` array) is possible but risky without a backup to fall back
on, and touches the live OS/root filesystem. The lower-risk path, since ClickHouse's
volume is already decoupled via `docker-volume-local-persist` (see `bootstrap.sh`):

1. File a Hetzner **Remote Hands** ticket to physically install 2 more NVMe drives into
   free chassis slots. They show up as new block devices (e.g. `/dev/nvme2n1`,
   `/dev/nvme3n1`) — the boot array (`/dev/md0`) is untouched.
2. Build a **separate** `mdadm` array on the new pair, `/dev/md1`. Prefer RAID1 over
   RAID0 here too: RAID0 doubles usable space (~3.84TB vs ~1.92TB) but any single disk
   failure loses 100% of ClickHouse's data instantly, and there's no backup job in this
   iteration to fall back on (see the backups gap noted in §6) — RAID1 keeps the same
   risk profile as the boot array at the cost of the capacity doubling.
3. `mkfs.ext4 /dev/md1`, mount at a new path (e.g. `/mnt/volumes/clickhouse-nvme2/_data`),
   add it to `/etc/fstab` so it survives reboots.
4. `docker compose stop clickhouse`, `rsync` the existing data from
   `/mnt/volumes/root_clickhouse-data/_data` to the new mount.
5. In `docker-compose.pin.yml`, change the `clickhouse-data` volume's
   `driver_opts.mountpoint` to the new path.
6. `docker compose up -d clickhouse`.

Net effect: a support ticket + one `rsync` + one line changed in one file, versus
reinstalling the OS. Downtime is scoped to ClickHouse, not the whole stack.

## 2. Install the OS (manual — Hetzner Rescue console)

1. Robot console → server → **Rescue** tab → activate Linux (64-bit) rescue system → **Reset** to power-cycle into it.
2. SSH in as `root` with the rescue password Robot shows you.
3. Confirm drives: `lsblk` (expect `/dev/nvme0n1`, `/dev/nvme1n1`).
4. Run `installimage` and set:
   ```
   DRIVE1 /dev/nvme0n1
   DRIVE2 /dev/nvme1n1
   SWRAID 1
   SWRAIDLEVEL 1
   HOSTNAME posthog-platform
   PART /boot ext3 1024M
   PART /    ext4 all
   IMAGENAME <exact Ubuntu-2404 image filename shown in the installimage picker>
   ```
   Single root filesystem across the whole array on purpose — `/mnt/volumes/...` used
   by `docker-volume-local-persist` is just a directory on that same root, no separate
   partition needed.
5. Reboot into the installed OS, verify: `cat /proc/mdstat` (expect `raid1`, `[UU]`).

## 3. Set the firewall baseline (manual — your machine, once)

```
HETZNER_ROBOT_USER=... HETZNER_ROBOT_PASSWORD=... SERVER_IP=... VPN_EGRESS_IP=... \
  ./firewall-baseline.sh
```

Create the Robot webservice account first (Robot console → Settings → Webservice) if
you don't have one — it's separate from your normal Robot login.

## 4. Configure GitHub

On `OrganicApps/posthog`, create a GitHub Environment (e.g. `hetzner-platform`) and set,
per `.env.example` in this directory:
- Variables: `DOMAIN`, `HETZNER_SERVER_IP`, `VPN_EGRESS_IP`, `GET_MY_IP_URL` (any
  "what's my IP" endpoint), `POSTHOG_APP_TAG`/`POSTHOG_NODE_TAG` (pin these to a real
  tag/digest before going to production, don't leave `latest` floating)
- Secrets: `HETZNER_ROBOT_USER`, `HETZNER_ROBOT_PASSWORD`, `HETZNER_SSH_KEY` (the
  server's root SSH private key), and optionally `SENTRY_DSN`, `ANTHROPIC_API_KEY`,
  `OPENAI_API_KEY`

## 5. First deploy

Push to `hetzner-deploy` (or trigger `workflow_dispatch`). The workflow: opens SSH on
the Robot Firewall for the runner's IP → waits for the port → copies this directory →
SSHes in → runs `bootstrap.sh` then `deploy.sh` → health-checks `/_health` → closes the
firewall rule again.

First run takes a while: Docker install, image pulls for ~25 services, ClickHouse/Kafka
init, Postgres migrations, TLS cert issuance via Let's Encrypt (needs the DNS A record
for `DOMAIN` already pointing at the server before this runs).

## 6. After the first deploy

- **Digest-pin the floating `:master` images** in `docker-compose.pin.yml` — see the
  TODOs at the bottom of that file. Do this before calling the instance production-ready;
  until then, those ~10 services will silently pick up whatever's newest on `:master` on
  every `--pull always`.
- **Run the verification steps** below.
- **Known gap, accepted for this iteration: no automated backups.** Postgres and
  ClickHouse data on this box has no backup job. If the disk/server is lost, the data is
  gone. Revisit this explicitly before this instance holds anything you can't afford to
  lose — it was deliberately deferred, not forgotten.

## Verification

1. `curl -sf https://$DOMAIN/_health` → `200`.
2. Ingestion round-trip:
   ```
   curl -X POST https://$DOMAIN/capture/ -H 'Content-Type: application/json' \
     -d '{"api_key":"<project_key>","event":"smoke_test","distinct_id":"deploy-verify"}'
   # wait ~30s
   docker compose exec clickhouse clickhouse-client --query \
     "SELECT count() FROM events WHERE event = 'smoke_test'"
   ```
3. Session replay: record a real session via the JS snippet in a browser, then confirm a
   blob shows up in object storage (SeaweedFS S3 API, credentials `any`/`any` per the
   compose file's `SESSION_RECORDING_V2_S3_*` env vars).
4. ClickHouse health baseline (re-check periodically — person-merge mutations are the
   known operational risk at this event volume):
   ```
   docker compose exec clickhouse clickhouse-client --query \
     "SELECT * FROM system.mutations WHERE is_done = 0"
   ```
