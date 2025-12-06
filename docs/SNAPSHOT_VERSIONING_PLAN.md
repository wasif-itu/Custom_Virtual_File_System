# SNAPSHOT AND VERSIONING IMPLEMENTATION PLAN
## Custom Virtual File System (CVFS)

**Document Version:** 1.0  
**Date:** December 6, 2025  
**Status:** Planning Phase

---

## TABLE OF CONTENTS

1. [Executive Summary](#executive-summary)
2. [Requirements Analysis](#requirements-analysis)
3. [Architecture Design](#architecture-design)
4. [Implementation Phases](#implementation-phases)
5. [Data Structures](#data-structures)
6. [API Specifications](#api-specifications)
7. [Storage Strategy](#storage-strategy)
8. [Testing Plan](#testing-plan)
9. [Performance Considerations](#performance-considerations)
10. [Future Enhancements](#future-enhancements)

---

## 1. EXECUTIVE SUMMARY

### Objective
Implement a robust snapshot and versioning system for CVFS that provides:
- **Point-in-time snapshots** of the entire filesystem or specific directories
- **File-level versioning** with automatic version creation on modifications
- **Space-efficient storage** using Copy-on-Write (CoW) semantics
- **Fast snapshot creation and restoration**
- **Version history navigation** and diff capabilities

### Key Features
- ✅ Incremental snapshots (only store changes)
- ✅ Copy-on-Write (CoW) for space efficiency
- ✅ Snapshot metadata with timestamps and descriptions
- ✅ Version chains for file history tracking
- ✅ Configurable version retention policies
- ✅ Integration with existing cache layer
- ✅ Atomic snapshot creation (transaction-safe)
- ✅ Multi-backend support (POSIX, FAT32, EXT4)

---

## 2. REQUIREMENTS ANALYSIS

### 2.1 Functional Requirements

#### FR1: Snapshot Management
- **FR1.1** Create full filesystem snapshot
- **FR1.2** Create directory-specific snapshot
- **FR1.3** List all snapshots with metadata
- **FR1.4** Delete snapshots (with dependency checking)
- **FR1.5** Restore filesystem from snapshot
- **FR1.6** Browse snapshot contents without restoration

#### FR2: File Versioning
- **FR2.1** Automatic version creation on write operations
- **FR2.2** Manual version checkpointing
- **FR2.3** List all versions of a file
- **FR2.4** Retrieve specific version of a file
- **FR2.5** Compare versions (diff functionality)
- **FR2.6** Rollback file to previous version

#### FR3: Storage Efficiency
- **FR3.1** Copy-on-Write for modified blocks
- **FR3.2** Reference counting for shared blocks
- **FR3.3** Deduplication for identical content
- **FR3.4** Compression for version data
- **FR3.5** Garbage collection for unreferenced blocks

#### FR4: Metadata Management
- **FR4.1** Snapshot metadata (timestamp, description, creator)
- **FR4.2** Version metadata (timestamp, size, checksum)
- **FR4.3** Relationship tracking (parent snapshots, version chains)
- **FR4.4** Tag support for snapshots

### 2.2 Non-Functional Requirements

#### NFR1: Performance
- Snapshot creation: < 100ms (for metadata)
- Version retrieval: < 50ms (cache hit)
- Space overhead: < 10% for metadata
- CoW overhead: < 5% on write operations

#### NFR2: Reliability
- Atomic snapshot operations (all-or-nothing)
- Crash recovery support
- Integrity checking (checksums)
- No data loss during snapshot/restore

#### NFR3: Scalability
- Support 10,000+ snapshots per filesystem
- Support 1,000+ versions per file
- Handle multi-TB filesystems
- Efficient metadata indexing

#### NFR4: Usability
- Simple CLI interface for snapshot operations
- FUSE integration (`.snapshots` directory)
- Clear error messages
- Progress indicators for long operations

---

## 3. ARCHITECTURE DESIGN

### 3.1 High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    FUSE Layer (unchanged)                       │
│                 Exposes .snapshots directory                    │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    VFS Core (modified)                          │
│  + Version-aware inode management                              │
│  + Snapshot-aware path resolution                              │
│  + CoW write interception                                      │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│              NEW: Snapshot/Version Layer                       │
│  ┌──────────────────┐  ┌──────────────────┐                   │
│  │ Snapshot Manager │  │ Version Manager  │                   │
│  │ - Create/Delete  │  │ - Track versions │                   │
│  │ - List/Restore   │  │ - CoW operations │                   │
│  │ - Metadata       │  │ - Diff engine    │                   │
│  └──────────────────┘  └──────────────────┘                   │
│  ┌──────────────────────────────────────────┐                 │
│  │     Block Reference Manager (CoW)        │                 │
│  │  - Reference counting                    │                 │
│  │  - Deduplication                         │                 │
│  │  - Garbage collection                    │                 │
│  └──────────────────────────────────────────┘                 │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    Cache Layer (modified)                       │
│  + CoW-aware caching                                           │
│  + Version-specific cache entries                              │
└─────────────────────────────────────────────────────────────────┘
                              ↓
┌─────────────────────────────────────────────────────────────────┐
│                    Backend Drivers (modified)                   │
│  + Version storage support                                     │
│  + Block-level CoW operations                                  │
└─────────────────────────────────────────────────────────────────┘
```

### 3.2 Component Interactions

**Snapshot Creation Flow:**
```
1. User calls vfs_snapshot_create("/path", "description")
2. Snapshot Manager:
   - Locks filesystem/subtree
   - Increments snapshot ID
   - Creates snapshot metadata entry
   - Marks all inodes as "copy-on-write"
   - Records inode->version mappings
   - Persists metadata to backend
   - Unlocks filesystem
3. Returns snapshot ID
```

**CoW Write Flow:**
```
1. User writes to file via vfs_write()
2. VFS Core checks if inode is CoW-protected
3. If protected:
   - Version Manager creates new version entry
   - Block Reference Manager allocates new blocks
   - Decrements refcount on old blocks
   - Updates inode to point to new blocks
   - Clears CoW flag (for this snapshot)
4. Proceeds with normal write
```

**Version Retrieval Flow:**
```
1. User requests file version: vfs_version_open("/file", version_id)
2. Version Manager:
   - Looks up version metadata
   - Retrieves block list for that version
   - Creates temporary read-only inode
   - Returns file handle
3. Reads proceed from version-specific blocks
```

### 3.3 Directory Structure

```
/                          (Live filesystem)
├── .snapshots/            (Virtual directory - FUSE level)
│   ├── snap_001_20251206_120000/
│   │   ├── home/
│   │   └── etc/
│   ├── snap_002_20251206_150000/
│   └── .snapshot_meta     (Snapshot metadata)
└── .versions/             (Backend storage)
    ├── blocks/            (Versioned block storage)
    │   ├── 0000/
    │   │   ├── block_0001
    │   │   └── block_0002
    │   └── 0001/
    ├── metadata/          (Version metadata)
    │   ├── snapshots.db   (Snapshot index)
    │   └── versions.db    (Version chains)
    └── refcount/          (Block reference counts)
```

---

## 4. IMPLEMENTATION PHASES

### Phase 1: Core Infrastructure (Week 1-2)
**Goal:** Establish foundational data structures and basic CoW support

#### Tasks:
1. **Design and implement snapshot/version data structures**
   - `vfs_snapshot_t` - Snapshot metadata
   - `vfs_version_t` - Version metadata
   - `vfs_block_ref_t` - Block reference tracking
   - `vfs_snapshot_inode_map_t` - Inode->version mapping

2. **Extend vfs_inode_t for versioning**
   - Add `uint32_t cow_flags` field
   - Add `uint64_t current_version` field
   - Add `vfs_version_t *version_head` field (version chain)

3. **Create snapshot manager module**
   - Files: `src/snapshot/snapshot_manager.c/h`
   - Functions: init, create, delete, list, restore

4. **Create version manager module**
   - Files: `src/snapshot/version_manager.c/h`
   - Functions: init, create_version, get_version, list_versions

5. **Block reference manager**
   - Files: `src/snapshot/block_ref.c/h`
   - Functions: alloc_block, incref, decref, gc

#### Deliverables:
- ✅ New source files with headers
- ✅ Data structure definitions
- ✅ Basic initialization code
- ✅ Unit tests for data structures

### Phase 2: CoW Implementation (Week 3-4)
**Goal:** Implement Copy-on-Write semantics

#### Tasks:
1. **Modify vfs_write() for CoW detection**
   - Check `cow_flags` before write
   - Trigger version creation if needed

2. **Implement block allocation with CoW**
   - Allocate new blocks for modified data
   - Update inode block pointers
   - Update reference counts

3. **Integrate with cache layer**
   - Add version ID to cache keys
   - Implement cache invalidation on CoW

4. **Backend storage for versioned blocks**
   - Extend backend API with version storage
   - Implement in POSIX backend first

5. **Reference counting system**
   - Track blocks shared across versions
   - Implement safe deletion

#### Deliverables:
- ✅ CoW-enabled write path
- ✅ Block reference counting
- ✅ Cache integration
- ✅ Unit tests for CoW operations

### Phase 3: Snapshot Operations (Week 5-6)
**Goal:** Full snapshot creation, deletion, and restoration

#### Tasks:
1. **Implement snapshot creation**
   - Lock filesystem/subtree
   - Mark all inodes for CoW
   - Create snapshot metadata
   - Persist to backend

2. **Implement snapshot deletion**
   - Check for dependent snapshots
   - Update reference counts
   - Trigger garbage collection
   - Remove metadata

3. **Implement snapshot restoration**
   - Validate snapshot integrity
   - Replace live inodes with snapshot versions
   - Update dentry cache
   - Handle file handles (close or redirect)

4. **Snapshot browsing**
   - Read-only access to snapshot contents
   - Virtual `.snapshots` directory in FUSE

5. **Metadata persistence**
   - Snapshot database (SQLite or custom format)
   - Crash recovery support

#### Deliverables:
- ✅ Full snapshot lifecycle
- ✅ Snapshot metadata database
- ✅ Restoration functionality
- ✅ Integration tests

### Phase 4: Version Management (Week 7-8)
**Goal:** File-level version tracking and retrieval

#### Tasks:
1. **Implement version chain management**
   - Link versions in temporal order
   - Track parent-child relationships

2. **Version retrieval API**
   - `vfs_version_open()` - Open specific version
   - `vfs_version_read()` - Read from version
   - `vfs_version_list()` - List all versions

3. **Version comparison (diff)**
   - Block-level diff
   - Content diff for text files
   - Metadata diff

4. **Version rollback**
   - Replace current with previous version
   - Update inode metadata
   - Trigger CoW for future writes

5. **Retention policies**
   - Time-based retention (keep last N days)
   - Count-based retention (keep last N versions)
   - Policy enforcement daemon

#### Deliverables:
- ✅ Version API implementation
- ✅ Diff functionality
- ✅ Rollback support
- ✅ Retention policies

### Phase 5: Optimization and Storage (Week 9-10)
**Goal:** Improve performance and storage efficiency

#### Tasks:
1. **Deduplication**
   - Content-based hashing (SHA256)
   - Block-level deduplication
   - Hash table for quick lookups

2. **Compression**
   - LZ4 compression for version blocks
   - Transparent compression/decompression

3. **Garbage collection**
   - Background GC thread
   - Reclaim unreferenced blocks
   - Compact storage

4. **Metadata indexing**
   - B-tree for snapshot lookups
   - Hash index for version IDs
   - Optimize query performance

5. **Performance tuning**
   - Batch metadata updates
   - Async block writes
   - Prefetching for version reads

#### Deliverables:
- ✅ Deduplication engine
- ✅ Compression support
- ✅ GC implementation
- ✅ Performance benchmarks

### Phase 6: FUSE Integration (Week 11)
**Goal:** Expose snapshots through FUSE interface

#### Tasks:
1. **Implement `.snapshots` virtual directory**
   - Special handling in `vfs_resolve_path()`
   - Dynamic directory listing

2. **Snapshot navigation**
   - Read-only mounts of snapshots
   - Transparent snapshot access

3. **Special files for control**
   - `.create_snapshot` - Trigger creation
   - `.list_versions` - Show version history

4. **FUSE callback extensions**
   - Handle snapshot paths
   - Version-aware read operations

#### Deliverables:
- ✅ FUSE snapshot browsing
- ✅ Snapshot control interface
- ✅ Integration tests

### Phase 7: CLI Tools (Week 12)
**Goal:** User-friendly command-line tools

#### Tasks:
1. **Snapshot CLI** (`vfssnap`)
   ```bash
   vfssnap create [path] "description"
   vfssnap list
   vfssnap delete <snapshot_id>
   vfssnap restore <snapshot_id> [path]
   vfssnap diff <snap1> <snap2>
   ```

2. **Version CLI** (`vfsver`)
   ```bash
   vfsver list <file>
   vfsver show <file> <version_id>
   vfsver diff <file> <ver1> <ver2>
   vfsver rollback <file> <version_id>
   ```

3. **Admin CLI** (`vfsadmin`)
   ```bash
   vfsadmin gc              # Run garbage collection
   vfsadmin stats           # Show snapshot stats
   vfsadmin retention set <policy>
   ```

#### Deliverables:
- ✅ CLI tools
- ✅ Man pages
- ✅ Usage examples

### Phase 8: Testing and Documentation (Week 13-14)
**Goal:** Comprehensive testing and documentation

#### Tasks:
1. **Unit tests**
   - Test all new modules
   - Edge case coverage
   - Memory leak detection

2. **Integration tests**
   - End-to-end snapshot workflows
   - Multi-user scenarios
   - Concurrent operations

3. **Stress tests**
   - 10,000 snapshots
   - 1,000 versions per file
   - Large file operations

4. **Documentation**
   - Architecture diagrams
   - API documentation
   - User guide
   - Performance tuning guide

#### Deliverables:
- ✅ Full test suite
- ✅ Test reports
- ✅ Complete documentation

---

## 5. DATA STRUCTURES

### 5.1 Snapshot Metadata

```c
/* Snapshot metadata structure */
typedef struct vfs_snapshot {
    uint64_t snapshot_id;              /* Unique snapshot ID */
    time_t timestamp;                  /* Creation timestamp */
    char description[256];             /* User description */
    char creator[64];                  /* Username */
    uint64_t parent_snapshot_id;       /* Parent snapshot (0 if full) */
    
    /* Snapshot type */
    enum {
        SNAPSHOT_FULL,                 /* Full filesystem snapshot */
        SNAPSHOT_INCREMENTAL,          /* Incremental from parent */
        SNAPSHOT_DIRECTORY             /* Directory-specific */
    } type;
    
    /* Scope */
    char root_path[PATH_MAX];          /* Root path of snapshot */
    
    /* Statistics */
    uint64_t num_inodes;               /* Inodes in snapshot */
    uint64_t num_blocks;               /* Blocks referenced */
    uint64_t total_size;               /* Total size in bytes */
    
    /* Metadata */
    uint32_t flags;                    /* Snapshot flags */
    char tags[512];                    /* Comma-separated tags */
    
    /* Reference tracking */
    int refcount;                      /* Reference count */
    pthread_rwlock_t lock;             /* Snapshot lock */
    
    /* Linked list */
    struct vfs_snapshot *next;         /* Next snapshot in list */
} vfs_snapshot_t;
```

### 5.2 Version Metadata

```c
/* File version metadata */
typedef struct vfs_version {
    uint64_t version_id;               /* Unique version ID */
    uint64_t snapshot_id;              /* Associated snapshot */
    uint64_t inode_num;                /* Inode number */
    
    time_t timestamp;                  /* Version creation time */
    off_t size;                        /* File size at version */
    mode_t mode;                       /* File mode at version */
    
    /* Block mapping */
    uint64_t *block_ids;               /* Array of block IDs */
    size_t num_blocks;                 /* Number of blocks */
    
    /* Content hash (for dedup) */
    uint8_t content_hash[32];          /* SHA256 hash */
    
    /* Version chain */
    struct vfs_version *parent;        /* Previous version */
    struct vfs_version *next;          /* Next version */
    
    /* Metadata */
    uint32_t flags;                    /* Version flags */
    pthread_mutex_t lock;              /* Version lock */
} vfs_version_t;
```

### 5.3 Block Reference Tracking

```c
/* Block reference entry */
typedef struct vfs_block_ref {
    uint64_t block_id;                 /* Unique block ID */
    uint32_t refcount;                 /* Reference count */
    uint8_t hash[32];                  /* Content hash (SHA256) */
    
    /* Storage location */
    enum {
        BLOCK_BACKEND,                 /* Stored in backend */
        BLOCK_CACHE,                   /* In cache only */
        BLOCK_COMPRESSED               /* Compressed storage */
    } storage_type;
    
    off_t backend_offset;              /* Offset in backend */
    size_t block_size;                 /* Actual block size */
    size_t compressed_size;            /* Size if compressed */
    
    /* Linked list for hash table */
    struct vfs_block_ref *next;
    
    pthread_mutex_t lock;              /* Block lock */
} vfs_block_ref_t;
```

### 5.4 Extended Inode Structure

```c
/* Extended inode with versioning support */
typedef struct vfs_inode_extended {
    /* Original fields (from vfs_inode_t) */
    uint64_t ino;
    mode_t mode;
    uid_t uid;
    gid_t gid;
    off_t size;
    int refcount;
    void *backend_handle;
    pthread_mutex_t lock;
    
    /* NEW: Versioning fields */
    uint32_t cow_flags;                /* Copy-on-Write flags */
    uint64_t current_version;          /* Current version ID */
    vfs_version_t *version_head;       /* Version chain head */
    uint64_t num_versions;             /* Total versions */
    
    /* NEW: Snapshot tracking */
    uint64_t snapshot_id;              /* Last snapshot ID */
    uint8_t is_cow_protected;          /* CoW protection flag */
    
} vfs_inode_extended_t;
```

---

## 6. API SPECIFICATIONS

### 6.1 Snapshot Management API

```c
/* Initialize snapshot subsystem */
int vfs_snapshot_init(void);

/* Shutdown snapshot subsystem */
int vfs_snapshot_shutdown(void);

/* Create a new snapshot */
int vfs_snapshot_create(const char *root_path, 
                        const char *description,
                        uint64_t *snapshot_id_out);

/* Delete a snapshot */
int vfs_snapshot_delete(uint64_t snapshot_id);

/* List all snapshots */
int vfs_snapshot_list(vfs_snapshot_t **snapshots_out, size_t *count_out);

/* Get snapshot metadata */
int vfs_snapshot_get(uint64_t snapshot_id, vfs_snapshot_t **snapshot_out);

/* Restore from snapshot */
int vfs_snapshot_restore(uint64_t snapshot_id, const char *target_path);

/* Compare two snapshots */
int vfs_snapshot_diff(uint64_t snap1_id, uint64_t snap2_id, 
                      vfs_snapshot_diff_t **diff_out);
```

### 6.2 Version Management API

```c
/* Initialize version subsystem */
int vfs_version_init(void);

/* Create a new version for inode */
int vfs_version_create(vfs_inode_t *inode, vfs_version_t **version_out);

/* Get specific version of a file */
int vfs_version_get(const char *path, uint64_t version_id, 
                    vfs_version_t **version_out);

/* List all versions of a file */
int vfs_version_list(const char *path, vfs_version_t **versions_out, 
                     size_t *count_out);

/* Open a specific version (read-only) */
int vfs_version_open(const char *path, uint64_t version_id, int *fh_out);

/* Read from a specific version */
ssize_t vfs_version_read(int fh, void *buf, size_t count, off_t offset);

/* Close version handle */
int vfs_version_close(int fh);

/* Rollback file to specific version */
int vfs_version_rollback(const char *path, uint64_t version_id);

/* Compare two versions */
int vfs_version_diff(const char *path, uint64_t ver1, uint64_t ver2,
                     vfs_version_diff_t **diff_out);
```

### 6.3 Block Reference API

```c
/* Initialize block reference manager */
int vfs_blockref_init(void);

/* Allocate new block */
int vfs_blockref_alloc(uint64_t *block_id_out);

/* Increment reference count */
int vfs_blockref_incref(uint64_t block_id);

/* Decrement reference count */
int vfs_blockref_decref(uint64_t block_id);

/* Get reference count */
int vfs_blockref_getref(uint64_t block_id, uint32_t *refcount_out);

/* Garbage collection */
int vfs_blockref_gc(void);

/* Deduplication check */
int vfs_blockref_deduplicate(const uint8_t *data, size_t size, 
                             uint64_t *existing_block_id);
```

---

## 7. STORAGE STRATEGY

### 7.1 Block Storage Layout

```
.versions/blocks/
├── 0000/
│   ├── 0000000001.blk      (Block data)
│   ├── 0000000002.blk
│   └── ...
├── 0001/
│   └── ...
└── index.db                (Block->File mapping)
```

**Block Naming Convention:**
- Directory: `(block_id / 10000) % 10000` (4 digits)
- Filename: `block_id % 10000` (10 digits) + `.blk`
- Example: Block 123456 → `0012/0000123456.blk`

### 7.2 Metadata Storage

```
.versions/metadata/
├── snapshots.db            (SQLite: Snapshot metadata)
├── versions.db             (SQLite: Version chains)
├── refcount.db             (SQLite: Block reference counts)
└── dedup.db                (SQLite: Hash->BlockID mapping)
```

**Schema (SQLite):**

```sql
-- snapshots.db
CREATE TABLE snapshots (
    snapshot_id INTEGER PRIMARY KEY,
    timestamp INTEGER NOT NULL,
    description TEXT,
    creator TEXT,
    parent_snapshot_id INTEGER,
    type INTEGER,
    root_path TEXT,
    num_inodes INTEGER,
    num_blocks INTEGER,
    total_size INTEGER,
    flags INTEGER,
    tags TEXT
);

-- versions.db
CREATE TABLE versions (
    version_id INTEGER PRIMARY KEY,
    snapshot_id INTEGER,
    inode_num INTEGER,
    timestamp INTEGER,
    size INTEGER,
    mode INTEGER,
    num_blocks INTEGER,
    content_hash BLOB,
    parent_version_id INTEGER,
    flags INTEGER
);

CREATE TABLE version_blocks (
    version_id INTEGER,
    block_index INTEGER,
    block_id INTEGER,
    PRIMARY KEY (version_id, block_index)
);

-- refcount.db
CREATE TABLE block_refs (
    block_id INTEGER PRIMARY KEY,
    refcount INTEGER NOT NULL,
    content_hash BLOB,
    storage_type INTEGER,
    backend_offset INTEGER,
    block_size INTEGER,
    compressed_size INTEGER
);

-- dedup.db
CREATE TABLE block_hash_index (
    content_hash BLOB PRIMARY KEY,
    block_id INTEGER
);
```

### 7.3 CoW Storage Flow

**Initial Write (No CoW):**
```
1. Write data to block
2. Update inode block pointer
3. Store block in backend
```

**CoW Write:**
```
1. Check if inode is CoW-protected
2. Allocate new block ID
3. Copy old block data (if partial write)
4. Write new data to new block
5. Update inode -> new block
6. Decrement old block refcount
7. If old block refcount == 0, mark for GC
```

---

## 8. TESTING PLAN

### 8.1 Unit Tests

**Snapshot Manager Tests:**
- Create/delete snapshots
- List snapshots with filters
- Snapshot metadata persistence
- Concurrent snapshot operations

**Version Manager Tests:**
- Version creation and linking
- Version chain traversal
- Version retrieval by ID
- Version deletion and GC

**Block Reference Tests:**
- Reference count increment/decrement
- Block allocation/deallocation
- Deduplication detection
- Garbage collection

**CoW Tests:**
- CoW flag setting/clearing
- Block copying on write
- Reference count updates
- Cache invalidation

### 8.2 Integration Tests

**End-to-End Snapshot:**
```bash
1. Create filesystem with test files
2. Create snapshot
3. Modify files
4. Create second snapshot
5. Restore first snapshot
6. Verify files match original
```

**End-to-End Versioning:**
```bash
1. Create file
2. Write data (version 1)
3. Modify file (version 2)
4. Modify again (version 3)
5. Retrieve version 1
6. Verify content matches original
7. Rollback to version 2
8. Verify file state
```

**Concurrent Operations:**
```bash
1. Create 100 threads
2. Each thread:
   - Creates snapshots
   - Modifies files
   - Creates versions
3. Verify no race conditions
4. Verify reference counts correct
```

### 8.3 Stress Tests

**Snapshot Scale Test:**
- Create 10,000 snapshots
- Measure creation time
- Measure storage overhead
- Test deletion performance

**Version Scale Test:**
- Create 1,000 versions of a file
- Measure version creation time
- Test version retrieval performance
- Verify memory usage

**Storage Efficiency Test:**
- Create 1,000 files (100MB each)
- Create 100 snapshots with small changes
- Measure total storage used
- Verify deduplication working
- Expected: < 110GB (10% overhead)

---

## 9. PERFORMANCE CONSIDERATIONS

### 9.1 Expected Performance Metrics

| Operation | Target | Measurement |
|-----------|--------|-------------|
| Snapshot creation (metadata) | < 100ms | Time to create snapshot record |
| Snapshot restoration | < 5s per GB | Time to restore files |
| Version creation | < 10ms | Time to create version entry |
| Version retrieval (cache hit) | < 50ms | Time to open version |
| CoW write overhead | < 5% | Compared to normal write |
| Deduplication check | < 1ms | Hash lookup time |
| Garbage collection | < 1s per 1000 blocks | GC scan time |

### 9.2 Optimization Strategies

**Metadata Caching:**
- Cache frequently accessed snapshots in memory
- Use LRU eviction for snapshot metadata
- Index versions by inode for fast lookup

**Batch Operations:**
- Batch reference count updates
- Batch block allocations
- Batch metadata writes to database

**Async Operations:**
- Async block writes to backend
- Async garbage collection
- Async compression

**Prefetching:**
- Prefetch version blocks on open
- Prefetch adjacent versions
- Prefetch snapshot metadata

### 9.3 Space Efficiency

**Deduplication:**
- Expected 20-30% space savings for typical workloads
- Higher savings for repeated content (configs, logs)

**Compression:**
- LZ4 compression ratio: 2-3x for text files
- Lower ratio for binary files
- Compression overhead: < 2ms per block

**Metadata Overhead:**
- Snapshot metadata: ~1KB per snapshot
- Version metadata: ~500 bytes per version
- Block reference: ~100 bytes per block
- Total: < 5% for typical workloads

---

## 10. FUTURE ENHANCEMENTS

### Phase 9+: Advanced Features

**Remote Snapshots:**
- Replicate snapshots to remote servers
- Incremental sync protocol
- Disaster recovery support

**Snapshot Scheduling:**
- Cron-based automatic snapshots
- Retention policy enforcement
- Health monitoring

**Snapshot Encryption:**
- Encrypt snapshot data at rest
- Key management integration
- Transparent decryption

**Snapshot Compression:**
- Compress entire snapshots
- Transparent decompression
- Space savings analysis

**Advanced Diff:**
- Syntax-aware diff for code files
- Visual diff tools
- Merge conflict resolution

**Snapshot Tagging:**
- Tag snapshots with metadata
- Search by tags
- Organize snapshots

**Snapshot Export/Import:**
- Export snapshots to archives
- Import snapshots from other systems
- Format conversion

---

## APPENDIX A: RISK ANALYSIS

| Risk | Impact | Probability | Mitigation |
|------|--------|-------------|------------|
| Reference count corruption | High | Medium | Extensive testing, atomic updates |
| Metadata corruption | High | Low | Checksums, redundant storage |
| Performance degradation | Medium | Medium | Profiling, optimization |
| Storage exhaustion | Medium | High | Quotas, GC, monitoring |
| Race conditions | High | Medium | Lock analysis, testing |
| Data loss during restore | High | Low | Validation, atomic operations |

---

## APPENDIX B: GLOSSARY

- **CoW (Copy-on-Write):** Optimization where data is not copied until modified
- **Snapshot:** Point-in-time capture of filesystem state
- **Version:** Historical state of a specific file
- **Refcount:** Reference count tracking shared resources
- **Deduplication:** Eliminating duplicate data blocks
- **GC (Garbage Collection):** Reclaiming unreferenced storage
- **Incremental Snapshot:** Snapshot storing only changes from parent

---

## APPENDIX C: REFERENCES

1. ZFS Snapshot Implementation: https://docs.oracle.com/cd/E19253-01/819-5461/gbciq/index.html
2. Btrfs Snapshot Design: https://btrfs.wiki.kernel.org/index.php/SysadminGuide#Snapshots
3. WAFL (Write Anywhere File Layout): NetApp Technical Report
4. Copy-on-Write B-Trees: "Modern B-Tree Techniques" by Goetz Graefe
5. File Versioning Systems: "Version Control with Git" by Jon Loeliger

---

**Document Status:** ✅ COMPLETE  
**Next Steps:** Review and approval, begin Phase 1 implementation  
**Estimated Total Development Time:** 14 weeks (3.5 months)  
**Team Size Required:** 2-3 developers
