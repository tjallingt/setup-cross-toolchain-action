#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
set -euo pipefail
IFS=$'\n\t'

x() {
    local cmd="$1"
    shift
    (
        set -x
        "${cmd}" "$@"
    )
}
retry() {
    for i in {1..10}; do
        if "$@"; then
            return 0
        else
            sleep "${i}"
        fi
    done
    "$@"
}
bail() {
    echo "::error::$*"
    exit 1
}
warn() {
    echo "::warning::$*"
}

export DEBIAN_FRONTEND=noninteractive
export CARGO_NET_RETRY=10
export RUSTUP_MAX_RETRIES=10

if [[ $# -gt 0 ]]; then
    bail "invalid argument '$1'"
fi

target="${INPUT_TARGET:?}"
runner="${INPUT_RUNNER:-}"

if [[ "${target}" == *"@"* ]]; then
    case "${target}" in
        *-freebsd* | *-netbsd*) ;;
        *) bail "versioned target triple is currently only supported on BSDs" ;;
    esac
    sys_version="${target#*@}"
    target="${target%@*}"
fi
target_lower="${target//-/_}"
target_lower="${target_lower//./_}"
target_upper="$(tr '[:lower:]' '[:upper:]' <<<"${target_lower}")"
host=$(rustc -Vv | grep 'host: ' | cut -c 7-)
rustc_version=$(rustc -Vv | grep 'release: ' | cut -c 10-)
rustc_minor_version="${rustc_version#*.}"
rustc_minor_version="${rustc_minor_version%%.*}"
rustup_target_list=$(rustup target list | sed 's/ .*//g')

install_apt_packages() {
    if [[ ${#apt_packages[@]} -gt 0 ]]; then
        retry sudo apt-get -o Acquire::Retries=10 -qq update
        if ! retry sudo apt-get -o Acquire::Retries=10 -o Dpkg::Use-Pty=0 install -y --no-install-recommends "${apt_packages[@]}"; then
            # Workaround for https://github.com/taiki-e/setup-cross-toolchain-action/issues/15
            sudo apt-get -o Acquire::Retries=10 -o Dpkg::Use-Pty=0 upgrade -y
            sudo apt-get -o Acquire::Retries=10 -o Dpkg::Use-Pty=0 install -y --no-install-recommends "${apt_packages[@]}"
        fi
        apt_packages=()
    fi
}
install_llvm() {
    # https://github.com/taiki-e/dockerfiles/blob/998a9ad25ae76314d9439681de4d5fe70bb25430/build-base/apt.Dockerfile#L68
    echo "::group::Install LLVM"
    codename="$(grep '^VERSION_CODENAME=' /etc/os-release | sed 's/^VERSION_CODENAME=//')"
    case "${codename}" in
        bionic) llvm_version=13 ;;
        # TODO: update to 16
        *) llvm_version=15 ;;
    esac
    echo "deb http://apt.llvm.org/${codename}/ llvm-toolchain-${codename}-${llvm_version} main" \
        | sudo tee "/etc/apt/sources.list.d/llvm-toolchain-${codename}-${llvm_version}.list" >/dev/null
    retry curl --proto '=https' --tlsv1.2 -fsSL --retry 10 --retry-connrefused https://apt.llvm.org/llvm-snapshot.gpg.key \
        | gpg --dearmor \
        | sudo tee /etc/apt/trusted.gpg.d/llvm-snapshot.gpg >/dev/null
    apt_packages+=(
        clang-"${llvm_version}"
        libc++-"${llvm_version}"-dev
        libc++abi-"${llvm_version}"-dev
        libclang-"${llvm_version}"-dev
        lld-"${llvm_version}"
        llvm-"${llvm_version}"
        llvm-"${llvm_version}"-dev
    )
    install_apt_packages
    for tool in /usr/bin/clang*-"${llvm_version}" /usr/bin/llvm-*-"${llvm_version}" /usr/bin/*lld*-"${llvm_version}" /usr/bin/wasm-ld-"${llvm_version}"; do
        local link="${tool%"-${llvm_version}"}"
        sudo update-alternatives --install "${link}" "${link##*/}" "${tool}" 100
    done
    echo "::endgroup::"
}
install_rust_cross_toolchain() {
    echo "::group::Install toolchain"
    rust_cross_toolchain_used=1
    toolchain_dir=/usr/local
    # https://github.com/taiki-e/rust-cross-toolchain/pkgs/container/rust-cross-toolchain
    retry docker create --name rust-cross-toolchain "ghcr.io/taiki-e/rust-cross-toolchain:${target}${sys_version:-}-dev-amd64"
    mkdir -p .setup-cross-toolchain-action-tmp
    docker cp "rust-cross-toolchain:/${target}" .setup-cross-toolchain-action-tmp/toolchain
    docker rm -f rust-cross-toolchain >/dev/null
    sudo cp -r .setup-cross-toolchain-action-tmp/toolchain/. "${toolchain_dir}"/
    rm -rf ./.setup-cross-toolchain-action-tmp
    # https://github.com/taiki-e/rust-cross-toolchain/blob/a92f4cc85408460235b024933451f0350e08b726/docker/test/entrypoint.sh#L47
    case "${target}" in
        aarch64_be-unknown-linux-gnu | armeb-unknown-linux-gnueabi* | arm-unknown-linux-gnueabihf) qemu_ld_prefix="/usr/local/${target}/libc" ;;
        riscv32gc-unknown-linux-gnu) qemu_ld_prefix="${toolchain_dir}/sysroot" ;;
        loongarch64-unknown-linux-gnu)
            qemu_ld_prefix="${toolchain_dir}/target/usr"
            echo "LD_LIBRARY_PATH=${toolchain_dir}/target/usr/lib64:${toolchain_dir}/${target}/lib64:${LD_LIBRARY_PATH:-}" >>"${GITHUB_ENV}"
            ;;
        *) qemu_ld_prefix="${toolchain_dir}/${target}" ;;
    esac
    case "${target}" in
        *-wasi*)
            # Do not use prefixed clang for wasi due to rustc 1.68.0 bug: https://github.com/rust-lang/rust/pull/109156
            cat >>"${GITHUB_ENV}" <<EOF
