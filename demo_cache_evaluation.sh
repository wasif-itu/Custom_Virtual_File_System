#!/bin/bash

# Comprehensive Cache + Working Set Model Demonstration
# For project evaluation: Shows LRU cache with WSM eviction policy

echo "=========================================="
echo "Cache + Working Set Model Demonstration"
echo "=========================================="
echo ""

# Step 1: Compile test program
cat > /tmp/demo_cache.c << 'EOF'
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

extern int vfs_init(void);
extern int vfs_shutdown(void);
extern long vfs_read_path(const char*, char*, unsigned long, long);

int main() {
    vfs_init();
    
    char buf[4096];
    printf("\n=== DEMONSTRATION STEPS ===\n\n");
    
    // Step 1: Cold cache - MISS
    printf("Step 1: Reading page 0 (offset 0) - Cache MISS expected\n");
    long r1 = vfs_read_path("/dir1/dir3/file2", buf, 4096, 0);
    printf("  Result: Read %ld bytes\n\n", r1);
    
    // Step 2: Re-read same page - HIT
    printf("Step 2: Re-reading page 0 (offset 0) - Cache HIT expected\n");
    long r2 = vfs_read_path("/dir1/dir3/file2", buf, 4096, 0);
    printf("  Result: Read %ld bytes\n\n", r2);
    
    // Step 3: Read page 1 - MISS
    printf("Step 3: Reading page 1 (offset 4096) - Cache MISS expected\n");
    long r3 = vfs_read_path("/dir1/dir3/file2", buf, 4096, 4096);
    printf("  Result: Read %ld bytes\n\n", r3);
    
    // Step 4: Re-read page 1 - HIT
    printf("Step 4: Re-reading page 1 (offset 4096) - Cache HIT expected\n");
    long r4 = vfs_read_path("/dir1/dir3/file2", buf, 4096, 4096);
    printf("  Result: Read %ld bytes\n\n", r4);
    
    // Step 5: Read page 2 - MISS
    printf("Step 5: Reading page 2 (offset 8192) - Cache MISS expected\n");
    long r5 = vfs_read_path("/dir1/dir3/file2", buf, 4096, 8192);
    printf("  Result: Read %ld bytes\n\n", r5);
    
    // Step 6: Re-read page 0 - HIT (still in cache)
    printf("Step 6: Re-reading page 0 - Cache HIT expected (in working set)\n");
    long r6 = vfs_read_path("/dir1/dir3/file2", buf, 4096, 0);
    printf("  Result: Read %ld bytes\n\n", r6);
    
    // Step 7: Many reads to advance time beyond tau (10000)
    printf("Step 7: Performing 12000 small reads to advance time beyond tau...\n");
    for (int i = 0; i < 12000; i++) {
        vfs_read_path("/dir1/dir3/file2", buf, 100, 100000 + i);
    }
    printf("  Completed 12000 reads\n\n");
    
    // Step 8: Try to re-read old pages - should be evicted
    printf("Step 8: Re-reading page 0 after time > tau - Should be evicted (MISS)\n");
    long r7 = vfs_read_path("/dir1/dir3/file2", buf, 4096, 0);
    printf("  Result: Read %ld bytes\n\n", r7);
    
    printf("\n=== FINAL CACHE STATISTICS ===\n");
    vfs_shutdown();
    
    return 0;
}
EOF

echo "Compiling demonstration program..."
gcc -o /tmp/demo_cache /tmp/demo_cache.c \
    src/core/vfs_core.o src/backends/*.o src/cache/*.o src/utils/*.o \
    -I./src -I./src/core -pthread

if [ $? -ne 0 ]; then
    echo "❌ Compilation failed"
    exit 1
fi

echo "✅ Compilation successful"
echo ""

# Step 2: Run with demo flags enabled
echo "Running demonstration with VFS_ENABLE_DEMO=1 VFS_CACHE_VERBOSE=1"
echo "--------------------------------------------------------------"
VFS_ENABLE_DEMO=1 VFS_CACHE_VERBOSE=1 /tmp/demo_cache

echo ""
echo "=========================================="
echo "Demonstration Complete"
echo "=========================================="
echo ""
echo "Key observations:"
echo "  1. Cache HIT/MISS logs show cache working correctly"
echo "  2. First access to each page: MISS"
echo "  3. Subsequent accesses to same page: HIT"
echo "  4. Working Set Model: Pages accessed outside time window (tau) are evicted"
echo "  5. Statistics show non-zero hits/misses"
echo ""
