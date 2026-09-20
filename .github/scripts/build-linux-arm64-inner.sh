#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# 在 Rocky Linux 8 (aarch64) 容器内构建 open-ontologies 的「麒麟 Linux ARM64」版本。
#
# 只由 .github/workflows/build-linux-arm64.yml 挂载进来执行，**不要在宿主直接跑**。
#
# ── 为什么基线必须钉在 Rocky 8 ────────────────────────────────────────────────
# 目标机是麒麟 Kylin V10/V11 aarch64，V10 SP1/SP2 的 glibc 是 2.28。本项目的
# `dist/dsh-portable-full-linux-arm64-*` 发行包（已在麒麟上验收）里全部 aarch64 原生
# 件实测「最高只要求 GLIBC_2.28」，这就是目标机能力的地面真值。
# Rocky Linux 8 同属 RHEL8 世代、glibc 恰为 2.28，因此构建基线 == 目标基线。
# 若改成在 ubuntu-22.04(2.35)/24.04(2.39) 上直接构建，产物会带 GLIBC_2.3x 符号需求，
# 搬到麒麟直接报 `version 'GLIBC_2.3x' not found`。
#
# ── 为什么必须用 gcc-toolset 而不是 Rocky 8 自带的 gcc 8.5 ────────────────────
# oxigraph 依赖 oxrocksdb-sys（RocksDB，C++），其 build.rs 里写死
#     config.flag("-std=c++20")
# GCC 8 不认 `-std=c++20`（只有 `-std=c++2a`）→ 直接编译失败。所以必须 GCC >= 10，
# 用 gcc-toolset-N（N=12 默认）。toolset 只是并行安装的新编译器，目标 glibc 仍是 2.28。
#
# ── 为什么必须把 libstdc++ 静态链接（关键）─────────────────────────────────────
# 动态链接 libstdc++ 时，产物会向 libstdc++.so.6 索要 GLIBCXX_* 符号版本，而该版本号
# 由**编译该 C++ 代码的工具链**决定：
#     上游 ubuntu-22.04 的产物（实测）要求 GLIBCXX_3.4.30
#     而麒麟 V10 SP1 的 libstdc++ 只到        GLIBCXX_3.4.26
#     （本项目发行包自身最高只到               GLIBCXX_3.4.22）
# GCC>=10 的 libstdc++ 马甲版本是 3.4.28，必然超出 3.4.26 —— 动态链接就是搬不过去。
# 解法：让 `-lstdc++` 绑定到静态归档。gcc libdir 里同时存在
#     libstdc++.so  ← 文本 linker script，指向共享库（ld 优先命中它）
#     libstdc++.a   ← 真正的静态归档（gcc-toolset-N-libstdc++-devel 自带，已核对）
# 把前者移开，ld 就落到后者。产物随即不再需要 libstdc++.so.6，GLIBCXX_* 需求整类消失。
# 这一步不是猜的：脚本最后会读产物自己的动态段来断言结果。
#
# 输入（环境变量）
#   TARGET            Rust target triple，固定 aarch64-unknown-linux-gnu
#   CARGO_FEATURES    Cargo features（上游 release 用 embeddings,plugins）
#   RUST_TOOLCHAIN    rustup toolchain（stable / 1.85.0 …）
#   GLIBC_BASELINE    目标机 glibc 基线，用于断言
#   GLIBCXX_BASELINE  目标机 libstdc++ 基线，用于断言
#   TOOLSETS          gcc-toolset 候选，按顺序尝试
#   OUT               产物输出目录（宿主挂载进来）
#
# 输出（全部落在 $OUT）
#   open-ontologies-aarch64-unknown-linux-gnu       + .sha256
#   SHA256SUMS.txt / build.env / ldd.txt / needed-libs.txt
#   required-glibc-symbols.txt / cargo-lock.sha256 / rustc-version.txt
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

