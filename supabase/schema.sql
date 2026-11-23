-- Café Jangkar schema — jalankan di Supabase SQL Editor.
create extension if not exists pgcrypto;
create table if not exists public.profiles (
 id uuid primary key references auth.users(id) on delete cascade,
 full_name text not null default 'Pengguna', role text not null default 'Kasir' check (role in ('Admin','Kasir')),
 active boolean not null default true, created_at timestamptz not null default now()
);
create table if not exists public.store_settings (
 id boolean primary key default true check (id), name text not null default 'Café Jangkar', address text default '', phone text default '', email text default '', tagline text default '',
 tax_enabled boolean not null default false, tax_name text not null default 'PPN', tax_rate numeric(5,2) not null default 0 check(tax_rate between 0 and 100), min_stock integer not null default 5, receipt_width text not null default '58mm', updated_at timestamptz not null default now()
);
insert into public.store_settings(id) values(true) on conflict do nothing;
create table if not exists public.categories(id uuid primary key default gen_random_uuid(), name text unique not null, created_at timestamptz default now());
create table if not exists public.products (
 id uuid primary key default gen_random_uuid(), name text not null, sku text unique, category text not null default 'Minuman', price bigint not null check(price>=0), cost bigint check(cost is null or cost>=0), stock integer not null default 0 check(stock>=0), min_stock integer not null default 5 check(min_stock>=0), description text, image text, active boolean not null default true, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table if not exists public.transactions (
 id uuid primary key default gen_random_uuid(), transaction_number text unique not null, cashier_id uuid references auth.users(id), cashier_name text not null default '', subtotal bigint not null, discount bigint not null default 0, tax bigint not null default 0, total bigint not null, payment_method text not null check(payment_method in ('Tunai','QRIS','Transfer','E-Wallet')), amount_received bigint not null default 0, change_amount bigint not null default 0, status text not null default 'Selesai' check(status in ('Selesai','Refund','Dibatalkan')), created_at timestamptz not null default now()
);
create table if not exists public.transaction_items (
 id uuid primary key default gen_random_uuid(), transaction_id uuid not null references public.transactions(id) on delete restrict, product_id uuid references public.products(id), product_name text not null, unit_price bigint not null, quantity integer not null check(quantity>0), line_total bigint not null
);
create table if not exists public.stock_movements (
 id uuid primary key default gen_random_uuid(), product_id uuid not null references public.products(id), movement_type text not null check(movement_type in ('IN','OUT','SALE','REFUND','ADJUSTMENT')), quantity integer not null, reason text not null, actor_id uuid references auth.users(id), created_at timestamptz not null default now()
);
create table if not exists public.payments (
 id uuid primary key default gen_random_uuid(), transaction_id uuid not null references public.transactions(id), method text not null, amount bigint not null, reference text, created_at timestamptz not null default now()
);
create table if not exists public.audit_logs (
 id uuid primary key default gen_random_uuid(), actor_id uuid references auth.users(id), actor_name text, action text not null, detail jsonb not null default '{}', created_at timestamptz not null default now()
);
create index if not exists idx_transactions_created on public.transactions(created_at desc);
create index if not exists idx_transaction_items_tx on public.transaction_items(transaction_id);
create index if not exists idx_products_active on public.products(active);

create or replace function public.current_role() returns text language sql stable security definer set search_path=public as $$ select role from profiles where id=auth.uid() and active=true $$;
create or replace function public.is_admin() returns boolean language sql stable security definer set search_path=public as $$ select coalesce(public.current_role()='Admin',false) $$;

alter table public.profiles enable row level security;
alter table public.store_settings enable row level security;
alter table public.categories enable row level security;
alter table public.products enable row level security;
alter table public.transactions enable row level security;
alter table public.transaction_items enable row level security;
alter table public.stock_movements enable row level security;
alter table public.payments enable row level security;
alter table public.audit_logs enable row level security;

drop policy if exists "profile self or admin read" on profiles;
create policy "profile self or admin read" on profiles for select to authenticated using(id=auth.uid() or public.is_admin());
drop policy if exists "admin manage profiles" on profiles;
create policy "admin manage profiles" on profiles for all to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists "authenticated read settings" on store_settings;
create policy "authenticated read settings" on store_settings for select to authenticated using(true);
drop policy if exists "admin update settings" on store_settings;
create policy "admin update settings" on store_settings for all to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists "authenticated read products" on products;
create policy "authenticated read products" on products for select to authenticated using(true);
drop policy if exists "admin manage products" on products;
create policy "admin manage products" on products for all to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists "authenticated read categories" on categories;
create policy "authenticated read categories" on categories for select to authenticated using(true);
drop policy if exists "admin manage categories" on categories;
create policy "admin manage categories" on categories for all to authenticated using(public.is_admin()) with check(public.is_admin());
drop policy if exists "read transactions" on transactions;
create policy "read transactions" on transactions for select to authenticated using(public.current_role() in ('Admin','Kasir'));
drop policy if exists "read transaction items" on transaction_items;
create policy "read transaction items" on transaction_items for select to authenticated using(exists(select 1 from transactions t where t.id=transaction_id));
drop policy if exists "read stock movements" on stock_movements;
create policy "read stock movements" on stock_movements for select to authenticated using(public.is_admin());
drop policy if exists "read payments" on payments;
create policy "read payments" on payments for select to authenticated using(public.current_role() in ('Admin','Kasir'));
drop policy if exists "read audit logs" on audit_logs;
create policy "read audit logs" on audit_logs for select to authenticated using(public.is_admin());

-- Atomic checkout: row lock, stock validation, snapshots, payment + audit in one transaction.
create or replace function public.complete_sale(p_items jsonb,p_method text,p_discount bigint default 0,p_tax_rate numeric default 0,p_received bigint default 0)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_tx uuid; v_num text; v_sub bigint:=0; v_tax bigint:=0; v_total bigint:=0; v_change bigint:=0; v_item jsonb; v_product products%rowtype; v_qty int; v_role text; v_cashier text;
begin
 v_role:=public.current_role(); if v_role not in ('Admin','Kasir') then raise exception 'Akses ditolak'; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Keranjang kosong'; end if;
 for v_item in select * from jsonb_array_elements(p_items) loop
   v_qty:=(v_item->>'qty')::int; if v_qty<=0 then raise exception 'Jumlah tidak valid'; end if;
   select * into v_product from products where id=(v_item->>'product_id')::uuid and active=true for update;
   if not found then raise exception 'Produk tidak ditemukan'; end if;
   if v_product.stock<v_qty then raise exception 'Stok % tidak mencukupi',v_product.name; end if;
   v_sub:=v_sub+(v_product.price*v_qty);
 end loop;
 if p_discount<0 or p_discount>v_sub then raise exception 'Diskon tidak valid'; end if;
 v_tax:=round((v_sub-p_discount)*greatest(0,least(100,p_tax_rate))/100); v_total:=v_sub-p_discount+v_tax;
 if p_method='Tunai' and p_received<v_total then raise exception 'Uang diterima kurang'; end if;
 if p_method not in ('Tunai','QRIS','Transfer','E-Wallet') then raise exception 'Metode pembayaran tidak valid'; end if;
 v_change:=case when p_method='Tunai' then p_received-v_total else 0 end;
 v_num:='CJ-'||to_char(now(),'YYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
 select coalesce(full_name,'Kasir') into v_cashier from profiles where id=auth.uid();
 insert into transactions(transaction_number,cashier_id,cashier_name,subtotal,discount,tax,total,payment_method,amount_received,change_amount)
 values(v_num,auth.uid(),coalesce(v_cashier,'Kasir'),v_sub,p_discount,v_tax,v_total,p_method,case when p_method='Tunai' then p_received else v_total end,v_change) returning id into v_tx;
 for v_item in select * from jsonb_array_elements(p_items) loop
   v_qty:=(v_item->>'qty')::int; select * into v_product from products where id=(v_item->>'product_id')::uuid for update;
   insert into transaction_items(transaction_id,product_id,product_name,unit_price,quantity,line_total) values(v_tx,v_product.id,v_product.name,v_product.price,v_qty,v_product.price*v_qty);
   update products set stock=stock-v_qty,updated_at=now() where id=v_product.id;
   insert into stock_movements(product_id,movement_type,quantity,reason,actor_id) values(v_product.id,'SALE',-v_qty,'Penjualan '||v_num,auth.uid());
 end loop;
 insert into payments(transaction_id,method,amount) values(v_tx,p_method,v_total);
 insert into audit_logs(actor_id,actor_name,action,detail) values(auth.uid(),coalesce(v_cashier,'Kasir'),'TRANSACTION_COMPLETED',jsonb_build_object('transaction_number',v_num,'total',v_total));
 return jsonb_build_object('id',v_tx,'transaction_number',v_num,'subtotal',v_sub,'tax',v_tax,'total',v_total,'change',v_change);
end; $$;
grant execute on function public.complete_sale(jsonb,text,bigint,numeric,bigint) to authenticated;
