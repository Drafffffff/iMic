import { WireScene } from './scene.js';

history.scrollRestoration='manual';
window.scrollTo(0,0);
const $ = s => document.querySelector(s);
const $$ = s => [...document.querySelectorAll(s)];
const phone=$('#phone'),surface=$('#scene-wrap'),glyphLayer=$('#glyph-layer');
const sample='把今天讨论的交互细节整理成一页说明，保留声音里的想法。';
const reduced=matchMedia('(prefers-reduced-motion: reduce)').matches;
let scene;
try { scene=new WireScene($('#scene')); }
catch(error){$('.scene-unavailable').hidden=false;console.error(error);}

const state={listening:false,started:0,text:'',pull:0,velocity:0,target:0,anchor:.5,dragging:false,release:false,fired:false,camera:'front',glow:true,crt:true,paused:false,lastActivity:performance.now(),ambient:0,glyphs:[],demoPull:0,sent:false};
let scheduled=0,renderedFrames=0;
let last=performance.now(),recordPointer=null,dragStart=null,backToReady=0;
const touch=()=>{
  state.lastActivity=performance.now();
  if(!scheduled&&!document.hidden){last=performance.now();scheduled=requestAnimationFrame(frame);}
};

for(const ruler of $$('.ruler')){
  for(let i=0;i<=24;i++){
    const y=2+i*7.5,line=document.createElementNS('http://www.w3.org/2000/svg','path');
    line.setAttribute('d',`M${i%4===0?0:i%2===0?5:9} ${y}H15`);
    line.setAttribute('opacity',i%4===0?'.95':'.55');ruler.append(line);
  }
}

