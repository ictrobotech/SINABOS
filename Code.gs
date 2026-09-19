/*************************************************************
 * SINABOS v3.0 — Google Apps Script API + Neon PostgreSQL
 * SMP LABSCHOOL UNTAD PALU
 *
 * Alur:
 *   1) action=scan -> lookup barcode rombel, buka form.
 *   2) action=simpanTransaksi -> simpan form multi-mapel melalui
 *      fungsi PostgreSQL atomik.
 *   3) action=stokMasuk -> jumlah + sumber diperoleh.
 *   4) action=adminData -> data dashboard admin.
 *
 * Apps Script terhubung langsung ke Neon memakai JDBC PostgreSQL.
 * Jangan memakai connection string atau password Neon pada frontend.
 *
 * Script Properties wajib:
 *   NEON_HOST
 *   NEON_DB
 *   NEON_USER
 *   NEON_PASSWORD
 *   NEON_PORT (opsional, default 5432)
 *   API_TOKEN
 *   SEKOLAH_NAMA
 *   ADMIN_EMAIL (opsional)
 *************************************************************/

const CFG = {
  HOST: PropertiesService.getScriptProperties().getProperty('NEON_HOST'),
  DB: PropertiesService.getScriptProperties().getProperty('NEON_DB') || 'neondb',
  USER: PropertiesService.getScriptProperties().getProperty('NEON_USER'),
  PASSWORD: PropertiesService.getScriptProperties().getProperty('NEON_PASSWORD'),
  PORT: PropertiesService.getScriptProperties().getProperty('NEON_PORT') || '5432',
  TOKEN: PropertiesService.getScriptProperties().getProperty('API_TOKEN'),
  SEKOLAH: PropertiesService.getScriptProperties().getProperty('SEKOLAH_NAMA') || 'SMP LABSCHOOL UNTAD PALU',
  ADMIN_EMAIL: PropertiesService.getScriptProperties().getProperty('ADMIN_EMAIL') || ''
};

// ---------- KONEKSI NEON POSTGRESQL VIA JDBC ----------
function db_() {
  if (!CFG.HOST || !CFG.USER || !CFG.PASSWORD) {
    throw new Error('NEON_HOST, NEON_USER, dan NEON_PASSWORD belum diisi');
  }
  // Apps Script JDBC memakai whitelist parameter dan menolak `sslmode` maupun
  // `ssl` pada query URL. Biarkan driver PostgreSQL menegosiasikan TLS secara
  // default; Neon hanya menerima koneksi terenkripsi.
  const url = 'jdbc:postgresql://' + CFG.HOST + ':' + CFG.PORT + '/' + CFG.DB;
  return Jdbc.getConnection(url, CFG.USER, CFG.PASSWORD);
}

function close_(obj) {
  try { if (obj) obj.close(); } catch (ignore) {}
}

function rows_(conn, sql, params) {
  let stmt = null;
  let rs = null;
  try {
    stmt = conn.prepareStatement(sql);
    (params || []).forEach(function (value, i) {
      stmt.setString(i + 1, value === null || value === undefined ? null : String(value));
    });
    rs = stmt.executeQuery();
    const meta = rs.getMetaData();
    const count = meta.getColumnCount();
    const out = [];
    while (rs.next()) {
      const row = {};
      for (let i = 1; i <= count; i++) {
        const key = meta.getColumnLabel(i);
        row[key] = rs.getString(i);
      }
      out.push(row);
    }
    return out;
  } finally {
    close_(rs);
    close_(stmt);
  }
}

function one_(conn, sql, params) {
  const data = rows_(conn, sql, params);
  return data.length ? data[0] : null;
}

function json_(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}

function requireToken_(p) {
  if (!CFG.TOKEN || p.token !== CFG.TOKEN) throw new Error('Token tidak valid');
}

