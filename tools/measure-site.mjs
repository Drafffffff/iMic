// First-screen transfer audit on an owned, empty Chromium tab. Launch a browser
// with agent-browser and pass its CDP URL, page URL, and output JSON path.
import fs from 'node:fs/promises';
const [endpoint, url, output] = process.argv.slice(2);
if (!output) throw new Error('Usage: node tools/measure-site.mjs <cdp-url> <page-url> <output.json>');
class CDP {
  constructor(endpoint) {
    this.id=0;this.pending=new Map();this.handlers=new Map();this.ws=new WebSocket(endpoint);
    this.ready=new Promise(resolve=>this.ws.addEventListener('open',resolve));
    this.ws.addEventListener('message',e=>{const d=JSON.parse(e.data);if(d.id){const p=this.pending.get(d.id);this.pending.delete(d.id);d.error?p.reject(new Error(JSON.stringify(d.error))):p.resolve(d.result);}else for(const f of this.handlers.get(d.method)||[])f(d.params);});
  }
  async call(method,params={},sessionId){await this.ready;const id=++this.id;return new Promise((resolve,reject)=>{this.pending.set(id,{resolve,reject});this.ws.send(JSON.stringify({id,method,params,sessionId}));});}
  on(method,fn){this.handlers.set(method,[...(this.handlers.get(method)||[]),fn]);}
}
const cdp=new CDP(endpoint),results=[];
const delay=ms=>new Promise(r=>setTimeout(r,ms));
try {
  for(const [width,height] of [[1440,900],[390,844]]) {
    const {targetId}=await cdp.call('Target.createTarget',{url:'about:blank'});
    const {sessionId}=await cdp.call('Target.attachToTarget',{targetId,flatten:true});
    const call=(method,params)=>cdp.call(method,params,sessionId);
    const entries=new Map();
    // IDs are globally unique across Chromium network requests.
    cdp.on('Network.requestWillBeSent',p=>entries.set(p.requestId,{url:p.request.url,type:p.type,bytes:0}));
    cdp.on('Network.loadingFinished',p=>{const e=entries.get(p.requestId);if(e)e.bytes=p.encodedDataLength;});
    await call('Page.enable');await call('Network.enable');
    await call('Network.setCacheDisabled',{cacheDisabled:true});
    await call('Emulation.setFocusEmulationEnabled',{enabled:true});
    await call('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:width===390});
    await call('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:'no-preference'}]});
    if(width===390)await call('Network.setUserAgentOverride',{userAgent:'Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1',platform:'iPhone'});
    const start=Date.now();await call('Page.navigate',{url});
    // Same cold-load window, no scrolling or clicks; video is included.
    await delay(8000);
    const {result}=await call('Runtime.evaluate',{expression:'JSON.stringify({bodyHeight:document.body.scrollHeight,overflow:document.documentElement.scrollWidth>innerWidth,heroWidth:document.querySelector(".hero-media").getBoundingClientRect().width,video:[...document.querySelectorAll("video")].filter(v=>v.src).map(v=>({src:v.getAttribute("src"),ready:v.readyState,paused:v.paused}))})',returnByValue:true});
    const requests=[...entries.values()];results.push({url,width,viewportHeight:height,windowMS:Date.now()-start,...JSON.parse(result.value),transferBytes:requests.reduce((sum,r)=>sum+r.bytes,0),requests});
    await cdp.call('Target.closeTarget',{targetId});
  }
  await fs.writeFile(output,JSON.stringify(results,null,2));
  console.log(JSON.stringify(results.map(({requests,...rest})=>rest),null,2));
} finally { cdp.ws.close(); }
