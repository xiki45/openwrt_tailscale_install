#!/bin/sh
#
# openwrt_tailscale_install.sh
# OpenWrt / 小米路由器 Tailscale 一键安装与增量更新脚本
#
# 三件事:
#   1) 平台识别   读 /etc/openwrt_release、uname -m、ELF 字节序，自动映射到官方静态包架构
#   2) 依赖补齐   缺什么补什么: https 抓取能力 (libustream-* + ca-bundle)、tun 设备 (kmod-tun)
#   3) 安装/更新  与 pkgs.tailscale.com 最新版比对，sha256 校验后安装/更新，并落 procd 服务
#
# 用法: sh openwrt_tailscale_install.sh [选项]
#   -h, --help         显示帮助
#   -a, --arch ARCH    强制架构 (386|amd64|arm|arm64|geode|mips|mipsle|mips64|mips64le|riscv64)
#   -v, --version VER  安装指定版本，例如 1.102.4
#   -u, --unstable     使用 unstable 通道 (默认 stable)
#   -f, --force        已是最新也强制重装
#   -t, --tmp          强制 /tmp 模式 (二进制放 tmpfs，重启由 init 脚本从持久化目录恢复)
#   -d, --dir DIR      /tmp 模式的持久化目录 (默认依次尝试 /data /userdisk /root /etc)
#   -p, --prefix DIR   路径前缀，测试/chroot 用 (默认空)
#   -n, --no-deps      跳过依赖补齐
#       --userspace    改用 --tun=userspace-networking (无 tun 时只能这样组网，不能做子网路由/出口节点)
#
# 退出码: 0 成功 (含"已是最新")，1 失败

MARKER="# managed by openwrt_tailscale_install.sh"
PKG_HOST="https://pkgs.tailscale.com"

ARCH_OVERRIDE=""
VERSION_OVERRIDE=""
CHANNEL="stable"
FORCE=0
TMP_MODE="auto"
PERSIST_OVERRIDE=""
PREFIX=""
SKIP_DEPS=0
USERSPACE=0

# 两个二进制约 30MB + 36MB，tgz 约 35MB: 解包暂存需 ~130MB，最终落盘需 ~90MB
STAGE_NEED_KB=140000
FINAL_NEED_KB=90000

# 进度走 stderr: 保证 $(...) 里调用函数时返回值不被日志污染
STAGE=""
log()  { printf '%s\n' "$*"; }
info() { printf '[i] %s\n' "$*" >&2; }
warn() { printf '[!] %s\n' "$*" >&2; }
cleanup() { [ -n "$STAGE" ] && rm -rf "$STAGE"; STAGE=""; }
die()  { printf '[x] %s\n' "$*" >&2; cleanup; exit 1; }

usage() {
	cat <<'EOF'
OpenWrt / 小米路由器 Tailscale 一键安装与更新脚本

用法: sh openwrt_tailscale_install.sh [选项]
  -h, --help         显示帮助
  -a, --arch ARCH    强制架构 (386|amd64|arm|arm64|geode|mips|mipsle|mips64|mips64le|riscv64)
  -v, --version VER  安装指定版本，例如 1.102.4
  -u, --unstable     使用 unstable 通道 (默认 stable)
  -f, --force        已是最新也强制重装
  -t, --tmp          强制 /tmp 模式 (二进制放 tmpfs，重启由 init 脚本从持久化目录恢复)
  -d, --dir DIR      /tmp 模式的持久化目录 (默认依次尝试 /data /userdisk /root /etc)
  -p, --prefix DIR   路径前缀，测试/chroot 用 (默认空)
  -n, --no-deps      跳过依赖补齐
      --userspace    改用 --tun=userspace-networking (无 tun 时的兜底)

不带参数即: 自动识别平台 -> 补齐 ipk 依赖 -> 安装/更新到最新版。
EOF
}

# ---------------------------------------------------------------- 参数解析
while [ $# -gt 0 ]; do
	case "$1" in
		-h|--help)    usage; exit 0 ;;
		-a|--arch)    ARCH_OVERRIDE="$2"; shift 2 ;;
		-v|--version) VERSION_OVERRIDE="$2"; shift 2 ;;
		-u|--unstable) CHANNEL="unstable"; shift ;;
		-f|--force)   FORCE=1; shift ;;
		-t|--tmp)     TMP_MODE="yes"; shift ;;
		-d|--dir)     TMP_MODE="yes"; PERSIST_OVERRIDE="$2"; shift 2 ;;
		-p|--prefix)  PREFIX="$2"; shift 2 ;;
		-n|--no-deps) SKIP_DEPS=1; shift ;;
		--userspace)  USERSPACE=1; shift ;;
		*)            die "未知参数: $1 (试试 --help)" ;;
	esac
