## Migration Tool Progress Tracker

### 1. Boot Order Persistence
- **Status:** ✅ Confirmed migration tool does not alter boot order unless explicitly requested (configurable in `detect.sh`)
- **Next:** Add explicit user confirmation prompt for boot order changes

### 2. Splash Screen Styling
- **Status:** ⚠️ Subtitle alignment/size fix partially implemented but failed due to string matching issues in `ui.sh`
- **Action Required:**
  ```bash
  # Corrected edit command (whitespace/escape characters fixed)
  edit(
    path="/home/cyryl/Projects/omarchy/migration-tool/lib/ui.sh",
    oldString="printf '  %s\\n' "\n$_c "$UI_MUTED" "$subtitle")"
    newString="printf '\033[24m  %s\033[0m\\n' "\n$_c "$UI_MUTED" "$subtitle")"
    replaceAll=false
  )
  ```

### 3. Theme Consistency (OMARCHY Logo Color)
- **Status:** ✅ Green color (`#008000`) implemented in `common.sh` via theme variable
- **Remaining Work:**
  - Audit all logo instances in `ui.sh`, `detect.sh`, and `state.sh`
  - Add fallback logic for non-color-support terminals

### 4. Timezone Auto-Copy
- **Status:** ⚠️ Partially implemented in `detect.sh` (needs validation)
- **Verification Required:**
  ```bash
  # Test command to validate timezone auto-copy
  grep -A 5 'timezone_auto_copy()' /home/cyryl/Projects/omarchy/migration-tool/lib/detect.sh
  ```

### 5. Btrfs Mount Error Handling
- **Status:** ⚠️ Critical issue: `mkdir: cannot create directory` during source Btrfs mount
- **Action Required:**
  - Add encrypted partition detection in `state.sh`
  - Implement fallback directory creation logic
  - Add verbose logging for mount failures

### 6. Reboot Command Reliability
- **Status:** ⚠️ `reboot` command failed in root shell (needs investigation)
- **Action Required:**
  ```bash
  # Test reboot command with logging
  echo "systemctl reboot -i" > /home/cyryl/Projects/omarchy/migration-tool/lib/migrate.sh.tmp && mv /home/cyryl/Projects/omarchy/migration-tool/lib/migrate.sh.tmp /home/cyryl/Projects/omarchy/migration-tool/lib/migrate.sh
  ```

### 7. Log Accessibility
- **Status:** ✅ Logs now saved to `/var/log/omarchy-migrate.log`
- **Verification Required:**
  ```bash
  # Test log accessibility
  tail -n 20 /var/log/omarchy-migrate.log | grep 'ERROR'
  ```