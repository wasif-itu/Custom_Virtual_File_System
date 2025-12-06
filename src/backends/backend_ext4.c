#include "backend_ext4.h"
#include "../core/vfs_core.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <stdio.h>

/* Minimal EXT4 structures and backend state */
typedef struct ext4_super_block {
    uint32_t s_inodes_count;
    uint32_t s_blocks_count_lo;
    uint32_t s_r_blocks_count_lo;
    uint32_t s_free_blocks_count_lo;
    uint32_t s_free_inodes_count;
    uint32_t s_first_data_block;
    uint32_t s_log_block_size; /* block size = 1024 << s_log_block_size */
    uint32_t s_log_cluster_size;
    uint32_t s_blocks_per_group;
    uint32_t s_clusters_per_group;
    uint32_t s_inodes_per_group;
    uint32_t s_mtime;
    uint32_t s_wtime;
    uint16_t s_mnt_count;
    uint16_t s_max_mnt_count;
    uint16_t s_magic; /* 0xEF53 */
    uint16_t s_state;
} __attribute__((packed)) ext4_super_block_t;

#define EXT4_SUPER_MAGIC 0xEF53
#define EXT4_SUPERBLOCK_OFFSET 1024

typedef struct ext4_backend {
    int device_fd;
    ext4_super_block_t sb;
    uint32_t block_size;
    struct ext4_file_handle {
        int in_use;
        uint32_t ino;
        off_t offset;
        uint64_t size;
        struct ext4_inode {
            uint16_t i_mode;
            uint16_t i_uid;
            uint32_t i_size_lo;
            uint32_t i_atime;
            uint32_t i_ctime;
            uint32_t i_mtime;
            uint32_t i_dtime;
            uint16_t i_gid;
            uint16_t i_links_count;
            uint32_t i_blocks_lo;
            uint32_t i_flags;
            uint32_t i_osd1;
            uint32_t i_block[15];
            uint32_t i_generation;
            uint32_t i_file_acl_lo;
            uint32_t i_size_high;
        } inode;
    } *handles;
    int max_handles;
} ext4_backend_t;

static int ext4_ops_init(const char *device_path, void **backend_data) {
    if (!device_path || !backend_data) return -EINVAL;
    ext4_backend_t *b = calloc(1, sizeof(ext4_backend_t));
    if (!b) return -ENOMEM;

    /* Open device or image file read-only for now */
    b->device_fd = open(device_path, O_RDONLY);
    if (b->device_fd < 0) {
        int err = -errno;
        free(b);
        return err;
    }

    /* Read superblock */
    ssize_t n = pread(b->device_fd, &b->sb, sizeof(b->sb), EXT4_SUPERBLOCK_OFFSET);
    if (n != (ssize_t)sizeof(b->sb)) {
        int err = -EIO;
        close(b->device_fd);
        free(b);
        return err;
    }

    if (b->sb.s_magic != EXT4_SUPER_MAGIC) {
        close(b->device_fd);
        free(b);
        return -EINVAL; /* Not an ext4 filesystem */
    }

    b->block_size = 1024u << b->sb.s_log_block_size;

        /* Diagnostic: print key parameters for verification */
        fprintf(stderr, "[ext4] mounted device '%s' block_size=%u inodes_per_group=%u blocks_per_group=%u\n",
            device_path, b->block_size, b->sb.s_inodes_per_group, b->sb.s_blocks_per_group);

    *backend_data = b;
    return 0;
}

static int ext4_ops_shutdown(void *backend_data) {
    if (!backend_data) return -EINVAL;
    ext4_backend_t *b = (ext4_backend_t *)backend_data;
    if (b->device_fd >= 0) close(b->device_fd);
    if (b->handles) free(b->handles);
    free(b);
    return 0;
}

/* ---- helpers for inode/extent and dir parsing ---- */
#define EXT4_ROOT_INO 2

static int ext4_read_inode(ext4_backend_t *b, uint32_t ino, void *inode_buf, size_t inode_size)
{
    if (!b || b->device_fd < 0 || !inode_buf || inode_size == 0) return -EINVAL;
    uint64_t inode_table_block = 5; /* demo placeholder */
    uint64_t offset = (inode_table_block * (uint64_t)b->block_size) + (uint64_t)(ino - 1) * inode_size;
    ssize_t n = pread(b->device_fd, inode_buf, inode_size, offset);
    if (n != (ssize_t)inode_size) return -EIO;
    return 0;
}

