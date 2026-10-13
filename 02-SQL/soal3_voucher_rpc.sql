
-- SOAL 3: FUNGSI POSTING VOUCHER KAS KELUAR
-- Database: Supabase / PostgreSQL

-- Aktifkan extension untuk membuat hash SHA-256.
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

CREATE OR REPLACE FUNCTION public.post_voucher(
    p_date DATE,
    p_ref TEXT,
    p_desc TEXT,
    p_lines JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $function$
DECLARE
    v_header_id BIGINT;
    v_total_debit NUMERIC(18,2);
    v_total_credit NUMERIC(18,2);
    v_line_count BIGINT;
    v_hash_payload JSONB;
    v_hash TEXT;
BEGIN
    -- 1. Validasi informasi utama
    IF p_date IS NULL
       OR p_ref IS NULL OR pg_catalog.btrim(p_ref) = ''
       OR p_desc IS NULL OR pg_catalog.btrim(p_desc) = '' THEN
        RAISE EXCEPTION 'Tanggal, nomor bukti, dan deskripsi wajib diisi';
    END IF;

    -- 2. Validasi format rincian jurnal
    IF p_lines IS NULL OR pg_catalog.jsonb_typeof(p_lines) <> 'array' THEN
        RAISE EXCEPTION 'Rincian jurnal harus berupa array JSON';
    END IF;

    IF pg_catalog.jsonb_array_length(p_lines) < 2 THEN
        RAISE EXCEPTION 'Jurnal harus memiliki minimal dua baris';
    END IF;

    -- 3. Pastikan setiap baris memiliki akun dan nominal yang valid
    IF EXISTS (
        SELECT 1
        FROM pg_catalog.jsonb_to_recordset(p_lines)
            AS x(account_id BIGINT, debit NUMERIC, credit NUMERIC)
        WHERE account_id IS NULL
           OR debit IS NULL
           OR credit IS NULL
           OR debit < 0
           OR credit < 0
           OR (debit = 0 AND credit = 0)
           OR (debit > 0 AND credit > 0)
    ) THEN
        RAISE EXCEPTION
            'Setiap baris harus memiliki akun dan tepat satu sisi bernilai positif';
    END IF;

    -- 4. Hitung total debit dan kredit
    SELECT
        COUNT(*),
        COALESCE(SUM(x.debit), 0),
        COALESCE(SUM(x.credit), 0)
    INTO v_line_count, v_total_debit, v_total_credit
    FROM pg_catalog.jsonb_to_recordset(p_lines)
        AS x(account_id BIGINT, debit NUMERIC, credit NUMERIC);

    IF v_line_count < 2 OR v_total_debit <= 0
       OR v_total_debit <> v_total_credit THEN
        RAISE EXCEPTION
            'Jurnal tidak seimbang. Debit=%, Kredit=%',
            v_total_debit, v_total_credit;
    END IF;

    -- 5. Pastikan semua akun tersedia
    IF EXISTS (
        SELECT 1
        FROM pg_catalog.jsonb_to_recordset(p_lines)
            AS x(account_id BIGINT, debit NUMERIC, credit NUMERIC)
        LEFT JOIN public.chart_of_accounts a
            ON a.account_id = x.account_id
        WHERE a.account_id IS NULL
    ) THEN
        RAISE EXCEPTION 'Ada akun yang tidak ditemukan';
    END IF;

    -- 6. Voucher kas keluar wajib mengkredit Kas/Bank/Setara Kas
    IF NOT EXISTS (
        SELECT 1
        FROM pg_catalog.jsonb_to_recordset(p_lines)
            AS x(account_id BIGINT, debit NUMERIC, credit NUMERIC)
        JOIN public.chart_of_accounts a
            ON a.account_id = x.account_id
        WHERE x.credit > 0
          AND a.is_cash_or_equivalent = TRUE
    ) THEN
        RAISE EXCEPTION
            'Voucher kas keluar harus mengkredit akun Kas, Bank, atau Setara Kas';
    END IF;

    -- 7. Buat header jurnal
    INSERT INTO public.journal_headers (
        trx_date, ref_number, description, status_posting
    )
    VALUES (
        p_date, pg_catalog.btrim(p_ref),
        pg_catalog.btrim(p_desc), 'DRAFT'
    )
    RETURNING id INTO v_header_id;

    -- 8. Simpan seluruh rincian jurnal
    INSERT INTO public.journal_lines (
        header_id, account_id, debit, credit
    )
    SELECT
        v_header_id, x.account_id, x.debit, x.credit
    FROM pg_catalog.jsonb_to_recordset(p_lines)
        AS x(account_id BIGINT, debit NUMERIC, credit NUMERIC);

    -- 9. Bangun representasi data untuk hash checksum
    SELECT pg_catalog.jsonb_build_object(
        'id', h.id,
        'trx_date', h.trx_date,
        'ref_number', h.ref_number,
        'description', h.description,
        'created_by', h.created_by,
        'created_at', h.created_at,
        'lines', (
            SELECT pg_catalog.jsonb_agg(
                pg_catalog.jsonb_build_object(
                    'account_id', l.account_id,
                    'debit', l.debit,
                    'credit', l.credit
                ) ORDER BY l.id
            )
            FROM public.journal_lines l
            WHERE l.header_id = h.id
        )
    )
    INTO v_hash_payload
    FROM public.journal_headers h
    WHERE h.id = v_header_id;

    -- Hitung SHA-256 atas representasi data tersebut
    v_hash := pg_catalog.encode(
        extensions.digest(
            pg_catalog.convert_to(v_hash_payload::TEXT, 'UTF8'),
            'sha256'
        ),
        'hex'
    );

    -- 10. Posting hanya setelah seluruh validasi berhasil
    UPDATE public.journal_headers
    SET status_posting = 'POSTED',
        posted_at = pg_catalog.now(),
        hash_checksum = v_hash
    WHERE id = v_header_id;

    -- 11. Kembalikan hasil kepada aplikasi
    RETURN pg_catalog.jsonb_build_object(
        'id', v_header_id,
        'ref_number', pg_catalog.btrim(p_ref),
        'status_posting', 'POSTED',
        'total_debit', v_total_debit,
        'total_credit', v_total_credit,
        'hash_checksum', v_hash
    );
END;
$function$;

-- Jangan izinkan pemanggilan fungsi oleh role publik secara default.
REVOKE ALL ON FUNCTION public.post_voucher(DATE, TEXT, TEXT, JSONB)
FROM PUBLIC;

-- Pemanggilan aplikasi nantinya menggunakan pengguna terautentikasi.
GRANT EXECUTE ON FUNCTION public.post_voucher(DATE, TEXT, TEXT, JSONB)
TO authenticated;
