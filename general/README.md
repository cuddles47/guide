# PostgreSQL incremental backup

## Setup

1. Create a dedicated backup role on the cluster primary:

   ```sql
   CREATE ROLE backup WITH LOGIN REPLICATION PASSWORD 'replace-with-a-long-random-password';
   GRANT CONNECT ON DATABASE postgres TO backup;
   ```

2. Copy `backup.env.example` to `/etc/postgresql/backup.env`, set a real password and backup path, then restrict it:

   ```sh
   install -o postgres -g postgres -m 600 backup.env.example /etc/postgresql/backup.env
   editor /etc/postgresql/backup.env
   install -o postgres -g postgres -m 750 incremental_backup.sh /usr/local/sbin/incremental_backup.sh
   mkdir -p /var/backups/postgresql/cluster_1
   chown postgres:postgres /var/backups/postgresql/cluster_1
   ```

3. Schedule it as the PostgreSQL service user:

   ```cron
   15 02 * * * /usr/local/sbin/incremental_backup.sh >> /var/log/postgresql/daily-incremental-backup.log 2>&1
   ```

The first successful run creates a full physical baseline. Later runs use the latest `backup_manifest` as the incremental reference. Keep the baseline and every dependent incremental backup together; deleting an older backup can make later backups unusable. Use `pg_combinebackup` on a PostgreSQL 17 system to assemble a complete backup for restore.

The script prefers running on a synchronous standby. If no sync standby exists in the cluster, it falls back to the replica with the lowest replication lag. It skips backup on the primary and on replicas with higher lag. A lock file prevents overlapping runs.