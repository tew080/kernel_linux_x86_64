#!/usr/bin/env bash
#
# propeller-pipeline.sh — จัดการ 4 ขั้นตอนของ Propeller build ให้ครบ
# (build-propeller -> train-propeller -> generate-profile -> build-optimized)
#
# ออกแบบมาให้ "detect state" จากไฟล์ที่มีอยู่จริงในโฟลเดอร์ปัจจุบัน
# แทนที่จะให้คนจำเองว่าตอนนี้ทำถึงขั้นไหนแล้ว — เพราะ pipeline นี้มีหลาย
# ขั้นตอนที่ต้อง "คั่นเวลา" ด้วยการเอา kernel ไป boot จริงบนเครื่อง target
# (ไม่ใช่รันรวดเดียวจบในคำสั่งเดียวได้ ต่างจาก AutoFDO ตัวเดียวที่ผ่านมา)

set -euo pipefail

# ── ค่าคงที่ ────────────────────────────────────────────────────────────
AUTOFDO_PROFILE="${AUTOFDO_PROFILE:-merged_all.afdo}"
PROP_PREFIX="${PROP_PREFIX:-kernel_prop}"
CC_PROFILE="${PROP_PREFIX}_cc_profile.txt"
LD_PROFILE="${PROP_PREFIX}_ld_profile.txt"
PERF_DATA="${PERF_DATA:-perf.data}"
PERF_DATA_HIT="${PERF_DATA}.hit"
CLANG_BIN="${CLANG_BIN:-clang-22}"
JOBS="${JOBS:-$(nproc)}"

export PATH="$(dirname "$CLANG_BIN"):$PATH"

# ── ฟังก์ชันช่วยพิมพ์สถานะให้อ่านง่าย ───────────────────────────────────
step() { printf '\n\033[1;36m▶ %s\033[0m\n' "$1"; }
ok()   { printf '\033[1;32m  ✓ %s\033[0m\n' "$1"; }
warn() { printf '\033[1;33m  ! %s\033[0m\n' "$1"; }
die()  { printf '\033[1;31m  ✗ %s\033[0m\n' "$1" >&2; exit 1; }

# ── เช็ค tool ที่จำเป็นก่อนเริ่ม (เรียนรู้จากบทเรียน llvm-profgen ก่อนหน้า) ──
check_tools() {
    step "เช็ค toolchain"
    command -v "$CLANG_BIN" >/dev/null 2>&1 || die "ไม่พบ $CLANG_BIN ในระบบ"
    if command -v generate_propeller_profiles >/dev/null 2>&1; then
        PROP_TOOL="generate_propeller_profiles"
    elif command -v create_llvm_prof >/dev/null 2>&1; then
        PROP_TOOL="create_llvm_prof"
        warn "ใช้ create_llvm_prof (เวอร์ชันเก่ากว่า generate_propeller_profiles)"
    else
        die "ไม่พบทั้ง generate_propeller_profiles และ create_llvm_prof — ติดตั้งก่อน"
    fi
    ok "ใช้ $PROP_TOOL สำหรับ generate profile"
}

# ── Step 1: build-propeller (ต้องมี AutoFDO profile อยู่แล้ว) ────────────
cmd_build_propeller() {
    [[ -f "$AUTOFDO_PROFILE" ]] || die "ไม่พบ $AUTOFDO_PROFILE — ต้องมี AutoFDO profile ก่อน"

    step "ล้างไฟล์ Build เก่า (make clean)"
    make clean

    step "Build kernel พร้อม AutoFDO เพื่อสร้าง .llvm_bb_addr_map metadata"
    # ต้องใส่ -fbasic-block-address-map เพื่อให้สร้าง Section ข้อมูลสำหรับ Propeller เสมอ
    make LLVM=1 CC="$CLANG_BIN" \
        KCFLAGS="-fbasic-block-address-map" \
        CLANG_AUTOFDO_PROFILE="$(pwd)/$AUTOFDO_PROFILE" \
        -j"$JOBS"

    ok "Build เสร็จ — ตอนนี้ vmlinux มี .llvm_bb_addr_map ฝังอยู่แล้ว"
    warn "ขั้นตอนถัดไป: ติดตั้ง/boot kernel ตัวนี้บนเครื่อง target จริง"
    warn "อย่าลืม: ปิด KASLR โดยเติม 'nokaslr' ใน GRUB"
    warn "แล้วรัน: $0 train"
}

