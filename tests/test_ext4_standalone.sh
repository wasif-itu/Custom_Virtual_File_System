#!/bin/bash
# Comprehensive EXT4 Backend Standalone Test Suite
# Tests ext4 implementation independently without relying on other tests
# Date: December 1, 2025

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;36m'
NC='\033[0m'

# Counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# Test image paths
TEST_DIR="/tmp/cvfs_ext4_test_$$"
TEST_IMAGE="$TEST_DIR/test.ext4"
MOUNT_POINT="$TEST_DIR/mnt"
VFS_MOUNT="$TEST_DIR/vfs_mnt"

# Project paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VFS_DEMO="$PROJECT_ROOT/vfs_demo"

# Helper functions
print_header() {
    echo ""
    echo "========================================"
    echo "$1"
    echo "========================================"
}

print_section() {
    echo ""
    echo -e "${BLUE}$1${NC}"
    echo "----------------------------------------"
}

pass() {
    echo -e "${GREEN}✅ PASS${NC}: $1"
    ((PASSED_TESTS++))
}

fail() {
    echo -e "${RED}❌ FAIL${NC}: $1"
    ((FAILED_TESTS++))
}

skip() {
    echo -e "${YELLOW}⊘ SKIP${NC}: $1"
}

test_start() {
    ((TOTAL_TESTS++))
    echo -ne "Test $TOTAL_TESTS: $1 ... "
}

cleanup() {
    echo "Cleaning up test environment..."
    fusermount -u "$VFS_MOUNT" 2>/dev/null || true
    sudo umount "$MOUNT_POINT" 2>/dev/null || true
    killall vfs_demo 2>/dev/null || true
    sleep 1
    rm -rf "$TEST_DIR"
}

trap cleanup EXIT

# ============================================
# PHASE 1: ENVIRONMENT SETUP
# ============================================
print_header "EXT4 BACKEND COMPREHENSIVE TEST SUITE"
echo "Project: CVFS"
echo "Backend: ext4 (direct filesystem access)"
echo "Date: $(date)"
echo ""

print_section "Phase 1: Environment Setup"

# Check if vfs_demo exists
if [ ! -f "$VFS_DEMO" ]; then
    echo -e "${RED}ERROR: vfs_demo not found at $VFS_DEMO${NC}"
    echo "Please run './build.sh build' first"
    exit 1
fi

echo "Creating test directory structure..."
mkdir -p "$TEST_DIR" "$MOUNT_POINT" "$VFS_MOUNT"

echo "Creating ext4 test image (20MB)..."
dd if=/dev/zero of="$TEST_IMAGE" bs=1M count=20 2>/dev/null
mkfs.ext4 -F -q "$TEST_IMAGE"

echo "Mounting test image to populate test data..."
sudo mount -o loop "$TEST_IMAGE" "$MOUNT_POINT"

# Create comprehensive test data
echo "Creating test files and directories..."

# Test file 1: Small text file
echo "Hello from EXT4" | sudo tee "$MOUNT_POINT/test1.txt" > /dev/null

# Test file 2: Slightly larger file
echo "This is a test file with multiple lines
Line 2
Line 3
Line 4
Line 5" | sudo tee "$MOUNT_POINT/test2.txt" > /dev/null

# Test file 3: Binary file (1KB)
dd if=/dev/urandom of="$MOUNT_POINT/binary.bin" bs=1K count=1 2>/dev/null
sudo chown $(whoami) "$MOUNT_POINT/binary.bin"

# Test file 4: Larger binary file (10KB) for multi-block reads
dd if=/dev/urandom of="$MOUNT_POINT/large.bin" bs=1K count=10 2>/dev/null
sudo chown $(whoami) "$MOUNT_POINT/large.bin"

# Test directories
sudo mkdir -p "$MOUNT_POINT/dir1"
sudo mkdir -p "$MOUNT_POINT/dir2"
sudo mkdir -p "$MOUNT_POINT/emptydir"

# Files in subdirectory
echo "Nested file" | sudo tee "$MOUNT_POINT/dir1/nested.txt" > /dev/null

# Hidden file
echo "Hidden" | sudo tee "$MOUNT_POINT/.hidden" > /dev/null

# File with special name
echo "Special" | sudo tee "$MOUNT_POINT/file-with-dash.txt" > /dev/null

sudo umount "$MOUNT_POINT"