CARGO_TARGET_${target_upper}_LINKER=clang
CC_${target_lower}=clang
CXX_${target_lower}=clang++
AR_${target_lower}=llvm-ar
RANLIB_${target_lower}=llvm-ranlib
AR=llvm-ar
NM=llvm-nm
STRIP=llvm-strip
OBJCOPY=llvm-objcopy
OBJDUMP=llvm-objdump
READELF=llvm-readelf
EOF
            ;;
        *)
            if type -P "${target}-gcc"; then
                cat >>"${GITHUB_ENV}" <<EOF
CARGO_TARGET_${target_upper}_LINKER=${target}-gcc
CC_${target_lower}=${target}-gcc
CXX_${target_lower}=${target}-g++
AR_${target_lower}=${target}-ar
RANLIB_${target_lower}=${target}-ranlib
STRIP=${target}-strip
OBJDUMP=${target}-objdump
EOF
            elif type -P "${target}-clang"; then
                cat >>"${GITHUB_ENV}" <<EOF
CARGO_TARGET_${target_upper}_LINKER=${target}-clang
CC_${target_lower}=${target}-clang
CXX_${target_lower}=${target}-clang++
AR_${target_lower}=llvm-ar
RANLIB_${target_lower}=llvm-ranlib
AR=llvm-ar
NM=llvm-nm
STRIP=llvm-strip
OBJCOPY=llvm-objcopy
OBJDUMP=llvm-objdump
READELF=llvm-readelf
EOF
            else
                bail "internal error: no linker found for ${target}"
            fi
            ;;
    esac
    echo "::endgroup::"
}

