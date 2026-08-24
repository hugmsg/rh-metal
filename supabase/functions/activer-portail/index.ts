import "jsr:@supabase/functions-js/edge-runtime.d.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

// Crée un compte Supabase Auth pour un salarié (RH-Metal, chantier auth/portail
// 2026-08-24) et l'invite par email (email_perso) à définir son mot de passe.
// Nécessaire car la création d'un utilisateur Auth requiert la clé service_role
// (API Admin), inaccessible depuis une RPC SQL classique.
//
// Autorisation gérée à la main dans le code (verify_jwt=false au déploiement) :
// - Bootstrap : tant qu'aucun is_rh_admin n'a de compte lié, l'appel est autorisé
//   sans authentification (1ère activation, avant que quiconque ne soit connecté).
// - Ensuite : l'appelant doit fournir un Authorization: Bearer <jwt> valide,
//   résolu vers un employe avec is_rh_admin = true.
//
// Déployé via MCP Supabase (mcp__supabase__deploy_edge_function) — ce fichier
// est la copie source/traçabilité dans le repo, pas rejoué automatiquement au
// déploiement (même logique que supabase/migrations/).

const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: cors });

  try {
    const { employe_id } = await req.json();
    if (!employe_id) return json({ ok: false, message: "employe_id requis" }, 400);

    const supabaseAdmin = createClient(
      Deno.env.get("SUPABASE_URL")!,
      Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
    );

    const { count: adminCount } = await supabaseAdmin
      .from("employes")
      .select("id", { count: "exact", head: true })
      .eq("is_rh_admin", true)
      .not("auth_user_id", "is", null);

    if ((adminCount ?? 0) > 0) {
      const authHeader = req.headers.get("Authorization") || "";
      const jwt = authHeader.replace("Bearer ", "");
      const { data: { user } } = await supabaseAdmin.auth.getUser(jwt);
      if (!user) return json({ ok: false, message: "Non authentifié" }, 401);
      const { data: caller } = await supabaseAdmin
        .from("employes").select("is_rh_admin").eq("auth_user_id", user.id).single();
      if (!caller?.is_rh_admin) return json({ ok: false, message: "Réservé au RH" }, 403);
    }

    const { data: emp } = await supabaseAdmin
      .from("employes").select("id, email_perso, auth_user_id")
      .eq("id", employe_id).single();
    if (!emp) return json({ ok: false, message: "Salarié introuvable" }, 404);
    if (!emp.email_perso) return json({ ok: false, message: "Email personnel requis avant activation" }, 400);
    if (emp.auth_user_id) return json({ ok: false, message: "Accès déjà activé" }, 400);

    const { data: invited, error } = await supabaseAdmin.auth.admin.inviteUserByEmail(emp.email_perso);
    if (error || !invited?.user) return json({ ok: false, message: error?.message || "Échec invitation" }, 500);

    await supabaseAdmin.from("employes").update({ auth_user_id: invited.user.id }).eq("id", employe_id);

    return json({ ok: true }, 200);
  } catch (e) {
    return json({ ok: false, message: String(e) }, 500);
  }
});
