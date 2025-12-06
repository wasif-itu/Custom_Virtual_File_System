#include "backend_fat.h"
#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

static uint32_t fat32_get_next_cluster(fat32_backend_t *fat, uint32_t cluster) {
    if (!fat || cluster >= fat->fat_cache_size) return 0;
    uint32_t next = fat->fat_cache[cluster] & 0x0FFFFFFF;
    if (next >= 0x0FFFFFF8) return 0;
    return next;
}

static int fat32_read_cluster(fat32_backend_t *fat, uint32_t cluster, void *buf) {
    if (!fat || !buf || cluster < 2) return -EINVAL;
    uint32_t first_sector = fat->data_start_sector + ((cluster - 2) * fat->sectors_per_cluster);
    off_t offset = (off_t)first_sector * fat->bytes_per_sector;
    ssize_t n = pread(fat->device_fd, buf, fat->bytes_per_cluster, offset);
    if (n != (ssize_t)fat->bytes_per_cluster) return -EIO;
    return 0;
}

static int fat32_ops_init(const char *device_path, void **backend_data) {
    if (!device_path || !backend_data) return -EINVAL;
    fat32_backend_t *fat = calloc(1, sizeof(fat32_backend_t));
    if (!fat) return -ENOMEM;
    fat->device_fd = open(device_path, O_RDONLY);
    if (fat->device_fd < 0) { free(fat); return -errno; }
    ssize_t n = pread(fat->device_fd, &fat->boot, sizeof(fat->boot), 0);
    if (n != (ssize_t)sizeof(fat->boot)) { int err=-EIO; close(fat->device_fd); free(fat); return err; }
    if (memcmp(fat->boot.BS_FilSysType, "FAT32   ", 8) != 0) { close(fat->device_fd); free(fat); return -EINVAL; }
    fat->bytes_per_sector = fat->boot.BPB_BytsPerSec;
    fat->sectors_per_cluster = fat->boot.BPB_SecPerClus;
    fat->bytes_per_cluster = fat->bytes_per_sector * fat->sectors_per_cluster;
    fat->fat_start_sector = fat->boot.BPB_RsvdSecCnt;
    fat->data_start_sector = fat->boot.BPB_RsvdSecCnt + (fat->boot.BPB_NumFATs * fat->boot.BPB_FATSz32);
    fat->root_cluster = fat->boot.BPB_RootClus;
    fat->fat_size_bytes = fat->boot.BPB_FATSz32 * fat->bytes_per_sector;
    fat->fat_cache_size = fat->fat_size_bytes / 4;
    fat->fat_cache = (uint32_t*)malloc(fat->fat_size_bytes);
    if (!fat->fat_cache) { close(fat->device_fd); free(fat); return -ENOMEM; }
    n = pread(fat->device_fd, fat->fat_cache, fat->fat_size_bytes, (off_t)fat->fat_start_sector * fat->bytes_per_sector);
    if (n != (ssize_t)fat->fat_size_bytes) { free(fat->fat_cache); close(fat->device_fd); free(fat); return -EIO; }
    fat->max_handles = 256;
    fat->handles = calloc(fat->max_handles, sizeof(*fat->handles));
    if (!fat->handles) { free(fat->fat_cache); close(fat->device_fd); free(fat); return -ENOMEM; }
    *backend_data = fat; return 0;
}

static int fat32_ops_shutdown(void *backend_data) {
    if (!backend_data) return -EINVAL;
    fat32_backend_t *fat = (fat32_backend_t*)backend_data;
    if (fat->device_fd >= 0) close(fat->device_fd);
    if (fat->fat_cache) free(fat->fat_cache);
    if (fat->handles) free(fat->handles);
    free(fat);
    return 0;
}

