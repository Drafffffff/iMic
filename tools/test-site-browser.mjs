// Real headless Chrome checks; starts and closes an owned agent-browser session.
// python3 -m http.server -d site 8000
// node tools/test-site-browser.mjs [optional-owned-browser-cdp-url]
import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
const base = process.env.IMIC_SITE_URL || 'http://127.0.0.1:8000/';
const output = path.resolve('build/ux-shots/site');
await fs.mkdir(output, {recursive:true});
const report=[];
class CDP {
  constructor(url){this.id=0;this.pending=new Map();this.events=new Map();this.ws=new WebSocket(url);this.ready=new Promise(r=>this.ws.addEventListener('open',r));this.ws.addEventListener('message',e=>{const v=JSON.parse(e.data);if(v.id){const p=this.pending.get(v.id);this.pending.delete(v.id);v.error?p?.reject(new Error(JSON.stringify(v.error))):p?.resolve(v.result);}else{for(const f of this.events.get(v.method)||[])f(v.params,v.sessionId);}});}
  async call(method,params={},sessionId){await this.ready;const id=++this.id;const p=new Promise((resolve,reject)=>this.pending.set(id,{resolve,reject}));this.ws.send(JSON.stringify({id,method,params,sessionId}));return p;}
  on(name,fn){this.events.set(name,[...(this.events.get(name)||[]),fn]);}
}
const ownedSession = process.argv[2] ? null : `imic-site-tests-${process.pid}`;
let endpoint = process.argv[2];
if (ownedSession) {
  execFileSync('agent-browser', ['--session', ownedSession, 'open', base]);
  endpoint = execFileSync('agent-browser', ['--session', ownedSession, 'get', 'cdp-url'], {encoding:'utf8'}).trim();
}
const cdp=new CDP(endpoint);
const target=await cdp.call('Target.createTarget',{url:'about:blank'});
const {sessionId}=await cdp.call('Target.attachToTarget',{targetId:target.targetId,flatten:true});
const call=(m,p)=>cdp.call(m,p,sessionId);
const evaluate=async expression=>{const r=await call('Runtime.evaluate',{expression,returnByValue:true,awaitPromise:true});if(r.exceptionDetails)throw new Error(JSON.stringify(r.exceptionDetails));return r.result.value;};
const delay=ms=>new Promise(r=>setTimeout(r,ms));
const until=async(expression,timeout=6000)=>{const end=Date.now()+timeout;while(Date.now()<end){if(await evaluate(expression))return;await delay(50);}throw new Error('Timed out: '+expression);};
let initId, mock=null,requests=0,loaded=false;
cdp.on('Page.loadEventFired',()=>{loaded=true;});
const api='https://api.github.com/repos/Drafffffff/iMic/releases/latest';
const fallback='https://github.com/Drafffffff/iMic/releases/latest';
cdp.on('Fetch.requestPaused',async p=>{try{requests++;if(mock==='timeout')return;if(mock==='offline'){await call('Fetch.failRequest',{requestId:p.requestId,errorReason:'InternetDisconnected'});return;}await call('Fetch.fulfillRequest',{requestId:p.requestId,responseCode:mock?.status||200,responseHeaders:[{name:'Content-Type',value:'application/json'},{name:'Access-Control-Allow-Origin',value:'*'}],body:Buffer.from(typeof mock?.body==='string'?mock.body:JSON.stringify(mock?.body||{})).toString('base64')});}catch(e){console.error(e.message);}});
await call('Page.enable');await call('Runtime.enable');await call('Network.enable');await call('Emulation.setFocusEmulationEnabled',{enabled:true});
const desktop='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';
const iphone='Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1';
async function navigate({url='',width=1440,height=900,mobile=false,reduced=false,init='',response=null,noJS=false}={}){
  await call('Fetch.disable');
  if(initId){await call('Page.removeScriptToEvaluateOnNewDocument',{identifier:initId});initId=null;}
  if(init)initId=(await call('Page.addScriptToEvaluateOnNewDocument',{source:init})).identifier;
  await call('Emulation.setScriptExecutionDisabled',{value:noJS});
  await call('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:1,mobile:false});
  await call('Network.setUserAgentOverride',{userAgent:mobile?iphone:desktop,platform:mobile?'iPhone':'MacIntel'});
  await call('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:reduced?'reduce':'no-preference'}]});
  mock=response;requests=0;
  if(response)await call('Fetch.enable',{patterns:[{urlPattern:api,requestStage:'Request'}]});
  // Isolate cases even when only the hash/viewport changes: same-document
  // navigation does not emit loadEventFired or re-run the mobile detector.
  await call('Page.navigate',{url:'about:blank'});
  await until('location.href === "about:blank" && document.readyState === "complete"');
  loaded=false;
  await call('Page.navigate',{url:new URL(url,base).href});
  const loadDeadline=Date.now()+10000;
  while(!loaded&&Date.now()<loadDeadline)await delay(20);
  assert(loaded,'Page load deadline');
  await until('document.readyState === "complete"');
  if(!noJS)await until('document.documentElement.dataset.releaseReady === "true"',7000);
  await delay(150);
}
async function check(name,fn){const start=Date.now();try{await fn();report.push({name,result:'PASS',ms:Date.now()-start});console.log('PASS '+name);}catch(e){report.push({name,result:'FAIL',ms:Date.now()-start,error:e.message});console.error('FAIL '+name+': '+e.message);}}
async function shot(name){await evaluate('document.querySelectorAll("video").forEach(v=>v.pause())');const {data}=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});await fs.writeFile(path.join(output,name+'.png'),Buffer.from(data,'base64'));}
async function scroll(selector){await evaluate(`document.querySelector(${JSON.stringify(selector)}).scrollIntoView({behavior:'instant',block:'start'})`);await delay(120);}
async function click(selector) {
  const point = await evaluate(`(()=>{const r=document.querySelector(${JSON.stringify(selector)}).getBoundingClientRect();return {x:r.x+r.width/2,y:r.y+r.height/2}})()`);
  await call('Input.dispatchMouseEvent',{type:'mousePressed',...point,button:'left',clickCount:1});
  await call('Input.dispatchMouseEvent',{type:'mouseReleased',...point,button:'left',clickCount:1});
}
const href=()=>evaluate('document.querySelector("#mac-download-link").href');
const valid={tag_name:'v9.8.7',assets:[{name:'iMic-9.8.7-macOS-universal.dmg',size:1581866,browser_download_url:'https://github.com/Drafffffff/iMic/releases/download/v9.8.7/iMic-9.8.7-macOS-universal.dmg'},{name:'SHA256SUMS.txt',browser_download_url:'https://github.com/Drafffffff/iMic/releases/download/v9.8.7/SHA256SUMS.txt'}]};
try{
await check('Real latest API → matching DMG, version and checksum',async()=>{await navigate();const url=await href();const match=url.match(/releases\/download\/v([^/]+)\/iMic-(.+)-macOS-universal\.dmg$/);assert(match,'Expected a versioned official DMG');assert.equal(match[1],match[2]);assert((await evaluate('document.querySelector("#release-meta").textContent')).includes(match[1]));assert((await evaluate('document.querySelector("#checksum-link").href')).endsWith(`/v${match[1]}/SHA256SUMS.txt`));await shot('desktop-hero');await scroll('#feel');await shot('desktop-feel');await scroll('#download');await shot('desktop-download');});
await check('Seven sections, three FEEL features, MODES and legacy START',async()=>{await navigate({reduced:true,response:{body:valid}});assert.deepEqual(await evaluate('[...document.querySelectorAll("main>section")].map(s=>s.id)'),['','anywhere','feel','modes','private','download','faq']);assert.deepEqual(await evaluate('[...document.querySelectorAll(".feature .index")].map(n=>n.textContent)'),['01 / 03','02 / 03','03 / 03']);assert.equal(await evaluate('document.querySelectorAll("#modes .example").length'),5);assert.equal(await evaluate('document.querySelector("#download").contains(document.querySelector("#start"))'),true);assert.equal(await evaluate('document.querySelector("#download").contains(document.querySelector(".steps"))'),true);assert.deepEqual(await evaluate('[...document.querySelectorAll(".masthead nav a")].map(a=>a.getAttribute("href"))'),['#anywhere','#feel','#modes','#private','#download']);assert.equal(await evaluate('[...document.querySelectorAll("#faq details")].some(d=>d.textContent.includes("新安装默认开启实时预览")&&d.textContent.includes("可能重复或误删"))'),true);});
await check('1440px hero fits one screen; wider layout and legible Mac text',async()=>{await navigate({reduced:true,response:{body:valid}});const sizes=await evaluate('(()=>{const v=document.querySelector(".hero-media").getBoundingClientRect(),c=document.querySelector(".hero-copy").getBoundingClientRect();return {bottom:v.bottom,left:v.left,copyRight:c.right,width:v.width,shell:document.querySelector(".shell").getBoundingClientRect().width,title:parseFloat(getComputedStyle(document.querySelector("h1")).fontSize),height:document.body.scrollHeight}})()');assert(sizes.bottom<=900);assert((await evaluate('document.querySelector(".hero-actions").getBoundingClientRect().bottom'))<=900);assert((await evaluate('document.querySelector(".hero-copy").getBoundingClientRect().bottom'))<=900);assert(sizes.left>=sizes.copyRight);assert(sizes.shell>1120);assert(sizes.title>=64&&sizes.title<=72);assert(sizes.height<=6093);assert(48*(1880/1656)/2*(sizes.width/1400)>=13);});
await check('Tablet uses two columns; 390px hero uses the portrait recording',async()=>{await navigate({width:820,height:1180,reduced:true,response:{body:valid}});assert.equal(await evaluate('getComputedStyle(document.querySelector(".hero")).gridTemplateColumns.split(" ").length'),2);await navigate({width:390,height:844,reduced:true,response:{body:valid}});assert.equal(await evaluate('document.documentElement.scrollWidth<=innerWidth'),true);assert.match(await evaluate('document.querySelector(".hero video").poster'),/hero-mobile\.webp$/);await evaluate('document.querySelector(".hero .video-toggle").click()');await until('!document.querySelector(".hero video").paused');assert.match(await evaluate('document.querySelector(".hero video").currentSrc'),/hero-mobile\.mp4$/);await until('document.querySelector(".hero video").videoWidth===720');await call('Emulation.setDeviceMetricsOverride',{width:1440,height:900,deviceScaleFactor:1,mobile:false});await delay(100);assert.match(await evaluate('document.querySelector(".hero video").poster'),/\/hero\.webp$/);});
// Animation assertions exercise actual text, CSS, media queries and viewport observation.
const demoState = () => evaluate('document.querySelector(".field-demo").dataset.state');
const fieldText = () => evaluate('[...document.querySelectorAll(".field-text")].map(t=>t.textContent)');
const fullFields = '[...document.querySelectorAll(".field-text")].every(t=>t.textContent===t.dataset.text)';
await check('ANYWHERE reduced motion: six complete, static, accessible fields',async()=>{
  await navigate({reduced:true,response:{body:valid}});await scroll('#anywhere');
  assert.equal(await demoState(),'static');assert.equal(await evaluate(fullFields),true);
  assert.equal(await evaluate('document.querySelector(".field-grid").getAttribute("aria-hidden")'),'true');
  assert.match(await evaluate('document.querySelector(".field-demo").getAttribute("aria-label")'),/示意动画.*聊天.*终端/);
  assert.equal(await evaluate('document.querySelector(".field-demo").getAttribute("role")'),'img');
  assert.equal(await evaluate('document.querySelector("[data-demo-toggle]").hidden'),true);
  const before=await fieldText();await delay(300);assert.deepEqual(await fieldText(),before);
  assert.equal(await evaluate('document.querySelector(".field-demo").getAnimations({subtree:true}).length'),0);
});
await check('ANYWHERE types sequentially, pauses offscreen and resumes',async()=>{
  await navigate({response:{body:valid}});
  assert.equal(await demoState(),'paused');const initial=await fieldText();await delay(200);assert.deepEqual(await fieldText(),initial);
  await scroll('#anywhere');await until('document.querySelector(".field-demo").dataset.state==="running"');
  await until('document.querySelector(".field-text").textContent.length>2');
  assert.equal((await fieldText())[1],'');
  await scroll('#download');await until('document.querySelector(".field-demo").dataset.state==="paused"');
  const frozen=await fieldText();await delay(300);assert.deepEqual(await fieldText(),frozen);
  assert.equal(await evaluate('document.querySelector(".field-demo").getAnimations({subtree:true}).length'),0);
  await scroll('#anywhere');await until('document.querySelector(".field-demo").dataset.state==="running"');
  await until('document.querySelector(".field-demo").dataset.phase==="complete"',14000);
  assert.equal(await evaluate(fullFields),true);
});
await check('ANYWHERE manual pause and live reduced-motion changes',async()=>{
  await navigate({response:{body:valid}});await scroll('#anywhere');
  await until('document.querySelector(".field-text").textContent.length>2');
  await click('[data-demo-toggle]');assert.equal(await demoState(),'paused');
  assert.equal(await evaluate('document.querySelector("[data-demo-toggle]").getAttribute("aria-pressed")'),'true');
  const paused=await fieldText();await delay(250);assert.deepEqual(await fieldText(),paused);
  await click('[data-demo-toggle]');assert.equal(await demoState(),'running');
  await call('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:'reduce'}]});
  await until('document.querySelector(".field-demo").dataset.state==="static"');assert.equal(await evaluate(fullFields),true);
  await call('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:'no-preference'}]});
  await until('document.querySelector(".field-demo").dataset.state==="running"');
});
await check('390px ANYWHERE has two readable columns and no overflow',async()=>{
  await navigate({width:390,height:844,reduced:true,response:{body:valid}});await scroll('#anywhere');
  assert.equal(await evaluate('getComputedStyle(document.querySelector(".field-grid")).gridTemplateColumns.split(" ").length'),2);
  assert.equal(await evaluate('document.documentElement.scrollWidth<=innerWidth'),true);
  assert.equal(await evaluate('[...document.querySelectorAll(".field-entry")].every(e=>parseFloat(getComputedStyle(e).fontSize)>=14 && e.scrollHeight<=e.parentElement.clientHeight && e.scrollWidth<=e.clientWidth)'),true);
  assert.equal(await evaluate(fullFields),true);
});
await check('SOUND retains opt-in audio and an accessible mute state',async()=>{await navigate({reduced:true,response:{body:valid}});await scroll('#sound-feature');assert.equal(await evaluate('document.querySelector("#sound-feature video").muted'),true);await click('.sound-toggle');await until('!document.querySelector("#sound-feature video").paused');assert.equal(await evaluate('document.querySelector(".sound-toggle").getAttribute("aria-pressed")'),'true');assert.equal(await evaluate('document.querySelector("#sound-feature video").muted'),false);await click('.sound-toggle');assert.equal(await evaluate('document.querySelector(".sound-toggle").getAttribute("aria-pressed")'),'false');});
await check('One API request; dynamic release replaces every DMG link',async()=>{await navigate({response:{body:valid}});assert.equal(requests,1);assert.match(await href(),/v9\.8\.7/);assert.equal(await evaluate('document.querySelector("[data-hero-version]").textContent'),'9.8.7');assert.equal(await evaluate('[...document.querySelectorAll("[data-dmg-link]")].every(a=>a.href.endsWith("iMic-9.8.7-macOS-universal.dmg"))'),true);});
for(const [name,response] of [['403',{status:403}],['429',{status:429}],['missing DMG',{body:{tag_name:'v1',assets:[]}}],['invalid JSON',{body:'{broken'}],['unsafe asset URL',{body:{...valid,assets:[{...valid.assets[0],browser_download_url:'https://example.com/fake.dmg'}]}}],['offline','offline'],['4-second timeout','timeout']]){
 await check('API fallback: '+name,async()=>{const start=Date.now();await navigate({response});assert.equal(await href(),fallback);assert.match(await evaluate('document.querySelector("#release-meta").textContent'),/^最新版本/);if(name==='4-second timeout')assert(Date.now()-start>=3900);});
}
await check('Explicit fail query',async()=>{await navigate({url:'?release-api=fail'});assert.equal(await href(),fallback);await scroll('#download');await shot('release-fallback');});
await check('No JavaScript: download remains usable; TestFlight disabled',async()=>{await navigate({noJS:true});assert.equal(await href(),fallback);assert.equal(await evaluate('document.querySelector("#testflight-pending").disabled'),true);assert.equal(await evaluate(fullFields),true);await scroll('#download');await shot('no-javascript');});
await check('390px iPhone: share button, direct link, no horizontal overflow',async()=>{await navigate({width:390,height:844,mobile:true});assert.equal(await evaluate('document.querySelector("#share-link").hidden'),false);assert.equal(await evaluate('document.querySelector("#mac-download-link").hidden'),true);assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth'),true);await shot('mobile-hero');await scroll('#download');await shot('mobile-download');});
await check('Native share receives production URL',async()=>{await navigate({mobile:true,init:'navigator.share=async data=>{window.__share=data}'});await evaluate('document.querySelector("#share-link").click()');assert.equal(await evaluate('window.__share.url'),'https://drafffffff.github.io/iMic/?from=ios#download');});
await check('Share cancel preserves UI without error',async()=>{await navigate({mobile:true,init:'navigator.share=async()=>{throw new DOMException("cancel","AbortError")}'});await evaluate('document.querySelector("#share-link").click()');await delay(50);assert.equal(await evaluate('document.querySelector("#share-status").textContent'),'');});
await check('Clipboard fallback and manual recovery',async()=>{await navigate({mobile:true,init:'Object.defineProperty(navigator,"share",{value:undefined});Object.defineProperty(navigator,"clipboard",{value:{writeText:async text=>{window.__copied=text}}})'});await evaluate('document.querySelector("#share-link").click()');await delay(50);assert.equal(await evaluate('window.__copied'),'https://drafffffff.github.io/iMic/?from=ios#download');assert.match(await evaluate('document.querySelector("#share-status").textContent'),/已复制/);await evaluate('navigator.clipboard.writeText=async()=>{throw new Error("denied")};document.querySelector("#share-link").click()');await delay(50);assert.equal(await evaluate('document.querySelector("#share-manual").hidden'),false);});
await check('768px iPad desktop-UA detection and layout',async()=>{await navigate({width:768,height:1024,init:'Object.defineProperty(navigator,"platform",{value:"MacIntel"});Object.defineProperty(navigator,"maxTouchPoints",{value:5})'});assert.equal(await evaluate('document.querySelector("#share-link").hidden'),false);assert.equal(await evaluate('document.documentElement.scrollWidth <= innerWidth'),true);await scroll('#download');await shot('tablet-download');});
await check('from=ios scroll, banner, 1.5s Mac highlight',async()=>{await navigate({url:'?from=ios#download',reduced:true,response:{body:JSON.parse(JSON.stringify(valid).replaceAll('9.8.7','1.4.4'))}});await until('document.querySelector("#mac-download").classList.contains("highlight")',1500);assert.equal(await evaluate('document.querySelector("#origin-banner").hidden'),false);assert((await evaluate('document.querySelector("#download").getBoundingClientRect().top'))<100);await shot('from-ios-highlight');await delay(1550);assert.equal(await evaluate('document.querySelector("#mac-download").classList.contains("highlight")'),false);});
await check('390px from=ios exposes sharing, the Mac button and sticky banner',async()=>{await navigate({url:'?from=ios#download',width:390,height:844,mobile:true,reduced:true,response:{body:valid}});assert.equal(await evaluate('document.querySelector("#share-link").hidden'),false);const r=await evaluate('document.querySelector("#share-link").getBoundingClientRect().toJSON()');assert(r.top>=0&&r.bottom<=844);assert.equal(await evaluate('document.querySelector("#origin-banner").getBoundingClientRect().top'),0);});
await check('Legacy #start opens the combined installation section',async()=>{await navigate({url:'#start',reduced:true,response:{body:valid}});const y=await evaluate('document.querySelector("#start").getBoundingClientRect().top');assert(y>=0&&y<120);});
await check('Hash-only deep link',async()=>{await navigate({url:'#download',reduced:true});assert.equal(await evaluate('document.querySelector("#origin-banner").hidden'),false);assert((await evaluate('document.querySelector("#download").getBoundingClientRect().top'))<100);});
await check('Reduced motion: posters only until explicit play',async()=>{await navigate({reduced:true});assert.equal(await evaluate('[...document.querySelectorAll("video")].every(v=>!v.getAttribute("src")&&v.paused)'),true);await shot('reduced-motion');await evaluate('document.querySelector(".video-toggle").click()');await until('!document.querySelector("video").paused');});
await check('Lazy videos start in viewport and pause after leaving',async()=>{await navigate();await until('!document.querySelector("video").paused');assert.equal(await evaluate('document.querySelector("#sound-feature video").getAttribute("src")'),null);await scroll('#download');await until('document.querySelector("video").paused');});
await check('FAQ keyboard interaction and storage-free page',async()=>{await navigate({reduced:true});await scroll('#faq');await evaluate('document.querySelector("summary").focus()');assert.equal(await evaluate('document.activeElement.tagName'),'SUMMARY');await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});await call('Input.dispatchKeyEvent',{type:'char',text:'\r',unmodifiedText:'\r',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});await call('Input.dispatchKeyEvent',{type:'keyUp',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});assert.equal(await evaluate('document.querySelector("details").open'),true);assert.equal(await evaluate('localStorage.length'),0);assert.equal(await evaluate('document.cookie'),'');});
}finally{
 await fs.mkdir('build/site-tests',{recursive:true});
 await fs.writeFile('build/site-tests/browser-results.json',JSON.stringify(report,null,2));
 await cdp.call('Target.closeTarget',{targetId:target.targetId});cdp.ws.close();
 if(ownedSession)execFileSync('agent-browser',['--session',ownedSession,'close']);
}
console.log(`${report.filter(x=>x.result==='PASS').length}/${report.length} browser checks passed`);
if(report.some(x=>x.result==='FAIL'))process.exitCode=1;
