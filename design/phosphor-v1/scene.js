// Genuine xyz wire geometry. Independent visual study; no native app code is used.
const TAU = Math.PI * 2;
const norm = a => { const l = Math.hypot(...a); return a.map(x => x / l); };
const cross = (a, b) => [a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0]];
const dot = (a,b) => a.reduce((s,x,i)=>s+x*b[i],0);
function multiply(a,b) {
  const c = new Float32Array(16);
  for(let j=0;j<4;j++) for(let i=0;i<4;i++) for(let k=0;k<4;k++) c[j*4+i]+=a[k*4+i]*b[j*4+k];
  return c;
}
function view(eye) {
  const z=norm(eye), x=norm(cross([0,1,0],z)), y=cross(z,x);
  return new Float32Array([x[0],y[0],z[0],0,x[1],y[1],z[1],0,x[2],y[2],z[2],0,-dot(x,eye),-dot(y,eye),-dot(z,eye),1]);
}
const lineVert=`#version 300 es
precision highp float;
layout(location=0) in vec2 corner;
layout(location=1) in vec3 start;
layout(location=2) in vec3 end;
layout(location=3) in vec4 color;
uniform mat4 mvp; uniform vec2 resolution; uniform float width;
out vec4 tint; out float edge;
void main(){
 vec4 a=mvp*vec4(start,1.),b=mvp*vec4(end,1.);
 vec2 direction=(b.xy/b.w-a.xy/a.w)*resolution;
 vec2 n=normalize(vec2(-direction.y,direction.x)+vec2(.00001));
 vec4 p=mix(a,b,corner.x); p.xy+=n*corner.y*width/resolution*p.w;
 gl_Position=p;tint=color;edge=corner.y;
}`;
const lineFrag=`#version 300 es
precision highp float;
in vec4 tint;in float edge;out vec4 result;
void main(){float a=(1.-smoothstep(.45,1.,abs(edge)))*tint.a;result=vec4(tint.rgb*a,a);}`;
const fullVert=`#version 300 es
precision highp float;out vec2 uv;
void main(){vec2 p=vec2(float((gl_VertexID<<1)&2),float(gl_VertexID&2));uv=p;gl_Position=vec4(p*2.-1.,0,1);}`;
const blurFrag=`#version 300 es
precision highp float;in vec2 uv;out vec4 result;
uniform sampler2D source;uniform vec2 direction;uniform bool threshold;
vec3 sampleAt(vec2 p){vec3 c=texture(source,p).rgb;return threshold?c*smoothstep(.08,.4,max(c.r,max(c.g,c.b))):c;}
void main(){vec3 c=sampleAt(uv)*.227027;
 c+=(sampleAt(uv+direction*1.384615)+sampleAt(uv-direction*1.384615))*.316216;
 c+=(sampleAt(uv+direction*3.230769)+sampleAt(uv-direction*3.230769))*.070270;
 result=vec4(c,1);}`;
const compositeFrag=`#version 300 es
precision highp float;in vec2 uv;out vec4 result;
uniform sampler2D source;uniform sampler2D nearGlow;uniform sampler2D farGlow;
uniform bool glow;uniform bool crt;
void main(){vec3 c=texture(source,uv).rgb;
 if(glow)c+=texture(nearGlow,uv).rgb*.95+texture(farGlow,uv).rgb*.47;
 c=1.-exp(-c*1.16);c=pow(c,vec3(.82));
 if(crt){float scan=.96+.04*sin(gl_FragCoord.y*3.14159265);c*=scan;}
 float a=max(c.r,max(c.g,c.b));result=vec4(c,a);}`;