static int fat32_path_lookup(fat32_backend_t *fat, const char *path, uint32_t *cluster_out) {
    if (!fat || !path || !cluster_out) return -EINVAL;
    if (strcmp(path, "/") == 0 || strcmp(path, ".") == 0 || path[0] == '\0') { *cluster_out = fat->root_cluster; return 0; }
    char *copy = strdup(path); if (!copy) return -ENOMEM;
    char *p = copy; if (*p == '/') p++;
    uint32_t current = fat->root_cluster;
    char *token;
    while ((token = strsep(&p, "/")) != NULL) {
        if (*token == '\0') continue;
        int found = 0; uint32_t search = current;
        while (search) {
            uint8_t *buf = (uint8_t*)malloc(fat->bytes_per_cluster); if (!buf) { free(copy); return -ENOMEM; }
            if (fat32_read_cluster(fat, search, buf) != 0) { free(buf); free(copy); return -EIO; }
            for (uint32_t off = 0; off + sizeof(struct fat32_dir_entry) <= fat->bytes_per_cluster; off += 32) {
                struct fat32_dir_entry *de = (struct fat32_dir_entry*)(buf + off);
                if (de->DIR_Name[0] == 0x00) break;
                if (de->DIR_Name[0] == 0xE5) continue;
                if (de->DIR_Attr == ATTR_LONG_NAME) continue;
                char name[13];
                int name_len = 0;
                for (int i=0;i<8 && de->DIR_Name[i] != ' ';i++) name[name_len++] = de->DIR_Name[i];
                if (de->DIR_Name[8] != ' ') { name[name_len++] = '.'; for (int i=8;i<11 && de->DIR_Name[i] != ' ';i++) name[name_len++] = de->DIR_Name[i]; }
                name[name_len] = '\0';
                if (strcasecmp(name, token) == 0) {
                    current = ((uint32_t)de->DIR_FstClusHI << 16) | de->DIR_FstClusLO;
                    found = 1; break;
                }
            }
            free(buf);
            if (found) break;
            search = fat32_get_next_cluster(fat, search);
        }
        if (!found) { free(copy); return -ENOENT; }
    }
    free(copy); *cluster_out = current; return 0;
}

static int fat32_ops_open(void *backend_data, const char *relpath, int flags, void **handle) {
    if (!backend_data || !relpath || !handle) return -EINVAL;
    fat32_backend_t *fat = (fat32_backend_t*)backend_data;
    uint32_t cluster; int r = fat32_path_lookup(fat, relpath, &cluster); if (r != 0) return r;
    /* read first directory entry for file to get size; simplified: iterate directory containing last token */
    /* For simplicity, assume regular file and derive size via first directory entry encountered matching name in path lookup loop is not retained; so here return a minimal handle with unknown size (0). */
    struct fat32_file_handle fh = {0}; fh.in_use=1; fh.first_cluster=cluster; fh.size=0; fh.flags=flags;
    for (int i=0;i<fat->max_handles;i++){ if(!fat->handles[i].in_use){ fat->handles[i]=fh; *handle=(void*)(intptr_t)(i+1); return 0; } }
    return -EMFILE;
}

static int fat32_ops_close(void *backend_data, void *handle) {
    if (!backend_data || !handle) return -EINVAL;
    fat32_backend_t *fat = (fat32_backend_t*)backend_data;
    int idx = (int)(intptr_t)handle - 1; if (idx < 0 || idx >= fat->max_handles) return -EBADF;
    fat->handles[idx].in_use = 0; return 0;
}

