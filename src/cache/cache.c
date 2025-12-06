
/* ================================================================
 * FILE: cache/cache.c
 * ================================================================ */
#include "cache.h"
#include "working_set.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

static Cache *g_cache = NULL;

// Hash function for block IDs
static size_t hash_block_id(uint64_t block_id, size_t table_size) {
    return (size_t)(block_id % table_size);
}

void cache_init(size_t capacity, uint64_t tau) {
    if (g_cache != NULL) {
        fprintf(stderr, "Cache already initialized\n");
        return;
    }

    g_cache = (Cache *)malloc(sizeof(Cache));
    if (g_cache == NULL) {
        fprintf(stderr, "Failed to allocate cache structure\n");
        return;
    }

    g_cache->capacity = capacity;
    g_cache->current_size = 0;
    g_cache->tau = tau;
    g_cache->table_size = capacity * 2;  // Use 2x capacity for hash table
    pthread_mutex_init(&g_cache->lock, NULL);
    g_cache->hits = 0;
    g_cache->misses = 0;

    g_cache->table = (CacheEntry **)calloc(g_cache->table_size, sizeof(CacheEntry *));
    if (g_cache->table == NULL) {
        fprintf(stderr, "Failed to allocate cache hash table\n");
        free(g_cache);
        g_cache = NULL;
        return;
    }

    printf("Cache initialized: capacity=%zu, tau=%lu, table_size=%zu\n", 
           capacity, tau, g_cache->table_size);
}

void cache_shutdown(void) {
    if (g_cache == NULL) {
        return;
    }

    // Free all cache entries
    for (size_t i = 0; i < g_cache->table_size; i++) {
        CacheEntry *entry = g_cache->table[i];
        while (entry != NULL) {
            CacheEntry *next = entry->next;
            free(entry->data);
            free(entry);
            entry = next;
        }
    }

    free(g_cache->table);
    pthread_mutex_destroy(&g_cache->lock);
    free(g_cache);
    g_cache = NULL;

    printf("Cache shutdown complete\n");
}

uint8_t *cache_lookup(uint64_t block_id, size_t *size) {
    if (g_cache == NULL) {
        return NULL;
    }

    pthread_mutex_lock(&g_cache->lock);
    size_t bucket = hash_block_id(block_id, g_cache->table_size);
    CacheEntry *entry = g_cache->table[bucket];

    while (entry != NULL) {
        if (entry->block_id == block_id) {
            // Found it - update access info
            cache_update_access(entry);
            if (size != NULL) {
                *size = entry->size;
            }
            uint8_t *data = entry->data;
            g_cache->hits++;
            const char *v = getenv("VFS_CACHE_VERBOSE");
            if (v && v[0] != '\0') {
                fprintf(stderr, "[cache] HIT block=%lu size=%zu\n", (unsigned long)block_id, entry->size);
            }
            pthread_mutex_unlock(&g_cache->lock);
            return data;
        }
        entry = entry->next;
    }

    g_cache->misses++;
    const char *v2 = getenv("VFS_CACHE_VERBOSE");
    if (v2 && v2[0] != '\0') {
        fprintf(stderr, "[cache] MISS block=%lu\n", (unsigned long)block_id);
    }
    pthread_mutex_unlock(&g_cache->lock);
    return NULL;  // Cache miss
}

void cache_update_access(CacheEntry *entry) {
    if (entry == NULL) {
        return;
    }

    entry->last_access_time = ws_current_time();
    entry->ref_count++;
}

void cache_insert(uint64_t block_id, uint8_t *data, size_t size) {
    if (g_cache == NULL || data == NULL || size == 0) {
        return;
    }

    pthread_mutex_lock(&g_cache->lock);
    
    // Check if already exists - update instead of duplicate
    size_t bucket = hash_block_id(block_id, g_cache->table_size);
    CacheEntry *existing = g_cache->table[bucket];
    
    while (existing != NULL) {
        if (existing->block_id == block_id) {
            // Update existing entry
            free(existing->data);
            existing->data = (uint8_t *)malloc(size);
            if (existing->data != NULL) {
                memcpy(existing->data, data, size);
                existing->size = size;
                cache_update_access(existing);
            }
            pthread_mutex_unlock(&g_cache->lock);
            return;
        }
        existing = existing->next;
    }

    // Evict if needed before inserting
    cache_evict_if_needed();

    // Create new entry
    CacheEntry *entry = (CacheEntry *)malloc(sizeof(CacheEntry));
    if (entry == NULL) {
        fprintf(stderr, "Failed to allocate cache entry\n");
        return;
    }

    entry->block_id = block_id;
    entry->size = size;
    entry->data = (uint8_t *)malloc(size);
    
    if (entry->data == NULL) {
        fprintf(stderr, "Failed to allocate cache entry data\n");
        free(entry);
        return;
    }

    memcpy(entry->data, data, size);
    entry->last_access_time = ws_current_time();
    entry->ref_count = 1;

    // Insert at head of bucket
    entry->next = g_cache->table[bucket];
    g_cache->table[bucket] = entry;
    g_cache->current_size++;
    const char *v3 = getenv("VFS_CACHE_VERBOSE");
    if (v3 && v3[0] != '\0') {
        fprintf(stderr, "[cache] INSERT block=%lu size=%zu\n", (unsigned long)block_id, size);
    }
    
    pthread_mutex_unlock(&g_cache->lock);
}

