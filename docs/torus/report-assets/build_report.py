"""Build a self-contained HTML and optional PDF from the concise report.

Requires markdown; --pdf also requires playwright and its Chromium installation.
"""
import base64, re, argparse
from pathlib import Path
import markdown

DOC = Path(__file__).resolve().parent.parent
text = (DOC/'design-report.md').read_text()
chunks = re.split(r'(?m)^## ',text)
intro=markdown.markdown(chunks[0])
sections=[]
for i,chunk in enumerate(chunks[1:]):
    body=markdown.markdown('## '+chunk,extensions=['tables'])
    if i==0:body=intro+body
    if i==4:
        # Put the real QoR capture next to the real Innovus canvas without editing either image.
        imgs=re.findall(r'<p><img .*?</p>',body)
        for im in imgs:body=body.replace(im,'')
        at=body.index('</h2>')+5
        body=body[:at]+'<div class="two-images">'+''.join(imgs)+'</div>'+body[at:]
    sections.append(f'<section id="part-{i+1}">{body}<footer>mynpu · ABI 4 · 2026-10-29 <span>{i+1} / 6</span></footer></section>')
html=''.join(sections)
def embed(m):
    p=DOC/m.group(1)
    mime='image/svg+xml' if p.suffix=='.svg' else 'image/png'
    return 'src="data:'+mime+';base64,'+base64.b64encode(p.read_bytes()).decode()+'"'
html=re.sub(r'src="([^"]+)"',embed,html)
css='''
@page {size:A4; margin:12mm 14mm;}
* {box-sizing:border-box} body {margin:0;background:#e9eef4;color:#233248;font:14px/1.65 "Noto Sans CJK SC",sans-serif;}
section {width:794px;min-height:1040px;background:white;margin:22px auto;padding:30px 36px;position:relative;}
h1 {font-size:27px;color:#123e70;margin:0 0 4px} h2 {font-size:21px;color:#123e70;margin:12px 0;} p{margin:12px 0;}
img {display:block;width:100%;height:auto;margin:10px auto;} strong {color:#124971} table {border-collapse:collapse;width:100%;font-size:12.5px;line-height:1.6;margin:16px 0;}
th {background:#edf4fa;text-align:left;color:#174b78} td,th {padding:9px 10px;border-bottom:1px solid #d9e1e9;vertical-align:top;}
td:first-child {min-width:95px;} a{color:#23629e;text-decoration:none;} code {font:12px monospace;background:#f2f5f8;overflow-wrap:anywhere;}
.two-images{display:grid;grid-template-columns:45% 55%;align-items:center;gap:12px;margin:12px 0}.two-images p{margin:0}.two-images img{width:100%;}
footer{border-top:1px solid #dae2ec;margin-top:22px;padding-top:8px;font-size:10px;color:#718096} footer span{float:right;}
@media print {body{background:white;font-size:12px;line-height:1.65}section{width:auto;min-height:0;margin:0;padding:0;break-after:page;}section:last-child{break-after:auto} h1{font-size:25px}h2{font-size:19px}p{margin:10px 0}table{font-size:11.5px}td,th{padding:7px}a{color:inherit}footer{margin-top:15px}.two-images{gap:10px;}}
'''
out=DOC/'design-report.html'
out.write_text('<!doctype html><html lang="zh-CN"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><title>mynpu 灵活架构与面积优化报告</title><style>'+css+'</style></head><body>'+html+'</body></html>')
parser=argparse.ArgumentParser()
parser.add_argument('--pdf',action='store_true')
if parser.parse_args().pdf:
    from playwright.sync_api import sync_playwright
    with sync_playwright() as p:
        browser=p.chromium.launch(channel='chromium',headless=True,args=['--no-sandbox'])
        page=browser.new_page(viewport={'width':1000,'height':1200},device_scale_factor=1)
        page.goto(out.as_uri());page.evaluate('document.fonts.ready');page.wait_for_timeout(500)
        assert page.locator('img').evaluate_all('(xs)=>xs.every(x=>x.complete&&x.naturalWidth>0)')
        page.pdf(path=str(DOC/'design-report.pdf'),print_background=True,prefer_css_page_size=True)
        page.screenshot(path=str(DOC.parent.parent/'build/torus/report-capture/report-preview.png'),full_page=True)
        print(page.locator('section').evaluate_all('(xs)=>xs.map(x=>({id:x.id,height:x.getBoundingClientRect().height}))'))
        browser.close()
print(out)
