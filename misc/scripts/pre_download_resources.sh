#!/bin/bash
#
# ScanNeo2 资源预下载：把运行时需要的外部文件预先镜像到对象存储（OSS/S3 兼容），
# 供 config/config.yaml 的 resources.base_url 使用，避免首次运行时从公网慢下载。
#
# 用法：
#   misc/scripts/pre_download_resources.sh --dest myoss:ligsh-bucket-01/ScanNeo2/resources/r111
#   misc/scripts/pre_download_resources.sh --dest ... --list    # 只列清单与源大小，不传输（相当于 dry-run）
#   misc/scripts/pre_download_resources.sh --dest ... --check   # 只核对镜像是否完整（不传输）
#
# 镜像布局为 <dest>/<相对路径>，与 workflow/rules/*.smk 中
# `if [ -n "{params.base_url}" ]` 分支里的路径逐条对应，例如
#   <dest>/refs/Homo_sapiens.GRCh38.111.gtf.gz
# 因此 config.yaml 要写成同一前缀：
#   resources:
#     base_url: https://<bucket>.<endpoint>/ScanNeo2/resources/r111
#
# 依赖 bash / curl / rclone：源站走匿名 `:http:` 远端（无需预先配置），
# 只有 --dest 指向的 OSS remote 需要事先配在 rclone.conf 里。
# 需要代理时用 --proxy（或环境变量 PRE_DOWNLOAD_PROXY）指定，curl 与 rclone
# 都识别标准的 http_proxy / https_proxy / no_proxy。

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

CONFIG_FILE="${REPO_ROOT}/config/config.yaml"
DEST=""
RELEASE=""
ONLY=""
PROXY="${PRE_DOWNLOAD_PROXY:-}"
LOG_FILE=""
STREAMS=16
CHUNK_SIZE="15M"
UPLOAD_CONCURRENCY=16
RETRIES=3
FORCE=0
MODE="download"

TAB=$'\t'

usage() {
    cat <<'EOF'
把 ScanNeo2 的全部外部资源预先镜像到对象存储。

必填：
  --dest REMOTE:PATH      目标前缀，如 myoss:ligsh-bucket-01/ScanNeo2/resources/r111

可选：
  --release N             参考基因组 release；默认取 config/config.yaml 的 reference.release
  --config FILE           配置文件路径（默认 <仓库根>/config/config.yaml）
  --proxy URL             下载代理，如 socks5h://127.0.0.1:1080（默认 $PRE_DOWNLOAD_PROXY）
  --streams N             大文件多线程分片数（默认 16）
  --chunk-size SIZE       OSS 分片上传的块大小（默认 15M）
  --upload-concurrency N  OSS 分片上传并发（默认 16）
  --retries N             单文件传输失败重试次数（默认 3）
  --only GROUPS           只处理指定分组，逗号分隔（refs,rediportal,hla,vep,vqsr,somatic,tools）
  --force                 忽略目标已存在的对象，强制重传
  --list                  只打印清单与源文件大小，不传输
  --check                 只核对镜像完整性，不传输
  --log FILE              额外把执行记录写进该文件
  -h, --help              显示本帮助
EOF
}

# 取选项的值，缺失时报错退出（避免 set -e 下 shift 越界）
opt_value() {
    if [[ $# -lt 2 ]]; then
        echo "错误: $1 需要一个值" >&2
        exit 2
    fi
    printf '%s' "$2"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
    --dest)
        DEST="$(opt_value "$@")"
        shift 2
        ;;
    --release)
        RELEASE="$(opt_value "$@")"
        shift 2
        ;;
    --config)
        CONFIG_FILE="$(opt_value "$@")"
        shift 2
        ;;
    --proxy)
        PROXY="$(opt_value "$@")"
        shift 2
        ;;
    --streams)
        STREAMS="$(opt_value "$@")"
        shift 2
        ;;
    --chunk-size)
        CHUNK_SIZE="$(opt_value "$@")"
        shift 2
        ;;
    --upload-concurrency)
        UPLOAD_CONCURRENCY="$(opt_value "$@")"
        shift 2
        ;;
    --retries)
        RETRIES="$(opt_value "$@")"
        shift 2
        ;;
    --only)
        ONLY="$(opt_value "$@")"
        shift 2
        ;;
    --log)
        LOG_FILE="$(opt_value "$@")"
        shift 2
        ;;
    --force)
        FORCE=1
        shift
        ;;
    --list)
        MODE="list"
        shift
        ;;
    --check)
        MODE="check"
        shift
        ;;
    -h | --help)
        usage
        exit 0
        ;;
    *)
        echo "错误: 未知参数 $1" >&2
        usage >&2
        exit 2
        ;;
    esac