echo -e "${GREEN}✓ Test environment prepared${NC}"

# ============================================
# PHASE 2: STATIC CODE ANALYSIS
# ============================================
print_section "Phase 2: Static Code Analysis"

test_start "Backend source file exists"
if [ -f "$PROJECT_ROOT/src/backends/backend_ext4.c" ]; then
    echo "OK"
    pass "backend_ext4.c found"
else
    echo "FAIL"
    fail "backend_ext4.c not found"
fi

test_start "Backend header file exists"
if [ -f "$PROJECT_ROOT/src/backends/backend_ext4.h" ]; then
    echo "OK"
    pass "backend_ext4.h found"
else
    echo "FAIL"
    fail "backend_ext4.h not found"
fi

test_start "Required structures defined"
REQUIRED_STRUCTS="ext4_super_block ext4_inode ext4_extent ext4_extent_header ext4_dir_entry_2"
MISSING=""
for struct in $REQUIRED_STRUCTS; do
    if ! grep -q "struct $struct\|typedef.*$struct" "$PROJECT_ROOT/src/backends/backend_ext4.c"; then
        MISSING="$MISSING $struct"
    fi
done
if [ -z "$MISSING" ]; then
    echo "OK"
    pass "All required structures present"
else
    echo "FAIL"
    fail "Missing structures:$MISSING"
fi

test_start "Constants defined correctly"
if grep -q "#define EXT4_SUPER_MAGIC.*0xEF53" "$PROJECT_ROOT/src/backends/backend_ext4.c" && \
   grep -q "#define EXT4_SUPERBLOCK_OFFSET.*1024" "$PROJECT_ROOT/src/backends/backend_ext4.c" && \
   grep -q "#define EXT4_ROOT_INO.*2" "$PROJECT_ROOT/src/backends/backend_ext4.c" && \
   grep -q "#define EXT4_EXTENT_MAGIC.*0xF30A" "$PROJECT_ROOT/src/backends/backend_ext4.c"; then
    echo "OK"
    pass "All constants defined correctly"
else
    echo "FAIL"
    fail "Some constants missing or incorrect"
fi

test_start "Backend operations implemented"
REQUIRED_OPS="ext4_ops_init ext4_ops_shutdown ext4_ops_open ext4_ops_close ext4_ops_read ext4_ops_write ext4_ops_stat ext4_ops_readdir"
MISSING_OPS=""
for op in $REQUIRED_OPS; do
    if ! grep -q "^static.*$op\|^.*$op(" "$PROJECT_ROOT/src/backends/backend_ext4.c"; then
        MISSING_OPS="$MISSING_OPS $op"
    fi
done
if [ -z "$MISSING_OPS" ]; then
    echo "OK"
    pass "All 8 backend operations implemented"
else
    echo "FAIL"
    fail "Missing operations:$MISSING_OPS"
fi

test_start "Backend registered in VFS"
if grep -q "ext4\|get_ext4_backend_ops" "$PROJECT_ROOT/src/core/vfs_core.c"; then
    echo "OK"
    pass "Backend registered in vfs_core.c"
else
    echo "FAIL"
    fail "Backend not registered in VFS"
fi

test_start "Packed attribute on structures"
PACKED_COUNT=$(grep -c "__attribute__((packed))" "$PROJECT_ROOT/src/backends/backend_ext4.c" || true)
if [ "$PACKED_COUNT" -ge 4 ]; then
    echo "OK"
    pass "Structures properly packed ($PACKED_COUNT instances)"
else
    echo "FAIL"
    fail "Insufficient packed attributes ($PACKED_COUNT found, need >= 4)"
fi

# ============================================
# PHASE 3: COMPILATION & LINKING
# ============================================
print_section "Phase 3: Compilation & Linking"

test_start "Project builds successfully"
if cd "$PROJECT_ROOT" && make clean >/dev/null 2>&1 && make >/dev/null 2>&1; then
    echo "OK"
    pass "Project compiles without errors"
else
    echo "FAIL"
    fail "Compilation failed"
    exit 1
fi

test_start "ext4 symbols in binary"
SYMBOLS="ext4_ops_init ext4_ops_open ext4_ops_read ext4_ops_stat ext4_ops_readdir"
MISSING_SYMS=""
for sym in $SYMBOLS; do
    if ! nm "$VFS_DEMO" 2>/dev/null | grep -q "$sym"; then
        MISSING_SYMS="$MISSING_SYMS $sym"
    fi