TARGET="${TARGET:?TARGET 未设置}"
FEATURES="${CARGO_FEATURES:?CARGO_FEATURES 未设置}"
TOOLCHAIN="${RUST_TOOLCHAIN:-stable}"
BASELINE="${GLIBC_BASELINE:?GLIBC_BASELINE 未设置}"
GLIBCXX_BASELINE="${GLIBCXX_BASELINE:-3.4.26}"
TOOLSETS="${TOOLSETS:-gcc-toolset-12 gcc-toolset-13 gcc-toolset-11}"
OUT="${OUT:-/out}"
ASSET="open-ontologies-${TARGET}"

mkdir -p "$OUT"

section() { printf '\n\033[1m===== %s =====\033[0m\n' "$*"; }
die()     { printf '::error::%s\n' "$*" >&2; exit 1; }

# ── 1. 容器基线 ───────────────────────────────────────────────────────────────
section "容器基线"
cat /etc/rocky-release 2>/dev/null || cat /etc/os-release
ldd --version | head -n 1
printf 'arch=%s nproc=%s\n' "$(uname -m)" "$(nproc)"
[ "$(uname -m)" = "aarch64" ] || die "容器不是 aarch64（当前 $(uname -m)）"

# ── 2. 构建依赖 ───────────────────────────────────────────────────────────────
section "安装构建依赖"
# · 对应上游 release.yml 的 Debian 名（pkg-config / libssl-dev / libpq-dev）与
#   Dockerfile 的 build-essential + clang，换成等价的 RPM 名。
# · clang 是硬需求：oxrocksdb-sys 用 bindgen 0.72 从 api/c.h 生成绑定，bindgen 需要
#   libclang —— 上游 Dockerfile 装 clang 正是这个原因。Rocky 8 AppStream 有 clang 17/18。
# · git 是硬需求：Cargo.lock 里有 12 条 git 依赖（oxigraph 走 fabio-rovai fork 的固定
#   rev），缺 git 连依赖解析都过不去，构建会停在第一步。
dnf -y \
  --setopt=install_weak_deps=False \
  --setopt=retries=3 \
  --setopt=timeout=60 \
  install \
    make pkgconf-pkg-config \
    openssl-devel libpq-devel libatomic \
    clang clang-devel llvm-libs \
    git tar gzip xz which findutils binutils file \
  || die "基础构建依赖安装失败"

# gcc-toolset：并行安装的新 GCC，目标 glibc 仍是 2.28；RocksDB 的 -std=c++20 需要它。
section "安装 gcc-toolset（RocksDB 需要 C++20）"
TOOLSET=""
for t in $TOOLSETS; do
  if dnf -y --setopt=retries=3 --setopt=timeout=60 install "$t-gcc-c++" "$t-libstdc++-devel" >/dev/null 2>&1; then
    TOOLSET="$t"; break
  fi
  printf '::warning::%s 安装失败，尝试下一个候选\n' "$t"
done
[ -n "$TOOLSET" ] || die "候选 gcc-toolset（$TOOLSETS）全部装不上"
TOOLSET_ROOT="/opt/rh/$TOOLSET/root/usr"
export PATH="$TOOLSET_ROOT/bin:$PATH"
export CC=gcc CXX=g++
export CARGO_TARGET_AARCH64_UNKNOWN_LINUX_GNU_LINKER=gcc
echo "使用工具链：$TOOLSET"
gcc --version | head -n 1
g++ --version | head -n 1

# ── 3. bindgen 的 libclang ────────────────────────────────────────────────────
section "定位 libclang（bindgen 需要）"
LIBCLANG="$(ldconfig -p 2>/dev/null | grep -oE '/[^ ]*libclang\.so[^ ]*' | head -n 1 || true)"
if [ -n "$LIBCLANG" ]; then
  export LIBCLANG_PATH="$(dirname "$LIBCLANG")"
  echo "LIBCLANG_PATH=$LIBCLANG_PATH"
  ls -l "$LIBCLANG"
