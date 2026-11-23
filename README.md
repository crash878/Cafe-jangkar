# Café Jangkar — POS & Operasional Café

Aplikasi operasional café berbasis React + Vite + Supabase. Tampilan memakai identitas visual pada PRD: espresso `#24130D`, brown `#4A2818`, caramel `#D9A36B`, cream `#F7F0E9`, dan warm white `#FFFCF8`.

## Isi paket

- Login Supabase dengan role Admin/Kasir dan mode demo lokal yang diberi label **DATA CONTOH**.
- Dashboard berbasis transaksi tersimpan, grafik 7/30 hari, KPI, produk terlaris, dan transaksi terbaru.
- POS: pencarian SKU/nama, kategori, keranjang, validasi stok, diskon khusus Admin, pajak configurable, Tunai/QRIS/Transfer/E-Wallet, kembalian, transaksi atomik dengan request ID idempoten untuk retry, dan struk cetak.
- Produk: CRUD, arsip/aktifkan kembali, SKU, kategori, harga jual/modal, deskripsi, foto, filter status, sorting, pagination, dan pencarian.
- Stok: penyesuaian masuk/keluar dengan alasan, pengguna, waktu, dan audit movement.
- Laporan: periode harian/mingguan/bulanan/kustom, penjualan bersih sebelum pajak, perbandingan periode, estimasi laba kotor jika snapshot harga modal tersedia, grafik, produk terlaris, export CSV, dan print.
- Riwayat: pencarian nomor/produk/kasir, filter tanggal/metode/status, detail/cetak struk, refund/pembatalan Admin yang mengembalikan stok dan tercatat.
- Pengaturan toko, pajak, batas stok, ukuran struk, manajemen akun via Edge Function, reset password email, backup/restore JSON, dan audit log.

## Stack dan konfigurasi hosting

- Frontend: React 18 + Vite 6.
- Backend: Supabase Postgres, Auth, RLS, RPC, Storage, Edge Functions.
- Hosting frontend: Cloudflare Pages (repository GitHub yang sekarang dapat tetap dipakai; tidak perlu membuat website/repository baru).
- Build command: `npm run build`.
- Output directory: `dist`.
- Node: 22.

Environment variables frontend:

```env
VITE_SUPABASE_URL=https://YOUR_PROJECT.supabase.co
VITE_SUPABASE_ANON_KEY=YOUR_SUPABASE_PUBLISHABLE_OR_ANON_KEY
```

Gunakan hanya publishable/anon key di frontend. **Jangan pernah** menaruh `service_role` key pada Cloudflare Pages, GitHub, atau source frontend.

## Supabase setup / pembaruan database

Untuk project yang sudah menjalankan `supabase/schema.sql`:

1. Buka Supabase → SQL Editor.
2. Buat query baru.
3. Salin seluruh isi `supabase/migrations/20261123_cafe_jangkar_complete.sql` lalu jalankan.
4. Pastikan hasil query sukses. Migration ini menambahkan metadata produk, email profil, logo toko, snapshot harga modal pada item transaksi, bucket foto, izin RLS/grants yang diperlukan, RPC penyesuaian stok/refund/restore, dan validasi diskon Admin.
5. Pastikan akun Admin masih memiliki baris `public.profiles` dengan `id` yang sama dengan Auth user, `role='Admin'`, dan `active=true`.

Untuk instalasi baru, jalankan `supabase/schema.sql` terlebih dahulu, kemudian migration di atas.

## Deploy Supabase Edge Function untuk manajemen akun

Fitur undang/nonaktifkan akun membutuhkan Edge Function `manage-user`. Ini adalah backend terpisah dari frontend Cloudflare Pages.

Dengan Supabase CLI:

```bash
npx supabase login
npx supabase link --project-ref YOUR_PROJECT_REF
npx supabase functions deploy manage-user
```

Supabase Edge Functions menyediakan environment `SUPABASE_URL`, `SUPABASE_ANON_KEY`, dan `SUPABASE_SERVICE_ROLE_KEY` di sisi server. Fungsi memeriksa JWT pemanggil dan role Admin sebelum melakukan operasi Auth Admin. Jangan menyalin service-role key ke aplikasi browser.

