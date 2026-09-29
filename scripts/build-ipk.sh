#!/bin/bash
# ---------------------------------------------------------------------------
# hebing OpenWrt AMD64 (x86_64) .ipk 打包脚本
#
# 借鉴自 https://github.com/tianlmm/fn-knock-turborepo 的 build-openwrt-ipk.sh
# 大幅精简：只保留 x86_64 架构、只产出 tar 格式 .ipk、不做交叉编译。
#
# 用法：
#   1. 把你的 x86_64 Linux ELF 二进制放到 dist/bin/（默认会打包所有文件）
#   2. 运行: bash scripts/build-ipk.sh
#   3. 产出: dist/openwrt/hebing_<版本>-<release>_x86_64.ipk
#
# 可调环境变量：
#   APP_NAME        包名，默认 hebing
#   VERSION         应用版本，默认 0.1.0
#   RELEASE         包 release 号，默认 1
#   DEPENDS         opkg 依赖，默认 "libc, bash, curl, ca-bundle"
#   MAINTAINER      维护者信息
#   HOMEPAGE        项目主页
#   LICENSE         许可证
#   ARCH            OpenWrt 架构名，默认 x86_64（AMD64）
#   BIN_DIR         要打包的二进制目录，默认 dist/bin
#   UI_DIR          可选的前端静态资源目录，会打包到 /usr/lib/$APP_NAME/ui/
#   OUTPUT_DIR      输出目录，默认 dist/openwrt
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

APP_NAME="${APP_NAME:-hebing}"
VERSION="${VERSION:-0.1.0}"
RELEASE="${RELEASE:-1}"
DEPENDS="${DEPENDS:-libc, bash, curl, ca-bundle}"
MAINTAINER="${MAINTAINER:-Your Name <you@example.com>}"
HOMEPAGE="${HOMEPAGE:-https://github.com/tianlmm/hebing}"
LICENSE="${LICENSE:-MIT}"
ARCH="${ARCH:-x86_64}"
# ipk 容器格式: ar (传统格式, opkg 全版本兼容) 或 tar (新版 opkg 支持)
IPK_FORMAT="${IPK_FORMAT:-ar}"
BIN_DIR="${BIN_DIR:-${ROOT_DIR}/dist/bin}"
UI_DIR="${UI_DIR:-}"
OUTPUT_DIR="${OUTPUT_DIR:-${ROOT_DIR}/dist/openwrt}"
TEMPLATE_DIR="${ROOT_DIR}/deploy/openwrt"
WORK_DIR="${OUTPUT_DIR}/work"

log()  { echo "[hebing-ipk] $*"; }
fail() { echo "[hebing-ipk] ERROR: $*" >&2; exit 1; }

# --- tar 兼容性（macOS 用 bsdtar）---
configure_tar() {
	local tv
	tv="$(tar --version 2>&1 | tr '[:upper:]' '[:lower:]')"
	case "${tv}" in
		*bsdtar*|*libarchive*)
			TAR_FLAVOR="bsd"
			TAR_OWNER=(--uid 0 --gid 0 --uname root --gname root) ;;
		*gnu\ tar*)
			TAR_FLAVOR="gnu"
			TAR_OWNER=(--owner=0 --group=0 --numeric-owner --sort=name) ;;
		*)
			fail "不支持的 tar 实现（需要 GNU tar 或 bsdtar）" ;;
	esac
}

require_cmd() {
	command -v "$1" >/dev/null 2>&1 || fail "缺少必需命令: $1"
}

# --- 校验架构 ---
[ "${ARCH}" = "x86_64" ] || fail "当前脚手架只支持 x86_64 (AMD64)，收到 ARCH=${ARCH}"

# --- 校验二进制是 x86_64 ELF ---
validate_amd64_elf() {
	local bin="$1"
	local info
	info="$(file -b "${bin}")"
	printf '%s\n' "${info}" | grep -Eq 'ELF 64-bit LSB.*x86-64' || \
		fail "二进制不是 Linux x86_64 ELF: ${bin} —— ${info}"
}

# --- 组装 control.tar.gz ---
write_control() {
	local control_dir="$1"
	local installed_size="$2"

	mkdir -p "${control_dir}"

	cat > "${control_dir}/control" <<EOF
Package: ${APP_NAME}
Version: ${VERSION}-${RELEASE}
Architecture: ${ARCH}
Maintainer: ${MAINTAINER}
Section: net
Priority: optional
Depends: ${DEPENDS}
Homepage: ${HOMEPAGE}
License: ${LICENSE}
Installed-Size: ${installed_size}
Description: ${APP_NAME} OpenWrt package
  双网关统一域名相关的 OpenWrt 服务包
EOF

	# conffiles：标记哪些文件是用户可修改的配置
	printf '%s\n' "/etc/config/${APP_NAME}" > "${control_dir}/conffiles"

	# 生命周期脚本从模板目录 rsync 过来
	if [ -d "${TEMPLATE_DIR}/control" ]; then
		rsync -a "${TEMPLATE_DIR}/control/" "${control_dir}/"
		# 删除示例文件，打包时不需要
		rm -f "${control_dir}/control.example"
		chmod 755 "${control_dir}/postinst" "${control_dir}/prerm" "${control_dir}/postrm" 2>/dev/null || true
	fi
}

