#!/usr/bin/env python3
"""Own simulator capture + deterministic local transcoding. No real service calls.

scripts/site-capture.sh              create, capture, transcode, delete simulator
scripts/site-capture.sh --resume     resume an owned simulator after interruption
scripts/site-capture.sh --transcode  only regenerate final media from build/site-capture
Optional IMIC_SITE_SWEEP_SOURCE points to an existing, reviewed neutral test screenshot.
"""
import json, os, pathlib, signal, subprocess, sys, time
from PIL import Image
ROOT = pathlib.Path(__file__).resolve().parents[1]
os.chdir(ROOT)
RAW = ROOT / 'build/site-capture'
RAW.mkdir(parents=True, exist_ok=True)
MARKER = RAW / 'owned-simulator.json'
NAME = 'iMic Site Capture landing-page'
BUNDLE = 'art.malette.imic'
FFMPEG = '/opt/homebrew/bin/ffmpeg'
SESSION = 'imic-site-capture'

def run(*args, **kw):
    return subprocess.run([str(a) for a in args], check=True, **kw)
def sim(*args):
    return run('xcrun', 'simctl', *args)
def browser(*args):
    return run('agent-browser', '--session', SESSION, *args)
def capture(udid, name, mode, *args):
    sim('terminate', udid, BUNDLE)
    sim('launch', udid, BUNDLE, '--ui-preview='+mode, *args)
    time.sleep(2)
    log = RAW / (name+'.record.log')
    with log.open('w') as out:
        process = subprocess.Popen(['xcrun','simctl','io',udid,'recordVideo','--codec=h264','--force',str(RAW/(name+'.mov'))], stdout=out, stderr=out)
        try:
            for _ in range(100):
                if 'Recording started' in log.read_text(): break
                if process.poll() is not None: raise RuntimeError(log.read_text())
                time.sleep(.1)
            else: raise RuntimeError('Simulator recording did not become ready')
            time.sleep(7)
        finally:
            process.send_signal(signal.SIGINT)
            process.wait(timeout=30)
    sim('io',udid,'screenshot',RAW/(name+'.png'))
    print('Captured '+name, flush=True)

def encode(name, *inputs, vf=None, complex_filter=None, seconds=6):
    command=[FFMPEG,'-hide_banner','-loglevel','error','-y',*map(str,inputs)]
    if vf: command+=['-vf',vf]
    if complex_filter: command+=['-filter_complex',complex_filter,'-map','[out]']
    command+=['-t',str(seconds),'-r','30','-an','-c:v','libx264','-preset','slow','-crf','26','-pix_fmt','yuv420p','-movflags','+faststart',str(ROOT/f'site/assets/video/{name}.mp4')]
    run(*command)

def poster(name, timestamp=0):
    png=ROOT/f'site/assets/img/{name}.png'
    run(FFMPEG,'-hide_banner','-loglevel','error','-y','-ss',str(timestamp),'-i',ROOT/f'site/assets/video/{name}.mp4','-frames:v','1',png)
    Image.open(png).save(png.with_suffix('.webp'),quality=80,method=6)