done

case "$ARCH_OVERRIDE" in
	""|386|amd64|arm|arm64|geode|mips|mipsle|mips64|mips64le|riscv64) ;;
	*) die "不支持的架构: $ARCH_OVERRIDE" ;;
esac
[ -z "$PREFIX" ] || [ -d "$PREFIX" ] || die "前缀目录不存在: $PREFIX"

REL_FILE="$PREFIX/etc/openwrt_release"
INIT_SCRIPT="$PREFIX/etc/init.d/tailscale"
RC_DIR="$PREFIX/etc/rc.d"
BIN_SBIN="$PREFIX/usr/sbin"
BIN_BIN="$PREFIX/usr/bin"
TMPFS_DIR="$PREFIX/tmp"
OPKG_DIR="$PREFIX/etc/opkg"
PKG_HOST_DL="https://downloads.openwrt.org"
INDEX_FILE="$TMPFS_DIR/.ts_index.$CHANNEL.html"

mkdir -p "$TMPFS_DIR" 2>/dev/null

# ---------------------------------------------------------------- 抓取工具
# OpenWrt 上通常是 uclient-fetch 或 busybox wget；https 需要 libustream + ca-bundle
DOWNLOADER=""
detect_downloader() {
	for c in uclient-fetch wget curl; do
		if command -v "$c" >/dev/null 2>&1; then DOWNLOADER="$c"; return 0; fi
	done
	DOWNLOADER=""
	return 1
}
detect_downloader || true

fetch() { # fetch <url> <outfile>
	[ -n "$DOWNLOADER" ] || return 1
	case "$DOWNLOADER" in
		uclient-fetch) uclient-fetch -q -O "$2" "$1" >/dev/null 2>&1 ;;
		wget)          wget -q -O "$2" "$1" >/dev/null 2>&1 ;;
		curl)          curl -fsSL -o "$2" "$1" >/dev/null 2>&1 ;;
	esac
}

fetch_retry() { # fetch_retry <url> <outfile> [retries]
	_r="${3:-3}"
	while [ "$_r" -gt 0 ]; do
		fetch "$1" "$2" && return 0
		_r=$((_r - 1))
		[ "$_r" -gt 0 ] && { warn "下载失败, 重试中 (剩余 $_r 次): $1"; sleep 5; }
	done
	return 1
}

free_kb() { df -Pk "$1" 2>/dev/null | awk 'NR==2 {print $4}'; }

pick_dir() { # pick_dir <需要KB> <候选目录...> -> 打印首个满足的目录
	_need="$1"; shift
	for _d in "$@"; do
		[ -d "$_d" ] && [ -w "$_d" ] || continue
		_f=$(free_kb "$_d")
		[ -n "$_f" ] || continue
		if [ "$_f" -ge "$_need" ]; then printf '%s' "$_d"; return 0; fi
		info "空间不足跳过 $_d (剩余 $((_f / 1024))MB < $((_need / 1024))MB)"
	done
	return 1
}

# 官方版本列表页: 抓一次缓存复用 (https 能力探测 + 版本提取共用)
refresh_index() {
	[ -s "$INDEX_FILE" ] && return 0
	fetch "$PKG_HOST/$CHANNEL/" "$INDEX_FILE" || { rm -f "$INDEX_FILE"; return 1; }
	grep -q 'tailscale_[0-9]' "$INDEX_FILE" || { rm -f "$INDEX_FILE"; return 1; }
	return 0
}

# ---------------------------------------------------------------- 1. 平台识别
DISTRO_ID=""; DISTRO_REL=""; DISTRO_ARCH=""; DISTRO_TARGET=""
if [ -r "$REL_FILE" ]; then
	# shellcheck disable=SC1090
	. "$REL_FILE"
	DISTRO_ID="$DISTRIB_ID"; DISTRO_REL="$DISTRIB_RELEASE"
	DISTRO_ARCH="$DISTRIB_ARCH"; DISTRO_TARGET="$DISTRIB_TARGET"
fi

elf_endian() { # ELF 头偏移 5 为 EI_DATA: 1=小端 2=大端
	[ -r "$1" ] || { printf '?'; return; }
	_e=$(od -An -j5 -N1 -tu1 "$1" 2>/dev/null | tr -d ' \n')
	case "$_e" in
		1) printf 'le' ;;
		2) printf 'be' ;;
		*) printf '?' ;;
	esac
}