struct ext4_extent_header { uint16_t eh_magic, eh_entries, eh_max, eh_depth; uint32_t eh_generation; } __attribute__((packed));
struct ext4_extent { uint32_t ee_block; uint16_t ee_len; uint16_t ee_start_hi; uint32_t ee_start_lo; } __attribute__((packed));
#define EXT4_EXTENT_MAGIC 0xF30A

static int ext4_extent_map_block(ext4_backend_t *b, const struct ext4_file_handle *fh, uint32_t lblock, uint64_t *pblock)
{
    (void)b;
    const struct ext4_extent_header *eh = (const struct ext4_extent_header *)fh->inode.i_block;
    if (eh->eh_magic != EXT4_EXTENT_MAGIC || eh->eh_depth != 0) return -ENOSYS;
    const struct ext4_extent *ext = (const struct ext4_extent *)(eh + 1);
    for (int i = 0; i < eh->eh_entries; i++) {
        uint32_t start = ext[i].ee_block; uint16_t len = ext[i].ee_len;
        uint64_t phys = ((uint64_t)ext[i].ee_start_hi << 32) | ext[i].ee_start_lo;
        if (lblock >= start && lblock < start + len) { *pblock = phys + (lblock - start); return 0; }
    }
    return -ENOENT;
}

struct ext4_dir_entry_2 { uint32_t inode; uint16_t rec_len; uint8_t name_len; uint8_t file_type; char name[]; } __attribute__((packed));

static int ext4_ops_open(void *backend_data, const char *relpath, int flags, void **handle) {
    if (!backend_data || !relpath || !handle) return -EINVAL;
    ext4_backend_t *b = (ext4_backend_t *)backend_data;
    if ((flags & O_WRONLY) || (flags & O_RDWR)) return -EACCES;
    /* read root inode */
    struct ext4_file_handle dirfh = {0};
    if (ext4_read_inode(b, EXT4_ROOT_INO, &dirfh.inode, sizeof(dirfh.inode)) != 0) return -ENOENT;
    uint64_t size = ((uint64_t)dirfh.inode.i_size_high << 32) | dirfh.inode.i_size_lo;
    uint32_t block_sz = b->block_size; uint32_t num_blocks = (size + block_sz - 1) / block_sz;
    uint32_t target_ino = 0;
    for (uint32_t i = 0; i < num_blocks && target_ino == 0; i++) {
        uint64_t phys_block = 0; if (ext4_extent_map_block(b, &dirfh, i, &phys_block) != 0) continue;
        uint8_t *blk = malloc(block_sz);
        if (!blk) return -ENOMEM;
        ssize_t n = pread(b->device_fd, blk, block_sz, phys_block * (uint64_t)block_sz);
        if (n != (ssize_t)block_sz) { free(blk); continue; }
        uint32_t off = 0;
        while (off + sizeof(struct ext4_dir_entry_2) <= block_sz) {
            struct ext4_dir_entry_2 *de = (struct ext4_dir_entry_2 *)(blk + off);
            if (de->rec_len == 0 || de->inode == 0) break;
            uint32_t reclen = de->rec_len; uint8_t namelen = de->name_len; if (off + reclen > block_sz) break;
            char name[256]; size_t nl = namelen < sizeof(name)-1 ? namelen : sizeof(name)-1;
            memcpy(name, de->name, nl); name[nl] = '\0';
            if (strcmp(name, relpath) == 0) { target_ino = de->inode; break; }
            off += reclen;
        }
        free(blk);
    }
    if (target_ino == 0) return -ENOENT;
    struct ext4_file_handle fh = {0};
    if (ext4_read_inode(b, target_ino, &fh.inode, sizeof(fh.inode)) != 0) return -EIO;
    if ((fh.inode.i_mode & S_IFMT) != S_IFREG) return -EISDIR;
    fh.in_use = 1; fh.ino = target_ino; fh.offset = 0; fh.size = ((uint64_t)fh.inode.i_size_high << 32) | fh.inode.i_size_lo;
    if (!b->handles) { b->max_handles = 256; b->handles = calloc(b->max_handles, sizeof(*b->handles)); if (!b->handles) return -ENOMEM; }
    for (int i = 0; i < b->max_handles; i++) { if (!b->handles[i].in_use) { b->handles[i] = fh; *handle = (void *)(intptr_t)(i + 1); return 0; } }
    return -EMFILE;
}