def transcode():
    for name in ['listening','flight','sound']:
        encode(name,'-i',RAW/(name+'.mov'),vf='scale=416:900:force_original_aspect_ratio=decrease,pad=720:900:(ow-iw)/2:(oh-ih)/2:color=0x090909,tpad=stop_mode=clone:stop_duration=6',seconds=6)
        poster(name,1 if name=='flight' else 0)
    # Headless recording of the actual repository fixture, with synthetic neutral text.
    encode('live','-i',RAW/'live.webm',vf='scale=720:450,pad=720:900:0:225:color=0x090909,tpad=stop_mode=clone:stop_duration=6',seconds=6)
    poster('live',4)
    # Montage: actual App preview waveform → App preview flight → fixture text.
    # This is explicitly labeled a preview composition, not an end-to-end recording.
    encode('hero','-i',ROOT/'site/assets/video/listening.mp4','-i',ROOT/'site/assets/video/flight.mp4','-i',ROOT/'site/assets/video/live.mp4',complex_filter='[0:v]trim=0:2,setpts=PTS-STARTPTS,scale=576:720,pad=720:720:72:0:color=0x090909[a];[1:v]trim=0:4,setpts=PTS-STARTPTS,scale=576:720,pad=720:720:72:0:color=0x090909[b];[2:v]trim=4:6,setpts=PTS-STARTPTS,scale=720:900,crop=720:720:0:90[c];[a][b][c]concat=n=3:v=1:a=0[out]',seconds=8)
    poster('hero',.4)
    source=os.environ.get('IMIC_SITE_SWEEP_SOURCE')
    if source: run('cp',source,RAW/'polish-source.png')
    if not (RAW/'polish-source.png').exists(): raise RuntimeError('Set IMIC_SITE_SWEEP_SOURCE to an existing neutral fixture screenshot (static fallback)')
    png=ROOT/'site/assets/img/polish.png'
    run(FFMPEG,'-hide_banner','-loglevel','error','-y','-i',RAW/'polish-source.png','-vf','scale=1440:-2','-frames:v','1',png)
    Image.open(png).save(png.with_suffix('.webp'),quality=80,method=6)
    print('Transcoded H.264 / yuv420p / faststart / 30 fps / no audio, ≤8 seconds.',flush=True)

if '--transcode' in sys.argv:
    transcode();sys.exit()
if '--resume' in sys.argv:
    owner=json.loads(MARKER.read_text())
    devices=json.loads(subprocess.check_output(['xcrun','simctl','list','devices','--json']))['devices']
    assert any(d['udid']==owner['udid'] and d['name']==NAME for group in devices.values() for d in group), 'Owned simulator mismatch'
    udid=owner['udid']
else:
    if MARKER.exists(): raise RuntimeError('Existing ownership marker: use --resume or remove after deleting that owned simulator')
    udid=subprocess.check_output(['xcrun','simctl','create',NAME,'com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro'],text=True).strip()
    MARKER.write_text(json.dumps({'udid':udid,'name':NAME}))
try:
    subprocess.run(['xcrun','simctl','boot',udid],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
    sim('bootstatus',udid,'-b')
    app=ROOT/'build/ios.noindex/Build/Products/Debug-iphonesimulator/iMic.app'
    if not app.exists():run(ROOT/'scripts/build-ios.sh')
    sim('install',udid,app)
    sim('status_bar',udid,'override','--time','9:41','--dataNetwork','wifi','--wifiMode','active','--wifiBars','3','--batteryState','charged','--batteryLevel','100')
    # Ensure the App is already running so terminate is scoped and deterministic.
    sim('launch',udid,BUNDLE,'--ui-preview=idle')
    capture(udid,'listening','listening')
    capture(udid,'flight','flight','--debug-flight-count=36','--debug-flight-delay=1')
    capture(udid,'sound','sounds')
    browser('--executable-path','/Applications/Google Chrome.app/Contents/MacOS/Google Chrome','open',(ROOT/'tests/PolishApps/fields.html').as_uri()+'?kind=chat&theme=dark')
    browser('set','viewport','960','600')
    (RAW/'live.webm').unlink(missing_ok=True)
    browser('record','start',str(RAW/'live.webm'))
    js="""(async()=>{const field=document.querySelector('.field');field.textContent='';const text='把今天讨论的交互细节整理成一页说明。';for(const char of text){field.textContent+=char;await new Promise(r=>setTimeout(r,110));}await new Promise(r=>setTimeout(r,2500));})()"""
    run('agent-browser','--session',SESSION,'eval','--stdin',input=js,text=True)
    browser('record','stop')
    transcode()
finally:
    subprocess.run(['agent-browser','--session',SESSION,'close'],stdout=subprocess.DEVNULL)
    sim('shutdown',udid)
    sim('delete',udid)
    MARKER.unlink(missing_ok=True)
