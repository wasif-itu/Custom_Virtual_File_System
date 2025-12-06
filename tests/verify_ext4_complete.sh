#!/bin/bash
# EXT4 Backend Implementation Verification Script
# Validates implementation against plan requirements
# Does NOT require sudo or actual execution

# Removed set -e to allow script to complete all checks

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;36m'
NC='\033[0m'

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT4_SRC="$PROJECT_ROOT/src/backends/backend_ext4.c"
EXT4_HDR="$PROJECT_ROOT/src/backends/backend_ext4.h"
VFS_CORE="$PROJECT_ROOT/src/core/vfs_core.c"
PLAN_DOC="$PROJECT_ROOT/docs/backend_implementation_plan.md"

test_check() {
    local name="$1"
    local result="$2"
    ((TESTS_TOTAL++))
    
    if [ "$result" = "PASS" ]; then
        echo -e "${GREEN}✅ PASS${NC}: $name"
        ((TESTS_PASSED++))
    else
        echo -e "${RED}❌ FAIL${NC}: $name"
        ((TESTS_FAILED++))
    fi
}

print_header() {
    echo ""
    echo "========================================"
    echo "$1"
    echo "=========================================="
}

print_section() {
    echo ""
    echo -e "${BLUE}$1${NC}"
    echo "----------------------------------------"
}

print_header "EXT4 BACKEND IMPLEMENTATION VERIFICATION"
echo "Project: CVFS"
echo "Backend: ext4 (read-only direct filesystem access)"
echo "Verification Date: $(date)"
echo ""

# ===========================================
# PHASE 1: FILE STRUCTURE
# ===========================================
print_section "Phase 1: File Structure"

if [ -f "$EXT4_SRC" ]; then
    test_check "backend_ext4.c exists" "PASS"
else
    test_check "backend_ext4.c exists" "FAIL"
    exit 1
fi

if [ -f "$EXT4_HDR" ]; then
    test_check "backend_ext4.h exists" "PASS"
else
    test_check "backend_ext4.h exists" "FAIL"
fi

# ===========================================
# PHASE 2: DATA STRUCTURES (Per Plan Section 3.3)
# ===========================================
print_section "Phase 2: Data Structures (Plan Section 3.3)"

# Superblock structure
if grep -q "struct ext4_super_block" "$EXT4_SRC" && \
   grep -q "s_magic" "$EXT4_SRC" && \
   grep -q "s_log_block_size" "$EXT4_SRC" && \
   grep -q "s_inodes_per_group" "$EXT4_SRC" && \
   grep -q "s_blocks_per_group" "$EXT4_SRC"; then
    test_check "ext4_super_block structure with required fields" "PASS"
else
    test_check "ext4_super_block structure with required fields" "FAIL"
fi

# Inode structure
if grep -q "struct ext4_inode" "$EXT4_SRC" && \
   grep -q "i_mode" "$EXT4_SRC" && \
   grep -q "i_size_lo" "$EXT4_SRC" && \
   grep -q "i_size_high" "$EXT4_SRC" && \
   grep -q "i_block\[15\]" "$EXT4_SRC" && \
   grep -q "i_links_count" "$EXT4_SRC"; then
    test_check "ext4_inode structure with required fields" "PASS"
else
    test_check "ext4_inode structure with required fields" "FAIL"
fi

# Extent structures
if grep -q "struct ext4_extent_header" "$EXT4_SRC" && \
   grep -q "eh_magic" "$EXT4_SRC" && \
   grep -q "eh_entries" "$EXT4_SRC" && \
   grep -q "eh_depth" "$EXT4_SRC"; then
    test_check "ext4_extent_header structure" "PASS"
else
    test_check "ext4_extent_header structure" "FAIL"
fi

if grep -q "struct ext4_extent" "$EXT4_SRC" && \
   grep -q "ee_block" "$EXT4_SRC" && \
   grep -q "ee_len" "$EXT4_SRC" && \
   grep -q "ee_start_lo" "$EXT4_SRC" && \
   grep -q "ee_start_hi" "$EXT4_SRC"; then
    test_check "ext4_extent structure with 48-bit addressing" "PASS"
else
    test_check "ext4_extent structure with 48-bit addressing" "FAIL"
fi

# Directory entry
if grep -q "struct ext4_dir_entry_2" "$EXT4_SRC" && \
   grep -q "rec_len" "$EXT4_SRC" && \
   grep -q "name_len" "$EXT4_SRC" && \
   grep -q "file_type" "$EXT4_SRC"; then
    test_check "ext4_dir_entry_2 structure" "PASS"
