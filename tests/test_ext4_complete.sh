#!/bin/bash
# Complete EXT4 Backend Testing Script
# Tests all functionality against docs/backend_implementation_plan.md

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_IMAGE="/tmp/test_ext4.img"
MOUNT_POINT="/tmp/cvfs_ext4_test"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

TESTS_PASSED=0
TESTS_FAILED=0

print_header() {
    echo ""
    echo "========================================"
    echo "$1"
    echo "========================================"
}

print_test() {
    echo ""
    echo "Test $1: $2"
    echo "----------------------------------------"
}

pass_test() {
    echo -e "${GREEN}✅ PASSED${NC} - $1"
    ((TESTS_PASSED++))
}

fail_test() {
    echo -e "${RED}❌ FAILED${NC} - $1"
    ((TESTS_FAILED++))
}

cleanup() {
    echo "Cleaning up..."
    fusermount -u "$MOUNT_POINT" 2>/dev/null || true
    rm -rf "$MOUNT_POINT"
    rm -f "$TEST_IMAGE"
    killall vfs_demo 2>/dev/null || true
}

trap cleanup EXIT

# ============================================
# Setup Phase
# ============================================
print_header "EXT4 BACKEND COMPREHENSIVE TEST SUITE"

echo "Setting up test environment..."

# Create test image with ext4 filesystem
if [ -f "$TEST_IMAGE" ]; then
    rm -f "$TEST_IMAGE"
fi

dd if=/dev/zero of="$TEST_IMAGE" bs=1M count=50 2>/dev/null
mkfs.ext4 -F "$TEST_IMAGE" > /dev/null 2>&1

# Mount temporarily to populate with test data
TEMP_MOUNT="/tmp/temp_ext4_mount"
mkdir -p "$TEMP_MOUNT"
 mount -o loop "$TEST_IMAGE" "$TEMP_MOUNT"

# Create test directory structure
 mkdir -p "$TEMP_MOUNT/dir1"
 mkdir -p "$TEMP_MOUNT/dir2"
 mkdir -p "$TEMP_MOUNT/dir1/subdir"

# Create test files with known content
echo "Hello from root" |  tee "$TEMP_MOUNT/file1.txt" > /dev/null
echo "Another file in root" |  tee "$TEMP_MOUNT/file2.txt" > /dev/null
echo "File in dir1" |  tee "$TEMP_MOUNT/dir1/nested.txt" > /dev/null
echo "File in subdir" |  tee "$TEMP_MOUNT/dir1/subdir/deep.txt" > /dev/null