// ---------- ROUTER ----------
function doPost(e) {
  try {
    const p = JSON.parse((e && e.postData && e.postData.contents) || '{}');
    requireToken_(p);

    if (p.action === '__ping__') return json_(tesKoneksi());
    if (p.action === 'adminData') return json_(aksiAdminData());
    if (p.action === 'scan') return json_(aksiScan(p));
    if (p.action === 'simpanTransaksi') return json_(aksiSimpanTransaksi(p));
    if (p.action === 'stokMasuk') return json_(aksiStokMasuk(p));
    if (p.action === 'daftarBarcode') return json_(aksiDaftarBarcode(p));
    if (p.action === 'rekapBulanan') return json_(rekapBulanan());

    return json_({ ok: false, error: 'Action tidak dikenal: ' + p.action });
  } catch (err) {
    return json_({ ok: false, error: String(err && err.message || err) });
  }
}

function doGet() {
  return json_({
    ok: true,
    app: 'SINABOS API v3.0',
    model: 'Neon PostgreSQL + scan-rombel-form-multi-mapel',
    sekolah: CFG.SEKOLAH
  });
}

// ---------- ADMIN DASHBOARD ----------
function aksiAdminData() {
  const conn = db_();
  try {
    return {
      ok: true,
      books: rows_(conn, `
        select id::text, kode_buku, judul, mata_pelajaran, kelas_target
        from books where aktif = true
        order by kelas_target, judul
      `),
      stocks: rows_(conn, `
        select * from v_stok where aktif = true
        order by kelas_target, judul
      `),
      transactions: rows_(conn, `
        select * from v_transaksi_admin
        order by created_at desc limit 100
      `),
      active: rows_(conn, `
        select * from v_peminjaman_aktif
        order by rombel, judul
      `)
    };
  } finally {
    close_(conn);
  }
}

// ---------- SCAN / LOOKUP ----------
// Scan hanya membuka form. Belum menulis transaksi.
function aksiScan(p) {
  if (!p.barcode || !String(p.barcode).trim()) throw new Error('Barcode wajib diisi');
  const conn = db_();
  try {
    const barcode = String(p.barcode).trim();
    const rb = one_(conn, `
      select id::text, barcode, rombel, kelas_target, coalesce(keterangan, '') as keterangan
      from rombel_barcodes
      where lower(barcode) = lower(?) and aktif = true
      limit 1
    `, [barcode]);
    if (!rb) throw new Error('Barcode rombel tidak terdaftar atau nonaktif');

    return {
      ok: true,
      mode: 'form',
      barcode: rb.barcode,
      rombel: rb.rombel,
      kelas_target: rb.kelas_target,
      keterangan: rb.keterangan || '',
      books: rows_(conn, `
        select id::text, kode_buku, judul, mata_pelajaran, kelas_target
        from books
        where kelas_target = ? and aktif = true
        order by judul
      `, [rb.kelas_target]),
      aktif: rows_(conn, `
        select * from v_peminjaman_aktif
        where barcode = ? order by judul
      `, [rb.barcode]),
      tanggal: Utilities.formatDate(new Date(), 'Asia/Makassar', 'yyyy-MM-dd')
    };
  } finally {
    close_(conn);
  }
}

// ---------- SIMPAN FORM TRANSAKSI ----------
function aksiSimpanTransaksi(p) {
  if (!p.barcode) throw new Error('Barcode wajib diisi');
  if (!p.jenis_transaksi || ['pinjam', 'kembali'].indexOf(p.jenis_transaksi) < 0) {
    throw new Error('Jenis transaksi harus pinjam atau kembali');
  }
  if (!p.nama_guru || !String(p.nama_guru).trim()) throw new Error('Nama guru wajib diisi');
  if (!Array.isArray(p.items) || !p.items.length) throw new Error('Minimal satu buku/mapel wajib diisi');

  const conn = db_();
  try {
    const row = one_(conn, `
      select public.simpan_transaksi_scan(?, ?, ?, cast(? as jsonb))::text as result
    `, [
      String(p.barcode).trim(),
      p.jenis_transaksi,
      String(p.nama_guru).trim(),
      JSON.stringify(p.items)
    ]);
    if (!row || !row.result) throw new Error('Respons transaksi kosong');
    const result = JSON.parse(row.result);
    if (!result.ok) throw new Error('Transaksi gagal disimpan');
    return result;
  } finally {
    close_(conn);
  }
}