# --- 组装 data.tar.gz ---
assemble_data_dir() {
	local data_dir="$1"
	local app_root="${data_dir}/usr/lib/${APP_NAME}"

	mkdir -p \
		"${app_root}/bin" \
		"${data_dir}/etc/config" \
		"${data_dir}/etc/init.d" \
		"${data_dir}/usr/bin" \
		"${data_dir}/usr/libexec"

	# 模板里的 etc/、usr/、www/ 全量复制（如果存在）
	for sub in etc usr www; do
		if [ -d "${TEMPLATE_DIR}/${sub}" ]; then
			rsync -a "${TEMPLATE_DIR}/${sub}/" "${data_dir}/${sub}/"
		fi
	done

	# 可执行权限（fn-knock 里的惯例，抄过来）
	chmod 755 \
		"${data_dir}/etc/init.d/${APP_NAME}" \
		"${data_dir}/usr/bin/"* 2>/dev/null || true
	chmod 755 "${data_dir}/usr/libexec/"* 2>/dev/null || true

	# 复制用户自己的二进制
	if [ -d "${BIN_DIR}" ]; then
		local count=0
		for f in "${BIN_DIR}"/*; do
			[ -f "${f}" ] || continue
			validate_amd64_elf "${f}"
			cp "${f}" "${app_root}/bin/"
			chmod 755 "${app_root}/bin/$(basename "${f}")"
			count=$((count + 1))
		done
		log "已从 ${BIN_DIR} 打包 ${count} 个二进制到 ${app_root}/bin/"
	else
		log "警告: BIN_DIR=${BIN_DIR} 不存在，.ipk 将不包含任何用户二进制"
	fi

	# 可选的 UI 静态资源
	if [ -n "${UI_DIR}" ] && [ -d "${UI_DIR}" ]; then
		mkdir -p "${app_root}/ui"
		rsync -a "${UI_DIR}/" "${app_root}/ui/"
		log "已打包 UI 资源到 ${app_root}/ui/"
	fi

	# 创建软链，init.d 里引用 $app_home/bin/hebing 时更方便
	if [ -f "${app_root}/bin/${APP_NAME}" ]; then
		ln -s "../bin/${APP_NAME}" "${app_root}/${APP_NAME}"
	fi
}

# --- 校验 tar 里所有条目都是 root:root ---
validate_root_ownership() {
	local tarball="$1"
	local bad
	case "${TAR_FLAVOR}" in
		bsd)
			bad="$(tar -tvzf "${tarball}" | awk '$3 != "root" || $4 != "root" { print }')" ;;
		gnu)
			bad="$(tar --numeric-owner -tvzf "${tarball}" | awk '$2 != "0/0" { print }')" ;;
		*)
			fail "tar 兼容性未配置" ;;
	esac
	[ -z "${bad}" ] || { printf '%s\n' "${bad}" >&2; fail "${tarball} 包含非 root 所有者条目"; }
}

# --- ar 容器 ipk 组装 ---
# OpenWrt 传统 .ipk 是 ar archive（debian-binary 是 magic），内部成员顺序：
#   1. debian-binary    → 文件 "2.0\n"
#   2. control.tar.gz    → control 元数据
#   3. data.tar.gz       → 文件内容
# 用 Python 辅助脚本生成，避免 shell 手工拼 ar header 时 printf escape 踩坑。
SCRIPT_DIR_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
build_ar_ipk_py="${SCRIPT_DIR_PY}/_build_ar_ipk.py"
create_ar_ipk() {
	local archive="$1" debian_binary="$2" control_tar="$3" data_tar="$4"
	require_cmd python3
	python3 "${build_ar_ipk_py}" "${archive}" "${debian_binary}" "${control_tar}" "${data_tar}"
}

# --- tar 容器 ipk 组装（新版 opkg 支持，旧版可能不认）---
create_tar_ipk() {
	local archive="$1" debian_binary="$2" control_tar="$3" data_tar="$4"

	COPYFILE_DISABLE=1 tar \
		"${TAR_OWNER[@]}" \
		--format=ustar \
		-czf "${archive}" \
		--owner=0 --group=0 --numeric-owner \
		-C "$(dirname "${debian_binary}")" \
		"$(basename "${debian_binary}")" \
		"$(basename "${data_tar}")" \
		"$(basename "${control_tar}")"
}

# --- 主流程 ---
main() {
	require_cmd tar
	require_cmd rsync
	require_cmd file
	configure_tar
	[ "${IPK_FORMAT}" = "tar" ] && require_cmd ar  # ar 格式不需要，我们手写

	rm -rf "${OUTPUT_DIR}"
	mkdir -p "${OUTPUT_DIR}" "${WORK_DIR}"

	local package_work_dir="${WORK_DIR}/package"
	local control_dir="${package_work_dir}/CONTROL"
	local data_dir="${package_work_dir}/data"
	local control_tar="${package_work_dir}/control.tar.gz"
	local data_tar="${package_work_dir}/data.tar.gz"
	local debian_binary="${package_work_dir}/debian-binary"
	local ipk_path="${OUTPUT_DIR}/${APP_NAME}_${VERSION}-${RELEASE}_${ARCH}.ipk"

	log "构建 .ipk: ${APP_NAME} v${VERSION}-${RELEASE} arch=${ARCH} format=${IPK_FORMAT}"

	mkdir -p "${control_dir}" "${data_dir}"

	assemble_data_dir "${data_dir}"
	local installed_size
	installed_size="$(du -sk "${data_dir}" | awk '{ print $1 }')"
	write_control "${control_dir}" "${installed_size}"

	printf '2.0\n' > "${debian_binary}"

	log "打包 control.tar.gz"
	COPYFILE_DISABLE=1 tar \
		"${TAR_OWNER[@]}" \
		--format=ustar \
		-czf "${control_tar}" \
		-C "${control_dir}" \
		.

	log "打包 data.tar.gz"
	COPYFILE_DISABLE=1 tar \
		"${TAR_OWNER[@]}" \
		--format=ustar \
		-czf "${data_tar}" \
		-C "${data_dir}" \
		.

	rm -f "${ipk_path}"
	case "${IPK_FORMAT}" in
		ar)  create_ar_ipk  "${ipk_path}" "${debian_binary}" "${control_tar}" "${data_tar}" ;;
		tar)  create_tar_ipk "${ipk_path}" "${debian_binary}" "${control_tar}" "${data_tar}" ;;
		*)    fail "无效 IPK_FORMAT: ${IPK_FORMAT}（支持 ar / tar）" ;;
	esac

	# --- 校验 .ipk 容器 ---
	log "校验 .ipk 容器格式"
	case "${IPK_FORMAT}" in
		ar)
			local magic
			magic="$(head -c 8 "${ipk_path}")"
			[ "${magic}" = "!<arch>" ] || fail ".ipk ar magic 不对 (前 8 字节应为 !<arch>\\n)"
			log "  ar magic OK"
			;;
		tar)
			local listing
			listing="$(tar -tzf "${ipk_path}" | sed -e 's#^\./##' -e '/^$/d' | sort)"
			local expected
			expected="$(printf 'debian-binary\ncontrol.tar.gz\ndata.tar.gz' | sort)"
			[ "${listing}" = "${expected}" ] || { printf '实际内容:\n%s\n期望内容:\n%s\n' "${listing}" "${expected}" >&2; fail ".ipk 内部结构不对"; }
			validate_root_ownership "${ipk_path}"
			;;
	esac

	# --- 解出 debian-binary / control.tar.gz / data.tar.gz ---
	local inspect_dir="${WORK_DIR}/inspect"
	rm -rf "${inspect_dir}" && mkdir -p "${inspect_dir}"
	case "${IPK_FORMAT}" in
		ar)  python3 "${SCRIPT_DIR_PY}/_extract_ar_ipk.py" "${ipk_path}" "${inspect_dir}" ;;
		tar)  tar -xzf "${ipk_path}" -C "${inspect_dir}" ;;
	esac

	# debian-binary
	local db_content
	db_content="$(tr -d '\n' < "${inspect_dir}/debian-binary")"
	[ "${db_content}" = "2.0" ] || fail "debian-binary 内容不对，应为 '2.0'，实际 '${db_content}'"
	log "  debian-binary = 2.0 OK"

	# control.tar.gz
	[ -f "${inspect_dir}/control.tar.gz" ] || fail "解不出 control.tar.gz"
	validate_root_ownership "${inspect_dir}/control.tar.gz"
	local ctrl
	ctrl="$(tar -xOzf "${inspect_dir}/control.tar.gz" ./control)"
	printf '%s\n' "${ctrl}" | grep -Fxq "Package: ${APP_NAME}"   || fail "control 缺少 Package"
	printf '%s\n' "${ctrl}" | grep -Fxq "Architecture: ${ARCH}"   || fail "control 缺少 Architecture"
	printf '%s\n' "${ctrl}" | grep -Fxq "Version: ${VERSION}-${RELEASE}" || fail "control 缺少 Version"

	# data.tar.gz
	[ -f "${inspect_dir}/data.tar.gz" ] || fail "解不出 data.tar.gz"
	validate_root_ownership "${inspect_dir}/data.tar.gz"
	log "校验 OK: ${ipk_path}"

	# data.tar.gz 内容完整性快速检查
	local data_listing
	data_listing="$(tar -tzf "${inspect_dir}/data.tar.gz" | sed -e 's#^\./##' -e '/^$/d')"
	grep -Fqx "etc/config/${APP_NAME}" <<<"${data_listing}" || fail "data 缺少 etc/config/${APP_NAME}"
	grep -Fqx "etc/init.d/${APP_NAME}" <<<"${data_listing}" || fail "data 缺少 etc/init.d/${APP_NAME}"

	local bytes
	bytes="$(wc -c < "${ipk_path}" | tr -d '[:space:]')"
	log "构建完成: ${ipk_path} ($(awk -v b="${bytes}" 'BEGIN{printf "%.1f MiB", b/1048576}'))"
}

main "$@"
