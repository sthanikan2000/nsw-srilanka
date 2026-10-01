-- @UP
ALTER TABLE consignments ADD COLUMN IF NOT EXISTS dry_note text;

-- @DOWN
SELECT 1;
