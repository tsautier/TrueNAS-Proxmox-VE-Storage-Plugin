#!/bin/bash
#
# TrueNAS Storage Performance Benchmark Tool
#
# Establishes performance baselines for troubleshooting and capacity planning
# Tests storage operations and optionally runs I/O benchmarks with fio
#
# Usage: ./benchmark.sh [storage_name] [options]
# Examples:
#   ./benchmark.sh tnscale                    # Quick operation benchmarks
#   ./benchmark.sh tnscale --with-io          # Include fio I/O tests
#   ./benchmark.sh tnscale --size 50G         # Specify test volume size
#   ./benchmark.sh tnscale --output report.json  # Save results to JSON
#

set -e

# Configuration defaults
STORAGE_NAME="tnscale"
TEST_SIZE="10G"
TEST_SIZE_BYTES=$((10 * 1024 * 1024 * 1024))
WITH_IO_TESTS=false
OUTPUT_FILE=""
NODE_NAME=$(hostname)
TEST_VMID=9999
CLONE_VMID=9998

# Colors
GREEN='\033[38;5;157m'
BLUE='\033[38;5;153m'
YELLOW='\033[38;5;229m'
RED='\033[38;5;217m'
CYAN='\033[38;5;159m'
NC='\033[0m'

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --with-io)
            WITH_IO_TESTS=true
            shift
            ;;
        --size)
            TEST_SIZE="$2"
            # Convert size to bytes (simple parser for G/M suffix)
            if [[ "$TEST_SIZE" =~ ^([0-9]+)G$ ]]; then
                TEST_SIZE_BYTES=$((${BASH_REMATCH[1]} * 1024 * 1024 * 1024))
            elif [[ "$TEST_SIZE" =~ ^([0-9]+)M$ ]]; then
                TEST_SIZE_BYTES=$((${BASH_REMATCH[1]} * 1024 * 1024))
            fi
            shift 2
            ;;
        --output)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            STORAGE_NAME="$1"
            shift
            ;;
    esac
done

# Timestamp functions
get_timestamp_ms() {
    date +%s.%3N
}

get_duration() {
    local start=$1
    local end=$2
    echo "$end - $start" | bc
}

format_duration() {
    local duration=$1
    printf "%.3fs" "$duration"
}

