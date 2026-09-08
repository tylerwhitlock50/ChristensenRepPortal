/**
 * A deliberately small Markdown-to-HTML renderer for help articles.
 *
 * Supports exactly what an admin writing a how-to needs: `##`/`###`
 * headings, paragraphs, `-` bullets, `1.` numbered lists, **bold**,
 * *italic*, `code`, and [links](https://…). Nothing else — no raw HTML, no
 * images, no tables — so a pasted article cannot inject markup. Every
 * character is HTML-escaped before the inline rules run, and links are
 * limited to http(s), mailto and same-app paths.
 *
 * Kept here rather than pulling a Markdown library: the whole app has one
 * consumer of this, and the dependency would be larger than the page.
 */

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
}

function safeHref(url: string): string | null {
  const u = url.trim()
  if (/^(https?:\/\/|mailto:|\/)/i.test(u)) return u
  return null
}

function inline(text: string): string {
  let out = escapeHtml(text)
  // `code` first so its contents are not touched by the emphasis rules.
  out = out.replace(/`([^`]+)`/g, '<code>$1</code>')
  out = out.replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (_m, label: string, url: string) => {
    const href = safeHref(url)
    if (!href) return label
    const external = /^https?:\/\//i.test(href)
    return `<a href="${escapeHtml(href)}"${external ? ' target="_blank" rel="noopener"' : ''}>${label}</a>`
  })
  out = out.replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
  out = out.replace(/(^|[^*])\*([^*\n]+)\*(?!\*)/g, '$1<em>$2</em>')
  return out
}

export function renderMarkdown(source: string): string {
  const lines = (source ?? '').replace(/\r\n?/g, '\n').split('\n')
  const html: string[] = []
  let paragraph: string[] = []
  let list: { tag: 'ul' | 'ol'; items: string[] } | null = null

  const flushParagraph = () => {
    if (paragraph.length) {
      html.push(`<p>${paragraph.map(inline).join('<br>')}</p>`)
      paragraph = []
    }
  }
  const flushList = () => {
    if (list) {
      html.push(
        `<${list.tag}>${list.items.map((i) => `<li>${inline(i)}</li>`).join('')}</${list.tag}>`,
      )
      list = null
    }
  }

  for (const raw of lines) {
    const line = raw.trimEnd()
    if (!line.trim()) {
      flushParagraph()
      flushList()
      continue
    }
    const heading = /^(#{1,3})\s+(.*)$/.exec(line)
    if (heading) {
      flushParagraph()
      flushList()
      // # and ## both render as h3 inside a card; the page owns h1/h2.
      const level = heading[1].length >= 3 ? 4 : 3
      html.push(`<h${level}>${inline(heading[2])}</h${level}>`)
      continue
    }
    const bullet = /^\s*[-*]\s+(.*)$/.exec(line)
    if (bullet) {
      flushParagraph()
      if (!list || list.tag !== 'ul') {
        flushList()
        list = { tag: 'ul', items: [] }
      }
      list.items.push(bullet[1])
      continue
    }
    const numbered = /^\s*\d+[.)]\s+(.*)$/.exec(line)
    if (numbered) {
      flushParagraph()
      if (!list || list.tag !== 'ol') {
        flushList()
        list = { tag: 'ol', items: [] }
      }
      list.items.push(numbered[1])
      continue
    }
    flushList()
    paragraph.push(line.trim())
  }
  flushParagraph()
  flushList()
  return html.join('\n')
}
