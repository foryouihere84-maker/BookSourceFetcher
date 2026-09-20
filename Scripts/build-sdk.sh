#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
package_dir="$(cd "${script_dir}/.." && pwd)"
version="$(sed -n 's/.*public static let version = "\([^"]*\)".*/\1/p' "${package_dir}/Sources/BookSourceFetcher/SDK/BookSourceSDK.swift")"
if [[ $# -gt 0 ]]; then
    version="$1"
fi

if [[ -z "${version}" ]]; then
    echo "Unable to read SDK version from BookSourceSDK.swift" >&2
    exit 1
fi

if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    echo "Invalid SDK version: ${version}" >&2
    exit 1
fi

if [[ "${SKIP_TESTS:-0}" != "1" ]]; then
    swift test --package-path "${package_dir}"
fi

output_dir="${package_dir}/dist"
archive_name="BookSourceFetcherSDK-${version}.zip"
checksum_name="${archive_name}.sha256"
temporary_dir="$(mktemp -d "${TMPDIR:-/tmp}/book-source-sdk.XXXXXX")"
stage_dir="${temporary_dir}/BookSourceFetcherSDK"
temporary_archive="${temporary_dir}/${archive_name}"

cleanup() {
    rm -rf "${temporary_dir}"
}
trap cleanup EXIT

mkdir -p "${stage_dir}" "${output_dir}"
cp "${package_dir}/Package.swift" "${stage_dir}/"
cp "${package_dir}/Package.resolved" "${stage_dir}/"
cp "${package_dir}/README.md" "${stage_dir}/"
cp "${package_dir}/SDK_INTEGRATION.md" "${stage_dir}/"
cp -R "${package_dir}/Sources" "${stage_dir}/Sources"
cp -R "${package_dir}/Tests" "${stage_dir}/Tests"

swift package --package-path "${stage_dir}" dump-package >/dev/null

(
    cd "${temporary_dir}"
    zip -qry "${temporary_archive}" BookSourceFetcherSDK
)

mv -f "${temporary_archive}" "${output_dir}/${archive_name}"
(
    cd "${output_dir}"
    shasum -a 256 "${archive_name}" >"${checksum_name}"
)

echo "SDK: ${output_dir}/${archive_name}"
echo "SHA-256: $(cut -d ' ' -f 1 "${output_dir}/${checksum_name}")"
