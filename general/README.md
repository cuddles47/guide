# PostgreSQL incremental backup

## Setup

1. Create a dedicated backup role on the cluster primary:

   ```sql
   CREATE ROLE backup WITH LOGIN REPLICATION PASSWORD 'longasspass4723xyzzzbigtitties';
   GRANT CONNECT ON DATABASE postgres TO backup;
   ```

2. Edit `incremental_backup.sh` to set connection credentials and backup path:

   ```sh
   PGHOST=127.0.0.1
   PGPORT=5432
   PGUSER=backup
   PGPASSWORD=your-password
   BACKUP_ROOT=/var/backups/postgresql/cluster_1
   BACKUP_RETENTION_DAYS=30
   ```

3. Install the script:

   ```sh
   install -o postgres -g postgres -m 750 incremental_backup.sh /usr/local/sbin/incremental_backup.sh
   mkdir -p /var/backups/postgresql/cluster_1
   chown postgres:postgres /var/backups/postgresql/cluster_1
   ```

4. Schedule it as the PostgreSQL service user:

   ```cron
   15 02 * * * /usr/local/sbin/incremental_backup.sh >> /var/log/postgresql/daily-incremental-backup.log 2>&1
   ```

The first successful run creates a full physical baseline. Later runs use the latest `backup_manifest` as the incremental reference. Keep the baseline and every dependent incremental backup together; deleting an older backup can make later backups unusable. Use `pg_combinebackup` on a PostgreSQL 17 system to assemble a complete backup for restore.

The script prefers running on a synchronous standby. If no sync standby exists in the cluster, it falls back to the replica with the lowest replication lag. It skips backup on the primary and on replicas with higher lag. A lock file prevents overlapping runs.

## NetBackup Integration

To push backups to Veritas NetBackup, set these variables in the script:

```sh
NETBACKUP_ENABLED=true
NETBACKUP_POLICY=PostgreSQL_Backup
NETBACKUP_CLIENT=$(hostname)
NETBACKUP_SERVER=netbackup-master
```

The script will use `nbbackup` or `bpcd` (whichever is available) to push the backup directory to NetBackup after local backup completes.

## MinIO Integration

To push backups to MinIO (S3-compatible), set these variables in the script:

```sh
MINIO_ENABLED=true
MINIO_ENDPOINT=http://100.85.22.67:9001
MINIO_ACCESS_KEY=minioadmin
MINIO_SECRET_KEY=minioadmin
MINIO_BUCKET=postgresql-backup
MINIO_ALIAS=pgbackup
```

The script will use `mc` (MinIO Client) or `aws` CLI (whichever is available) to sync the backup directory to MinIO after local backup completes. Old backups on MinIO are automatically cleaned up based on `BACKUP_RETENTION_DAYS`.