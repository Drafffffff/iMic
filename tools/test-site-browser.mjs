// Real headless Chrome checks; starts and closes an owned agent-browser session.
// Start your own HTTP server and set IMIC_SITE_URL.
// node tools/test-site-browser.mjs [optional-owned-browser-cdp-url]
import fs from 'node:fs/promises';
import path from 'node:path';
import assert from 'node:assert/strict';
import {execFileSync} from 'node:child_process';
const base = process.env.IMIC_SITE_URL;
assert(base, 'Set IMIC_SITE_URL to an HTTP server owned by this worktree');
assert.notEqual(new URL(base).port, '8000', 'Use an owned server on a port other than 8000');
const output = path.resolve('build/ux-shots/site');
await fs.mkdir(output, {recursive:true});
const report=[];
class CDP {
  constructor(url){this.id=0;this.pending=new Map();this.events=new Map();this.ws=new WebSocket(url);this.ready=new Promise(r=>this.ws.addEventListener('open',r));this.ws.addEventListener('message',e=>{const v=JSON.parse(e.data);if(v.id){const p=this.pending.get(v.id);this.pending.delete(v.id);clearTimeout(p?.timer);v.error?p?.reject(new Error(JSON.stringify(v.error))):p?.resolve(v.result);}else{for(const f of this.events.get(v.method)||[])f(v.params,v.sessionId);}});}
  async call(method,params={},sessionId){await this.ready;const id=++this.id;const p=new Promise((resolve,reject)=>this.pending.set(id,{resolve,reject,timer:setTimeout(()=>{this.pending.delete(id);reject(new Error("CDP deadline: "+method))},15000)}));this.ws.send(JSON.stringify({id,method,params,sessionId}));return p;}
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
let analyticsId=null, analyticsMode='stub', fixtureOrigin=null;
let analyticsRequests=[], analyticsBodies=[];
const samples=[];
const testID='00000000-0000-4000-8000-000000000001';
const analyticsHosts=new Set(['cloud.umami.is','gateway.umami.is']);
cdp.on('Network.requestWillBeSent', p=>{
  if(analyticsHosts.has(new URL(p.request.url).hostname))analyticsRequests.push(p.request.url);
});
cdp.on('Page.loadEventFired',()=>{loaded=true;});
const api='https://api.github.com/repos/Drafffffff/iMic/releases/latest';
const fallback='https://github.com/Drafffffff/iMic/releases/latest';
// All enabled analytics tests are intercepted; no test events reach a provider.
cdp.on('Fetch.requestPaused',async p=>{
 try {
  const url=new URL(p.request.url);
  const fulfill=async(body,type='application/javascript',status=200)=>call('Fetch.fulfillRequest',{
    requestId:p.requestId,responseCode:status,
    responseHeaders:[{name:'Content-Type',value:type},{name:'Access-Control-Allow-Origin',value:'*'},{name:'Access-Control-Allow-Headers',value:'*'},{name:'Access-Control-Allow-Methods',value:'POST, OPTIONS'}],
    body:Buffer.from(body).toString('base64')
  });
  if(url.hostname==='cloud.umami.is') {
    if(analyticsMode==='failed')return await call('Fetch.failRequest',{requestId:p.requestId,errorReason:'InternetDisconnected'});
    if(analyticsMode==='pending')return;
    const body=analyticsMode==='live' ? await (await fetch('https://cloud.umami.is/script.js')).text()
      : 'window.__analyticsPayloads=[];window.umami={track:p=>{window.__analyticsPayloads.push(p);return Promise.resolve()}};';
    return await fulfill(body);
  }
  if(url.hostname==='gateway.umami.is') {
    if(p.request.method==='POST')analyticsBodies.push(JSON.parse(p.request.postData));
    return await fulfill(p.request.method==='OPTIONS'?'':JSON.stringify({cache:'test-cache'}),'application/json');
  }
  if(url.pathname.endsWith('/assets/js/site.js')) {
    let source=await fs.readFile('site/assets/js/site.js','utf8');
    // Tests are independent of the configured production ID: every page load gets an
    // explicit ID (empty unless a test injects one).
    source=source.replace(/const ANALYTICS_SITE_ID = "[^"]*";/,`const ANALYTICS_SITE_ID = ${JSON.stringify(analyticsId ?? '')};`);
    return await fulfill(source);
  }
  if(fixtureOrigin&&url.origin===fixtureOrigin) {
    // Production-like URL in Chrome, but every byte comes from this worktree's server.
    const local=new URL(url.pathname.replace(/^\/iMic\//,''),base);
    local.search=url.search;
    const response=await fetch(local);
    return await fulfill(await response.arrayBuffer(),response.headers.get('content-type'),response.status);
  }
  requests++;
  if(mock==='timeout')return;
  if(mock==='offline')return await call('Fetch.failRequest',{requestId:p.requestId,errorReason:'InternetDisconnected'});
  await fulfill(typeof mock?.body==='string'?mock.body:JSON.stringify(mock?.body||{}),'application/json',mock?.status||200);
 } catch(e) { console.error(e.message);await call('Fetch.failRequest',{requestId:p.requestId,errorReason:'Failed'}); }
});
await call('Page.enable');await call('Runtime.enable');await call('Network.enable');await call('Emulation.setFocusEmulationEnabled',{enabled:true});
const desktop='Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140.0.0.0 Safari/537.36';
const iphone='Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1';
async function navigate({url='',width=1440,height=900,dpr=1,mobile=false,reduced=false,init='',response=null,noJS=false,siteID=null,analytics='stub',origin=null}={}){
  await call('Page.stopLoading');
  await call('Fetch.disable');
  if(initId){await call('Page.removeScriptToEvaluateOnNewDocument',{identifier:initId});initId=null;}
  const observe='window.__tracks=[];document.addEventListener("imic:track",e=>window.__tracks.push(e.detail));';
  initId=(await call('Page.addScriptToEvaluateOnNewDocument',{source:observe+init})).identifier;
  await call('Emulation.setScriptExecutionDisabled',{value:noJS});
  await call('Emulation.setDeviceMetricsOverride',{width,height,deviceScaleFactor:dpr,mobile:false});
  await call('Network.setUserAgentOverride',{userAgent:mobile?iphone:desktop,platform:mobile?'iPhone':'MacIntel'});
  await call('Emulation.setEmulatedMedia',{features:[{name:'prefers-reduced-motion',value:reduced?'reduce':'no-preference'}]});
  mock=response;requests=0;
  analyticsId=siteID;analyticsMode=analytics;fixtureOrigin=origin;
  const patterns=['*assets/js/site.js','https://cloud.umami.is/*','https://gateway.umami.is/*'];
  if(response)patterns.push(api);
  if(origin)patterns.push(origin+'/*');
  await call('Fetch.enable',{patterns:patterns.map(urlPattern=>({urlPattern,requestStage:'Request'}))});
  // Isolate cases even when only the hash/viewport changes: same-document
  // navigation does not emit loadEventFired or re-run the mobile detector.
  await call('Page.navigate',{url:'about:blank'});
  await until('location.href === "about:blank" && document.readyState === "complete"');
  loaded=false;analyticsRequests=[];analyticsBodies=[];
  const root=origin?new URL('/iMic/',origin).href:base;
  await call('Page.navigate',{url:new URL(url,root).href});
  const loadDeadline=Date.now()+10000;
  if(analytics!=='pending') {
    while(!loaded&&Date.now()<loadDeadline)await delay(20);
    assert(loaded,'Page load deadline');
    await until('document.readyState === "complete"');
  } else await until('document.readyState !== "loading"'); // Async script must not hold up DOM/UI.
  if(!noJS)await until('document.documentElement.dataset.releaseReady === "true"',7000);
  await delay(150);
  if(!noJS && !url.startsWith('file:')) {
    assert.equal(await evaluate('document.cookie'), '');
    assert.equal(await evaluate('sessionStorage.length + localStorage.length'),0);
  }
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

const tracks=(name)=>evaluate(`window.__tracks.filter(e=>e.name===${JSON.stringify(name)})`);
const saveSamples=async()=>{samples.push(...await evaluate('window.__tracks'));};
const production='https://drafffffff.github.io';
const storageFree=async()=>{
 assert.equal(await evaluate('sessionStorage.length+localStorage.length'),0);
 assert.equal(await evaluate('document.cookie'),'');
 assert.equal((await call('Network.getCookies')).cookies.length,0);
};
// Suppress default navigation after the real click handler (do not modify destinations).
const stay='document.addEventListener("click",e=>{if(e.target.closest("a"))e.preventDefault()});';
await check('Analytics empty ID: zero provider requests, including production-like URL',async()=>{
 await navigate({origin:production,response:{body:valid}});
 assert.deepEqual(analyticsRequests,[]);
 assert.equal(await evaluate('document.querySelector("script[src*=umami]")'),null);
 await storageFree();
});
for(const origin of [null,`http://localhost:${new URL(base).port}`,'http://[::1]:48763','http://preview.local']) {
 await check(`Analytics configured ID stays off at local address ${origin||base}`,async()=>{
  await navigate({origin,siteID:testID,response:{body:valid}});
  assert.deepEqual(analyticsRequests,[]);
  assert.equal(await evaluate('document.querySelector("script[src*=umami]")'),null);
 });
}
await check('Analytics file URL stays off with configured ID',async()=>{
 await navigate({url:new URL('file://'+path.resolve('site/index.html')).href,siteID:testID,reduced:true,response:{body:valid}});
 assert.deepEqual(analyticsRequests,[]);
 assert.equal(await evaluate('document.querySelector("script[src*=umami]")'),null);
});
for(const [signal,init] of [
 ['DNT','Object.defineProperty(navigator,"doNotTrack",{value:"1"});'],
 ['window DNT','Object.defineProperty(window,"doNotTrack",{value:"yes"});'],
 ['legacy DNT','Object.defineProperty(navigator,"msDoNotTrack",{value:"1"});'],
 ['GPC','Object.defineProperty(navigator,"globalPrivacyControl",{value:true});']
])await check(`Analytics ${signal}: zero provider requests on public hostname`,async()=>{
 await navigate({origin:production,siteID:testID,init,response:{body:valid}});
 assert.deepEqual(analyticsRequests,[]);
 assert.equal(await evaluate('document.querySelector("script[src*=umami]")'),null);
});
await check('Analytics adapter: async, explicit sanitized payload; in-page detail precedes provider',async()=>{
 await navigate({origin:production,url:'?from=ios&email=private@example.com#download',siteID:testID,reduced:true,response:{body:valid},init:stay+`Object.defineProperty(document,'referrer',{value:'https://source.example/private?token=secret#name'});`});
 assert.equal(await evaluate('document.querySelector("script[src*=umami]").async'),true);
 assert.equal(await evaluate('document.querySelector("script[src*=umami]").referrerPolicy'),'no-referrer');
 assert.equal(await evaluate('document.querySelector("script[src*=umami]").dataset.autoTrack'),'false');
 const payloads=await evaluate('window.__analyticsPayloads');
 assert.equal(payloads.filter(p=>!p.name).length,1);
 assert.equal(payloads[0].url,'/iMic/');assert.equal(payloads[0].referrer,'https://source.example');
 assert.equal(payloads[0].title,'iMic');assert(!JSON.stringify(payloads).match(/private|secret|email|token|#download/));
 assert.equal(payloads.filter(p=>p.name==='from_ios').length,1);
 await evaluate(`document.addEventListener('imic:track',()=>{window.__before=window.__analyticsPayloads.length},{once:true});document.querySelector('.hero-actions .primary').click()`);
 assert.equal(await evaluate('window.__analyticsPayloads.length-window.__before'),1);
 assert.deepEqual((await evaluate('window.__analyticsPayloads.at(-1)')).data,{placement:'hero',lang:'zh'});
 // Page events cannot be used to inject arbitrary payloads into the adapter.
 const count=await evaluate('window.__analyticsPayloads.length');
 await evaluate(`document.dispatchEvent(new CustomEvent('imic:track',{detail:{name:'private',props:{email:'private'}}}))`);
 assert.equal(await evaluate('window.__analyticsPayloads.length'),count);
 await evaluate(`Object.defineProperty(navigator,'globalPrivacyControl',{value:true});document.querySelector('.hero-actions .primary').click()`);
 assert.equal(await evaluate('window.__analyticsPayloads.length'),count,'privacy rechecked on send');
 await storageFree();
});
for(const lang of ['zh','en'])await check(`Analytics ${lang}: download/iPhone/language/from_ios properties`,async()=>{
 const prefix=lang==='en'?'en/':'';
 await navigate({url:prefix+'?from=ios#download',reduced:true,response:{body:valid},init:stay});
 assert.deepEqual(await tracks('from_ios'),[{name:'from_ios',props:{lang}}]);
 await evaluate(`document.querySelector('.hero-actions .primary').click();document.querySelector('#mac-download-link').click();document.querySelector('.hero-actions .text-link').click();document.querySelector('#testflight-link').hidden=false;document.querySelector('#testflight-link').href='https://testflight.apple.com/join/test';document.querySelector('#testflight-link').click();document.querySelector('.language-switch').click()`);
 assert.deepEqual(await tracks('download_mac'),['hero','card'].map(placement=>({name:'download_mac',props:{placement,lang}})));
 assert.deepEqual(await tracks('iphone_get'),['hero','card'].map(placement=>({name:'iphone_get',props:{placement,lang}})));
 assert.deepEqual(await tracks('language_switch'),[{name:'language_switch',props:{to:lang==='en'?'zh':'en',placement:'nav'}}]);
 await evaluate(`location.hash='faq';location.hash='download'`);
 assert.equal((await tracks('from_ios')).length,1);
 await saveSamples();
 await navigate({url:prefix+'#download',mobile:true,reduced:true,response:{body:valid},init:stay});
 await evaluate(`document.querySelector('#mobile-download-note a').click()`);
 assert.deepEqual(await tracks('download_mac'),[{name:'download_mac',props:{placement:'mobile-direct',lang}}]);
 assert.deepEqual(await tracks('from_ios'),[],'hash alone is not from_ios');
 await saveSamples();
});
await check('Analytics language banner: English destination',async()=>{
 await navigate({init:stay+'Object.defineProperty(navigator,"language",{value:"en-US"});',response:{body:valid}});
 await evaluate('document.querySelector("#language-banner a").click()');
 assert.deepEqual(await tracks('language_switch'),[{name:'language_switch',props:{to:'en',placement:'banner'}}]);
 await saveSamples();
});
for(const lang of ['zh','en'])for(const [result,init] of [
 ['shared','navigator.share=async()=>{};'],
 ['copied','Object.defineProperty(navigator,"share",{value:undefined});Object.defineProperty(navigator,"clipboard",{value:{writeText:async()=>{}}});'],
 ['copied','navigator.share=async()=>{throw new Error("denied")};Object.defineProperty(navigator,"clipboard",{value:{writeText:async()=>{}}});'],
 ['failed','navigator.share=async()=>{throw new Error("denied")};Object.defineProperty(navigator,"clipboard",{value:{writeText:async()=>{throw new Error("denied")}}});'],
 ['failed','navigator.share=async()=>{throw new DOMException("cancel","AbortError")};']
])await check(`Analytics ${lang} share outcome ${result}: ${init.includes('AbortError')?'cancel':init.includes('undefined')?'clipboard':init.includes('denied')?'denied API':'native'}`,async()=>{
 await navigate({url:lang==='en'?'en/':'',mobile:true,reduced:true,response:{body:valid},init});
 await evaluate('document.querySelector("#share-link").click()');
 await until('window.__tracks.some(e=>e.name==="share_to_mac")');
 assert.deepEqual(await tracks('share_to_mac'),[{name:'share_to_mac',props:{result,lang}}]);
 await saveSamples();
});
await check('Analytics autoplay/decoration emits no video_play; manual video IDs and sound opt-in',async()=>{
 await navigate({response:{body:valid}});
 await until('!document.querySelector("video").paused');
 assert.deepEqual(await tracks('video_play'),[]);
 await evaluate(`document.dispatchEvent(new CustomEvent('imic:glitch',{detail:{level:'small'}}))`);
 assert.equal(await evaluate('window.__tracks.some(e=>/glitch|demo/.test(e.name))'),false);
 await navigate({reduced:true,response:{body:valid}});
 for(const [video,selector] of [['hero','.hero'],['string','#string-feature'],['polish','#polish-feature'],['sound','#sound-feature']]) {
  await scroll(selector);await click(selector+' .video-toggle');
  await until(`!document.querySelector('${selector} video').paused`);
  await click(selector+' .video-toggle');
  assert.equal((await tracks('video_play')).filter(e=>e.props.video===video).length,1);
 }
 await click('.sound-toggle');await click('.sound-toggle');await click('.sound-toggle');
 assert.deepEqual(await tracks('video_play'),['hero','string','polish','sound'].map(video=>({name:'video_play',props:{video}})));
 assert.deepEqual(await tracks('sound_on'),[{name:'sound_on',props:{}},{name:'sound_on',props:{}}]);
 await saveSamples();
});
await check('Analytics FAQ numbers, closing excluded; scroll milestones once per load',async()=>{
 await navigate({reduced:true,response:{body:valid}});
 const count=await evaluate('document.querySelectorAll("#faq details").length');
 for(let i=0;i<count;i++) {
  await evaluate(`document.querySelectorAll('#faq details')[${i}].open=true`);
  await until(`window.__tracks.filter(e=>e.name==='faq_open').length===${i+1}`);
  await evaluate(`document.querySelectorAll('#faq details')[${i}].open=false`);await delay(30);
 }
 assert.deepEqual(await tracks('faq_open'),Array.from({length:count},(_,i)=>({name:'faq_open',props:{question:String(i+1)}})));
 for(const depth of [25,50,75,100,0,100]) {
  await evaluate(`scrollTo({top:(document.documentElement.scrollHeight-innerHeight)*${depth}/100,behavior:'instant'})`);await delay(100);
 }
 assert.deepEqual(await tracks('scroll_depth'),['25','50','75','100'].map(depth=>({name:'scroll_depth',props:{depth}})));
 await saveSamples();
 await navigate({reduced:true,response:{body:valid}});
 await evaluate(`scrollTo({top:document.documentElement.scrollHeight,behavior:'instant'})`);
 await until('window.__tracks.filter(e=>e.name==="scroll_depth").length===4');
 assert.deepEqual(await tracks('scroll_depth'),['25','50','75','100'].map(depth=>({name:'scroll_depth',props:{depth}})));
});
for(const analytics of ['failed','pending'])await check(`Analytics script ${analytics}: controls and local events work without provider`,async()=>{
 await navigate({origin:production,url:'?from=ios',siteID:testID,analytics,reduced:true,response:{body:valid},init:stay});
 await evaluate('document.querySelector(".hero-actions .primary").click()');
 assert.deepEqual(await tracks('download_mac'),[{name:'download_mac',props:{placement:'hero',lang:'zh'}}]);
 await until('window.__tracks.filter(e=>e.name==="from_ios").length===1');
 assert(analyticsRequests.every(url=>new URL(url).hostname==='cloud.umami.is'));
 assert.match(await href(),/v9\.8\.7/);await storageFree();
});
await check('Analytics actual Umami script: intercepted ingestion, no storage writes or URL leakage',async()=>{
 await navigate({origin:production,url:'en/?from=ios&token=secret#download',siteID:testID,analytics:'live',reduced:true,response:{body:valid},init:stay+`Object.defineProperty(document,'referrer',{value:'https://source.example/private?token=secret#name'});`});
 await until('typeof window.umami?.track === "function"',10000);
 await evaluate(`document.querySelector('.hero-actions .primary').click()`);
 const end=Date.now()+6000;while(analyticsBodies.length<3&&Date.now()<end)await delay(50);
 assert.equal(analyticsBodies.filter(b=>!b.payload.name).length,1);
 assert.equal(analyticsBodies.filter(b=>b.payload.name==='from_ios').length,1);
 assert.equal(analyticsBodies.filter(b=>b.payload.name==='download_mac').length,1);
 for(const body of analyticsBodies) {
  assert.equal(body.type,'event');assert.equal(body.payload.url,'/iMic/en/');
  assert.equal(body.payload.referrer,'https://source.example');assert.equal(body.payload.website,testID);
  assert(!JSON.stringify(body).match(/secret|private|token|#download/));
 }
 assert.deepEqual(analyticsBodies.find(b=>b.payload.name==='download_mac').payload.data,{placement:'hero',lang:'en'});
 await storageFree();
});
await check('Real latest API → matching DMG, version and checksum',async()=>{await navigate();const url=await href();const match=url.match(/releases\/download\/v([^/]+)\/iMic-(.+)-macOS-universal\.dmg$/);assert(match,'Expected a versioned official DMG');assert.equal(match[1],match[2]);assert((await evaluate('document.querySelector("#release-meta").textContent')).includes(match[1]));assert((await evaluate('document.querySelector("#checksum-link").href')).endsWith(`/v${match[1]}/SHA256SUMS.txt`));await shot('desktop-hero');await scroll('#feel');await shot('desktop-feel');await scroll('#download');await shot('desktop-download');});
await check('Seven sections, three FEEL features, MODES and legacy START',async()=>{await navigate({reduced:true,response:{body:valid}});assert.deepEqual(await evaluate('[...document.querySelectorAll("main>section")].map(s=>s.id)'),['','anywhere','feel','modes','private','download','faq']);assert.deepEqual(await evaluate('[...document.querySelectorAll(".feature .index")].map(n=>n.textContent)'),['01 / 03','02 / 03','03 / 03']);assert.equal(await evaluate('document.querySelectorAll("#modes .example").length'),5);assert.equal(await evaluate('document.querySelector("#download").contains(document.querySelector("#start"))'),true);assert.equal(await evaluate('document.querySelector("#download").contains(document.querySelector(".steps"))'),true);assert.deepEqual(await evaluate('[...document.querySelectorAll(".masthead nav > a")].map(a=>a.getAttribute("href"))'),['#anywhere','#feel','#modes','#private','#download']);assert.equal(await evaluate('[...document.querySelectorAll("#faq details")].some(d=>d.textContent.includes("新安装默认开启实时预览")&&d.textContent.includes("可能重复或误删"))'),true);});
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
await check('Bailian FAQ gives Beijing, full permissions and rejects plan keys',async()=>{await navigate({reduced:true,response:{body:valid}});const text=await evaluate('document.querySelector("#faq details").textContent');for(const phrase of ['1.','2.','3.','实名认证','华北2（北京）','权限选「全部」','套餐 Key（Token Plan、Coding Plan）不能用于 iMic','免费额度'])assert(text.includes(phrase),phrase);});
await check('FAQ keyboard interaction and storage-free page',async()=>{await navigate({reduced:true});await scroll('#faq');await evaluate('document.querySelector("summary").focus()');assert.equal(await evaluate('document.activeElement.tagName'),'SUMMARY');await call('Input.dispatchKeyEvent',{type:'keyDown',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});await call('Input.dispatchKeyEvent',{type:'char',text:'\r',unmodifiedText:'\r',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});await call('Input.dispatchKeyEvent',{type:'keyUp',key:'Enter',code:'Enter',windowsVirtualKeyCode:13});assert.equal(await evaluate('document.querySelector("details").open'),true);assert.equal(await evaluate('localStorage.length'),0);assert.equal(await evaluate('document.cookie'),'');});
// English coverage uses the same shared media, download code and animation.
for (const width of [1440,390]) {
 await check(`English ${width}px: metadata, navigation, no clipping and downloads`,async()=>{
  await navigate({url:'en/',width,height:width===390?844:900,reduced:true,response:{body:valid}});
  assert.equal(await evaluate('document.documentElement.lang'),'en');
  assert.equal(await evaluate('document.documentElement.scrollWidth<=innerWidth'),true);
  assert.equal(await evaluate('document.querySelector("#language-banner")'),null);
  assert.equal(await evaluate('document.querySelectorAll("link[rel=alternate][hreflang]").length'),3);
  assert.match(await evaluate('document.querySelector(".language-switch").href'),/\/$/);
  assert.match(await href(),/v9\.8\.7/);
  assert.match(await evaluate('document.querySelector(".field-text").dataset.text'),/Meeting at three/);
  assert.equal(await evaluate('document.querySelectorAll("video").length'),4);
  const review=output;await fs.mkdir(review,{recursive:true});
  const {data}=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:false});
  await fs.writeFile(path.join(review,`site-en-${width}.png`),Buffer.from(data,'base64'));
  if(width===1440){const metrics=await call('Page.getLayoutMetrics');const full=await call('Page.captureScreenshot',{format:'png',captureBeyondViewport:true,clip:{x:0,y:0,width:1440,height:metrics.cssContentSize.height,scale:1}});await fs.writeFile(path.join(review,'site-en-full.png'),Buffer.from(full.data,'base64'));}
 });
}
await check('English animation pause labels and reduced-motion fallback',async()=>{
 await navigate({url:'en/',response:{body:valid}});await scroll('#anywhere');
 await until('document.querySelector(".field-demo").dataset.state === "running"');
 await click('[data-demo-toggle]');assert.equal(await evaluate('document.querySelector("[data-demo-toggle]").textContent'),'Play illustration');
 await click('[data-demo-toggle]');assert.equal(await evaluate('document.querySelector("[data-demo-toggle]").textContent'),'Pause illustration');
});
await check('English API fallback, no JavaScript and from=ios',async()=>{
 await navigate({url:'en/',response:{status:403}});assert.equal(await href(),fallback);assert.match(await evaluate('document.querySelector("#release-meta").textContent'),/^Latest version/);
 await navigate({url:'en/',noJS:true});assert.equal(await href(),fallback);
 await navigate({url:'en/?from=ios#download',width:390,height:844,mobile:true,reduced:true,response:{body:valid},init:'navigator.share=async data=>{window.__share=data}'});
 assert.equal(await evaluate('document.querySelector("#origin-banner").hidden'),false);
 await evaluate('document.querySelector("#share-link").click()');assert.equal(await evaluate('window.__share.url'),'https://drafffffff.github.io/iMic/en/?from=ios#download');
 assert((await evaluate('document.querySelector("#share-link").getBoundingClientRect().bottom'))<=844);
});
await check('Language suggestion is dismissible, storage-free and never redirects',async()=>{
 const language=lang=>`Object.defineProperty(navigator,"language",{value:${JSON.stringify(lang)}})`;
 await navigate({init:language('en-US'),response:{body:valid}});
 assert.equal(await evaluate('document.querySelector("#language-banner").hidden'),false);assert.equal(await evaluate('location.pathname'),new URL(base).pathname);
 const {data}=await call('Page.captureScreenshot',{format:'png'});await fs.writeFile(path.join(output,'site-zh-suggestion.png'),Buffer.from(data,'base64'));
 await click('#language-banner button');assert.equal(await evaluate('document.querySelector("#language-banner").hidden'),true);
 assert.equal(await evaluate('document.cookie'), '');assert.equal(await evaluate('sessionStorage.length + localStorage.length'),0);
 await navigate({init:language('zh-TW'),response:{body:valid}});assert.equal(await evaluate('document.querySelector("#language-banner").hidden'),true);
});
await check('DPR 2: actual CRT draw covers the full headline (CSS path skips)',async()=>{
 await navigate({dpr:2,reduced:true,response:{body:valid},init:`
  const native=CanvasRenderingContext2D.prototype.drawElementImage;
  if(native)CanvasRenderingContext2D.prototype.drawElementImage=function(element,...args){
   const result=native.call(this,element,...args),r=element.getBoundingClientRect();
   window.__crtDrawHeight=result&&typeof result.d==='number'
    ? Math.abs(result.b)*element.offsetWidth+Math.abs(result.d)*element.offsetHeight:r.height;
   return result;
  };`});
 if(await evaluate('document.documentElement.dataset.crt !== "canvas"'))return;
 const size=await evaluate(`({draw:window.__crtDrawHeight,title:document.querySelector('#hero-title').getBoundingClientRect().height})`);
 assert(Number.isFinite(size.draw),'Measure a native draw, not only canvas allocation');
 assert(size.draw+1>=size.title && size.draw<=size.title*1.1,JSON.stringify(size));
});
await check('Glitch: short, self-cleaning, one signal drop per visit, none for reduced motion',async()=>{
 await navigate({response:{body:valid}});
 await delay(4600); // let the scheduled first headline glitch (2-4 s) finish
 await evaluate(`document.dispatchEvent(new CustomEvent('imic:glitch',{detail:{target:document.querySelector('#hero-title'),level:'medium'}}))`);
 await delay(90);
 const canvas=await evaluate('document.documentElement.dataset.crt === "canvas"');
 assert.equal(await evaluate('document.querySelectorAll(".glitch-layer .glitch-ghost").length'),canvas?0:2);
 await shot('glitch-title');
 await delay(600);
 assert.equal(await evaluate('document.querySelectorAll(".glitch-layer").length'),0);
 assert.equal(await evaluate('document.querySelector("#hero-title").style.clipPath + document.querySelector("#hero-title").style.transform'),'');
 await evaluate(`document.dispatchEvent(new CustomEvent('imic:glitch',{detail:{level:'signal'}}))`);
 await delay(80);
 assert.equal(await evaluate('document.querySelectorAll(".signal-drop i").length'),7);
 assert.equal(await evaluate('document.documentElement.classList.contains("is-signal-drop")'),true);
 await shot('glitch-signal');
 await delay(500);
 assert.equal(await evaluate('document.querySelectorAll(".signal-drop").length + document.querySelector("main").style.transform.length'),0);
 await evaluate(`document.dispatchEvent(new CustomEvent('imic:glitch',{detail:{level:'signal'}}))`);
 await delay(60);
 assert.equal(await evaluate('document.querySelectorAll(".signal-drop").length'),0,'signal drop must run once per visit');
 await navigate({reduced:true,response:{body:valid}});
 await evaluate(`document.dispatchEvent(new CustomEvent('imic:glitch',{detail:{target:document.querySelector('#hero-title'),level:'medium'}}));document.dispatchEvent(new CustomEvent('imic:glitch',{detail:{level:'signal'}}))`);
 await delay(60);
 assert.equal(await evaluate('document.querySelectorAll(".glitch-layer,.signal-drop").length'),0);
});
}finally{
 await fs.mkdir('build/site-tests',{recursive:true});
 await fs.writeFile('build/site-tests/analytics-samples.json',JSON.stringify(samples,null,2));
 await fs.writeFile('build/site-tests/browser-results.json',JSON.stringify(report,null,2));
 await cdp.call('Target.closeTarget',{targetId:target.targetId});cdp.ws.close();
 if(ownedSession)execFileSync('agent-browser',['--session',ownedSession,'close']);
}
console.log(`${report.filter(x=>x.result==='PASS').length}/${report.length} browser checks passed`);
if(report.some(x=>x.result==='FAIL'))process.exitCode=1;
