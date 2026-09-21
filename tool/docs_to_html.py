# Turn the two MyEmail documents into self-contained HTML pages.
#
# Deliberately narrow: it handles exactly what those files use — headings,
# paragraphs, bullet and numbered lists, tables, rules, and inline bold,
# code and links. A general Markdown library would be another dependency
# on a machine that has none, for two known files.
#
# Nothing is fetched: no web fonts, no scripts from anywhere. The pages
# are opened from a synced folder on a tablet that may be offline, so
# everything they need is inside them.
import io, os, re, html

SRC = r'C:\Users\Ron\OneDrive\AI Projects\Email client'

PHONE_ICON = ('<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="7" y="2.5" width="10" '
              'height="19" rx="2.2"/><line x1="10.5" y1="18.6" x2="13.5" y2="18.6"/></svg>')
TABLET_ICON = ('<svg viewBox="0 0 24 24" aria-hidden="true"><rect x="3.5" y="4" width="17" '
               'height="16" rx="2.2"/><line x1="17.6" y1="12" x2="17.6" y2="12.1"/></svg>')

TEMPLATE = """<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<style>
  :root {{
    color-scheme: light dark;
    --bg: #fbfbfd;
    --card: #ffffff;
    --fg: #1a1a1f;
    --muted: #63636e;
    --faint: #8b8b96;
    --rule: #e4e4ec;
    --accent: #2f5ea8;
    --accent-soft: #eaf0fb;
    --chip: #f1f2f7;
    --shadow: 0 1px 2px rgba(16, 20, 40, .06), 0 8px 24px rgba(16, 20, 40, .05);
  }}
  @media (prefers-color-scheme: dark) {{
    :root {{
      --bg: #0f1013;
      --card: #17181d;
      --fg: #e8e6ea;
      --muted: #a6a4ad;
      --faint: #85838d;
      --rule: #2b2c34;
      --accent: #9dc0ff;
      --accent-soft: #1b2435;
      --chip: #212229;
      --shadow: 0 1px 2px rgba(0, 0, 0, .4), 0 10px 30px rgba(0, 0, 0, .35);
    }}
  }}
  * {{ box-sizing: border-box; }}
  html {{ scroll-behavior: smooth; }}
  body {{
    margin: 0;
    background: var(--bg);
    color: var(--fg);
    font: 16.5px/1.65 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto,
          "Helvetica Neue", Arial, sans-serif;
    -webkit-text-size-adjust: 100%;
  }}

  /* The cover band */
  header.cover {{
    background:
      radial-gradient(120% 140% at 8% 0%, var(--accent-soft) 0%, transparent 60%),
      var(--card);
    border-bottom: 1px solid var(--rule);
  }}
  .cover-inner {{ max-width: 62rem; margin: 0 auto; padding: 3rem 1.25rem 2.25rem; }}
  .eyebrow {{
    font-size: .74rem; letter-spacing: .16em; text-transform: uppercase;
    color: var(--accent); font-weight: 700; margin: 0 0 .6rem;
  }}
  .cover h1 {{
    font-size: clamp(1.9rem, 5vw, 2.7rem); line-height: 1.12;
    margin: 0 0 .5rem; letter-spacing: -.025em; font-weight: 700;
  }}
  .cover .lede {{ color: var(--muted); margin: 0; max-width: 34rem; font-size: 1.04rem; }}
  .badges {{ display: flex; flex-wrap: wrap; gap: .5rem; margin-top: 1.25rem; }}
  .badge {{
    display: inline-flex; align-items: center; gap: .4rem;
    background: var(--chip); color: var(--muted); border: 1px solid var(--rule);
    border-radius: 999px; padding: .3rem .8rem; font-size: .82rem; font-weight: 600;
    text-decoration: none;
  }}
  a.badge:hover {{ border-color: var(--accent); color: var(--accent); }}

  /* Body layout: a sticky contents column where there is room */
  .layout {{ max-width: 62rem; margin: 0 auto; padding: 0 1.25rem 6rem; }}
  @media (min-width: 62rem) {{
    .layout.sidebar {{ display: grid; grid-template-columns: 15rem 1fr; gap: 3rem; align-items: start; }}
    nav.contents {{ position: sticky; top: 1.5rem; max-height: calc(100vh - 3rem); overflow: auto; }}
  }}
  /* No contents column: keep the text to a readable measure rather than
     letting it run the full width of a tablet. */
  .layout:not(.sidebar) article {{ max-width: 44rem; }}
  nav.contents {{ padding-top: 2.25rem; }}
  nav.contents h2 {{
    font-size: .74rem; letter-spacing: .16em; text-transform: uppercase;
    color: var(--faint); margin: 0 0 .6rem; border: 0; padding: 0;
  }}
  nav.contents ol {{ list-style: none; margin: 0; padding: 0; counter-reset: toc; }}
  nav.contents li {{ margin: 0; counter-increment: toc; }}
  nav.contents a {{
    display: block; padding: .3rem 0 .3rem 1.6rem; position: relative;
    color: var(--muted); text-decoration: none; font-size: .92rem; line-height: 1.4;
    border-left: 2px solid transparent;
  }}
  nav.contents a::before {{
    content: counter(toc); position: absolute; left: .45rem; top: .3rem;
    font-size: .74rem; color: var(--faint); font-variant-numeric: tabular-nums;
  }}
  nav.contents a:hover {{ color: var(--accent); border-left-color: var(--accent); }}

  article {{ padding-top: 2.25rem; min-width: 0; }}
  article > h2 {{
    font-size: 1.5rem; line-height: 1.25; letter-spacing: -.015em;
    margin: 3rem 0 1rem; padding-top: 1.75rem; border-top: 1px solid var(--rule);
    display: flex; align-items: center; gap: .6rem;
  }}
  article > h2:first-child {{ margin-top: 0; padding-top: 0; border-top: 0; }}
  h3 {{ font-size: 1.12rem; margin: 2rem 0 .5rem; letter-spacing: -.01em; }}
  h4 {{ font-size: .95rem; margin: 1.4rem 0 .4rem; color: var(--muted);
        text-transform: uppercase; letter-spacing: .08em; }}
  p, li {{ margin: .65rem 0; }}
  ul {{ padding-left: 1.2rem; }}
  li::marker {{ color: var(--faint); }}
  strong {{ font-weight: 650; }}
  a {{ color: var(--accent); text-underline-offset: .18em; }}
  hr {{ display: none; }}

  h2 svg {{
    width: 1.15em; height: 1.15em; flex: none; fill: none;
    stroke: var(--accent); stroke-width: 1.6; stroke-linecap: round;
  }}

  code {{
    background: var(--chip); border-radius: 5px; padding: .12em .38em;
    font: .86em/1.4 ui-monospace, "Cascadia Mono", "SF Mono", Consolas, monospace;
  }}
  /* Shortcut tables: the first column reads as keys on a keyboard. */
  table.keys td:first-child code, kbd {{
    display: inline-block; background: var(--card); border: 1px solid var(--rule);
    border-bottom-width: 2px; border-radius: 6px; padding: .16em .5em;
    box-shadow: 0 1px 0 rgba(0,0,0,.03); font-weight: 600; white-space: nowrap;
  }}

  table {{
    width: 100%; border-collapse: separate; border-spacing: 0;
    margin: 1.1rem 0; font-size: .95rem;
    background: var(--card); border: 1px solid var(--rule);
    border-radius: 12px; overflow: hidden; box-shadow: var(--shadow);
  }}
  .scroller {{ overflow-x: auto; }}
  th, td {{ text-align: left; padding: .62rem .85rem; vertical-align: top; }}
  th {{
    font-weight: 700; color: var(--faint); font-size: .72rem;
    text-transform: uppercase; letter-spacing: .1em;
    background: var(--chip); border-bottom: 1px solid var(--rule);
  }}
  td {{ border-bottom: 1px solid var(--rule); }}
  tbody tr:last-child td {{ border-bottom: 0; }}
  table.keys td:first-child {{ width: 13rem; }}

  footer {{
    max-width: 62rem; margin: 0 auto; padding: 2rem 1.25rem 4rem;
    color: var(--faint); font-size: .85rem; border-top: 1px solid var(--rule);
  }}

  @media print {{
    body {{ background: #fff; font-size: 10.5pt; }}
    header.cover {{ background: #fff; border-bottom: 1pt solid #ccc; }}
    .cover-inner, .layout, footer {{ max-width: none; padding: 0; }}
    nav.contents {{ display: none; }}
    .layout {{ display: block; }}
    article > h2 {{ break-after: avoid; }}
    table, ul, ol {{ break-inside: avoid; }}
    table {{ box-shadow: none; }}
    a {{ color: inherit; text-decoration: none; }}
  }}
</style>
</head>
<body>
<header class="cover">
  <div class="cover-inner">
    <p class="eyebrow">MyEmail{version}</p>
    <h1>{heading}</h1>
    <p class="lede">{lede}</p>
    <div class="badges">{badges}</div>
  </div>
</header>
<div class="layout{sidebar_class}">
{nav}<article>
{body}
</article>
</div>
<footer>{footer}</footer>
</body>
</html>
"""


