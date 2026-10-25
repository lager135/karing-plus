from pathlib import Path
from bs4 import BeautifulSoup
html = Path('static/index.html').read_text(encoding='utf-8')
soup = BeautifulSoup(html, 'html5lib')
body = soup.find('body')
print('body children:', len(list(body.children)))
for child in body.children:
    if getattr(child, 'name', None):
        print(' ', child.name, child.get('class', ''))
