/*
 * EXT4 Backend Unit Test
 * Direct testing of ext4 backend functionality
 * Date: December 1, 2025
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <errno.h>

/* Forward declare backend structure */
typedef struct vfs_backend_ops vfs_backend_ops_t;

/* Include backend header */
extern const vfs_backend_ops_t *get_ext4_backend_ops(void);

typedef struct vfs_backend_ops {
    const char *name;
    int (*init)(const char *device_path, void **backend_data);
    int (*shutdown)(void *backend_data);
    int (*open)(void *backend_data, const char *relpath, int flags, void **handle);
    int (*close)(void *backend_data, void *handle);
    ssize_t (*read)(void *backend_data, void *handle, void *buf, size_t count, off_t offset);
    ssize_t (*write)(void *backend_data, void *handle, const void *buf, size_t count, off_t offset);
    int (*stat)(void *backend_data, const char *relpath, struct stat *st);
    int (*readdir)(void *backend_data, const char *relpath, void *buf, void *filler);
} vfs_backend_ops_t;

/* Test counters */
static int tests_run = 0;
static int tests_passed = 0;
static int tests_failed = 0;

#define TEST_START(name) do { \
    tests_run++; \
    printf("Test %d: %s ... ", tests_run, name); \
    fflush(stdout); \
} while(0)

#define TEST_PASS() do { \
    printf("\033[0;32m✅ PASS\033[0m\n"); \
    tests_passed++; \
} while(0)

#define TEST_FAIL(msg) do { \
    printf("\033[0;31m❌ FAIL\033[0m: %s\n", msg); \
    tests_failed++; \
} while(0)

/* Create a minimal ext4 test image */
static int create_test_image(const char *path) {
    char cmd[512];
    
    /* Create 10MB image */
    snprintf(cmd, sizeof(cmd), "dd if=/dev/zero of=%s bs=1M count=10 2>/dev/null", path);
    if (system(cmd) != 0) return -1;
    
    /* Format as ext4 */
    snprintf(cmd, sizeof(cmd), "mkfs.ext4 -F -q %s", path);
    if (system(cmd) != 0) return -1;
    
    /* Mount and create test files */
    const char *mnt = "/tmp/ext4_unit_mnt";
    snprintf(cmd, sizeof(cmd), "mkdir -p %s && sudo mount -o loop %s %s", mnt, path, mnt);
    if (system(cmd) != 0) return -1;
    
    /* Create test files */
    snprintf(cmd, sizeof(cmd), "echo 'Test content' | sudo tee %s/testfile.txt > /dev/null", mnt);
    system(cmd);
    
    snprintf(cmd, sizeof(cmd), "sudo mkdir -p %s/testdir", mnt);
    system(cmd);
    
    snprintf(cmd, sizeof(cmd), "dd if=/dev/urandom of=%s/binary.dat bs=1K count=5 2>/dev/null", mnt);
    system(cmd);
    
    /* Unmount */
    snprintf(cmd, sizeof(cmd), "sudo umount %s", mnt);
    system(cmd);
    
    return 0;
}