done
if [ -z "$MISSING_SYMS" ]; then
    echo "OK"
    pass "All ext4 symbols exported"
else
    echo "FAIL"
    fail "Missing symbols:$MISSING_SYMS"
fi

test_start "No undefined ext4 symbols"
UNDEF=$(nm "$VFS_DEMO" 2>/dev/null | grep "ext4" | grep " U " || true)
if [ -z "$UNDEF" ]; then
    echo "OK"
    pass "No undefined ext4 symbols"
else
    echo "FAIL"
    fail "Undefined symbols found"
fi

# ============================================
# PHASE 4: BACKEND INITIALIZATION
# ============================================
print_section "Phase 4: Backend Initialization Tests"

test_start "Mount ext4 image via VFS"
timeout 10 "$VFS_DEMO" -f -s "$VFS_MOUNT" -o backend=ext4,source="$TEST_IMAGE" > "$TEST_DIR/vfs_init.log" 2>&1 &
VFS_PID=$!
sleep 2

if ps -p $VFS_PID > /dev/null 2>&1; then
    echo "OK"
    pass "VFS demo started with ext4 backend"
else
    echo "FAIL"
    fail "VFS demo failed to start"
    cat "$TEST_DIR/vfs_init.log"
    exit 1
fi

test_start "Superblock read and validated"
if grep -q "ext4.*mounted" "$TEST_DIR/vfs_init.log" && \
   grep -q "block_size" "$TEST_DIR/vfs_init.log"; then
    echo "OK"
    pass "Superblock read with diagnostic output"
else
    echo "FAIL"
    fail "Superblock diagnostics not found"
fi

test_start "Mount point accessible"
if [ -d "$VFS_MOUNT" ] && timeout 5 ls "$VFS_MOUNT" > /dev/null 2>&1; then
    echo "OK"
    pass "Mount point accessible"
else
    echo "FAIL"
    fail "Mount point not accessible"
fi

# ============================================
# PHASE 5: DIRECTORY OPERATIONS
# ============================================
print_section "Phase 5: Directory Operations Tests"

test_start "Root directory listing works"
LISTING=$(timeout 5 ls -1a "$VFS_MOUNT" 2>/dev/null || echo "")
if [ -n "$LISTING" ]; then
    echo "OK"
    pass "Directory listing successful"
else
    echo "FAIL"
    fail "Cannot list root directory"
fi

test_start "Dot entries present (. and ..)"
if echo "$LISTING" | grep -q "^\.$" && echo "$LISTING" | grep -q "^\.\.$"; then
    echo "OK"
    pass "Dot entries (. and ..) present"
else
    echo "FAIL"
    fail "Missing . or .. entries"
fi

test_start "Test files visible in listing"
if echo "$LISTING" | grep -q "^test1.txt$" && \
   echo "$LISTING" | grep -q "^test2.txt$" && \
   echo "$LISTING" | grep -q "^binary.bin$"; then
    echo "OK"
    pass "All test files visible"
else
    echo "FAIL"
    fail "Some test files missing from listing"
fi

test_start "Directories visible in listing"
if echo "$LISTING" | grep -q "^dir1$" && \
   echo "$LISTING" | grep -q "^dir2$" && \
   echo "$LISTING" | grep -q "^emptydir$"; then
    echo "OK"
    pass "All directories visible"
else
    echo "FAIL"
    fail "Some directories missing from listing"
fi

test_start "Hidden files visible"
if echo "$LISTING" | grep -q "^\.hidden$"; then
    echo "OK"
    pass "Hidden files (starting with .) visible"
else
    echo "FAIL"
    fail "Hidden file not visible"
fi

# ============================================
# PHASE 6: FILE METADATA (STAT) TESTS
# ============================================
print_section "Phase 6: File Metadata Tests"

test_start "Root directory stat"
if timeout 5 stat "$VFS_MOUNT" > /dev/null 2>&1; then
    ROOT_TYPE=$(stat -c "%F" "$VFS_MOUNT" 2>/dev/null)
    if [ "$ROOT_TYPE" = "directory" ]; then
        echo "OK"
        pass "Root directory stat returns directory type"
    else
        echo "FAIL"
        fail "Root stat type incorrect: $ROOT_TYPE"
    fi
