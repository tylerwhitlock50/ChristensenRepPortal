/**
 * Links to help articles that live outside the Help page itself.
 *
 * The slug is a contract with the database: help article
 * 'portal-vs-tableau-numbers' is seeded by 20261027090700. Sales Intel links
 * to it in-app; the new-user login email and the "not signed in yet"
 * reminder link to it by URL, for reps coming off Tableau.
 */
export const TABLEAU_ARTICLE_SLUG = 'portal-vs-tableau-numbers'

/**
 * An absolute link to the "Why the portal and Tableau numbers differ"
 * article, for an email. Signed out, the router sends the reader to /login
 * with ?redirect, so they land on the article after signing in.
 */
export function tableauArticleUrl(portalUrl: string): string {
  return `${portalUrl.replace(/\/+$/, '')}/help?article=${TABLEAU_ARTICLE_SLUG}`
}