else
  printf '::warning::ldconfig 里没有 libclang.so*；bindgen 可能找不到 libclang\n'
fi

# ── 4. 让 -lstdc++ 绑定到静态归档 ─────────────────────────────────────────────
section "libstdc++ 静态化（消除 GLIBCXX_* 运行期依赖）"
STATIC_LIB="$(gcc -print-file-name=libstdc++.a)"
if [ "$STATIC_LIB" = "libstdc++.a" ] || [ ! -f "$STATIC_LIB" ]; then
  die "找不到 libstdc++.a（gcc 报 $STATIC_LIB）—— 无法静态链接，产物会索要 GLIBCXX_3.4.28+ 而麒麟 V10 只有 $GLIBCXX_BASELINE"
fi
STATIC_LIBDIR="$(dirname "$STATIC_LIB")"
echo "静态归档：$STATIC_LIB"
LSZ=$(stat -c %s "$STATIC_LIB"); echo "大小：$LSZ 字节"
[ "$LSZ" -gt 100000 ] || die "libstdc++.a 太小（$LSZ 字节），不像是真的静态归档"

# 移开所有会把 -lstdc++ 解析到共享库的 linker script / 符号链接，让 ld 落到 .a
for p in "$STATIC_LIBDIR/libstdc++.so" \
         /usr/lib64/libstdc++.so \
         /usr/lib/libstdc++.so \
         /usr/lib/gcc/aarch64-redhat-linux/*/libstdc++.so; do
  if [ -e "$p" ]; then
    mv -v "$p" "$p.disabled-for-static-link"
  fi
done
echo "剩余的 libstdc++ 候选（应只剩 .a）："
find /opt/rh /usr/lib /usr/lib64 /usr/lib/gcc -maxdepth 6 -name 'libstdc++.*' 2>/dev/null | head -20

# ── 5. Rust ──────────────────────────────────────────────────────────────────
section "安装 Rust（$TOOLCHAIN）"
export RUSTUP_HOME=/opt/rustup
export CARGO_HOME=/opt/cargo
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs -o /tmp/rustup-init.sh
sh /tmp/rustup-init.sh -y --profile minimal --no-modify-path --default-toolchain "$TOOLCHAIN"
export PATH="$CARGO_HOME/bin:$PATH"
rustc --version | tee "$OUT/rustc-version.txt"
cargo --version

# ── 6. 构建 ──────────────────────────────────────────────────────────────────
section "构建 $TARGET（features: $FEATURES）"
cd /src

# --locked 优先：产物必须与仓库提交的 Cargo.lock 一致 —— 下游按 sha256 登记供应链锁，
# 版本漂移会直接对不上账。若 lock 与 Cargo.toml 不同步，cargo 会在**编译开始之前**
# 立刻失败，所以退化为不加 --locked 重试几乎不额外花时间，同时把这件事记进 build.env。
LOCKED=yes
if ! cargo build --release --locked --features "$FEATURES" --target "$TARGET"; then
  printf '\n::warning::`--locked` 构建失败 —— Cargo.lock 可能与 Cargo.toml 不同步；改为不加 --locked 重试\n'
  LOCKED=no
  cargo build --release --features "$FEATURES" --target "$TARGET"
fi

BIN="/src/target/$TARGET/release/open-ontologies"
[ -x "$BIN" ] || die "未找到可执行产物：$BIN"

# ── 7. 架构、动态依赖、ABI 需求 ───────────────────────────────────────────────
section "产物架构与动态依赖"
file "$BIN"
readelf -h "$BIN" | grep -E 'Class:|Machine:|Type:'
if ! readelf -h "$BIN" | grep -q 'AArch64'; then
  die "产物不是 AArch64 —— 目标三元组或运行器架构不对"
fi
ls -l "$BIN"

ldd "$BIN" > "$OUT/ldd.txt" 2>&1 || true
cat "$OUT/ldd.txt"
if grep -q 'not found' "$OUT/ldd.txt"; then
  die "存在无法解析的动态库（见上），产物到目标机会起不来"
fi

readelf -d "$BIN" | grep -E 'NEEDED|RPATH|RUNPATH' > "$OUT/needed-libs.txt" 2>&1 || true
echo "--- 动态段 NEEDED/RPATH ---"
cat "$OUT/needed-libs.txt"

section "ABI 需求判定（对麒麟的兼容性）"
# 读产物自己的版本需求表（.gnu.version_r），而不是猜。这是「能不能在麒麟上加载」的
# 机器判据。
readelf --version-info "$BIN" 2>/dev/null \
  | grep -oE 'GLIBC(XX)?_[0-9]+(\.[0-9]+)*' \
  | sort -uV > "$OUT/required-glibc-symbols.txt" || true
cat "$OUT/required-glibc-symbols.txt"
[ -s "$OUT/required-glibc-symbols.txt" ] \
  || die "未能从产物读出符号版本需求（readelf 输出格式可能变了）"

MAX_GLIBC=$(grep -oE 'GLIBC_[0-9]+(\.[0-9]+)*' "$OUT/required-glibc-symbols.txt" \
            | sed 's/^GLIBC_//' | sort -V | tail -n 1)
[ -n "$MAX_GLIBC" ] || die "未能解析出 GLIBC 版本号"
echo "产物最高要求：GLIBC_$MAX_GLIBC　（麒麟 V10 基线 GLIBC_$BASELINE）"
NEWEST=$(printf '%s\n%s\n' "$MAX_GLIBC" "$BASELINE" | sort -V | tail -n 1)
if [ "$NEWEST" != "$BASELINE" ]; then
  die "产物要求 GLIBC_$MAX_GLIBC，高于麒麟 V10 的 GLIBC_$BASELINE —— 目标机会报 version 'GLIBC_$MAX_GLIBC' not found"
fi

# libstdc++：期望整类消失（静态链接成功）。若仍在，至少要 <= 基线。
MAX_GLIBCXX=$(grep -oE 'GLIBCXX_[0-9]+(\.[0-9]+)*' "$OUT/required-glibc-symbols.txt" \
              | sed 's/^GLIBCXX_//' | sort -V | tail -n 1 || true)
if [ -z "$MAX_GLIBCXX" ]; then
  echo "✅ 无 GLIBCXX_* 需求 —— libstdc++ 已静态链接，目标机无需提供 libstdc++.so.6"
else
  NEWCXX=$(printf '%s\n%s\n' "$MAX_GLIBCXX" "$GLIBCXX_BASELINE" | sort -V | tail -n 1)
  if [ "$NEWCXX" != "$GLIBCXX_BASELINE" ]; then
    die "产物要求 GLIBCXX_$MAX_GLIBCXX，高于麒麟 V10 SP1 的 GLIBCXX_$GLIBCXX_BASELINE —— libstdc++ 静态化没生效"
  fi
  printf '::warning::libstdc++ 仍是动态链接（最高 GLIBCXX_%s，未超基线 %s）；目标机需提供 libstdc++.so.6\n' \
    "$MAX_GLIBCXX" "$GLIBCXX_BASELINE"
fi

if grep -q 'libstdc++.so' "$OUT/needed-libs.txt"; then
  printf '::warning::动态段仍引用 libstdc++.so —— 与上面无 GLIBCXX 需求并存说明它未被实际使用\n'
fi
if grep -q 'libssl\.so\|libcrypto\.so' "$OUT/needed-libs.txt"; then
  echo "注意：产物依赖 OpenSSL 共享库（麒麟 V10 自带 openssl 1.1.1，提供 libssl.so.1.1，正常）"
fi
echo "✅ 兼容性判定通过：glibc $BASELINE / GLIBCXX ${MAX_GLIBCXX:-无需求} 环境下可加载"

# ── 8. 功能冒烟（aarch64 原生执行）────────────────────────────────────────────
section "功能冒烟"
export OPEN_ONTOLOGIES_STORAGE_MODE=persistent
DATA=/tmp/oo-data
rm -rf "$DATA"; mkdir -p "$DATA"

# 刻意**不跑 `init`**：它建完库表后要去 HuggingFace 拉 embedding 模型，离网环境必然
# exit 1。手写最小 config 即可让 CLI 与 serve 正常工作（这也是本项目的离线形态）。
cat > "$DATA/config.toml" <<'CFG'
[storage]
mode = "persistent"

[imports]
follow_remote = false
CFG

cat > "$DATA/sat.ttl" <<'TTL'
@prefix owl:  <http://www.w3.org/2002/07/owl#> .
@prefix rdfs: <http://www.w3.org/2000/01/rdf-schema#> .
@prefix ex:   <http://example.org/satcom#> .

ex:Spacecraft    a owl:Class ; rdfs:label "航天器" .
ex:Satellite     a owl:Class ; rdfs:label "卫星" ; rdfs:subClassOf ex:Spacecraft .
ex:GroundStation a owl:Class ; rdfs:label "地面站" .
ex:hasDownlink   a owl:ObjectProperty ; rdfs:domain ex:Satellite ; rdfs:range ex:GroundStation .

ex:LEOSat a ex:Satellite ; rdfs:label "低轨卫星" ; ex:hasDownlink ex:GS01 .
ex:GS01   a ex:GroundStation ; rdfs:label "北京站" .
TTL

# 两个已实测的 CLI 事实（都与直觉不同，且直接决定这段脚本能不能跑通）：
#   · **没有 `--version` 参数** —— clap 未启用 version，写 `--version` 会被判未知参数。
#     版本证据改用 `--help` 与 `status` 返回的 version 字段。
#   · 推理要写 `reason --profile rdfs`，写 `reason rdfs` 会被判未知参数。
# 另：--data-dir / --no-connect 是全局选项，可放在子命令之前。
OO() { "$BIN" --data-dir "$DATA" --no-connect "$@"; }

OO --help > /dev/null
echo "✅ --help"

STATUS=$(OO status); echo "status: $STATUS"
SELF_REPORTED_VERSION=$(printf '%s' "$STATUS" | grep -oE '"version":"[^"]*"' | head -n 1 | cut -d'"' -f4 || true)
echo "二进制自报版本：${SELF_REPORTED_VERSION:-未知}"
echo "（上游已知自报值落后于 Cargo.toml —— 登记供应链锁请以 sha256 为凭据）"

LOADED=$(OO load "$DATA/sat.ttl"); echo "load: $LOADED"
if ! printf '%s' "$LOADED" | grep -q '"triples_loaded":15'; then
  die "load 结果不符预期：$LOADED"
fi

ST=$(OO stats); echo "stats: $ST"
if ! printf '%s' "$ST" | grep -q '"classes":3'; then
  die "stats 结果不符预期：$ST"
fi

Q=$(OO query "SELECT ?c WHERE { ?c a <http://www.w3.org/2002/07/owl#Class> }"); echo "query: $Q"
if ! printf '%s' "$Q" | grep -q 'Spacecraft'; then
  die "SPARQL 查询结果不符预期：$Q"
fi

R=$(OO reason --profile rdfs); echo "reason: $R"
if ! printf '%s' "$R" | grep -q '"inferred_count":1'; then
  die "rdfs 推理结果不符预期：$R"
fi

D=$(OO defects "$DATA/sat.ttl"); echo "defects: $D"
if ! printf '%s' "$D" | grep -q '"defect_count":0'; then
  die "defects 结果不符预期：$D"
fi
echo "✅ CLI 链路（status/load/stats/query/reason/defects）通过"

# ── 9. MCP stdio 握手 ────────────────────────────────────────────────────────
section "MCP stdio 握手"
# 这一步是「能否被当作标准 MCP server 集成」的核心证据：能被打包路径 spawn 起来、
# 完成 initialize 并列出工具，才谈得上接进 DSH 的插件体系。
cat > /tmp/mcp-request.jsonl <<'REQ'
{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"ci-probe","version":"1"}}}
{"jsonrpc":"2.0","method":"notifications/initialized"}
{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}
REQ

# serve 用「选项跟在子命令后面」的写法（已实测），与上面的全局选项写法区分开。
run_serve() {
  timeout 90 "$BIN" serve --data-dir "$DATA" --no-connect "$@" \
    < /tmp/mcp-request.jsonl 2>/dev/null || true
}

run_serve > /tmp/mcp.jsonl
TOOLS_LINE=$(grep '"tools"' /tmp/mcp.jsonl | tail -n 1 || true)
TOOL_COUNT=$(printf '%s' "$TOOLS_LINE" | grep -o '"inputSchema"' | wc -l)
TOOL_COUNT=$((TOOL_COUNT))
echo "MCP 工具总数：$TOOL_COUNT"
if [ "$TOOL_COUNT" -lt 100 ]; then
  head -c 600 /tmp/mcp.jsonl || true
  die "MCP tools/list 只返回 $TOOL_COUNT 个工具，握手可能失败"
fi

run_serve --tools-allow '@read_only' > /tmp/mcp-ro.jsonl
RO_LINE=$(grep '"tools"' /tmp/mcp-ro.jsonl | tail -n 1 || true)
RO_TOOL_COUNT=$(printf '%s' "$RO_LINE" | grep -o '"inputSchema"' | wc -l)
RO_TOOL_COUNT=$((RO_TOOL_COUNT))
echo "MCP @read_only 工具数：$RO_TOOL_COUNT"
if [ "$RO_TOOL_COUNT" -lt 1 ]; then
  die "@read_only 分组过滤未生效（预期收敛到只读子集）"
fi

grep -o '"serverInfo":{[^}]*}' /tmp/mcp.jsonl | head -n 1 || true
echo "✅ MCP 协议握手通过"

# ── 10. 产物落地与校验和 ──────────────────────────────────────────────────────
section "产物落地与校验和"
cp "$BIN" "$OUT/$ASSET"
chmod 0755 "$OUT/$ASSET"

SHA256=$(sha256sum "$OUT/$ASSET" | cut -d' ' -f1)
BYTES=$(stat -c %s "$OUT/$ASSET")
printf '%s  %s\n' "$SHA256" "$ASSET" > "$OUT/SHA256SUMS.txt"
printf '%s\n' "$SHA256" > "$OUT/$ASSET.sha256"
sha256sum /src/Cargo.lock | cut -d' ' -f1 > "$OUT/cargo-lock.sha256"

cat "$OUT/SHA256SUMS.txt"
awk -v b="$BYTES" 'BEGIN{printf "size: %d bytes (%.1f MiB)\n", b, b/1048576}'

if [ "$LOCKED" != yes ]; then
  printf '::warning::本次构建未使用 --locked，Cargo.lock 可能已被 cargo 改写；产物与仓库提交的 lock 不必然一致\n'
fi

{
  echo "LOCKED=$LOCKED"
  echo "TOOLSET=$TOOLSET"
  echo "SHA256=$SHA256"
  echo "BYTES=$BYTES"
  echo "TOOL_COUNT=$TOOL_COUNT"
  echo "RO_TOOL_COUNT=$RO_TOOL_COUNT"
  echo "MAX_GLIBC=$MAX_GLIBC"
  echo "MAX_GLIBCXX=${MAX_GLIBCXX:-none}"
  echo "SELF_REPORTED_VERSION=$SELF_REPORTED_VERSION"
  echo "RUSTC=$(rustc --version)"
  echo "CARGO=$(cargo --version)"
  echo "GCC=$(gcc --version | head -n 1)"
  echo "CONTAINER_GLIBC=$(ldd --version | head -n 1)"
} > "$OUT/build.env"
cat "$OUT/build.env"

section "完成"
ls -l "$OUT"
