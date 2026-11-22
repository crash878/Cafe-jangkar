# Café Jangkar — POS & Operasional Café

Aplikasi React + Vite dengan tema espresso/cream/caramel. Target hosting frontend: Netlify. Backend cloud: Supabase (Postgres + Auth + RLS + RPC).

## Status dan batasan yang wajib diketahui

- Frontend dan mode demo lokal tersedia. Mode demo menyimpan data di browser perangkat yang sama; bukan database bersama dan tidak boleh dipakai sebagai catatan transaksi resmi multi-kasir.
- Mode cloud memerlukan project Supabase milik pemilik café, menjalankan `supabase/schema.sql`, membuat akun Auth dan baris `profiles` untuk setiap pengguna, serta mengisi environment variables Netlify.
- Login cloud membaca role dari `profiles`; user tanpa profile aktif akan ditolak. Pembuatan akun pegawai belum disediakan dari UI karena pembuatan user Auth yang aman membutuhkan Supabase Edge Function dengan service-role key (key ini tidak boleh diletakkan di frontend).
- Pembayaran QRIS/Transfer/E-Wallet hanya dicatat sebagai metode. Tidak ada payment gateway otomatis.
- Refund, upload gambar ke Supabase Storage, pengelolaan akun dari UI, laporan Excel, dan audit/backup cloud lintas tabel belum diimplementasikan sepenuhnya. Backup JSON di UI adalah backup mode browser.
- Build harus diverifikasi di lingkungan yang dapat mengunduh npm packages. `npm install` pada lingkungan pembuatan sempat timeout; jangan anggap build sudah lolos sebelum Netlify menampilkan deploy sukses.

## Menjalankan lokal

Persyaratan: Node.js 22 atau lebih baru.

```bash
npm install
npm run dev
```

## Deploy frontend ke Netlify lewat GitHub

Upload seluruh isi folder proyek ini ke root repository (jangan membungkusnya dengan folder tambahan). Netlify build settings:

- Base directory: kosong
- Build command: `npm run build`
- Publish directory: `dist`
- Node: 22 (`.nvmrc` dan `netlify.toml`)

Netlify environment variables untuk mode cloud:

- `VITE_SUPABASE_URL` = Project URL dari Supabase
- `VITE_SUPABASE_ANON_KEY` = anon/public key dari Supabase

Setelah menambahkan/mengubah environment variables, trigger redeploy. Jangan pernah memasukkan `service_role` key ke Netlify frontend variables atau source code.

## Menyiapkan Supabase (wajib dilakukan pemilik)

1. Buat project di https://supabase.com/ (Free Plan memiliki kuota dan batas penggunaan; cek dashboard Supabase untuk kuota terbaru).
2. Buka SQL Editor dan jalankan seluruh `supabase/schema.sql`.
3. Buka Authentication → Users → Add user, buat akun Admin dengan email/password milik café.
4. Setelah user dibuat, ambil UUID user dari Authentication → Users. Jalankan SQL berikut dengan UUID dan nama yang benar:

```sql
insert into public.profiles (id, full_name, role, active)
values ('UUID_USER_DARI_AUTH', 'Admin Café', 'Admin', true)
on conflict (id) do update
set full_name = excluded.full_name, role = excluded.role, active = true;
```

5. Buat akun kasir dari Authentication → Users, lalu buat baris profile dengan role `Kasir` memakai UUID kasir:

```sql
insert into public.profiles (id, full_name, role, active)
values ('UUID_KASIR_DARI_AUTH', 'Nama Kasir', 'Kasir', true)
on conflict (id) do update
set full_name = excluded.full_name, role = excluded.role, active = true;
```

6. Isi environment variables di Netlify seperti di atas dan redeploy.
7. Uji login Admin dan Kasir. Pastikan Kasir tidak dapat membuka menu Admin. Uji transaksi nominal kecil dan pastikan stok turun sekali serta riwayat muncul.

## Catatan data awal

Mode demo menyediakan katalog contoh dan semua itu bukan data riil. Database Supabase baru tidak otomatis diisi produk demo; Admin perlu memasukkan produk café sendiri setelah login.

## Keamanan dan operasional

- Jangan gunakan akun demo kosong untuk data nyata.
- Simpan password Admin dengan aman dan aktifkan MFA bila tersedia.
- RLS dan fungsi `complete_sale` pada schema menangani otorisasi dan transaksi atomik dasar. Audit keamanan dan uji konkurensi tetap diperlukan sebelum operasional penuh.
- Buat backup database dari Supabase secara berkala; backup JSON browser bukan pengganti backup database server.