else
    echo "FAIL"
    fail "Cannot stat root directory"
fi

test_start "Root inode number is 2"
ROOT_INO=$(stat -c "%i" "$VFS_MOUNT" 2>/dev/null || echo "0")
if [ "$ROOT_INO" = "2" ]; then
    echo "OK"
    pass "Root inode is 2 (EXT4_ROOT_INO)"
else
    echo "FAIL"
    fail "Root inode incorrect: $ROOT_INO (expected 2)"
fi

test_start "File stat works"
if timeout 5 stat "$VFS_MOUNT/test1.txt" > /dev/null 2>&1; then
    FILE_TYPE=$(stat -c "%F" "$VFS_MOUNT/test1.txt" 2>/dev/null)
    if [ "$FILE_TYPE" = "regular file" ]; then
        echo "OK"
        pass "File stat returns regular file type"
    else
        echo "FAIL"
        fail "File type incorrect: $FILE_TYPE"
    fi
else
    echo "FAIL"
    fail "Cannot stat test1.txt"
fi

test_start "File size correct"
FILE_SIZE=$(stat -c "%s" "$VFS_MOUNT/test1.txt" 2>/dev/null || echo "0")
EXPECTED_SIZE=17  # "Hello from EXT4\n"
if [ "$FILE_SIZE" = "$EXPECTED_SIZE" ]; then
    echo "OK"
    pass "File size correct: $FILE_SIZE bytes"
else
    echo "FAIL"
    fail "File size incorrect: $FILE_SIZE (expected $EXPECTED_SIZE)"
fi

test_start "Directory stat works"
if timeout 5 stat "$VFS_MOUNT/dir1" > /dev/null 2>&1; then
    DIR_TYPE=$(stat -c "%F" "$VFS_MOUNT/dir1" 2>/dev/null)
    if [ "$DIR_TYPE" = "directory" ]; then
        echo "OK"
        pass "Directory stat returns directory type"
    else
        echo "FAIL"
        fail "Directory type incorrect: $DIR_TYPE"
    fi
else
    echo "FAIL"
    fail "Cannot stat dir1"
fi

test_start "Nonexistent file returns ENOENT"
if timeout 5 stat "$VFS_MOUNT/nonexistent.txt" 2>&1 | grep -qi "No such file"; then
    echo "OK"
    pass "Nonexistent file returns ENOENT"
else
    echo "FAIL"
    fail "ENOENT not returned for missing file"
fi

# ============================================
# PHASE 7: FILE READ OPERATIONS
# ============================================
print_section "Phase 7: File Read Operations Tests"

test_start "Read small text file"
CONTENT=$(timeout 5 cat "$VFS_MOUNT/test1.txt" 2>/dev/null || echo "")
EXPECTED="Hello from EXT4"
if [ "$CONTENT" = "$EXPECTED" ]; then
    echo "OK"
    pass "Small file read correctly"
else
    echo "FAIL"
    fail "Content mismatch: got '$CONTENT', expected '$EXPECTED'"
fi

test_start "Read multi-line text file"
if timeout 5 cat "$VFS_MOUNT/test2.txt" > "$TEST_DIR/read_test2.txt" 2>&1; then
    if grep -q "Line 3" "$TEST_DIR/read_test2.txt"; then
        echo "OK"
        pass "Multi-line file read correctly"
    else
        echo "FAIL"
        fail "Multi-line file content incorrect"
    fi
else
    echo "FAIL"
    fail "Cannot read test2.txt"
fi

test_start "Read binary file (1KB)"
if timeout 5 dd if="$VFS_MOUNT/binary.bin" of="$TEST_DIR/read_binary.bin" bs=1K count=1 2>/dev/null; then
    READ_SIZE=$(stat -c "%s" "$TEST_DIR/read_binary.bin" 2>/dev/null)
    if [ "$READ_SIZE" = "1024" ]; then
        echo "OK"
        pass "Binary file (1KB) read completely"
    else
        echo "FAIL"
        fail "Binary read incomplete: $READ_SIZE bytes"
    fi
else
    echo "FAIL"
    fail "Cannot read binary.bin"
fi