# ── Step 2: แค่พิมพ์คำสั่งเก็บ perf ให้ (ต้องรันเองบนเครื่อง target) ──────
cmd_train() {
    step "คำสั่งสำหรับเก็บ perf profile บนเครื่อง target"
    cat <<'EOF'

  รันคำสั่งนี้บนเครื่อง target (ต้อง boot ด้วย vmlinux ที่เพิ่ง build จาก
  cmd_build_propeller แล้ว และปิด KASLR แล้ว) 

  เปิด 2 Terminal เพื่อสร้าง Workload ควบคู่กับการอัดข้อมูล:

  [Terminal 1] รัน Workload:
    stress-ng --cpu 0 --io 4 --vm 2 --timeout 60s

  [Terminal 2] อัด Perf (รันพร้อมกัน):
    sudo perf record -e cycles:k -F 5000 -a -b -o perf.data -- sleep 60

  เสร็จแล้วเอา perf.data กลับมาที่เครื่อง build (scp/rsync) ไว้ตำแหน่งเดียว
  กับสคริปต์นี้ แล้วรัน:  ./propeller-pipeline.sh generate

EOF
}

# ── Step 3: generate propeller profile จาก perf.data ────────────────────
cmd_generate() {
    check_tools
    [[ -f "$PERF_DATA" ]] || die "ไม่พบ $PERF_DATA — เก็บ perf record มาก่อน (ดู: $0 train)"
    [[ -f vmlinux ]] || die "ไม่พบ vmlinux ในโฟลเดอร์ปัจจุบัน"

    step "ซ่อมแซม Build-ID และ MMAP ด้วย perf inject"
    sudo perf inject -b -i "$PERF_DATA" -o "$PERF_DATA_HIT"
    ok "สร้างไฟล์ $PERF_DATA_HIT สำเร็จ"

    step "Generate propeller cc_profile / ld_profile จาก $PERF_DATA_HIT"
    if [[ "$PROP_TOOL" == "generate_propeller_profiles" ]]; then
        sudo generate_propeller_profiles \
            --binary=vmlinux \
            --profile="$PERF_DATA_HIT" \
            --format=propeller \
            --out="$CC_PROFILE" \
            --propeller_symorder="$LD_PROFILE" \
            --profiled_binary_name="[kernel.kallsyms]"
    else
        sudo create_llvm_prof \
            --format=propeller \
            --binary=vmlinux \
            --profile="$PERF_DATA_HIT" \
            --out="$CC_PROFILE" \
            --propeller_symorder="$LD_PROFILE" \
            --profiled_binary_name="[kernel.kallsyms]"
    fi

    ok "ได้ $CC_PROFILE และ $LD_PROFILE แล้ว"
    warn "ขั้นตอนสุดท้าย: $0 build-optimized"
}

# ── Step 4: build-optimized (ใช้ทั้ง AutoFDO + Propeller profile) ────────
# DEB_PKG=1 (default) -> pack เป็น .deb เลย, DEB_PKG=0 -> ได้แค่ vmlinux เปล่า ๆ
DEB_PKG="${DEB_PKG:-1}"

