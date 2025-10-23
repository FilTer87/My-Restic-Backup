# Restic Docker Backup

An automated backup solution for Docker Compose applications using Restic. Supports two backup strategies: traditional stop-backup-restart for complete consistency, or live backups via custom commands (e.g., database dumps) without service interruption. Features flexible secrets management (GPG / Pass / Vaultwarden), comprehensive logging, and automatic repository integrity verification.

## Prerequisites

- `restic` - Backup tool
- `jq` - JSON parser
- `docker` and `docker compose`
- `gpg` - For decrypting secrets
- Root privileges (required for backing up some databases and Docker volumes)

## Configuration

Edit `backup-config.json` with your setup. The script supports two backup modes for each app:

### Mode 1: Stop-Backup-Start
For Docker Compose apps that need to be stopped during backup:

```json
{
  "name": "app-name",
  "path": "/path/to/docker-compose-dir",
  "additional-paths": ["/extra/data/path"],
  "start_cmd": "docker#compose#up#-d",
  "stop_cmd": "docker#compose#down"
}
```

### Mode 2: Command-Based Backup
For backups using custom commands without stopping containers (e.g., database dumps):

```json
{
  "name": "postgres-db",
  "path": "/path/to/backup-storage",
  "bkp_cmd": "docker#exec#container-name#pg_dump#-U#user#dbname#>#dump.sql"
}
```

The `bkp_cmd` will execute inside a temporary `.backup-tmp/` directory within `path`, which is then backed up to Restic and cleaned up automatically.

### Full Configuration Example

```json
{
  "restic-repo": "/path/to/restic-repository",
  "log-path": "/var/log/restic-backups",
  "secrets-method": "gpg", // "gpg | pass | vaultwarden"
  "decr_pwd_file": "/path/to/gpg-passphrase.txt", // it depends on secrets-method used (see the example files)
  "docker-apps": [
    {
      "name": "your-app-1",
      "path": "/pat/to/your-app-1",
      "additional-paths": ["/media/storage/your-app-data"],
      "start_cmd": "docker#compose#up#-d",
      "stop_cmd": "docker#compose#down"
    },
    {
      "name": "database-container",
      "path": "/path/to/database-container",
      "bkp_cmd": "docker#exec#postgres#pg_dump#-U#postgres#mydb#>#database.sql"
    }
  ],
  "additional-backups": [ // array of simple folders to backup
    {
      "name": "my-documents",
      "path": "/path/to/my-documents"
    },
    {
      "name": "logs",
      "path": "/var/log/important-logs"
    }
  ]
}
```

**Note**: Use `#` instead of spaces in commands (e.g., `docker#compose#up#-d`) due to jq parsing limitations.

## How It Works

This is intended for each defined `docker-app`:

### Stop-Backup-Start Mode
1. Stops Docker Compose application (300s timeout)
2. Backs up the application directory and additional paths to Restic repository
3. Restarts the application

### Command-Based Backup Mode
1. Creates temporary `.backup-tmp/` directory in the specified path
2. Executes the custom backup command inside this directory
3. Backs up the temporary directory to Restic repository
4. Cleans up the temporary directory

### Final Steps (both modes)
- Processes additional backup paths (just basic folders backup with restic)
- Verifies Restic repository integrity
- Shows retention policy preview (keeps weekly backups for 15 days, monthly for 3 months)

Logs are written to `{log-path}/Backup-YYYY_MM_DD.log`.

## Usage

Copy one of the configuration example file, rename it as `backup-config.json` and update it to match your environment, as explained in the previous section. Then run the script or use it in cron jobs.
Here's an example of basic usage:

```bash
# Use default config path (/root/.config/restic-backup/backup-config.json)
sudo ./backups.sh

# Use custom config file
sudo ./backups.sh /path/to/backup-config.json
```

## Secrets Management

The script supports **three methods** for managing the Restic password and other secrets, in order to be executed without human input (e.g. crontab):

### Method 1: GPG

Uses GPG-encrypted files for storing secrets.

**Configuration:**
```json
{
  "secrets-method": "gpg",
  "decr_pwd_file": "/path/to/gpg-passphrase.txt"
}
```

**Setup:**
```bash
# Create encrypted secrets file
echo "RESTIC_LOCAL_PWD=your-restic-password" | gpg -e -r your@email.com > /home/user/.secrets

# Set proper permissions
chmod 600 /home/user/.secrets
chmod 600 /path/to/gpg-passphrase.txt

# Optional: use custom secrets file location
export SECRETS_FILE=/path/to/custom/secrets
```

### Method 2: Pass

Uses `pass` (passwordstore.org) - a simple, Unix-philosophy password manager based on GPG.

**Configuration:**
```json
{
  "secrets-method": "pass",
  "pass-entry": "infra/restic/local"
}
```

**Setup:**
```bash
# Install pass
sudo apt install pass

# Initialize with your GPG key
pass init your-gpg-key-id

# Store the Restic password
pass insert infra/restic/local
# Enter your password when prompted

# Optional: setup git sync for backup
pass git init
pass git remote add origin git@yourserver:pass-infra.git
pass git push
```

**Advantages:**
- ✅ No separate passphrase files needed
- ✅ Easy to manage multiple secrets
- ✅ Optional git backup/sync
- ✅ Separation from personal passwords (use different pass store for infra)

### Method 3: Vaultwarden/Bitwarden

Uses Bitwarden CLI to retrieve secrets from your Vaultwarden instance.

**Configuration:**
```json
{
  "secrets-method": "vaultwarden",
  "vaultwarden-item": "Restic Backup Password",
  "vaultwarden-session-file": "/root/.bw-session"
}
```

**Setup:**
```bash
# Install Bitwarden CLI
npm install -g @bitwarden/cli

# Configure server (for self-hosted Vaultwarden)
bw config server https://your-vaultwarden.com

# Login and save session
bw login your@email.com
bw unlock --raw > /root/.bw-session
chmod 600 /root/.bw-session

# Create item in Vaultwarden UI or CLI
# Store password as "Secure Note" or "Login" item
```

---

### Security Notes:
All methods validate file permissions and existence on startup. The script will warn if permissions are not secure (`600` or `400`).

If you are already using Pass or Vaultwarden/Bitwarden for your personal accounts, consider using a separate instance or a dedicated account for infrastructure secrets to limit blast radius in case of compromise.