Email undangan dan reset password memerlukan layanan email Supabase yang aktif. Untuk operasional nyata, konfigurasi SMTP khusus agar pengiriman email dapat diandalkan. Tambahkan domain Pages yang sama ke Authentication → URL Configuration → Site URL dan Redirect URLs agar tautan pemulihan kembali ke aplikasi.

## Cloudflare Pages: perbarui website yang sudah ada

1. Jangan buat project Pages baru. Buka project `cafe-jangkar` yang sudah terhubung ke repository GitHub sekarang.
2. Ganti/unggah isi source project ini ke root repository yang sama (jangan membuat folder pembungkus).
3. Commit perubahan ke branch yang dipakai Pages.
4. Pastikan Build command `npm run build` dan output directory `dist`.
5. Pastikan dua environment variable Supabase di atas masih ada.
6. Commit baru akan memicu build/deploy otomatis. URL Pages yang lama tetap digunakan.

Jika perubahan environment variable dibuat, lakukan redeploy setelah menyimpannya.

## Menjalankan lokal dan pengujian

```bash
npm install
npm run dev
npm test
npm run build
```

Tes unit `node --test` mencakup kalkulasi subtotal/diskon/pajak/total, kembalian, status stok, dan penjualan bersih. Pengujian unit tidak menggantikan pengujian end-to-end pada project Supabase milik café.

## Aturan data dan keamanan

- Harga disimpan sebagai integer Rupiah.
- Transaksi dibuat melalui RPC `complete_sale` yang mengunci stok dan menyimpan transaksi/item/pembayaran/pergerakan stok/audit secara atomik.
- Diskon dibatasi untuk Admin di UI dan divalidasi ulang di RPC. Pajak dihitung ulang dari pengaturan toko di database, bukan mempercayai nilai pajak dari browser.
- Kasir hanya dapat membaca transaksi miliknya sendiri; Admin dapat membaca seluruh transaksi. Kasir tidak dapat menjalankan refund, mengelola produk, melihat laporan, atau mengubah pengaturan.
- Refund/pembatalan hanya Admin, hanya sekali, mengembalikan stok, dan menambahkan catatan pembalik.
- Produk yang sudah dipakai transaksi diarsipkan; bukan dihapus sehingga histori tidak rusak.
- Laba kotor hanya ditampilkan jika item transaksi memiliki snapshot harga modal. Transaksi lama yang dibuat sebelum migration dapat tetap menampilkan “—”. Laba bersih tidak ditampilkan karena biaya operasional belum dicatat.
- QRIS/Transfer/E-Wallet hanya dicatat sebagai metode pembayaran. Tidak ada payment gateway otomatis.
- Backup JSON menggabungkan/memulihkan data bisnis dan metadata profil berdasarkan ID. Password dan kredensial Auth tidak pernah dibackup; pemulihan profil hanya berlaku untuk user Auth yang sudah ada dan tidak mengubah profil Admin yang sedang login. File foto fisik tetap berada di Supabase Storage; backup JSON menyimpan URL foto, bukan menyalin binary foto.
- Mode demo menyimpan data pada browser/perangkat yang sama dan bukan untuk transaksi nyata atau multi-kasir.

## Catatan verifikasi

Source JSX sudah diperiksa parser TypeScript/JSX dan tes unit Node lulus. Instalasi dependency npm di lingkungan penyusunan mengalami timeout jaringan, sehingga build Vite penuh dan pengujian langsung terhadap project Supabase/Cloudflare belum dapat diklaim lulus. Setelah dependency dapat diunduh, jalankan `npm install` dan `npm run build` sebelum mengganti source production.

## Pembaruan desain mengikuti PRD

Antarmuka menggunakan enam gambar referensi di PRD sebagai acuan visual utama: sidebar espresso dengan ikon jangkar, header foto kopi, aksen caramel, panel cream/warm-white, dashboard ringkas, POS dua kolom (katalog + keranjang), serta tabel dan panel detail untuk produk, laporan, riwayat, dan pengaturan. Layout desktop memakai rail navigasi ramping; pada layar ponsel navigasi berubah menjadi drawer agar konten tetap terbaca dan tidak menimbulkan overflow horizontal. Seluruh perubahan visual berada di `src/style.css` dan tidak mengubah skema database atau konfigurasi Supabase.
