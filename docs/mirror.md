# 资源镜像

ScanNeo2 首次运行要下载约 36 GB 参考数据：Ensembl 的基因组、注释和蛋白质组，VEP 缓存
与插件，GATK/VQSR 训练集，REDIportal 编辑图谱，IMGT/HLA 等位基因，OptiType 的 HLA 参考
面板，以及 IEDB 的预测工具。每条下载规则都接受 `resources.base_url`，因此这些文件可以
改从对象存储（或任意 HTTP 服务器）提供，而不必走原始公开源——当公开源在工作流所在机器
上很慢或不可达时，这是必要的。

## 镜像里必须放什么

必须是与规则下载**完全相同的归档文件**，放在相同的相对路径下。镜像**不是**解压后的
`resources/` 目录树——`gzip -d`、`tar xz` 仍由规则自己执行。权威清单是
`misc/scripts/pre_download_resources.sh` 里内嵌的那张表，它必须与 `workflow/rules/*.smk`
中 `base_url` 分支里的路径保持一致。

## 怎么建

```bash
# 先 dry-run：只列出每个文件及其大小，不传输
misc/scripts/pre_download_resources.sh --dest myoss:bucket/ScanNeo2/resources/r111 --list

# 再正式建（幂等，失败后直接重跑）
misc/scripts/pre_download_resources.sh --dest myoss:bucket/ScanNeo2/resources/r111
```

脚本从配置里的 `reference.release` 取版本（`--release` 可覆盖），并用 rclone 把每个文件
**流式**写到目标：多线程、不在本地落盘。已存在且大小一致的文件会跳过，传输完成后复核
大小，失败会重试，**只要有一个失败就以非零码退出并列出失败清单**——残缺的镜像不可能被
当成完整的。`--check` 核对已有镜像，`--only <组>` 只重跑某一组，`--force` 强制重传；
镜像根目录会写入 `MANIFEST.tsv`（路径、大小、源 URL）。

## 每个 release 用一个独立前缀

把 `base_url` 指向带 Ensembl release 的前缀，不要用平铺的公共前缀：

```yaml
resources:
  base_url: https://bucket.oss-cn-beijing.aliyuncs.com/ScanNeo2/resources/r111
```

镜像里有三个文件**随 release 变化、但文件名里不带 release**：Ensembl 蛋白质组
（`refs/Homo_sapiens.GRCh38.pep.all.fa.gz`）和两个 Ensembl VEP 插件。若用平铺前缀，一旦
升 `reference.release`，它们会静默地继续提供上一版，而基因组和注释已经换新。按 release
分前缀能让每份快照内部自洽，也允许先把下一版建好、`--check` 通过后再切换，期间旧版照常
对外服务。

## 私有镜像

若前缀不是公共可读的，规则的下载会返回 `403`。与其把桶开放，不如给规则凭据：

```bash
export OSS_ACCESS_KEY_ID=...
export OSS_ACCESS_KEY_SECRET=...
```

下载会经过 `workflow/scripts/fetch_resource.sh`：**仅当** URL 主机名属于 `*.aliyuncs.com`
**且**这两个变量都已设置时，它才用 curl 内建的 SigV4 给请求签名。region 从 endpoint 主机名
解析（`...oss-cn-beijing-internal...` → `cn-beijing`，可用 `OSS_REGION` 覆盖）。两个变量都
没设时走普通 HTTP——公共可读的镜像无需任何配置，行为与以前完全一致。

!!! note "OSS 桶开启了「阻止公共访问」"
    在桶开启 *Block Public Access* 期间，OSS 会拒绝写入允许匿名的 `GetObject` 策略——即使
    该策略用 `acs:SourceVpc` 条件限定在某个 VPC 内也不行（`AccessDenied: Put public bucket
    policy is not allowed`）。这种情况只能走凭据，而对象本身仍可保持私有。

## 首次构建容易踩的坑

这些是首次构建会遇到的问题——无论用这个脚本还是自己的工具，都值得知道。

| 现象 | 原因 | 处理 |
| --- | --- | --- |
| 落地的文件远小于预期，或内容是 HTML | NCBI 拦截 rclone 默认的 `rclone/vX.Y.Z` User-Agent：**返回 HTTP 200**，但正文是拦截页 | 脚本发送标识项目的 User-Agent；真正抓住它的是大小校验 |
| 多线程下载报 `503 Service Unavailable` | 同一个源拒绝并发的 Range 请求（单个 Range 请求返回 `206` 正常） | `SINGLE_STREAM_HOSTS` 让这些源退回单流 |
| 小内存机器上 OOM | `--buffer-size` 是**按下载流**分配的，`--multi-thread-streams 16 --buffer-size 64M` 最多要 1 GB | 调小 buffer，而不是减少流数 |
| 上传报 `InvalidLocationConstraint` | S3 兼容的 endpoint 拒绝了 rclone 的桶存在性检查，随后 rclone 会尝试创建桶 | 在 rclone remote 上设 `no_check_bucket = true` |
| 传输成功但日志里看不到进度 | rclone 的 `--stats` 输出是 INFO 级，默认的 NOTICE 级别把它滤掉了 | 脚本会传 `--log-level INFO` |

## 核对镜像

`--check` 把每个镜像对象与源站的 `Content-Length` 做对比。这能抓住截断的上传和"下载到
拦截页"，但抓不住**大小未变的内容损坏**——对最大或最关键的几个文件，建议再比对一段尾部
数据（或哈希）。
