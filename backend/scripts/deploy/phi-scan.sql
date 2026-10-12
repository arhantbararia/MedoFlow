-- Synthetic-data scan for the Cloudflare demo/pilot database (PHI gate, HIPAA §4.2).
-- Scans every text/varchar/json/jsonb column in `public` for patterns that indicate
-- real-world PII. Every row of the result must show hits = 0 before the environment
-- is declared synthetic-only.
--
--   psql "$DATABASE_URL" -f backend/scripts/deploy/phi-scan.sql
--
-- Patterns:
--   webmail_email  addresses at public mailbox providers (fixtures use .demo/.test/example.com)
--   ssn            NNN-NN-NNNN
--   phone_non555   North-American phone numbers outside the fictional 555-01xx range
--   card_number    16-digit card-like sequences
CREATE TEMP TABLE phi_scan_hits (pattern text, table_name text, column_name text, hits bigint);

DO $$
DECLARE
  r record;
  p record;
  n bigint;
BEGIN
  FOR p IN SELECT * FROM (VALUES
      ('webmail_email', '@(gmail|yahoo|hotmail|outlook|icloud|proton|protonmail|aol|live|msn)\.'),
      ('ssn',           '(^|[^0-9])[0-9]{3}-[0-9]{2}-[0-9]{4}([^0-9]|$)'),
      ('phone_non555',  '(^|[^0-9])\(?[2-9][0-9]{2}\)?[ .-]?(?!555)[2-9][0-9]{2}[ .-][0-9]{4}([^0-9]|$)'),
      ('card_number',   '(^|[^0-9])[0-9]{4}[ -]?[0-9]{4}[ -]?[0-9]{4}[ -]?[0-9]{4}([^0-9]|$)')
    ) AS t(name, rx)
  LOOP
    FOR r IN
      SELECT table_name, column_name FROM information_schema.columns
      WHERE table_schema = 'public'
        AND data_type IN ('text', 'character varying', 'json', 'jsonb')
        AND column_name NOT IN ('password', 'passwordHash', 'token', 'tokenHash', 'checksum')
    LOOP
      EXECUTE format('SELECT count(*) FROM public.%I WHERE %I::text ~* %L', r.table_name, r.column_name, p.rx)
        INTO n;
      IF n > 0 THEN
        INSERT INTO phi_scan_hits VALUES (p.name, r.table_name, r.column_name, n);
      END IF;
    END LOOP;
  END LOOP;
END $$;

SELECT pattern, coalesce(sum(hits), 0) AS hits, string_agg(table_name || '.' || column_name, ', ') AS locations
FROM (VALUES ('webmail_email'), ('ssn'), ('phone_non555'), ('card_number')) AS p(pattern)
LEFT JOIN phi_scan_hits h USING (pattern)
GROUP BY pattern
ORDER BY pattern;
