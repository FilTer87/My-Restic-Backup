#!/bin/bash

set -e

echo "I start from here: $(pwd)"

# disable history (just for prevention)
set +o history

# Source configuration file
if [ -z "$1" ]; then
    # Unfortunately '~/' path is causing many issues, so we use absolute path instead.
    # also, root user is needed in order to backups some databases and other data :/ so..
    CONFIG_FILE=/root/.config/restic-backup/backup-config.json # <-- this is the default path for lab-01.k.net
    # CONFIG_FILE=/home/filter/Projects/personal/scripts/backup-docker-apps/backup-config.json # <-- uncomment this for local check
else
    CONFIG_FILE=$1
fi

# Extract paths and repository from JSON configuration
LOG_PATH=$(jq -r '.["log-path"]' "$CONFIG_FILE")
RESTIC_REPO=$(jq -r '.["restic-repo"]' "$CONFIG_FILE")

# Secrets management method (gpg, pass, or vaultwarden)
SECRETS_METHOD=$(jq -r '.["secrets-method"] // "gpg"' "$CONFIG_FILE")

echo "Using secrets method: $SECRETS_METHOD"

# Validate and setup based on secrets method
case "$SECRETS_METHOD" in
    "gpg")
        DECR_PWD_FILE=$(jq -r '.["decr_pwd_file"]' "$CONFIG_FILE")
        SECRETS_FILE="${SECRETS_FILE:-/home/filter/.secrets}"

        # Security checks for GPG method
        if [ ! -f "$SECRETS_FILE" ]; then
            echo "ERROR: Secrets file not found: $SECRETS_FILE" >&2
            exit 1
        fi

        secrets_perms=$(stat -c %a "$SECRETS_FILE" 2>/dev/null || stat -f %A "$SECRETS_FILE" 2>/dev/null)
        if [ "$secrets_perms" != "600" ] && [ "$secrets_perms" != "400" ]; then
            echo "WARNING: $SECRETS_FILE has permissions $secrets_perms (should be 600 or 400)" >&2
            echo "Run: chmod 600 $SECRETS_FILE" >&2
        fi

        if [ ! -f "$DECR_PWD_FILE" ]; then
            echo "ERROR: GPG passphrase file not found: $DECR_PWD_FILE" >&2
            exit 1
        fi

        decr_perms=$(stat -c %a "$DECR_PWD_FILE" 2>/dev/null || stat -f %A "$DECR_PWD_FILE" 2>/dev/null)
        if [ "$decr_perms" != "600" ] && [ "$decr_perms" != "400" ]; then
            echo "WARNING: $DECR_PWD_FILE has permissions $decr_perms (should be 600 or 400)" >&2
            echo "Run: chmod 600 $DECR_PWD_FILE" >&2
        fi
        ;;

    "pass")
        PASS_ENTRY=$(jq -r '.["pass-entry"] // "infra/restic/local"' "$CONFIG_FILE")

        # Check if pass is installed
        if ! command -v pass &> /dev/null; then
            echo "ERROR: 'pass' command not found. Install it with: apt install pass" >&2
            exit 1
        fi

        # Check if pass store is initialized
        if [ ! -d "$HOME/.password-store" ] && [ ! -d "${PASSWORD_STORE_DIR:-$HOME/.password-store}" ]; then
            echo "ERROR: pass store not initialized. Run: pass init <gpg-key-id>" >&2
            exit 1
        fi

        # Verify the entry exists
        if ! pass show "$PASS_ENTRY" &> /dev/null; then
            echo "ERROR: pass entry '$PASS_ENTRY' not found" >&2
            echo "Create it with: pass insert $PASS_ENTRY" >&2
            exit 1
        fi
        ;;

    "vaultwarden")
        VW_ITEM=$(jq -r '.["vaultwarden-item"] // "Restic Backup Password"' "$CONFIG_FILE")
        VW_SESSION_FILE=$(jq -r '.["vaultwarden-session-file"] // "$HOME/.bw-session"' "$CONFIG_FILE")

        # Check if bw is installed
        if ! command -v bw &> /dev/null; then
            echo "ERROR: 'bw' (Bitwarden CLI) not found. Install it with: npm install -g @bitwarden/cli" >&2
            exit 1
        fi

        # Check session
        if [ -z "$BW_SESSION" ]; then
            if [ -f "$VW_SESSION_FILE" ]; then
                BW_SESSION=$(cat "$VW_SESSION_FILE")
            else
                echo "ERROR: BW_SESSION not found. Run: bw unlock --raw > $VW_SESSION_FILE" >&2
                exit 1
            fi
        fi
        ;;

    *)
        echo "ERROR: Unknown secrets method '$SECRETS_METHOD'. Supported: gpg, pass, vaultwarden" >&2
        exit 1
        ;;
