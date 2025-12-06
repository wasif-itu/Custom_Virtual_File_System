#!/bin/bash
# Don't exit early; run all checks
RED='\033[0;31m'; GREEN='\033[0;32m'; BLUE='\033[0;36m'; NC='\033[0m'
TESTS_PASSED=0; TESTS_FAILED=0; TESTS_TOTAL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/src/backends/backend_fat.c"; HDR="$ROOT/src/backends/backend_fat.h"; CORE="$ROOT/src/core/vfs_core.c"; MK="$ROOT/Makefile"

print() { echo -e "$1"; }
check(){ local n="$1"; shift; ((TESTS_TOTAL++)); if eval "$*"; then print "${GREEN}✅ PASS${NC}: $n"; ((TESTS_PASSED++)); else print "${RED}❌ FAIL${NC}: $n"; ((TESTS_FAILED++)); fi }

print "\n========================================\nFAT32 BACKEND IMPLEMENTATION VERIFICATION\n=========================================="

print "\n${BLUE}Phase 1: Files${NC}\n----------------------------------------"
check "backend_fat.c exists" "[ -f '$SRC' ]"
check "backend_fat.h exists" "[ -f '$HDR' ]"

print "\n${BLUE}Phase 2: Structures${NC}\n----------------------------------------"
check "boot sector struct" "grep -q 'struct fat32_boot_sector' '$HDR'"
check "dir entry struct" "grep -q 'struct fat32_dir_entry' '$HDR'"
PACKED_COUNT=$(grep -c "__attribute__((packed))" "$HDR" 2>/dev/null || echo 0)
TESTS_TOTAL=$((TESTS_TOTAL+1))
if [ "$PACKED_COUNT" -ge 2 ]; then
	print "${GREEN}✅ PASS${NC}: packed attributes ($PACKED_COUNT)"
	TESTS_PASSED=$((TESTS_PASSED+1))
else
	print "${RED}❌ FAIL${NC}: packed attributes"
	TESTS_FAILED=$((TESTS_FAILED+1))
fi

print "\n${BLUE}Phase 3: Init${NC}\n----------------------------------------"
check "init reads boot" "grep -A10 'fat32_ops_init' '$SRC' | grep -q 'pread.*&fat->boot'"
check "validates FAT32 signature" "grep -A20 'fat32_ops_init' '$SRC' | grep -q 'BS_FilSysType'"
check "computes geometry" "grep -q 'bytes_per_cluster' '$SRC'"
check "loads FAT cache" "grep -q 'fat_cache' '$SRC'"

print "\n${BLUE}Phase 4: Ops${NC}\n----------------------------------------"
check "open implemented" "grep -q 'fat32_ops_open' '$SRC'"
check "read implemented" "grep -q 'fat32_ops_read' '$SRC'"
check "stat implemented" "grep -q 'fat32_ops_stat' '$SRC'"
check "readdir implemented" "grep -q 'fat32_ops_readdir' '$SRC'"
check "write returns ENOSYS" "grep -A5 'fat32_ops_write' '$SRC' | grep -q 'ENOSYS'"

print "\n${BLUE}Phase 5: Helpers${NC}\n----------------------------------------"
check "next cluster helper" "grep -q 'fat32_get_next_cluster' '$SRC'"
check "read cluster helper" "grep -q 'fat32_read_cluster' '$SRC'"
check "path lookup" "grep -q 'fat32_path_lookup' '$SRC'"

print "\n${BLUE}Phase 6: Integration${NC}\n----------------------------------------"
check "backend registered" "grep -q 'get_fat32_backend_ops' '$CORE'"
check "Makefile includes backend_fat.c" "grep -q 'backend_fat.c' '$MK'"

print "\n${BLUE}Phase 7: Build${NC}\n----------------------------------------"
if [ -f "$ROOT/vfs_demo" ]; then check "vfs_demo exists" "true"; else check "vfs_demo exists (run make)" "false"; fi

print "\n========================================\nSUMMARY\n=========================================="
PR=$((TESTS_PASSED * 100 / (TESTS_TOTAL==0?1:TESTS_TOTAL)))
print "Total Checks:  $TESTS_TOTAL"
print "Passed:        ${GREEN}$TESTS_PASSED${NC}"
print "Failed:        ${RED}$TESTS_FAILED${NC}"
print "Pass Rate:     $PR%\n"
[ $TESTS_FAILED -eq 0 ]
