
/* ================================================================
 * FILE: cache/cache.h
 * ================================================================ */
#ifndef CACHE_H
#define CACHE_H

#include <stdint.h>
#include <stddef.h>
#include <sys/types.h>
#include <pthread.h>
#include "cache_entry.h"

typedef struct Cache {
    CacheEntry **table;
    size_t capacity;        // Maximum number of entries
    size_t current_size;    // Current number of entries
    size_t table_size;      // Hash table size (buckets)
    uint64_t tau;           // Working-set window size (W)
    pthread_mutex_t lock;   // Thread safety
    // Stats
    size_t hits;
    size_t misses;
} Cache;

// Core cache operations
void cache_init(size_t capacity, uint64_t tau);
void cache_shutdown(void);

uint8_t *cache_lookup(uint64_t block_id, size_t *size);
void cache_insert(uint64_t block_id, uint8_t *data, size_t size);

void cache_update_access(CacheEntry *entry);
void cache_evict_if_needed(void);

// VFS-aware helpers
uint64_t cache_compute_block_id(uint64_t mount_id, uint64_t ino, off_t offset);
void cache_invalidate_mount(uint64_t mount_id);

// Statistics (optional)
void cache_print_stats(void);
void cache_get_stats(size_t *hits, size_t *misses);

#endif // CACHE_H