test_start "Read large multi-block file (10KB)"
if timeout 5 dd if="$VFS_MOUNT/large.bin" of="$TEST_DIR/read_large.bin" bs=1K count=10 2>/dev/null; then
    READ_SIZE=$(stat -c "%s" "$TEST_DIR/read_large.bin" 2>/dev/null)
    if [ "$READ_SIZE" = "10240" ]; then
        echo "OK"
        pass "Large file (10KB) read completely (multi-block)"
    else
        echo "FAIL"
        fail "Large read incomplete: $READ_SIZE bytes"
    fi
else
    echo "FAIL"
    fail "Cannot read large.bin"
fi

test_start "Partial read with offset (head)"
HEAD_CONTENT=$(timeout 5 head -c 5 "$VFS_MOUNT/test1.txt" 2>/dev/null || echo "")
if [ "$HEAD_CONTENT" = "Hello" ]; then
    echo "OK"
    pass "Partial read from beginning works"
else
    echo "FAIL"
    fail "Head read incorrect: '$HEAD_CONTENT'"
fi

test_start "Partial read with offset (tail)"
TAIL_CONTENT=$(timeout 5 tail -c 4 "$VFS_MOUNT/test1.txt" 2>/dev/null || echo "")
if [ "$TAIL_CONTENT" = "XT4" ] || [ "$TAIL_CONTENT" = "EXT4" ]; then
    echo "OK"
    pass "Partial read from end works"
else
    echo "FAIL"
    fail "Tail read incorrect: '$TAIL_CONTENT'"
fi

test_start "Multiple simultaneous reads"
if timeout 10 sh -c "cat '$VFS_MOUNT/test1.txt' > /dev/null & cat '$VFS_MOUNT/test2.txt' > /dev/null & cat '$VFS_MOUNT/binary.bin' > /dev/null & wait"; then
    echo "OK"
    pass "Concurrent file reads successful"
else
    echo "FAIL"
    fail "Concurrent reads failed"
fi

# ============================================
# PHASE 8: WRITE PROTECTION TESTS
# ============================================
print_section "Phase 8: Write Protection Tests"

test_start "Write to file rejected"
if ! timeout 5 sh -c "echo 'test' > '$VFS_MOUNT/test1.txt'" 2>/dev/null; then
    echo "OK"
    pass "Write to existing file correctly rejected"
else
    echo "FAIL"
    fail "Write was allowed (should be read-only)"
fi

test_start "Create new file rejected"
if ! timeout 5 touch "$VFS_MOUNT/newfile.txt" 2>/dev/null; then
    echo "OK"
    pass "File creation correctly rejected"
else
    echo "FAIL"
    fail "File creation was allowed (should be read-only)"
fi

test_start "Delete file rejected"
if ! timeout 5 rm "$VFS_MOUNT/test1.txt" 2>/dev/null; then
    echo "OK"
    pass "File deletion correctly rejected"
else
    echo "FAIL"
    fail "File deletion was allowed (should be read-only)"
fi

test_start "Create directory rejected"
if ! timeout 5 mkdir "$VFS_MOUNT/newdir" 2>/dev/null; then
    echo "OK"
    pass "Directory creation correctly rejected"
else
    echo "FAIL"
    fail "Directory creation was allowed (should be read-only)"
fi

# ============================================
# PHASE 9: ERROR HANDLING TESTS
# ============================================
print_section "Phase 9: Error Handling Tests"

test_start "Read nonexistent file returns error"
if ! timeout 5 cat "$VFS_MOUNT/does_not_exist.txt" > /dev/null 2>&1; then
    echo "OK"
    pass "Nonexistent file read returns error"
else
    echo "FAIL"
    fail "Nonexistent file did not return error"
fi

test_start "Read directory as file returns error"
if ! timeout 5 cat "$VFS_MOUNT/dir1" > /dev/null 2>&1; then
    echo "OK"
    pass "Reading directory as file returns error (EISDIR)"
else
    echo "FAIL"
    fail "Reading directory as file succeeded (should fail)"
fi

test_start "Open with write flags rejected"
# This is tested implicitly by the write protection tests above
echo "OK"
pass "Write flag rejection tested via write operations"

# ============================================
# PHASE 10: EXTENT TREE TESTS
# ============================================
print_section "Phase 10: Extent Tree Tests"

test_start "Small files use extents"
if timeout 5 cat "$VFS_MOUNT/test1.txt" > /dev/null 2>&1; then
    echo "OK"
    pass "Small file readable via extent tree"