function setStatus(word,caption){$('#status-word').textContent=word;$('#status-caption').textContent=caption;}
function refreshTextUI(){
  $('#result-button').hidden=!state.text;$('#footer-hint').hidden=!!state.text;
  $('#result-text').textContent=state.text||sample;
}
function addGlyph(char,index){
  const el=document.createElement('span');el.className='glyph';el.textContent=char;glyphLayer.append(el);
  // Golden-angle packing avoids straight rows while retaining a distinct place for each glyph.
  state.glyphs.push({el,index,s:.12+(index%29)/29*.76,angle:index*2.39996,age:0,mode:'incoming',seed:(Math.sin(index*91.7)*43758.5453)%1});
}
function clearGlyphs(){for(const glyph of state.glyphs)glyph.el.remove();state.glyphs=[];}
function populate(text=sample){clearGlyphs();state.text=text;[...text].slice(0,64).forEach(addGlyph);refreshTextUI();}
function startVoice(){
  state.dragging=false;state.release=false;state.demoPull=0;state.target=0;dragStart=null;
  if(state.listening)return;touch();clearTimeout(backToReady);state.listening=true;state.started=performance.now();state.text='';state.sent=false;clearGlyphs();
  phone.classList.add('listening');$('#record-label').textContent='LISTENING';$('#record-meta').textContent='SIGNAL / LIVE';
  $('#demo-voice').innerHTML='结束录音演示 <span>↙</span>';$('#demo-voice').setAttribute('aria-pressed','true');
  setStatus('LISTEN','声音正在形成文字');refreshTextUI();
}
function endVoice(cancel=false){
  if(!state.listening)return;state.listening=false;touch();phone.classList.remove('listening');$('#record-label').textContent='HOLD TO SPEAK';$('#elapsed').textContent='';$('#record-meta').textContent='PRESS + HOLD';
  $('#demo-voice').innerHTML='开始录音演示 <span>↗</span>';$('#demo-voice').setAttribute('aria-pressed','false');
  if(cancel){state.text='';clearGlyphs();setStatus('READY','按住说话，让声音成为文字');}
  else {if(!state.text)populate('让声音成为文字。');setStatus('DONE','文字已就绪，下拉松手发射');}
  refreshTextUI();
}
function fire(){
  if(state.fired)return;state.fired=true;state.sent=true;touch();
  const n=state.glyphs.length;
  for(const glyph of state.glyphs){
    const p=scene?.project(scene.pointOnRing(glyph.s,glyph.angle))||{x:200,y:120};
    glyph.mode='flight';glyph.age=0;glyph.origin=p;
    // Immediate explosive fan, then air drag. No sequenced meteor trail.
    const fan=(glyph.index/Math.max(1,n-1)-.5)*1.3+Math.sin(glyph.index*2.17)*.28;
    glyph.vx=Math.sin(fan)*1800;glyph.vy=-Math.cos(fan)*2600;glyph.rotation=Math.sin(glyph.index*1.4)*18;
  }
  setStatus('SENT','已演示发射');
  backToReady=setTimeout(()=>{if(!state.listening&&!state.dragging)setStatus(state.text?'DONE':'READY',state.text?'文字已就绪，下拉松手发射':'按住说话，让声音成为文字');},1400);
}
function release(){state.dragging=false;state.release=true;state.target=0;state.fired=false;touch();}
function showSettings(){touch();$('#settings').hidden=false;$('#settings-close').focus();}
function hideSettings(){$('#settings').hidden=true;$('#settings-button').focus();touch();}
$('#settings-button').onclick=showSettings;$('#device-button').onclick=showSettings;$('#settings-close').onclick=hideSettings;
$('#result-button').onclick=()=>{$('#result-sheet').hidden=false;$('#result-close').focus();touch();};
$('#result-close').onclick=()=>{$('#result-sheet').hidden=true;$('#result-button').focus();};
$('#library-button').onclick=()=>{populate();$('#settings').hidden=true;setStatus('DONE','演示文字已附着在声场上');touch();};
$('#polish-switch').onclick=event=>{
  const el=event.currentTarget,on=el.getAttribute('aria-checked')!=='true';el.setAttribute('aria-checked',String(on));el.classList.toggle('on',on);
  $$('.options button').forEach(b=>b.disabled=!on);$('#save-status').textContent=on?'已确认 · 原型中的本地演示设置':'已关闭 · 原型中的本地演示设置';
};
for(const key of ['strength','scenario'])for(const button of $$(`[data-${key}]`))button.onclick=()=>{
  $$(`[data-${key}]`).forEach(b=>{const selected=b===button;b.classList.toggle('selected',selected);b.setAttribute('aria-pressed',String(selected));});
  $('#save-status').textContent='已确认 · 原型中的本地演示设置';
};
for(const button of $$('[data-view]'))button.onclick=()=>{
  state.camera=button.dataset.view;touch();$$('[data-view]').forEach(b=>{b.classList.toggle('selected',b===button);b.setAttribute('aria-pressed',String(b===button));});
};
$('#glow-control').onchange=e=>{state.glow=e.target.checked;touch();};
$('#crt-control').onchange=e=>{state.crt=e.target.checked;$('.screen-texture').style.opacity=state.crt?'.24':'0';touch();};
$('#pause-control').onchange=e=>{state.paused=e.target.checked;touch();};
$('#demo-voice').onclick=()=>state.listening?endVoice():startVoice();
$('#demo-fire').onclick=()=>{
  endVoice();populate();state.glyphs.forEach(g=>{g.age=2;g.mode='attached';});
  state.demoPull=performance.now();state.release=false;state.fired=false;state.anchor=.5;touch();
};

$('#record-button').addEventListener('pointerdown',e=>{if(e.button!==0)return;e.preventDefault();recordPointer={id:e.pointerId,y:e.clientY};e.currentTarget.setPointerCapture(e.pointerId);startVoice();});
$('#record-button').addEventListener('pointerup',e=>{if(recordPointer?.id===e.pointerId){const cancel=e.clientY-recordPointer.y< -55;recordPointer=null;endVoice(cancel);}});
$('#record-button').addEventListener('pointercancel',()=>{recordPointer=null;endVoice(true);});
$('#record-button').addEventListener('lostpointercapture',()=>{if(recordPointer){recordPointer=null;endVoice(true);}});
$('#record-button').addEventListener('keydown',e=>{if((e.key===' '||e.key==='Enter')&&!e.repeat){e.preventDefault();startVoice();}});
$('#record-button').addEventListener('keyup',e=>{if(e.key===' '||e.key==='Enter'){e.preventDefault();endVoice();}});