# OpenWrt 的 DISTRIB_ARCH 最可靠 (uname -m 在大端/小端 MIPS 上都报 mips)，其次 uname + 字节序
detect_arch() {
	case "$DISTRO_ARCH" in
		x86_64)                      printf 'amd64'; return 0 ;;
		i386_*|i486_*|i586_*|i686_*) printf '386';   return 0 ;;
		geode)                       printf 'geode'; return 0 ;;
		aarch64*|arm64*)             printf 'arm64'; return 0 ;;
		arm_*|armv*)                 printf 'arm';   return 0 ;;
		mipsel*)                     printf 'mipsle';   return 0 ;;
		mips64el*|mips64le*)         printf 'mips64le'; return 0 ;;
		mips64*)                     printf 'mips64';   return 0 ;;
		mips*)                       printf 'mips';     return 0 ;;
		riscv64*)                    printf 'riscv64';  return 0 ;;
	esac
	_m=$(uname -m 2>/dev/null)
	case "$_m" in
		x86_64|amd64)        printf 'amd64'; return 0 ;;
		i386|i486|i586|i686) printf '386';   return 0 ;;
		aarch64|arm64)       printf 'arm64'; return 0 ;;
		armv*|arm)           printf 'arm';   return 0 ;;
		riscv64)             printf 'riscv64'; return 0 ;;
		mips|mips64)
			for _b in /bin/busybox /bin/sh /usr/bin/env; do
				case "$(elf_endian "$_b")" in
					le) [ "$_m" = "mips64" ] && printf 'mips64le' || printf 'mipsle'; return 0 ;;
					be) printf '%s' "$_m"; return 0 ;;
				esac
			done
			# 字节序判不出来时按大端算 (ath79 等常见大端 MIPS)，可用 --arch 覆盖
			printf '%s' "$_m"
			return 0 ;;
	esac
	return 1
}

if [ -n "$ARCH_OVERRIDE" ]; then
	ARCH="$ARCH_OVERRIDE"
	info "架构: $ARCH (手动指定)"
else
	ARCH=$(detect_arch) || die "无法识别平台架构，请用 --arch 手动指定"
	info "架构: $ARCH (uname -m=$(uname -m), DISTRIB_ARCH=${DISTRO_ARCH:-无})"
fi

if [ -n "$DISTRO_REL" ]; then
	info "系统: ${DISTRO_ID:-unknown} ${DISTRO_REL}${DISTRO_TARGET:+ / $DISTRO_TARGET}${DISTRO_ARCH:+ / $DISTRO_ARCH}"
else
	warn "未找到 $REL_FILE，按通用 Linux 处理"
fi

# /etc 必须可写且能扛过重启: 服务文件 /etc/init.d/tailscale、自启链 /etc/rc.d/S99tailscale、
# tailscaled 状态 /etc/config/tailscaled.state 与 /etc/tailscale/ 都在这里。
# 小米原厂固件不挂 overlayfs 时 /etc 是只读的，这里提前卡住，避免"下了 35MB 才发现写不进"。
# 注意: 用真实写入探测，root 下 [ -w ] 对只读文件系统也会返回真。
probe_writable() { # probe_writable <目录>
	[ -d "$1" ] || return 1
	_t="$1/.ts_probe.$$"
	(umask 077; : > "$_t") 2>/dev/null || return 1
	rm -f "$_t" 2>/dev/null
	return 0
}

for _d in "$PREFIX/etc" "$PREFIX/etc/init.d" "$PREFIX/etc/rc.d" "$PREFIX/etc/config"; do
	[ -d "$_d" ] || mkdir -p "$_d" 2>/dev/null
	if probe_writable "$_d"; then continue; fi
	warn "/etc 不可写: $_d"
	die "安装需要可写且持久的 /etc (服务文件 /etc/init.d/tailscale、自启链接 /etc/rc.d/S99tailscale、状态 /etc/config/tailscaled.state 都放这里)。
    小米路由器请先按 README 挂载 overlayfs (mount --bind /data/overlay /overlay + fopivot)，使 /etc 可写后再重跑本脚本；
    普通 OpenWrt 若 /etc 只读，说明根文件系统是 squashfs 且 overlay 未启用，同样先解决挂载。"
done
info "前提检查: /etc 可写"

