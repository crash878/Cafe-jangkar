import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return new Response(JSON.stringify({ error: 'Method not allowed' }), { status: 405, headers: { ...cors, 'Content-Type': 'application/json' } });

  const url = Deno.env.get('SUPABASE_URL')!;
  const anon = Deno.env.get('SUPABASE_ANON_KEY')!;
  const service = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const authHeader = req.headers.get('Authorization') ?? '';
  const callerClient = createClient(url, anon, { global: { headers: { Authorization: authHeader } } });
  const { data: { user: caller }, error: callerError } = await callerClient.auth.getUser();
  if (callerError || !caller) return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401, headers: { ...cors, 'Content-Type': 'application/json' } });

  const adminClient = createClient(url, service, { auth: { autoRefreshToken: false, persistSession: false } });
  const { data: profile, error: profileError } = await adminClient.from('profiles').select('role,active').eq('id', caller.id).single();
  if (profileError || profile?.role !== 'Admin' || !profile.active) return new Response(JSON.stringify({ error: 'Admin access required' }), { status: 403, headers: { ...cors, 'Content-Type': 'application/json' } });

  try {
    const body = await req.json();
    if (body.action === 'create') {
      const email = String(body.email ?? '').trim().toLowerCase();
      const full_name = String(body.full_name ?? '').trim();
      const role = body.role === 'Admin' ? 'Admin' : 'Kasir';
      if (!email || !full_name) throw new Error('Nama dan email wajib diisi.');
      const { data, error } = await adminClient.auth.admin.inviteUserByEmail(email, { data: { full_name } });
      if (error) throw error;
      const { error: insertError } = await adminClient.from('profiles').upsert({ id: data.user.id, full_name, email, role, active: true });
      if (insertError) {
        await adminClient.auth.admin.deleteUser(data.user.id);
        throw insertError;
      }
      await adminClient.from('audit_logs').insert({ actor_id: caller.id, actor_name: 'Admin', action: 'USER_CREATED', detail: { email, role, full_name } });
      return new Response(JSON.stringify({ success: true, message: 'Undangan akun telah dikirim.' }), { headers: { ...cors, 'Content-Type': 'application/json' } });
    }
    if (body.action === 'set-role') {
      const userId = String(body.user_id ?? '');
      const role = body.role === 'Admin' ? 'Admin' : body.role === 'Kasir' ? 'Kasir' : '';
      if (!userId || !role || userId === caller.id) throw new Error('Role tidak valid atau tidak dapat mengubah role akun sendiri.');
      const { error } = await adminClient.from('profiles').update({ role }).eq('id', userId);
      if (error) throw error;
      await adminClient.from('audit_logs').insert({ actor_id: caller.id, actor_name: 'Admin', action: 'USER_ROLE_CHANGED', detail: { user_id: userId, role } });
      return new Response(JSON.stringify({ success: true, message: 'Role pengguna diperbarui.' }), { headers: { ...cors, 'Content-Type': 'application/json' } });
    }
    if (body.action === 'deactivate' || body.action === 'activate') {
      const userId = String(body.user_id ?? '');
      if (!userId || userId === caller.id) throw new Error('Akun sendiri tidak dapat dinonaktifkan dari sini.');
      const active = body.action === 'activate';
      const { error } = await adminClient.from('profiles').update({ active }).eq('id', userId);
      if (error) throw error;
      await adminClient.auth.admin.updateUserById(userId, { ban_duration: active ? 'none' : '876000h' });
      await adminClient.from('audit_logs').insert({ actor_id: caller.id, actor_name: 'Admin', action: active ? 'USER_ACTIVATED' : 'USER_DEACTIVATED', detail: { user_id: userId } });
      return new Response(JSON.stringify({ success: true, message: active ? 'Akun diaktifkan.' : 'Akun dinonaktifkan.' }), { headers: { ...cors, 'Content-Type': 'application/json' } });
    }
    throw new Error('Aksi tidak dikenal.');
  } catch (error) {
    return new Response(JSON.stringify({ error: error instanceof Error ? error.message : 'Terjadi kesalahan.' }), { status: 400, headers: { ...cors, 'Content-Type': 'application/json' } });
  }
});
