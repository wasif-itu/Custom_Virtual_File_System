#!/bin/bash
# Test Image Creation Script
# Creates EXT4 and FAT32 filesystem images for backend testing

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;36m'
NC='\033[0m'

print() { echo -e "${BLUE}$1${NC}"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; exit 1; }

# Check prerequisites
command -v dd >/dev/null 2>&1 || error "dd not found"
command -v mkfs.ext4 >/dev/null 2>&1 || error "mkfs.ext4 not found"
command -v mkfs.vfat >/dev/null 2>&1 || error "mkfs.vfat not found"

print "\n========================================
Test Image Creation for CVFS Backends
========================================\n"

# Create EXT4 test image
print "Creating EXT4 test image..."
dd if=/dev/zero of=test_ext4.img bs=1M count=100 2>/dev/null
mkfs.ext4 -F test_ext4.img >/dev/null 2>&1
success "Created test_ext4.img (100MB)"

mkdir -p /tmp/ext4_mount
sudo mount -o loop test_ext4.img /tmp/ext4_mount
echo "Test data from EXT4 backend" | sudo tee /tmp/ext4_mount/test.txt >/dev/null
echo "Hello from EXT4" | sudo tee /tmp/ext4_mount/hello.txt >/dev/null
sudo mkdir -p /tmp/ext4_mount/subdir
echo "Nested file" | sudo tee /tmp/ext4_mount/subdir/nested.txt >/dev/null
sudo umount /tmp/ext4_mount
success "Populated EXT4 image with test files"

# Create FAT32 test image
print "\nCreating FAT32 test image..."
dd if=/dev/zero of=test_fat32.img bs=1M count=100 2>/dev/null
mkfs.vfat -F 32 test_fat32.img >/dev/null 2>&1
success "Created test_fat32.img (100MB)"

mkdir -p /tmp/fat_mount
sudo mount -o loop test_fat32.img /tmp/fat_mount
echo "FAT test data from FAT32 backend" | sudo tee /tmp/fat_mount/test.txt >/dev/null
echo "Hello from FAT32" | sudo tee /tmp/fat_mount/hello.txt >/dev/null
sudo mkdir -p /tmp/fat_mount/subdir
echo "FAT nested file" | sudo tee /tmp/fat_mount/subdir/nested.txt >/dev/null
sudo umount /tmp/fat_mount
success "Populated FAT32 image with test files"

print "\n========================================
Summary
========================================\n"
echo "Test images created successfully:"
ls -lh test_*.img
print "\nThese images can be used with:"
echo "  - EXT4 backend: ./test_ext4.img"
echo "  - FAT32 backend: ./test_fat32.img"
print "\nTo verify backend functionality:"
echo "  wsl bash ./tests/verify_ext4_complete.sh"
echo "  wsl bash ./tests/verify_fat32_complete.sh"
