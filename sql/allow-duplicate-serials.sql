-- Allow duplicate serial numbers
-- ==============================
-- Stock entry treats an existing serial as a confirmable warning rather than a
-- hard stop, so the same serial can be logged again deliberately (equipment that
-- comes back through the depot). That is impossible while the database enforces
-- uniqueness on serials: the insert fails with 23505 / HTTP 409 and the job is
-- rolled back.
--
-- APPLIED to the Serial Tracker project (lfydtctndrzzdyavmlva) on 2026-08-24 as
-- migration 20260824013359_allow_duplicate_serials. It dropped two UNIQUE
-- constraints that were both live:
--   serials_serial_depot_unique  UNIQUE (serial_number, depot_id)
--   unique_serial                UNIQUE (serial_number)
-- The second was global rather than per-depot, so it had also been blocking the
-- same serial from existing in two different depots — contrary to the
-- documented per-depot scoping. Kept here as the record, and for any other
-- environment that still needs it; the script is idempotent and safe to re-run.

-- 1. Inspect first: what unique constraints/indexes exist on serials?
--    (Run this on its own and read the output before running step 2.)
SELECT i.relname AS index_name,
       ix.indisunique AS is_unique,
       ix.indisprimary AS is_primary,
       array_agg(a.attname ORDER BY k.ord) AS columns
FROM pg_index ix
JOIN pg_class t ON t.oid = ix.indrelid
JOIN pg_class i ON i.oid = ix.indexrelid
JOIN unnest(ix.indkey) WITH ORDINALITY AS k(attnum, ord) ON true
JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
WHERE t.relname = 'serials'
  AND t.relnamespace = 'public'::regnamespace
  AND ix.indisunique
GROUP BY i.relname, ix.indisunique, ix.indisprimary;

-- 2. Drop the uniqueness on serial_number, leaving the primary key alone.
--    Only indexes whose columns are exactly (serial_number) or
--    (depot_id, serial_number) are touched; anything else is left for you to
--    review by hand from the output of step 1.
DO $$
DECLARE
    rec record;
BEGIN
    FOR rec IN
        SELECT i.relname AS index_name,
               ix.indisprimary AS is_primary,
               array_agg(a.attname::text ORDER BY k.ord) AS columns
        FROM pg_index ix
        JOIN pg_class t ON t.oid = ix.indrelid
        JOIN pg_class i ON i.oid = ix.indexrelid
        JOIN unnest(ix.indkey) WITH ORDINALITY AS k(attnum, ord) ON true
        JOIN pg_attribute a ON a.attrelid = t.oid AND a.attnum = k.attnum
        WHERE t.relname = 'serials'
          AND t.relnamespace = 'public'::regnamespace
          AND ix.indisunique
        GROUP BY i.relname, ix.indisprimary
    LOOP
        IF rec.is_primary THEN
            CONTINUE;  -- never touch the primary key
        END IF;
        IF rec.columns <> ARRAY['serial_number']
           AND rec.columns <> ARRAY['depot_id','serial_number']
           AND rec.columns <> ARRAY['serial_number','depot_id'] THEN
            RAISE NOTICE 'Leaving unique index % (%) alone — review it by hand',
                rec.index_name, array_to_string(rec.columns, ', ');
            CONTINUE;
        END IF;

        -- A unique *constraint* owns its index and must be dropped as a
        -- constraint; a bare unique index is dropped directly.
        IF EXISTS (SELECT 1 FROM pg_constraint
                   WHERE conrelid = 'public.serials'::regclass
                     AND conname = rec.index_name) THEN
            EXECUTE format('ALTER TABLE public.serials DROP CONSTRAINT %I', rec.index_name);
            RAISE NOTICE 'Dropped unique constraint %', rec.index_name;
        ELSE
            EXECUTE format('DROP INDEX public.%I', rec.index_name);
            RAISE NOTICE 'Dropped unique index %', rec.index_name;
        END IF;
    END LOOP;
END $$;

-- 3. Keep the lookup fast. The duplicate check queries serials by
--    depot_id + serial_number, which was riding on the dropped unique index.
CREATE INDEX IF NOT EXISTS serials_depot_serial_idx
    ON public.serials (depot_id, serial_number);
