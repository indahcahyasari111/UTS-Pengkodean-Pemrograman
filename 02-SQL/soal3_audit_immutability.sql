-- SOAL 3: AUDIT TRAIL, IMMUTABILITY, DAN AKSES DATABASE
-- Jalankan di Supabase SQL Editor setelah soal3_schema.sql dan fungsi post_voucher berhasil.

-- =====================================================
-- 1. Lindungi transaksi yang sudah POSTED dari UPDATE/DELETE
--    Baris DRAFT masih boleh dibuat dan diposting.
-- =====================================================
CREATE OR REPLACE FUNCTION public.protect_posted_journal()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_status TEXT;
BEGIN
    IF TG_TABLE_NAME = 'journal_headers' THEN
        IF TG_OP = 'DELETE' THEN
            IF OLD.status_posting = 'POSTED' THEN
                RAISE EXCEPTION
                    'Jurnal POSTED tidak boleh dihapus. Gunakan jurnal pembalik (reversing entry).';
            END IF;
            RETURN OLD;
        ELSIF TG_OP = 'UPDATE' THEN
            IF OLD.status_posting = 'POSTED' THEN
                RAISE EXCEPTION
                    'Jurnal POSTED tidak boleh diubah. Gunakan jurnal pembalik (reversing entry).';
            END IF;
            -- Mengizinkan perpindahan DRAFT -> POSTED.
            RETURN NEW;
        END IF;

    ELSIF TG_TABLE_NAME = 'journal_lines' THEN
        -- Untuk UPDATE/DELETE, periksa jurnal asal.
        IF TG_OP IN ('UPDATE', 'DELETE') THEN
            SELECT h.status_posting
            INTO v_status
            FROM public.journal_headers AS h
            WHERE h.id = OLD.header_id
            FOR UPDATE;

            IF v_status = 'POSTED' THEN
                RAISE EXCEPTION
                    'Rincian jurnal POSTED tidak boleh diubah atau dihapus. Gunakan jurnal pembalik.';
            END IF;
        END IF;

        -- Untuk INSERT/UPDATE, periksa jurnal tujuan.
        IF TG_OP IN ('INSERT', 'UPDATE') THEN
            SELECT h.status_posting
            INTO v_status
            FROM public.journal_headers AS h
            WHERE h.id = NEW.header_id
            FOR UPDATE;

            IF v_status = 'POSTED' THEN
                RAISE EXCEPTION
                    'Rincian tidak boleh ditambahkan ke jurnal POSTED.';
            END IF;
        END IF;

        IF TG_OP = 'DELETE' THEN
            RETURN OLD;
        END IF;
        RETURN NEW;
    END IF;

    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_protect_posted_header ON public.journal_headers;
CREATE TRIGGER trg_protect_posted_header
BEFORE UPDATE OR DELETE ON public.journal_headers
FOR EACH ROW
EXECUTE FUNCTION public.protect_posted_journal();

DROP TRIGGER IF EXISTS trg_protect_posted_lines ON public.journal_lines;
CREATE TRIGGER trg_protect_posted_lines
BEFORE INSERT OR UPDATE OR DELETE ON public.journal_lines
FOR EACH ROW
EXECUTE FUNCTION public.protect_posted_journal();

-- =====================================================
-- 2. Catat INSERT/UPDATE/DELETE jurnal secara otomatis
-- =====================================================
CREATE OR REPLACE FUNCTION public.audit_journal_changes()
RETURNS TRIGGER
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    v_old JSONB;
    v_new JSONB;
    v_record_id TEXT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        v_new := pg_catalog.to_jsonb(NEW);
        v_record_id := v_new ->> 'id';
        INSERT INTO public.audit_log
            (table_name, record_id, operation, actor_id, occurred_at, old_data, new_data)
        VALUES
            (TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, v_record_id, TG_OP,
             auth.uid(), pg_catalog.clock_timestamp(), NULL, v_new);
        RETURN NEW;

    ELSIF TG_OP = 'UPDATE' THEN
        v_old := pg_catalog.to_jsonb(OLD);
        v_new := pg_catalog.to_jsonb(NEW);
        v_record_id := v_new ->> 'id';
        INSERT INTO public.audit_log
            (table_name, record_id, operation, actor_id, occurred_at, old_data, new_data)
        VALUES
            (TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, v_record_id, TG_OP,
             auth.uid(), pg_catalog.clock_timestamp(), v_old, v_new);
        RETURN NEW;

    ELSIF TG_OP = 'DELETE' THEN
        v_old := pg_catalog.to_jsonb(OLD);
        v_record_id := v_old ->> 'id';
        INSERT INTO public.audit_log
            (table_name, record_id, operation, actor_id, occurred_at, old_data, new_data)
        VALUES
            (TG_TABLE_SCHEMA || '.' || TG_TABLE_NAME, v_record_id, TG_OP,
             auth.uid(), pg_catalog.clock_timestamp(), v_old, NULL);
        RETURN OLD;
    END IF;

    RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_audit_journal_headers ON public.journal_headers;
CREATE TRIGGER trg_audit_journal_headers
AFTER INSERT OR UPDATE OR DELETE ON public.journal_headers
FOR EACH ROW
EXECUTE FUNCTION public.audit_journal_changes();

DROP TRIGGER IF EXISTS trg_audit_journal_lines ON public.journal_lines;
CREATE TRIGGER trg_audit_journal_lines
AFTER INSERT OR UPDATE OR DELETE ON public.journal_lines
FOR EACH ROW
EXECUTE FUNCTION public.audit_journal_changes();

-- =====================================================
-- 3. Audit log bersifat append-only: tidak boleh UPDATE/DELETE
-- =====================================================
CREATE OR REPLACE FUNCTION public.block_audit_log_mutation()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = ''
AS $$
BEGIN
    RAISE EXCEPTION 'Audit log bersifat append-only: UPDATE/DELETE tidak diizinkan.';
END;
$$;

DROP TRIGGER IF EXISTS trg_block_audit_log_mutation ON public.audit_log;
CREATE TRIGGER trg_block_audit_log_mutation
BEFORE UPDATE OR DELETE ON public.audit_log
FOR EACH ROW
EXECUTE FUNCTION public.block_audit_log_mutation();

-- =====================================================
-- 4. Aktifkan RLS dan minimalkan akses langsung dari browser
--    Frontend akan membaca daftar akun dan memanggil RPC.
-- =====================================================
ALTER TABLE public.chart_of_accounts ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.journal_headers ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.journal_lines ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_log ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.chart_of_accounts,
    public.journal_headers,
    public.journal_lines,
    public.audit_log
FROM anon, authenticated;

GRANT SELECT ON TABLE public.chart_of_accounts TO authenticated;

DROP POLICY IF EXISTS coa_read_authenticated ON public.chart_of_accounts;
CREATE POLICY coa_read_authenticated
ON public.chart_of_accounts
FOR SELECT
TO authenticated
USING (true);

-- Pengguna terautentikasi dapat memanggil RPC; tidak diberi akses tulis langsung.
REVOKE ALL ON FUNCTION public.post_voucher(DATE, TEXT, TEXT, JSONB)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.post_voucher(DATE, TEXT, TEXT, JSONB)
TO authenticated;

-- Catatan: tidak ada policy langsung untuk journal_headers, journal_lines, audit_log.
-- Akses transaksi dilakukan melalui fungsi RPC yang tervalidasi.