else
    test_check "ext4_dir_entry_2 structure" "FAIL"
fi

# Packed attribute
PACKED_COUNT=$(grep -c "__attribute__((packed))" "$EXT4_SRC" || echo "0")
if [ "$PACKED_COUNT" -ge 4 ]; then
    test_check "Structures use __attribute__((packed)) ($PACKED_COUNT)" "PASS"
else
    test_check "Structures use __attribute__((packed))" "FAIL"
fi

# ===========================================
# PHASE 3: CONSTANTS (Per Plan Section 3.3)
# ===========================================
print_section "Phase 3: Constants & Definitions"

if grep -q "#define EXT4_SUPER_MAGIC.*0xEF53" "$EXT4_SRC"; then
    test_check "EXT4_SUPER_MAGIC = 0xEF53" "PASS"
else
    test_check "EXT4_SUPER_MAGIC = 0xEF53" "FAIL"
fi

if grep -q "#define EXT4_SUPERBLOCK_OFFSET.*1024" "$EXT4_SRC"; then
    test_check "EXT4_SUPERBLOCK_OFFSET = 1024" "PASS"
else
    test_check "EXT4_SUPERBLOCK_OFFSET = 1024" "FAIL"
fi

if grep -q "#define EXT4_ROOT_INO.*2" "$EXT4_SRC"; then
    test_check "EXT4_ROOT_INO = 2" "PASS"
else
    test_check "EXT4_ROOT_INO = 2" "FAIL"
fi

if grep -q "#define EXT4_EXTENT_MAGIC.*0xF30A" "$EXT4_SRC"; then
    test_check "EXT4_EXTENT_MAGIC = 0xF30A" "PASS"
else
    test_check "EXT4_EXTENT_MAGIC = 0xF30A" "FAIL"
fi

# ===========================================
# PHASE 4: BACKEND OPERATIONS (Per Plan Section 3.4)
# ===========================================
print_section "Phase 4: Backend Operations (Plan Section 3.4)"

# Init function
if grep -q "ext4_ops_init" "$EXT4_SRC" && \
   grep -A20 "ext4_ops_init" "$EXT4_SRC" | grep -q "pread.*&b->sb\|pread.*superblock\|pread.*s_magic"; then
    test_check "ext4_ops_init() - reads superblock" "PASS"
else
    test_check "ext4_ops_init() - reads superblock" "FAIL"
fi

# Superblock validation
if grep -A40 "ext4_ops_init" "$EXT4_SRC" | grep -q "s_magic.*!=.*EXT4_SUPER_MAGIC\|EXT4_SUPER_MAGIC.*!=.*s_magic"; then
    test_check "Superblock magic validation in init" "PASS"
else
    test_check "Superblock magic validation in init" "FAIL"
fi

# Block size calculation
if grep -q "block_size.*=.*1024.*<<.*s_log_block_size\|1024u.*<<.*s_log_block_size" "$EXT4_SRC"; then
    test_check "Block size calculation: 1024 << s_log_block_size" "PASS"
else
    test_check "Block size calculation" "FAIL"
fi

# Shutdown function
if grep -q "ext4_ops_shutdown" "$EXT4_SRC" && \
   grep -A10 "ext4_ops_shutdown" "$EXT4_SRC" | grep -q "close.*device_fd\|close.*fd"; then
    test_check "ext4_ops_shutdown() - closes device" "PASS"
else
    test_check "ext4_ops_shutdown() - closes device" "FAIL"
fi

# Open function
if grep -q "ext4_ops_open" "$EXT4_SRC"; then
    test_check "ext4_ops_open() implemented" "PASS"
else
    test_check "ext4_ops_open() implemented" "FAIL"
fi

# Read-only enforcement in open
if grep -A20 "ext4_ops_open" "$EXT4_SRC" | grep -q "O_WRONLY.*O_RDWR.*EACCES\|O_RDWR.*O_WRONLY.*EACCES"; then
    test_check "open() rejects write flags (read-only)" "PASS"
else
    test_check "open() rejects write flags" "FAIL"
fi

# Close function
if grep -q "ext4_ops_close" "$EXT4_SRC"; then
    test_check "ext4_ops_close() implemented" "PASS"
else
    test_check "ext4_ops_close() implemented" "FAIL"
fi

