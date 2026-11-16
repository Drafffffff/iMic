// Owned local Chrome / CDP regression and before/after evidence for the CRT headline.
// IMIC_SITE_URL=http://127.0.0.1:<owned-port>/ node tools/test-site-crt.mjs [before|after]
import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
const base = process.env.IMIC_SITE_URL;
assert(base && new URL(base).protocol === 'http:', 'Set IMIC_SITE_URL to your worktree HTTP server');
assert.notEqual(new URL(base).port, '8000');
const label = process.argv[2] || 'after';
assert(['before','after'].includes(label));
const output = path.resolve('build/site-tests/hidpi', label);
await fs.mkdir(output, {recursive:true});
// Same small CDP transport as test-site-browser.mjs, including deadlines.
class CDP {
  constructor(url) {
    this.id=0; this.pending=new Map(); this.ws=new WebSocket(url);
    this.ready=new Promise(r=>this.ws.addEventListener('open',r));
    this.ws.addEventListener('message',e=>{
      const v=JSON.parse(e.data), p=this.pending.get(v.id);
      if(!p)return;
      this.pending.delete(v.id); clearTimeout(p.timer);
      v.error?p.reject(new Error(JSON.stringify(v.error))):p.resolve(v.result);
    });
  }
  async call(method,params={},sessionId) {
    await this.ready; const id=++this.id;
    const p=new Promise((resolve,reject)=>this.pending.set(id,{resolve,reject,timer:setTimeout(()=>{
      this.pending.delete(id);reject(new Error('CDP deadline: '+method));
    },15000)}));
    this.ws.send(JSON.stringify({id,method,params,sessionId})); return p;
  }
}
const delay=ms=>new Promise(r=>setTimeout(r,ms));
const results=[];
// Observe the actual native draw, not just the allocated canvas height. The old
// DOMMatrix describes CSS geometry; the newer void API updates DOM geometry itself.
const observe=`window.__crtDraw=null;window.__crtFault=null;window.__crtReturn=null;
const native=CanvasRenderingContext2D.prototype.drawElementImage;
if(native)CanvasRenderingContext2D.prototype.drawElementImage=function(element,...args){
 if(window.__crtFault==='throw')throw new Error('Injected draw failure');
 if(window.__crtFault==='scale'){this.save();this.scale(1.5,1.5);}
 let image;try{const i=this.canvas.captureElementImage(element);image=[i.width,i.height];i.close();}catch{}
 const result=native.call(this,element,...args);
 if(window.__crtFault==='scale')this.restore();
 const returned=window.__crtReturn==='void'?undefined:result;
 // On this Chrome the native method returns DOMMatrix without synchronizing DOM
 // bounds. Emulate the documented modern synchronization when testing void mode.
 if(window.__crtReturn==='void'&&result)element.style.transform=result.toString();
 const r=element.getBoundingClientRect();
 window.__crtDraw={args,image,returnType:returned===undefined?'void':'DOMMatrix',
   width:returned&&typeof returned.a==='number'?Math.hypot(returned.a,returned.c)*element.offsetWidth:r.width,
   height:returned&&typeof returned.d==='number'?Math.hypot(returned.b,returned.d)*element.offsetHeight:r.height};
 return returned;
};`;
for(const enabled of [true,false]) {
 const session=`imic-crt-${label}-${enabled?'canvas':'css'}-${process.pid}`;
 const args=['--session',session,'--executable-path',process.env.IMIC_CHROME || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome'];
 if(enabled)args.push('--args','--enable-blink-features=CanvasDrawElement');
 execFileSync('agent-browser',[...args,'open',base]);
 const endpoint=execFileSync('agent-browser',['--session',session,'get','cdp-url'],{encoding:'utf8'}).trim();
 const cdp=new CDP(endpoint);
 const {targetId}=await cdp.call('Target.createTarget',{url:'about:blank'});
 const {sessionId}=await cdp.call('Target.attachToTarget',{targetId,flatten:true});
 const call=(m,p)=>cdp.call(m,p,sessionId);
 const evaluate=async expression=>{
  const r=await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});
  if(r.exceptionDetails)throw new Error(JSON.stringify(r.exceptionDetails)); return r.result.value;
 };
 const until=async expression=>{for(let i=0;i<150;i++){if(await evaluate(expression))return;await delay(50);}throw new Error('Timed out: '+expression);};
 const shot=async name=>{const {data}=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});await fs.writeFile(path.join(output,name+'.png'),Buffer.from(data,'base64'));};
 const metrics=()=>evaluate(`(()=>{const t=document.querySelector('#hero-title'),c=document.querySelector('.crt-title'),r=t.getBoundingClientRect();return {dpr:devicePixelRatio,mode:document.documentElement.dataset.crt||'css',title:[r.width,r.height],canvas:c?[c.width,c.height]:null,draw:window.__crtDraw}})()`);
 const assertSize=m=>{
  assert.equal(m.mode,enabled?'canvas':'css');
  if(enabled){assert(m.draw,'Actual draw required');for(const [i,key] of ['width','height'].entries())assert(Math.abs(m.draw[key]/m.title[i]-1)<0.1,JSON.stringify(m));}
 };
 async function navigate(lang,width,height,dpr,extra='') {
  await call('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:dpr,mobile:false});
  if(extra)await call('Page.addScriptToEvaluateOnNewDocument',{source:extra});
  await call('Page.navigate',{url:new URL(lang==='en'?'en/':'',base).href});
  await until('document.readyState==="complete" && !!document.querySelector("#hero-title")');
  await evaluate('document.fonts.ready');
  await until(enabled?'!!window.__crtDraw':'!!document.querySelector("#hero-title")');
  await delay(180); // Stay ahead of the scheduled 2–4 s title glitch.
  await evaluate('document.querySelectorAll("video").forEach(v=>v.pause())');
 }
 async function selectTitle(){
  const points=await evaluate(`(()=>{const t=document.querySelector('#hero-title'),a=document.createRange(),b=document.createRange();a.setStart(t.firstChild,0);a.setEnd(t.firstChild,1);const last=t.querySelector('.accent').firstChild;b.setStart(last,0);b.setEnd(last,last.length);const x=a.getBoundingClientRect(),y=b.getBoundingClientRect();return {start:{x:x.left,y:x.top+x.height/2},end:{x:y.right,y:y.top+y.height/2},expected:t.innerText}})()`);
  await call('Input.dispatchMouseEvent',{type:'mouseMoved',...points.start});
  await call('Input.dispatchMouseEvent',{type:'mousePressed',...points.start,button:'left',clickCount:1});
  for(let i=1;i<=12;i++)await call('Input.dispatchMouseEvent',{type:'mouseMoved',x:points.start.x+(points.end.x-points.start.x)*i/12,y:points.start.y+(points.end.y-points.start.y)*i/12,buttons:1,button:'left'});
  await call('Input.dispatchMouseEvent',{type:'mouseReleased',...points.end,button:'left',clickCount:1});
  const selected=await evaluate('getSelection().toString()');
  assert.equal(selected.replace(/\s/g,''),points.expected.replace(/\s/g,''),'Mouse selection: complete title exactly once');
  return selected;
 }
 try {
  await call('Page.enable');await call('Page.bringToFront');
  await call('Emulation.setFocusEmulationEnabled',{enabled:true});
  await call('Page.addScriptToEvaluateOnNewDocument',{source:observe});
  const version=await cdp.call('Browser.getVersion');
  for(const lang of ['zh','en'])for(const [width,height] of [[1440,900],[2560,1440]])for(const dpr of [1,2]){
   await navigate(lang,width,height,dpr);
   const m=await metrics();
   if(label==='after')assertSize(m);
   const name=`${lang}-${width}x${height}-dpr${dpr}-${enabled?'canvas':'css'}`;
   await shot(name);
   const selected=await selectTitle();
   results.push({name,browser:version.product,...m,selected});console.log(label,name,JSON.stringify(m));
  }
  if(enabled&&label==='after'){
   // Repeated cross-screen/zoom DPR changes, with no CSS viewport resize.
   await navigate('zh',1440,900,1);
   for(const dpr of [2,1.25,3,1]){
    await call('Emulation.setDeviceMetricsOverride',{width:1440,height:900,deviceScaleFactor:dpr,mobile:false});
    await until(`document.querySelector('.crt-title')?.width===Math.round((document.querySelector('#hero-title').getBoundingClientRect().width+48)*${dpr})`);
    assertSize(await metrics());results.push({name:'DPR transition '+dpr,...await metrics()});
   }
   await navigate('zh',1440,900,2);
   await evaluate(`document.dispatchEvent(new CustomEvent('imic:glitch',{detail:{target:document.querySelector('#hero-title'),level:'medium'}}))`);
   await delay(100);await shot('glitch-dpr2');assertSize(await metrics());
   // Failures after an already successful frame must permanently restore CSS.
   for(const fault of ['scale','throw']){
    await navigate('zh',1440,900,2);
    await evaluate(`window.__crtFault=${JSON.stringify(fault)};document.querySelector('.crt-title').requestPaint()`);
    await until('!document.querySelector(".crt-title") && !document.querySelector("#hero-title").classList.contains("crt-lit")');
    assert.equal((await metrics()).mode,'css');
    await shot('fallback-'+fault);results.push({name:'fallback '+fault,result:'PASS'});
   }
   // Test the documented void-return geometry branch on our DOMMatrix build.
   await navigate('en',1440,900,2,'window.__crtReturn="void";');
   assertSize(await metrics());results.push({name:'modern void-return geometry (emulated)',...await metrics()});
  }
 } finally {
  await fs.writeFile(path.join(output,'results.json'),JSON.stringify(results,null,2));
  await cdp.call('Target.closeTarget',{targetId});cdp.ws.close();
  execFileSync('agent-browser',['--session',session,'close']);
 }
}
console.log(`${label}: ${results.length} CRT cases recorded in ${output}`);