# Header
echo ""
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  TrueNAS Storage Performance Benchmark${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""
echo -e "${BLUE}Storage:${NC}      $STORAGE_NAME"
echo -e "${BLUE}Test Size:${NC}    $TEST_SIZE"
echo -e "${BLUE}Node:${NC}         $NODE_NAME"
echo -e "${BLUE}Date:${NC}         $(date '+%Y-%m-%d %H:%M:%S')"
echo -e "${BLUE}I/O Tests:${NC}    $([ "$WITH_IO_TESTS" = true ] && echo "Enabled" || echo "Disabled (use --with-io to enable)")"
echo ""

# Results storage
declare -A RESULTS

# Cleanup function
cleanup() {
    echo ""
    echo -e "${YELLOW}Cleaning up test resources...${NC}"

    # Destroy clone VM if exists
    if qm status $CLONE_VMID >/dev/null 2>&1; then
        qm destroy $CLONE_VMID --purge >/dev/null 2>&1 || true
    fi

    # Destroy test VM if exists
    if qm status $TEST_VMID >/dev/null 2>&1; then
        qm destroy $TEST_VMID --purge >/dev/null 2>&1 || true
    fi

    echo -e "${GREEN}✓${NC} Cleanup complete"
}

trap cleanup EXIT

# Check if storage exists
echo -e "${BLUE}Verifying storage configuration...${NC}"
if ! pvesm status | grep -q "^$STORAGE_NAME"; then
    echo -e "${RED}Error: Storage '$STORAGE_NAME' not found${NC}"
    exit 1
fi

STORAGE_STATUS=$(pvesm status | grep "^$STORAGE_NAME" | awk '{print $3}')
if [ "$STORAGE_STATUS" != "active" ]; then
    echo -e "${RED}Error: Storage '$STORAGE_NAME' is not active (status: $STORAGE_STATUS)${NC}"
    exit 1
fi
echo -e "${GREEN}✓${NC} Storage is active"
echo ""

# Ensure test VMs don't exist
if qm status $TEST_VMID >/dev/null 2>&1; then
    echo -e "${YELLOW}Warning: Test VM $TEST_VMID already exists, destroying...${NC}"
    qm destroy $TEST_VMID --purge >/dev/null 2>&1
fi

if qm status $CLONE_VMID >/dev/null 2>&1; then
    echo -e "${YELLOW}Warning: Clone VM $CLONE_VMID already exists, destroying...${NC}"
    qm destroy $CLONE_VMID --purge >/dev/null 2>&1
fi

echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Storage Operations Benchmark${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""

# Test 1: VM Creation
echo -e "${BLUE}[1/6] VM Creation${NC}"
START=$(get_timestamp_ms)
qm create $TEST_VMID --name "benchmark-test-$$" --memory 512 --cores 1 --net0 virtio,bridge=vmbr0 >/dev/null
END=$(get_timestamp_ms)
DURATION=$(get_duration $START $END)
RESULTS[vm_create]=$DURATION
echo -e "      Duration: ${GREEN}$(format_duration $DURATION)${NC}"
echo ""

# Test 2: Volume Creation (via qm set - size in MB for Proxmox)
echo -e "${BLUE}[2/6] Volume Creation ($TEST_SIZE)${NC}"
# Extract numeric size in GB and convert to MB (e.g., "10G" -> "10240")
SIZE_GB=$(echo "$TEST_SIZE" | sed 's/G$//')
SIZE_MB=$((SIZE_GB * 1024))
START=$(get_timestamp_ms)
qm set $TEST_VMID --scsi0 "$STORAGE_NAME:$SIZE_MB" >/dev/null 2>&1
END=$(get_timestamp_ms)
DURATION=$(get_duration $START $END)
RESULTS[volume_create]=$DURATION
echo -e "      Duration: ${GREEN}$(format_duration $DURATION)${NC}"
echo ""

# Test 3: Snapshot Creation
echo -e "${BLUE}[3/6] Snapshot Creation${NC}"
START=$(get_timestamp_ms)
qm snapshot $TEST_VMID benchmark-snap >/dev/null
END=$(get_timestamp_ms)
DURATION=$(get_duration $START $END)
RESULTS[snapshot_create]=$DURATION
echo -e "      Duration: ${GREEN}$(format_duration $DURATION)${NC}"
echo ""

# Test 4: VM Clone Operation
echo -e "${BLUE}[4/6] VM Clone Operation${NC}"
START=$(get_timestamp_ms)
qm clone $TEST_VMID $CLONE_VMID --name "benchmark-clone-$$" >/dev/null
END=$(get_timestamp_ms)
DURATION=$(get_duration $START $END)
RESULTS[clone_operation]=$DURATION
echo -e "      Duration: ${GREEN}$(format_duration $DURATION)${NC}"
echo ""

# Test 5: Volume Resize
echo -e "${BLUE}[5/6] Volume Resize (+2G)${NC}"
START=$(get_timestamp_ms)
qm resize $TEST_VMID scsi0 +2G >/dev/null
END=$(get_timestamp_ms)
DURATION=$(get_duration $START $END)
RESULTS[volume_resize]=$DURATION
echo -e "      Duration: ${GREEN}$(format_duration $DURATION)${NC}"
echo ""

# Test 6: Snapshot Deletion
echo -e "${BLUE}[6/6] Snapshot Deletion${NC}"
START=$(get_timestamp_ms)
qm delsnapshot $TEST_VMID benchmark-snap >/dev/null
END=$(get_timestamp_ms)
DURATION=$(get_duration $START $END)
RESULTS[snapshot_delete]=$DURATION
echo -e "      Duration: ${GREEN}$(format_duration $DURATION)${NC}"
echo ""

# I/O Performance Tests (optional)
if [ "$WITH_IO_TESTS" = true ]; then
    # Check if fio is installed
    if ! command -v fio &> /dev/null; then
        echo -e "${YELLOW}Warning: fio not installed, skipping I/O tests${NC}"
        echo -e "${YELLOW}Install with: apt-get install fio${NC}"
        echo ""
    else
        echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
        echo -e "${CYAN}  I/O Performance Tests (fio)${NC}"
        echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
        echo ""

        # Start the test VM
        echo -e "${BLUE}Starting VM for I/O tests...${NC}"
        qm start $TEST_VMID >/dev/null
        sleep 5

        # Get the disk device path
        DISK_PATH=$(qm config $TEST_VMID | grep "^scsi0:" | awk '{print $2}')
        DEVICE="/dev/disk/by-id/scsi-0QEMU_QEMU_HARDDISK_drive-scsi0"

        if [ -e "$DEVICE" ]; then
            # Sequential Write Test
            echo -e "${BLUE}[7/10] Sequential Write Test${NC}"
            FIO_OUTPUT=$(fio --name=seqwrite --rw=write --bs=1M --size=1G --numjobs=1 \
                --filename=$DEVICE --direct=1 --group_reporting --output-format=json 2>/dev/null || echo "{}")
            SEQ_WRITE_BW=$(echo "$FIO_OUTPUT" | jq -r '.jobs[0].write.bw // 0' 2>/dev/null || echo "0")
            RESULTS[seq_write_mbps]=$(echo "scale=2; $SEQ_WRITE_BW / 1024" | bc)
            echo -e "      Bandwidth: ${GREEN}${RESULTS[seq_write_mbps]} MB/s${NC}"
            echo ""

            # Sequential Read Test
            echo -e "${BLUE}[8/10] Sequential Read Test${NC}"
            FIO_OUTPUT=$(fio --name=seqread --rw=read --bs=1M --size=1G --numjobs=1 \
                --filename=$DEVICE --direct=1 --group_reporting --output-format=json 2>/dev/null || echo "{}")
            SEQ_READ_BW=$(echo "$FIO_OUTPUT" | jq -r '.jobs[0].read.bw // 0' 2>/dev/null || echo "0")
            RESULTS[seq_read_mbps]=$(echo "scale=2; $SEQ_READ_BW / 1024" | bc)
            echo -e "      Bandwidth: ${GREEN}${RESULTS[seq_read_mbps]} MB/s${NC}"
            echo ""

            # Random Read IOPS Test
            echo -e "${BLUE}[9/10] Random Read IOPS (4K)${NC}"
            FIO_OUTPUT=$(fio --name=randread --rw=randread --bs=4k --size=1G --numjobs=1 \
                --filename=$DEVICE --direct=1 --group_reporting --output-format=json 2>/dev/null || echo "{}")
            RAND_READ_IOPS=$(echo "$FIO_OUTPUT" | jq -r '.jobs[0].read.iops // 0' 2>/dev/null || echo "0")
            RESULTS[rand_read_iops]=$(printf "%.0f" "$RAND_READ_IOPS")
            echo -e "      IOPS: ${GREEN}${RESULTS[rand_read_iops]}${NC}"
            echo ""

            # Random Write IOPS Test
            echo -e "${BLUE}[10/10] Random Write IOPS (4K)${NC}"
            FIO_OUTPUT=$(fio --name=randwrite --rw=randwrite --bs=4k --size=1G --numjobs=1 \
                --filename=$DEVICE --direct=1 --group_reporting --output-format=json 2>/dev/null || echo "{}")
            RAND_WRITE_IOPS=$(echo "$FIO_OUTPUT" | jq -r '.jobs[0].write.iops // 0' 2>/dev/null || echo "0")
            RESULTS[rand_write_iops]=$(printf "%.0f" "$RAND_WRITE_IOPS")
            echo -e "      IOPS: ${GREEN}${RESULTS[rand_write_iops]}${NC}"
            echo ""
        else
            echo -e "${YELLOW}Warning: Could not access disk device, skipping I/O tests${NC}"
            echo ""
        fi

        # Stop the VM
        qm stop $TEST_VMID >/dev/null 2>&1 || true
        sleep 2
    fi
fi

# Generate Results Report
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${CYAN}  Performance Benchmark Results${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""

echo -e "${BLUE}Storage Operations:${NC}"
printf "  %-25s %10s   %s\n" "Operation" "Duration" "Status"
echo "  ───────────────────────────────────────────────────────"

evaluate_operation() {
    local name=$1
    local duration=$2
    local warn_threshold=$3
    local fail_threshold=$4

    local status="${GREEN}GOOD${NC}"
    if (( $(echo "$duration > $fail_threshold" | bc -l) )); then
        status="${RED}POOR${NC}"
    elif (( $(echo "$duration > $warn_threshold" | bc -l) )); then
        status="${YELLOW}FAIR${NC}"
    fi

    printf "  %-25s %9.3fs   %b\n" "$name" "$duration" "$status"
}

evaluate_operation "VM Create" "${RESULTS[vm_create]}" 2.0 5.0
evaluate_operation "Volume Create ($TEST_SIZE)" "${RESULTS[volume_create]}" 5.0 15.0
evaluate_operation "Snapshot Create" "${RESULTS[snapshot_create]}" 2.0 5.0
evaluate_operation "Clone Operation" "${RESULTS[clone_operation]}" 60.0 120.0
evaluate_operation "Volume Resize" "${RESULTS[volume_resize]}" 3.0 10.0
evaluate_operation "Snapshot Delete" "${RESULTS[snapshot_delete]}" 2.0 5.0

echo ""

if [ "$WITH_IO_TESTS" = true ] && [ -n "${RESULTS[seq_write_mbps]}" ]; then
    echo -e "${BLUE}I/O Performance:${NC}"
    printf "  %-25s %10s   %s\n" "Test" "Result" "Status"
    echo "  ───────────────────────────────────────────────────────"

    # Sequential Write
    SEQ_WRITE=${RESULTS[seq_write_mbps]}
    SEQ_WRITE_STATUS="${GREEN}GOOD${NC}"
    if (( $(echo "$SEQ_WRITE < 50" | bc -l) )); then
        SEQ_WRITE_STATUS="${RED}POOR${NC}"
    elif (( $(echo "$SEQ_WRITE < 100" | bc -l) )); then
        SEQ_WRITE_STATUS="${YELLOW}FAIR${NC}"
    fi
    printf "  %-25s %8.2f MB/s   %b\n" "Sequential Write" "$SEQ_WRITE" "$SEQ_WRITE_STATUS"

    # Sequential Read
    SEQ_READ=${RESULTS[seq_read_mbps]}
    SEQ_READ_STATUS="${GREEN}GOOD${NC}"
    if (( $(echo "$SEQ_READ < 50" | bc -l) )); then
        SEQ_READ_STATUS="${RED}POOR${NC}"
    elif (( $(echo "$SEQ_READ < 100" | bc -l) )); then
        SEQ_READ_STATUS="${YELLOW}FAIR${NC}"
    fi
    printf "  %-25s %8.2f MB/s   %b\n" "Sequential Read" "$SEQ_READ" "$SEQ_READ_STATUS"

    # Random Read IOPS
    RAND_READ=${RESULTS[rand_read_iops]}
    RAND_READ_STATUS="${GREEN}GOOD${NC}"
    if (( $(echo "$RAND_READ < 500" | bc -l) )); then
        RAND_READ_STATUS="${RED}POOR${NC}"
    elif (( $(echo "$RAND_READ < 1000" | bc -l) )); then
        RAND_READ_STATUS="${YELLOW}FAIR${NC}"
    fi
    printf "  %-25s %9.0f IOPS   %b\n" "Random Read (4K)" "$RAND_READ" "$RAND_READ_STATUS"

    # Random Write IOPS
    RAND_WRITE=${RESULTS[rand_write_iops]}
    RAND_WRITE_STATUS="${GREEN}GOOD${NC}"
    if (( $(echo "$RAND_WRITE < 500" | bc -l) )); then
        RAND_WRITE_STATUS="${RED}POOR${NC}"
    elif (( $(echo "$RAND_WRITE < 1000" | bc -l) )); then
        RAND_WRITE_STATUS="${YELLOW}FAIR${NC}"
    fi
    printf "  %-25s %9.0f IOPS   %b\n" "Random Write (4K)" "$RAND_WRITE" "$RAND_WRITE_STATUS"

    echo ""
fi

# Overall Score
echo -e "${BLUE}Expected Baseline Values:${NC}"
echo "  VM Create:           < 2s     (Good),  < 5s     (Fair),  > 5s     (Poor)"
echo "  Volume Create:       < 5s     (Good),  < 15s    (Fair),  > 15s    (Poor)"
echo "  Snapshot Create:     < 2s     (Good),  < 5s     (Fair),  > 5s     (Poor)"
echo "  Clone Operation:     < 60s    (Good),  < 120s   (Fair),  > 120s   (Poor)"
echo "  Volume Resize:       < 3s     (Good),  < 10s    (Fair),  > 10s    (Poor)"
if [ "$WITH_IO_TESTS" = true ]; then
    echo "  Sequential Write:    > 100MB/s (Good),  > 50MB/s  (Fair),  < 50MB/s  (Poor)"
    echo "  Sequential Read:     > 100MB/s (Good),  > 50MB/s  (Fair),  < 50MB/s  (Poor)"
    echo "  Random IOPS:         > 1000    (Good),  > 500     (Fair),  < 500     (Poor)"
fi
echo ""

# Save JSON output if requested
if [ -n "$OUTPUT_FILE" ]; then
    echo -e "${BLUE}Saving results to: ${OUTPUT_FILE}${NC}"

    cat > "$OUTPUT_FILE" << EOF
{
  "benchmark": {
    "storage": "$STORAGE_NAME",
    "node": "$NODE_NAME",
    "test_size": "$TEST_SIZE",
    "test_size_bytes": $TEST_SIZE_BYTES,
    "timestamp": "$(date -Iseconds)",
    "with_io_tests": $WITH_IO_TESTS
  },
  "operations": {
    "vm_create_seconds": ${RESULTS[vm_create]},
    "volume_create_seconds": ${RESULTS[volume_create]},
    "snapshot_create_seconds": ${RESULTS[snapshot_create]},
    "clone_operation_seconds": ${RESULTS[clone_operation]},
    "volume_resize_seconds": ${RESULTS[volume_resize]},
    "snapshot_delete_seconds": ${RESULTS[snapshot_delete]}
  }$([ "$WITH_IO_TESTS" = true ] && [ -n "${RESULTS[seq_write_mbps]}" ] && cat << IOEOF || echo ""
,
  "io_performance": {
    "sequential_write_mbps": ${RESULTS[seq_write_mbps]},
    "sequential_read_mbps": ${RESULTS[seq_read_mbps]},
    "random_read_iops": ${RESULTS[rand_read_iops]},
    "random_write_iops": ${RESULTS[rand_write_iops]}
  }
IOEOF
)
}
EOF

    echo -e "${GREEN}✓${NC} Results saved"
    echo ""
fi

echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}Benchmark Complete!${NC}"
echo -e "${CYAN}═══════════════════════════════════════════════════════════${NC}"
echo ""

if [ "$WITH_IO_TESTS" = false ]; then
    echo -e "${YELLOW}Tip: Run with --with-io flag for comprehensive I/O performance tests${NC}"
    echo ""
fi