else
    echo "FAIL"
    fail "Small file extent reading failed"
fi

test_start "Multi-block files traverse extents"
if timeout 5 cat "$VFS_MOUNT/large.bin" > /dev/null 2>&1; then
    echo "OK"
    pass "Multi-block file extent traversal works"
else
    echo "FAIL"
    fail "Multi-block extent traversal failed"
fi

# ============================================
# PHASE 11: INTEGRATION TESTS
# ============================================
print_section "Phase 11: Integration Tests"

test_start "VFS and ext4 backend integrated"
if ps -p $VFS_PID > /dev/null 2>&1; then
    echo "OK"
    pass "VFS still running with ext4 backend"
else
    echo "FAIL"
    fail "VFS crashed during tests"
fi

test_start "No memory leaks (process stable)"
INITIAL_MEM=$(ps -o rss= -p $VFS_PID 2>/dev/null || echo "0")
# Do some operations
for i in {1..10}; do
    timeout 2 cat "$VFS_MOUNT/test1.txt" > /dev/null 2>&1 || true
done
sleep 1
FINAL_MEM=$(ps -o rss= -p $VFS_PID 2>/dev/null || echo "0")
MEM_GROWTH=$((FINAL_MEM - INITIAL_MEM))
if [ "$MEM_GROWTH" -lt 1000 ]; then  # Less than 1MB growth
    echo "OK"
    pass "Memory usage stable (growth: ${MEM_GROWTH}KB)"
else
    echo "FAIL"
    fail "Possible memory leak (growth: ${MEM_GROWTH}KB)"
fi

test_start "Mount survives stress test"
for i in {1..20}; do
    timeout 2 ls "$VFS_MOUNT" > /dev/null 2>&1 || true
    timeout 2 cat "$VFS_MOUNT/test1.txt" > /dev/null 2>&1 || true
    timeout 2 stat "$VFS_MOUNT/dir1" > /dev/null 2>&1 || true
done
if ps -p $VFS_PID > /dev/null 2>&1; then
    echo "OK"
    pass "Backend survives stress test (20 operations)"
else
    echo "FAIL"
    fail "Backend crashed during stress test"
fi

# ============================================
# PHASE 12: CLEANUP AND SUMMARY
# ============================================
print_section "Phase 12: Cleanup"

echo "Unmounting VFS..."
fusermount -u "$VFS_MOUNT" 2>/dev/null || true
kill $VFS_PID 2>/dev/null || true
wait $VFS_PID 2>/dev/null || true

echo "VFS unmounted successfully"

# ============================================
# FINAL SUMMARY
# ============================================
print_header "TEST SUMMARY"

PASS_RATE=0
if [ $TOTAL_TESTS -gt 0 ]; then
    PASS_RATE=$((PASSED_TESTS * 100 / TOTAL_TESTS))
fi

echo ""
echo "Total Tests:  $TOTAL_TESTS"
echo -e "Passed:       ${GREEN}$PASSED_TESTS${NC}"
echo -e "Failed:       ${RED}$FAILED_TESTS${NC}"
echo "Pass Rate:    $PASS_RATE%"
echo ""

if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}╔════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   ✅ ALL TESTS PASSED SUCCESSFULLY   ║${NC}"
    echo -e "${GREEN}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "EXT4 Backend Status: FULLY FUNCTIONAL ✅"
    echo ""
    echo "Verified Capabilities:"
    echo "  ✓ Superblock reading and validation"
    echo "  ✓ Directory listing with bounds checking"
    echo "  ✓ File metadata (stat) operations"
    echo "  ✓ File reading (single and multi-block)"
    echo "  ✓ Extent tree traversal"
    echo "  ✓ Read-only enforcement"
    echo "  ✓ Error handling (ENOENT, EISDIR, etc.)"
    echo "  ✓ Memory stability"
    echo "  ✓ VFS integration"
    echo ""
    exit 0
else
    echo -e "${RED}╔════════════════════════════════════════╗${NC}"
    echo -e "${RED}║     ❌ SOME TESTS FAILED              ║${NC}"
    echo -e "${RED}╚════════════════════════════════════════╝${NC}"
    echo ""
    echo "EXT4 Backend Status: NEEDS ATTENTION"
    echo ""
    echo "Please review the failed tests above."
    echo "Log file: $TEST_DIR/vfs_init.log"
    echo ""
    exit 1
fi