# ---------------------------------------------------------------- 2. 依赖补齐
# opkg list-installed 里名字带 ABI 后缀 (libustream-openssl20201210)，用前缀匹配
opkg_installed() {
	command -v opkg >/dev/null 2>&1 || return 1
	opkg list-installed 2>/dev/null | grep -q "^$1"
}

opkg_try() { # opkg_try <包名...> 逐个尝试，任一成功即满足 (这些是互相替代的候选)
	command -v opkg >/dev/null 2>&1 || return 1
	for _p in "$@"; do
		opkg_installed "$_p" && return 0
		info "安装依赖: $_p"
		opkg install "$_p" >/dev/null 2>&1 && return 0
		warn "软件源里装不上: $_p"
	done
	return 1
}

# 本地 ipk (用户事先放好的) 优先于联网拉取，但低于 opkg 源 (源里的 ABI 一定匹配)
LOCAL_IPK_DIRS="$(dirname "$0") $PREFIX/root $PREFIX/tmp $PREFIX/ipk $PREFIX/data $PREFIX/userdisk"

local_ipk() { # local_ipk <glob> -> 打印首个匹配的 ipk
	for _d in $LOCAL_IPK_DIRS; do
		for _f in "$_d"/$1; do
			[ -f "$_f" ] && { printf '%s' "$_f"; return 0; }
		done
	done
	return 1
}