void cache_evict_if_needed(void) {
    if (g_cache == NULL || g_cache->current_size < g_cache->capacity) {
        return;
    }

    uint64_t now = ws_current_time();
    CacheEntry *victim = NULL;
    CacheEntry **victim_prev = NULL;
    size_t victim_bucket = 0;

    // Phase 1: Evict entries outside working set window
    for (size_t i = 0; i < g_cache->table_size && g_cache->current_size >= g_cache->capacity; i++) {
        CacheEntry **prev = &g_cache->table[i];
        CacheEntry *entry = g_cache->table[i];

        while (entry != NULL) {
            if (!ws_is_in_working_set(entry, now, g_cache->tau)) {
                // Remove this entry
                *prev = entry->next;
                free(entry->data);
                free(entry);
                g_cache->current_size--;
                entry = *prev;
            } else {
                prev = &entry->next;
                entry = entry->next;
            }
        }
    }

    // Phase 2: If still over capacity, evict based on ref_count and age
    if (g_cache->current_size >= g_cache->capacity) {
        for (size_t i = 0; i < g_cache->table_size; i++) {
            CacheEntry **prev = &g_cache->table[i];
            CacheEntry *entry = g_cache->table[i];

            while (entry != NULL) {
                if (victim == NULL ||
                    entry->ref_count < victim->ref_count ||
                    (entry->ref_count == victim->ref_count && 
                     entry->last_access_time < victim->last_access_time)) {
                    victim = entry;
                    victim_prev = prev;
                    victim_bucket = i;
                }
                prev = &entry->next;
                entry = entry->next;
            }
        }

        if (victim != NULL) {
            *victim_prev = victim->next;
            free(victim->data);
            free(victim);
            g_cache->current_size--;
        }
    }
}

void cache_print_stats(void) {
    if (g_cache == NULL) {
        printf("Cache not initialized\n");
        return;
    }

    pthread_mutex_lock(&g_cache->lock);
    printf("Cache Statistics:\n");
    printf("  Capacity: %zu\n", g_cache->capacity);
    printf("  Current Size: %zu\n", g_cache->current_size);
    printf("  Tau (window): %lu\n", g_cache->tau);
    printf("  Load Factor: %.2f%%\n", 
           (g_cache->current_size * 100.0) / g_cache->capacity);
    printf("  Hits: %zu\n", g_cache->hits);
    printf("  Misses: %zu\n", g_cache->misses);
    pthread_mutex_unlock(&g_cache->lock);
}
void cache_get_stats(size_t *hits, size_t *misses) {
    if (!g_cache) {
        if (hits) *hits = 0;
        if (misses) *misses = 0;
        return;
    }
    pthread_mutex_lock(&g_cache->lock);
    if (hits) *hits = g_cache->hits;
    if (misses) *misses = g_cache->misses;
    pthread_mutex_unlock(&g_cache->lock);
}

// VFS-aware helper: compute block ID from mount, inode, and page offset
#define PAGE_SIZE 4096

uint64_t cache_compute_block_id(uint64_t mount_id, uint64_t ino, off_t offset) {
    // Align offset to page boundary
    uint64_t page_offset = (uint64_t)(offset / PAGE_SIZE);
    
    // Combine mount_id, inode, and page into unique block ID
    // Use bit shifting to avoid collisions
    return (mount_id << 48) | (ino << 16) | (page_offset & 0xFFFF);
}

void cache_invalidate_mount(uint64_t mount_id) {
    if (g_cache == NULL) {
        return;
    }

    pthread_mutex_lock(&g_cache->lock);
    
    // Extract mount_id from block_id and remove matching entries
    for (size_t i = 0; i < g_cache->table_size; i++) {
        CacheEntry **prev = &g_cache->table[i];
        CacheEntry *entry = g_cache->table[i];

        while (entry != NULL) {
            uint64_t entry_mount_id = entry->block_id >> 48;
            if (entry_mount_id == mount_id) {
                // Remove this entry
                *prev = entry->next;
                free(entry->data);
                free(entry);
                g_cache->current_size--;
                entry = *prev;
            } else {
                prev = &entry->next;
                entry = entry->next;
            }
        }
    }
    
    pthread_mutex_unlock(&g_cache->lock);
    printf("Cache: Invalidated all entries for mount_id %lu\n", mount_id);
}

