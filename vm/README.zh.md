# dsh-vm — QEMU guest 中的 DeepSeek Harness web UI

[English](README.md) | 中文

发布流程构建的镜像在单个容器内以 QEMU/KVM 运行 Ubuntu guest。`dsh` npm 依赖树随镜像分发于 `/opt/dsh`,并以只读方式透传进 guest;宿主的 config 与 skills 目录以只读方式挂载进容器,再作为只读 9p 共享导出,guest 消费它们但从不回写。整体结构参照 [Compiler-Security/CompilerExplorer-Deploy](https://github.com/Compiler-Security/CompilerExplorer-Deploy):薄 QEMU 运行时镜像、按需下载的 Ubuntu cloud 基础镜像、cloud-init 供给的 qcow2 overlay。

```
docker run → container → QEMU/KVM → Ubuntu guest
                                      ├─ dsh web (systemd dsh.service, guest 10240)
                                      ├─ /mnt/dsh    ← 9p ro ← container /opt/dsh
                                      ├─ /mnt/config ← 9p ro ← container /share/config ← host
                                      └─ /mnt/skills ← 9p ro ← container /share/skills ← host
```

## 运行

```sh
docker run -d --name dsh-vm \
  -p 127.0.0.1:10240:10240 -p 127.0.0.1:2222:2222 \
  -v dsh-vm-disk:/vm/disk \
  -v "$HOME/dsh-config:/share/config:ro" \
  -v "$HOME/dsh-skills:/share/skills:ro" \
  -e DEEPSEEK_API_KEY=sk-... \
  ghcr.io/xinlong-wu/ssct-dsh:<version>
```

首次启动会把基础 cloud 镜像下载进 `dsh-vm-disk` 卷,并在 guest 内完成供给(Node 24、pnpm、挂载、`dsh` 服务、SSH);有 `/dev/kvm` 时只需几分钟。容器日志跟随 guest 串口控制台,并在 web UI 就绪时输出提示。

## 挂载契约

| 宿主(`docker run -v`) | 容器 | guest(9p,只读) | guest 内角色 |
|---|---|---|---|
| —(镜像内) | `/opt/dsh` | `/mnt/dsh` | 服务运行的 dsh npm 依赖树 |
| `...:/share/config:ro` | `/share/config` | `/mnt/config` | `/home/dsh/.dsh`(`DSH_HOME`)的 overlayfs 下层:profiles、补丁、skills 可见;运行态写入留在 guest overlay 内 |
| `...:/share/skills:ro` | `/share/skills` | `/mnt/skills` | 链接为 `/home/dsh/.agents/skills` |

省略某个挂载时 guest 侧为空:home 从空白开始,额外 skills 不可见。宿主目录从不被写入。

## 端口与 SSH

| 容器端口 | guest | 用途 |
|---|---|---|
| `10240` | `10240` | dsh web UI(`DSH_VM_WEB_PORT` 改宿主侧端口) |
| `${DSH_VM_SSH_PORT:-2222}` | `22` | guest 管理 SSH |

SSH 仅支持密钥。可以传入自己的私钥:`-e DSH_VM_SSH_KEY=/keys/id_ed25519 -v "$HOME/.ssh/id_ed25519:/keys/id_ed25519:ro"`;否则 entrypoint 在首启时把密钥对生成到 `dsh-vm-disk` 卷中(日志会输出位置)。然后:

```sh
ssh -i "$HOME/.ssh/id_ed25519" -p 2222 dsh@127.0.0.1
sudo systemctl status dsh.service      # the guest user has passwordless sudo
touch /mnt/config/probe && fail        # shares are read-only, as designed
```

## 环境变量

| 变量 | 默认值 | 含义 |
|---|---|---|
| `DEEPSEEK_API_KEY` / `DEEPSEEK_BASE_URL` / `DSH_TELEMETRY_DISABLED` | — | 转发给 guest 服务的 `/etc/dsh.env` |
| `DSH_VM_SSH_KEY` | 自动生成 | 其公钥会在 guest 内授权的私钥 |
| `DSH_VM_SSH_PORT` | `2222` | 容器侧 SSH 转发端口 |
| `DSH_VM_WEB_PORT` | `10240` | 容器侧 web 转发端口 |
| `DSH_VM_CPUS` / `DSH_VM_MEMORY_MB` / `DSH_VM_DISK_GB` | `4` / `4096` / `40` | guest 规格 |
| `VM_IMAGE_URL` | Ubuntu noble cloud 镜像 | guest 基础镜像 |
| `VM_IMAGE_SHA256` | 观测值(记录,不强制) | 强制校验钉死的基础镜像;生产建议钉死某一日期版本 |
| `FORCE_REPROVISION` | `0` | 设为 `1` 时丢弃 overlay,下次启动重新供给 |

供给输入(seed、dsh 树版本、基础镜像哈希)任一变化都会干净地重建 overlay;`FORCE_REPROVISION` 强制重建。`docker run ... --selftest` 校验镜像(qemu 工具链与 dsh npm 树)而不启动 guest;CI 在发布冒烟中运行它。

## 构建与发布

`.github/workflows/upstream-release.yml` 的 `docker` job 在 release tag 镜像完成后构建镜像:从 tag 提交打包 dsh 家族 tarballs,把 `dist/npm/deepseek-ai-dsh-<version>.tgz` 安装进 `/opt/dsh`(依赖从公共 registry 解析),运行 `--selftest`,以 `GITHUB_TOKEN`(`packages: write`)推送 `ghcr.io/xinlong-wu/ssct-dsh:<version>`。仅 amd64——guest 为 x86_64。首次推送后,需在 GitHub 包设置中把可见性改为 public。

本地构建(构建上下文需在 `vm/` 旁包含 `dist/npm/deepseek-ai-dsh-<version>.tgz`):

```sh
docker build -f vm/Dockerfile --build-arg DSH_VERSION=<version> \
  --build-arg DSH_COMMIT=$(git rev-parse HEAD) -t dsh-vm:local .
docker run --rm dsh-vm:local --selftest
```

`compose.yaml` 与 `.env.example` 把同一次运行接到 `docker compose up`,卷与挂载均已接好。
