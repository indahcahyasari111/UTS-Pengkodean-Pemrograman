-- SOAL 1.2: VALIDASI KESEIMBANGAN JURNAL
-- Memastikan total debit = total kredit
-- Pemeriksaan dilakukan saat transaksi akan COMMIT.

CREATE OR REPLACE FUNCTION check_journal_balanced()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_ids BIGINT[];
    v_id BIGINT;
    v_debit NUMERIC(18,2);
    v_credit NUMERIC(18,2);
    v_count INTEGER;
BEGIN
    -- Tentukan jurnal yang perlu diperiksa
    IF TG_TABLE_NAME = 'journal_headers' THEN
        v_ids := ARRAY[NEW.id];

    ELSIF TG_OP = 'DELETE' THEN
        v_ids := ARRAY[OLD.header_id];

    ELSIF TG_OP = 'UPDATE' THEN
        v_ids := ARRAY[OLD.header_id, NEW.header_id];

    ELSE
        v_ids := ARRAY[NEW.header_id];
    END IF;

    -- Periksa setiap jurnal yang terdampak
    FOREACH v_id IN ARRAY v_ids LOOP

        SELECT
            COALESCE(SUM(debit), 0),
            COALESCE(SUM(credit), 0),
            COUNT(*)
        INTO v_debit, v_credit, v_count
        FROM journal_lines
        WHERE header_id = v_id;

        -- Minimal dua baris dan debit harus sama dengan kredit
        IF EXISTS (
            SELECT 1
            FROM journal_headers
            WHERE id = v_id
        )
        AND (v_count < 2 OR v_debit <> v_credit) THEN

            RAISE EXCEPTION
                'Jurnal % tidak seimbang. Debit=%, Kredit=%, jumlah baris=%',
                v_id, v_debit, v_credit, v_count
                USING ERRCODE = 'check_violation';
        END IF;

    END LOOP;

    RETURN NULL;
END;
$$;

-- Trigger untuk INSERT, UPDATE, dan DELETE baris jurnal
CREATE CONSTRAINT TRIGGER ctrg_journal_lines_balanced
AFTER INSERT OR UPDATE OR DELETE ON journal_lines
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION check_journal_balanced();

-- Trigger untuk mencegah header jurnal tanpa rincian yang valid
CREATE CONSTRAINT TRIGGER ctrg_journal_headers_balanced
AFTER INSERT ON journal_headers
DEFERRABLE INITIALLY DEFERRED
FOR EACH ROW
EXECUTE FUNCTION check_journal_balanced();