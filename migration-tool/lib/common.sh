export SPLASH_SUBTITLE_FONT_SIZE=24
export SPLASH_SUBTITLE_TEXT_ALIGN="center"

# Omarchy migration tool environment variables with defaults
: "${OM_LOG:=/tmp/omarchy-migrate.log}"
: "${OM_ROOT:=}"
: "${OM_RUN_DIR:=/run/omarchy-migrate}"
: "${OM_SRC_ESP_MNT:=/boot/efi}"
: "${OM_STATE_MNT:=/tmp/state-esp}"
: "${OM_TGT_MNT:=/mnt/target-root}"
: "${OM_TGT_TOP:=/mnt/target-top}"

# Runtime helper function stubs for development/testing from source
# These would normally be provided by Omarchy's deployment infrastructure

# Get current timestamp in ISO 8601 format (nanoseconds since epoch)
om_now() {
    date -Iseconds -u
}

# Generate a unique run identifier (UUID)
om_uuid() {
    uuidgen -r
}

# Generate a fingerprint based on system state
om_fingerprint() {
    # Simple fingerprint for development - in production this would be more comprehensive
    local kernel host os release
    kernel="$(uname -r)"
    host="$(hostname 2>/dev/null || echo 'unknown')"
    os="$(uname -s)"
    release="$(grep -oP '^VERSION="[^"]*"' /etc/os-release 2>/dev/null | cut -d'=' -f2 || echo 'unknown')"
    printf '%s:%s:%s:%s' "$kernel" "$host" "$os" "$release"
}

# Re-execute the current script with a new root directory (for elevated operations)
om_reexec_root() {
    # For development/testing from source without actual sudo support
    echo "Error: This command requires root privileges. Please run as root." >&2
    exit 1
}

# Initialize runtime environment (sets up paths, mounts, etc.)
om_init_runtime() {
    : # Stub for development - in production this would set up actual runtime state
}

# Omarchy migration tool version
: "${OM_VERSION:=0.1.0}"