setup_linux_host() {
    apt_packages=()
    if [[ "${host}" != "${target}" ]]; then
        case "${target}" in
            *-linux-gnu*)
                # https://github.com/taiki-e/rust-cross-toolchain/blob/a92f4cc85408460235b024933451f0350e08b726/docker/linux-gnu.sh
                case "${target}" in
                    # (tier3) Toolchains for aarch64_be-linux-gnu/armeb-linux-gnueabi/riscv32-linux-gnu is not available in APT.
                    # https://github.com/taiki-e/rust-cross-toolchain/blob/a92f4cc85408460235b024933451f0350e08b726/docker/linux-gnu.sh#L17
                    aarch64_be-unknown-linux-gnu | armeb-unknown-linux-gnueabi* | riscv32gc-unknown-linux-gnu | loongarch64-unknown-linux-gnu) install_rust_cross_toolchain ;;
                    arm-unknown-linux-gnueabihf)
                        # (tier2) Ubuntu's gcc-arm-linux-gnueabihf enables armv7 by default
                        # https://github.com/taiki-e/rust-cross-toolchain/blob/a92f4cc85408460235b024933451f0350e08b726/docker/linux-gnu.sh#L55
                        bail "target '${target}' not yet supported; consider using armv7-unknown-linux-gnueabihf for testing armhf or arm-unknown-linux-gnueabi for testing armv6"
                        ;;
                    sparc-unknown-linux-gnu)
                        # (tier3) Setup is tricky.
                        # https://github.com/taiki-e/rust-cross-toolchain/blob/a92f4cc85408460235b024933451f0350e08b726/docker/linux-gnu.Dockerfile#L44
                        bail "target '${target}' not yet supported"
                        ;;
                    *)
                        case "${target}" in
                            arm*hf | thumbv7neon-*) cc_target=arm-linux-gnueabihf ;;
                            arm*) cc_target=arm-linux-gnueabi ;;
                            riscv32gc-* | riscv64gc-*) cc_target="${target/gc-unknown/}" ;;
                            sparc-*)
                                cc_target=sparc-linux-gnu
                                apt_target=sparc64-linux-gnu
                                multilib=1
                                ;;
                            *) cc_target="${target/-unknown/}" ;;
                        esac
                        apt_target="${apt_target:-"${cc_target/i586/i686}"}"
                        # TODO: can we reduce the setup time by providing an option to skip installing packages for C++?
                        apt_packages+=("g++-${multilib:+multilib-}${apt_target/_/-}")
                        # https://github.com/taiki-e/rust-cross-toolchain/blob/fcb7a7e6ca14333d93c528f34a1def5a38745b3a/docker/test/entrypoint.sh
                        qemu_ld_prefix="/usr/${apt_target}"
                        cat >>"${GITHUB_ENV}" <<EOF