cmd_build_optimized() {
    [[ -f "$AUTOFDO_PROFILE" ]] || die "ไม่พบ $AUTOFDO_PROFILE"
    [[ -f "$CC_PROFILE" && -f "$LD_PROFILE" ]] || \
        die "ไม่พบ $CC_PROFILE / $LD_PROFILE — รัน '$0 generate' ก่อน"

    step "ล้างไฟล์ Build เก่า (make clean)"
    make clean

    local make_args=(
        LLVM=1 CC="$CLANG_BIN"
        CLANG_AUTOFDO_PROFILE="$(pwd)/$AUTOFDO_PROFILE"
        CLANG_PROPELLER_PROFILE_PREFIX="$(pwd)/$PROP_PREFIX"
    )

    if [[ "$DEB_PKG" == "1" ]]; then
        step "Build kernel รอบสุดท้าย + pack เป็น .deb (AutoFDO + Propeller ครบ)"
        make_args+=(
            KDEB_NO_SOURCE_PACKAGE=1
            NO_SOURCE=1
            KBUILD_NO_SYNC_CONFIG=1
            KCONFIG_NOTIMESTAMP=1
            KCONFIG_OVERWRITECONFIG=1
            INSTALL_MOD_STRIP=1
            bindeb-pkg
        )
    else
        step "Build kernel รอบสุดท้าย (vmlinux เปล่า ไม่ pack .deb — ตั้ง DEB_PKG=0 ไว้)"
    fi

    make "${make_args[@]}" -j"$JOBS"

    if [[ "$DEB_PKG" == "1" ]]; then
        ok "Build + pack เสร็จ — ไฟล์ .deb อยู่ที่ไดเรกทอรีเหนือ kernel source:"
        ls -la ../*.deb 2>/dev/null || warn "ไม่เจอ .deb ในตำแหน่งที่คาดไว้ — เช็ค path เอง"
    else
        ok "Build เสร็จสมบูรณ์ — vmlinux ตัวนี้คือ build-optimized (ไม่มี .deb)"
    fi
}

# ── Auto-detect: เดาว่าตอนนี้ควรทำ step ไหนต่อ จากไฟล์ที่มีอยู่ ──────────
cmd_auto() {
    step "ตรวจสถานะไฟล์ในโฟลเดอร์ปัจจุบัน"
    if [[ -f "$CC_PROFILE" && -f "$LD_PROFILE" ]]; then
        ok "พบ propeller profile ครบแล้ว -> ไป build-optimized"
        cmd_build_optimized
    elif [[ -f "$PERF_DATA" ]]; then
        ok "พบ $PERF_DATA แต่ยังไม่ generate profile -> ไป generate"
        cmd_generate
    elif [[ -f "$AUTOFDO_PROFILE" ]]; then
        warn "มี AutoFDO profile แต่ยังไม่มี perf.data ของ propeller"
        warn "เช็คว่า build-propeller (step 1) ทำไปหรือยัง"
        printf '  รัน manually: %s build-propeller  หรือ  %s train  ตามสถานะจริง\n' "$0" "$0"
    else
        die "ไม่พบ $AUTOFDO_PROFILE เลย — ต้องมี AutoFDO profile ก่อนเริ่ม Propeller pipeline"
    fi
}

# ── Entry point ───────────────────────────────────────────────────────
case "${1:-auto}" in
    build-propeller)  cmd_build_propeller ;;
    train)            cmd_train ;;
    generate)         cmd_generate ;;
    build-optimized)  cmd_build_optimized ;;
    auto)             cmd_auto ;;
    *)
        cat <<EOF
วิธีใช้: $0 [command]

  auto              (default) เดาขั้นตอนถัดไปจากไฟล์ที่มีอยู่ แล้วรันให้เอง
  build-propeller   Step 1: build kernel พร้อม AutoFDO เพื่อสร้าง metadata
  train             Step 2: แสดงคำสั่ง perf record ที่ต้องรันบนเครื่อง target
  generate          Step 3: สร้าง cc_profile/ld_profile จาก perf.data
  build-optimized   Step 4: build รอบสุดท้ายด้วย profile ครบทั้งคู่

ตัวแปร environment ที่ปรับได้:
  AUTOFDO_PROFILE (default: merged_all.afdo)
  PROP_PREFIX     (default: kernel_prop)
  PERF_DATA       (default: perf.data)
  CLANG_BIN       (default: clang-22)
  JOBS            (default: nproc)
  DEB_PKG         (default: 1) -> 1=pack .deb ใน build-optimized, 0=vmlinux เปล่า
EOF
        exit 1
        ;;
esac