surface.addEventListener('pointerdown',e=>{
  if(e.button!==0)return;e.preventDefault();touch();endVoice();clearTimeout(backToReady);
  if(!state.text||!state.glyphs.length){populate();state.glyphs.forEach(g=>{g.age=2;g.mode='attached';});}
  state.sent=false;
  state.dragging=true;state.release=false;state.fired=false;state.demoPull=0;state.velocity=0;
  const r=surface.getBoundingClientRect();state.anchor=Math.max(.08,Math.min(.92,(e.clientX-r.left)/r.width));
  dragStart={id:e.pointerId,x:e.clientX,y:e.clientY};surface.setPointerCapture(e.pointerId);
});
surface.addEventListener('pointermove',e=>{
  if(dragStart?.id!==e.pointerId)return;touch();const dy=e.clientY-dragStart.y;
  state.target=Math.max(-.45,Math.min(1.15,dy/135));state.pull=state.target;
  if(state.target>.08)setStatus('PULL','松手，释放这一段想法');
  else if(state.target<-.08)setStatus('CLEAR','继续上拉，删除演示文字');
});
surface.addEventListener('pointerup',e=>{
  if(dragStart?.id!==e.pointerId)return;
  const dy=e.clientY-dragStart.y;dragStart=null;
  if(dy< -65){clearGlyphs();state.text='';refreshTextUI();setStatus('READY','按住说话，让声音成为文字');state.release=false;state.target=0;state.dragging=false;}
  else if(state.pull>.05)release();else {state.dragging=false;state.target=0;setStatus('DONE','文字已就绪，下拉松手发射');}
});
function cancelDrag(){dragStart=null;state.dragging=false;state.release=false;state.target=0;touch();}
surface.addEventListener('pointercancel',cancelDrag);
surface.addEventListener('lostpointercapture',()=>{if(dragStart)cancelDrag();});
surface.addEventListener('keydown',e=>{
  if(e.key==='ArrowDown'){e.preventDefault();if(!state.glyphs.length)populate();state.target=Math.min(1.15,state.target+.15);state.pull=state.target;state.fired=false;state.release=false;state.dragging=true;setStatus('PULL','松手，释放这一段想法');touch();}
  if(e.key==='Enter'){e.preventDefault();release();}
  if(e.key==='Escape'){cancelDrag();}
});
document.addEventListener('keydown',e=>{if(e.key==='Escape'){if(!$('#settings').hidden)hideSettings();$('#result-sheet').hidden=true;}});
document.addEventListener('visibilitychange',()=>{last=performance.now();if(document.hidden){endVoice();cancelDrag();}else touch();});

