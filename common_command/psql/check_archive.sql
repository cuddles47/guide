SELECT name, setting, context
FROM pg_settings
WHERE name IN (
    'archive_mode',
    'archive_command',
    'archive_timeout'
);

ALTER SYSTEM SET archive_mode = 'on';
ALTER SYSTEM SET archive_command = '';