static ssize_t fat32_ops_read(void *backend_data, void *handle, void *buf, size_t count, off_t offset) {
    if (!backend_data || !handle || !buf) return -EINVAL;
    fat32_backend_t *fat = (fat32_backend_t*)backend_data;
    int idx = (int)(intptr_t)handle - 1; if (idx < 0 || idx >= fat->max_handles) return -EBADF;
    struct fat32_file_handle *fh = &fat->handles[idx]; if (!fh->in_use) return -EBADF;
    size_t read_total = 0; uint8_t *dst = (uint8_t*)buf;
    uint32_t cluster_offset = offset / fat->bytes_per_cluster; uint32_t byte_offset = offset % fat->bytes_per_cluster;
    uint32_t current = fh->first_cluster;
    for (uint32_t i=0;i<cluster_offset && current;i++) current = fat32_get_next_cluster(fat, current);
    while (read_total < count && current) {
        uint8_t *cbuf = (uint8_t*)malloc(fat->bytes_per_cluster); if (!cbuf) return -ENOMEM;
        if (fat32_read_cluster(fat, current, cbuf) != 0) { free(cbuf); break; }
        size_t to_copy = fat->bytes_per_cluster - byte_offset; if (to_copy > count - read_total) to_copy = count - read_total;
        memcpy(dst + read_total, cbuf + byte_offset, to_copy);
        free(cbuf);
        read_total += to_copy; byte_offset = 0;
        if (read_total < count) current = fat32_get_next_cluster(fat, current);
    }
    return (ssize_t)read_total;
}

static int fat32_ops_stat(void *backend_data, const char *relpath, struct stat *st) {
    if (!backend_data || !relpath || !st) return -EINVAL;
    fat32_backend_t *fat = (fat32_backend_t*)backend_data;
    uint32_t cluster; int r = fat32_path_lookup(fat, relpath, &cluster); if (r != 0) return r;
    memset(st, 0, sizeof(*st)); st->st_ino = cluster; st->st_mode = S_IFREG | 0644; st->st_size = 0; /* size unknown in simplified path */
    return 0;
}

static int fat32_ops_readdir(void *backend_data, const char *relpath, void *buf, void *filler) {
    if (!backend_data || !relpath || !buf || !filler) return -EINVAL;
    fat32_backend_t *fat = (fat32_backend_t*)backend_data;
    uint32_t cluster; int r = fat32_path_lookup(fat, relpath, &cluster); if (r != 0) return r;
    typedef int (*fill_fn_t)(void *, const char *, const struct stat *, off_t, int);
    fill_fn_t fill = (fill_fn_t)filler;
    uint32_t current = cluster;
    while (current) {
        uint8_t *cbuf = (uint8_t*)malloc(fat->bytes_per_cluster); if (!cbuf) return -ENOMEM;
        if (fat32_read_cluster(fat, current, cbuf) != 0) { free(cbuf); return -EIO; }
        for (uint32_t off = 0; off + sizeof(struct fat32_dir_entry) <= fat->bytes_per_cluster; off += 32) {
            struct fat32_dir_entry *de = (struct fat32_dir_entry*)(cbuf + off);
            if (de->DIR_Name[0] == 0x00) break;
            if (de->DIR_Name[0] == 0xE5) continue;
            if (de->DIR_Attr == ATTR_LONG_NAME) continue;
            char name[13]; int name_len = 0;
            for (int i=0;i<8 && de->DIR_Name[i] != ' ';i++) name[name_len++] = de->DIR_Name[i];
            if (de->DIR_Name[8] != ' ') { name[name_len++] = '.'; for (int i=8;i<11 && de->DIR_Name[i] != ' ';i++) name[name_len++] = de->DIR_Name[i]; }
            name[name_len] = '\0';
            fill(buf, name, NULL, 0, 0);
        }
        free(cbuf);
        current = fat32_get_next_cluster(fat, current);
    }
    return 0;
}

static ssize_t fat32_ops_write(void *backend_data, void *handle, const void *buf, size_t count, off_t offset) {
    (void)backend_data; (void)handle; (void)buf; (void)count; (void)offset; return -ENOSYS;
}

static const vfs_backend_ops_t fat32_backend_ops = {
    .name = "fat32",
    .init = fat32_ops_init,
    .shutdown = fat32_ops_shutdown,
    .open = fat32_ops_open,
    .close = fat32_ops_close,
    .read = fat32_ops_read,
    .write = fat32_ops_write,
    .stat = fat32_ops_stat,
    .readdir = fat32_ops_readdir,
};

const vfs_backend_ops_t *get_fat32_backend_ops(void) { return &fat32_backend_ops; }