function drawGlyphs(dt){
  const width=surface.clientWidth,height=surface.clientHeight;
  for(const glyph of state.glyphs){
    glyph.age+=dt;let x,y,size,opacity=1,rotation=0;
    const p=scene.project(scene.pointOnRing(glyph.s,glyph.angle));
    if(glyph.mode==='flight'){
      const t=glyph.age,k=.00036,speed=Math.hypot(glyph.vx,glyph.vy),distance=Math.log1p(k*speed*t)/k;
      x=glyph.origin.x+distance*glyph.vx/speed;y=glyph.origin.y+distance*glyph.vy/speed+210*t*t;
      size=Math.min(16,Math.max(10,25-state.glyphs.length*.28));rotation=glyph.rotation*Math.min(1,t*7);opacity=Math.max(0,1-t/1.2);
      if(reduced){x=glyph.origin.x;y=glyph.origin.y;opacity=Math.max(0,1-t/.18);}
    }else{
      const u=reduced?1:Math.min(1,glyph.age/.75),ease=1-Math.pow(1-u,3);
      x=(width*.48+Math.sin(glyph.index*.9)*30)*(1-ease)+p.x*ease;
      y=(height+100-glyph.index%3*5)*(1-ease)+p.y*ease-Math.sin(u*Math.PI)*38;
      size=18*(1-ease)+8.5*ease;opacity=.65+.35*ease;
      if(u===1)glyph.mode='attached';
    }
    glyph.el.style.transform=`translate(${x}px,${y}px) translate(-50%,-50%) rotate(${rotation}deg)`;
    glyph.el.style.fontSize=`${size}px`;glyph.el.style.opacity=opacity;
  }
  state.glyphs=state.glyphs.filter(g=>{if(g.mode==='flight'&&g.age>1.25){g.el.remove();return false;}return true;});
}
function frame(now){
  scheduled=0;if(document.hidden)return;
  const dt=Math.min(.035,(now-last)/1000);last=now;
  const idle=(now-state.lastActivity)/1000,fade=idle<40?1:Math.max(0,1-(idle-40)/4);
  if(!state.paused&&!reduced)state.ambient+=dt*fade;
  if(state.demoPull){const t=(now-state.demoPull)/1000;state.pull=Math.min(1,t/.45)*.92;state.target=state.pull;state.dragging=true;
    if(t>=.55){state.demoPull=0;release();}}
  if(!state.dragging){
    const previous=state.pull;state.velocity+=(-120*(state.pull-state.target)-9*state.velocity)*dt;state.pull+=state.velocity*dt;
    if(state.release&&!state.fired&&previous>0&&state.pull<=0){fire();state.release=false;}
    if(Math.abs(state.pull)<.0005&&Math.abs(state.velocity)<.005){state.pull=0;state.velocity=0;}
  }
  if(state.listening){
    const seconds=(now-state.started)/1000;$('#elapsed').textContent=`${String(Math.floor(seconds/60)).padStart(2,'0')}:${String(Math.floor(seconds)%60).padStart(2,'0')}`;
    const count=Math.min(sample.length,Math.floor(seconds*5));
    if(count>state.text.length){const previous=state.text.length;state.text=sample.slice(0,count);[...state.text].slice(previous).forEach((char,i)=>addGlyph(char,previous+i));refreshTextUI();}
  }
  const level=state.listening?.45+.2*Math.sin(state.ambient*7.3)+.18*Math.sin(state.ambient*12.1):0;
  if(scene){
    scene.render({time:state.ambient,level,pull:state.pull,anchor:state.anchor,camera:state.camera,glow:state.glow,crt:state.crt});
    drawGlyphs(dt);
    $$('.fixed-anchor').forEach((el,i)=>{const p=scene.project(scene.center(i));el.style.left=`${p.x-2}px`;el.style.top=`${p.y-2}px`;el.style.right='auto';});
  }
  const tension=Math.round(Math.max(0,state.pull)*87);$('#tension-readout').textContent=`↳ ${String(tension).padStart(2,'0')}`;
  surface.setAttribute('aria-valuenow',String(Math.min(100,tension)));phone.classList.toggle('charging',state.pull>.08);
  renderedFrames++;
  const moving=state.listening||state.dragging||state.demoPull||Math.abs(state.pull)>.0005||Math.abs(state.velocity)>.005||state.glyphs.some(g=>g.mode==='incoming'||g.mode==='flight');
  if((!state.paused&&!reduced&&idle<44)||moving)scheduled=requestAnimationFrame(frame);
}
window.addEventListener('resize',touch);
window.DWPreview={get state(){return {camera:state.camera,listening:state.listening,text:state.text,depth:!!scene,glow:state.glow,crt:state.crt,pull:state.pull,glyphs:state.glyphs.length,sent:state.sent,ambient:state.ambient,renderedFrames,scheduled:!!scheduled};}};
touch();
