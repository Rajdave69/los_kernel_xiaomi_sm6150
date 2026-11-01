#!/usr/bin/env bash
# Reproducible root integration for sweet2. Runs only in the Actions workspace.
# The original Oct 8 OEM workflow did not record its dependencies' commit IDs.
# These commits are audited pins, NOT asserted identical to the old kernel.
set -euo pipefail
cd "$GITHUB_WORKSPACE"

KSU_REPO="https://github.com/manipvlator/KernelSU.git"
KSU_SHA="fcefc0a3ef8cda1d241bea1b24751e090db48281"
NOMOUNT_REPO="https://github.com/maxsteeel/nomount.git"
NOMOUNT_SHA="71883de7ab2e2468bbbaf78ef64ac44a33069531"

checkout_pinned() {
  local name="$1" repo="$2" commit="$3"
  test ! -e "$name" || { echo "Unexpected preexisting $name"; exit 1; }
  git clone -q --filter=blob:none --no-checkout "$repo" "$name"
  git -C "$name" fetch -q --no-tags --depth=1 origin "$commit"
  git -C "$name" checkout -q --detach "$commit"
  local actual
  actual="$(git -C "$name" rev-parse HEAD)"
  test "$actual" = "$commit" || { echo "$name commit mismatch: $actual"; exit 1; }
  echo "$name pinned to $actual"
}

# Match the original integration sequence (NoMount, then KernelSU).
checkout_pinned NoMount "$NOMOUNT_REPO" "$NOMOUNT_SHA"
ln -sfn "$(realpath --relative-to="$PWD/fs" "$PWD/NoMount/kernel/src")" fs/nomount
if ! grep -q 'nomount' fs/Makefile; then
  printf '\nobj-$(CONFIG_NOMOUNT) += nomount/\n' >> fs/Makefile
fi
if ! grep -Fq 'source "fs/nomount/Kconfig"' fs/Kconfig; then
  awk '/^endmenu/ { last=NR } { line[NR]=$0 }
       END { for (i=1;i<=NR;i++) {
         if (i==last) print "source \"fs/nomount/Kconfig\"";
         print line[i];
       } }' fs/Kconfig > fs/Kconfig.tmp
  mv fs/Kconfig.tmp fs/Kconfig
fi

checkout_pinned KernelSU "$KSU_REPO" "$KSU_SHA"
ln -sfn "$(realpath --relative-to="$PWD/drivers" "$PWD/KernelSU/kernel")" drivers/kernelsu
if ! grep -q 'kernelsu' drivers/Makefile; then
  printf '\nobj-$(CONFIG_KSU) += kernelsu/\n' >> drivers/Makefile
fi
if ! grep -Fq 'source "drivers/kernelsu/Kconfig"' drivers/Kconfig; then
  sed -i '/endmenu/i\source "drivers/kernelsu/Kconfig"' drivers/Kconfig
fi

# Add an additional *package candidate*, not a signature-verification bypass.
# The expected KSUN APK certificate is still enforced by is_manager_apk().
python3 - <<'PY'
from pathlib import Path
tracker = Path("KernelSU/kernel/manager/throne_tracker.c")
cert = Path("KernelSU/kernel/manager/apk_sign.c")
mk = Path("KernelSU/kernel/Makefile")
source = tracker.read_text()
old_define = '#define is_ksun_apk(tgt) extra_manager_apk(tgt, "com.rifsxd.ksunext")'
new_define = old_define + '\n#define is_spoofed_ksun_apk(tgt) extra_manager_apk(tgt, "kqvdie.zeykvw.hpbcyd")'
old_list = 'is_ksun_apk(tgt) || is_bksu_apk(tgt)'
new_list = 'is_ksun_apk(tgt) || is_spoofed_ksun_apk(tgt) || is_bksu_apk(tgt)'
assert source.count(old_define) == 1, "Unexpected KernelSU manager macro"
assert source.count(old_list) == 1, "Unexpected KernelSU package allowlist"
assert source.count("test_extra_pkgs(") >= 4, "Manager candidate checks changed"
assert "is_manager_apk(candidate_path)" in source, "APK signature gate missing"
assert 'check_v2_signature(path, 0x3e6, "79e590113c4c4c0c222978e413a5faa801666957b1212a328e46c00c69821bf7")' in cert.read_text(), "Trusted KSUN certificate unexpectedly changed"
assert "KSU_VERSION := 32707" in mk.read_text(), "Unexpected KernelSU version"
source = source.replace(old_define, new_define).replace(old_list, new_list)
tracker.write_text(source)
assert source.count('kqvdie.zeykvw.hpbcyd') == 1
print("Spoofed KSUN package now discoverable; signature checks remain mandatory.")
PY

echo "Pinned root-source revisions:"
git -C KernelSU rev-parse HEAD
git -C NoMount rev-parse HEAD
git -C KernelSU --no-pager diff -- kernel/manager/throne_tracker.c