int main(int argc, char **argv) {
    const char *test_image = "/tmp/ext4_unit_test.img";
    void *backend_data = NULL;
    const vfs_backend_ops_t *ops = NULL;
    
    printf("========================================\n");
    printf("  EXT4 BACKEND UNIT TEST\n");
    printf("========================================\n\n");
    
    /* Phase 1: Backend Operations Structure */
    printf("Phase 1: Backend Operations Structure\n");
    printf("--------------------------------------\n");
    
    TEST_START("Get EXT4 backend ops");
    ops = get_ext4_backend_ops();
    if (ops != NULL) {
        TEST_PASS();
    } else {
        TEST_FAIL("get_ext4_backend_ops() returned NULL");
        goto cleanup;
    }
    
    TEST_START("Backend name is 'ext4'");
    if (ops->name && strcmp(ops->name, "ext4") == 0) {
        TEST_PASS();
    } else {
        TEST_FAIL("Backend name incorrect or missing");
    }
    
    TEST_START("All operation pointers non-NULL");
    if (ops->init && ops->shutdown && ops->open && ops->close &&
        ops->read && ops->write && ops->stat && ops->readdir) {
        TEST_PASS();
    } else {
        TEST_FAIL("Some operation pointers are NULL");
    }
    
    /* Phase 2: Test Image Creation */
    printf("\nPhase 2: Test Image Preparation\n");
    printf("--------------------------------\n");
    
    TEST_START("Create ext4 test image");
    if (create_test_image(test_image) == 0) {
        TEST_PASS();
    } else {
        TEST_FAIL("Failed to create test image");
        goto cleanup;
    }
    
    /* Phase 3: Backend Initialization */
    printf("\nPhase 3: Backend Initialization\n");
    printf("--------------------------------\n");
    
    TEST_START("Initialize backend with test image");
    int ret = ops->init(test_image, &backend_data);
    if (ret == 0 && backend_data != NULL) {
        TEST_PASS();
    } else {
        TEST_FAIL("init() failed or returned NULL backend_data");
        goto cleanup;
    }
    
    TEST_START("Initialize with NULL path fails");
    void *dummy = NULL;
    ret = ops->init(NULL, &dummy);
    if (ret < 0) {
        TEST_PASS();
    } else {
        TEST_FAIL("init() should reject NULL path");
    }
    
    TEST_START("Initialize with nonexistent file fails");
    ret = ops->init("/nonexistent/path/file.img", &dummy);
    if (ret < 0) {
        TEST_PASS();
    } else {
        TEST_FAIL("init() should fail on nonexistent file");
    }
    
    /* Phase 4: Stat Operations */
    printf("\nPhase 4: Stat Operations\n");
    printf("------------------------\n");
    
    TEST_START("Stat root directory");
    struct stat st;
    memset(&st, 0, sizeof(st));
    ret = ops->stat(backend_data, "", &st);
    if (ret == 0 && S_ISDIR(st.st_mode)) {
        TEST_PASS();
    } else {
        TEST_FAIL("Root stat failed or not a directory");
    }
    
    TEST_START("Root inode number is 2");
    if (st.st_ino == 2) {
        TEST_PASS();
    } else {
        TEST_FAIL("Root inode is not 2 (EXT4_ROOT_INO)");
    }
    
    TEST_START("Stat existing file");
    memset(&st, 0, sizeof(st));
    ret = ops->stat(backend_data, "testfile.txt", &st);
    if (ret == 0 && S_ISREG(st.st_mode)) {
        TEST_PASS();
    } else {
        TEST_FAIL("File stat failed or not a regular file");
    }
    
    TEST_START("File size is reasonable");
    if (st.st_size > 0 && st.st_size < 1000) {
        TEST_PASS();
    } else {
        TEST_FAIL("File size unreasonable");
    }
    
    TEST_START("Stat nonexistent file returns ENOENT");
    ret = ops->stat(backend_data, "nonexistent.txt", &st);
    if (ret == -ENOENT) {
        TEST_PASS();
    } else {
        TEST_FAIL("Should return -ENOENT for missing file");
    }
    
    TEST_START("Stat with NULL backend fails");
    ret = ops->stat(NULL, "testfile.txt", &st);
    if (ret < 0) {
        TEST_PASS();
    } else {
        TEST_FAIL("Should fail with NULL backend");
    }
    
    /* Phase 5: Directory Operations */
    printf("\nPhase 5: Directory Operations\n");
    printf("------------------------------\n");
    
    /* Simple readdir test - just check it doesn't crash */
    TEST_START("Readdir on root doesn't crash");
    ret = ops->readdir(backend_data, "", NULL, NULL);
    /* We expect it to fail with NULL filler, but shouldn't crash */
    TEST_PASS();
    
    TEST_START("Readdir with NULL backend fails");
    ret = ops->readdir(NULL, "", NULL, NULL);
    if (ret < 0) {
        TEST_PASS();
    } else {
        TEST_FAIL("Should fail with NULL backend");
    }
    
    /* Phase 6: File Operations */
    printf("\nPhase 6: File Operations\n");
    printf("------------------------\n");
    
    TEST_START("Open existing file for reading");
    void *file_handle = NULL;
    ret = ops->open(backend_data, "testfile.txt", O_RDONLY, &file_handle);
    if (ret == 0 && file_handle != NULL) {
        TEST_PASS();
    } else {
        TEST_FAIL("Failed to open testfile.txt");
        goto phase7;
    }
    
    TEST_START("Read from opened file");
    char buf[256];
    memset(buf, 0, sizeof(buf));
    ssize_t bytes = ops->read(backend_data, file_handle, buf, sizeof(buf) - 1, 0);
    if (bytes > 0) {
        TEST_PASS();
    } else {
        TEST_FAIL("Read returned zero or error");
    }
    
    TEST_START("Read content is correct");
    if (bytes > 0 && strstr(buf, "Test") != NULL) {
        TEST_PASS();
    } else {
        TEST_FAIL("Read content doesn't match expected");
    }
    
    TEST_START("Read with offset works");
    char buf2[256];
    memset(buf2, 0, sizeof(buf2));
    bytes = ops->read(backend_data, file_handle, buf2, 4, 5);
    if (bytes > 0) {
        TEST_PASS();
    } else {
        TEST_FAIL("Offset read failed");
    }
    
    TEST_START("Close file handle");
    ret = ops->close(backend_data, file_handle);
    if (ret == 0) {
        TEST_PASS();
    } else {
        TEST_FAIL("Close failed");
    }
    
    phase7:
    TEST_START("Open nonexistent file fails");
    ret = ops->open(backend_data, "nonexistent.txt", O_RDONLY, &file_handle);
    if (ret < 0) {
        TEST_PASS();
    } else {
        TEST_FAIL("Should fail to open nonexistent file");
        if (file_handle) ops->close(backend_data, file_handle);
    }
    
    TEST_START("Open with write flags rejected");
    ret = ops->open(backend_data, "testfile.txt", O_WRONLY, &file_handle);
    if (ret == -EACCES) {
        TEST_PASS();
    } else {
        TEST_FAIL("Should reject write access (read-only backend)");
        if (ret == 0 && file_handle) ops->close(backend_data, file_handle);
    }
    
    TEST_START("Open directory as file fails");
    ret = ops->open(backend_data, "testdir", O_RDONLY, &file_handle);
    if (ret < 0) {
        TEST_PASS();
    } else {
        TEST_FAIL("Should fail to open directory as file");
        if (file_handle) ops->close(backend_data, file_handle);
    }
    
    /* Phase 7: Write Protection */
    printf("\nPhase 7: Write Protection\n");
    printf("-------------------------\n");
    
    TEST_START("Write operation returns ENOSYS");
    ret = (int)ops->write(backend_data, NULL, "test", 4, 0);
    if (ret == -ENOSYS) {
        TEST_PASS();
    } else {
        TEST_FAIL("Write should return -ENOSYS (read-only)");
    }
    
    /* Phase 8: Cleanup */
    printf("\nPhase 8: Backend Shutdown\n");
    printf("-------------------------\n");
    
    TEST_START("Shutdown backend");
    ret = ops->shutdown(backend_data);
    if (ret == 0) {
        TEST_PASS();
    } else {
        TEST_FAIL("Shutdown failed");
    }
    
    TEST_START("Shutdown with NULL backend fails");
    ret = ops->shutdown(NULL);
    if (ret < 0) {
        TEST_PASS();
    } else {
        TEST_FAIL("Should fail with NULL backend");
    }
    
cleanup:
    /* Cleanup test image */
    unlink(test_image);
    
    /* Print Summary */
    printf("\n========================================\n");
    printf("  TEST SUMMARY\n");
    printf("========================================\n");
    printf("Total Tests:  %d\n", tests_run);
    printf("Passed:       \033[0;32m%d\033[0m\n", tests_passed);
    printf("Failed:       \033[0;31m%d\033[0m\n", tests_failed);
    
    if (tests_failed == 0) {
        printf("\n\033[0;32m✅ ALL TESTS PASSED\033[0m\n");
        printf("\nEXT4 Backend Implementation: VERIFIED ✅\n\n");
        return 0;
    } else {
        printf("\n\033[0;31m❌ SOME TESTS FAILED\033[0m\n");
        printf("\nEXT4 Backend Implementation: INCOMPLETE\n\n");
        return 1;
    }
}
