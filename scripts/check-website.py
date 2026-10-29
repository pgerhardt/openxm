#!/usr/bin/env python3
"""Dependency-free checks for the buildless website's links and local assets."""
from html.parser import HTMLParser
from pathlib import Path
from urllib.parse import urlsplit
root = Path(__file__).resolve().parent.parent / 'website' / 'dist'
class Page(HTMLParser):
    def __init__(self):
        super().__init__(); self.ids = set(); self.links = []; self.errors = []
    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if 'id' in attrs:
            if attrs['id'] in self.ids: self.errors.append('Duplicate id: ' + attrs['id'])
            self.ids.add(attrs['id'])
        for attr in ('href', 'src'):
            if attr in attrs: self.links.append(attrs[attr])
        if tag == 'img' and 'alt' not in attrs: self.errors.append('Image missing alt')
p = Page(); p.feed((root / 'index.html').read_text())
for link in p.links:
    parts = urlsplit(link)
    if parts.scheme or parts.netloc: continue
    if parts.path and not (root / parts.path).is_file(): p.errors.append('Missing asset: ' + link)
    if not parts.path and parts.fragment and parts.fragment not in p.ids: p.errors.append('Missing fragment: ' + link)
assert not p.errors, '\n'.join(p.errors)
assert (root / 'app.js').is_file() and (root / 'style.css').is_file()
print(f'Website passed: {len(p.ids)} unique IDs and {len(p.links)} links/assets checked.')
