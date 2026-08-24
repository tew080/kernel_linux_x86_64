#!/bin/bash
# ============================================================
# BMQ_BURST Benchmark (Robust + Thermal-Controlled + Randomized)
# - ป้องกัน Outlier ด้วย Median + IQR + Truncated Mean
# - เก็บ raw samples ทั้งหมดไว้ในไฟล์ CSV
# - สุ่มลำดับ + ควบคุมความร้อน
# - ROUNDS=10, SAMPLES=100, ITER=50000
# ============================================================

set -euo pipefail

# ---------- ตัวแปรหลัก ----------
RESULT_DIR="bmq_burst_robust_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$RESULT_DIR"

RESULT_CSV="$RESULT_DIR/results.csv"
RAW_SAMPLES_DIR="$RESULT_DIR/raw_samples"
TEMP_LOG="$RESULT_DIR/temperature.log"
SUMMARY_TXT="$RESULT_DIR/summary.txt"

mkdir -p "$RAW_SAMPLES_DIR"

SAMPLES=100               # จำนวน sample ต่อรอบ
ITER=50000                # จำนวน iteration ต่อ sample
ROUNDS=10                 # จำนวนรอบต่อ config
DURATION=180              # ระยะเวลา stress-ng ต่อ config (วินาที)
CORES=4
SLEEP_BETWEEN=90          # พักระหว่าง config (วินาที)
COOLDOWN_TEMP=65          # อุณหภูมิเป้าหมาย (Celsius)

TUNING_FILE="/proc/sys/kernel"

# ---------- สี ----------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# ---------- ฟังก์ชันอ่านค่า sysctl ----------
read_current_tunables() {
    OFFSET=$(cat $TUNING_FILE/sched_bmq_burst_penalty_offset 2>/dev/null || echo "N/A")
    SCALE=$(cat $TUNING_FILE/sched_bmq_burst_penalty_scale 2>/dev/null || echo "N/A")
    SMOOTH=$(cat $TUNING_FILE/sched_bmq_burst_smoothness_shift 2>/dev/null || echo "N/A")
    BURST=$(cat $TUNING_FILE/sched_bmq_burst 2>/dev/null || echo "N/A")
}

# ---------- ฟังก์ชันวัดอุณหภูมิ ----------
get_temp() {
    if [[ -r /sys/class/thermal/thermal_zone0/temp ]]; then
        echo $(($(cat /sys/class/thermal/thermal_zone0/temp 2>/dev/null || echo 0) / 1000))
    elif command -v sensors &>/dev/null; then
        sensors | awk '/Package id 0/ {print $4}' | sed 's/[^0-9.]//g' | cut -d. -f1 | head -1
    else
        echo "0"
    fi
}

log_temp() {
    local label="$1"
    local temp=$(get_temp)
    local msg="[$(date +%H:%M:%S)] TEMP_${label}=${temp}°C"
    echo "$msg" >> "$TEMP_LOG"
    echo "$msg" >&2   # ส่งไป stderr ไม่ให้ปนกับ stdout
}

# ---------- ฟังก์ชันรันการทดสอบ ----------
# คืนค่า: path ของไฟล์ที่มี sample values (หนึ่งบรรทัดต่อค่า)
run_test() {
    local mode=$1
    local offset=$2
    local scale=$3
    local smooth=$4
    local load=$5
    local round=$6
    local label=$7

    # ตั้งค่า sysctl
    echo $offset > $TUNING_FILE/sched_bmq_burst_penalty_offset 2>/dev/null
    echo $scale > $TUNING_FILE/sched_bmq_burst_penalty_scale 2>/dev/null
    echo $smooth > $TUNING_FILE/sched_bmq_burst_smoothness_shift 2>/dev/null
    echo $mode > $TUNING_FILE/sched_bmq_burst 2>/dev/null

    log_temp "BEFORE_${label}_B${mode}_R${round}"

    if [[ "$load" == "yes" ]]; then
        stress-ng --cpu $CORES --timeout ${DURATION}s --cpu-method matrixprod 2>&1 > /dev/null &
        STRESS_PID=$!
        sleep 3
    fi

    # เก็บ sample values ลงไฟล์ชั่วคราว
    TMP_FILE=$(mktemp)
    for i in $(seq 1 $SAMPLES); do
        VAL=$(perf bench sched pipe -l $ITER 2>/dev/null | grep "usecs/op" | head -1 | awk '{print $1}')
        if [[ "$VAL" =~ ^[0-9.]+$ ]]; then
            echo $VAL >> $TMP_FILE
        fi
        echo -ne "\r        Sample $i / $SAMPLES" >&2
    done
    echo "" >&2

    if [[ "$load" == "yes" ]]; then
        sudo kill -INT $STRESS_PID 2>/dev/null
        wait $STRESS_PID 2>/dev/null
    fi

    log_temp "AFTER_${label}_B${mode}_R${round}"

    # สร้างชื่อไฟล์ถาวรสำหรับ raw samples
    local SAMPLE_FILE="$RAW_SAMPLES_DIR/${label}_B${mode}_R${round}.samples"
    mv "$TMP_FILE" "$SAMPLE_FILE"
    echo "$SAMPLE_FILE"
}