esac

echo "$(date '+%Y_%m_%d %H:%M:%S') BACKUP INIT" > "$LOG_PATH/Backup-$(date '+%Y_%m_%d').log"

# Function to log output and errors
log_output() {
    echo "$(date '+%Y_%m_%d %H:%M:%S') $*" >> "$LOG_PATH/Backup-$(date '+%Y_%m_%d').log"
}

create_backup() {
    local backup_name=$1
    local backup_path=$2
    echo "Creating backup of $backup_name (pwd: $(pwd), bak-path: $backup_path)..."
    log_output "Creating backup of $backup_name (pwd: $pwd, $backup_path)..."

    # restic -r "$RESTIC_REPO" backup "$backup_path" --tag "$backup_name" --exclude-file=.backupignore --verbose=2 --dry-run || {
    restic -r "$RESTIC_REPO" backup "$backup_path" --tag "$backup_name" --verbose=2 || {
        log_output "Error creating backup of $backup_name."
        echo "Backup failed: Error creating backup of $backup_name. See $LOG_PATH/Backup-$(date '+%Y_%m_%d').log for details." >&2
        err=1
    }
    sleep 0.4
}

# Function to perform backup using a custom command (without stopping containers)
backup_app_with_command() {
    local app_name=$1
    local app_path=$2
    local bkp_cmd=$3

    cd "$app_path" || exit 1
    echo -e "\npwd: $(pwd)"

    err=0
    local tmp_dir=".backup-tmp"

    # Create temporary directory for backup files
    echo "Creating temporary backup directory: $tmp_dir"
    log_output "Creating temporary backup directory for $app_name: $tmp_dir"
    mkdir -p "$tmp_dir" || {
        log_output "Error creating temporary directory for $app_name."
        echo "Backup failed: Error creating temporary directory. See $LOG_PATH/Backup-$(date '+%Y_%m_%d').log for details." >&2
        return 1
    }

    # Execute custom backup command
    echo "Executing backup command for $app_name..."
    log_output "Executing backup command for $app_name: $bkp_cmd"

    cd "$tmp_dir" || exit 1
    eval ${bkp_cmd} || {
        log_output "Error executing backup command for $app_name."
        echo "Backup failed: Error executing backup command for $app_name. See $LOG_PATH/Backup-$(date '+%Y_%m_%d').log for details." >&2
        cd ..
        rm -rf "$tmp_dir"
        return 1
    }
    cd ..

    # Backup the temporary directory with restic
    create_backup "$app_name" "$app_path/$tmp_dir"

    # Clean up temporary directory
    echo "Cleaning up temporary backup directory..."
    log_output "Cleaning up temporary backup directory for $app_name"
    rm -rf "$tmp_dir" || {
        log_output "Warning: Could not remove temporary directory for $app_name."
    }
}

# Function to perform backup of a single application path
backup_app_path() {
    local app_name=$1
    local app_path=$2
    local additional_paths=$3
    local start_cmd=$4
    local stop_cmd=$5

    cd "$app_path" || exit 1
    echo -e "\npwd: $(pwd)"

    err=0

    # Stop Docker containers and wait for them to stop
    echo "Stopping containers for $app_name..."
    log_output "Stopping containers for $app_name..."

    ${stop_cmd} --timeout 300 || {
        log_output "Error stopping containers for $app_name."
        echo "Backup failed: Error stopping containers for $app_name. See $LOG_PATH/$error_log for details." >&2
        err=1
    }

    # Backup main app folder
    create_backup "$app_name" "$app_path"
    # create_backup . "$app_path"

    if [ "$err" -eq 0 ]; then
        # Backup application paths
        # local backup_success=true
        for path in $(echo "$additional_paths" | jq -r '.[]'); do
            echo "- add-path: $path .."

            create_backup "$app_name" "$path"
        done
    fi

    # if [ "$backup_success" = true ]; then
    if [ "$err" -eq 0 ]; then
        # Start Docker containers
        echo "Starting containers for $app_name..."
        log_output "Starting containers for $app_name..."

        ${start_cmd} --timeout 300 || {
            log_output "Error starting containers for $app_name."
            echo "Backup failed: Error starting containers for $app_name. See $(pwd)/$LOG_PATH/$error_log for details." >&2
        }
    fi
}

# Load configuration from JSON file
docker_apps=$(jq '.["docker-apps"]' "$CONFIG_FILE")
echo -e "\n\ndocker_apps:\n"
echo "$docker_apps"
additional_backups=$(jq '.["additional-backups"]' "$CONFIG_FILE")

