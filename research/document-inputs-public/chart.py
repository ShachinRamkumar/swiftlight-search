"""Build a self-contained comparison chart from the actual benchmark results."""
import json
from pathlib import Path

HERE = Path(__file__).resolve().parent


def main():
    result = json.loads((HERE/'results.json').read_text())
    scopes = {'Reports and lectures, merged corpus':result.get('merged_owner_queries',result['owner_like_pooled']),
              'All queries, merged corpus':result.get('merged_corpus',result['pooled']),
              'Within-subset aggregate':result['pooled'],**result['subsets']}
    payload = json.dumps(scopes).replace('</','<\\/')
    html = '''<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Public document input comparison</title>
<style>
:root {color-scheme:light dark;font-family:var(--font-sans,system-ui,sans-serif)}
html,body {margin:0} body {color:var(--foreground,CanvasText);font-size:13px}
.controls {display:flex;gap:12px;flex-wrap:wrap;align-items:center;margin-bottom:14px}
label {display:flex;gap:8px;align-items:center}
select {font:inherit;color:var(--foreground,CanvasText);background:var(--secondary,ButtonFace);border:1px solid var(--border,GrayText);border-radius:var(--radius,6px);padding:7px;max-width:100%}
.caption {color:var(--muted-foreground,GrayText);line-height:1.5;margin:8px 0}
svg {width:100%;height:360px;display:block;overflow:visible}
svg text {fill:var(--foreground,CanvasText);font:12px var(--font-sans,system-ui,sans-serif)}
.axis {stroke:var(--border,GrayText)} .zero {stroke:var(--foreground,CanvasText);stroke-opacity:.5;stroke-dasharray:3 3}
.interval {stroke:var(--chart-1,Highlight);stroke-width:2}.point {fill:var(--chart-1,Highlight)}
table {width:100%;border-collapse:collapse;font-size:12px}td,th {padding:6px 4px;text-align:right;border-bottom:1px solid var(--border)}td:first-child,th:first-child {text-align:left}
summary {cursor:pointer;padding:8px 0;color:var(--muted-foreground)}
</style></head><body>
<div class="controls"><label>Corpus <select id="scope"></select></label>
<label>Metric <select id="metric"><option>nDCG@5</option><option>Recall@1</option><option>Recall@5</option><option>MRR@10</option></select></label></div>
<p class="caption">Change versus P, in percentage points. Lines show paired bootstrap 95% confidence intervals.</p>
<svg id="plot" role="img" aria-label="Retrieval accuracy differences from the production-rule proxy"></svg>
<p class="caption" id="baseline"></p>
<details><summary>Show exact numbers</summary><table><thead><tr><th>Variant</th><th>Score</th><th>Change</th><th>95% interval</th></tr></thead><tbody id="numbers"></tbody></table></details>
<script>
const data=PAYLOAD;
const variants=[['T','Text only'],['I','Image only'],['V1','P + image'],['V1_raw','P + image, raw'],['V2','Mixed, image first'],['V2_text_image','Mixed, text first'],['prompt_image','Prompt + image'],['V2+P','Mixed + P']];
const scope=document.getElementById('scope'), metric=document.getElementById('metric');
Object.keys(data).forEach(k=>{const option=document.createElement('option');option.textContent=k;scope.append(option)});
const ns='http://www.w3.org/2000/svg';
function el(tag,attrs,text){const n=document.createElementNS(ns,tag);Object.entries(attrs).forEach(([k,v])=>n.setAttribute(k,v));if(text!==undefined)n.textContent=text;return n}
function f(x){return (x>=0?'+':'')+x.toFixed(2)}
function draw(){
const s=data[scope.value],m=metric.value,svg=document.getElementById('plot'),W=Math.max(340,svg.clientWidth);svg.replaceChildren();svg.setAttribute('viewBox',`0 0 ${W} 360`);
const rows=variants.map(([key,label])=>({key,label,...s.variants[key][m]}));
const lo=Math.min(-1,...rows.map(r=>r.delta_ci95[0]*100)),hi=Math.max(1,...rows.map(r=>r.delta_ci95[1]*100));
const pad=(hi-lo)*.08,min=lo-pad,max=hi+pad,left=W<500?135:170,right=W-48,x=v=>left+(v-min)/(max-min)*(right-left);
svg.append(el('line',{x1:x(0),x2:x(0),y1:5,y2:320,class:'zero'}));
rows.forEach((r,i)=>{const y=24+i*38,a=r.delta_ci95[0]*100,b=r.delta_ci95[1]*100,d=r.delta_vs_P*100;
svg.append(el('text',{x:0,y:y+4},r.label));
const g=el('g',{});g.append(el('title',{},`${r.label}: score ${r.value.toFixed(4)}, change ${f(d)} pp, 95% CI [${f(a)}, ${f(b)}] pp`));
g.append(el('line',{x1:x(a),x2:x(b),y1:y,y2:y,class:'interval'}));
for(const z of [a,b])g.append(el('line',{x1:x(z),x2:x(z),y1:y-5,y2:y+5,class:'interval'}));
g.append(el('circle',{cx:x(d),cy:y,r:4,class:'point'}));svg.append(g);
svg.append(el('text',{x:W-1,y:y+4,'text-anchor':'end'},f(d)));
});
svg.append(el('line',{x1:left,x2:right,y1:328,y2:328,class:'axis'}));
for(let i=0;i<=4;i++){const v=min+(max-min)*i/4;svg.append(el('text',{x:x(v),y:347,'text-anchor':'middle'},v.toFixed(1)))}
document.getElementById('baseline').textContent=`P ${m}: ${s.variants.P[m].value.toFixed(3)}. ${s.queries} queries, ${s.clusters} source clusters. OCR-based public proxy; Core AI parity pending.`;
const body=document.getElementById('numbers');body.replaceChildren();
rows.forEach(r=>{const row=document.createElement('tr');[r.label,r.value.toFixed(4),f(r.delta_vs_P*100),`[${f(r.delta_ci95[0]*100)}, ${f(r.delta_ci95[1]*100)}]`].forEach(v=>{const cell=document.createElement('td');cell.textContent=v;row.append(cell)});body.append(row)});
}
scope.addEventListener('change',draw);metric.addEventListener('change',draw);window.addEventListener('resize',draw);draw();
</script></body></html>'''.replace('PAYLOAD',payload)
    (HERE/'comparison.html').write_text(html)


if __name__=='__main__':
    main()
