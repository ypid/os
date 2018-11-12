#!/bin/bash
set -e
cd "$HOME"
device="${DEVICE?}"
build_type="${BUILD_TYPE?}"
build_variant="${BUILD_VARIANT?}"
manifest_branch="${MANIFEST_BRANCH?}"
driver_build="${DRIVER_BUILD?}"
kernel_name="${KERNEL_NAME?}"
kernel_commit="${KERNEL_COMMIT?}"
kernel_defconfig="${KERNEL_DEFCONFIG?}"
ndk_version="${NDK_VERSION?}"
ndk_sha256="${NDK_SHA256?}"
toolchain_version="${TOOLCHAIN_VERSION?}"

declare -A driver_sha256=(
    ["google_devices"]="${DRIVER_SHA256_GOOGLE?}"
    ["qcom"]="${DRIVER_SHA256_QCOM?}"
)
declare -A driver_crc=(
    ["google_devices"]="${DRIVER_CRC_GOOGLE?}"
    ["qcom"]="${DRIVER_CRC_QCOM?}"
)
drivers=( google_devices qcom )

manifest_url="https://android.googlesource.com/platform/manifest"
driver_url="https://dl.google.com/dl/android/aosp"
kernel_url="https://android.googlesource.com/kernel/${kernel_name}"
ndk_url="https://dl.google.com/android/repository"

temp_dir="$(mktemp -d)"
download_dir="${temp_dir}/downloads/"
release_dir="$HOME"

function sha256() { openssl sha256 "$@" | awk '{print $2}'; }

cores=$(grep -c ^processor /proc/cpuinfo)

mkdir -p "${download_dir}" "${release_dir}"

for driver in "${drivers[@]}"; do
	file="${driver}-${device}-${driver_build}-${driver_crc[$driver]}.tgz"
	if [ ! -f "${release_dir}/${file}" ]; then
		wget "${driver_url}/${file}" -O "${download_dir}/${file}"
		file_hash="$(sha256 "${download_dir}/${file}")"
		echo "$file_hash"
		[[ "${driver_sha256[${driver}]}" == "$file_hash" ]] || \
			{ ( >&2 echo "Invalid hash for ${file}"); exit 1; }
		mv "${download_dir}/${file}" "${release_dir}/${file}"
	fi
	tar -xvf "${release_dir}/${file}" -C "${release_dir}"
	tail -n +315 "${release_dir}/extract-${driver}-${device}.sh" \
		| tar -xzv -C "${release_dir}"
done

ndk_file="android-ndk-${ndk_version}-linux-x86_64.zip"
if [ ! -f "${release_dir}/${ndk_file}" ]; then
	wget "${ndk_url}/${ndk_file}" -O "${download_dir}/${ndk_file}"
	ndk_file_hash="$(sha256 "${download_dir}/${ndk_file}")"
	echo "$ndk_file_hash"
	[[ "${ndk_sha256}" == "$ndk_file_hash" ]] || \
		{ ( >&2 echo "Invalid hash for ${file}"); exit 1; }
	mv "${download_dir}/${ndk_file}" "${release_dir}/${ndk_file}"
fi
unzip -n -d "ndk" "${release_dir}/${ndk_file}"

git config --global user.email "staff@hashbang.sh"
git config --global user.name "Hashbang Staff"
git config --global color.ui false

# Build Kernel
export ARCH=arm64
export CROSS_COMPILE="$PWD/ndk/android-ndk-${ndk_version}/toolchains/aarch64-linux-android-${toolchain_version}/prebuilt/linux-x86_64/bin/aarch64-linux-android-"
mkdir -p "kernel/${kernel_name}"
if [ ! -d "kernel/${kernel_name}" ]; then
	git clone "${kernel_url}" "kernel/${kernel_name}"
fi
cd "kernel/${kernel_name}"
git pull origin "${kernel_commit}"
git checkout "${kernel_commit}"
make "${kernel_defconfig}_defconfig"
make V=1 -j "${cores}"

cd -
cp "kernel/arch/arm64/boot/dtbo.img" "device/google/${device}-kernel/"
cp "kernel/arch/arm64/boot/Image.lz4-dtb" "device/google/${device}-kernel/"

# Build flashable android image
repo \
	--no-pager \
	--color=auto \
	init \
    --manifest-url "$manifest_url" \
    --manifest-branch "$manifest_branch" \
    --depth 1
repo sync \
	-c \
	--no-tags \
	--no-clone-bundle \
	--jobs "${cores}"


# shellcheck disable=SC1091
source build/envsetup.sh

choosecombo "${build_type}" "aosp_${device}" "${build_variant}"
make -j "${cores}" fastboot
make -j "${cores}" target-files-package
make -j "${cores}" brillo_update_payload
