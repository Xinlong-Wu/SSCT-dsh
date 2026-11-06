# dsh-vm — DeepSeek Harness web UI in a QEMU guest

English | [中文](README.zh.md)

The release-built image runs an Ubuntu guest under QEMU/KVM inside one
container. The `dsh` npm tree ships inside the image at `/opt/dsh` and is
exported read-only into the guest; host config and skills directories are
mounted read-only into the container and exported as read-only 9p shares, so
the guest consumes them without ever writing back. The structure follows
[Compiler-Security/CompilerExplorer-Deploy](https://github.com/Compiler-Security/CompilerExplorer-Deploy):
a thin QEMU runtime image, a downloaded Ubuntu cloud base image, and a
cloud-init-provisioned qcow2 overlay.

```
docker run → container → QEMU/KVM → Ubuntu guest
                                      ├─ dsh web (systemd dsh.service, guest 10240)
                                      ├─ /mnt/dsh    ← 9p ro ← container /opt/dsh
                                      ├─ /mnt/config ← 9p ro ← container /share/config ← host
                                      └─ /mnt/skills ← 9p ro ← container /share/skills ← host
```

## Run

```sh
docker run -d --name dsh-vm \
  -p 127.0.0.1:10240:10240 -p 127.0.0.1:2222:2222 \
  -v dsh-vm-disk:/vm/disk \
  -v "$HOME/dsh-config:/share/config:ro" \
  -v "$HOME/dsh-skills:/share/skills:ro" \
  -e DEEPSEEK_API_KEY=sk-... \
  ghcr.io/xinlong-wu/ssct-dsh:<version>
```

The first boot downloads the base cloud image into the `dsh-vm-disk` volume and
provisions the guest (Node 24, pnpm, mounts, the `dsh` service, SSH); with
`/dev/kvm` this takes a few minutes. The container logs stream the guest serial
console and report when the web UI answers.

## Mount contract

| Host (`docker run -v`) | Container | Guest (9p, read-only) | Guest role |
|---|---|---|---|
| — (in image) | `/opt/dsh` | `/mnt/dsh` | the dsh npm tree the service runs from |
| `...:/share/config:ro` | `/share/config` | `/mnt/config` | overlayfs lowerdir of `/home/dsh/.dsh` (`DSH_HOME`): profiles, patches, skills are visible; runtime writes stay in the guest overlay |
| `...:/share/skills:ro` | `/share/skills` | `/mnt/skills` | linked to `/home/dsh/.agents/skills` |

Omitting a mount leaves the guest side empty: the home starts fresh and no
extra skills are visible. Host directories are never written.

## Ports and SSH

| Container port | Guest | Purpose |
|---|---|---|
| `10240` | `10240` | dsh web UI (`DSH_VM_WEB_PORT` renames the host side) |
| `${DSH_VM_SSH_PORT:-2222}` | `22` | management SSH into the guest |

SSH uses keys only. Either pass your own private key,
`-e DSH_VM_SSH_KEY=/keys/id_ed25519 -v "$HOME/.ssh/id_ed25519:/keys/id_ed25519:ro"`,
or let the entrypoint generate a keypair into the `dsh-vm-disk` volume on first
boot (it logs the location). Then:

```sh
ssh -i "$HOME/.ssh/id_ed25519" -p 2222 dsh@127.0.0.1
sudo systemctl status dsh.service      # the guest user has passwordless sudo
touch /mnt/config/probe && fail        # shares are read-only, as designed
```

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `DEEPSEEK_API_KEY` / `DEEPSEEK_BASE_URL` / `DSH_TELEMETRY_DISABLED` | — | forwarded into the guest's `/etc/dsh.env` for the service |
| `DSH_VM_SSH_KEY` | generated | private key whose public half is authorized in the guest |
| `DSH_VM_SSH_PORT` | `2222` | container-side SSH forward |
| `DSH_VM_WEB_PORT` | `10240` | container-side web forward |
| `DSH_VM_CPUS` / `DSH_VM_MEMORY_MB` / `DSH_VM_DISK_GB` | `4` / `4096` / `40` | guest sizing |
| `VM_IMAGE_URL` | Ubuntu noble cloud image | guest base image |
| `VM_IMAGE_SHA256` | observed (recorded, not enforced) | enforce a pinned base image; pin a dated release for production |
| `FORCE_REPROVISION` | `0` | `1` discards the overlay and reprovisions on the next boot |

Provisioning also restarts cleanly whenever the seed inputs, the dsh tree
version, or the base image hash change; the overlay is discarded and rebuilt.
`docker run ... --selftest` verifies the image (qemu toolchain plus the dsh
npm tree) without booting the guest; CI runs it as the release smoke.

## Build and publish

The `docker` job in `.github/workflows/upstream-release.yml` builds the image
after a release tag is mirrored: it packs the dsh family tarballs from the tag
commit, installs `dist/npm/deepseek-ai-dsh-<version>.tgz` into `/opt/dsh`
(dependencies resolve from the public registry), runs `--selftest`, and pushes
`ghcr.io/xinlong-wu/ssct-dsh:<version>` with `GITHUB_TOKEN`
(`packages: write`). amd64 only — the guest is x86_64. After the first push,
flip the package visibility to public in the GitHub package settings.

Local build (context must contain `dist/npm/deepseek-ai-dsh-<version>.tgz`
beside `vm/`):

```sh
docker build -f vm/Dockerfile --build-arg DSH_VERSION=<version> \
  --build-arg DSH_COMMIT=$(git rev-parse HEAD) -t dsh-vm:local .
docker run --rm dsh-vm:local --selftest
```

`compose.yaml` plus `.env.example` provide the same run as `docker compose up`
with the persistent volume and mounts wired.