static int ext4_ops_close(void *backend_data, void *handle) {
    if (!backend_data || !handle) return -EINVAL;
    ext4_backend_t *b = (ext4_backend_t *)backend_data;
    int idx = (int)(intptr_t)handle - 1; if (idx < 0 || idx >= b->max_handles) return -EBADF;
    b->handles[idx].in_use = 0; return 0;
}

static ssize_t ext4_ops_read(void *backend_data, void *handle, void *buf, size_t count, off_t offset) {
    if (!backend_data || !handle || !buf) return -EINVAL;
    ext4_backend_t *b = (ext4_backend_t *)backend_data;
    int idx = (int)(intptr_t)handle - 1; if (idx < 0 || idx >= b->max_handles) return -EBADF;
    struct ext4_file_handle *fh = &b->handles[idx]; if (!fh->in_use) return -EBADF;
    uint64_t size = fh->size; if ((uint64_t)offset >= size) return 0; if ((uint64_t)offset + count > size) count = (size - offset);
    size_t read_total = 0; uint8_t *dst = (uint8_t *)buf; uint32_t block_sz = b->block_size;
    while (read_total < count) {
        uint64_t abs_off = (uint64_t)offset + read_total; uint32_t lblock = abs_off / block_sz; uint32_t boff = abs_off % block_sz;
        uint64_t phys_block = 0; if (ext4_extent_map_block(b, fh, lblock, &phys_block) != 0) break;
        uint8_t *blk = malloc(block_sz);
        if (!blk) return -ENOMEM;
        ssize_t n = pread(b->device_fd, blk, block_sz, phys_block * (uint64_t)block_sz); if (n != (ssize_t)block_sz) { free(blk); break; }
        size_t to_copy = block_sz - boff; if (to_copy > count - read_total) to_copy = count - read_total;
        memcpy(dst + read_total, blk + boff, to_copy); free(blk); read_total += to_copy;
    }
    return (ssize_t)read_total;
}

static ssize_t ext4_ops_write(void *backend_data, void *handle, const void *buf, size_t count, off_t offset) {
    /* Read-only filesystem - writes not supported */
    (void)backend_data; (void)handle; (void)buf; (void)count; (void)offset;
    return -ENOSYS;
}

static int ext4_ops_stat(void *backend_data, const char *relpath, struct stat *st) {
    if (!backend_data || !relpath || !st) return -EINVAL;
    ext4_backend_t *b = (ext4_backend_t *)backend_data;
    /* Root directory stat */
    if (relpath[0] == '\0' || (relpath[0] == '.' && relpath[1] == '\0')) {
        memset(st, 0, sizeof(*st));
        st->st_mode = S_IFDIR | 0755;
        st->st_nlink = 2;
        st->st_ino = EXT4_ROOT_INO;
        st->st_size = b->block_size;
        return 0;
    }
    /* Single-level lookup in root directory */
    struct ext4_file_handle dirfh = {0};
    if (ext4_read_inode(b, EXT4_ROOT_INO, &dirfh.inode, sizeof(dirfh.inode)) != 0) return -ENOENT;
    uint64_t size = ((uint64_t)dirfh.inode.i_size_high << 32) | dirfh.inode.i_size_lo;
    uint32_t block_sz = b->block_size; uint32_t num_blocks = (size + block_sz - 1) / block_sz;
    uint32_t target_ino = 0;
    for (uint32_t i = 0; i < num_blocks && target_ino == 0; i++) {
        uint64_t phys_block = 0; if (ext4_extent_map_block(b, &dirfh, i, &phys_block) != 0) continue;
        uint8_t *blk = malloc(block_sz);
        if (!blk) return -ENOMEM;
        ssize_t n = pread(b->device_fd, blk, block_sz, phys_block * (uint64_t)block_sz);
        if (n != (ssize_t)block_sz) { free(blk); continue; }
        uint32_t off = 0;
        while (off + sizeof(struct ext4_dir_entry_2) <= block_sz) {
            struct ext4_dir_entry_2 *de = (struct ext4_dir_entry_2 *)(blk + off);
            if (de->rec_len == 0 || de->inode == 0) break;
            uint32_t reclen = de->rec_len; if (reclen < sizeof(struct ext4_dir_entry_2) || off + reclen > block_sz) break;
            uint8_t namelen = de->name_len; if (namelen > reclen - sizeof(struct ext4_dir_entry_2)) namelen = (uint8_t)(reclen - sizeof(struct ext4_dir_entry_2));
            char name[256]; size_t nl = namelen < sizeof(name)-1 ? namelen : sizeof(name)-1; memcpy(name, de->name, nl); name[nl] = '\0';
            if (strcmp(name, relpath) == 0) { target_ino = de->inode; break; }
            off += reclen;
        }
        free(blk);
    }
    if (target_ino == 0) return -ENOENT;
    struct ext4_inode ino = {0}; if (ext4_read_inode(b, target_ino, &ino, sizeof(ino)) != 0) return -EIO;
    memset(st, 0, sizeof(*st));
    st->st_ino = target_ino;
    st->st_mode = ino.i_mode;
    st->st_nlink = ino.i_links_count;
    st->st_size = ((uint64_t)ino.i_size_high << 32) | ino.i_size_lo;
    return 0;
}

