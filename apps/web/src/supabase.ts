import { createClient } from '@supabase/supabase-js'
import type { Database } from './types/database'

// Anon key only. The service-role key never goes in web code (CLAUDE.md §6.4).
// Supabase Auth keeps and refreshes the session itself.
export const supabase = createClient<Database>(
  import.meta.env.VITE_SUPABASE_URL,
  import.meta.env.VITE_SUPABASE_ANON_KEY,
)
