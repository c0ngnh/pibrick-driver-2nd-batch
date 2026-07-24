#!/bin/bash
#
# build-module.sh - Build the MMA8451Q kernel module
#
# This script builds the custom kernel module for piBrick's MMA8451Q accelerometer.
# It handles kernel header installation if needed and provides clear error messages.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MODULE_NAME="mma8451q"
KVER="$(uname -r)"
KVER_DIR="/lib/modules/${KVER}"
BUILD_DIR="${KVER_DIR}/build"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }

# Check if running as root
if [ "$(id -u)" != "0" ]; then
    log_error "This script must be run as root (use sudo)"
    exit 1
fi

log_info "Building ${MODULE_NAME} kernel module for kernel ${KVER}"

# Check for kernel headers
check_kernel_headers() {
    log_info "Checking for kernel headers..."

    if [ ! -d "$BUILD_DIR" ]; then
        log_warn "Kernel headers not found at ${BUILD_DIR}"
        log_info "Installing kernel headers..."
        
        if command -v apt-get >/dev/null 2>&1; then
            local headers_package="linux-headers-${KVER}"
            log_info "Installing: ${headers_package}"
            apt-get update && apt-get install -y "${headers_package}" || {
                log_error "Failed to install kernel headers"
                log_info "Try: sudo apt install linux-headers-rpi-v8  (for 64-bit)"
                log_info "Or:   sudo apt install linux-headers-armv7l  (for 32-bit)"
                exit 1
            }
        else
            log_error "Unknown package manager. Please install kernel headers manually."
            exit 1
        fi
    fi

    if [ ! -f "${BUILD_DIR}/Makefile" ]; then
        log_error "Invalid kernel headers (no Makefile found)"
        exit 1
    fi

    log_info "Kernel headers found at ${BUILD_DIR}"
}

# Build the module
build_module() {
    log_info "Building module..."

    cd "$SCRIPT_DIR"

    # Clean any previous build
    make clean 2>/dev/null || true

    # Build
    if make -C "$BUILD_DIR" M="$(pwd)" modules 2>&1; then
        log_info "Module built successfully"
        
        if [ -f "${MODULE_NAME}.ko" ]; then
            log_info "Module: ${MODULE_NAME}.ko"
            modinfo "${MODULE_NAME}.ko" || true
        else
            log_error "Module file not created"
            exit 1
        fi
    else
        log_error "Build failed"
        exit 1
    fi
}

# Install the module
install_module() {
    log_info "Installing module..."

    # Create module directory if needed
    mkdir -p "${KVER_DIR}/extra"

    # Copy module
    cp "${MODULE_NAME}.ko" "${KVER_DIR}/extra/"

    # Update module dependencies
    depmod -a

    log_info "Module installed to ${KVER_DIR}/extra/${MODULE_NAME}.ko"

    # Load the module
    log_info "Loading module..."
    if modprobe -v "${MODULE_NAME}" 2>&1; then
        log_info "Module loaded successfully"
        
        # Check if device appeared
        if [ -d "/sys/bus/iio/devices/iio:device0" ] || \
           ls /sys/bus/iio/devices/ 2>/dev/null | grep -q mma; then
            log_info "IIO device created:"
            for dev in /sys/bus/iio/devices/iio:device*; do
                [ -f "$dev/name" ] && echo "  - $dev: $(cat "$dev/name")"
            done
        fi
    else
        log_warn "Module may not have loaded - check dmesg"
    fi
}

# Main
main() {
    check_kernel_headers
    build_module
    
    if [ "${1:-}" = "--install" ]; then
        install_module
    fi
}

main "$@"
