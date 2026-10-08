# upstream-comparison 实例（32.236.75.213:81）

第二个 Chatwoot，跑**从本仓库构建的镜像**，用来跟自有客服系统做对比。
与生产栈完全隔离（独立项目名 / 网络 / 命名卷，容器前缀 `chatwoot-upstream-*`）。

服务器安装位置：`/opt/chatwoot-upstream/`

---

## 镜像怎么来

**不用官方 `chatwoot/chatwoot`，也不用 bind mount 源码，也不用 registry。**

原因：官方镜像的前端产物是**它自己那个 commit** 编译的。把本仓库的代码塞给它，
后端和前端就是两个版本 —— 实测把工作树 bind mount 进容器后，Super Admin 因为
缺 `entrypoints/superadmin.scss`（develop 的 #16137 新增）**整片 500**。
自建镜像让前后端来自同一次构建。

```
./deploy.sh
  │  DOCKER_HOST=ssh://ubuntu@32.236.75.213
  │  把本地工作树当构建上下文（含 .git，Dockerfile 要写 .git_sha）
  ▼
服务器的 docker daemon 原生构建（x86_64）
  │  bundle install → pnpm install → assets:precompile
  ▼
服务器本地镜像  chatwoot-upstream:<短SHA>
  │  docker compose up -d
  ▼
容器
```

**为什么在服务器上构建**：本机是 arm64，服务器是 x86_64。在本机构建要 QEMU 模拟，
Chatwoot 这种体量会慢到不可用。走 `DOCKER_HOST=ssh://` 不需要本地 Docker daemon，
也不需要经过任何 registry —— 镜像构建完就直接落在服务器的 image store 里。

**EE 版不需要额外开关**：`ChatwootApp.enterprise?` 只看 `enterprise/` 目录在不在
（`lib/chatwoot_app.rb`），而本仓库有它。上游 workflow 里那句 `ENV CW_EDITION="ee"`
只影响给 hub 上报的 `edition` 字段，而 hub 本来就被挡住了。

---

## 日常部署

```bash
./deploy.sh                 # 构建 + 部署（tag = 短 SHA，工作区脏则加 -dirty）
./deploy.sh --build-only    # 只构建，先验证再部署
./deploy.sh --status        # 看服务器上现在跑的是哪个镜像、有哪些历史镜像
./deploy.sh --tag <tag>     # 切到已构建的 tag，不重新构建
```

`deploy.sh` 会自动改写服务器上 `docker-compose.yml` 里那行 `image:`。

⚠️ **构建跑在生产机上**（那台机器同时跑着客服生产栈）：4 核，可用内存约 5～6G，
而 vite 构建要 4G 堆。构建期间盯一眼 `free -h`，别让它把生产栈挤 OOM。
构建约 20–40 分钟，有缓存会快一些。

compose 里写了 `pull_policy: never` —— 本地镜像是唯一来源，拉不到就该直接报错，
而不是悄悄回退到旧镜像。

（`.env` 在服务器上是 `root:root 600`，所以脚本里 `docker compose` 都带 `sudo -n`，
否则读不到 `POSTGRES_PASSWORD`。）

---

## 订阅检查（每天被重置那个）

Chatwoot 每天会检查订阅，把 `INSTALLATION_PRICING_PLAN` 打回 `community`
并回收全部 premium feature：

```
schedule.yml  internal_check_new_versions_job   cron 0 0 * * *
  └─ TriggerDailyScheduledItemsJob   排到本实例固定分钟（MD5(installation_identifier) % 1440）
     └─ Internal::CheckNewVersionsJob#perform
          ├─ ChatwootHub.sync_with_hub     POST hub.2.chatwoot.com/ping
          └─ [enterprise] update_plan_info ← 把返回的 plan 写回 InstallationConfig
             [enterprise] ReconcilePlanConfigService ← 关掉所有 premium feature
```

`docker-compose.yml` 里的 `extra_hosts: hub.2.chatwoot.com:127.0.0.1` 把它拦住。
阻断后 `sync_with_hub` 返回 `nil`，enterprise 那两段就都不执行了。

**为什么是挡域名，而不是删 `schedule.yml` 里的定时任务：**

- `app/controllers/super_admin/settings_controller.rb` 里有
  `Internal::CheckNewVersionsJob.perform_now` —— **点开 Super Admin → Settings
  就同步触发一次同样的重置**，跟 cron 无关。删 cron 挡不住这条。
- `DISABLE_TELEMETRY=1` 也不能用，它只影响 metrics 上报，`/ping` 照发。
- 挡域名两条入口一起挡，且不用改任何上游文件。

⚠️ 副作用：`check_new_versions_job.rb` 的 `update_version_info` 里
`@instance_info['version']` 会对 `nil` 抛 `NoMethodError`（`@instance_info` 是 nil）。
结果是对的（崩在写 plan 之前），但**每天日志里会多一条 ERROR**。

---

## 打进镜像的本仓库改动

- `config/initializers/zz_local_patches.rb` —— 把
  `Concerns::CaptainMarkdownDocumentable::MARKDOWN_MAX_LENGTH` 从 10_000 提到
  50_000，让 39K 的客服手册能整份导入。上游没有这个文件，是我们加的。

其余定制（Captain/LLM 相关）都走 InstallationConfig / App Configs，不在代码里。

---

## 可复现性

镜像 tag 是构建时的短 SHA（工作区脏则带 `-dirty`）。想知道线上跑的是哪份代码，
`./deploy.sh --status` 一看便知。要回到某个历史构建：`./deploy.sh --tag <tag>`。

---

## 回滚

`./deploy.sh --tag <上一个 tag>` 即可 —— 镜像都还在服务器上。
原上游 compose 备份在 `/opt/chatwoot-upstream/docker-compose.yml.bak.<日期>`，
但和现在的结构差很多（少了 `extra_hosts` 和 `pull_policy`），只在极端情况下才用它。