done

if [[ -z "$DEST" ]]; then
    echo "错误: 必须用 --dest 指定目标（如 myoss:bucket/prefix）" >&2
    usage >&2
    exit 2
fi
DEST="${DEST%/}"
if [[ "$DEST" != *:* ]]; then
    echo "错误: --dest 必须是 rclone 远端路径（形如 remote:path），当前为 '$DEST'" >&2
    exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "错误: 找不到 curl" >&2
    exit 2
fi
if [[ "$MODE" != "list" ]] && ! command -v rclone >/dev/null 2>&1; then
    echo "错误: 找不到 rclone（--check 与传输都需要）" >&2
    exit 2
fi

# 交互式终端下才开进度条，否则（写日志时）只留周期性统计，免得 ANSI 刷屏
PROGRESS_FLAG=""
if [[ -t 1 ]]; then
    PROGRESS_FLAG="--progress"
fi

if [[ -n "$PROXY" ]]; then
    export http_proxy="$PROXY"
    export https_proxy="$PROXY"
fi
# 只要有任何代理生效，就让对象存储走直连（内网 endpoint 同样命中 aliyuncs.com）
if [[ -n "${http_proxy:-}${https_proxy:-}" ]]; then
    no_proxy="aliyuncs.com,localhost,127.0.0.1,.internal${no_proxy:+,${no_proxy}}"
    export no_proxy
fi

effective_proxy="${PROXY:-${http_proxy:-${https_proxy:-}}}"

say() {
    printf '%s\n' "$*"
    if [[ -n "$LOG_FILE" ]]; then
        printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG_FILE"
    fi
}