# ---------- ฟังก์ชันคำนวณสถิติแบบ Robust (ใช้ Python ล้วน ไม่ต้อง scipy) ----------
compute_robust_stats() {
    local file=$1
    python3 - "$file" <<'PY'
import sys, math, statistics

path = sys.argv[1]
values = []
with open(path, 'r') as f:
    for line in f:
        try:
            x = float(line.strip())
            if math.isfinite(x):
                values.append(x)
        except:
            pass

n = len(values)
if n < 2:
    print("0,0,0,0,0,0,0,0,0,0")
    sys.exit(0)

values.sort()
mean = statistics.mean(values)
median = statistics.median(values)
stdev = statistics.stdev(values) if n > 1 else 0.0

# quantiles
if n >= 4:
    q1 = statistics.quantiles(values, n=4, method='inclusive')[0]
    q3 = statistics.quantiles(values, n=4, method='inclusive')[2]
else:
    q1 = values[0]
    q3 = values[-1]
iqr = q3 - q1

# Outlier detection (1.5*IQR)
lower = q1 - 1.5 * iqr
upper = q3 + 1.5 * iqr
outliers = [x for x in values if x < lower or x > upper]
outlier_count = len(outliers)

# Trimmed mean (5%)
trim = int(0.05 * n)
trimmed = values[trim:n-trim] if n - 2*trim > 0 else values
trimmed_mean = statistics.mean(trimmed) if trimmed else mean

print(f"{mean:.9f},{median:.9f},{stdev:.9f},{q1:.9f},{q3:.9f},{iqr:.9f},{outlier_count},{trimmed_mean:.9f},{values[0]:.9f},{values[-1]:.9f}")
PY
}

# ---------- ฟังก์ชันทดสอบ config ----------
test_config() {
    local label=$1
    local offset=$2
    local scale=$3
    local smooth=$4
    local load=$5

    echo -e "\n${YELLOW}▶ Testing: $label${NC} (load=$load)"
    echo "  offset=$offset, scale=$scale, smooth=$smooth"

    declare -a sample_files_0 sample_files_1

    for round in $(seq 1 $ROUNDS); do
        echo -n "    Round $round/$ROUNDS BURST=0: " >&2
        SAMPLE_FILE_0=$(run_test 0 $offset $scale $smooth $load $round "$label")
        sample_files_0+=("$SAMPLE_FILE_0")
        echo -n " Round $round/$ROUNDS BURST=1: " >&2
        SAMPLE_FILE_1=$(run_test 1 $offset $scale $smooth $load $round "$label")
        sample_files_1+=("$SAMPLE_FILE_1")
    done

    # รวม samples
    COMBINED_0=$(mktemp)
    COMBINED_1=$(mktemp)
    for f in "${sample_files_0[@]}"; do cat "$f" >> "$COMBINED_0"; done
    for f in "${sample_files_1[@]}"; do cat "$f" >> "$COMBINED_1"; done

    STATS_0=$(compute_robust_stats "$COMBINED_0")
    STATS_1=$(compute_robust_stats "$COMBINED_1")

    MED0=$(echo "$STATS_0" | cut -d',' -f2)
    MED1=$(echo "$STATS_1" | cut -d',' -f2)
    TRIMMED0=$(echo "$STATS_0" | cut -d',' -f8)
    TRIMMED1=$(echo "$STATS_1" | cut -d',' -f8)
    OUTLIER0=$(echo "$STATS_0" | cut -d',' -f7)
    OUTLIER1=$(echo "$STATS_1" | cut -d',' -f7)

    IMPROV_MED=$(awk -v m0="$MED0" -v m1="$MED1" 'BEGIN { if(m0==0) print 0; else printf "%.2f", ((m0-m1)/m0)*100 }')
    IMPROV_TRIMMED=$(awk -v t0="$TRIMMED0" -v t1="$TRIMMED1" 'BEGIN { if(t0==0) print 0; else printf "%.2f", ((t0-t1)/t0)*100 }')

    echo "$label,$offset,$scale,$smooth,$load,$ROUNDS,$MED0,$MED1,$IMPROV_MED,$TRIMMED0,$TRIMMED1,$IMPROV_TRIMMED,$OUTLIER0,$OUTLIER1" >> "$RESULT_CSV"

    echo -e "\n  📊 Robust Summary (Median of combined samples):"
    echo "    BURST=0: Median=$MED0 usecs/op (trimmed_mean=$TRIMMED0, outliers=$OUTLIER0)"
    echo "    BURST=1: Median=$MED1 usecs/op (trimmed_mean=$TRIMMED1, outliers=$OUTLIER1)"
    echo "    Improvement (Median): $IMPROV_MED%"
    echo "    Improvement (Trimmed Mean): $IMPROV_TRIMMED%"

    if (( $(echo "$MED1 < $MED0" | bc -l 2>/dev/null) )); then
        echo -e "    Result: ${GREEN}BURST=1 ดีกว่า (Median)${NC}"
    elif (( $(echo "$MED0 < $MED1" | bc -l 2>/dev/null) )); then
        echo -e "    Result: ${RED}BURST=0 ดีกว่า (Median)${NC}"
    else
        echo "    Result: เสมอกัน (Median)"
    fi

    rm -f "$COMBINED_0" "$COMBINED_1"
}