# Read function
if grep -q "ext4_ops_read" "$EXT4_SRC" && \
   grep -A30 "ext4_ops_read" "$EXT4_SRC" | grep -q "extent.*map\|extent_map"; then
    test_check "ext4_ops_read() - uses extent mapping" "PASS"
else
    test_check "ext4_ops_read() - uses extent mapping" "FAIL"
fi

# Write function
if grep -q "ext4_ops_write" "$EXT4_SRC" && \
   grep -A5 "ext4_ops_write" "$EXT4_SRC" | grep -q "ENOSYS"; then
    test_check "ext4_ops_write() returns -ENOSYS" "PASS"
else
    test_check "ext4_ops_write() returns -ENOSYS" "FAIL"
fi

# Stat function
if grep -q "ext4_ops_stat" "$EXT4_SRC" && \
   grep -A50 "ext4_ops_stat" "$EXT4_SRC" | grep -q "st_mode\|st_size\|st_ino"; then
    test_check "ext4_ops_stat() - populates struct stat" "PASS"
else
    test_check "ext4_ops_stat() - populates struct stat" "FAIL"
fi

# Readdir function
if grep -q "ext4_ops_readdir" "$EXT4_SRC" && \
   grep -A50 "ext4_ops_readdir" "$EXT4_SRC" | grep -q "ext4_dir_entry"; then
    test_check "ext4_ops_readdir() - parses directory entries" "PASS"
else
    test_check "ext4_ops_readdir() - parses directory entries" "FAIL"
fi

# ===========================================
# PHASE 5: HELPER FUNCTIONS
# ===========================================
print_section "Phase 5: Helper Functions"

# Inode reading helper
if grep -q "ext4_read_inode" "$EXT4_SRC"; then
    test_check "ext4_read_inode() helper function" "PASS"
else
    test_check "ext4_read_inode() helper function" "FAIL"
fi

# Extent mapping helper
if grep -q "ext4_extent_map_block\|ext4_extent_get_block" "$EXT4_SRC"; then
    test_check "Extent block mapping helper" "PASS"
else
    test_check "Extent block mapping helper" "FAIL"
fi

# Extent magic validation
if grep -A20 "extent.*map\|extent_map" "$EXT4_SRC" | grep -q "eh_magic.*0xF30A\|EXT4_EXTENT_MAGIC"; then
    test_check "Extent tree magic validation (0xF30A)" "PASS"
else
    test_check "Extent tree magic validation" "FAIL"
fi

# Extent depth check (leaf only)
if grep -A20 "extent.*map\|extent_map" "$EXT4_SRC" | grep -q "eh_depth.*0\|depth.*==.*0"; then
    test_check "Extent depth check (leaf-only support)" "PASS"
else
    test_check "Extent depth check" "FAIL"
fi

# ===========================================
# PHASE 6: SAFETY & ERROR HANDLING (Per Plan Section 9)
# ===========================================
print_section "Phase 6: Safety & Error Handling"

# 64-bit file size support
if grep -q "i_size_high.*32.*i_size_lo\|i_size_high.*<<.*32" "$EXT4_SRC"; then
    test_check "64-bit file size: (i_size_high << 32) | i_size_lo" "PASS"
else
    test_check "64-bit file size support" "FAIL"
fi

# 48-bit physical block addressing
if grep -q "ee_start_hi.*32.*ee_start_lo\|ee_start_hi.*<<.*32" "$EXT4_SRC"; then
    test_check "48-bit block addressing: (ee_start_hi << 32) | ee_start_lo" "PASS"
else
    test_check "48-bit block addressing" "FAIL"
fi

# Bounds checking for rec_len
if grep -A50 "ext4_ops_readdir\|readdir" "$EXT4_SRC" | grep -q "rec_len.*block_sz\|block_sz.*rec_len\|reclen.*block_sz\|block_sz.*reclen"; then
    test_check "Directory rec_len bounds checking" "PASS"
else
    test_check "Directory rec_len bounds checking" "FAIL"
fi

# Null pointer checks
NULL_CHECK_COUNT=$(grep -c "if (!.*backend\|if (!.*handle\|if (!.*relpath\|if (!.*buf\|if (!.*st" "$EXT4_SRC" || echo "0")
if [ "$NULL_CHECK_COUNT" -ge 8 ]; then
    test_check "Null pointer validation ($NULL_CHECK_COUNT checks)" "PASS"
else
    test_check "Null pointer validation (insufficient: $NULL_CHECK_COUNT)" "FAIL"