# 资源清单：<镜像相对路径> <原始 URL>，URL 里的 {release} 由 --release 替换。
# ⚠️ 必须与 workflow/rules/*.smk 中 `if [ -n "{params.base_url}" ]` 分支里的
#    路径保持一致；任何一边改动，另一边都要同步。
#    vqsr/dbSNP_b150.vcf.gz 是刻意的改名：源站文件名是 00-common_all.vcf.gz。
manifest() {
    cat <<'EOF'
refs/Homo_sapiens.GRCh38.dna_sm.primary_assembly.fa.gz    https://ftp.ensembl.org/pub/release-{release}/fasta/homo_sapiens/dna/Homo_sapiens.GRCh38.dna_sm.primary_assembly.fa.gz
refs/Homo_sapiens.GRCh38.{release}.gtf.gz                 https://ftp.ensembl.org/pub/release-{release}/gtf/homo_sapiens/Homo_sapiens.GRCh38.{release}.gtf.gz
refs/Homo_sapiens.GRCh38.pep.all.fa.gz                    https://ftp.ensembl.org/pub/release-{release}/fasta/homo_sapiens/pep/Homo_sapiens.GRCh38.pep.all.fa.gz
rediportal/TABLE1_hg38_v3.txt.gz                          https://rediportal.cloud.ba.infn.it/download/TABLE1_hg38_v3.txt.gz
hla/hla_gen.fasta                                         https://ftp.ebi.ac.uk/pub/databases/ipd/imgt/hla/hla_gen.fasta
hla/hla_reference_dna.fasta                               https://raw.githubusercontent.com/FRED-2/OptiType/v1.3.5/data/hla_reference_dna.fasta
hla/hla_reference_rna.fasta                               https://raw.githubusercontent.com/FRED-2/OptiType/v1.3.5/data/hla_reference_rna.fasta
vep/plugins/NMD.pm                                        https://raw.githubusercontent.com/Ensembl/VEP_plugins/release/{release}/NMD.pm
vep/plugins/Downstream.pm                                 https://raw.githubusercontent.com/Ensembl/VEP_plugins/release/{release}/Downstream.pm
vep/plugins/Wildtype.pm                                   https://raw.githubusercontent.com/griffithlab/pVAC-Seq/master/pvacseq/VEP_plugins/Wildtype.pm
vep/cache/homo_sapiens_vep_{release}_GRCh38.tar.gz        https://ftp.ensembl.org/pub/release-{release}/variation/indexed_vep_cache/homo_sapiens_vep_{release}_GRCh38.tar.gz
vqsr/hapmap_3.3.hg38.vcf.gz                               https://storage.googleapis.com/gcp-public-data--broad-references/hg38/v0/hapmap_3.3.hg38.vcf.gz
vqsr/hapmap_3.3.hg38.vcf.gz.tbi                           https://storage.googleapis.com/gcp-public-data--broad-references/hg38/v0/hapmap_3.3.hg38.vcf.gz.tbi
vqsr/1000G_omni2.5.hg38.vcf.gz                            https://storage.googleapis.com/gcp-public-data--broad-references/hg38/v0/1000G_omni2.5.hg38.vcf.gz
vqsr/1000G_omni2.5.hg38.vcf.gz.tbi                        https://storage.googleapis.com/gcp-public-data--broad-references/hg38/v0/1000G_omni2.5.hg38.vcf.gz.tbi
vqsr/1000G_phase1.snps.high_confidence.hg38.vcf.gz        https://storage.googleapis.com/gcp-public-data--broad-references/hg38/v0/1000G_phase1.snps.high_confidence.hg38.vcf.gz
vqsr/1000G_phase1.snps.high_confidence.hg38.vcf.gz.tbi    https://storage.googleapis.com/gcp-public-data--broad-references/hg38/v0/1000G_phase1.snps.high_confidence.hg38.vcf.gz.tbi
vqsr/dbSNP_b150.vcf.gz                                    https://ftp.ncbi.nlm.nih.gov/snp/organisms/human_9606_b150_GRCh38p7/VCF/GATK/00-common_all.vcf.gz
vqsr/dbSNP_b150.vcf.gz.tbi                                https://ftp.ncbi.nlm.nih.gov/snp/organisms/human_9606_b150_GRCh38p7/VCF/GATK/00-common_all.vcf.gz.tbi
vqsr/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz     https://storage.googleapis.com/gcp-public-data--broad-references/hg38/v0/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz
vqsr/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz.tbi https://storage.googleapis.com/gcp-public-data--broad-references/hg38/v0/Mills_and_1000G_gold_standard.indels.hg38.vcf.gz.tbi
somatic/af-only-gnomad.hg38.vcf.gz                        https://storage.googleapis.com/gatk-best-practices/somatic-hg38/af-only-gnomad.hg38.vcf.gz
somatic/af-only-gnomad.hg38.vcf.gz.tbi                    https://storage.googleapis.com/gatk-best-practices/somatic-hg38/af-only-gnomad.hg38.vcf.gz.tbi
tools/IEDB_MHC_I-3.1.4.tar.gz                             https://downloads.iedb.org/tools/mhci/3.1.4/IEDB_MHC_I-3.1.4.tar.gz
tools/IEDB_MHC_II-3.1.12.tar.gz                           https://downloads.iedb.org/tools/mhcii/3.1.12/IEDB_MHC_II-3.1.12.tar.gz
tools/IEDB_Immunogenicity-3.0.tar.gz                      https://downloads.iedb.org/tools/immunogenicity/3.0/IEDB_Immunogenicity-3.0.tar.gz
EOF
}