// ---------- STOK MASUK ----------
function aksiStokMasuk(p) {
  if (!p.buku_id) throw new Error('Jenis buku wajib dipilih');
  if (!(Number(p.jumlah) > 0)) throw new Error('Jumlah buku harus lebih dari 0');
  if (!p.sumber_perolehan || !String(p.sumber_perolehan).trim()) {
    throw new Error('Sumber diperoleh wajib diisi');
  }

  const conn = db_();
  try {
    const row = one_(conn, `
      insert into stock_movements
        (buku_id, tipe, jumlah, sumber_perolehan, keterangan)
      values (?, 'masuk', ?, ?, 'Stok masuk')
      returning id::text as id, tanggal::text as tanggal
    `, [p.buku_id, Number(p.jumlah), String(p.sumber_perolehan).trim()]);
    return { ok: true, message: 'Stok masuk tersimpan', data: row };
  } finally {
    close_(conn);
  }
}

// ---------- MASTER BARCODE ROMBEL ----------
function aksiDaftarBarcode(p) {
  if (!p.barcode) throw new Error('barcode wajib diisi');
  if (!p.rombel) throw new Error('rombel wajib diisi');
  if (!p.kelas_target) throw new Error('kelas_target wajib diisi');

  const conn = db_();
  try {
    const row = one_(conn, `
      insert into rombel_barcodes (barcode, rombel, kelas_target, keterangan, aktif)
      values (?, ?, ?, ?, true)
      returning id::text as id, barcode, rombel, kelas_target
    `, [
      String(p.barcode).trim(), String(p.rombel).trim(),
      String(p.kelas_target).trim(), p.keterangan || ''
    ]);
    return { ok: true, message: 'Barcode rombel terdaftar', data: row };
  } finally {
    close_(conn);
  }
}

// ---------- REKAP BULANAN ----------
function rekapBulanan() {
  const bulan = Utilities.formatDate(new Date(), 'Asia/Makassar', 'yyyy-MM');
  const conn = db_();
  try {
    const mutasi = rows_(conn, `
      select * from v_mutasi_bulanan where bulan = ? order by kode_buku
    `, [bulan]);
    const ss = SpreadsheetApp.create('SINABOS SMP LABSCHOOL UNTAD PALU - Rekap Mutasi ' + bulan);
    const sh = ss.getActiveSheet();
    sh.appendRow(['Bulan', 'Kode Buku', 'Judul', 'Masuk', 'Dipinjam', 'Kembali', 'Rusak/Hilang', 'Sumber']);
    (mutasi || []).forEach(function (r) {
      sh.appendRow([r.bulan, r.kode_buku, r.judul, r.masuk, r.dipinjam, r.kembali, r.rusak_hilang, r.sumber || '-']);
    });
    if (CFG.ADMIN_EMAIL) {
      MailApp.sendEmail(
        CFG.ADMIN_EMAIL,
        '[SINABOS SMP LABSCHOOL UNTAD PALU] Rekap mutasi buku ' + bulan,
        'Rekap otomatis: ' + ss.getUrl()
      );
    }
    return { ok: true, bulan: bulan, spreadsheet: ss.getUrl() };
  } finally {
    close_(conn);
  }
}

// ---------- TES KONEKSI ----------
function tesKoneksi() {
  const conn = db_();
  try {
    const row = one_(conn, 'select current_database() as database, current_user as user, now()::text as waktu');
    return { ok: true, message: 'Koneksi Neon berhasil', data: row };
  } finally {
    close_(conn);
  }
}
