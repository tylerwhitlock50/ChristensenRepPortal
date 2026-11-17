/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_SUPABASE_URL: string
  /** Publishable (anon) key. Public by design — RLS is the security boundary. */
  readonly VITE_SUPABASE_PUBLISHABLE_KEY: string
  /**
   * Optional. Extra addresses the OAuth consent screen (/oauth/consent) may
   * send an approval to, besides Claude's own callback and apps on the same
   * computer. Comma separated https URLs; a bare origin allows any path on
   * it. Leave unset unless another MCP client has to connect.
   */
  readonly VITE_MCP_OAUTH_REDIRECTS?: string
}

interface ImportMeta {
  readonly env: ImportMetaEnv
}