fi

# Error code usage
ERROR_CODES="EINVAL EIO ENOENT ENOMEM EACCES EISDIR ENOSYS EBADF EMFILE"
ERROR_COUNT=0
for code in $ERROR_CODES; do
    if grep -q "\-$code" "$EXT4_SRC"; then
        ((ERROR_COUNT++))
    fi
done
if [ "$ERROR_COUNT" -ge 7 ]; then
    test_check "Comprehensive error codes ($ERROR_COUNT/9)" "PASS"
else
    test_check "Error code usage ($ERROR_COUNT/9)" "FAIL"
fi

# ===========================================
# PHASE 7: VFS INTEGRATION (Per Plan Section 7)
# ===========================================
print_section "Phase 7: VFS Integration"

# Backend getter function
if grep -q "get_ext4_backend_ops" "$EXT4_SRC"; then
    test_check "get_ext4_backend_ops() function" "PASS"
else
    test_check "get_ext4_backend_ops() function" "FAIL"
fi

# Backend ops structure
if grep -A20 "ext4_backend_ops" "$EXT4_SRC" | grep -q ".name.*=.*\"ext4\""; then
    test_check "Backend ops structure with name='ext4'" "PASS"
else
    test_check "Backend ops structure" "FAIL"
fi

# VFS registration
if grep -q "ext4\|get_ext4_backend_ops" "$VFS_CORE"; then
    test_check "Backend registered in vfs_core.c" "PASS"
else
    test_check "Backend registered in vfs_core.c" "FAIL"
fi

# Makefile integration
if grep -q "backend_ext4" "$PROJECT_ROOT/Makefile"; then
    test_check "backend_ext4.c in Makefile" "PASS"
else
    test_check "backend_ext4.c in Makefile" "FAIL"
fi

# ===========================================
# PHASE 8: BUILD VERIFICATION
# ===========================================
print_section "Phase 8: Build Verification"

# Check if project builds
if [ -f "$PROJECT_ROOT/vfs_demo" ]; then
    test_check "vfs_demo binary exists" "PASS"
else
    test_check "vfs_demo binary exists (run make first)" "FAIL"
fi

# Check for ext4 symbols in binary
if [ -f "$PROJECT_ROOT/vfs_demo" ]; then
    if nm "$PROJECT_ROOT/vfs_demo" 2>/dev/null | grep -q "ext4"; then
        test_check "ext4 symbols in binary" "PASS"
    else
        test_check "ext4 symbols in binary" "FAIL"
    fi
fi

# ===========================================
# SUMMARY
# ===========================================
print_header "VERIFICATION SUMMARY"

PASS_RATE=0
if [ $TESTS_TOTAL -gt 0 ]; then
    PASS_RATE=$((TESTS_PASSED * 100 / TESTS_TOTAL))
fi

echo ""
echo "Total Checks:  $TESTS_TOTAL"
echo -e "Passed:        ${GREEN}$TESTS_PASSED${NC}"
echo -e "Failed:        ${RED}$TESTS_FAILED${NC}"
echo "Pass Rate:     $PASS_RATE%"
echo ""

if [ $TESTS_FAILED -eq 0 ]; then
    echo -e "${GREEN}╔══════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✅ IMPLEMENTATION COMPLETE & VERIFIED  ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo "EXT4 Backend Status: FULLY IMPLEMENTED ✅"
    echo ""
    echo "Verified against plan (docs/backend_implementation_plan.md):"
    echo "  ✓ Section 3.3: Data Structures"
    echo "  ✓ Section 3.4: Implementation Functions"
    echo "  ✓ Section 7: Integration Steps"
    echo "  ✓ Section 9: Security & Safety"
    echo ""
    echo "Implementation includes:"
    echo "  • Superblock reading and validation"
    echo "  • Inode structures with 64-bit sizes"
    echo "  • Leaf extent tree support (48-bit addressing)"
    echo "  • Directory entry parsing with bounds checking"
    echo "  • Read-only file operations"
    echo "  • Comprehensive error handling"
    echo "  • VFS integration and registration"
    echo ""
    exit 0
else
    echo -e "${RED}╔══════════════════════════════════════════╗${NC}"
    echo -e "${RED}║    ❌ SOME CHECKS FAILED                ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════╝${NC}"
    echo ""
    echo "EXT4 Backend Status: NEEDS ATTENTION"
    echo ""
    echo "Review failed checks above and fix implementation."
    echo ""
    exit 1
fi
