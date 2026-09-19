-- Bukan rollback/migrasi. Pembersihan operasional aman, jalankan berkala oleh owner.
-- Tidak menghapus ledger, audit, atau idempotency transaksi.
BEGIN;
DELETE FROM public.sinabos_sessions WHERE expires_at < now();
DELETE FROM public.sinabos_limits WHERE expires_at < now();
COMMIT;