export class WireScene {
  constructor(canvas) {
    this.canvas=canvas;this.gl=canvas.getContext('webgl2',{alpha:true,premultipliedAlpha:true,antialias:false});
    if(!this.gl)throw new Error('WebGL 2 unavailable');
    const g=this.gl;
    this.hdr=!!g.getExtension('EXT_color_buffer_float');
    this.line=this.program(lineVert,lineFrag);this.blur=this.program(fullVert,blurFrag);this.composite=this.program(fullVert,compositeFrag);
    this.vao=g.createVertexArray();g.bindVertexArray(this.vao);
    const corners=g.createBuffer();g.bindBuffer(g.ARRAY_BUFFER,corners);
    g.bufferData(g.ARRAY_BUFFER,new Float32Array([0,-1,1,-1,1,1,0,-1,1,1,0,1]),g.STATIC_DRAW);
    g.enableVertexAttribArray(0);g.vertexAttribPointer(0,2,g.FLOAT,false,0,0);
    this.data=new Float32Array(6000*10);this.instances=g.createBuffer();g.bindBuffer(g.ARRAY_BUFFER,this.instances);g.bufferData(g.ARRAY_BUFFER,this.data.byteLength,g.DYNAMIC_DRAW);
    [[1,3,0],[2,3,12],[3,4,24]].forEach(([loc,size,offset])=>{g.enableVertexAttribArray(loc);g.vertexAttribPointer(loc,size,g.FLOAT,false,40,offset);g.vertexAttribDivisor(loc,1);});
    this.fullVAO=g.createVertexArray();this.targets=[];this.width=0;this.height=0;this.settings={time:0,level:0,pull:0,anchor:.5,camera:'front'};
    this.resize();canvas.dataset.ready='true';
  }
  program(v,f) {
    const g=this.gl,p=g.createProgram();
    for(const [type,source] of [[g.VERTEX_SHADER,v],[g.FRAGMENT_SHADER,f]]){const s=g.createShader(type);g.shaderSource(s,source);g.compileShader(s);if(!g.getShaderParameter(s,g.COMPILE_STATUS))throw new Error(g.getShaderInfoLog(s));g.attachShader(p,s);g.deleteShader(s);}
    g.linkProgram(p);if(!g.getProgramParameter(p,g.LINK_STATUS))throw new Error(g.getProgramInfoLog(p));return p;
  }
  uniform(p,name){return this.gl.getUniformLocation(p,name);}
  target(w,h,depth=false){
    const g=this.gl,tex=g.createTexture(),fb=g.createFramebuffer();g.bindTexture(g.TEXTURE_2D,tex);
    g.texImage2D(g.TEXTURE_2D,0,this.hdr?g.RGBA16F:g.RGBA,w,h,0,g.RGBA,this.hdr?g.HALF_FLOAT:g.UNSIGNED_BYTE,null);
    g.texParameteri(g.TEXTURE_2D,g.TEXTURE_MIN_FILTER,g.LINEAR);g.texParameteri(g.TEXTURE_2D,g.TEXTURE_MAG_FILTER,g.LINEAR);
    g.texParameteri(g.TEXTURE_2D,g.TEXTURE_WRAP_S,g.CLAMP_TO_EDGE);g.texParameteri(g.TEXTURE_2D,g.TEXTURE_WRAP_T,g.CLAMP_TO_EDGE);
    g.bindFramebuffer(g.FRAMEBUFFER,fb);g.framebufferTexture2D(g.FRAMEBUFFER,g.COLOR_ATTACHMENT0,g.TEXTURE_2D,tex,0);
    let rb=null;if(depth){rb=g.createRenderbuffer();g.bindRenderbuffer(g.RENDERBUFFER,rb);g.renderbufferStorage(g.RENDERBUFFER,g.DEPTH_COMPONENT16,w,h);g.framebufferRenderbuffer(g.FRAMEBUFFER,g.DEPTH_ATTACHMENT,g.RENDERBUFFER,rb);}
    if(g.checkFramebufferStatus(g.FRAMEBUFFER)!==g.FRAMEBUFFER_COMPLETE)throw new Error('Incomplete rendering target');
    return {tex,fb,rb,w,h};
  }
  resize(){
    const r=this.canvas.getBoundingClientRect(),dpr=Math.min(devicePixelRatio||1,2),w=Math.max(2,Math.round(r.width*dpr)),h=Math.max(2,Math.round(r.height*dpr));
    this.cssWidth=r.width;this.cssHeight=r.height;this.dpr=dpr;
    if(w===this.width&&h===this.height)return;
    const g=this.gl;this.targets.forEach(t=>{g.deleteTexture(t.tex);g.deleteFramebuffer(t.fb);if(t.rb)g.deleteRenderbuffer(t.rb);});
    this.width=this.canvas.width=w;this.height=this.canvas.height=h;
    const hw=Math.ceil(w/2),hh=Math.ceil(h/2);this.targets=[this.target(w,h,true),...Array.from({length:4},()=>this.target(hw,hh))];
  }
  matrix(camera){
    const a=this.width/this.height,scale=2.05,top=scale/a;
    const ortho=new Float32Array([1/scale,0,0,0,0,1/top,0,0,0,0,-2/20,0,0,0,-1.01,1]);
    const eye=camera==='side'?[5,.7,.7]:camera==='oblique'?[3.2,2.1,4.7]:[1.25,.48,5.5];
    return multiply(ortho,view(eye));
  }
  center(s){
    const {time,level,pull,anchor}=this.settings;
    const envelope=Math.pow(Math.sin(Math.PI*s),.85);
    // Both ends remain fixed; moving the grab point changes the bend maximum.
    const bend=s<anchor?Math.sin(s/anchor*Math.PI/2):Math.sin((1-s)/(1-anchor)*Math.PI/2);
    return [(s-.5)*3.56,-pull*bend+.018*Math.sin(s*TAU*1.4-time*.8)*envelope,.012*Math.sin(time*.6+s*4)*envelope];
  }
  pointOnRing(s,angle){
    const {time,level,pull}=this.settings,c=this.center(s),lo=this.center(Math.max(0,s-.002)),hi=this.center(Math.min(1,s+.002));
    const tangent=norm(hi.map((v,i)=>v-lo[i])),n=norm(cross([0,0,1],tangent)),b=cross(tangent,n);
    const envelope=Math.pow(Math.sin(Math.PI*s),.65);
    const voice=(.5+.3*Math.sin(s*20+time*7)+.2*Math.sin(s*37-time*9))*level;
    const radius=.055+envelope*(.55+.035*Math.sin(s*9-time*.65)+voice*.26)*(1-Math.min(.25,Math.abs(pull)*.09));
    return c.map((v,i)=>v+radius*(Math.cos(angle)*n[i]+Math.sin(angle)*b[i]));
  }
  project(point){
    const m=this.mvp,p=[...point,1],v=[0,0,0,0];for(let i=0;i<4;i++)for(let j=0;j<4;j++)v[i]+=m[j*4+i]*p[j];
    return {x:(v[0]/v[3]+1)*this.cssWidth/2,y:(1-v[1]/v[3])*this.cssHeight/2,z:v[2]/v[3]};
  }
  segment(a,b,c){let n=this.count++*10;this.data.set(a,n);this.data.set(b,n+3);this.data.set(c,n+6);}
  geometry(){
    this.count=0;const {time,pull,anchor,level}=this.settings;
    // A faint measurement plane makes the z dimension legible without filling the background.
    for(let i=0;i<13;i++){const x=-1.8+i*.3;this.segment([x,-.85,-.5],[x,-.85,.5],[.12,.25,.42,.11]);}
    for(let i=0;i<5;i++){const z=-.5+i*.25;this.segment([-1.8,-.85,z],[1.8,-.85,z],[.12,.25,.42,.11]);}
    for(let i=0;i<44;i++){
      const s=i/43,charged=Math.max(0,1-Math.abs(s-anchor)*2.8)*Math.min(1,Math.abs(pull)*2.2);
      let a=this.pointOnRing(s,0);
      for(let j=1;j<=72;j++){
        const angle=j/72*TAU,b=this.pointOnRing(s,angle),front=.24+.76*Math.pow((Math.sin(angle)+1)/2,1.5);
        const pulse=.9+.1*Math.sin(s*8-time*.5);
        const c=[(.23*(1-charged)+1.3*charged)*pulse,(.52*(1-charged)+.36*charged)*pulse,(1.14*(1-charged)+.08*charged)*pulse,front*(.68+level*.12)];
        this.segment(a,b,c);a=b;
      }
    }
    for(let j=0;j<6;j++){const angle=j/6*TAU+.1;for(let i=1;i<44;i++)this.segment(this.pointOnRing((i-1)/43,angle),this.pointOnRing(i/43,angle),[.21,.46,.84,.15]);}
    // End clamps and the center tension reference inhabit the same xyz scene.
    for(const s of [0,1]){const c=this.center(s);this.segment([c[0]-.07,c[1],0],[c[0]+.07,c[1],0],[1.5,.48,.1,.8]);}
  }
  texture(p,name,tex,unit){const g=this.gl;g.activeTexture(g.TEXTURE0+unit);g.bindTexture(g.TEXTURE_2D,tex);g.uniform1i(this.uniform(p,name),unit);}
  blurPass(src,dest,dx,dy,threshold=false){
    const g=this.gl,p=this.blur;g.bindFramebuffer(g.FRAMEBUFFER,dest.fb);g.viewport(0,0,dest.w,dest.h);g.useProgram(p);this.texture(p,'source',src.tex,0);g.uniform2f(this.uniform(p,'direction'),dx/src.w,dy/src.h);g.uniform1i(this.uniform(p,'threshold'),threshold);g.drawArrays(g.TRIANGLES,0,3);
  }
  render(settings){
    this.resize();this.settings=settings;this.mvp=this.matrix(settings.camera);this.geometry();
    const g=this.gl,[scene,nearA,nearB,farA,farB]=this.targets;
    g.bindFramebuffer(g.FRAMEBUFFER,scene.fb);g.viewport(0,0,this.width,this.height);g.clearColor(0,0,0,0);g.clear(g.COLOR_BUFFER_BIT|g.DEPTH_BUFFER_BIT);
    g.enable(g.DEPTH_TEST);g.depthFunc(g.LEQUAL);g.enable(g.BLEND);g.blendFunc(g.ONE,g.ONE);g.bindVertexArray(this.vao);g.useProgram(this.line);
    g.bindBuffer(g.ARRAY_BUFFER,this.instances);g.bufferSubData(g.ARRAY_BUFFER,0,this.data.subarray(0,this.count*10));
    g.uniformMatrix4fv(this.uniform(this.line,'mvp'),false,this.mvp);g.uniform2f(this.uniform(this.line,'resolution'),this.width,this.height);g.uniform1f(this.uniform(this.line,'width'),2.05*this.dpr);
    g.drawArraysInstanced(g.TRIANGLES,0,6,this.count);
    g.disable(g.DEPTH_TEST);g.disable(g.BLEND);g.bindVertexArray(this.fullVAO);
    if(settings.glow){this.blurPass(scene,nearA,1,0,true);this.blurPass(nearA,nearB,0,1);this.blurPass(nearB,farA,3.5,0);this.blurPass(farA,farB,0,3.5);}
    g.bindFramebuffer(g.FRAMEBUFFER,null);g.viewport(0,0,this.width,this.height);g.useProgram(this.composite);
    this.texture(this.composite,'source',scene.tex,0);this.texture(this.composite,'nearGlow',nearB.tex,1);this.texture(this.composite,'farGlow',farB.tex,2);
    g.uniform1i(this.uniform(this.composite,'glow'),settings.glow);g.uniform1i(this.uniform(this.composite,'crt'),settings.crt);g.drawArrays(g.TRIANGLES,0,3);
  }
}