# ---------- ฟังก์ชันหลัก ----------
main() {
    clear
    echo "=================================================================="
    echo "  BMQ_BURST Robust Benchmark (Thermal-Controlled + Randomized)"
    echo "=================================================================="
    echo "Date: $(date)"
    echo "Samples per round: $SAMPLES"
    echo "Iterations per sample: $ITER"
    echo "Rounds per config: $ROUNDS"
    echo "Stress cores: $CORES"
    echo "Stress duration: ${DURATION}s"
    echo "Sleep between configs: ${SLEEP_BETWEEN}s"
    echo "Result dir: $RESULT_DIR"
    echo "=================================================================="
    echo ""
    echo "⚠️  This benchmark will take significant time (approx 3-4 hours)."
    echo "   It includes thermal cooldown, randomized order, and robust outlier handling."
    echo ""

    read_current_tunables
    echo "📌 Current sysctl values:"
    echo "  sched_bmq_burst = $BURST"
    echo "  sched_bmq_burst_penalty_offset = $OFFSET"
    echo "  sched_bmq_burst_penalty_scale = $SCALE"
    echo "  sched_bmq_burst_smoothness_shift = $SMOOTH"
    echo ""

    TEST_CASES=(
        "Offset30,30,1536,1,yes"
        "Offset31,31,1536,1,yes"
        "Offset32,32,1536,1,yes"
        "Offset33,33,1536,1,yes"
        "Offset34,34,1536,1,yes"
        "Scale1400,32,1400,1,yes"
        "Scale1500,32,1500,1,yes"
        "Scale1600,32,1600,1,yes"
        "Scale1700,32,1700,1,yes"
        "Smooth0,32,1536,0,yes"
        "Smooth1,32,1536,1,yes"
        "Smooth2,32,1536,2,yes"
        "Best_Guess,31,1550,1,yes"
        "Best_Guess2,33,1520,1,yes"
        "NoLoad_Default,24,1536,1,no"
        "NoLoad_Best,32,1536,1,no"
    )

    if command -v shuf &>/dev/null; then
        RANDOMIZED_TESTS=($(printf "%s\n" "${TEST_CASES[@]}" | shuf))
    else
        RANDOMIZED_TESTS=($(printf "%s\n" "${TEST_CASES[@]}" | sort -R))
    fi

    echo "🧪 Randomized Test Order:"
    for tc in "${RANDOMIZED_TESTS[@]}"; do
        IFS=',' read -r label offset scale smooth load <<< "$tc"
        echo "  - $label (offset=$offset, scale=$scale, smooth=$smooth, load=$load)"
    done

    echo "Test,offset,scale,smooth,load,Rounds,Median_BURST0,Median_BURST1,Improvement_Median%,TrimmedMean_BURST0,TrimmedMean_BURST1,Improvement_Trimmed%,Outliers_BURST0,Outliers_BURST1" > "$RESULT_CSV"

    echo -e "\n${YELLOW}🔄 Running tests... (randomized order, with cooldown)${NC}\n"

    local first=1
    for tc in "${RANDOMIZED_TESTS[@]}"; do
        IFS=',' read -r label offset scale smooth load <<< "$tc"

        if [[ $first -eq 0 ]]; then
            echo -e "\n${YELLOW}⏳ Cooling down for ${SLEEP_BETWEEN}s...${NC}"
            sleep $SLEEP_BETWEEN
            local temp=$(get_temp)
            while [[ $temp -gt $COOLDOWN_TEMP ]]; do
                echo -e "${YELLOW}⚠️  Temperature still at ${temp}°C (target <=${COOLDOWN_TEMP}°C). Waiting 30s...${NC}"
                sleep 30
                temp=$(get_temp)
            done
        fi
        first=0

        test_config "$label" "$offset" "$scale" "$smooth" "$load"
    done

    echo -e "\n=================================================================="
    echo -e "${GREEN}✅ All tests complete!${NC}"
    echo "=================================================================="

    echo -e "\n📊 Results Summary (with load, sorted by improvement using Median):"
    echo "------------------------------------------------------------"
    echo "Test | BURST=0 Median | BURST=1 Median | Improvement % | Outliers(0/1)"
    echo "------------------------------------------------------------"

    grep ",yes," "$RESULT_CSV" | tail -n +2 | sort -t',' -k9 -rn | while IFS=',' read -r label offset scale smooth load rounds med0 med1 imp_med trim0 trim1 imp_trim out0 out1; do
        printf "%-20s | %8.4f | %8.4f | %+7.2f%% | %2d / %2d\n" "$label" "$med0" "$med1" "$imp_med" "$out0" "$out1"
    done

    echo "------------------------------------------------------------"
    echo ""
    echo -e "\n📊 No-Load Results (overhead only):"
    echo "------------------------------------------------------------"
    grep ",no," "$RESULT_CSV" | tail -n +2 | while IFS=',' read -r label offset scale smooth load rounds med0 med1 imp_med trim0 trim1 imp_trim out0 out1; do
        printf "%-20s | %8.4f | %8.4f | %+7.2f%% | %2d / %2d\n" "$label" "$med0" "$med1" "$imp_med" "$out0" "$out1"
    done

    echo "------------------------------------------------------------"
    echo ""
    echo "📁 Full results saved to: $RESULT_CSV"
    echo "📁 Raw samples saved in: $RAW_SAMPLES_DIR"
    echo "📁 Temperature log: $TEMP_LOG"

    BEST_LABEL=$(grep ",yes," "$RESULT_CSV" | tail -n +2 | sort -t',' -k9 -rn | head -1 | cut -d',' -f1)
    BEST_OFFSET=$(grep ",yes," "$RESULT_CSV" | tail -n +2 | sort -t',' -k9 -rn | head -1 | cut -d',' -f2)
    BEST_SCALE=$(grep ",yes," "$RESULT_CSV" | tail -n +2 | sort -t',' -k9 -rn | head -1 | cut -d',' -f3)
    BEST_SMOOTH=$(grep ",yes," "$RESULT_CSV" | tail -n +2 | sort -t',' -k9 -rn | head -1 | cut -d',' -f4)
    BEST_IMP=$(grep ",yes," "$RESULT_CSV" | tail -n +2 | sort -t',' -k9 -rn | head -1 | cut -d',' -f9)

    echo ""
    echo "🏆 Best combination found (using Median, robust to outliers):"
    echo "  $BEST_LABEL: offset=$BEST_OFFSET, scale=$BEST_SCALE, smooth=$BEST_SMOOTH"
    echo "  Improvement: $BEST_IMP%"
    echo ""
    echo "🔁 To apply these settings:"
    echo "  echo 1 | sudo tee /proc/sys/kernel/sched_bmq_burst"
    echo "  echo $BEST_OFFSET | sudo tee /proc/sys/kernel/sched_bmq_burst_penalty_offset"
    echo "  echo $BEST_SCALE | sudo tee /proc/sys/kernel/sched_bmq_burst_penalty_scale"
    echo "  echo $BEST_SMOOTH | sudo tee /proc/sys/kernel/sched_bmq_burst_smoothness_shift"
}

main "$@"