feed_urls() {
	for _c in "$OPKG_DIR"/*.conf "$OPKG_DIR"/*.conf.d/*.conf; do
		[ -f "$_c" ] || continue
		sed -n 's|^[[:space:]]*src/[a-z0-9]*[[:space:]][A-Za-z0-9_.-]*[[:space:]]*\([^[:space:]]*\).*|\1|p' "$_c"
	done
	# 内核模块 (kmod-tun) 只在 targets/<target>/packages 这个 feed 里，按发行版信息补上
	if [ -n "$DISTRO_REL" ] && [ -n "$DISTRO_TARGET" ]; then
		printf '%s\n' "$PKG_HOST_DL/releases/$DISTRO_REL/targets/$DISTRO_TARGET/packages"
		printf '%s\n' "$PKG_HOST_DL/releases/$DISTRO_REL/packages/$DISTRO_ARCH/base"
	fi
}

gunzip_c() { gunzip -c "$1" 2>/dev/null || zcat "$1" 2>/dev/null; }

feed_fetch_ipk() { # feed_fetch_ipk <包名> <落地目录> -> 打印 ipk 路径
	_p="$1"; _out="$2"
	[ -n "$DOWNLOADER" ] || return 1
	for _u in $(feed_urls | sort -u); do
		_idx="$_out/.Packages.gz"
		fetch "$_u/Packages.gz" "$_idx" || continue
		_fn=$(gunzip_c "$_idx" | awk -v p="$_p" '
			/^Package: / { hit = ($2 == p) }
			hit && /^Filename: / { print $2; exit }')
		rm -f "$_idx"
		[ -n "$_fn" ] || continue
		info "从 feeds 取包: $_u/$_fn"
		fetch "$_u/$_fn" "$_out/$_p.ipk" && { printf '%s' "$_out/$_p.ipk"; return 0; }
	done
	return 1
}

ensure_any() { # ensure_any <描述> <候选包名...> 三者顺序: opkg 源 -> 本地 ipk -> 按 feed 索引拉 ipk
	_desc="$1"; shift
	for _p in "$@"; do opkg_installed "$_p" && return 0; done
	opkg_try "$@" && return 0
	if command -v opkg >/dev/null 2>&1; then
		for _p in "$@"; do
			if _f=$(local_ipk "${_p}*.ipk"); then
				info "使用本地 ipk: $_f"
				opkg install "$_f" >/dev/null 2>&1 && return 0
				warn "本地 ipk 装不上 (ABI 不匹配?): $_f"
			fi
			if _f=$(feed_fetch_ipk "$_p" "$TMPFS_DIR"); then
				opkg install "$_f" >/dev/null 2>&1 && return 0
				warn "下载的 ipk 装不上: $_f"
			fi
		done
	fi
	warn "依赖未补齐: $_desc"
	return 1
}

tun_ok() { # 实测能不能建 tuntap，而不是猜包在不在
	[ -c "$PREFIX/dev/net/tun" ] && return 0
	[ -n "$PREFIX" ] || { command -v modprobe >/dev/null 2>&1 && modprobe tun >/dev/null 2>&1; }
	if command -v ip >/dev/null 2>&1 && ip tuntap add dev tsprobe mode tun >/dev/null 2>&1; then
		ip link del tsprobe >/dev/null 2>&1
		return 0
	fi
	if [ ! -e "$PREFIX/dev/net/tun" ]; then
		mkdir -p "$PREFIX/dev/net" 2>/dev/null
		mknod "$PREFIX/dev/net/tun" c 10 200 >/dev/null 2>&1
		chmod 0600 "$PREFIX/dev/net/tun" >/dev/null 2>&1
	fi
	[ -c "$PREFIX/dev/net/tun" ]
}

if [ "$SKIP_DEPS" -eq 1 ]; then
	info "已跳过依赖补齐"
else
	if command -v opkg >/dev/null 2>&1; then
		opkg update >/dev/null 2>&1 || warn "opkg update 失败，改用已有索引继续"
	else
		warn "没有 opkg，跳过 ipk 依赖补齐"
	fi

	if refresh_index; then
		info "https 抓取能力: 就绪"
	elif ! command -v opkg >/dev/null 2>&1; then
		die "无法 https 访问 $PKG_HOST，且没有 opkg 可补依赖 (需要 uclient-fetch/wget/curl)，无法下载安装包"
	else
		warn "无法 https 访问 $PKG_HOST (OpenWrt 需要 libustream + ca-bundle)"
		# 三组独立需求: 抓取工具 / TLS 后端 (openSSL|wolfSSL|mbedTLS 三选一) / CA 证书包
		ensure_any "抓取工具" uclient-fetch wget-ssl curl || true
		detect_downloader
		ensure_any "TLS 后端 (libustream)" \
			libustream-openssl libustream-wolfssl libustream-mbedtls || true
		ensure_any "CA 证书包" ca-bundle ca-certificates ca-certs || true
		detect_downloader
		refresh_index || die "依赖补齐后仍无法 https 访问 $PKG_HOST。请手动 opkg install libustream-openssl ca-bundle，或把对应 ipk 放到 $TMPFS_DIR 后重试"
		info "https 抓取能力: 补齐后就绪 ($DOWNLOADER)"
	fi

	if tun_ok; then
		info "tun 设备: 就绪"
	else
		command -v opkg >/dev/null 2>&1 && { ensure_any "tun 内核模块 (kmod-tun)" kmod-tun || true; }
		if tun_ok; then
			info "tun 设备: 补齐后就绪"
		else
			warn "tun 不可用: 子网路由 (--advertise-routes) 与出口节点 (--advertise-exit-node) 会失效"
			warn "常见原因: 内核与该 feed 的 kmod-tun 版本不匹配 (自制固件/手动换过内核)，或该系统 tun 未内建"
			[ "$USERSPACE" -eq 1 ] || warn "只用于普通组网可加 --userspace 用 --tun=userspace-networking 兜底"
		fi
	fi

	if ! command -v nft >/dev/null 2>&1 && ! command -v iptables >/dev/null 2>&1; then
		warn "没有 nft/iptables: 子网路由与出口节点需要防火墙工具"
	fi
fi

# ---------------------------------------------------------------- 3. 版本比对
installed_version() {
	for _spec in "$BIN_BIN/tailscale:version" "$BIN_SBIN/tailscaled:--version"; do
		_p="${_spec%:*}"; _arg="${_spec##*:}"
		[ -x "$_p" ] || continue
		_v=$("$_p" "$_arg" 2>/dev/null | sed -n 's/[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)
		[ -n "$_v" ] && { printf '%s' "$_v"; return 0; }
	done
	return 1
}

# 该架构下官方列表里的最大版本号 (x.y.z 按 1000 进制比较)
latest_version() {
	sed -n "s/.*tailscale_\([0-9][0-9.]*\)_$ARCH\.tgz.*/\1/p" "$INDEX_FILE" 2>/dev/null \
		| awk -F. 'NF >= 3 { k = $1 * 1000000 + $2 * 1000 + $3; if (k > best) { best = k; v = $0 } } END { if (v) print v }'
}

ver_gt() { # ver_gt A B -> A > B
	awk -F. -v a="$1" -v b="$2" 'BEGIN {
		split(a, x, "."); split(b, y, ".");
		ka = x[1] * 1000000 + x[2] * 1000 + x[3];
		kb = y[1] * 1000000 + y[2] * 1000 + y[3];
		exit !(ka > kb) }'
}

if [ -n "$VERSION_OVERRIDE" ]; then
	VERSION="$VERSION_OVERRIDE"
	info "目标版本: $VERSION (手动指定)"
