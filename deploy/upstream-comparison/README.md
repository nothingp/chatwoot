# upstream-comparison 实例（32.236.75.213:81）

第二个 Chatwoot，跑**本仓库自己构建的镜像**，用来跟自有客服系统做对比。
与生产栈完全隔离（独立项目名 / 网络 / 命名卷，容器前缀 `chatwoot-upstream-*`）。

服务器安装位置：`/opt/chatwoot-upstream/`

---

## 镜像怎么来

不要用官方 `chatwoot/chatwoot`。本实例要跑本仓库的代码，而官方镜像的前端产物是
**它自己那个 commit** 编译的 —— 曾经把本仓库的工作树 bind mount 进容器，结果后端来自
本仓库、前端来自官方镜像，Super Admin 因为缺 `entrypoints/superadmin.scss`
（develop 的 PR #16137 新增）整片 500。自建镜像让前后端来自同一次构建。

```
本机改代码  →  git push origin develop
                │  .github/workflows/publish_fork_image.yml（自动触发）
                ▼
             GitHub Actions 构建（linux/amd64，EE 版，带 GHA 缓存）
                │  docker/build-push-action
                ▼
             ghcr.io/nothingp/chatwoot:develop
                             :sha-xxxxxxxx        ← 同一次构建的固定 tag
                │  deploy.sh
                ▼
服务器 /opt/chatwoot-upstream/  →  docker compose pull && up -d
```

workflow 照上游 `publish_ee_docker.yml` 改的：**保留 `enterprise/` 并追加
`ENV CW_EDITION="ee"`**。（官方 `chatwoot/chatwoot:latest` 就是 EE 镜像；
`publish_foss_docker.yml` 那份打的是 `latest-ce`。）差别只在：只构建 amd64、
推 GHCR、加了缓存。

**任意分支**都可以构建：Actions 页面 → Publish fork image (GHCR) → Run workflow →
选分支。构建完从该分支的 commit 里挑 `sha-xxxxxxxx` tag 部署。

---

## 日常部署

```bash
./deploy.sh                # 拉 :develop 最新并重建
./deploy.sh sha-1a2b3c4    # 切到某个固定构建再重建（写回服务器上的 compose）
./deploy.sh --status       # 只看当前跑的镜像版本
```

Rails 在 production 下不热重载，所以更新 = 换镜像 + 重建容器。改了代码要走
**push → 等 Actions → deploy.sh** 这一圈，不像以前挂载那样"存盘即生效"。
这是为了换来版本一致性付的代价。

（`.env` 在服务器上是 `root:root 600`，所以脚本里所有 `docker compose` 都带 `sudo -n`，
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

`:develop` 是浮动 tag。要在 README 里记下"这个实例当时跑的是哪个构建"，用
`./deploy.sh --status` 看，或直接固定到 `sha-xxxxxxxx`。

---

## 回滚

`./deploy.sh sha-xxxxxxxx` 切回上一个构建即可。
原上游 compose 备份在服务器 `/opt/chatwoot-upstream/docker-compose.yml.bak.<日期>`，
但已经和现在的结构差很多（少了 extra_hosts），只在极端情况下才用它。