static int ext4_ops_readdir(void *backend_data, const char *relpath, void *buf, void *filler) {
    if (!backend_data || !relpath || !buf || !filler) return -EINVAL;
    ext4_backend_t *b = (ext4_backend_t *)backend_data;
    (void)b;
    /* Large-step: provide minimal root readdir handling for relpath "." or empty */
    if (relpath[0] == '\0' || (relpath[0] == '.' && relpath[1] == '\0')) {
        /* FUSE3 filler signature: int (*)(void*, const char*, const struct stat*, off_t, int) */
        typedef int (*fill_fn_t)(void *, const char *, const struct stat *, off_t, int);
        fill_fn_t fill = (fill_fn_t)filler;
        /* Add . and .. entries */
        if (fill(buf, ".", NULL, 0, 0) != 0) return 0;
        if (fill(buf, "..", NULL, 0, 0) != 0) return 0;
        /* List entries from root directory leaf extents */
        struct ext4_file_handle fh = {0}; fh.in_use = 1; fh.ino = EXT4_ROOT_INO;
        if (ext4_read_inode(b, EXT4_ROOT_INO, &fh.inode, sizeof(fh.inode)) == 0) {
            /* iterate leaf extents and emit names */
            uint64_t size = ((uint64_t)fh.inode.i_size_high << 32) | fh.inode.i_size_lo;
            uint32_t block_sz = b->block_size; uint32_t num_blocks = (size + block_sz - 1) / block_sz;
            for (uint32_t i = 0; i < num_blocks; i++) {
                uint64_t phys_block = 0; if (ext4_extent_map_block(b, &fh, i, &phys_block) != 0) continue;
                uint8_t *blk = malloc(block_sz);
                if (!blk) return -ENOMEM;
                ssize_t n = pread(b->device_fd, blk, block_sz, phys_block * (uint64_t)block_sz);
                if (n != (ssize_t)block_sz) { free(blk); continue; }
                uint32_t off = 0;
                while (off + sizeof(struct ext4_dir_entry_2) <= block_sz) {
                    struct ext4_dir_entry_2 *de = (struct ext4_dir_entry_2 *)(blk + off);
                    if (de->rec_len == 0 || de->inode == 0) break;
                    uint32_t reclen = de->rec_len;
                    if (reclen < sizeof(struct ext4_dir_entry_2) || off + reclen > block_sz) break;
                    uint8_t namelen = de->name_len;
                    if (namelen > reclen - sizeof(struct ext4_dir_entry_2)) namelen = (uint8_t)(reclen - sizeof(struct ext4_dir_entry_2));
                    char name[256]; size_t nl = namelen < sizeof(name)-1 ? namelen : sizeof(name)-1;
                    memcpy(name, de->name, nl); name[nl] = '\0';
                    if (strcmp(name, ".") && strcmp(name, "..")) fill(buf, name, NULL, 0, 0);
                    off += reclen;
                }
                free(blk);
            }
        }
        return 0;
    }
    /* Non-root directories not implemented yet */
    return -ENOSYS;
}

static const vfs_backend_ops_t ext4_backend_ops = {
    .name = "ext4",
    .init = ext4_ops_init,
    .shutdown = ext4_ops_shutdown,
    .open = ext4_ops_open,
    .close = ext4_ops_close,
    .read = ext4_ops_read,
    .write = ext4_ops_write,
    .stat = ext4_ops_stat,
    .readdir = ext4_ops_readdir,
};

const vfs_backend_ops_t *get_ext4_backend_ops(void) {
    return &ext4_backend_ops;
}