# 从 config.yaml 的 reference 块解析 release；--release 优先
resolve_release() {
    if [[ -n "$RELEASE" ]]; then
        return
    fi
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "错误: 配置文件不存在: ${CONFIG_FILE}（用 --config 指定，或用 --release 直接给定版本）" >&2
        exit 2
    fi
    # 只认 reference 块里的 release:，并剥掉行尾注释后的非数字字符
    RELEASE="$(awk '
        /^reference:/             { in_ref = 1; next }
        in_ref && /^[^[:space:]]/ { in_ref = 0 }
        in_ref && /^[[:space:]]+release:/ {
            line = $0
            sub(/#.*/, "", line)
            gsub(/[^0-9]/, "", line)
            print line
            exit
        }
    ' "$CONFIG_FILE")"
    if [[ -z "$RELEASE" ]]; then
        echo "错误: 无法从 ${CONFIG_FILE} 解析 reference.release，请用 --release 指定" >&2
        exit 2
    fi
}

# 源文件字节数；取重定向后最后一个 Content-Length。取不到（HEAD 不被支持等）返回空。
source_size() {
    curl -sIL --max-time 60 "$1" 2>/dev/null |
        tr -d '\r' |
        awk 'tolower($1) == "content-length:" { n = $2 } END { if (n != "") print n }' || true
}

# 目标对象字节数；对象不存在返回空
object_size() {
    rclone lsl "$1" 2>/dev/null | awk 'NF >= 4 { print $1; exit }' || true
}

human_size() {
    if [[ -z "${1:-}" ]]; then
        printf '?'
    elif command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec "$1"
    else
        printf '%s' "$1"
    fi
}

# 流式转储：源走匿名 :http: 远端，多线程分片直接写成 OSS 对象，不落本地磁盘。
# 注意多线程分片上传后 OSS 对象的 ETag 不再是 MD5，所以只按大小校验。
transfer() {
    local url="$1" rel="$2"
    local proto="${url%%://*}"
    local rest="${url#*://}"
    local origin="${proto}://${rest%%/*}"
    local path="${rest#*/}"

    rclone copyto ":http:${path}" "${DEST}/${rel}" \
        --http-url "$origin" \
        --multi-thread-streams "$STREAMS" \
        --multi-thread-cutoff 64M \
        --buffer-size 64M \
        --s3-chunk-size "$CHUNK_SIZE" \
        --s3-upload-concurrency "$UPLOAD_CONCURRENCY" \
        --timeout 5m \
        --contimeout 60s \
        --low-level-retries 10 \
        --retries 1 \
        --stats 30s \
        --stats-one-line \
        --log-file "$RCLONE_LOG" \
        $PROGRESS_FLAG
}

resolve_release
RCLONE_LOG="${LOG_FILE:-/dev/null}"

say "🚀 ScanNeo2 资源预下载  [$(date '+%Y-%m-%d %H:%M:%S')]"
say "   模式:     ${MODE}"
say "   release:  ${RELEASE}"
say "   目标:     ${DEST}"
say "   代理:     ${effective_proxy:-（直连）}"
if [[ "$MODE" == "download" ]]; then
    say "   分片:     ${STREAMS} 线程 / 块 ${CHUNK_SIZE} / 上传并发 ${UPLOAD_CONCURRENCY}"
    say "   重试:     每文件最多 ${RETRIES} 次"
fi
if [[ -n "$ONLY" ]]; then
    say "   分组过滤: ${ONLY}"
fi
say ""

ok=0
skipped=0
failed=0
listed=0
failed_list=()
rows=()
total_src=0

while read -r rel_tpl url_tpl; do
    if [[ -z "${rel_tpl:-}" || "$rel_tpl" == \#* ]]; then
        continue
    fi
    # 相对路径与 URL 里都可能带 {release}（如 ...GRCh38.{release}.gtf.gz）
    rel="${rel_tpl//\{release\}/$RELEASE}"
    url="${url_tpl//\{release\}/$RELEASE}"

    if [[ -n "$ONLY" ]]; then
        grp="${rel%%/*}"
        case ",${ONLY}," in
        *",${grp},"*) ;;
        *) continue ;;
        esac
    fi

    target="${DEST}/${rel}"

    if [[ "$MODE" == "list" ]]; then
        src_size="$(source_size "$url")"
        printf '  %-58s %12s\n' "$rel" "$(human_size "$src_size")"
        listed=$((listed + 1))
        if [[ -n "$src_size" ]]; then
            total_src=$((total_src + src_size))
        fi
        continue
    fi

    src_size="$(source_size "$url")"
    dst_size="$(object_size "$target")"

    if [[ "$MODE" == "check" ]]; then
        if [[ -z "$dst_size" ]]; then
            printf '  ✗ 缺失      %s\n' "$rel"
            failed=$((failed + 1))
            failed_list+=("$rel (缺失)")
        elif [[ -n "$src_size" && "$dst_size" != "$src_size" ]]; then
            printf '  ✗ 大小不符  %s (源 %s / 目标 %s)\n' "$rel" "$src_size" "$dst_size"
            failed=$((failed + 1))
            failed_list+=("$rel (大小不符)")
        else
            printf '  ✓ %-58s %12s\n' "$rel" "$(human_size "$dst_size")"
            ok=$((ok + 1))
        fi
        continue
    fi

    # download：源与目标大小一致就跳过，使脚本可重复执行
    if [[ "$FORCE" -eq 0 && -n "$src_size" && "$dst_size" == "$src_size" ]]; then
        say "⏭  已存在，跳过: $rel ($(human_size "$dst_size"))"
        skipped=$((skipped + 1))
        rows+=("${rel}${TAB}${dst_size}${TAB}${url}")
        continue
    fi

    say "📥 ${rel}"
    say "     <- ${url}"
    success=0
    for ((attempt = 1; attempt <= RETRIES; attempt++)); do
        if transfer "$url" "$rel"; then
            success=1
            break
        fi
        say "⚠️  第 ${attempt}/${RETRIES} 次传输失败: $rel"
        if [[ "$attempt" -lt "$RETRIES" ]]; then
            sleep 10
        fi
    done
    if [[ "$success" -eq 0 ]]; then
        say "❌ 传输失败（已重试 $((RETRIES - 1)) 次）: $rel"
        failed=$((failed + 1))
        failed_list+=("$rel")
        continue
    fi

    actual="$(object_size "$target")"
    if [[ -z "$actual" ]]; then
        say "❌ 传输后目标对象不存在: $rel"
        failed=$((failed + 1))
        failed_list+=("$rel (校验失败)")
        continue
    fi
    if [[ -n "$src_size" && "$actual" != "$src_size" ]]; then
        say "❌ 大小校验失败: $rel (源 ${src_size} / 目标 ${actual})"
        failed=$((failed + 1))
        failed_list+=("$rel (大小不符)")
        continue
    fi

    say "✅ $rel ($(human_size "$actual"))"
    ok=$((ok + 1))
    rows+=("${rel}${TAB}${actual}${TAB}${url}")
done < <(manifest)

say ""

if [[ "$MODE" == "list" ]]; then
    say "清单共 ${listed} 条，已知源文件合计 $(human_size "$total_src")"
    say "（--list 不传输；确认无误后去掉该参数正式执行）"
    exit 0
fi

if [[ "$MODE" == "check" ]]; then
    say "🏁 核对完成: 正常 ${ok} / 异常 ${failed}"
else
    # 写一份镜像清单到目标根目录，便于审计与后续核对
    if [[ "${#rows[@]}" -gt 0 ]]; then
        manifest_out="$(mktemp)"
        {
            printf '# ScanNeo2 resource mirror\n'
            printf '# release\t%s\n' "$RELEASE"
            printf '# generated\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
            printf '# relative_path\tsize_bytes\tsource_url\n'
            for row in "${rows[@]}"; do
                printf '%s\n' "$row"
            done
        } >"$manifest_out"
        if rclone copyto "$manifest_out" "${DEST}/MANIFEST.tsv" >>"$RCLONE_LOG" 2>&1; then
            say "📄 已写出镜像清单: ${DEST}/MANIFEST.tsv"
        else
            say "⚠️  镜像清单写入失败: ${DEST}/MANIFEST.tsv"
        fi
        rm -f "$manifest_out"
    fi
    say "🏁 完成: 成功 ${ok} / 跳过 ${skipped} / 失败 ${failed}"
fi

if [[ "${#failed_list[@]}" -gt 0 ]]; then
    say "问题清单:"
    for item in "${failed_list[@]}"; do
        say "  - ${item}"
    done
    exit 1
fi
