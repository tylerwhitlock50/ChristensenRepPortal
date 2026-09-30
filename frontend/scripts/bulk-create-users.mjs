#!/usr/bin/env node
/*============================================================================
  bulk-create-users.mjs — one-off bulk rep onboarding.

  Reads a CSV (id, name, company_name, email) and creates one portal user per
  row by calling the admin-create-user Edge Function as a signed-in admin.
  Nothing here touches service_role: the function re-checks is_admin() and
  applies every guard the Admin → Users form gets (placeholder rep codes,
  password floor, rollback on profile failure).

    id            → profiles.sales_rep_key   (the ERP rep code, verbatim)
    name          → profiles.full_name
    email         → auth email (lower-cased)
    company_name  → ignored; the rep group comes from erp.dim_sales_rep

  Every user is created as role 'rep' with NO rep_group_vendor_id. Flip a
  principal on afterwards in Admin → Users if someone should see the whole
  agency book.

  Usage (from frontend/):
    node scripts/bulk-create-users.mjs <path-to.csv> [--dry-run]

  Env:
    VITE_SUPABASE_URL / VITE_SUPABASE_PUBLISHABLE_KEY  read from .env.local
    ADMIN_EMAIL      optional; prompted if missing
    ADMIN_PASSWORD   optional; prompted (hidden) if missing
    TEMP_PASSWORD    optional; prompted (hidden) if missing. Never hard-code
                     it here — this file is committed.
============================================================================*/

import { readFileSync, existsSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { createInterface } from 'node:readline'
import { createClient, FunctionsHttpError } from '@supabase/supabase-js'

const MIN_PASSWORD_LENGTH = 12

const here = dirname(fileURLToPath(import.meta.url))
const frontendDir = resolve(here, '..')

/*--------------------------------------------------------------- args ---*/
const args = process.argv.slice(2)
const dryRun = args.includes('--dry-run')
const csvPath = args.find((a) => !a.startsWith('--'))
if (!csvPath) {
  console.error('usage: node scripts/bulk-create-users.mjs <file.csv> [--dry-run]')
  process.exit(2)
}
if (!existsSync(csvPath)) {
  console.error(`CSV not found: ${csvPath}`)
  process.exit(2)
}

/*---------------------------------------------------------------- env ---*/
function loadDotEnv(file) {
  if (!existsSync(file)) return
  for (const raw of readFileSync(file, 'utf8').split(/\r?\n/)) {
    const line = raw.trim()
    if (!line || line.startsWith('#')) continue
    const eq = line.indexOf('=')
    if (eq < 0) continue
    const k = line.slice(0, eq).trim()
    let v = line.slice(eq + 1).trim()
    if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) {
      v = v.slice(1, -1)
    }
    if (process.env[k] === undefined) process.env[k] = v
  }
}
loadDotEnv(resolve(frontendDir, '.env.local'))
loadDotEnv(resolve(frontendDir, '.env'))

const supabaseUrl = process.env.VITE_SUPABASE_URL
const supabaseKey = process.env.VITE_SUPABASE_PUBLISHABLE_KEY
if (!supabaseUrl || !supabaseKey) {
  console.error('Missing VITE_SUPABASE_URL / VITE_SUPABASE_PUBLISHABLE_KEY (frontend/.env.local).')
  process.exit(2)
}

/*---------------------------------------------------------------- csv ---*/
function parseCsv(text) {
  const lines = text.split(/\r?\n/)
  const rows = []
  const problems = []
  let header = null

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]
    if (!line.trim()) continue
    const delim = line.includes('\t') ? '\t' : ','
    const cells = line.split(delim).map((c) => c.trim().replace(/^"|"$/g, ''))

    // The pasted sheet repeats its header once per group — accept it anywhere.
    if (cells[0]?.toLowerCase() === 'id') {
      header = cells.map((c) => c.toLowerCase())
      continue
    }
    if (!header) {
      problems.push(`line ${i + 1}: data before a header row`)
      continue
    }
    const rec = Object.fromEntries(header.map((h, j) => [h, cells[j] ?? '']))
    if (!rec.id && !rec.email && !rec.name) continue // blank spacer row
    rows.push({ line: i + 1, ...rec })
  }
  return { rows, problems }
}

const { rows, problems } = parseCsv(readFileSync(csvPath, 'utf8'))