def slug(text):
    s = re.sub(r'<[^>]+>', '', text).lower()
    s = re.sub(r'[^a-z0-9 \-]', '', s)
    return re.sub(r'\s+', '-', s.strip())


def inline(text):
    out = html.escape(text, quote=False)
    out = re.sub(r'`([^`]+)`', lambda m: f'<code>{m.group(1)}</code>', out)
    # Bold with an italic inside it — **always from *sender*** — before the
    # plain rule, which would otherwise stop at the wrong asterisk.
    out = re.sub(r'\*\*([^*]*)\*([^*]+)\*([^*]*)\*\*',
                 r'<strong>\1<em>\2</em>\3</strong>', out)
    out = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', out)
    out = re.sub(r'(?<!\*)\*([^*\n]+)\*(?!\*)', r'<em>\1</em>', out)
    out = re.sub(r'\[([^\]]+)\]\(([^)]+)\)', r'<a href="\2">\1</a>', out)
    return out


def is_break(line):
    return (not line.strip()
            or line.startswith('#')
            or line.startswith('---')
            or line.lstrip().startswith('|')
            or re.match(r'^\s*(?:[-*]|\d+\.)\s+', line) is not None)


def convert(md, skip_contents=False):
    """The document as HTML, and its h2 headings in order."""
    lines = md.split('\n')
    out, sections, i = [], [], 0
    skipping = False

    while i < len(lines):
        line = lines[i]

        if not line.strip():
            i += 1
            continue

        if line.startswith('---') and set(line.strip()) == {'-'}:
            out.append('<hr>')
            i += 1
            continue

        m = re.match(r'^(#{1,4})\s+(.*)$', line)
        if m:
            level, text = len(m.group(1)), m.group(2)
            # The markdown's own contents list is replaced by the sidebar.
            if skip_contents and level == 2 and text.strip().lower() == 'contents':
                skipping = True
                i += 1
                continue
            skipping = False
            if level == 1:
                i += 1  # The title lives in the cover band.
                continue
            body = inline(text)
            if level == 2:
                icon = ''
                low = text.lower()
                if 'on the phone' in low:
                    icon = PHONE_ICON
                elif 'on the tablet' in low:
                    icon = TABLET_ICON
                sections.append((slug(text), re.sub(r'^\d+\.\s*', '', text)))
                out.append(f'<h2 id="{slug(text)}">{icon}<span>{body}</span></h2>')
            else:
                out.append(f'<h{level} id="{slug(text)}">{body}</h{level}>')
            i += 1
            continue

        if skipping:
            i += 1
            continue

        # A table: a header row, a divider, then rows.
        if line.lstrip().startswith('|') and i + 1 < len(lines) and \
                re.match(r'^\s*\|[\s:|-]+\|\s*$', lines[i + 1]):
            def cells(row):
                return [c.strip() for c in row.strip().strip('|').split('|')]

            head = cells(line)
            i += 2
            rows = []
            while i < len(lines) and lines[i].lstrip().startswith('|'):
                rows.append(cells(lines[i]))
                i += 1
            klass = ' class="keys"' if head and head[0].lower() == 'key' else ''
            out.append('<div class="scroller"><table' + klass + '><thead><tr>' +
                       ''.join(f'<th>{inline(c)}</th>' for c in head) +
                       '</tr></thead><tbody>' +
                       ''.join('<tr>' + ''.join(f'<td>{inline(c)}</td>' for c in r) + '</tr>'
                               for r in rows) +
                       '</tbody></table></div>')
            continue

        # Lists, numbered or bulleted.
        if re.match(r'^\s*(?:[-*]|\d+\.)\s+', line):
            ordered = bool(re.match(r'^\s*\d+\.\s+', line))
            items = []
            while i < len(lines) and re.match(r'^\s*(?:[-*]|\d+\.)\s+', lines[i]):
                text = re.sub(r'^\s*(?:[-*]|\d+\.)\s+', '', lines[i])
                i += 1
                while i < len(lines) and not is_break(lines[i]):
                    text += ' ' + lines[i].strip()
                    i += 1
                items.append(f'<li>{inline(text)}</li>')
            tag = 'ol' if ordered else 'ul'
            out.append(f'<{tag}>' + ''.join(items) + f'</{tag}>')
            continue

        # Everything else is a paragraph, joined across wrapped lines.
        text = line.strip()
        i += 1
        while i < len(lines) and not is_break(lines[i]):
            text += ' ' + lines[i].strip()
            i += 1
        out.append(f'<p>{inline(text)}</p>')

    return '\n'.join(out), sections