else
	refresh_index || die "拿不到 $CHANNEL 通道的版本列表 (检查网络，或改用 --version 指定版本)"
	VERSION=$(latest_version)
	[ -n "$VERSION" ] || die "取不到 $CHANNEL 通道 $ARCH 的最新版本号，请用 --version 指定"
	info "目标版本: $VERSION ($CHANNEL 通道最新)"
fi

CUR=$(installed_version) || CUR=""
if [ -n "$CUR" ] && [ "$CUR" = "$VERSION" ] && [ "$FORCE" -eq 0 ] && [ "$TMP_MODE" != "yes" ]; then
	log "已是最新版本 $CUR，无需更新。"
	exit 0
fi
if [ -n "$CUR" ] && [ "$FORCE" -eq 0 ] && ver_gt "$CUR" "$VERSION"; then
	die "本机版本 $CUR 高于目标版本 $VERSION，不做降级 (要降级加 --force)"
fi
if [ -n "$CUR" ]; then
	info "版本变化: $CUR -> $VERSION"
else
	info "本机版本: 未安装"
fi

# ---------------------------------------------------------------- 4. 暂存目录
STAGE=$(pick_dir "$STAGE_NEED_KB" "$TMPFS_DIR" "$PREFIX/data" "$PREFIX/userdisk" "$PREFIX/root" "$PREFIX/etc" "$PREFIX/overlay") \
	|| die "找不到剩余空间 >= $((STAGE_NEED_KB / 1024))MB 的目录解包 (可用 --dir 指定大分区目录)"
STAGE="$STAGE/.ts_install.$$"
mkdir -p "$STAGE" || die "无法创建暂存目录: $STAGE"
info "暂存目录: $STAGE"
trap 'cleanup; exit 1' INT TERM HUP

# ---------------------------------------------------------------- 5. 下载 + 校验 + 解包
TARBALL="tailscale_${VERSION}_${ARCH}.tgz"
URL="$PKG_HOST/$CHANNEL/$TARBALL"
info "下载 $URL"
fetch_retry "$URL" "$STAGE/$TARBALL" 3 || die "下载失败: $URL (检查 DNS/代理/空间)"

if command -v sha256sum >/dev/null 2>&1; then
	if fetch "$URL.sha256" "$STAGE/$TARBALL.sha256"; then
		_want=$(cut -c1-64 "$STAGE/$TARBALL.sha256" | tr -d ' \n\r')
		_got=$(sha256sum "$STAGE/$TARBALL" | cut -d' ' -f1)
		[ "$_want" = "$_got" ] || die "sha256 校验失败 (期望 $_want 实际 $_got)，已终止"
		info "sha256 校验通过"
	else
		warn "拿不到 .sha256，跳过校验"
	fi
else
	warn "没有 sha256sum，跳过校验"
fi

# 只取两个二进制，不解 systemd 目录，省空间
tar -C "$STAGE" -xzf "$STAGE/$TARBALL" \
	"tailscale_${VERSION}_${ARCH}/tailscale" "tailscale_${VERSION}_${ARCH}/tailscaled" \
	|| die "解包失败 (空间不足或包损坏)"
NEW_TS="$STAGE/tailscale_${VERSION}_${ARCH}/tailscale"
NEW_TD="$STAGE/tailscale_${VERSION}_${ARCH}/tailscaled"
[ -f "$NEW_TS" ] && [ -f "$NEW_TD" ] || die "包内缺少 tailscale/tailscaled"
chmod 0755 "$NEW_TS" "$NEW_TD"