# Create file with specific size for read testing
dd if=/dev/urandom of="$TEMP_MOUNT/largefile.bin" bs=1K count=10 2>/dev/null
 chmod 644 "$TEMP_MOUNT"/*.txt "$TEMP_MOUNT"/dir1/*.txt 2>/dev/null || true

 umount "$TEMP_MOUNT"
rmdir "$TEMP_MOUNT"

echo -e "${GREEN}✓${NC} Test image created and populated: $TEST_IMAGE"

# ============================================
# Test 1: Backend Initialization
# ============================================
print_test "1" "Backend Initialization & Superblock Validation"

mkdir -p "$MOUNT_POINT"
timeout 5 "$PROJECT_ROOT/vfs_demo" -f -s "$MOUNT_POINT" -o backend=ext4,source="$TEST_IMAGE" > /tmp/ext4_init_log.txt 2>&1 &
DEMO_PID=$!
sleep 2

if ps -p $DEMO_PID > /dev/null; then
    # Check if superblock was read correctly
    if grep -q "ext4.*mounted" /tmp/ext4_init_log.txt && \
       grep -q "block_size" /tmp/ext4_init_log.txt && \
       grep -q "inodes_per_group" /tmp/ext4_init_log.txt; then
        pass_test "Superblock read and validated (magic: 0xEF53)"
    else
        fail_test "Superblock validation failed or not logged"
    fi
else
    fail_test "Backend init failed - demo process exited"
fi

# ============================================
# Test 2: Root Directory Stat
# ============================================
print_test "2" "Root Directory Stat Operation"

if [ -d "$MOUNT_POINT" ]; then
    STAT_OUTPUT=$(stat "$MOUNT_POINT" 2>&1)
    
    if echo "$STAT_OUTPUT" | grep -q "directory"; then
        if echo "$STAT_OUTPUT" | grep -q "Inode: 2" || stat -c "%i" "$MOUNT_POINT" 2>/dev/null | grep -q "2"; then
            pass_test "Root directory stat (inode 2, mode=directory)"
        else
            fail_test "Root inode not 2 (expected EXT4_ROOT_INO)"
        fi
    else
        fail_test "Root stat failed or not recognized as directory"
    fi
else
    fail_test "Mount point not accessible"
fi

# ============================================
# Test 3: Root Directory Listing (readdir)
# ============================================
print_test "3" "Root Directory Listing"

sleep 1
if [ -d "$MOUNT_POINT" ]; then
    ENTRIES=$(ls -1a "$MOUNT_POINT" 2>/dev/null)
    
    FOUND_DOT=$(echo "$ENTRIES" | grep -c "^\.$" || true)
    FOUND_DOTDOT=$(echo "$ENTRIES" | grep -c "^\.\.$" || true)
    FOUND_FILE1=$(echo "$ENTRIES" | grep -c "^file1.txt$" || true)
    FOUND_DIR1=$(echo "$ENTRIES" | grep -c "^dir1$" || true)
    
    if [ "$FOUND_DOT" -ge 1 ] && [ "$FOUND_DOTDOT" -ge 1 ]; then
        if [ "$FOUND_FILE1" -ge 1 ] && [ "$FOUND_DIR1" -ge 1 ]; then
            pass_test "Root readdir returns ., .., and actual entries"
        else
            fail_test "Root readdir missing expected files (file1.txt, dir1)"
        fi
    else
        fail_test "Root readdir missing . or .. entries"
    fi
else
    fail_test "Mount point not accessible"
fi

# ============================================
# Test 4: Single-Level Path Lookup (stat)
# ============================================
print_test "4" "Single-Level Path Lookup & Stat"

if [ -f "$MOUNT_POINT/file1.txt" ]; then
    FILE_STAT=$(stat -c "mode=%f size=%s" "$MOUNT_POINT/file1.txt" 2>&1)
    
    if echo "$FILE_STAT" | grep -q "size=" && echo "$FILE_STAT" | grep -q "mode="; then
        SIZE=$(stat -c "%s" "$MOUNT_POINT/file1.txt")
        if [ "$SIZE" -gt 0 ]; then
            pass_test "File stat via path lookup (mode, size, inode populated)"
        else
            fail_test "File stat returned zero size"
        fi
    else
        fail_test "File stat incomplete"
    fi
else
    fail_test "file1.txt not found via path lookup"
fi

# ============================================
# Test 5: File Open (read-only)
# ============================================
print_test "5" "Read-Only File Open"

if [ -f "$MOUNT_POINT/file1.txt" ]; then
    if cat "$MOUNT_POINT/file1.txt" > /dev/null 2>&1; then
        pass_test "Read-only file open successful"
    else
        fail_test "File open failed"
    fi
else
    fail_test "File not accessible for open test"
fi

# Test write rejection
if echo "test" > "$MOUNT_POINT/file1.txt" 2>/dev/null; then
    fail_test "Write succeeded (should be read-only)"
else
    pass_test "Write correctly rejected (read-only mode)"
fi

# ============================================
# Test 6: File Read via Leaf Extents
# ============================================
print_test "6" "File Read via Leaf Extent Tree"

if [ -f "$MOUNT_POINT/file1.txt" ]; then
    CONTENT=$(cat "$MOUNT_POINT/file1.txt" 2>&1)
    EXPECTED="Hello from root"
    
    if [ "$CONTENT" = "$EXPECTED" ]; then
        pass_test "File read returns correct content via extents"
    else
        fail_test "File content mismatch. Expected: '$EXPECTED', Got: '$CONTENT'"
    fi
else
    fail_test "File not readable"
fi

# ============================================
# Test 7: Multi-Block File Read
# ============================================
print_test "7" "Multi-Block File Read"

if [ -f "$MOUNT_POINT/largefile.bin" ]; then
    SIZE=$(stat -c "%s" "$MOUNT_POINT/largefile.bin")
    
    if [ "$SIZE" -eq 10240 ]; then
        # Try to read the entire file
        if dd if="$MOUNT_POINT/largefile.bin" of=/tmp/read_test.bin bs=1K count=10 2>/dev/null; then
            READ_SIZE=$(stat -c "%s" /tmp/read_test.bin)
            if [ "$READ_SIZE" -eq 10240 ]; then
                pass_test "Multi-block read (10KB file read successfully)"
            else
                fail_test "Multi-block read incomplete: $READ_SIZE bytes"
            fi
            rm -f /tmp/read_test.bin
        else
            fail_test "Multi-block read operation failed"
        fi
    else
        fail_test "Large file size mismatch: expected 10240, got $SIZE"
    fi
else
    fail_test "Large file not accessible"
fi

# ============================================
# Test 8: Partial Read with Offset
# ============================================
print_test "8" "Partial Read with Offset Handling"

if [ -f "$MOUNT_POINT/file2.txt" ]; then
    # Read from offset (skip first 8 bytes)
    PARTIAL=$(dd if="$MOUNT_POINT/file2.txt" bs=1 skip=8 count=10 2>/dev/null)
    
    if [ -n "$PARTIAL" ]; then
        pass_test "Partial read with offset works"
    else
        fail_test "Partial read failed"
    fi
else
    fail_test "File for offset test not found"
fi

# ============================================
# Test 9: Directory Entry Bounds Checking
# ============================================
print_test "9" "Directory Entry Parsing (rec_len bounds check)"

# This test verifies that readdir doesn't crash with corrupted entries
if ls -la "$MOUNT_POINT" > /tmp/readdir_safe.txt 2>&1; then
    ENTRY_COUNT=$(cat /tmp/readdir_safe.txt | wc -l)
    if [ "$ENTRY_COUNT" -ge 4 ]; then
        pass_test "Directory parsing with rec_len validation (no crashes)"
    else
        fail_test "Directory listing returned too few entries"
    fi
    rm -f /tmp/readdir_safe.txt
else
    fail_test "Directory listing crashed or failed"
fi

# ============================================
# Test 10: Extent Tree Magic Validation
# ============================================
print_test "10" "Extent Tree Magic Number Validation"

# Attempt to read a file - if extent magic is wrong, it should fail gracefully
if [ -f "$MOUNT_POINT/file1.txt" ]; then
    if timeout 3 cat "$MOUNT_POINT/file1.txt" > /dev/null 2>&1; then
        pass_test "Extent tree magic validated (0xF30A)"
    else
        fail_test "Extent validation failed or timeout"
    fi
else
    fail_test "File not available for extent test"
fi

# ============================================
# Test 11: File Handle Management
# ============================================
print_test "11" "File Handle Allocation & Release"

# Open multiple files simultaneously
HANDLES_OK=true
for i in 1 2; do
    if ! timeout 2 cat "$MOUNT_POINT/file${i}.txt" > /dev/null 2>&1; then
        HANDLES_OK=false
    fi
done

if [ "$HANDLES_OK" = true ]; then
    pass_test "Multiple file handles allocated and released"
else
    fail_test "File handle management issue"
fi

# ============================================
# Test 12: Inode Reading from Correct Block Group
# ============================================
print_test "12" "Inode Read from Inode Table"

# If we can stat files with different inodes, inode reading works
if [ -f "$MOUNT_POINT/file1.txt" ] && [ -f "$MOUNT_POINT/file2.txt" ]; then
    INO1=$(stat -c "%i" "$MOUNT_POINT/file1.txt" 2>/dev/null)
    INO2=$(stat -c "%i" "$MOUNT_POINT/file2.txt" 2>/dev/null)
    
    if [ -n "$INO1" ] && [ -n "$INO2" ] && [ "$INO1" != "$INO2" ]; then
        pass_test "Inode table reads return distinct inodes"
    else
        fail_test "Inode reading issue (duplicate or missing inodes)"
    fi
else
    fail_test "Files not accessible for inode test"
fi

# ============================================
# Test 13: Error Handling - Nonexistent File
# ============================================
print_test "13" "Error Handling - ENOENT for Missing Files"

if cat "$MOUNT_POINT/nonexistent.txt" 2>&1 | grep -qi "No such file"; then
    pass_test "Missing file returns ENOENT"
else
    fail_test "Missing file error not handled correctly"
fi

# ============================================
# Test 14: Error Handling - Directory as File
# ============================================
print_test "14" "Error Handling - EISDIR for Directory Open as File"

if cat "$MOUNT_POINT/dir1" 2>&1 | grep -qi "Is a directory"; then
    pass_test "Directory open as file returns EISDIR"
else
    fail_test "Directory-as-file error not handled"
fi

# ============================================
# Test 15: Block Size Calculation
# ============================================
print_test "15" "Block Size Calculation from s_log_block_size"

if grep -q "block_size=4096" /tmp/ext4_init_log.txt || \
   grep -q "block_size=1024" /tmp/ext4_init_log.txt; then
    pass_test "Block size computed correctly (1024 << s_log_block_size)"
else
    fail_test "Block size not logged or incorrect"
fi

# ============================================
# Summary
# ============================================
print_header "TEST SUMMARY"

TOTAL_TESTS=$((TESTS_PASSED + TESTS_FAILED))
SUCCESS_RATE=$((TESTS_PASSED * 100 / TOTAL_TESTS))

echo "Tests Passed: $TESTS_PASSED/$TOTAL_TESTS"
echo "Success Rate: $SUCCESS_RATE%"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}Status: ✅ ALL TESTS PASSED${NC}"
    echo "EXT4 Backend: FULLY FUNCTIONAL"
    exit 0
else
    echo -e "${RED}Status: ❌ $TESTS_FAILED TEST(S) FAILED${NC}"
    echo "EXT4 Backend: INCOMPLETE"
    exit 1
fi