const emailRe = /^[^\s@]+@[^\s@]+\.[^\s@]+$/
const seenEmail = new Set()
const seenKey = new Set()
const plan = []
for (const r of rows) {
  const email = (r.email ?? '').toLowerCase()
  const key = (r.id ?? '').trim()
  const name = (r.name ?? '').trim()
  const errs = []
  if (!emailRe.test(email)) errs.push('bad email')
  if (!key) errs.push('missing id (rep code)')
  if (!name) errs.push('missing name')
  if (seenEmail.has(email)) errs.push('duplicate email in file')
  if (seenKey.has(key)) errs.push('duplicate rep code in file')
  seenEmail.add(email)
  seenKey.add(key)
  plan.push({ line: r.line, email, key, name, company: r.company_name ?? '', errs })
}

console.log(`\nParsed ${plan.length} row(s) from ${csvPath}`)
for (const p of problems) console.log(`  ! ${p}`)
console.table(
  plan.map((p) => ({
    line: p.line,
    rep_code: p.key,
    full_name: p.name,
    email: p.email,
    company: p.company,
    issues: p.errs.join('; ') || '',
  })),
)

const invalid = plan.filter((p) => p.errs.length)
if (invalid.length) {
  console.error(`\n${invalid.length} row(s) have problems — fix the CSV and rerun.`)
  process.exit(1)
}
if (dryRun) {
  console.log('\n--dry-run: nothing created.')
  process.exit(0)
}

/*------------------------------------------------------------ prompts ---*/
function ask(question, { hidden = false } = {}) {
  return new Promise((res) => {
    const rl = createInterface({ input: process.stdin, output: process.stdout, terminal: true })
    if (hidden) {
      // Mute echo while the password is typed.
      const origWrite = rl._writeToOutput
      rl._writeToOutput = function (s) {
        if (s.includes(question)) origWrite.call(rl, question)
      }
    }
    rl.question(question, (answer) => {
      rl.close()
      if (hidden) process.stdout.write('\n')
      res(answer.trim())
    })
  })
}

const adminEmail = process.env.ADMIN_EMAIL || (await ask('Admin email: '))
const adminPassword = process.env.ADMIN_PASSWORD || (await ask('Admin password: ', { hidden: true }))
const tempPassword =
  process.env.TEMP_PASSWORD ||
  (await ask('Temporary password for the new users: ', { hidden: true }))
if (tempPassword.length < MIN_PASSWORD_LENGTH) {
  console.error(`Temporary password must be at least ${MIN_PASSWORD_LENGTH} characters.`)
  process.exit(2)
}

/*------------------------------------------------------------- create ---*/
const supabase = createClient(supabaseUrl, supabaseKey, {
  auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
})

const signIn = await supabase.auth.signInWithPassword({ email: adminEmail, password: adminPassword })
if (signIn.error) {
  console.error(`Sign-in failed: ${signIn.error.message}`)
  process.exit(1)
}

async function functionError(error) {
  if (error instanceof FunctionsHttpError) {
    try {
      const body = await error.context.json()
      if (body?.error?.code) return `${body.error.code}: ${body.error.message}`
    } catch {
      /* not JSON */
    }
  }
  return error?.message ?? 'unknown error'
}

console.log(`\nCreating ${plan.length} user(s) as ${adminEmail} — role 'rep', temp password set.\n`)
const results = []
for (const p of plan) {
  const { data, error } = await supabase.functions.invoke('admin-create-user', {
    body: {
      email: p.email,
      password: tempPassword,
      full_name: p.name,
      role: 'rep',
      sales_rep_key: p.key,
      rep_group_vendor_id: null,
      active: true,
    },
  })
  if (error) {
    const msg = await functionError(error)
    results.push({ email: p.email, rep_code: p.key, status: 'FAILED', detail: msg })
    console.log(`  x ${p.email}  ${msg}`)
    continue
  }
  const warn = (data?.warnings ?? []).join(' | ')
  results.push({ email: p.email, rep_code: p.key, status: 'created', detail: warn || data?.user_id })
  console.log(`  + ${p.email}  ${data?.user_id}${warn ? `  (warning: ${warn})` : ''}`)
}

await supabase.auth.signOut({ scope: 'local' })

console.log('')
console.table(results)
const failed = results.filter((r) => r.status !== 'created').length
console.log(`\n${results.length - failed} created, ${failed} failed.`)
process.exit(failed ? 1 : 0)
