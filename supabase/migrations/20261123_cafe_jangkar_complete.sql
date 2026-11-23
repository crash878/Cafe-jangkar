-- Café Jangkar production completion migration
-- Run after the original schema.sql. RLS stays enabled.

-- Extra product metadata and storage bucket for product photos.
alter table public.profiles add column if not exists email text;
alter table public.store_settings add column if not exists logo_url text;
alter table public.transaction_items add column if not exists unit_cost bigint;
alter table public.transactions add column if not exists request_id uuid unique;
update public.profiles p set email=u.email from auth.users u where p.id=u.id and p.email is null;
alter table public.products add column if not exists description text;
alter table public.products add column if not exists image text;
alter table public.products add column if not exists updated_at timestamptz not null default now();
alter table public.products add column if not exists sku text;

insert into public.categories(name) values ('Minuman'),('Makanan'),('Snack'),('Dessert') on conflict(name) do nothing;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values ('cafe-products','cafe-products',true,5242880,array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public=true,file_size_limit=5242880,allowed_mime_types=array['image/jpeg','image/png','image/webp'];

drop policy if exists "public can view cafe product images" on storage.objects;
create policy "public can view cafe product images" on storage.objects for select using(bucket_id='cafe-products');
drop policy if exists "admins upload cafe product images" on storage.objects;
create policy "admins upload cafe product images" on storage.objects for insert to authenticated with check(bucket_id='cafe-products' and public.is_admin());
drop policy if exists "admins update cafe product images" on storage.objects;
create policy "admins update cafe product images" on storage.objects for update to authenticated using(bucket_id='cafe-products' and public.is_admin()) with check(bucket_id='cafe-products' and public.is_admin());
drop policy if exists "admins delete cafe product images" on storage.objects;
create policy "admins delete cafe product images" on storage.objects for delete to authenticated using(bucket_id='cafe-products' and public.is_admin());

-- Ensure table grants match the RLS policies. These grants do not bypass RLS.
grant select on public.products, public.categories, public.transactions,
 public.transaction_items, public.payments, public.store_settings to authenticated;
grant insert, update, delete on public.products, public.categories, public.store_settings to authenticated;
grant select on public.stock_movements, public.audit_logs, public.profiles to authenticated;

-- Stock adjustment is atomic and Admin-only.
create or replace function public.adjust_stock(p_product_id uuid,p_quantity integer,p_reason text,p_direction text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_product public.products%rowtype; v_delta integer; v_name text;
begin
 if not public.is_admin() then raise exception 'Hanya Admin yang boleh menyesuaikan stok'; end if;
 if p_quantity is null or p_quantity<=0 then raise exception 'Jumlah harus lebih dari nol'; end if;
 if length(trim(coalesce(p_reason,'')))<3 then raise exception 'Alasan penyesuaian wajib diisi'; end if;
 if p_direction not in ('IN','OUT') then raise exception 'Jenis penyesuaian tidak valid'; end if;
 select * into v_product from public.products where id=p_product_id for update;
 if not found then raise exception 'Produk tidak ditemukan'; end if;
 v_delta:=case when p_direction='IN' then p_quantity else -p_quantity end;
 if v_product.stock+v_delta<0 then raise exception 'Stok tidak mencukupi untuk pengurangan'; end if;
 update public.products set stock=stock+v_delta,updated_at=now() where id=p_product_id returning name into v_name;
 insert into public.stock_movements(product_id,movement_type,quantity,reason,actor_id)
 values(p_product_id,p_direction,v_delta,trim(p_reason),auth.uid());
 insert into public.audit_logs(actor_id,actor_name,action,detail)
 select auth.uid(),coalesce(full_name,'Admin'),'STOCK_ADJUSTED',jsonb_build_object('product_id',p_product_id,'product_name',v_name,'direction',p_direction,'quantity',p_quantity,'reason',trim(p_reason)) from public.profiles where id=auth.uid();
 return jsonb_build_object('product_id',p_product_id,'stock',v_product.stock+v_delta);
end; $$;
grant execute on function public.adjust_stock(uuid,integer,text,text) to authenticated;

-- Cancel/refund a completed transaction once and put its items back into stock.
create or replace function public.reverse_transaction(p_transaction_id uuid,p_reason text,p_status text default 'Refund')
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_tx public.transactions%rowtype; v_item record; v_cashier text;
begin
 if not public.is_admin() then raise exception 'Hanya Admin yang boleh membatalkan atau refund'; end if;
 if p_status not in ('Refund','Dibatalkan') then raise exception 'Status pembalik tidak valid'; end if;
 if length(trim(coalesce(p_reason,'')))<3 then raise exception 'Alasan wajib diisi'; end if;
 select * into v_tx from public.transactions where id=p_transaction_id for update;
 if not found then raise exception 'Transaksi tidak ditemukan'; end if;
 if v_tx.status<>'Selesai' then raise exception 'Transaksi ini sudah pernah diproses'; end if;
 for v_item in select product_id,product_name,quantity from public.transaction_items where transaction_id=v_tx.id loop
   if v_item.product_id is not null then
     update public.products set stock=stock+v_item.quantity,updated_at=now() where id=v_item.product_id;
     insert into public.stock_movements(product_id,movement_type,quantity,reason,actor_id)
     values(v_item.product_id,'REFUND',v_item.quantity, p_status||' transaksi '||v_tx.transaction_number||': '||trim(p_reason),auth.uid());
   end if;
 end loop;
 update public.transactions set status=p_status where id=v_tx.id;
 insert into public.payments(transaction_id,method,amount,reference)
 values(v_tx.id,v_tx.payment_method,-v_tx.total,'Pembalik: '||trim(p_reason));
 select coalesce(full_name,'Admin') into v_cashier from public.profiles where id=auth.uid();
 insert into public.audit_logs(actor_id,actor_name,action,detail)
 values(auth.uid(),coalesce(v_cashier,'Admin'),upper(p_status),jsonb_build_object('transaction_id',v_tx.id,'transaction_number',v_tx.transaction_number,'reason',trim(p_reason),'amount',v_tx.total));
 return jsonb_build_object('id',v_tx.id,'status',p_status);
end; $$;
grant execute on function public.reverse_transaction(uuid,text,text) to authenticated;

-- Admin-only full data snapshot. Auth users are intentionally not included; credentials are never backed up.
create or replace function public.restore_business_backup(p_backup jsonb)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_count integer:=0;
begin
 if not public.is_admin() then raise exception 'Hanya Admin yang boleh memulihkan backup'; end if;
 if coalesce(p_backup->>'app','')<>'cafe-jangkar' or coalesce(p_backup->>'version','')<>'1' then raise exception 'Format backup tidak dikenali'; end if;
 if jsonb_typeof(p_backup->'products')<>'array' or jsonb_typeof(p_backup->'categories')<>'array' or jsonb_typeof(p_backup->'transactions')<>'array' then raise exception 'Isi backup tidak lengkap'; end if;
 -- Validate and upsert store settings.
 if jsonb_typeof(p_backup->'store_settings')='object' then
   insert into public.store_settings(id,name,address,phone,email,tagline,tax_enabled,tax_name,tax_rate,min_stock,receipt_width,logo_url)
   values(true,coalesce(p_backup#>>'{store_settings,name}','Café Jangkar'),coalesce(p_backup#>>'{store_settings,address}',''),coalesce(p_backup#>>'{store_settings,phone}',''),coalesce(p_backup#>>'{store_settings,email}',''),coalesce(p_backup#>>'{store_settings,tagline}',''),coalesce((p_backup#>>'{store_settings,tax_enabled}')::boolean,false),coalesce(p_backup#>>'{store_settings,tax_name}','PPN'),coalesce((p_backup#>>'{store_settings,tax_rate}')::numeric,0),coalesce((p_backup#>>'{store_settings,min_stock}')::integer,5),coalesce(p_backup#>>'{store_settings,receipt_width}','58mm'),p_backup#>>'{store_settings,logo_url}')
   on conflict(id) do update set name=excluded.name,address=excluded.address,phone=excluded.phone,email=excluded.email,tagline=excluded.tagline,tax_enabled=excluded.tax_enabled,tax_name=excluded.tax_name,tax_rate=excluded.tax_rate,min_stock=excluded.min_stock,receipt_width=excluded.receipt_width,logo_url=excluded.logo_url;
 end if;
 -- Restore master data and transaction history by original IDs. Existing records are merged, not silently deleted.
 insert into public.categories(id,name) select (x->>'id')::uuid,x->>'name' from jsonb_array_elements(p_backup->'categories') x where x ? 'id' and x ? 'name' on conflict(id) do update set name=excluded.name;
 insert into public.products(id,name,sku,category,price,cost,stock,min_stock,description,image,active)
 select (x->>'id')::uuid,x->>'name',nullif(x->>'sku',''),coalesce(x->>'category','Minuman'),(x->>'price')::bigint,nullif(x->>'cost','')::bigint,coalesce((x->>'stock')::integer,0),coalesce((x->>'min_stock')::integer,5),x->>'description',x->>'image',coalesce((x->>'active')::boolean,true)
 from jsonb_array_elements(p_backup->'products') x where x ? 'id' and x ? 'name'
 on conflict(id) do update set name=excluded.name,sku=excluded.sku,category=excluded.category,price=excluded.price,cost=excluded.cost,stock=excluded.stock,min_stock=excluded.min_stock,description=excluded.description,image=excluded.image,active=excluded.active,updated_at=now();
 get diagnostics v_count=row_count;
 -- Restore profile metadata only for Auth users that already exist in this Supabase project.
 -- Never restore passwords or Auth credentials, and never change the currently logged-in Admin.
 insert into public.profiles(id,full_name,email,role,active)
 select (x->>'id')::uuid,coalesce(x->>'full_name','Pengguna'),x->>'email',coalesce(x->>'role','Kasir'),coalesce((x->>'active')::boolean,true)
 from jsonb_array_elements(coalesce(p_backup->'profiles','[]'::jsonb)) x
 where x ? 'id' and (x->>'id')::uuid<>auth.uid() and exists(select 1 from auth.users au where au.id=(x->>'id')::uuid)
 on conflict(id) do update set full_name=excluded.full_name,email=excluded.email,role=excluded.role,active=excluded.active;
 -- Restore transaction history and its immutable item/payment snapshots by original IDs.
 insert into public.transactions(id,transaction_number,cashier_id,cashier_name,subtotal,discount,tax,total,payment_method,amount_received,change_amount,status,created_at)
 select (x->>'id')::uuid,x->>'transaction_number',case when nullif(x->>'cashier_id','') is not null and exists(select 1 from auth.users au where au.id=(x->>'cashier_id')::uuid) then (x->>'cashier_id')::uuid else null end,coalesce(x->>'cashier_name',''),(x->>'subtotal')::bigint,coalesce((x->>'discount')::bigint,0),coalesce((x->>'tax')::bigint,0),(x->>'total')::bigint,x->>'payment_method',coalesce((x->>'amount_received')::bigint,0),coalesce((x->>'change_amount')::bigint,0),coalesce(x->>'status','Selesai'),coalesce((x->>'created_at')::timestamptz,now())
 from jsonb_array_elements(coalesce(p_backup->'transactions','[]'::jsonb)) x where x ? 'id' and x ? 'transaction_number'
 on conflict(id) do update set transaction_number=excluded.transaction_number,cashier_name=excluded.cashier_name,subtotal=excluded.subtotal,discount=excluded.discount,tax=excluded.tax,total=excluded.total,payment_method=excluded.payment_method,amount_received=excluded.amount_received,change_amount=excluded.change_amount,status=excluded.status,created_at=excluded.created_at;
 insert into public.transaction_items(id,transaction_id,product_id,product_name,unit_price,unit_cost,quantity,line_total)
 select (x->>'id')::uuid,(x->>'transaction_id')::uuid,nullif(x->>'product_id','')::uuid,x->>'product_name',(x->>'unit_price')::bigint,nullif(x->>'unit_cost','')::bigint,(x->>'quantity')::integer,(x->>'line_total')::bigint
 from jsonb_array_elements(coalesce(p_backup->'transaction_items','[]'::jsonb)) x where x ? 'id' and x ? 'transaction_id'
 on conflict(id) do update set transaction_id=excluded.transaction_id,product_id=excluded.product_id,product_name=excluded.product_name,unit_price=excluded.unit_price,unit_cost=excluded.unit_cost,quantity=excluded.quantity,line_total=excluded.line_total;
 insert into public.payments(id,transaction_id,method,amount,reference,created_at)
 select (x->>'id')::uuid,(x->>'transaction_id')::uuid,x->>'method',(x->>'amount')::bigint,x->>'reference',coalesce((x->>'created_at')::timestamptz,now())
 from jsonb_array_elements(coalesce(p_backup->'payments','[]'::jsonb)) x where x ? 'id' and x ? 'transaction_id'
 on conflict(id) do update set transaction_id=excluded.transaction_id,method=excluded.method,amount=excluded.amount,reference=excluded.reference,created_at=excluded.created_at;
 insert into public.stock_movements(id,product_id,movement_type,quantity,reason,actor_id,created_at)
 select (x->>'id')::uuid,(x->>'product_id')::uuid,x->>'movement_type',(x->>'quantity')::integer,x->>'reason',case when nullif(x->>'actor_id','') is not null and exists(select 1 from auth.users au where au.id=(x->>'actor_id')::uuid) then (x->>'actor_id')::uuid else null end,coalesce((x->>'created_at')::timestamptz,now())
 from jsonb_array_elements(coalesce(p_backup->'stock_movements','[]'::jsonb)) x where x ? 'id' and x ? 'product_id'
 on conflict(id) do nothing;
 insert into public.audit_logs(id,actor_id,actor_name,action,detail,created_at)
 select (x->>'id')::uuid,case when nullif(x->>'actor_id','') is not null and exists(select 1 from auth.users au where au.id=(x->>'actor_id')::uuid) then (x->>'actor_id')::uuid else null end,coalesce(x->>'actor_name','Backup restore'),x->>'action',coalesce(x->'detail','{}'::jsonb),coalesce((x->>'created_at')::timestamptz,now())
 from jsonb_array_elements(coalesce(p_backup->'audit_logs','[]'::jsonb)) x where x ? 'id' and x ? 'action'
 on conflict(id) do nothing;
 insert into public.audit_logs(actor_id,actor_name,action,detail)
 select auth.uid(),coalesce(full_name,'Admin'),'BACKUP_RESTORED',jsonb_build_object('products_restored',v_count) from public.profiles where id=auth.uid();
 return jsonb_build_object('products_restored',v_count,'historical_transactions_restored',true);
end; $$;
grant execute on function public.restore_business_backup(jsonb) to authenticated;

-- Profiles may be read by Admin; the Edge Function performs Auth user creation securely.
drop policy if exists "admin manage profiles" on public.profiles;
create policy "admin manage profiles" on public.profiles for all to authenticated using(public.is_admin()) with check(public.is_admin());

drop policy if exists "admin insert stock movements" on public.stock_movements;
create policy "admin insert stock movements" on public.stock_movements for insert to authenticated with check(public.is_admin());
drop policy if exists "authenticated create audit entries" on public.audit_logs;
create policy "authenticated create audit entries" on public.audit_logs for insert to authenticated with check(actor_id=auth.uid());

-- Replace checkout RPC with explicit Admin-only discount authorization.
drop function if exists public.complete_sale(jsonb,text,bigint,numeric,bigint);
create or replace function public.complete_sale(p_items jsonb,p_method text,p_discount bigint,p_tax_rate numeric,p_received bigint,p_request_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_tx uuid; v_num text; v_sub bigint:=0; v_tax bigint:=0; v_total bigint:=0; v_change bigint:=0; v_item jsonb; v_product public.products%rowtype; v_qty int; v_role text; v_cashier text; v_existing public.transactions%rowtype; v_tax_enabled boolean:=false; v_configured_tax numeric:=0;
begin
 v_role:=public.current_role(); if v_role not in ('Admin','Kasir') then raise exception 'Akses ditolak'; end if;
 if p_request_id is null then raise exception 'ID permintaan transaksi wajib diisi'; end if;
 select * into v_existing from public.transactions where request_id=p_request_id;
 if found then if v_existing.cashier_id is distinct from auth.uid() and v_role<>'Admin' then raise exception 'Akses ditolak'; end if; return jsonb_build_object('id',v_existing.id,'transaction_number',v_existing.transaction_number,'subtotal',v_existing.subtotal,'tax',v_existing.tax,'total',v_existing.total,'change',v_existing.change_amount,'duplicate',true); end if;
 if p_discount>0 and v_role<>'Admin' then raise exception 'Diskon hanya dapat diberikan oleh Admin'; end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'Keranjang kosong'; end if;
 for v_item in select * from jsonb_array_elements(p_items) loop
   v_qty:=(v_item->>'qty')::int; if v_qty<=0 then raise exception 'Jumlah tidak valid'; end if;
   select * into v_product from public.products where id=(v_item->>'product_id')::uuid and active=true for update;
   if not found then raise exception 'Produk tidak ditemukan'; end if;
   if v_product.stock<v_qty then raise exception 'Stok % tidak mencukupi',v_product.name; end if;
   v_sub:=v_sub+(v_product.price*v_qty);
 end loop;
 if p_discount<0 or p_discount>v_sub then raise exception 'Diskon tidak valid'; end if;
 select tax_enabled,tax_rate into v_tax_enabled,v_configured_tax from public.store_settings where id=true;
 v_tax:=round((v_sub-p_discount)*case when coalesce(v_tax_enabled,false) then greatest(0,least(100,coalesce(v_configured_tax,0))) else 0 end/100); v_total:=v_sub-p_discount+v_tax;
 if p_method='Tunai' and p_received<v_total then raise exception 'Uang diterima kurang'; end if;
 if p_method not in ('Tunai','QRIS','Transfer','E-Wallet') then raise exception 'Metode pembayaran tidak valid'; end if;
 v_change:=case when p_method='Tunai' then p_received-v_total else 0 end;
 v_num:='CJ-'||to_char(now(),'YYMMDD')||'-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,6));
 select coalesce(full_name,'Kasir') into v_cashier from public.profiles where id=auth.uid();
 insert into public.transactions(transaction_number,cashier_id,cashier_name,subtotal,discount,tax,total,payment_method,amount_received,change_amount,request_id)
 values(v_num,auth.uid(),coalesce(v_cashier,'Kasir'),v_sub,p_discount,v_tax,v_total,p_method,case when p_method='Tunai' then p_received else v_total end,v_change,p_request_id) returning id into v_tx;
 for v_item in select * from jsonb_array_elements(p_items) loop
   v_qty:=(v_item->>'qty')::int; select * into v_product from public.products where id=(v_item->>'product_id')::uuid for update;
   insert into public.transaction_items(transaction_id,product_id,product_name,unit_price,unit_cost,quantity,line_total) values(v_tx,v_product.id,v_product.name,v_product.price,v_product.cost,v_qty,v_product.price*v_qty);
   update public.products set stock=stock-v_qty,updated_at=now() where id=v_product.id;
   insert into public.stock_movements(product_id,movement_type,quantity,reason,actor_id) values(v_product.id,'SALE',-v_qty,'Penjualan '||v_num,auth.uid());
 end loop;
 insert into public.payments(transaction_id,method,amount) values(v_tx,p_method,v_total);
 insert into public.audit_logs(actor_id,actor_name,action,detail) values(auth.uid(),coalesce(v_cashier,'Kasir'),'TRANSACTION_COMPLETED',jsonb_build_object('transaction_number',v_num,'total',v_total,'discount',p_discount));
 return jsonb_build_object('id',v_tx,'transaction_number',v_num,'subtotal',v_sub,'tax',v_tax,'total',v_total,'change',v_change);
end; $$;
grant execute on function public.complete_sale(jsonb,text,bigint,numeric,bigint,uuid) to authenticated;
grant insert on public.stock_movements, public.audit_logs to authenticated;

-- Backward-compatible wrapper for an already-open old frontend during automatic deployment.
-- The new frontend always supplies p_request_id and uses the idempotent six-argument function.
create or replace function public.complete_sale(p_items jsonb,p_method text,p_discount bigint default 0,p_tax_rate numeric default 0,p_received bigint default 0)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
 return public.complete_sale(p_items,p_method,p_discount,p_tax_rate,p_received,gen_random_uuid());
end; $$;
grant execute on function public.complete_sale(jsonb,text,bigint,numeric,bigint) to authenticated;

-- Cashiers can read only their own sales; Admin can read all sales.
drop policy if exists "read transactions" on public.transactions;
create policy "read transactions" on public.transactions for select to authenticated
using (public.is_admin() or cashier_id=auth.uid());
drop policy if exists "read transaction items" on public.transaction_items;
create policy "read transaction items" on public.transaction_items for select to authenticated
using (exists(select 1 from public.transactions t where t.id=transaction_id and (public.is_admin() or t.cashier_id=auth.uid())));
drop policy if exists "read payments" on public.payments;
create policy "read payments" on public.payments for select to authenticated
using (exists(select 1 from public.transactions t where t.id=transaction_id and (public.is_admin() or t.cashier_id=auth.uid())));
