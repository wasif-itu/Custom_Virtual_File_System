#!/bin/bash
# Simple cache demonstration using direct VFS API calls
# Shows cache hits/misses without FUSE indirection

cat > /tmp/test_cache_direct.c << 'EOF'
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* External VFS API */
extern int vfs_init(void);
extern int vfs_shutdown(void);
extern long vfs_read_path(const char *path, char *buf, unsigned long count, long offset);
extern void cache_print_stats(void);

int main() {
    char buf[4096];
    
    /* Set demo mode */
    setenv("VFS_ENABLE_DEMO", "1", 1);
    setenv("VFS_CACHE_VERBOSE", "1", 1);
    
    printf("\n=== Direct VFS Cache Test ===\n\n");
    
    if (vfs_init() != 0) {
        fprintf(stderr, "vfs_init failed\n");
        return 1;
    }
    
    const char *path = "/dir1/dir3/file2";
    
    printf("Step 1: First read (cache MISS expected)\n");
    long r1 = vfs_read_path(path, buf, 4096, 0);
    printf("Read %ld bytes\n\n", r1);
    
    printf("Step 2: Second read same offset (cache HIT expected)\n");
    long r2 = vfs_read_path(path, buf, 4096, 0);
    printf("Read %ld bytes\n\n", r2);
    
    printf("Step 3: Read different offset (cache MISS expected)\n");
    long r3 = vfs_read_path(path, buf, 4096, 8192);
    printf("Read %ld bytes\n\n", r3);
    
    printf("Step 4: Re-read second offset (cache HIT expected)\n");
    long r4 = vfs_read_path(path, buf, 4096, 8192);
    printf("Read %ld bytes\n\n", r4);
    
    printf("\n=== Cache Statistics ===\n");
    cache_print_stats();
    
    vfs_shutdown();
    return 0;
}
EOF

echo "Compiling direct cache test..."
gcc -I./src -I./src/core -I./src/cache -I./src/utils -o test_cache_direct /tmp/test_cache_direct.c \
    src/core/vfs_core.o src/cache/cache.o src/cache/working_set.o src/utils/time.o \
    src/backends/backend_posix.o src/backends/backend_ext4.o src/backends/backend_fat.o \
    -pthread || exit 1

echo "Running direct cache test..."
echo ""
VFS_ENABLE_DEMO=1 VFS_CACHE_VERBOSE=1 ./test_cache_direct

echo ""
echo "✅ Direct VFS cache test complete"