# 冒烟测试: 真跑一下，架构选错/包损坏在这里就暴露，不会先删旧的
_smoke=$("$NEW_TS" --version 2>&1 | sed -n 's/[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)
[ -n "$_smoke" ] || die "新二进制在本机跑不起来 (架构 $ARCH 不匹配?)，未替换任何文件"
info "冒烟测试通过: tailscale $_smoke"

# ---------------------------------------------------------------- 6. 落盘
# 系统模式: 直接进 /usr/sbin + /usr/bin (持久化)
# /tmp 模式: 二进制进 tmpfs 再留一份持久化副本，由 init 脚本开机恢复 (小米路由器 overlay 小)
if [ "$TMP_MODE" = "auto" ]; then
	_free=$(free_kb "$BIN_SBIN")
	if [ -n "$_free" ] && [ "$_free" -ge "$FINAL_NEED_KB" ]; then
		TMP_MODE="no"
	else
		TMP_MODE="yes"
		warn "/usr 剩余空间不足 $((FINAL_NEED_KB / 1024))MB，自动切 /tmp 模式"
	fi
fi

if [ "$TMP_MODE" = "yes" ]; then
	if [ -n "$PERSIST_OVERRIDE" ]; then
		mkdir -p "$PERSIST_OVERRIDE" || die "无法创建持久化目录: $PERSIST_OVERRIDE"
		PERSIST="$PERSIST_OVERRIDE"
	else
		PERSIST=$(pick_dir "$FINAL_NEED_KB" "$PREFIX/data" "$PREFIX/userdisk" "$PREFIX/root" "$PREFIX/etc" "$PREFIX/overlay") \
			|| die "/tmp 模式需要一份持久化副本，但 /data /userdisk /root /etc 都放不下 (可用 --dir 指定)"
	fi
	[ "$PERSIST" = "$TMPFS_DIR" ] && die "持久化目录不能是 tmpfs: $PERSIST"
	TD_DIR="$TMPFS_DIR"; TS_DIR="$TMPFS_DIR"
	info "安装模式: /tmp 模式 (运行目录 $TMPFS_DIR，持久化副本 $PERSIST)"
else
	TD_DIR="$BIN_SBIN"; TS_DIR="$BIN_BIN"
	PERSIST=""
	info "安装模式: 系统模式 ($BIN_SBIN/tailscaled + $BIN_BIN/tailscale)"
fi

# 换文件前先停服务: 运行中的 tailscaled 会让旧的 tailscaled 二进制处于 busy 状态
if [ -x "$INIT_SCRIPT" ]; then
	"$INIT_SCRIPT" stop >/dev/null 2>&1 || true
fi
if command -v pidof >/dev/null 2>&1 && [ -n "$(pidof tailscaled 2>/dev/null)" ]; then
	warn "tailscaled 仍在运行，尝试直接结束进程"
	command -v killall >/dev/null 2>&1 && killall tailscaled >/dev/null 2>&1
	sleep 1
fi

mkdir -p "$TD_DIR" "$TS_DIR"
cp -f "$NEW_TD" "$TD_DIR/tailscaled" || die "写不进 $TD_DIR/tailscaled (服务还在跑? 先执行 $INIT_SCRIPT stop)"
cp -f "$NEW_TS" "$TS_DIR/tailscale"  || die "写不进 $TS_DIR/tailscale (服务还在跑? 先执行 $INIT_SCRIPT stop)"
chmod 0755 "$TD_DIR/tailscaled" "$TS_DIR/tailscale"

if [ -n "$PERSIST" ]; then
	cp -f "$NEW_TD" "$PERSIST/tailscaled" || die "写不进持久化副本 $PERSIST"
	cp -f "$NEW_TS" "$PERSIST/tailscale"  || die "写不进持久化副本 $PERSIST"
	chmod 0755 "$PERSIST/tailscaled" "$PERSIST/tailscale"
fi

# /tmp 模式下在 /usr/bin /usr/sbin 放软链，保证 PATH 里能直接敲 tailscale
if [ "$TD_DIR" = "$TMPFS_DIR" ]; then
	ln -sf "$TD_DIR/tailscaled" "$BIN_SBIN/tailscaled" 2>/dev/null || true
	ln -sf "$TS_DIR/tailscale"  "$BIN_BIN/tailscale"   2>/dev/null || true
fi

# ---------------------------------------------------------------- 7. procd 服务
TUN_LINE=""
[ "$USERSPACE" -eq 1 ] && TUN_LINE="
	# 无 tun 环境: 仅 userspace 组网，子网路由/出口节点不可用
	procd_append_param command --tun=userspace-networking"

write_init() {
	mkdir -p "${INIT_SCRIPT%/*}"
	cat > "$INIT_SCRIPT" <<EOF
#!/bin/sh /etc/rc.common

# Copyright 2020 Google LLC.
# SPDX-License-Identifier: Apache-2.0
$MARKER

USE_PROCD=1
START=99
STOP=1

BIN_DIR="$TD_DIR"
PERSIST_DIR="$PERSIST"

start_service() {
	if [ ! -x "\$BIN_DIR/tailscaled" ]; then
		# /tmp 模式: 重启后 tmpfs 清空，从持久化目录恢复二进制
		if [ -n "\$PERSIST_DIR" ] && [ -x "\$PERSIST_DIR/tailscaled" ]; then
			mkdir -p "\$BIN_DIR"
			cp "\$PERSIST_DIR/tailscaled" "\$PERSIST_DIR/tailscale" "\$BIN_DIR/"
			chmod 0755 "\$BIN_DIR/tailscaled" "\$BIN_DIR/tailscale"
			ln -sf "\$BIN_DIR/tailscale" "$BIN_BIN/tailscale"
			ln -sf "\$BIN_DIR/tailscaled" "$BIN_SBIN/tailscaled"
		else
			logger -t tailscale "tailscaled 二进制缺失: \$BIN_DIR/tailscaled"
			return 1
		fi
	fi

	procd_open_instance
	procd_set_param command "\$BIN_DIR/tailscaled"

	# Set the port to listen on for incoming VPN packets.
	# Remote nodes will automatically be informed about the new port number.
	procd_append_param command --port 41641

	# OpenWRT /var is a symlink to /tmp, so write persistent state elsewhere.
	procd_append_param command --state /etc/config/tailscaled.state

	# Persist files for TLS cert & Taildrop files
	procd_append_param command --statedir /etc/tailscale/$TUN_LINE

	procd_set_param respawn
	procd_set_param stdout 1
	procd_set_param stderr 1

	procd_close_instance
}

stop_service() {
	[ -x "\$BIN_DIR/tailscaled" ] && "\$BIN_DIR/tailscaled" --cleanup
}
EOF
	chmod 0755 "$INIT_SCRIPT"
}

if [ -f "$INIT_SCRIPT" ] && ! grep -qF "$MARKER" "$INIT_SCRIPT"; then
	cp -f "$INIT_SCRIPT" "$INIT_SCRIPT.bak"
	warn "原有 $INIT_SCRIPT 不是本脚本管的，已备份为 tailscale.bak"
fi
write_init
if [ ! -f "$INIT_SCRIPT" ] || ! grep -qF "$MARKER" "$INIT_SCRIPT" 2>/dev/null; then
	die "服务文件写入失败: $INIT_SCRIPT (检查 /etc/init.d 是否真的可写)"
fi
info "服务文件: $INIT_SCRIPT"

# ---------------------------------------------------------------- 8. 开机自启 + 启动
if [ -n "$PREFIX" ]; then
	mkdir -p "$RC_DIR"
	ln -sf "$INIT_SCRIPT" "$RC_DIR/S99tailscale" 2>/dev/null || true
	info "prefix 模式: 跳过 enable/启动"
elif "$INIT_SCRIPT" enable >/dev/null 2>&1; then
	if "$INIT_SCRIPT" restart >/dev/null 2>&1; then
		info "tailscaled 已启动"
	else
		warn "服务启动失败，检查: logread | grep tailscale"
	fi
else
	# 兜底: 个别固件的 rc.common enable 不落软链
	mkdir -p "$RC_DIR"
	ln -sf "$INIT_SCRIPT" "$RC_DIR/S99tailscale" 2>/dev/null || true
	warn "rc.common enable 未生效，已手工建 $RC_DIR/S99tailscale"
fi

if [ ! -L "$RC_DIR/S99tailscale" ]; then
	warn "开机自启链接未建立: $RC_DIR/S99tailscale"
	die "自启未生效，/etc 很可能不是可写的 overlayfs (小米路由器请先做 overlayfs 挂载)"
fi

# ---------------------------------------------------------------- 9. 后续提示
lan_cidr() {
	_c=$(ip -4 addr show br-lan 2>/dev/null | sed -n 's/.*inet \([0-9.]*\/[0-9]*\).*/\1/p' | head -1)
	[ -z "$_c" ] && _c=$(uci -q get network.lan.ipaddr 2>/dev/null)
	case "$_c" in
		*.*.*.*/24) printf '%s' "$(printf '%s' "$_c" | cut -d. -f1-3).0/24" ;;
		*)          printf '%s' "$_c" ;;
	esac
}
TS_CMD="tailscale"
[ "$TS_DIR" = "$BIN_BIN" ] || TS_CMD="$TS_DIR/tailscale"
ROUTES_ARGS=""
_cidr=$(lan_cidr)
[ -n "$_cidr" ] && ROUTES_ARGS="--advertise-routes=$_cidr "
[ "$CUR" = "$VERSION" ] && CHANGE="(已是最新)" || CHANGE="${CUR:-未安装} -> $VERSION"

log ""
log "完成: Tailscale $VERSION / 架构 $ARCH / $CHANGE"
log "登录组网: $TS_CMD up ${ROUTES_ARGS}--accept-routes --accept-dns=false"
log "查看状态: $TS_CMD status"
log "服务: $INIT_SCRIPT (已设开机自启 S99tailscale)"
cleanup
trap - INT TERM HUP
