#ifndef BACKEND_EXT4_H
#define BACKEND_EXT4_H

#include <stdint.h>
#include <sys/stat.h>

/* Minimal public API for EXT4 backend integration */
struct vfs_backend_ops;

/* Getter to register with VFS */
const struct vfs_backend_ops *get_ext4_backend_ops(void);

#endif /* BACKEND_EXT4_H */