# Retrieve Restic password based on secrets method
case "$SECRETS_METHOD" in
    "gpg")
        echo "Retrieving Restic password from GPG-encrypted file..."
        log_output "Retrieving Restic password using GPG method"
        eval "$(gpg --batch --passphrase-file $DECR_PWD_FILE --decrypt $SECRETS_FILE | grep '^RESTIC_LOCAL_PWD=')"
        export RESTIC_PASSWORD=$RESTIC_LOCAL_PWD
        ;;

    "pass")
        echo "Retrieving Restic password from pass..."
        log_output "Retrieving Restic password from pass entry: $PASS_ENTRY"
        export RESTIC_PASSWORD=$(pass show "$PASS_ENTRY")
        ;;

    "vaultwarden")
        echo "Retrieving Restic password from Vaultwarden..."
        log_output "Retrieving Restic password from Vaultwarden item: $VW_ITEM"
        export RESTIC_PASSWORD=$(bw get notes "$VW_ITEM" --session "$BW_SESSION" 2>/dev/null || bw get password "$VW_ITEM" --session "$BW_SESSION")
        ;;
esac

# Verify password was retrieved
if [ -z "$RESTIC_PASSWORD" ]; then
    echo "ERROR: Failed to retrieve Restic password using method: $SECRETS_METHOD" >&2
    log_output "ERROR: Failed to retrieve Restic password"
    exit 1
fi

log_output "Restic password retrieved successfully"

# Create log directories if they do not exist
mkdir -p "$LOG_PATH"

# Process docker apps
for app in $(echo "$docker_apps" | jq -rc '.[]'); do

    # no way to prevent jq to replace newlines with spaces;
    # '#' must be provided in the JSON file to prevent this issue instead of spacecs in strings
    app=$(echo "${app//#/ }")
    echo "$app"

    # echo "$app" >> "$LOG_PATH/check_jq.json"
    echo -ne "\napp:"
    app_name=$(echo "$app" | jq -r '.name')
    echo -ne "\n  - name: $app_name"
    app_path=$(echo "$app" | jq -r '.path')
    echo -ne "\n  - path: $app_path"

    # Check if this app uses bkp_cmd mode or stop/start mode
    bkp_cmd=$(echo "$app" | jq -r '.["bkp_cmd"]')

    if [ "$bkp_cmd" != "null" ] && [ -n "$bkp_cmd" ]; then
        # Mode: backup with custom command (no container stop/start)
        echo -ne "\n  - mode: bkp_cmd"
        echo -ne "\n  - bkp_cmd: $bkp_cmd"

        backup_app_with_command "$app_name" "$app_path" "$bkp_cmd"
    else
        # Mode: traditional stop-backup-start
        echo -ne "\n  - mode: stop-backup-start"

        start_cmd=$(echo "$app" | jq -r '.["start_cmd"]')
        if [ -z "$start_cmd" ] || [ "$start_cmd" = "null" ]; then
            start_cmd="docker compose up -d"
        fi
        echo -ne "\n  - start_cmd: $start_cmd"

        stop_cmd=$(echo "$app" | jq -r '.["stop_cmd"]')
        if [ -z "$stop_cmd" ] || [ "$stop_cmd" = "null" ]; then
            stop_cmd="docker compose down"
        fi
        echo -ne "\n  - stop_cmd: $stop_cmd"

        additional_paths=$(echo "$app" | jq '.["additional-paths"]')
        echo -ne "\n  - additional-paths: $additional_paths"

        backup_app_path "$app_name" "$app_path" "$additional_paths" "$start_cmd" "$stop_cmd"
    fi
done

# Process additional backups
for backup in $(echo "$additional_backups" | jq -c '.[]'); do
    backup_name=$(echo "$backup" | jq -r '.name')
    backup_path=$(echo "$backup" | jq -r '.path')

    echo -e "\n\nAdditonal Backup:"
    echo -e " - Name: $backup_name"
    echo -e " - Path: $backup_path\n"

    create_backup "$backup_name" "$backup_path"
done

# Check restic repository integrity
echo "Checking restic repository integrity..."
log_output "Checking restic repository integrity..."

# shellcheck disable=SC2015
restic -r "$RESTIC_REPO" check && log_output "Restic repository is healthy." || {
    error_log="ERR-$(date '+%Y_%m_%d').log"
    log_output "Error checking restic repository."
    echo "Backup failed: Error checking restic repository. See $(pwd)/$LOG_PATH/$error_log for details." >&2
    exit 1
}

restic -r "$RESTIC_REPO" forget --keep-within-weekly 15d --keep-within-monthly 3m --dry-run

# re-enable history
set -o history