DOCS = [
    dict(
        name='Features',
        title='MyEmail — what it can do',
        heading='What it can do',
        lede='Everything MyEmail offers, listed for the phone and for the tablet, '
             'since the same app gives you more where there is more screen.',
        other=('User manual.html', 'Read the user manual'),
        asset='features.html',
        sidebar=False,
    ),
    dict(
        name='User manual',
        title='MyEmail — user manual',
        heading='User manual',
        lede='How to use MyEmail on the phone and on the tablet. Where the two '
             'differ, it says so; everything else works the same on both.',
        other=('Features.html', 'See the feature list'),
        asset='user-manual.html',
        sidebar=True,
    ),
]

for doc in DOCS:
    md = io.open(os.path.join(SRC, doc['name'] + '.md'), encoding='utf-8').read()
    body, sections = convert(md, skip_contents=doc['sidebar'])

    nav = ''
    if doc['sidebar']:
        links = ''.join(
            f'<li><a href="#{anchor}">{html.escape(text)}</a></li>'
            for anchor, text in sections
        )
        nav = f'<nav class="contents"><h2>Contents</h2><ol>{links}</ol></nav>\n'

    badges = f'<span class="badge">Version 2.23.1</span>' \
             f'<a class="badge" href="{doc["other"][0]}">{doc["other"][1]} →</a>'

    page = TEMPLATE.format(
        title=html.escape(doc['title']),
        version=' · manual' if doc['sidebar'] else ' · features',
        heading=html.escape(doc['heading']),
        lede=html.escape(doc['lede']),
        badges=badges,
        nav=nav,
        sidebar_class=' sidebar' if doc['sidebar'] else '',
        body=body,
        footer='MyEmail is built for Ron Dvir. This page is generated from '
               f'<code>{html.escape(doc["name"])}.md</code> and works offline.',
    )
    io.open(os.path.join(SRC, doc['name'] + '.html'), 'w',
            encoding='utf-8', newline='\n').write(page)

    # The copy the app carries, so About can show it with no signal and
    # always describe the build it is in.
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    assets = os.path.join(repo, 'assets', 'help')
    os.makedirs(assets, exist_ok=True)
    io.open(os.path.join(assets, doc['asset']), 'w',
            encoding='utf-8', newline='\n').write(page)

    print('wrote', doc['name'] + '.html', 'and assets/help/' + doc['asset'],
          f'({len(page):,} bytes, {len(sections)} sections)')