CARGO_TARGET_${target_upper}_LINKER=${apt_target}-gcc
CC_${target_lower}=${apt_target}-gcc
CXX_${target_lower}=${apt_target}-g++
AR_${target_lower}=${apt_target}-ar
RANLIB_${target_lower}=${apt_target}-ranlib
STRIP=${apt_target}-strip
OBJDUMP=${apt_target}-objdump
PKG_CONFIG_PATH=/usr/lib/${apt_target}/pkgconfig:${PKG_CONFIG_PATH:-}
EOF
                        ;;
                esac
                ;;
            *-linux-musl*)
                # https://github.com/rust-lang/rust/pull/107129
                if [[ "${rustc_minor_version}" -lt 71 ]]; then
                    sys_version=1.1
                else
                    sys_version=1.2
                fi
                install_rust_cross_toolchain
                ;;
            *-freebsd*)
                install_rust_cross_toolchain
                install_llvm
                ;;
            *-netbsd*)
                install_rust_cross_toolchain
                ;;
            *-wasi*)
                install_rust_cross_toolchain
                case "${runner}" in
                    '' | 'wasmtime') ;;
                    *) bail "unrecognized runner '${runner}'" ;;
                esac
                echo "CARGO_TARGET_${target_upper}_RUNNER=${target}-runner" >>"${GITHUB_ENV}"
                x wasmtime --version
                # https://github.com/taiki-e/rust-cross-toolchain/blob/fcb7a7e6ca14333d93c528f34a1def5a38745b3a/docker/test/entrypoint.sh#L174
                echo "CXXSTDLIB=c++" >>"${GITHUB_ENV}"
                ;;
            x86_64-pc-windows-gnu)
                arch="${target%%-*}"
                apt_target="${arch}-w64-mingw32"
                apt_packages+=("g++-mingw-w64-${arch/_/-}")

                # https://wiki.winehq.org/Ubuntu
                # https://wiki.winehq.org/Wine_User%27s_Guide#Wine_from_WineHQ
                sudo dpkg --add-architecture i386
                codename="$(grep '^VERSION_CODENAME=' /etc/os-release | sed 's/^VERSION_CODENAME=//')"
                sudo mkdir -pm755 /etc/apt/keyrings
                retry sudo wget -O /etc/apt/keyrings/winehq-archive.key https://dl.winehq.org/wine-builds/winehq.key
                retry sudo wget -NP /etc/apt/sources.list.d/ "https://dl.winehq.org/wine-builds/ubuntu/dists/${codename}/winehq-${codename}.sources"
                case "${runner}" in
                    '')
                        # Use winehq-devel 7.13 as default because mio/wepoll needs wine 7.13+.
                        # https://github.com/tokio-rs/mio/issues/1444
                        wine_version=7.13
                        wine_branch=devel
                        ;;
                    wine@*)
                        wine_version="${runner#*@}"
                        if [[ "${wine_version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
                            wine_branch=stable
                        elif [[ "${wine_version}" =~ ^[0-9]+\.[0-9]+$ ]]; then
                            wine_branch=devel
                        else
                            bail "unrecognized runner '${runner}'"
                        fi
                        ;;
                    *) bail "unrecognized runner '${runner}'" ;;
                esac
                # The suffix is 1 in most cases, rarely 2.
                # https://dl.winehq.org/wine-builds/ubuntu/dists/jammy/main/binary-amd64
                # https://dl.winehq.org/wine-builds/ubuntu/dists/focal/main/binary-amd64
                wine_build_suffix=1
                apt_packages+=(
                    "winehq-${wine_branch}=${wine_version}~${codename}-${wine_build_suffix}"
                    "wine-${wine_branch}=${wine_version}~${codename}-${wine_build_suffix}"
                    "wine-${wine_branch}-amd64=${wine_version}~${codename}-${wine_build_suffix}"
                    "wine-${wine_branch}-i386=${wine_version}~${codename}-${wine_build_suffix}"
                    "wine-${wine_branch}-dev=${wine_version}~${codename}-${wine_build_suffix}"
                )
                install_apt_packages
                x wine --version

                gcc_lib="$(basename "$(ls -d "/usr/lib/gcc/${apt_target}"/*posix)")"
                # Adapted from https://github.com/cross-rs/cross/blob/16a64e7028d90a3fdf285cfd642cdde9443c0645/docker/windows-entry.sh
                cat >"/usr/local/bin/${target}-runner" <<EOF
#!/bin/sh
set -eu
export HOME=/tmp/home
mkdir -p "\${HOME}"
export WINEPREFIX=/tmp/wine
mkdir -p "\${WINEPREFIX}"
if [ ! -e /tmp/WINEBOOT ]; then
    wineboot &>/dev/null
    touch /tmp/WINEBOOT
fi
export WINEPATH="/usr/lib/gcc/${apt_target}/${gcc_lib};/usr/${apt_target}/lib;\${WINEPATH:-}"
exec wine "\$@"
EOF
                chmod +x "/usr/local/bin/${target}-runner"

                cat >>"${GITHUB_ENV}" <<EOF
CARGO_TARGET_${target_upper}_RUNNER=${target}-runner
CARGO_TARGET_${target_upper}_LINKER=${apt_target}-gcc-posix
CC_${target_lower}=${apt_target}-gcc-posix
CXX_${target_lower}=${apt_target}-g++-posix
AR_${target_lower}=${apt_target}-ar
RANLIB_${target_lower}=${apt_target}-ranlib
STRIP=${apt_target}-strip
OBJDUMP=${apt_target}-objdump
EOF
                ;;
            *) bail "target '${target}' is not supported yet on Linux host" ;;
        esac
    fi

    case "${target}" in
        *-unknown-linux-*)
            case "${runner}" in
                '')
                    case "${target}" in
                        # On x86, qemu-user is not used by default.
                        x86_64* | i686-*) ;;
                        *) use_qemu='1' ;;
                    esac
                    ;;
                native) ;;
                qemu-user) use_qemu='1' ;;
                *) bail "unrecognized runner '${runner}'" ;;
            esac
            ;;
        *-freebsd* | *-netbsd*)
            # Runners for BSDs are not supported yet.
            # We are currently testing the uploaded artifacts manually with Cirrus CI and local VM.
            # https://cirrus-ci.org/guide/FreeBSD
            case "${runner}" in
                '') ;;
                *) bail "unrecognized runner '${runner}'" ;;
            esac
            ;;
    esac
    if [[ -n "${use_qemu:-}" ]]; then
        # https://github.com/taiki-e/rust-cross-toolchain/blob/fcb7a7e6ca14333d93c528f34a1def5a38745b3a/docker/test/entrypoint.sh#L307
        # We basically set the newer and more powerful CPU as the
        # default QEMU_CPU so that we can test more CPU features.
        # In some contexts, we want to test for a specific CPU,
        # so respect user-set QEMU_CPU.
        case "${target}" in
            aarch64* | arm64*)
                qemu_arch="${target%%-*}"
                case "${target}" in
                    arm64*be*) qemu_arch=aarch64_be ;;
                    arm64*) qemu_arch=aarch64 ;;
                esac
                qemu_cpu=a64fx
                ;;
            arm* | thumb*)
                case "${target}" in
                    armeb* | thumbeb*) qemu_arch=armeb ;;
                    *) qemu_arch=arm ;;
                esac
                ;;
            i*86-*) qemu_arch=i386 ;;
            hexagon-*) qemu_arch=hexagon ;;
            loongarch64-*) qemu_arch=loongarch64 ;;
            m68k-*) qemu_arch=m68k ;;
            mips-* | mipsel-*) qemu_arch="${target%%-*}" ;;
            mips64-* | mips64el-*)
                qemu_arch="${target%%-*}"
                # As of qemu 6.1, only Loongson-3A4000 supports MSA instructions with mips64r5.
                qemu_cpu=Loongson-3A4000
                ;;
            mipsisa32r6-* | mipsisa32r6el-*)
                qemu_arch="${target%%-*}"
                qemu_arch="${qemu_arch/isa32r6/}"
                qemu_cpu=mips32r6-generic
                ;;
            mipsisa64r6-* | mipsisa64r6el-*)
                qemu_arch="${target%%-*}"
                qemu_arch="${qemu_arch/isa64r6/64}"
                qemu_cpu=I6400
                ;;
            powerpc-*spe)
                qemu_arch=ppc
                qemu_cpu=e500v2
                ;;
            powerpc-*)
                qemu_arch=ppc
                qemu_cpu=Vger
                ;;
            powerpc64-*)
                qemu_arch=ppc64
                qemu_cpu=power10
                ;;
            powerpc64le-*)
                qemu_arch=ppc64le
                qemu_cpu=power10
                ;;
            riscv32gc-* | riscv64gc-*) qemu_arch="${target%%gc-*}" ;;
            s390x-*) qemu_arch=s390x ;;
            sparc-*) qemu_arch=sparc32plus ;;
            sparc64-*) qemu_arch=sparc64 ;;
            x86_64*)
                qemu_arch=x86_64
                # qemu does not seem to support emulating x86_64 CPU features on x86_64 hosts.
                # > qemu-x86_64: warning: TCG doesn't support requested feature
                #
                # A way that works well for emulating x86_64 CPU features on x86_64 hosts is to use Intel SDE.
                # https://www.intel.com/content/www/us/en/developer/articles/tool/software-development-emulator.html
                # It is not OSS, but it is licensed under Intel Simplified Software License and redistribution is allowed.
                # https://www.intel.com/content/www/us/en/developer/articles/license/pre-release-license-agreement-for-software-development-emulator.html
                # https://www.intel.com/content/www/us/en/developer/articles/license/onemkl-license-faq.html
                ;;
            *) bail "unrecognized target '${target}'" ;;
        esac
        echo "CARGO_TARGET_${target_upper}_RUNNER=qemu-${qemu_arch}" >>"${GITHUB_ENV}"
        # QEMU's multi-threading support is incomplete and slow.
        echo "RUST_TEST_THREADS=1" >>"${GITHUB_ENV}"
        if [[ -n "${qemu_cpu:-}" ]] && [[ -z "${QEMU_CPU:-}" ]]; then
            echo "QEMU_CPU=${qemu_cpu}" >>"${GITHUB_ENV}"
        fi
        if [[ -n "${qemu_ld_prefix:-}" ]] && [[ -z "${QEMU_LD_PREFIX:-}" ]]; then
            echo "QEMU_LD_PREFIX=${qemu_ld_prefix}" >>"${GITHUB_ENV}"
        fi
        if [[ -z "${rust_cross_toolchain_used:-}" ]]; then
            qemu_bin_dir=/usr/bin
            echo "::group::Instal QEMU"
            # https://github.com/taiki-e/dockerfiles/pkgs/container/qemu-user
            retry docker create --name qemu-user ghcr.io/taiki-e/qemu-user
            mkdir -p .setup-cross-toolchain-action-tmp
            docker cp qemu-user:/usr/bin .setup-cross-toolchain-action-tmp/qemu
            docker rm -f qemu-user >/dev/null
            sudo mv .setup-cross-toolchain-action-tmp/qemu/qemu-* "${qemu_bin_dir}"/
            rm -rf ./.setup-cross-toolchain-action-tmp
            echo "::endgroup::"
        else
            qemu_bin_dir="${toolchain_dir}/bin"
        fi
        x "qemu-${qemu_arch}" --version
        echo "::group::Register binfmt"
        # Refs: https://github.com/multiarch/qemu-user-static.
        # https://github.com/qemu/qemu/blob/master/scripts/qemu-binfmt-conf.sh
        local url=https://raw.githubusercontent.com/qemu/qemu/a279ca4ea07383314b2d2b2f1d550be9482f148e/scripts/qemu-binfmt-conf.sh
        retry curl --proto '=https' --tlsv1.2 -fsSL --retry 10 --retry-connrefused -o __qemu-binfmt-conf.sh "${url}"
        sed -i "s/i386_magic/qemu_target_list=\"${qemu_arch}\"\\ni386_magic/" ./__qemu-binfmt-conf.sh
        chmod +x ./__qemu-binfmt-conf.sh
        if [[ ! -d /proc/sys/fs/binfmt_misc ]]; then
            bail "kernel does not support binfmt"
        fi
        if [[ ! -f /proc/sys/fs/binfmt_misc/register ]]; then
            sudo mount binfmt_misc -t binfmt_misc /proc/sys/fs/binfmt_misc
        fi
        sudo ./__qemu-binfmt-conf.sh --qemu-path "${qemu_bin_dir}" --persistent yes
        rm ./__qemu-binfmt-conf.sh
        echo "::endgroup::"
    fi

    install_apt_packages
}

case "${host}" in
    *-linux-gnu*) setup_linux_host ;;
    # GitHub-provided macOS runners support cross-compile for other architectures or environments.
    *-darwin*)
        case "${target}" in
            *-darwin*) ;;
            *) bail "target '${target}' is not supported yet on macOS host" ;;
        esac
        case "${runner}" in
            '' | native) ;;
            *) bail "unrecognized runner '${runner}'" ;;
        esac
        ;;
    *) bail "unsupported host '${host}'" ;;
esac

if grep <<<"${rustup_target_list}" -Eq "^${target}$"; then
    retry rustup target add "${target}" &>/dev/null
    # Note: -Z doctest-xcompile doesn't compatible with -Z build-std yet.
    if [[ "${rustc_version}" == *"nightly"* ]] || [[ "${rustc_version}" == *"dev"* ]]; then
        if cargo -Z help | grep -Eq '\bZ doctest-xcompile\b'; then
            echo "DOCTEST_XCOMPILE=-Zdoctest-xcompile" >>"${GITHUB_ENV}"
        fi
    fi
else
    # for -Z build-std
    retry rustup component add rust-src &>/dev/null
    echo "BUILD_STD=-Zbuild-std" >>"${GITHUB_ENV}"
fi
echo "CARGO_BUILD_TARGET=${target}" >>"${GITHUB_ENV}"
